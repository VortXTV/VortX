import Foundation

/// A single GET. No redirects, cookies, shared cache, auth challenge credentials, retries or polling.
/// Production address checks reuse AddonURLGuard before and after the request. Its accepted DNS
/// resolve/connect rebinding limitation remains; this does not claim connection IP pinning.
enum XperienceExportHTTP {
    typealias AddressCheck = @Sendable (URL) async -> Bool
    static func load(_ endpoint: XperienceExportEndpoint,
                     configuration supplied: URLSessionConfiguration? = nil,
                     addressCheck: @escaping AddressCheck = { await AddonURLGuard.validate($0) == nil }) async throws -> Data {
        try Task.checkCancellation()
        guard await addressCheck(endpoint.url) else { throw XperienceExportFailure.invalidURL }
        try Task.checkCancellation()
        let configuration = supplied ?? .ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never; configuration.urlCredentialStorage = nil
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: DenyRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "GET"; request.timeoutInterval = 15
        request.httpShouldHandleCookies = false; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (stream, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, endpoint.acceptsResponseURL(http.url) else {
                throw XperienceExportFailure.invalidResponse
            }
            // Deny before considering Location. The delegate also rejects automatic following.
            guard !(300...399).contains(http.statusCode) else { throw XperienceExportFailure.invalidResponse }
            if [401, 403, 404, 410].contains(http.statusCode) { throw XperienceExportFailure.revoked }
            guard http.statusCode == 200, http.mimeType?.lowercased() == "application/json" else {
                throw XperienceExportFailure.invalidResponse
            }
            guard http.expectedContentLength <= Int64(XperienceCollections.maximumBytes) else {
                throw XperienceExportFailure.tooLarge
            }
            var data = Data()
            data.reserveCapacity(min(XperienceCollections.maximumBytes, 64 * 1024))
            for try await byte in stream {
                if data.count & 4095 == 0 { try Task.checkCancellation() }
                guard data.count < XperienceCollections.maximumBytes else { throw XperienceExportFailure.tooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard await addressCheck(endpoint.url) else { throw XperienceExportFailure.invalidURL }
            try Task.checkCancellation()
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let failure as XperienceExportFailure { throw failure }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw XperienceExportFailure.unavailable // Never surface URLSession's private URL/errors.
        }
    }
    private final class DenyRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Keep normal system TLS trust evaluation; never select saved HTTP credentials.
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }
}
