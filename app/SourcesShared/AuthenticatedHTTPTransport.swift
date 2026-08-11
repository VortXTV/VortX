import Foundation

/// Stable, non-sensitive failure categories for bearer-bearing HTTP requests.
///
/// No case carries a URL, response body, token, or Foundation error description. Callers may therefore expose
/// `errorDescription` without turning a provider-controlled response or system diagnostic into credential output.
enum AuthenticatedHTTPTransportError: Error, Equatable, Sendable, LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case redirectRejected
    case invalidContentLength
    case responseTooLarge
    case invalidUTF8
    case invalidJSON
    case transportFailure

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Authenticated endpoint rejected."
        case .invalidResponse: return "Authenticated server response rejected."
        case .redirectRejected: return "Authenticated request redirect rejected."
        case .invalidContentLength: return "Authenticated response length rejected."
        case .responseTooLarge: return "Authenticated response exceeded its limit."
        case .invalidUTF8: return "Authenticated JSON response was not valid UTF-8."
        case .invalidJSON: return "Authenticated JSON response was malformed."
        case .transportFailure: return "Authenticated request failed."
        }
    }
}

struct AuthenticatedHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

/// A single fail-closed transport for direct API calls that carry provider bearer tokens.
///
/// Every request gets a fresh ephemeral session so cookies, credential storage, and cache state cannot cross
/// accounts or providers. The request and response URL must both use HTTPS and match an exact caller-owned host
/// allowlist. Redirects are refused. Bodies are streamed into a hard cap that remains authoritative when
/// Content-Length is absent or understated.
final class AuthenticatedHTTPTransport: @unchecked Sendable {
    static let shared = AuthenticatedHTTPTransport()

    /// PIN/token/control documents and mutation acknowledgements are expected to be tiny JSON envelopes.
    static let controlResponseLimit = 64 * 1024
    /// Full watched/history/playback/list snapshots can legitimately contain thousands of rows. Eight MiB is
    /// deliberately generous for those bounded whole-account reads while still preventing unbounded buffering.
    static let snapshotResponseLimit = 8 * 1024 * 1024

    private let protocolClasses: [AnyClass]?

