import Foundation

/// Exact full-account carrier. Unknown fields, legacy/provider siblings and typed native source
/// numeric tokens stay as raw JSON slices. This is a serializer, not proof of authentication or
/// peer compatibility. Production creation is paired with the existing pull/provider authority.
struct OwnerHistoryAccountExport: Sendable {
    typealias Exact = OwnerHistoryExactJSON
    static let archiveKey = "nativeOwnerHistorySources"
    static let maximumSealedBytes = 7 * 1024 * 1024
    static let maximumResponseBytes = 8 * 1024 * 1024
    private let fields: Exact.Object
    private static let ownedKeys: Set<String> = ["nativeSync", "nativeHostPreferences",
        "profileEditResults", "nativeProviderCredentials", "apiKeys", archiveKey]

    init(completeAccountPlaintext: Data) throws {
        fields = try Exact.Object(completeAccountPlaintext)
    }
    private init(fields: Exact.Object) { self.fields = fields }
    func raw(_ key: String) -> Data? { fields[key] }
    func encoded() throws -> Data { try fields.encoded() }

    /// The existing sync merger owns only these specific projections. It must not rebuild
    /// unrelated pulled fields through Foundation/Double to obtain an export or budget base.
    func replacingOwned(_ replacements: [String: Data]) throws -> Self {
        guard Set(replacements.keys).isSubset(of: Self.ownedKeys) else { throw VortxNativeError.invalidSnapshot }
        var next = fields
        for (key, value) in replacements {
            next.set(key, value)
        }
        return .init(fields: next)
    }

    /// Source-bearing projection includes the complete journal AND unresolved original pending
    /// records. It is one sibling of nativeSync, never an injected mutable kernel field.
    func projecting(_ checkpoint: OwnerHistorySessionCoordinator.Checkpoint) throws -> Self {
        try replacingOwned([
            "nativeSync": checkpoint.nativeSync,
            "nativeHostPreferences": checkpoint.nativeHostPreferences,
            "profileEditResults": checkpoint.profileEditResults,
            Self.archiveKey: checkpoint.ownerHistorySources
        ])
    }

    /// Host-only projection is cached until host preferences change. This never parses native
    /// ownerHistory or raw source archives and is not called for an unchanged progress tick.
    static func hostProjection(_ hostPreferences: Data, scope: VortxAccountScope) throws
        -> (document: Data, profileEditResults: Data) {
        try VortxNativeHostPreferences.validateSealed(hostPreferences, scope: scope)
        let host = try Exact.Object(hostPreferences)
        let hostLocal = try JSONDecoder().decode(VortxNativeHostPreferences.Local.self, from: hostPreferences)
        guard case .object(var result) = try VortxNativeProfileEditHost.outcome(hostLocal) else {
            throw VortxNativeError.invalidSnapshot
        }
        result["addonConflicts"] = try JSONDecoder().decode(VortxJSON.self,
            from: JSONEncoder().encode(hostLocal.websiteAddonConflicts ?? []))
        return try (host.required("document"), VortxNativeHostFieldEvidence.canonicalData(.object(result)))
    }

    static func sourceCarrier(local bytes: Data, scope: VortxAccountScope, readOwnerUID: String) throws -> Data {
        try scope.validate()
        let local = try Exact.Object(bytes)
        guard Set(local.fields.keys) == ["kind", "journalBase64", "pending"],
              try local.text("kind") == "vortx.owner-history.local/1",
              let journalBytes = Data(base64Encoded: try local.text("journalBase64")),
              journalBytes.base64EncodedString() == (try local.text("journalBase64")) else {
            throw VortxNativeError.invalidSnapshot
        }
        let journal = try Exact.Object(journalBytes)
        guard try Exact.sameText(journal.text("scope"), scope.account),
              try journal.text("ownerProfileId") == scope.ownerProfileID,
              try journal.text("kind") == VortxNativeOwnerHistoryJournal.kind else {
            throw VortxNativeError.invalidSnapshot
        }
        _ = try Exact.Object(local.required("pending"))
        var carrier = try Exact.Object(Data("{}".utf8))
        carrier.set("schemaVersion", Data("1".utf8))
        carrier.set("capability", try Exact.string("vortx.owner-history-complete-archive/1"))
        carrier.set("journal", journalBytes)
        try validateReadOwnerUID(readOwnerUID)
        carrier.set("readOwnerUID", try Exact.string(readOwnerUID))
        carrier.set("pending", try local.required("pending"))
        return try carrier.encoded()
    }

