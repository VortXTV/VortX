import Foundation

/// Pure admission projection of ONE decrypted account. This is not authentication,
/// mutation authority, a merge, a receipt, or permission to export to an older writer.
/// The same-file Manager factory binds these bytes to its actual pull and original read.
struct OwnerHistoryPeerMaterial: Sendable {
    typealias Exact = OwnerHistoryExactJSON
    let nativeDocument: Data
    let localArchive: Data
    let peerCapabilities: Data
    let hostPreferencesData: Data?
    let carriesHistory: Bool
    let readOwnerUID: String?

    init(plaintext: Data, scope: VortxAccountScope) throws {
        try scope.validate()
        let account = try Exact.Object(plaintext)
        hostPreferencesData = account["nativeHostPreferences"]
        nativeDocument = try account.required("nativeSync")
        let native = try Exact.Object(nativeDocument)
        guard try Exact.sameText(native.text("scope"), scope.account),
              try Exact.sameText(native.text("ownerProfileId"), scope.ownerProfileID),
              let owner = UUID(uuidString: scope.ownerProfileID) else {
            throw VortxNativeError.invalidSnapshot
        }
        let rawSchema = try native.required("schemaVersion")
        guard let schema = Int(String(decoding: rawSchema, as: UTF8.self)),
              Data(String(schema).utf8) == rawSchema, (1...6).contains(schema) else {
            throw VortxNativeError.invalidSnapshot
        }
        var capabilities: [String] = []
        if let history = native["ownerHistory"] {
            let advertised = try Exact.Object(history)
            guard schema == 6,
                  try advertised.required("schemaVersion") == Data("1".utf8),
                  try advertised.text("capability") == "vortx.owner-history-fallback/1",
                  let carrier = account[OwnerHistoryAccountExport.archiveKey] else {
                throw VortxNativeError.invalidSnapshot
            }
            // These are the original authenticated producer's explicit schema/capability
            // pair, not a claim that a schema-5 peer understands a schema-6 export.
            localArchive = try OwnerHistoryAccountExport.localArchive(from: carrier, scope: scope)
            readOwnerUID = try OwnerHistoryAccountExport.readOwnerUID(from: carrier, scope: scope)
            capabilities = ["vortx.owner-history-fallback/1"]
            carriesHistory = true
        } else {
            // A known legacy peer has no source archive. Absence contributes an empty
            // journal to a UNION; it must never clear this device's retained sources.
            // Pending-only sidecars under schema5 are not safe for old-client round trips.
            guard schema <= 5, account[OwnerHistoryAccountExport.archiveKey] == nil else {
                throw VortxNativeError.invalidSnapshot
            }
            let journal = try VortxNativeOwnerHistoryJournal(scope: scope.account, ownerProfileID: owner)
            var local = try Exact.Object(Data("{}".utf8))
            local.set("kind", try Exact.string("vortx.owner-history.local/1"))
            local.set("journalBase64", try Exact.string(journal.encoded().base64EncodedString()))
            local.set("pending", Data("{}".utf8))
            localArchive = try local.encoded()
            readOwnerUID = nil
            carriesHistory = false
        }
        // Native validation and exact incomingNative conservation still run on the real
        // merge route. This projection cannot certify a raw document by itself.
        peerCapabilities = try JSONSerialization.data(withJSONObject: [
            "schemas": [schema], "capabilities": capabilities
        ], options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

extension OwnerHistoryRawAccountPreparationWorker {
    /// Interpretation-only legacy inputs from an ALREADY validated original raw checkpoint.
    /// No native hydration, schema downgrade or owner-history value decoding occurs here.
    func legacyNativeProjection(_ snapshot: Data) throws -> VortxJSON {
        guard !Thread.isMainThread else { throw Failure.mainThreadExecution }
        try Task.checkCancellation()
        let native = try OwnerHistoryExactJSON.Object(OwnerHistoryExactJSON.Object(snapshot).required("nativeSync"))
        var projection = try OwnerHistoryExactJSON.Object(Data("{}".utf8))
        for key in ["schemaVersion", "legacyImport", "profiles", "accountSlots"] {
            if let value = native[key] { projection.set(key, value) }
        }
        let checked = try VortxProfileOverlayWitness.decodeObject(json: projection.encoded())
        let result = try JSONDecoder().decode(VortxJSON.self,
            from: JSONSerialization.data(withJSONObject: checked, options: [.sortedKeys, .withoutEscapingSlashes]))
        try Task.checkCancellation()
        return result
    }
    func legacyHostSourceArchive(_ host: Data, scope: VortxAccountScope) throws -> Data? {
        guard !Thread.isMainThread else { throw Failure.mainThreadExecution }
        try Task.checkCancellation()
        try VortxNativeHostPreferences.validateSealed(host, scope: scope)
        let local = try JSONDecoder().decode(VortxNativeHostPreferences.Local.self, from: host)
        try Task.checkCancellation()
        return local.authenticatedSourceArchive
    }
    /// Legacy policy sees only its host tree. Neither raw native numbers nor owner source
    /// archives pass through Foundation. The original complete account remains the budget base.
    func peerHostProjection(_ plaintext: Data) throws -> Data {
        guard !Thread.isMainThread else { throw Failure.mainThreadExecution }
        try Task.checkCancellation()
        var host = try OwnerHistoryExactJSON.Object(plaintext)
        host.remove("nativeSync"); host.remove(OwnerHistoryAccountExport.archiveKey)
        let bytes = try host.encoded()
        try Task.checkCancellation()
        return bytes
    }
    func peerMaterial(_ plaintext: Data, scope: VortxAccountScope) throws -> OwnerHistoryPeerMaterial {
        guard !Thread.isMainThread else { throw Failure.mainThreadExecution }
        try Task.checkCancellation()
        let result = try OwnerHistoryPeerMaterial(plaintext: plaintext, scope: scope)
        try Task.checkCancellation()
        return result
    }

    func peerScope(_ plaintext: Data, account: String) throws -> VortxAccountScope {
        guard !Thread.isMainThread else { throw Failure.mainThreadExecution }
        try Task.checkCancellation()
        let native = try OwnerHistoryExactJSON.Object(OwnerHistoryExactJSON.Object(plaintext).required("nativeSync"))
        guard try OwnerHistoryExactJSON.sameText(native.text("scope"), account) else { throw VortxNativeError.invalidSnapshot }
        let scope = VortxAccountScope(account: account, ownerProfileID: try native.text("ownerProfileId"))
        try scope.validate()
        return scope
    }

    func requiresCausalOwnerHistoryRepublish(pulled: Data, accepted: Data) throws -> Bool {
        guard !Thread.isMainThread else { throw Failure.mainThreadExecution }
        try Task.checkCancellation()
        let old = try OwnerHistoryExactJSON.Object(pulled), joined = try OwnerHistoryExactJSON.Object(accepted)
        for key in ["nativeSync", "nativeHostPreferences", OwnerHistoryAccountExport.archiveKey,
                    "nativeProviderCredentials", "apiKeys"] {
            switch (old[key], joined[key]) {
            case (nil, nil): continue
            case (.some(let a), .some(let b)):
                if try OwnerHistoryExactJSON.canonical(a) != OwnerHistoryExactJSON.canonical(b) { return true }
            default: return true
            }
        }
        try Task.checkCancellation()
        return false
    }
}
