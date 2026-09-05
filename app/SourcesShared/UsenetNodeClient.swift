import Foundation

/// Minimal Node `/nzb/create` transport.  Kept injectable so its wire contract can be exercised without
/// launching Node or touching a provider account.
enum UsenetNodeClient {
    enum ClientError: Error, Equatable { case createFailed(Int), badResponse }

    static func createStream(base: String, nzbURLs: [String], servers: [String], session: URLSession,
                             timeout: TimeInterval) async throws -> URL {
        guard let createURL = URL(string: "\(base)/nzb/create") else { throw ClientError.badResponse }
        let body: [String: Any] = ["servers": servers, "nzbUrls": nzbURLs]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { throw ClientError.badResponse }
        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw ClientError.createFailed(code) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["key"] as? String, !key.isEmpty else { throw ClientError.badResponse }
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        guard let streamURL = URL(string: "\(base)/nzb/stream?key=\(encodedKey)") else {
            throw ClientError.badResponse
        }
        return streamURL
    }
}
