import Foundation

/// Bounded cold parser for receipt candidates and list-query fingerprints. It reads only requested
/// playlist registers from the exact frozen upload plaintext; no full-account VortxJSON conversion occurs.
actor NativePlaylistCloudReceiptProjectionWorker {
    static let shared = NativePlaylistCloudReceiptProjectionWorker()
    enum Failure: Error { case mainThread, invalidProjection }

    func candidateProjection(plaintext: Data, owner: NativePlaylistReceiptOwner,
                             fields: [String], edits: [String: UUID]) throws -> NativePlaylistCandidateProjection {
        guard !Thread.isMainThread else { throw Failure.mainThread }
        try Task.checkCancellation()
        guard plaintext.count <= OwnerHistoryExactJSON.maximumBytes,
              fields.count <= NativePlaylistCloudReceiptLedger.maximumEntries,
              Set(fields).count == fields.count, Set(edits.keys) == Set(fields),
              fields.allSatisfy({ $0.hasPrefix(VortxNativePlaylist.v1Prefix) }) else {
            throw Failure.invalidProjection
        }
        let account = try OwnerHistoryExactJSON.Object(plaintext)
        let hostBytes = try OwnerHistoryExactJSON.Object(account.required("nativeHostPreferences"))
        let profiles = try OwnerHistoryExactJSON.Object(hostBytes.required("profiles"))
        guard let profileBytes = profiles[owner.profileKey] else { throw Failure.invalidProjection }
        let profile = try OwnerHistoryExactJSON.Object(profileBytes)
        let registers = try OwnerHistoryExactJSON.Object(profile.required("fields"))
        var selected: [String: Data] = [:]
        for field in fields {
            try Task.checkCancellation()
            guard let raw = registers[field] else { continue }
            guard raw.count <= VortxNativePlaylist.maximumRegisterBytes else { throw Failure.invalidProjection }
            let value = try JSONDecoder().decode(VortxJSON.self, from: raw)
            guard let canonical = VortxNativePlaylist.canonicalReceiptRegister(value),
                  try OwnerHistoryExactJSON.canonical(raw) == canonical else { throw Failure.invalidProjection }
            selected[field] = canonical
        }
        try Task.checkCancellation()
        return .init(owner: owner, registers: selected, edits: edits.filter { selected[$0.key] != nil })
    }

    func fingerprint(_ register: VortxJSON) throws -> NativePlaylistRegisterFingerprint? {
        guard !Thread.isMainThread else { throw Failure.mainThread }
        try Task.checkCancellation()
        guard let canonical = VortxNativePlaylist.canonicalReceiptRegister(register) else { return nil }
        let result = NativePlaylistRegisterFingerprint(canonicalRegister: canonical)
        try Task.checkCancellation()
        return result
    }
}
