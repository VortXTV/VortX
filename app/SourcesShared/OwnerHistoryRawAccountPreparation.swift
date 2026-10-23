import Foundation

/// Read-only reconciliation for an ALREADY accepted raw native source. This is not a peer
/// merger, an authority, a seed, or an encoder for the entire account through VortxJSON.
enum OwnerHistoryRawAccountPreparation {
    typealias Exact = OwnerHistoryExactJSON
    enum Failure: Error, Equatable {
        case invalidEnvelope, incompatiblePeerBase, providerPending, providerReconciliationRequired
    }

    static func envelope(_ response: Data) throws -> (document: String, version: Int) {
        let object = try Exact.Object(response)
        guard Set(object.fields.keys) == ["document", "version"] else { throw Failure.invalidEnvelope }
        let document = try object.text("document")
        let versionBytes = try object.required("version")
        guard !document.isEmpty, document.utf8.count <= OwnerHistoryAccountExport.maximumSealedBytes,
              !versionBytes.isEmpty, versionBytes.allSatisfy({ (48...57).contains($0) }),
              let version = Int(String(decoding: versionBytes, as: UTF8.self)),
              version <= 9_007_199_254_740_991,
              Data(String(version).utf8) == versionBytes else { throw Failure.invalidEnvelope }
        return (document, version)
    }

    /// Until the separate typed raw-peer merge is available, every native/host/source base
    /// must ALREADY agree. A different authenticated peer is a real hold, not permission to
    /// overwrite it with this device's state. All unrelated account and apiKeys slices survive.
    static func reconcile(plaintext: Data, source: VortxNativeOwnerHistorySource.Capture,
        snapshotData: Data, hostPreferencesData: Data, ownerHistoryLocalData: Data?, readOwnerUID: String,
        provider: VortxNativeProviderCredentials) throws -> OwnerHistoryAccountExport {
        guard source.matches(snapshotData: snapshotData) else { throw VortxNativeError.superseded }
        let scope = VortxAccountScope(account: source.scope, ownerProfileID: source.ownerProfileID.uuidString)
        let account = try OwnerHistoryAccountExport(completeAccountPlaintext: plaintext)
        let host = try OwnerHistoryAccountExport.hostProjection(hostPreferencesData, scope: scope)
        guard try same(account.raw("nativeSync"), source.nativeDocumentBytes),
              try same(account.raw("nativeHostPreferences"), host.document),
              try same(account.raw("profileEditResults"), host.profileEditResults) else {
            throw Failure.incompatiblePeerBase
        }
        let localSources = try ownerHistoryLocalData.map { try OwnerHistoryAccountExport.sourceCarrier(local: $0, scope: scope, readOwnerUID: readOwnerUID) }
        guard try same(account.raw(OwnerHistoryAccountExport.archiveKey), localSources) else {
            throw Failure.incompatiblePeerBase
        }
        return try projectingLocalProvider(account: account, provider: provider)
    }

    /// A SAME-envelope accepted base, not a stale cloud comparison. This reuses the exact
    /// existing provider contradiction/hydration/tombstone policy for local transactions.
    static func projectingLocalProvider(account: OwnerHistoryAccountExport,
        provider: VortxNativeProviderCredentials) throws -> OwnerHistoryAccountExport {
        try projectingProvider(account: account, provider: provider, acceptsPeerJoin: false)
    }

    /// Authenticated peer preparation uses the real register merge without prematurely
    /// persisting or acknowledging remote credentials. The original secure-byte witness
    /// still encloses the native commit; Manager then uses its existing durable provider
    /// apply route. Local actions deliberately retain the already-joined requirement.
    static func projectingPeerProvider(account: OwnerHistoryAccountExport,
        provider: VortxNativeProviderCredentials) throws -> OwnerHistoryAccountExport {
        try projectingProvider(account: account, provider: provider, acceptsPeerJoin: true)
    }

    private static func projectingProvider(account: OwnerHistoryAccountExport,
        provider: VortxNativeProviderCredentials, acceptsPeerJoin: Bool) throws -> OwnerHistoryAccountExport {
        guard !provider.hasPreparedMutation else { throw Failure.providerPending }

        var keys = try Exact.Object(account.raw("apiKeys") ?? Data("{}".utf8))
        var metadata = try Exact.Object(keys["metadata"] ?? Data("{}".utf8))
        var joined = provider
        if let rawProvider = account.raw("nativeProviderCredentials") {
            // Only this closed, credential-specific schema is decoded. Never decode the
            // complete account/native/source tree or arbitrary apiKeys siblings into Double.
            let wire = try JSONDecoder().decode(VortxJSON.self, from: rawProvider)
            try joined.merge(wire) // actual strict allowlist, register/group/clock/actor checks
            let remote = try wire.decode(VortxNativeProviderCredentials.Document.self)
            for (key, event) in remote.fields {
                let aliases = [keys[key], metadataKeys.contains(key) ? metadata[key] : nil].compactMap { $0 }
                if case .string(let value) = event.value {
                    guard !aliases.isEmpty, try aliases.allSatisfy({
                        try Exact.sameText(JSONDecoder().decode(String.self, from: $0), value)
                    }) else { throw Failure.providerReconciliationRequired }
                } else if !aliases.isEmpty { throw Failure.providerReconciliationRequired }
            }
        }
        // A newer peer credential must first take the existing secure hydration route.
        // This pure producer never acknowledges/persists credentials or invents an edit.
        if !acceptsPeerJoin {
            guard try XperienceExactEvidence.json(joined.document, provider.document) else {
                throw Failure.providerReconciliationRequired
            }
        }
        for (key, event) in joined.local.document.fields {
            if case .string(let value) = event.value {
                keys.set(key, try Exact.string(value))
                if metadataKeys.contains(key) { metadata.set(key, try Exact.string(value)) }
            } else {
                keys.remove(key)
                if metadataKeys.contains(key) { metadata.remove(key) }
            }
        }
        if keys["metadata"] != nil || !metadata.fields.isEmpty { keys.set("metadata", try metadata.encoded()) }
        return try account.replacingOwned([
            "nativeProviderCredentials": JSONEncoder().encode(joined.local.document),
            "apiKeys": keys.encoded()
        ])
    }

    private static let metadataKeys: Set<String> = ["tmdb", "mdblist", "fanart"]
    private static func same(_ left: Data?, _ right: Data?) throws -> Bool {
        switch (left, right) {
        case (nil, nil): true
        case (.some(let left), .some(let right)): try Exact.canonical(left) == Exact.canonical(right)
        default: false
        }
    }
}
