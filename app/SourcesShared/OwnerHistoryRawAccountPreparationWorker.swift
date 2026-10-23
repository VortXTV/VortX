import Foundation

/// Dedicated serial cold-preparation executor. No MainActor, transport, secure store, bundle,
/// mutation authority, witness, checkpoint, callback or retained credential cache lives here.
actor OwnerHistoryRawAccountPreparationWorker {
    static let shared = OwnerHistoryRawAccountPreparationWorker()
    enum Failure: Error, Equatable { case mainThreadExecution }
    struct Input: Sendable {
        let plaintext: Data
        let source: VortxNativeOwnerHistorySource.Capture
        let snapshotData: Data
        let hostPreferencesData: Data
        let ownerHistoryLocalData: Data?
        let readOwnerUID: String
        let providerBytes: String
        let providerActor: String
        let writeV2: Bool
    }

    func envelope(_ response: Data) throws -> (document: String, version: Int) {
        // Actual execution assertion, not an inference from an async call's spelling.
        guard !Thread.isMainThread else { throw Failure.mainThreadExecution }
        try Task.checkCancellation()
        let value = try OwnerHistoryRawAccountPreparation.envelope(response)
        try Task.checkCancellation()
        return value
    }

    func acknowledgedBase(_ bytes: Data, source: VortxNativeOwnerHistorySource.Capture,
        snapshot: Data, host: Data, local: Data?, readOwnerUID: String) throws -> Data {
        guard !Thread.isMainThread else { throw Failure.mainThreadExecution }
        try Task.checkCancellation()
        guard source.matches(snapshotData: snapshot) else { throw VortxNativeError.superseded }
        let scope = VortxAccountScope(account: source.scope, ownerProfileID: source.ownerProfileID.uuidString)
        let base = try OwnerHistoryAccountExport(completeAccountPlaintext: bytes)
        let projection = try OwnerHistoryAccountExport.hostProjection(host, scope: scope)
        var owned: [String: Data] = ["nativeSync": source.nativeDocumentBytes,
            "nativeHostPreferences": projection.document, "profileEditResults": projection.profileEditResults]
        if let local { owned[OwnerHistoryAccountExport.archiveKey] = try OwnerHistoryAccountExport.sourceCarrier(local: local, scope: scope, readOwnerUID: readOwnerUID) }
        else if base.raw(OwnerHistoryAccountExport.archiveKey) != nil { throw VortxNativeError.invalidSnapshot }
        let value = try base.replacingOwned(owned).encoded()
        try Task.checkCancellation()
        return value
    }

    func localCheckpointBase(_ bytes: Data, scope: VortxAccountScope,
        providerBytes: String, providerActor: String, writeV2: Bool) throws -> OwnerHistoryAccountExport {
        guard !Thread.isMainThread else { throw Failure.mainThreadExecution }
        try Task.checkCancellation()
        let provider = try VortxNativeProviderCredentials(scope: scope.account,
            actor: providerActor, sealed: Data(providerBytes.utf8))
        let base = try OwnerHistoryAccountExport(completeAccountPlaintext: bytes)
        let complete = try OwnerHistoryRawAccountPreparation.projectingLocalProvider(account: base, provider: provider)
        _ = try complete.validatedPlaintext(writeV2: writeV2)
        try Task.checkCancellation()
        return complete
    }

    func peerCheckpointBase(_ bytes: Data, scope: VortxAccountScope,
        providerBytes: String, providerActor: String, writeV2: Bool) throws -> OwnerHistoryAccountExport {
        guard !Thread.isMainThread else { throw Failure.mainThreadExecution }
        try Task.checkCancellation()
        let provider = try VortxNativeProviderCredentials(scope: scope.account,
            actor: providerActor, sealed: Data(providerBytes.utf8))
        let base = try OwnerHistoryAccountExport(completeAccountPlaintext: bytes)
        let complete = try OwnerHistoryRawAccountPreparation.projectingPeerProvider(account: base, provider: provider)
        _ = try complete.validatedPlaintext(writeV2: writeV2)
        try Task.checkCancellation()
        return complete
    }

    /// ACK-only projection of the exact SENT complete-account plaintext. Never use it
    /// for persistence, export, a new native authority or a replacement current-state read.
    func nativePreferenceAckProjection(_ plaintext: Data) throws -> Data {
        guard !Thread.isMainThread else { throw Failure.mainThreadExecution }
        try Task.checkCancellation()
        typealias Exact = OwnerHistoryExactJSON
        let account = try Exact.Object(plaintext)
        let native = try Exact.Object(account.required("nativeSync"))
        var projectedNative = try Exact.Object(Data("{}".utf8))
        for key in ["scope", "ownerProfileId"] {
            projectedNative.set(key, try native.required(key))
        }
        var profiles = try Exact.Object(Data("{}".utf8))
        for (id, bytes) in try Exact.Object(native.required("profiles")).fields {
            let record = try Exact.Object(bytes)
            var projected = try Exact.Object(Data("{}".utf8))
            projected.set("profile", try record.required("profile"))
            if let bytes = record["fieldClocks"] {
                let clocks = try Exact.Object(bytes)
                var retained = try Exact.Object(Data("{}".utf8))
                for key in ["accent", "oled", "textScale", "deleted"] {
                    if let value = clocks[key] { retained.set(key, value) }
                }
                projected.set("fieldClocks", try retained.encoded())
            }
            profiles.set(id, try projected.encoded())
        }
        projectedNative.set("profiles", try profiles.encoded())
        if let bytes = native["accountSlots"] {
            var slots = try Exact.Object(Data("{}".utf8))
            for (id, bytes) in try Exact.Object(bytes).fields {
                let record = try Exact.Object(bytes)
                if let binding = record["activeBinding"] {
                    var slot = try Exact.Object(Data("{}".utf8))
                    slot.set("activeBinding", binding)
                    slots.set(id, try slot.encoded())
                }
            }
            projectedNative.set("accountSlots", try slots.encoded())
        }
        var result = try Exact.Object(Data("{}".utf8))
        result.set("nativeSync", try projectedNative.encoded())
        result.set("nativeHostPreferences", try account.required("nativeHostPreferences"))
        let bytes = try result.encoded()
        try Task.checkCancellation()
        return bytes
    }

    func prepare(_ input: Input) throws -> OwnerHistoryAccountExport {
        guard !Thread.isMainThread else { throw Failure.mainThreadExecution }
        try Task.checkCancellation()
        // Reconstruct the REAL typed provider only here. No secure bytes are written or
        // acknowledged; input is an immutable confirmed read, never a live authority.
        let provider = try VortxNativeProviderCredentials(scope: input.source.scope,
            actor: input.providerActor, sealed: Data(input.providerBytes.utf8))
        let complete = try OwnerHistoryRawAccountPreparation.reconcile(plaintext: input.plaintext,
            source: input.source, snapshotData: input.snapshotData,
            hostPreferencesData: input.hostPreferencesData, ownerHistoryLocalData: input.ownerHistoryLocalData,
            readOwnerUID: input.readOwnerUID, provider: provider)
        _ = try complete.validatedPlaintext(writeV2: input.writeV2)
        try Task.checkCancellation()
        return complete
    }
}