    /// `protocolClasses` exists only for the standalone real-URLSession hostile harness. The transport still
    /// creates and hardens an ephemeral configuration itself; callers cannot inject a shared or disk-backed
    /// session through this seam.
    init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
    }

    func send(
        _ request: URLRequest,
        allowedHosts: Set<String>,
        maxResponseBytes: Int
    ) async throws -> AuthenticatedHTTPResponse {
        guard maxResponseBytes >= 0,
              Self.isAllowed(request.url, allowedHosts: allowedHosts) else {
            throw AuthenticatedHTTPTransportError.invalidEndpoint
        }

        var hardened = request
        hardened.cachePolicy = .reloadIgnoringLocalCacheData
        hardened.httpShouldHandleCookies = false
        hardened.setValue(nil, forHTTPHeaderField: "Cookie")

        return try await LiveRequest(
            allowedHosts: Self.normalizedHosts(allowedHosts),
            maxResponseBytes: maxResponseBytes,
            protocolClasses: protocolClasses
        ).run(hardened)
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard String(data: data, encoding: .utf8) != nil else {
            throw AuthenticatedHTTPTransportError.invalidUTF8
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AuthenticatedHTTPTransportError.invalidJSON
        }
    }

    static func jsonObject(from data: Data) throws -> Any {
        guard String(data: data, encoding: .utf8) != nil else {
            throw AuthenticatedHTTPTransportError.invalidUTF8
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AuthenticatedHTTPTransportError.invalidJSON
        }
    }

    private static func normalizedHosts(_ hosts: Set<String>) -> Set<String> {
        Set(hosts.map { $0.lowercased() })
    }

    private static func isAllowed(_ url: URL?, allowedHosts: Set<String>) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil else { return false }
        return normalizedHosts(allowedHosts).contains(host)
    }

    private static func parsedContentLength(_ raw: String?) throws -> Int? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
              let parsed = UInt64(value),
              parsed <= UInt64(Int.max) else {
            throw AuthenticatedHTTPTransportError.invalidContentLength
        }
        return Int(parsed)
    }

    /// One delegate and one ephemeral session per request. The lock covers caller cancellation racing URLSession
    /// callbacks. Completion takes the continuation exactly once and drops all buffered bytes on every failure.
    private final class LiveRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let allowedHosts: Set<String>
        private let maxResponseBytes: Int
        private let protocolClasses: [AnyClass]?
        private let lock = NSLock()
        private var continuation: CheckedContinuation<AuthenticatedHTTPResponse, Error>?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var response: HTTPURLResponse?
        private var data = Data()
        private var cancellationRequested = false
        private var completed = false

        init(
            allowedHosts: Set<String>,
            maxResponseBytes: Int,
            protocolClasses: [AnyClass]?
        ) {
            self.allowedHosts = allowedHosts
            self.maxResponseBytes = maxResponseBytes
            self.protocolClasses = protocolClasses
        }

        func run(_ request: URLRequest) async throws -> AuthenticatedHTTPResponse {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    start(request, continuation: continuation)
                }
            } onCancel: {
                self.cancelFromCaller()
            }
        }

        private func start(
            _ request: URLRequest,
            continuation: CheckedContinuation<AuthenticatedHTTPResponse, Error>
        ) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            if let protocolClasses { configuration.protocolClasses = protocolClasses }

            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let task = session.dataTask(with: request)

            lock.lock()
            if cancellationRequested {
                completed = true
                lock.unlock()
                task.cancel()
                session.invalidateAndCancel()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            self.session = session
            self.task = task
            task.resume()
            lock.unlock()
        }

        private func cancelFromCaller() {
            lock.lock()
            cancellationRequested = true
            let started = continuation != nil
            lock.unlock()
            if started { finish(.failure(CancellationError()), cancelTask: true) }
        }

        private func finish(
            _ result: Result<AuthenticatedHTTPResponse, Error>,
            cancelTask: Bool
        ) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            if case .failure = result { data.removeAll(keepingCapacity: false) }
            let continuation = continuation
            let session = session
            let task = task
            self.continuation = nil
            self.session = nil
            self.task = nil
            lock.unlock()

            if cancelTask {
                task?.cancel()
                session?.invalidateAndCancel()
            } else {
                session?.finishTasksAndInvalidate()
            }
            continuation?.resume(with: result)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
            finish(.failure(AuthenticatedHTTPTransportError.redirectRejected), cancelTask: true)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse,
                  AuthenticatedHTTPTransport.isAllowed(http.url, allowedHosts: allowedHosts) else {
                completionHandler(.cancel)
                finish(.failure(AuthenticatedHTTPTransportError.invalidEndpoint), cancelTask: true)
                return
            }
            guard !(300..<400).contains(http.statusCode) else {
                completionHandler(.cancel)
                finish(.failure(AuthenticatedHTTPTransportError.redirectRejected), cancelTask: true)
                return
            }

            let declaredLength: Int?
            do {
                declaredLength = try AuthenticatedHTTPTransport.parsedContentLength(
                    http.value(forHTTPHeaderField: "Content-Length")
                )
            } catch {
                completionHandler(.cancel)
                finish(.failure(AuthenticatedHTTPTransportError.invalidContentLength), cancelTask: true)
                return
            }
            guard declaredLength.map({ $0 <= maxResponseBytes }) ?? true else {
                completionHandler(.cancel)
                finish(.failure(AuthenticatedHTTPTransportError.responseTooLarge), cancelTask: true)
                return
            }

            lock.lock()
            if !completed { self.response = http }
            let alreadyCompleted = completed
            lock.unlock()
            completionHandler(alreadyCompleted ? .cancel : .allow)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive chunk: Data
        ) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            guard chunk.count <= maxResponseBytes - data.count else {
                lock.unlock()
                finish(.failure(AuthenticatedHTTPTransportError.responseTooLarge), cancelTask: true)
                return
            }
            data.append(chunk)
            lock.unlock()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            let response = response
            let data = data
            lock.unlock()

            guard error == nil, let response else {
                finish(.failure(AuthenticatedHTTPTransportError.transportFailure), cancelTask: false)
                return
            }
            finish(
                .success(AuthenticatedHTTPResponse(data: data, statusCode: response.statusCode)),
                cancelTask: false
            )
        }
    }
}
