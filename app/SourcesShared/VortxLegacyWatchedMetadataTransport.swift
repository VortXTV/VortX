import Foundation

/// One raw metadata request to the descriptor retained in the authenticated migration source.
/// This never consults AddonManager, the native runtime's current registry, or cached projections.
enum VortxLegacyWatchedMetadataTransport {
    typealias Send = @Sendable (URLRequest, Set<String>, Int) async throws -> AuthenticatedHTTPResponse

    static func fetch(_ request: LegacyWatchedBitfieldMigrationEvidence.MetadataRequest,
                      send: Send = { try await AuthenticatedHTTPTransport.shared.send($0, allowedHosts: $1, maxResponseBytes: $2) }) async throws -> LegacyWatchedBitfieldMigrationEvidence.MetadataResponse {
        guard request.type == "series", !request.metaID.isEmpty,
              var components = URLComponents(string: request.addon.transportURL),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.percentEncodedPath.hasSuffix("/manifest.json") else {
            throw AuthenticatedHTTPTransportError.invalidEndpoint
        }
        // A video identifier is one path segment. Encode slash, percent, question and hash too,
        // so source-controlled identities cannot turn this into another resource or query.
        let segmentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let metaID = request.metaID.addingPercentEncoding(withAllowedCharacters: segmentCharacters) else {
            throw AuthenticatedHTTPTransportError.invalidEndpoint
        }
        components.percentEncodedPath = String(components.percentEncodedPath.dropLast("/manifest.json".count))
            + "/meta/series/" + metaID + ".json"
        guard let url = components.url else { throw AuthenticatedHTTPTransportError.invalidEndpoint }
        var http = URLRequest(url: url)
        http.httpMethod = "GET"; http.timeoutInterval = 20
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await send(http, [host], 2 * 1024 * 1024)
        guard (200..<300).contains(response.statusCode), response.data.count <= 2 * 1024 * 1024 else {
            throw AuthenticatedHTTPTransportError.invalidResponse
        }
        return .init(request: request, raw: response.data)
    }
}
