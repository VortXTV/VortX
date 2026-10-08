import Foundation

/// Device-local, source-bound migration journal. These bytes never enter nativeSync or cloud
/// preferences. Historical evidence and pending sources are immutable, including after retries.
enum VortxNativeWatchedArchive {
    static let evidenceKey = "nativeWatchedMigrationEvidence"
    static let pendingKey = "nativeWatchedMigrationPending"
    enum Failure: LocalizedError, Equatable {
        case pending, malformed
        var errorDescription: String? {
            switch self {
            case .pending: return "Watched history is preserved, but episode metadata from an original addon is unavailable. Retry watched-history migration before completing this account connection."
            case .malformed: return "The saved watched-history migration evidence could not be verified. No history was replaced."
            }
        }
    }
    static func pendingProfileIDs(_ archive: Data?) throws -> [UUID] {
        func identity(_ bytes: Data) throws -> VortxJSON {
            let value = try JSONDecoder().decode(VortxJSON.self, from: bytes)
            return .array([value["accountId"] ?? .null, value["ownerProfileId"] ?? .null,
                value["profileId"] ?? .null, value["verifiedStreamingUid"] ?? .null,
                value["sourceDocumentSha256"] ?? .null, value["row"] ?? .null])
        }
        let completed = try entries(archive, key: evidenceKey).map(identity)
        var ids = Set<UUID>()
        for bytes in try entries(archive, key: pendingKey) where !completed.contains(try identity(bytes)) {
            let value = try JSONDecoder().decode(VortxJSON.self, from: bytes)
            guard case .string(let id) = value["profileId"], let profile = UUID(uuidString: id) else { throw Failure.malformed }
            ids.insert(profile)
        }
        return ids.sorted { $0.uuidString < $1.uuidString }
    }

    static func entries(_ archive: Data?, key: String) throws -> [Data] {
        guard let archive else { return [] }
        try VortxNativeBootstrapArchive.validate(archive)
        let value = try JSONDecoder().decode(VortxJSON.self, from: archive)
        guard let field = value["hostDocument"]?[key] else { return [] }
        guard let entries = field.array, entries.count <= 10_000 else { throw Failure.malformed }
        return try entries.map {
            guard case .string(let raw) = $0, let bytes = Data(base64Encoded: raw),
                  bytes.base64EncodedString() == raw else { throw Failure.malformed }
            return bytes
        }
    }
    static func validate(_ archive: Data?, scope: VortxAccountScope) throws {
        guard let owner = UUID(uuidString: scope.ownerProfileID) else { throw Failure.malformed }
        for bytes in try entries(archive, key: evidenceKey) {
            try VortxLegacyWatchedMigration.validateArchivedEvidence(bytes, accountID: scope.account, ownerProfileID: owner)
        }
        for bytes in try entries(archive, key: pendingKey) {
            try VortxLegacyWatchedMigration.validateArchivedPending(bytes, accountID: scope.account, ownerProfileID: owner)
        }
    }
    static func retaining(_ archive: Data, prior: Data? = nil, evidence: [Data] = [], pending: [Data] = [],
                          scope: VortxAccountScope) throws -> Data {
        try validate(prior, scope: scope)
        try validate(archive, scope: scope)
        var root = try JSONDecoder().decode(VortxJSON.self, from: archive)["hostDocument"]?.decode([String: VortxJSON].self) ?? [:]
        for (key, added) in [(evidenceKey, evidence), (pendingKey, pending)] {
            let combined = try entries(prior, key: key) + entries(archive, key: key) + added
            let unique = Set(combined).sorted { $0.lexicographicallyPrecedes($1) }
            guard unique.count <= 10_000, unique.reduce(0, { $0 + $1.count }) <= 32 * 1_024 * 1_024 else { throw Failure.malformed }
            if !unique.isEmpty { root[key] = .array(unique.map { .string($0.base64EncodedString()) }) }
        }
        let result = try VortxNativeBootstrapArchive.encode(document: JSONEncoder().encode(VortxJSON.object(root)))
        try validate(result, scope: scope)
        return result
    }
}
