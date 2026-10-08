import Foundation

/// External authentication/fetch boundary only. Typed addon/library/watch conversion belongs to
/// VortxLegacyBootstrapMaterial; source ownership and merge semantics belong to the native kernel.
enum VortxNativeOwnAccountProducer {
    struct Generation: Equatable, Sendable { fileprivate let slot: String; fileprivate let value: UUID; fileprivate let context: UUID }
    private final class Epochs: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var values: [String: UUID] = [:]
        var context = UUID()
    }
    private static let epochs = Epochs()
    static func capture(slot: String) -> Generation {
        epochs.lock.withLock {
            let value = epochs.values[slot] ?? UUID(); epochs.values[slot] = value
            return Generation(slot: slot, value: value, context: epochs.context)
        }
    }
    static func invalidate(slot: String) { epochs.lock.withLock { epochs.values[slot] = UUID() } }
    static func withCredentialMutation<T>(slot: String, _ mutation: () throws -> T) rethrows -> T {
        try epochs.lock.withLock { epochs.values[slot] = UUID(); return try mutation() }
    }
    static func invalidateContext() { epochs.lock.withLock { epochs.context = UUID() } }
    struct Authority: VortxMutationAuthority {
        let generations: [Generation]
        let validate: @Sendable () -> Bool
        func withActive(_ operation: () throws -> Void) throws {
            try epochs.lock.withLock {
                try Task.checkCancellation()
                guard generations.allSatisfy({ epochs.values[$0.slot] == $0.value && epochs.context == $0.context }), validate() else { throw VortxNativeError.superseded }
                try operation()
            }
        }
    }
    private struct RawSource: Encodable {
        let schemaVersion = 1
        let libraryResponseBase64: String
        let addonsResponseBase64: String
        let profileOverlayBase64: String
    }
    /// Copy only the exact authenticated UUID slice. Saved owner membership and global intents
    /// are deliberately absent; the importer decides which profile-local fields it understands.
    static func overlay(document: VortxJSON, profileID: UUID) throws -> Data {
        func selected(_ value: VortxJSON?) throws -> VortxJSON? {
            guard let value else { return nil }
            guard case .object(let fields) = value else { throw VortxNativeError.invalidSnapshot }
            let matches = fields.filter { UUID(uuidString: $0.key) == profileID }
            guard matches.count <= 1 else { throw VortxNativeError.invalidSnapshot }
            return matches.first?.value
        }
        var result: [String: VortxJSON] = [:]
        if let bucket = try selected(document["vortx"]?["byProfile"]) {
            result["vortx"] = .object(["byProfile": .object([profileID.uuidString: bucket])])
        }
        if let removed = try selected(document["webProgress"]?["removed"]?["byProfile"]) {
            result["webProgress"] = .object(["removed": .object(["byProfile": .object([profileID.uuidString: removed])])])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(VortxJSON.object(result))
    }
    typealias Verify = @Sendable (String) async throws -> String
    typealias Send = @Sendable (URLRequest) async throws -> AuthenticatedHTTPResponse

    static func fetch(profileID: UUID, authKey: String, authority: any VortxMutationAuthority,
                      profileOverlay: Data = Data("{}".utf8),
                      verify: Verify = { try await LinkAuthService.authenticatedIdentity(authKey: $0).uid },
                      send: Send = { try await AuthenticatedHTTPTransport.shared.send($0, allowedHosts: ["api.strem.io"],
                          maxResponseBytes: AuthenticatedHTTPTransport.snapshotResponseLimit) }) async throws -> VortxLegacyBootstrapMaterial.OwnAccountSource {
        guard !authKey.isEmpty else { throw VortxNativeError.invalidSnapshot }
        try authority.withActive {}
        let uid = try await verify(authKey)
        try authority.withActive {}
        guard !uid.isEmpty, uid == uid.trimmingCharacters(in: .whitespacesAndNewlines), uid.utf8.count <= 256,
              !uid.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw VortxNativeError.invalidResponse }
        func request(_ path: String, fields: [String: Any]) throws -> URLRequest {
            var request = URLRequest(url: URL(string: "https://api.strem.io/api/" + path)!)
            request.httpMethod = "POST"; request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body = fields; body["authKey"] = authKey
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }
        let library = try await send(request("datastoreGet", fields: ["collection": "libraryItem", "all": true]))
        try authority.withActive {}
        guard (200..<300).contains(library.statusCode),
              let libraryObject = try AuthenticatedHTTPTransport.jsonObject(from: library.data) as? [String: Any],
              libraryObject["error"] == nil || libraryObject["error"] is NSNull,
              libraryObject["result"] is [[String: Any]] else { throw VortxNativeError.invalidResponse }
        let addons = try await send(request("addonCollectionGet", fields: ["update": false]))
        try authority.withActive {}
        guard (200..<300).contains(addons.statusCode),
              let addonsObject = try AuthenticatedHTTPTransport.jsonObject(from: addons.data) as? [String: Any],
              addonsObject["error"] == nil || addonsObject["error"] is NSNull,
              let result = addonsObject["result"] as? [String: Any], result["addons"] is [[String: Any]] else { throw VortxNativeError.invalidResponse }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let source = try encoder.encode(RawSource(libraryResponseBase64: library.data.base64EncodedString(), addonsResponseBase64: addons.data.base64EncodedString(),
                                                profileOverlayBase64: profileOverlay.base64EncodedString()))
        try authority.withActive {}
        return .init(profileID: profileID, verifiedStreamingUID: uid, sourceDocument: source)
    }
}
