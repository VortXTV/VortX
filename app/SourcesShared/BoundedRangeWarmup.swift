import Foundation

/// Reads at most a bounded prefix and accepts only an HTTP range response.
/// A server that ignores Range is canceled before its media body is retained.
enum BoundedRangeWarmup {
    struct Origin: Equatable, Sendable {
        let scheme: String
        let host: String
        let port: Int
    }

    struct Result: Equatable, Sendable {
        let statusCode: Int
        let byteCount: Int
    }

    enum WarmupError: Error, Equatable {
        case invalidResponse
        case rangeNotHonored(statusCode: Int)
        case emptyResponse
        case canceled
        case transport
    }

    static let defaultLimit = 16 * 1_024 * 1_024

    static func origin(of url: URL) -> Origin? {
        guard let rawScheme = url.scheme?.lowercased(),
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty else { return nil }
        let defaultPort: Int
        switch rawScheme {
        case "http":
            defaultPort = 80
        case "https":
            defaultPort = 443
        default:
            return nil
        }
        return Origin(
            scheme: rawScheme,
            host: rawHost,
            port: url.port ?? defaultPort
        )
    }

    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsOrigin = origin(of: lhs),
              let rhsOrigin = origin(of: rhs) else { return false }
        return lhsOrigin == rhsOrigin
    }

    /// Preserve required add-on headers only inside the exact scheme, host and effective-port origin.
    /// A cross-origin hop gets a new GET containing only the bounded Range request. No caller-supplied
    /// cookie, authorization or custom header can cross that boundary.
    static func redirectRequest(
        from source: URLRequest,
        to proposed: URLRequest
    ) -> URLRequest? {
        guard let sourceURL = source.url,
              let targetURL = proposed.url,
              origin(of: targetURL) != nil,
              targetURL.user == nil,
              targetURL.password == nil,
              let range = source.value(forHTTPHeaderField: "Range"),
              isValidRangeHeader(range) else { return nil }

        if isSameOrigin(sourceURL, targetURL) {
            var retained = proposed
            retained.httpMethod = "GET"
            retained.httpBody = nil
            retained.httpShouldHandleCookies = false
            for (name, value) in source.allHTTPHeaderFields ?? [:] {
                retained.setValue(value, forHTTPHeaderField: name)
            }
            return retained
        }

        var sanitized = URLRequest(
            url: targetURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: source.timeoutInterval
        )
        sanitized.httpMethod = "GET"
        sanitized.httpShouldHandleCookies = false
        sanitized.setValue(range, forHTTPHeaderField: "Range")
        return sanitized
    }

    private static func isValidRangeHeader(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.hasPrefix("bytes=0-") else { return false }
        let end = normalized.dropFirst("bytes=0-".count)
        return !end.isEmpty && end.allSatisfy(\.isNumber)
    }

    static func acceptsRangeResponse(
        statusCode: Int,
        contentRange: String?,
        requestedLimit: Int = defaultLimit
    ) -> Bool {
        guard statusCode == 206, let contentRange else { return false }
        let normalized = contentRange
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.hasPrefix("bytes "),
              requestedLimit > 0 else { return false }
        let value = normalized.dropFirst("bytes ".count)
        let slashParts = value.split(separator: "/", maxSplits: 1)
        guard slashParts.count == 2 else { return false }
        let bounds = slashParts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int(bounds[0]),
              let end = Int(bounds[1]),
              start == 0,
              end >= start,
              end < requestedLimit else { return false }
        return true
    }

    static func acceptedBytes(current: Int, incoming: Int, limit: Int) -> Int {
        guard current >= 0, incoming > 0, limit > current else { return 0 }
        return min(incoming, limit - current)
    }

    static func fetch(
        _ request: URLRequest,
        limit: Int = defaultLimit,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> Result {
        guard limit > 0 else { throw WarmupError.emptyResponse }
        let loader = BoundedRangeLoader(limit: limit, configuration: configuration)
        return try await loader.run(request)
    }
}

private final class BoundedRangeLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BoundedRangeWarmup.Result, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var statusCode = 0
    private var receivedBytes = 0
    private var rangeAccepted = false
    private var finished = false
    private var cancelRequested = false

    init(limit: Int, configuration: URLSessionConfiguration) {
        self.limit = limit
        self.configuration = configuration
    }

    func run(_ request: URLRequest) async throws -> BoundedRangeWarmup.Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.httpCookieAcceptPolicy = .never
                configuration.urlCredentialStorage = nil
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                var request = request
                request.httpShouldHandleCookies = false
                let task = session.dataTask(with: request)

                lock.lock()
                self.continuation = continuation
                self.session = session
                self.task = task
                let wasCanceled = cancelRequested
                lock.unlock()

                if wasCanceled {
                    finish(.failure(BoundedRangeWarmup.WarmupError.canceled))
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var source = task.currentRequest ?? task.originalRequest
        if source?.url != response.url { source?.url = response.url }
        guard let source else {
            completionHandler(nil)
            finish(.failure(BoundedRangeWarmup.WarmupError.transport))
            return
        }
        let redirect = BoundedRangeWarmup.redirectRequest(from: source, to: request)
        completionHandler(redirect)
        if redirect == nil {
            finish(.failure(BoundedRangeWarmup.WarmupError.transport))
        }
    }

    private func cancel() {
        lock.lock()
        cancelRequested = true
        let hasContinuation = continuation != nil
        lock.unlock()
        if hasContinuation {
            finish(.failure(BoundedRangeWarmup.WarmupError.canceled))
        }
    }

    private func finish(
        _ result: Result<BoundedRangeWarmup.Result, Error>
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()

        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(BoundedRangeWarmup.WarmupError.invalidResponse))
            return
        }
        let contentRange = response.value(forHTTPHeaderField: "Content-Range")
        guard BoundedRangeWarmup.acceptsRangeResponse(
            statusCode: response.statusCode,
            contentRange: contentRange,
            requestedLimit: limit
        ) else {
            completionHandler(.cancel)
            finish(.failure(
                BoundedRangeWarmup.WarmupError.rangeNotHonored(
                    statusCode: response.statusCode
                )
            ))
            return
        }

        lock.lock()
        statusCode = response.statusCode
        rangeAccepted = true
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        let accepted = BoundedRangeWarmup.acceptedBytes(
            current: receivedBytes,
            incoming: data.count,
            limit: limit
        )
        receivedBytes += accepted
        let reachedLimit = receivedBytes >= limit
        let result = BoundedRangeWarmup.Result(
            statusCode: statusCode,
            byteCount: receivedBytes
        )
        lock.unlock()

        if reachedLimit {
            finish(.success(result))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let accepted = rangeAccepted
        let count = receivedBytes
        let status = statusCode
        let wasCanceled = cancelRequested
        lock.unlock()

        if wasCanceled {
            finish(.failure(BoundedRangeWarmup.WarmupError.canceled))
        } else if error != nil {
            finish(.failure(BoundedRangeWarmup.WarmupError.transport))
        } else if accepted, count > 0 {
            finish(.success(.init(statusCode: status, byteCount: count)))
        } else {
            finish(.failure(BoundedRangeWarmup.WarmupError.emptyResponse))
        }
    }
}
