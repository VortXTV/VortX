import Foundation

/// Sends tracker-bearing torrent create requests without ever replaying their POST body to a redirect target.
///
/// A create body contains the torrent hash and tracker list. URLSession's default 307/308 handling preserves
/// the method and body, so a redirect could disclose that payload to a different origin. This transport always
/// refuses redirects and returns the original response status. The response body is never consumed.
final class TorrentCreateTransport: @unchecked Sendable {
    static let shared = TorrentCreateTransport()

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(
            configuration: configuration,
            delegate: NoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Returns the exact status from the original endpoint. Redirects therefore remain 30x and fail the
    /// caller's normal 2xx gate. `bytes(for:)` exposes headers without buffering the body; the task is canceled
    /// immediately after the status is captured.
    func create(url: URL, jsonBody: Data, timeout: TimeInterval = 15) async throws -> Int {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody
        request.timeoutInterval = timeout

        let (bytes, response) = try await session.bytes(for: request)
        return try await withTaskCancellationHandler {
            defer { bytes.task.cancel() }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return http.statusCode
        } onCancel: {
            bytes.task.cancel()
        }
    }
}