    /// Reverse transport keeps every original source/archive byte. It does NOT grant peer
    /// capability or authenticate a peer: the caller must own the exact authenticated account
    /// envelope and run the native full validator before using any source-bearing document.
    static func localArchive(from carrierBytes: Data, scope: VortxAccountScope) throws -> Data {
        try scope.validate()
        let carrier = try Exact.Object(carrierBytes)
        guard Set(carrier.fields.keys) == ["schemaVersion", "capability", "journal", "pending", "readOwnerUID"],
              try carrier.required("schemaVersion") == Data("1".utf8),
              try carrier.text("capability") == "vortx.owner-history-complete-archive/1" else {
            throw VortxNativeError.invalidSnapshot
        }
        let uid = try carrier.text("readOwnerUID")
        try validateReadOwnerUID(uid)
        let journalBytes = try carrier.required("journal"), journal = try Exact.Object(journalBytes)
        guard try Exact.sameText(journal.text("scope"), scope.account),
              try journal.text("ownerProfileId") == scope.ownerProfileID,
              try journal.text("kind") == VortxNativeOwnerHistoryJournal.kind else { throw VortxNativeError.invalidSnapshot }
        _ = try Exact.Object(carrier.required("pending"))
        var local = try Exact.Object(Data("{}".utf8))
        local.set("kind", try Exact.string("vortx.owner-history.local/1"))
        local.set("journalBase64", try Exact.string(journalBytes.base64EncodedString()))
        local.set("pending", try carrier.required("pending"))
        return try local.encoded()
    }

    /// Pending schema5 metadata stays encrypted LOCAL. Older clients cannot safely retain
    /// the new archive carrier. Do not fabricate schema6 merely to publish that carrier.
    /// Once native genuinely admits schema6, every journal and pending record is exported.
    func cloudPlaintext(writeV2: Bool) throws -> Data {
        let native = try Exact.Object(fields.required("nativeSync"))
        let schema = try JSONDecoder().decode(Int.self, from: native.required("schemaVersion"))
        if schema == 6 {
            guard native["ownerHistory"] != nil, fields[Self.archiveKey] != nil else {
                throw VortxNativeError.invalidSnapshot
            }
            return try validatedPlaintext(writeV2: writeV2)
        }
        guard (1...5).contains(schema), native["ownerHistory"] == nil else { throw VortxNativeError.invalidSnapshot }
        if let carrierBytes = fields[Self.archiveKey] {
            let carrier = try Exact.Object(carrierBytes)
            let journal = try Exact.Object(carrier.required("journal"))
            guard try Exact.Object(journal.required("sources")).fields.isEmpty else {
                throw VortxNativeError.invalidSnapshot
            }
        }
        var legacy = fields
        legacy.remove(Self.archiveKey)
        return try Self(fields: legacy).validatedPlaintext(writeV2: writeV2)
    }

    /// Presentation selector from the SAME authenticated encrypted account as nativeSync.
    /// This is not a credential, token, provider identity proof or source-import authority.
    /// Caller must pair scope/native/profile provenance; never infer this value from a journal.
    static func readOwnerUID(from carrier: Data, scope: VortxAccountScope) throws -> String {
        _ = try localArchive(from: carrier, scope: scope)
        return try Exact.Object(carrier).text("readOwnerUID")
    }

    static func validateReadOwnerUID(_ uid: String) throws {
        guard !uid.isEmpty, uid.utf8.count <= 1024,
              !uid.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VortxNativeError.invalidSnapshot
        }
    }

    func validatedPlaintext(writeV2: Bool) throws -> Data {
        let plaintext = try encoded()
        let sealed = try XperienceExportBudget.sealedByteCount(plaintextCount: plaintext.count, writeV2: writeV2)
        // Verified server response shape is JSON.stringify({document,version}). Ciphertext is
        // base64 plus optional "v2.", so it contains no JSON quotes, backslashes or controls.
        // JS does not escape slash. Maximum admitted version is 9007199254740991 (16 digits).
        let responseBytes = sealed + Data(#"{"document":"","version":}"#.utf8).count + 16
        guard sealed <= Self.maximumSealedBytes, responseBytes <= Self.maximumResponseBytes else {
            throw XperiencePersistenceFailure.exportTooLarge
        }
        return plaintext
    }
}

/// Concrete whole-account validator used by the source transaction. The pure serializer cannot
/// cross the production Bridge: this wrapper additionally owns the real observation/provider
/// witness captured by VortXSyncManager. Original credential/install/profile/FIFO/cancellation
/// authorities still enclose it at Session commit; it never replaces those authorities.
struct OwnerHistoryPreparedExport: OwnerHistoryCompleteCheckpointAuthority, Sendable {
    let completeAccount: OwnerHistoryAccountExport
    let scope: VortxAccountScope
    let writeV2: Bool
    let authority: XperienceExportWitnessAuthority
    func validateCompleteAccount(_ checkpoint: OwnerHistorySessionCoordinator.Checkpoint) throws {
        guard checkpoint.scope == scope else { throw VortxNativeError.superseded }
        _ = try completeAccount.projecting(checkpoint).validatedPlaintext(writeV2: writeV2)
    }
    func projected(_ checkpoint: OwnerHistorySessionCoordinator.Checkpoint) throws -> OwnerHistoryAccountExport {
        guard checkpoint.scope == scope else { throw VortxNativeError.superseded }
        return try completeAccount.projecting(checkpoint)
    }
    func completeAccount(_ checkpoint: OwnerHistorySessionCoordinator.Checkpoint) throws -> Data {
        try projected(checkpoint).validatedPlaintext(writeV2: writeV2)
    }
    func withActive(_ operation: () throws -> Void) throws { try authority.withActive(operation) }
}
