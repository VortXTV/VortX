import Foundation

/// Local `/nzb/create` transport, injectable without launching a server or touching a provider account.
enum UsenetNodeClient {
    enum ClientError: Error, Equatable {
        case createFailed(Int), badResponse, unsafeEndpoint, nativeUnavailable, unsupportedArchive
    }

    struct Endpoint: Sendable, Equatable {
        let base: String
        let requiresNativeCapabilities: Bool
    }

    private struct NativeCapabilities: Decodable {
        let version: Int
        let raw: Bool
        let multipartYenc: Bool
        let checksumsRequired: Bool
        let archives: [String]
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func acceptsNativeCapabilities(statusCode: Int, body: Data) -> Bool {
        guard statusCode == 200, let capabilities = try? JSONDecoder().decode(NativeCapabilities.self, from: body),
              capabilities.version == 1, capabilities.raw, capabilities.multipartYenc, capabilities.checksumsRequired,
              Set(["rar4-store", "rar5-store", "7z-copy"]).isSubset(of: Set(capabilities.archives)) else { return false }
        return true
    }

    static func createStream(endpoint: Endpoint, nzbURLs: [String], servers: [String], session: URLSession,
                             timeout: TimeInterval) async throws -> URL {
        try await createStream(base: endpoint.base, nzbURLs: nzbURLs, servers: servers, session: session,
                               timeout: timeout, requiresNativeCapabilities: endpoint.requiresNativeCapabilities)
    }

    static func createStream(base: String, nzbURLs: [String], servers: [String], session: URLSession,
                             timeout: TimeInterval, requiresNativeCapabilities: Bool = false) async throws -> URL {
        guard let origin = NativeTransportPolicy.localControlBase(base) else { throw ClientError.unsafeEndpoint }
        try Task.checkCancellation()
        let noRedirects = NoRedirects()
        if requiresNativeCapabilities {
            var probe = URLRequest(url: origin.appendingPathComponent("nzb/capabilities"))
            probe.timeoutInterval = min(timeout, 4)
            probe.cachePolicy = .reloadIgnoringLocalCacheData
            let (capabilities, response) = try await session.data(for: probe, delegate: noRedirects)
            guard acceptsNativeCapabilities(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                            body: capabilities) else { throw ClientError.nativeUnavailable }
            try Task.checkCancellation()
        }
        let createURL = origin.appendingPathComponent("nzb/create")
        let body: [String: Any] = ["servers": servers, "nzbUrls": nzbURLs]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { throw ClientError.badResponse }
        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request, delegate: noRedirects)
        try Task.checkCancellation()
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if requiresNativeCapabilities, code == 422 { throw ClientError.unsupportedArchive }
        guard (200...299).contains(code) else { throw ClientError.createFailed(code) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["key"] as? String, !key.isEmpty else { throw ClientError.badResponse }
        // A Node key is one opaque value, never additional query parameters or a fragment.
        let keyCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: keyCharacters) else {
            throw ClientError.badResponse
        }
        guard let streamURL = URL(string: "\(origin.appendingPathComponent("nzb/stream").absoluteString)?key=\(encodedKey)") else {
            throw ClientError.badResponse
        }
        return streamURL
    }
}
