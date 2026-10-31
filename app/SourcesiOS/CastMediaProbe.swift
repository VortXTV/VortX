#if os(iOS) && !CINEMA_UI_SMOKE_RENDERER
import Foundation
import Darwin

/// Sender preflight rejects unsafe endpoints and redirects; it cannot prove another device's routing,
/// codec support, or DNS. Only the receiver's matching media status transfers playback ownership.
final class CastMediaProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case unavailable, unsafe, format
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The Cast source could not be reached. Check your Wi-Fi and source."
            case .unsafe: return "This source is local-only or redirects to an endpoint that cannot be shared with a receiver."
            case .format: return "The standard Cast receiver needs MP4, WebM, DASH or HLS. Choose another source; VortX does not convert this file for Cast."
            }
        }
    }
    // One probe instance owns one header-only task. The delegate cancels at the response boundary;
    // no response-body Data is accumulated, even if a server violates HEAD semantics.
    private let headerLock = NSLock()
    private var headerContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var headerTask: URLSessionDataTask?
    private var headerStarted = false
    private var headerCancelled = false
    typealias ConfigurationFactory = @Sendable () -> URLSessionConfiguration
    private let makeConfiguration: ConfigurationFactory
    private let selectedServer: URL?
    private let torrent: Bool
    private let localTorrentBase: URL?
    init(selectedServer: URL?, torrent: Bool, localTorrentBase: URL? = nil,
         makeConfiguration: @escaping ConfigurationFactory = { .ephemeral }) {
        self.selectedServer = selectedServer; self.torrent = torrent; self.localTorrentBase = localTorrentBase
        self.makeConfiguration = makeConfiguration
    }

    func prepare(_ url: URL) async throws -> (URL, String) {
        guard await Task.detached(priority: .utility, operation: { self.allowed(url) }).value else { throw Failure.unsafe }
        let config = makeConfiguration()
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 20
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: callbacks)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let response = try await headers(in: session, request: request)
        try Task.checkCancellation()
        guard (200...299).contains(response.statusCode), let finalURL = response.url else { throw Failure.unavailable }
        guard let type = GoogleCastFormatPolicy.contentType(responseType: response.value(forHTTPHeaderField: "Content-Type"), url: finalURL) else { throw Failure.format }
        if localTorrentBase != nil && type != "video/mp4" { throw Failure.format }
        return (finalURL, type)
    }

    private func headers(in session: URLSession, request: URLRequest) async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                headerLock.lock()
                guard !headerStarted, !headerCancelled else {
                    let cancelled = headerCancelled
                    headerLock.unlock()
                    task.cancel()
                    continuation.resume(throwing: cancelled ? CancellationError() : Failure.unavailable)
                    return
                }
                headerStarted = true
                headerContinuation = continuation; headerTask = task
                headerLock.unlock()
                task.resume()
            }
        } onCancel: { self.cancelHeaders() }
    }

    private func cancelHeaders() {
        headerLock.lock()
        headerCancelled = true
        let continuation = headerContinuation; headerContinuation = nil
        let task = headerTask; headerTask = nil
        headerLock.unlock()
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private func finishHeaders(_ result: Result<HTTPURLResponse, Error>,
                               cancelResponse: (@Sendable (URLSession.ResponseDisposition) -> Void)? = nil) {
        headerLock.lock()
        let continuation = headerContinuation; headerContinuation = nil
        let task = headerTask; headerTask = nil
        headerLock.unlock()
        // Claim the continuation before cancellation can synchronously or asynchronously complete the
        // task. Deny body delivery before waking prepare(), independently of delegate callback ordering.
        cancelResponse?(.cancel)
        task?.cancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        // Deny body delivery before returning response metadata. The async data(for:) convenience API
        // would otherwise be allowed to retain a misbehaving server's entire HEAD response body.
        if let response = response as? HTTPURLResponse {
            finishHeaders(.success(response), cancelResponse: completionHandler)
        } else {
            finishHeaders(.failure(Failure.unavailable), cancelResponse: completionHandler)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Defensive only: body delivery was denied above. Never append, iterate or retain the bytes.
        dataTask.cancel()
        finishHeaders(.failure(Failure.unavailable))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // The expected cancellation after a successful header receipt finds no continuation left.
        finishHeaders(.failure(error ?? Failure.unavailable))
    }

    private func allowed(_ url: URL) -> Bool {
        if let base = localTorrentBase { return CastTorrentRelayPolicy.sourceIsPinned(url, nativeBase: base) }
        guard torrent ? ReceiverURLPolicy.permitsTorrent(url, selectedServer: selectedServer)
                : ReceiverURLPolicy.permits(url, selectedServer: selectedServer), let host = url.host else { return false }
        let unbracketed = ReceiverURLPolicy.normalizedHost(host)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(unbracketed, nil, nil, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(first) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        var found = false
        while let current = node {
            defer { node = current.pointee.ai_next }
            guard current.pointee.ai_family == AF_INET || current.pointee.ai_family == AF_INET6 else { continue }
            var numeric = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen,
                              &numeric, socklen_t(numeric.count), nil, 0, NI_NUMERICHOST) == 0 else { return false }
            let scope = ReceiverURLPolicy.scope(String(decoding: numeric.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            if scope == .forbidden { return false }
            if scope == .lan, !(selectedServer.map { ReceiverURLPolicy.sameOrigin(url, $0) } ?? false) { return false }
            found = true
        }
        return found
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard localTorrentBase == nil, task.countOfBytesReceived == 0,
              let url = request.url, task.originalRequest?.url?.scheme != "https" || url.scheme == "https" else {
            completionHandler(nil); return
        }
        DispatchQueue.global(qos: .utility).async {
            // Use the validated final endpoint in the receiver load, rather than re-sending the redirector.
            completionHandler(self.allowed(url) ? request : nil)
        }
    }
}
#endif
