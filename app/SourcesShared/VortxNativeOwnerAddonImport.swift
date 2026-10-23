import Foundation

/// Explicit owner import fetch only. Passive sign-in recovery never calls this helper. Descriptor
/// validation reuses the shipping strict bootstrap parser; the native batch owns membership.
/// Descriptors that parser holds are left out of the import.
enum VortxNativeOwnerAddonImport {
    struct Incomplete: Error {}
    typealias Send = @Sendable (URLRequest) async throws -> AuthenticatedHTTPResponse

    static func fetch(authKey: String, verifiedUID: String, owner: UserProfile,
                      authority: any VortxMutationAuthority,
                      send: Send = { try await AuthenticatedHTTPTransport.shared.send($0, allowedHosts: ["api.strem.io"],
                          maxResponseBytes: AuthenticatedHTTPTransport.snapshotResponseLimit) }) async throws -> [VortxJSON] {
        guard !authKey.isEmpty, owner.isOwner, !verifiedUID.isEmpty, verifiedUID.utf8.count <= 256,
              verifiedUID == verifiedUID.trimmingCharacters(in: .whitespacesAndNewlines),
              verifiedUID.rangeOfCharacter(from: .controlCharacters) == nil else { throw VortxNativeError.invalidResponse }
        try authority.withActive {}
        var request = URLRequest(url: URL(string: "https://api.strem.io/api/addonCollectionGet")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["authKey": authKey, "update": false])
        let response = try await send(request)
        try authority.withActive {}
        guard (200..<300).contains(response.statusCode),
              let envelope = try AuthenticatedHTTPTransport.jsonObject(from: response.data) as? [String: Any],
              envelope["error"] == nil || envelope["error"] is NSNull,
              let result = envelope["result"] as? [String: Any], let rows = result["addons"] as? [[String: Any]] else {
            throw VortxNativeError.invalidResponse
        }
        let document = try JSONSerialization.data(withJSONObject: ["addons": rows])
        let prepared = try VortxLegacyBootstrapMaterial.project(document: document, roster: [owner], ownerProfileID: owner.id,
                                                                rosterModifiedSeconds: nil, preparePendingMembership: false)
        let projected = try JSONDecoder().decode(VortxJSON.self, from: prepared.material)
        // A descriptor the engine cannot represent is skipped, not fatal (issue #262): one odd add-on
        // must not fail the whole Stremio connection. The import only adds, so nothing is removed.
        // Every other row must still project exactly once.
        let skipped = prepared.held.filter { $0.kind == "addon" }.count
        guard let addons = projected["addons"]?[owner.id.uuidString]?["items"]?.array, addons.count + skipped == rows.count else {
            throw VortxNativeError.invalidResponse
        }
        try authority.withActive {}
        return addons
    }
}
