import Foundation
import CryptoKit

enum VortxNativeUnattributedOverlayArchive {
    static let key = "ownAccountOverlayQuarantine"
    private static let pendingOrigin = "first_import_missing_credential"
    /// Schema 2 records retain an already-made isolation decision, never account attribution.
    /// Ordinary schema 1 recovery records cannot authorize this first-import path.
    struct FirstImportRecovery: Sendable {
        let pending: [String: VortxJSON]
        let quarantinedProfiles: Set<UUID>
    }
    static func firstImportRecovery(_ archive: Data?, scope: VortxAccountScope) throws -> FirstImportRecovery {
        guard let archive else { return .init(pending: [:], quarantinedProfiles: []) }
        try VortxNativeBootstrapArchive.validate(archive)
        let root = try JSONDecoder().decode(VortxJSON.self, from: archive)
        guard let validated = try merge(nil, root["hostDocument"]?[key], scope: scope),
              case .object(let records) = validated else { return .init(pending: [:], quarantinedProfiles: []) }
        var pending: [String: VortxJSON] = [:], profiles = Set<UUID>()
        for identity in records.keys.sorted() {
            let record = records[identity]!
            guard case .string(let id) = record["profileId"], let profile = UUID(uuidString: id) else { throw VortxNativeError.invalidSnapshot }
            profiles.insert(profile)
            if record["schemaVersion"] == .integer(2), pending[id] == nil {
                pending[id] = .object(["profileOverlayBase64": record["profileOverlayBase64"]!, "reason": .string("missing_witness")])
            }
        }
        return .init(pending: pending, quarantinedProfiles: profiles)
    }
    private static func overlay(document: VortxJSON, profileID: UUID) throws -> Data {
        func selected(_ value: VortxJSON?) throws -> VortxJSON? {
            guard let value else { return nil }
            guard case .object(let fields) = value else { throw VortxNativeError.invalidSnapshot }
            let matches = fields.filter { UUID(uuidString: $0.key) == profileID }
            guard matches.count <= 1, matches.isEmpty || matches.first?.key == profileID.uuidString else { throw VortxNativeError.invalidSnapshot }
            return matches.first?.value
        }
        var result: [String: VortxJSON] = [:]
        if let bucket = try selected(document["vortx"]?["byProfile"]) {
            guard case .object = bucket else { throw VortxNativeError.invalidSnapshot }
            result["vortx"] = .object(["byProfile": .object([profileID.uuidString: bucket])])
        }
        if let removed = try selected(document["webProgress"]?["removed"]?["byProfile"]) {
            guard case .array = removed else { throw VortxNativeError.invalidSnapshot }
            result["webProgress"] = .object(["removed": .object(["byProfile": .object([profileID.uuidString: removed])])])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(VortxJSON.object(result))
    }

    /// Append-only recovery evidence. No UID or independent-source digest is allowed here.
    /// This journal is deliberately never an input to pendingOverlay or account authentication.
    static func merge(_ prior: VortxJSON?, _ incoming: VortxJSON?,
                                         scope: VortxAccountScope, state: VortxJSON? = nil) throws -> VortxJSON? {
        var merged: [String: VortxJSON] = [:]
        for candidate in [prior, incoming].compactMap({ $0 }) {
            guard case .object(let records) = candidate, records.count <= 10_000 else { throw VortxNativeError.invalidSnapshot }
            for (key, record) in records {
                let originalMissing = record["schemaVersion"] == .integer(2) && record["origin"] == .string(pendingOrigin)
                let expectedFields: Set<String> = ["schemaVersion", "scope", "ownerProfileId", "profileId", "rootDocumentSha256", "profileOverlaySha256", "profileOverlayBase64"]
                guard case .object(let fields) = record,
                      Set(fields.keys) == (originalMissing ? expectedFields.union(["origin"]) : expectedFields),
                      originalMissing || record["schemaVersion"] == .integer(1), record["scope"] == .string(scope.account),
                      record["ownerProfileId"] == .string(scope.ownerProfileID),
                      case .string(let id) = record["profileId"], let profile = UUID(uuidString: id), profile.uuidString == id,
                      id != scope.ownerProfileID,
                      case .string(let rootHash) = record["rootDocumentSha256"], rootHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      case .string(let overlayHash) = record["profileOverlaySha256"],
                      case .string(let raw) = record["profileOverlayBase64"], let bytes = Data(base64Encoded: raw), bytes.base64EncodedString() == raw,
                      try VortxProfileOverlayWitness.digest(json: bytes) == overlayHash,
                      let value = try? JSONDecoder().decode(VortxJSON.self, from: bytes),
                      try overlay(document: value, profileID: profile) == bytes else { throw VortxNativeError.invalidSnapshot }
                if let state {
                    guard state["roster"]?["profiles"]?[id]?["owner"] == .bool(false) else { throw VortxNativeError.invalidSnapshot }
                }
                let identity = VortxJSON.array([.string(scope.account), .string(scope.ownerProfileID), .string(id), .string(rootHash), .string(overlayHash)]
                    + (originalMissing ? [.string(pendingOrigin)] : []))
                let digest = SHA256.hash(data: try JSONEncoder().encode(identity)).map { String(format: "%02x", $0) }.joined()
                guard key == digest, merged[key] == nil || merged[key] == record else { throw VortxNativeError.invalidSnapshot }
                merged[key] = record
            }
        }
        guard merged.count <= 10_000 else { throw VortxNativeError.invalidSnapshot }
        guard !merged.isEmpty else { return nil }
        let result = VortxJSON.object(merged)
        guard try JSONEncoder().encode(result).count <= 32 * 1_024 * 1_024 else { throw VortxNativeError.invalidSnapshot }
        return result
    }
    static func retaining(_ archive: Data, prior: Data?, document: Data,
                          profileIDs: Set<UUID>, pendingOriginProfileIDs: Set<UUID> = [], scope: VortxAccountScope) throws -> Data {
        guard pendingOriginProfileIDs.isSubset(of: profileIDs) else { throw VortxNativeError.invalidSnapshot }
        let archive = try VortxNativeBootstrapArchive.mergingRecoveryEnvelope(archive, prior: prior)
        try VortxNativeBootstrapArchive.validate(archive)
        if let prior { try VortxNativeBootstrapArchive.validate(prior) }
        var host = try JSONDecoder().decode(VortxJSON.self, from: archive)["hostDocument"]!.decode([String: VortxJSON].self)
        let old = try prior.map { try JSONDecoder().decode(VortxJSON.self, from: $0)["hostDocument"]?[key] } ?? nil
        var added: [String: VortxJSON] = [:]
        let rootHash = SHA256.hash(data: document).map { String(format: "%02x", $0) }.joined()
        let root = try JSONDecoder().decode(VortxJSON.self, from: document)
        for profile in profileIDs {
            let bytes = try overlay(document: root, profileID: profile)
            let overlayHash = try VortxProfileOverlayWitness.digest(json: bytes)
            let originalMissing = pendingOriginProfileIDs.contains(profile)
            let identity = VortxJSON.array([.string(scope.account), .string(scope.ownerProfileID), .string(profile.uuidString), .string(rootHash), .string(overlayHash)]
                + (originalMissing ? [.string(pendingOrigin)] : []))
            let key = SHA256.hash(data: try JSONEncoder().encode(identity)).map { String(format: "%02x", $0) }.joined()
            var record: [String: VortxJSON] = ["schemaVersion": .integer(originalMissing ? 2 : 1), "scope": .string(scope.account),
                "ownerProfileId": .string(scope.ownerProfileID), "profileId": .string(profile.uuidString),
                "rootDocumentSha256": .string(rootHash), "profileOverlaySha256": .string(overlayHash),
                "profileOverlayBase64": .string(bytes.base64EncodedString())]
            if originalMissing { record["origin"] = .string(pendingOrigin) }
            added[key] = .object(record)
        }
        let retained = try merge(old, host[key], scope: scope)
        host[key] = try merge(retained, .object(added), scope: scope)
        return try VortxNativeBootstrapArchive.replacingHostDocument(in: archive,
            with: JSONEncoder().encode(VortxJSON.object(host)))
    }
}

/// Device-local, source-bound migration journal. These bytes never enter nativeSync or cloud
/// preferences. Historical evidence and pending sources are immutable, including after retries.
enum VortxNativeWatchedArchive {
    static let evidenceKey = "nativeWatchedMigrationEvidence"
    static let pendingKey = "nativeWatchedMigrationPending"
    static let sourcesKey = "nativeWatchedMigrationSources"
    private static let maximumJournalBytes = 32 * 1_024 * 1_024
    // Compatibility arrays and one streaming batch have a work budget. A pooled journal may
    // contain more total work: production consumers must process it incrementally, never expand
    // it into one aggregate array. The separate encoded storage cap remains unchanged.
    private static let maximumExpandedJournalBytes = 96 * 1_024 * 1_024
    private static let maximumEntries = 10_000

    /// In-process proof of full strict replay, not publication authority. Only this
    /// file can construct it; no Codable/memberwise initializer accepts caller bytes.
    /// It retains the exact immutable envelope, including unknown/source/pending fields.
    struct ValidatedDraft: Sendable {
        private let archive: Data
        private let scopeBytes: Data
        fileprivate init(archive: Data, scope: VortxAccountScope) {
            self.archive = archive; scopeBytes = scope.authenticatedData
        }
        func bytes(for scope: VortxAccountScope) throws -> Data {
            try scope.validate()
            // Do not use String's Unicode-canonical equality for an exact AAD scope.
            guard scope.authenticatedData == scopeBytes else { throw VortxNativeError.invalidSnapshot }
            return archive
        }
    }

    /// Version-1 inline receipts remain readable. Version-2 entries omit only the repeated
    /// source field, whose exact bytes are held once by SHA-256. The migration API still sees
    /// the original version-1 bytes and performs its complete source/UID/metadata validation.
    /// Noncanonical older receipt spellings remain inline rather than being rewritten.
    /// Every receipt/source iteration checks the lease and suspends. A single strict JSON
    /// parse/hash/credential inspection is still indivisible; this is not a latency bound.
    fileprivate struct Cooperation: Sendable {
        let isCurrent: @Sendable () -> Bool
        let checkpoint: (@Sendable () async throws -> Void)?
        func check() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw LegacyWatchedBitfieldMigrationEvidence.Failure.admissionRevoked }
        }
        func boundary() async throws {
            try check()
            await Task.yield()
            if let checkpoint { try await checkpoint() }
            try check()
        }
    }

    fileprivate struct Journal: Sendable {
        var host: [String: VortxJSON] = [:]
        var sources: [String: String] = [:]
        var expandedByteCount = 0

        init(_ archive: Data?) throws {
            guard let archive else { return }
            try VortxNativeBootstrapArchive.validate(archive)
            host = try JSONDecoder().decode(VortxJSON.self, from: archive)["hostDocument"]!.decode([String: VortxJSON].self)
            if let field = host[sourcesKey] {
                let journal = host.filter { [evidenceKey, pendingKey, sourcesKey].contains($0.key) }
                guard try JSONEncoder().encode(VortxJSON.object(journal)).count <= maximumJournalBytes else { throw Failure.malformed }
                guard case .object(let values) = field, values.count <= 2 * maximumEntries else { throw Failure.malformed }
                for (digest, value) in values {
                    try Task.checkCancellation()
                    guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                          case .string(let raw) = value, let bytes = Data(base64Encoded: raw),
                          bytes.count <= maximumJournalBytes, bytes.base64EncodedString() == raw,
                          sha256(bytes) == digest else { throw Failure.malformed }
                    sources[digest] = raw
                }
            }
            var used = Set<String>()
            for key in [evidenceKey, pendingKey] {
                for entry in try records(key) {
                    try Task.checkCancellation()
                    if case .object(let fields) = entry {
                        guard Set(fields.keys) == ["schemaVersion", "sourceDocumentSha256", "receiptBase64"],
                              fields["schemaVersion"] == .integer(2),
                              case .string(let digest) = fields["sourceDocumentSha256"], sources[digest] != nil,
                              case .string = fields["receiptBase64"] else { throw Failure.malformed }
                        used.insert(digest)
                    } else if case .string = entry {} else { throw Failure.malformed }
                }
            }
            // Unreferenced sources are not silently removed on the next retention pass.
            guard used == Set(sources.keys) else { throw Failure.malformed }
            var total = 0
            for key in [evidenceKey, pendingKey] {
                for entry in try records(key) {
                    try Task.checkCancellation()
                    let size = try expandedSize(entry)
                    let (sum, overflow) = total.addingReportingOverflow(size)
                    guard !overflow else { throw Failure.processingLimit }
                    total = sum
                }
            }
            // Old valid writers allowed 32 MiB decoded per array. Preserve those reads, but
            // do not accept an unbounded new inline-only input in the name of compatibility.
            guard host[sourcesKey] != nil || total <= maximumExpandedJournalBytes else { throw Failure.processingLimit }
            expandedByteCount = total
        }

        private init() {}
        static func load(_ archive: Data?, cooperation: Cooperation, on worker: isolated RecoveryWorker) async throws -> Journal {
            var result = Journal()
            try await cooperation.boundary()
            guard let archive else { return result }
            try VortxNativeBootstrapArchive.validate(archive)
            result.host = try JSONDecoder().decode(VortxJSON.self, from: archive)["hostDocument"]!.decode([String: VortxJSON].self)
            if let field = result.host[sourcesKey] {
                let journal = result.host.filter { [evidenceKey, pendingKey, sourcesKey].contains($0.key) }
                guard try JSONEncoder().encode(VortxJSON.object(journal)).count <= maximumJournalBytes else { throw Failure.malformed }
                guard case .object(let values) = field, values.count <= 2 * maximumEntries else { throw Failure.malformed }
                for (digest, value) in values {
                    try Task.checkCancellation()
                    try await cooperation.boundary()
                    guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                          case .string(let raw) = value, let bytes = Data(base64Encoded: raw),
                          bytes.count <= maximumJournalBytes, bytes.base64EncodedString() == raw,
                          sha256(bytes) == digest else { throw Failure.malformed }
                    result.sources[digest] = raw
                }
            }
            var used = Set<String>()
            for key in [evidenceKey, pendingKey] {
                for entry in try result.records(key) {
                    try await cooperation.boundary()
                    if case .object(let fields) = entry {
                        guard Set(fields.keys) == ["schemaVersion", "sourceDocumentSha256", "receiptBase64"],
                              fields["schemaVersion"] == .integer(2),
                              case .string(let digest) = fields["sourceDocumentSha256"], result.sources[digest] != nil,
                              case .string = fields["receiptBase64"] else { throw Failure.malformed }
                        used.insert(digest)
                    } else if case .string = entry {} else { throw Failure.malformed }
                }
            }
            // Unreferenced sources are not silently removed on the next retention pass.
            guard used == Set(result.sources.keys) else { throw Failure.malformed }
            var total = 0
            for key in [evidenceKey, pendingKey] {
                for entry in try result.records(key) {
                    try await cooperation.boundary()
                    let size = try result.expandedSize(entry)
                    let (sum, overflow) = total.addingReportingOverflow(size)
                    guard !overflow else { throw Failure.processingLimit }
                    total = sum
                }
            }
            // Old valid writers allowed 32 MiB decoded per array. Preserve those reads, but
            // do not accept an unbounded new inline-only input in the name of compatibility.
            guard result.host[sourcesKey] != nil || total <= maximumExpandedJournalBytes else { throw Failure.processingLimit }
            result.expandedByteCount = total
            try await cooperation.boundary()
            return result
        }

        func records(_ key: String) throws -> [VortxJSON] {
            guard [evidenceKey, pendingKey].contains(key) else { throw Failure.malformed }
            guard let value = host[key] else { return [] }
            guard let records = value.array, records.count <= maximumEntries else { throw Failure.malformed }
            return records
        }

        func fields(_ entry: VortxJSON) throws -> [String: Any] {
            let raw: String
            switch entry {
            case .string(let inline): raw = inline
            case .object(let compact):
                guard case .string(let encoded) = compact["receiptBase64"] else { throw Failure.malformed }
                raw = encoded
            default: throw Failure.malformed
            }
            guard let bytes = Data(base64Encoded: raw), bytes.base64EncodedString() == raw else { throw Failure.malformed }
            let fields = try VortxProfileOverlayWitness.decodeObject(json: bytes)
            if case .object(let compact) = entry {
                guard fields["sourceDocumentBase64"] == nil,
                      let digest = fields["sourceDocumentSha256"] as? String,
                      compact["sourceDocumentSha256"] == .string(digest), sources[digest] != nil else { throw Failure.malformed }
            }
            return fields
        }

        func expandedSize(_ entry: VortxJSON) throws -> Int {
            if case .string(let raw) = entry {
                guard let bytes = Data(base64Encoded: raw), bytes.base64EncodedString() == raw else { throw Failure.malformed }
                return bytes.count
            }
            let object = try fields(entry)
            guard let digest = object["sourceDocumentSha256"] as? String, let source = sources[digest] else { throw Failure.malformed }
            // Base64 needs no JSON escaping with withoutEscapingSlashes. The object is nonempty
            // (it contains the source digest), so adding one field adds exactly one comma.
            let header = try canonical(object).count
            let overhead = Data(",\"sourceDocumentBase64\":\"\"".utf8).count
            let (withSource, overflow) = header.addingReportingOverflow(source.utf8.count)
            let (total, overheadOverflow) = withSource.addingReportingOverflow(overhead)
            guard !overflow, !overheadOverflow else { throw Failure.processingLimit }
            return total
        }

        func expanded(_ entry: VortxJSON) throws -> Data {
            if case .string(let inline) = entry {
                guard let bytes = Data(base64Encoded: inline), bytes.base64EncodedString() == inline else { throw Failure.malformed }
                return bytes
            }
            var object = try fields(entry)
            guard let digest = object["sourceDocumentSha256"] as? String, let source = sources[digest] else { throw Failure.malformed }
            object["sourceDocumentBase64"] = source
            return try canonical(object)
        }
    }

    /// One retry invocation's immutable preflight, not a cache or publication lease.
    /// The only initializer performs the full validator; no raw Journal can mint it.
    fileprivate struct ValidatedJournalSnapshot: Sendable {
        let archive: Data
        let scope: VortxAccountScope
        let journal: Journal
        init(validating archive: Data, scope: VortxAccountScope,
             isCurrent: @escaping @Sendable () -> Bool,
             checkpoint: (@Sendable () async throws -> Void)?) async throws {
            try scope.validate()
            let worker = RecoveryWorker(scope: scope, isCurrent: isCurrent, checkpoint: checkpoint)
            let journal = try await worker.validatedJournal(archive)
            try Task.checkCancellation()
            guard isCurrent() else { throw LegacyWatchedBitfieldMigrationEvidence.Failure.admissionRevoked }
            self.archive = archive; self.scope = scope; self.journal = journal
        }
    }

    private static func canonical(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func compact(_ bytes: Data, sources: inout [String: String]) throws -> VortxJSON {
        var object = try VortxProfileOverlayWitness.decodeObject(json: bytes)
        guard let raw = object["sourceDocumentBase64"] as? String, let source = Data(base64Encoded: raw),
              source.base64EncodedString() == raw, let digest = object["sourceDocumentSha256"] as? String,
              sha256(source) == digest else { throw Failure.malformed }
        guard try canonical(object) == bytes else { return .string(bytes.base64EncodedString()) }
        guard sources[digest] == nil || sources[digest] == raw else { throw Failure.malformed }
        sources[digest] = raw
        object.removeValue(forKey: "sourceDocumentBase64")
        return .object(["schemaVersion": .integer(2), "sourceDocumentSha256": .string(digest),
                        "receiptBase64": .string(try canonical(object).base64EncodedString())])
    }
    /// Resolve historical pending snapshots in their original scope, even if the current cloud
    /// document changed or removed the row. No validated import rows escape this operation.
    /// The caller commits the returned immutable union under its captured source authority.
    static func retryHistorical(_ archive: Data?, scope: VortxAccountScope,
                                isCurrent: @escaping @Sendable () -> Bool,
                                fetch: LegacyWatchedBitfieldMigrationEvidence.MetadataFetcher,
                                persist: (@Sendable (Data) async throws -> Void)? = nil,
                                checkpoint: (@Sendable () async throws -> Void)? = nil) async throws -> Data? {
        let cooperation = Cooperation(isCurrent: isCurrent, checkpoint: checkpoint)
        try await cooperation.boundary()
        guard let archive else { return nil }
        let worker = RecoveryWorker(scope: scope, isCurrent: isCurrent, checkpoint: checkpoint)
        let snapshot = try await ValidatedJournalSnapshot(validating: archive, scope: scope,
            isCurrent: isCurrent, checkpoint: checkpoint)
        let journal = snapshot.journal
        let pending = try journal.records(pendingKey)
        guard !pending.isEmpty, let owner = UUID(uuidString: scope.ownerProfileID) else { return archive }
        let indexed = try await worker.index(journal)
        var stream: Stream?
        var seen = Set<Data>()
        for record in pending {
            try await cooperation.boundary()
            let bytes = try journal.expanded(record)
            let tuple = try identity(journal.fields(record))
            // Multiple pending reasons/spellings are immutable observations of the same
            // source tuple, not permission for multiple provider captures in one retry.
            guard seen.insert(tuple).inserted else { continue }
            let matching = indexed[tuple] ?? []
            guard matching.count <= 1 else { throw Failure.malformed }
            // Only one pending tuple and its matching evidence are expanded at a time. Each
            // captured result is compacted immediately; old pending bytes stay in the journal.
            let retried = try await VortxLegacyWatchedMigration.retryArchivedPending([bytes],
                accountID: scope.account, ownerProfileID: owner,
                archivedEvidence: matching.map(journal.expanded), isCurrent: isCurrent, fetch: fetch)
            if matching.isEmpty {
                for receipt in retried.archives {
                    // Old pending observations may already be resolved, or still be
                    // unavailable. Do not recompact history until an actual addition.
                    let destination: Stream
                    if let stream { destination = stream }
                    else {
                        destination = try await worker.stream(snapshot: snapshot, persist: persist)
                        stream = destination
                    }
                    try await destination.append(receipt, pending: false)
                }
            }
        }
        try await cooperation.boundary()
        guard let stream else { return archive }
        return try await stream.finish()
    }
    enum Failure: LocalizedError, Equatable {
        case pending, malformed, processingLimit
        var errorDescription: String? {
            switch self {
            case .pending: return "Watched history is preserved, but episode metadata from an original addon is unavailable. Retry watched-history migration before completing this account connection."
            case .malformed: return "The saved watched-history migration evidence could not be verified. No history was replaced."
            case .processingLimit: return "Watched-history recovery exceeds this version's processing limit. Your original history is preserved. Keep this account data and contact support or update the app before trying recovery again."
            }
        }
    }
    private static func identity(_ value: [String: Any]) throws -> Data {
        var fields = Dictionary(uniqueKeysWithValues: ["accountId", "ownerProfileId", "profileId",
            "verifiedStreamingUid", "sourceDocumentSha256", "row"].map { ($0, value[$0] ?? NSNull()) })
        for key in ["ownerProfileId", "profileId"] {
            if let raw = fields[key] as? String, let id = UUID(uuidString: raw) { fields[key] = id.uuidString }
        }
        return try canonical(fields)
    }
    private static func evidenceIndex(_ journal: Journal) throws -> [Data: [VortxJSON]] {
        var index: [Data: [VortxJSON]] = [:]
        for entry in try journal.records(evidenceKey) {
            index[try identity(journal.fields(entry)), default: []].append(entry)
        }
        return index
    }
    /// Current preparation only expands the receipt for its exact current tuple. Historical
    /// evidence remains in the sealed journal and cannot inflate an eager input array.
    static func evidenceLookup(_ archive: Data?, scope: VortxAccountScope) throws -> VortxLegacyWatchedMigration.ArchivedEvidenceLookup {
        try validate(archive, scope: scope)
        let journal = try Journal(archive)
        let index = try evidenceIndex(journal)
        return { requested, digest, locator in
            guard Data(requested.accountID.utf8) == Data(scope.account.utf8),
                  requested.ownerProfileID == UUID(uuidString: scope.ownerProfileID) else { throw Failure.malformed }
            let key = try identity(["accountId": requested.accountID, "ownerProfileId": requested.ownerProfileID.uuidString,
                "profileId": requested.profileID.uuidString, "verifiedStreamingUid": requested.verifiedStreamingUID as Any? ?? NSNull(),
                "sourceDocumentSha256": digest, "row": VortxLegacyWatchedMigration.encodeLocator(locator)])
            let matching = index[key] ?? []
            guard matching.count <= 1 else { throw Failure.malformed }
            return try matching.map(journal.expanded)
        }
    }
    static func pendingProfileIDs(_ archive: Data?) throws -> [UUID] {
        let journal = try Journal(archive)
        // A forged/malformed evidence header must not hide a pending row in presentation.
        // Scope-aware ingress validates the expected account separately; this display-only
        // helper still requires all entries to agree on one valid authenticated tuple.
        let records = try journal.records(evidenceKey) + journal.records(pendingKey)
        if let first = records.first {
            let fields = try journal.fields(first)
            guard let account = fields["accountId"] as? String,
                  let owner = fields["ownerProfileId"] as? String else { throw Failure.malformed }
            try validate(archive, scope: .init(account: account, ownerProfileID: owner))
        }
        let completed = try Set(evidenceIndex(journal).filter { $0.value.count == 1 }.keys)
        var ids = Set<UUID>()
        for entry in try journal.records(pendingKey) {
            let value = try journal.fields(entry)
            guard !completed.contains(try identity(value)) else { continue }
            guard let id = value["profileId"] as? String, let profile = UUID(uuidString: id) else { throw Failure.malformed }
            ids.insert(profile)
        }
        return ids.sorted { $0.uuidString < $1.uuidString }
    }

    static func entries(_ archive: Data?, key: String) throws -> [Data] {
        let journal = try Journal(archive)
        guard journal.expandedByteCount <= maximumExpandedJournalBytes else { throw Failure.processingLimit }
        return try journal.records(key).map(journal.expanded)
    }
    static func validate(_ archive: Data?, scope: VortxAccountScope) throws {
        guard let owner = UUID(uuidString: scope.ownerProfileID) else { throw Failure.malformed }
        let journal = try Journal(archive)
        // Expand one receipt at a time during checkpoint validation. A compact on-disk journal
        // must not require allocating its entire source-per-row representation just to open it.
        for entry in try journal.records(evidenceKey) {
            try Task.checkCancellation()
            try VortxLegacyWatchedMigration.validateArchivedEvidence(journal.expanded(entry), accountID: scope.account, ownerProfileID: owner)
        }
        for entry in try journal.records(pendingKey) {
            try Task.checkCancellation()
            try VortxLegacyWatchedMigration.validateArchivedPending(journal.expanded(entry), accountID: scope.account, ownerProfileID: owner)
        }
    }
    static func retaining(_ archive: Data, prior: Data? = nil, evidence: [Data] = [], pending: [Data] = [],
                          scope: VortxAccountScope) throws -> Data {
        let archive = try VortxNativeBootstrapArchive.mergingRecoveryEnvelope(archive, prior: prior)
        try validate(prior, scope: scope)
        try validate(archive, scope: scope)
        let journals = try [Journal(prior), Journal(archive)]
        var root = journals[1].host
        var sources: [String: String] = [:]
        for (key, added) in [(evidenceKey, evidence), (pendingKey, pending)] {
            var unique: [String: VortxJSON] = [:]
            func retain(_ bytes: Data) throws {
                let digest = sha256(bytes)
                let record = try compact(bytes, sources: &sources)
                guard unique[digest] == nil || unique[digest] == record else { throw Failure.malformed }
                unique[digest] = record
                guard unique.count <= maximumEntries else { throw Failure.malformed }
            }
            for journal in journals {
                for entry in try journal.records(key) { try retain(journal.expanded(entry)) }
            }
            for bytes in added { try retain(bytes) }
            if !unique.isEmpty { root[key] = .array(unique.keys.sorted().map { unique[$0]! }) }
        }
        if sources.isEmpty { root.removeValue(forKey: sourcesKey) }
        else { root[sourcesKey] = .object(sources.mapValues(VortxJSON.string)) }
        let journal = root.filter { [evidenceKey, pendingKey, sourcesKey].contains($0.key) }
        guard try JSONEncoder().encode(VortxJSON.object(journal)).count <= maximumJournalBytes else { throw Failure.malformed }
        // Retention only changes the journal. Preserve the enclosing material, original-source
        // archive and exclusion receipt instead of rebuilding an empty bootstrap envelope.
        let result = try VortxNativeBootstrapArchive.replacingHostDocument(in: archive,
            with: JSONEncoder().encode(VortxJSON.object(root)))
        try validate(result, scope: scope)
        return result
    }

    /// Explicit non-main executor for production journal operations. Construction stores
    /// only immutable scope/callbacks. Results have no publication authority; callers retain
    /// their source/account/profile fences and the store retains strict expected-byte CAS.
    actor RecoveryWorker {
        private let scope: VortxAccountScope
        private let cooperation: Cooperation
        init(scope: VortxAccountScope, isCurrent: @escaping @Sendable () -> Bool,
             checkpoint: (@Sendable () async throws -> Void)? = nil) {
            self.scope = scope
            cooperation = Cooperation(isCurrent: isCurrent, checkpoint: checkpoint)
        }
        fileprivate func validatedJournal(_ archive: Data?) async throws -> Journal {
            try await cooperation.boundary()
            guard let owner = UUID(uuidString: scope.ownerProfileID) else { throw Failure.malformed }
            let journal = try await Journal.load(archive, cooperation: cooperation, on: self)
            for (key, pending) in [(evidenceKey, false), (pendingKey, true)] {
                for entry in try journal.records(key) {
                    try await cooperation.boundary()
                    let bytes = try journal.expanded(entry)
                    if pending { try VortxLegacyWatchedMigration.validateArchivedPending(bytes, accountID: scope.account, ownerProfileID: owner) }
                    else { try VortxLegacyWatchedMigration.validateArchivedEvidence(bytes, accountID: scope.account, ownerProfileID: owner) }
                }
            }
            try await cooperation.boundary()
            return journal
        }
        func validate(_ archive: Data?) async throws {
            _ = try await validatedJournal(archive)
        }
        func validatedDraft(_ archive: Data) async throws -> ValidatedDraft {
            try scope.validate()
            try await validate(archive)
            try cooperation.check()
            return ValidatedDraft(archive: archive, scope: scope)
        }
        fileprivate func index(_ journal: Journal) async throws -> [Data: [VortxJSON]] {
            var result: [Data: [VortxJSON]] = [:]
            for entry in try journal.records(evidenceKey) {
                try await cooperation.boundary()
                result[try identity(journal.fields(entry)), default: []].append(entry)
            }
            try await cooperation.boundary()
            return result
        }
        func retaining(_ archive: Data, prior: Data? = nil) async throws -> Data {
            try await cooperation.boundary()
            let archive = try VortxNativeBootstrapArchive.mergingRecoveryEnvelope(archive, prior: prior)
            let old = try await validatedJournal(prior)
            let incoming = try await validatedJournal(archive)
            var root = incoming.host
            var sources: [String: String] = [:]
            for key in [evidenceKey, pendingKey] {
                var unique: [String: VortxJSON] = [:]
                for journal in [old, incoming] {
                    for entry in try journal.records(key) {
                        try await cooperation.boundary()
                        let bytes = try journal.expanded(entry), digest = sha256(bytes)
                        let record = try compact(bytes, sources: &sources)
                        guard unique[digest] == nil || unique[digest] == record else { throw Failure.malformed }
                        unique[digest] = record
                        guard unique.count <= maximumEntries else { throw Failure.malformed }
                    }
                }
                if !unique.isEmpty { root[key] = .array(unique.keys.sorted().map { unique[$0]! }) }
            }
            if sources.isEmpty { root.removeValue(forKey: sourcesKey) }
            else { root[sourcesKey] = .object(sources.mapValues(VortxJSON.string)) }
            let fields = root.filter { [evidenceKey, pendingKey, sourcesKey].contains($0.key) }
            guard try JSONEncoder().encode(VortxJSON.object(fields)).count <= maximumJournalBytes else { throw Failure.malformed }
            try await cooperation.boundary()
            let result = try VortxNativeBootstrapArchive.replacingHostDocument(in: archive,
                with: JSONEncoder().encode(VortxJSON.object(root)))
            try await validate(result)
            return result
        }
        func evidenceLookup(_ archive: Data?) async throws -> VortxLegacyWatchedMigration.ArchivedEvidenceLookup {
            let journal = try await validatedJournal(archive)
            let index = try await index(journal)
            let scope = scope, cooperation = cooperation
            return { requested, digest, locator in
                try cooperation.check()
                guard Data(requested.accountID.utf8) == Data(scope.account.utf8),
                      requested.ownerProfileID == UUID(uuidString: scope.ownerProfileID) else { throw Failure.malformed }
                let key = try identity(["accountId": requested.accountID, "ownerProfileId": requested.ownerProfileID.uuidString,
                    "profileId": requested.profileID.uuidString, "verifiedStreamingUid": requested.verifiedStreamingUID as Any? ?? NSNull(),
                    "sourceDocumentSha256": digest, "row": VortxLegacyWatchedMigration.encodeLocator(locator)])
                let matching = index[key] ?? []
                guard matching.count <= 1 else { throw Failure.malformed }
                let result = try matching.map(journal.expanded)
                try cooperation.check()
                return result
            }
        }
        /// Cold capture + strict replay of both installed and separate draft sources.
        /// A read/decrypt/validation failure throws; it can never become an empty source.
        func externalCWDenials(_ archive: Data?, store: any VortxCheckpointStore, profileID: String,
            candidates: [VortxNativeExternalCW.Candidate]) async throws
            -> (denials: VortxNativeExternalCWPending.Denials, draft: VortxMigrationDraftRead) {
            guard UUID(uuidString: profileID)?.uuidString == profileID else { throw Failure.malformed }
            var result = try VortxNativeExternalCWPending.Denials(candidates: candidates)
            try await cooperation.boundary()
            let draft = try store.captureMigrationDraft(scope: scope)
            let installedJournal = try await validatedJournal(archive)
            let draftJournal = try await validatedJournal(draft.archive)
            let journals = [installedJournal, draftJournal]
            // Match completion across both immutable snapshots, deduplicating exact receipts.
            // Two different witnesses for the same tuple stay ambiguous and cannot clear it.
            var indexed: [Data: Set<Data>] = [:]
            for journal in journals {
                for entry in try journal.records(evidenceKey) {
                    try await cooperation.boundary()
                    indexed[try identity(journal.fields(entry)), default: []].insert(Data(SHA256.hash(data: try journal.expanded(entry))))
                }
            }
            let completed = Set(indexed.filter { $0.value.count == 1 }.keys)
            guard let owner = UUID(uuidString: scope.ownerProfileID) else { throw Failure.malformed }
            for journal in journals {
            for entry in try journal.records(pendingKey) {
                try await cooperation.boundary()
                guard !completed.contains(try identity(journal.fields(entry))) else { continue }
                let attribution = try VortxLegacyWatchedMigration.pendingAttribution(journal.expanded(entry),
                    accountID: scope.account, ownerProfileID: owner)
                if attribution.profileID.uuidString == profileID {
                    result.denyTitle(attribution.metaID, reason: "host_pending_watched")
                }
            }
            if let pending = journal.host["ownAccountOverlayPending"] {
                guard case .object(let profiles) = pending else { throw Failure.malformed }
                if let entry = profiles[profileID] {
                    guard case .object(let fields) = entry,
                          Set(fields.keys) == ["profileOverlayBase64", "reason"]
                            || Set(fields.keys) == ["verifiedStreamingUid", "sourceDocumentSha256", "profileOverlayBase64", "reason"],
                          case .string(let reason) = fields["reason"], ["missing_witness", "changed_witness"].contains(reason),
                          case .string(let raw) = fields["profileOverlayBase64"], let bytes = Data(base64Encoded: raw),
                          bytes.base64EncodedString() == raw else { throw Failure.malformed }
                    if let uid = fields["verifiedStreamingUid"] {
                        guard case .string(let value) = uid, !value.isEmpty,
                              case .string(let digest) = fields["sourceDocumentSha256"],
                              digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw Failure.malformed }
                    } else if reason != "missing_witness" { throw Failure.malformed }
                    try await cooperation.boundary()
                    try result.overlay(bytes, profileID: profileID, reason: "host_pending_overlay", check: cooperation.check)
                }
            }
            try await cooperation.boundary()
            if let validated = try VortxNativeUnattributedOverlayArchive.merge(nil,
                journal.host[VortxNativeUnattributedOverlayArchive.key], scope: scope), case .object(let records) = validated {
                for record in records.values {
                    try await cooperation.boundary()
                    guard record["profileId"] == .string(profileID) else { continue }
                    guard case .string(let raw) = record["profileOverlayBase64"], let bytes = Data(base64Encoded: raw) else {
                        throw Failure.malformed
                    }
                    try result.overlay(bytes, profileID: profileID, reason: "host_unattributed_overlay", check: cooperation.check)
                }
            }
            }
            try await cooperation.boundary()
            try draft.withActive {}
            return (result, draft)
        }
        func pendingProfileIDs(_ archive: Data?) async throws -> [UUID] {
            let journal = try await validatedJournal(archive)
            let indexed = try await index(journal)
            let completed = Set(indexed.filter { $0.value.count == 1 }.keys)
            var ids = Set<UUID>()
            for entry in try journal.records(pendingKey) {
                try await cooperation.boundary()
                let value = try journal.fields(entry)
                guard !completed.contains(try identity(value)) else { continue }
                guard let id = value["profileId"] as? String, let profile = UUID(uuidString: id) else { throw Failure.malformed }
                ids.insert(profile)
            }
            try await cooperation.boundary()
            return ids.sorted { $0.uuidString < $1.uuidString }
        }
        func stream(archive: Data, persist: (@Sendable (Data) async throws -> Void)? = nil) async throws -> Stream {
            try await cooperation.boundary()
            let stream = try Stream(archive: archive, scope: scope, isCurrent: cooperation.isCurrent,
                persist: persist, checkpoint: cooperation.checkpoint)
            try await stream.initialize()
            try await cooperation.boundary()
            return stream
        }
        fileprivate func stream(snapshot: ValidatedJournalSnapshot,
                                persist: (@Sendable (Data) async throws -> Void)?) async throws -> Stream {
            try await cooperation.boundary()
            guard scope.authenticatedData == snapshot.scope.authenticatedData else { throw Failure.malformed }
            let stream = Stream(snapshot: snapshot, isCurrent: cooperation.isCurrent,
                persist: persist, checkpoint: cooperation.checkpoint)
            try await stream.initialize()
            try await cooperation.boundary()
            return stream
        }
        func readDraft(_ store: VortxEncryptedCheckpointStore) async throws -> Data? {
            try await cooperation.boundary()
            let result = try await store.readMigrationDraftCooperatively(scope: scope,
                isCurrent: cooperation.isCurrent, checkpoint: cooperation.checkpoint)
            try await cooperation.boundary()
            return result
        }
        /// Compatibility fallback for a protocol store that only implements the old
        /// synchronous read. Its indivisible I/O/validation stays off the main actor;
        /// we still replay the returned immutable bytes with the full strict inspector.
        func readSynchronousDraft(_ store: any VortxCheckpointStore) async throws -> Data? {
            try await cooperation.boundary()
            try scope.validate()
            let archive = try store.readMigrationDraft(scope: scope)
            try await cooperation.boundary()
            if let archive { try await validate(archive) }
            try cooperation.check()
            return archive
        }
        func authenticatedSourceArchive(_ store: VortxEncryptedCheckpointStore) async throws -> Data? {
            try await cooperation.boundary()
            let host = try store.readHostPreferences(scope: scope)
            let result = try host.map { try JSONDecoder().decode(VortxNativeHostPreferences.Local.self, from: $0).authenticatedSourceArchive } ?? nil
            try await cooperation.boundary()
            return result
        }
        func hostDocument(_ archive: Data) async throws -> [String: VortxJSON] {
            try await validatedJournal(archive).host
        }
        func firstImportRecovery(_ archive: Data?) async throws -> VortxNativeUnattributedOverlayArchive.FirstImportRecovery {
            try await cooperation.boundary()
            let result = try VortxNativeUnattributedOverlayArchive.firstImportRecovery(archive, scope: scope)
            try await cooperation.boundary()
            return result
        }
        func retainingUnattributed(_ archive: Data, prior: Data?, document: Data,
            profileIDs: Set<UUID>, pendingOriginProfileIDs: Set<UUID> = []) async throws -> Data {
            try await cooperation.boundary()
            let result = try VortxNativeUnattributedOverlayArchive.retaining(archive, prior: prior, document: document,
                profileIDs: profileIDs, pendingOriginProfileIDs: pendingOriginProfileIDs, scope: scope)
            try await cooperation.boundary()
            return result
        }
        func appendingMembership(_ receipts: Data?, to archive: Data, sourceDocument: Data) async throws -> Data {
            try await cooperation.boundary()
            let result = try VortxLegacyMembershipReceiptArchive.appending(receipts, to: archive,
                scope: scope.account, ownerProfileID: scope.ownerProfileID, sourceDocumentSHA256: sha256(sourceDocument))
            try await cooperation.boundary()
            return result
        }
        func authenticatedCheckpoint(_ store: VortxEncryptedCheckpointStore) async throws -> String? {
            try await cooperation.boundary()
            let result = try store.authenticatedCheckpoint(scope: scope)
            try await cooperation.boundary()
            return result
        }
    }

    /// Scoped CAS publication is separate from the native checkpoint/source fence. A draft
    /// cannot import rows or authenticate an own account; it only makes validated recovery
    /// receipts crash-resumable. No cursor can acknowledge or skip an unresolved tuple.
    actor DraftPublisher {
        private var expected: Data?
        private let write: @Sendable (Data, Data?) async throws -> Void
        init(expected: Data?, write: @escaping @Sendable (Data, Data?) async throws -> Void) {
            self.expected = expected; self.write = write
        }
        func publish(_ archive: Data) async throws {
            try Task.checkCancellation()
            guard archive != expected else { return }
            let prior = expected
            try await write(archive, prior)
            expected = archive
        }
    }

    /// The only retained raw receipt is the one currently being admitted. Compact records and
    /// exact pooled sources are bounded by the existing encoded journal cap. The batch counters
    /// bound uncheckpointed work, not total lifetime history or measured process RSS.
    actor Stream {
        private let scope: VortxAccountScope
        private let isCurrent: @Sendable () -> Bool
        private let persist: (@Sendable (Data) async throws -> Void)?
        private var archive: Data
        private var host: [String: VortxJSON]
        private var sources: [String: String] = [:]
        private var evidence: [String: VortxJSON] = [:]
        private var pending: [String: VortxJSON] = [:]
        private var encodedBytes = 0
        private var batchBytes = 0
        private var batchCount = 0
        private var operationActive = false
        private var ready = false
        private var initialSnapshot: ValidatedJournalSnapshot?
        private let cooperation: Cooperation
        private static let maximumBatchCount = 64

        init(archive: Data, scope: VortxAccountScope, isCurrent: @escaping @Sendable () -> Bool,
             persist: (@Sendable (Data) async throws -> Void)? = nil,
             checkpoint: (@Sendable () async throws -> Void)? = nil) throws {
            self.archive = archive; self.scope = scope; self.isCurrent = isCurrent; self.persist = persist
            self.host = [:]
            cooperation = Cooperation(isCurrent: isCurrent, checkpoint: checkpoint)
        }
        fileprivate init(snapshot: ValidatedJournalSnapshot, isCurrent: @escaping @Sendable () -> Bool,
                         persist: (@Sendable (Data) async throws -> Void)?,
                         checkpoint: (@Sendable () async throws -> Void)?) {
            archive = snapshot.archive; scope = snapshot.scope; self.isCurrent = isCurrent; self.persist = persist
            host = [:]; initialSnapshot = snapshot
            cooperation = Cooperation(isCurrent: isCurrent, checkpoint: checkpoint)
        }
        /// Called on this actor, never in its synchronous initializer. Local working maps
        /// become visible only after every old receipt has passed strict admission.
        fileprivate func initialize() async throws {
            guard !operationActive else { throw Failure.malformed }
            operationActive = true
            defer { operationActive = false }
            try await loadIfNeeded()
        }
        private func loadIfNeeded() async throws {
            if ready { try requireCurrent(); return }
            let journal: Journal
            if let snapshot = initialSnapshot {
                try requireCurrent()
                guard archive == snapshot.archive, scope.authenticatedData == snapshot.scope.authenticatedData else { throw Failure.malformed }
                journal = snapshot.journal
            } else {
                let worker = RecoveryWorker(scope: scope, isCurrent: isCurrent, checkpoint: cooperation.checkpoint)
                journal = try await worker.validatedJournal(archive)
            }
            var pool: [String: String] = [:]
            var captured: [String: VortxJSON] = [:], unresolved: [String: VortxJSON] = [:]
            for (key, isPending) in [(evidenceKey, false), (pendingKey, true)] {
                for record in try journal.records(key) {
                    try await cooperation.boundary()
                    let raw = try journal.expanded(record), digest = sha256(raw)
                    let compacted = try compact(raw, sources: &pool)
                    if isPending { unresolved[digest] = compacted } else { captured[digest] = compacted }
                }
            }
            let value: [String: VortxJSON] = [evidenceKey: .array(Array(captured.values)),
                pendingKey: .array(Array(unresolved.values)), sourcesKey: .object(pool.mapValues(VortxJSON.string))]
            let size = try JSONEncoder().encode(VortxJSON.object(value)).count
            guard size <= maximumJournalBytes else { throw Failure.processingLimit }
            try await cooperation.boundary()
            sources = pool; evidence = captured; pending = unresolved
            host = journal.host; encodedBytes = size; initialSnapshot = nil; ready = true
        }
        func append(_ receipt: Data, pending isPending: Bool) async throws {
            guard !operationActive else { throw Failure.malformed }
            operationActive = true
            defer { operationActive = false }
            try await loadIfNeeded()
            try await cooperation.boundary()
            guard receipt.count <= maximumExpandedJournalBytes else { throw Failure.processingLimit }
            let digest = sha256(receipt)
            if (isPending ? pending[digest] : evidence[digest]) != nil { return }
            guard let owner = UUID(uuidString: scope.ownerProfileID) else { throw Failure.malformed }
            if isPending { try VortxLegacyWatchedMigration.validateArchivedPending(receipt, accountID: scope.account, ownerProfileID: owner) }
            else { try VortxLegacyWatchedMigration.validateArchivedEvidence(receipt, accountID: scope.account, ownerProfileID: owner) }
            if receipt.count > maximumExpandedJournalBytes - batchBytes { try await flush() }
            var pool = sources
            let record = try compact(receipt, sources: &pool)
            let count = isPending ? pending.count : evidence.count
            guard count < maximumEntries else { throw Failure.processingLimit }
            var additional = try JSONEncoder().encode(record).count + (count == 0 ? 0 : 1)
            var poolCount = sources.count
            for (key, value) in pool where sources[key] == nil {
                let field = VortxJSON.object([key: .string(value)])
                additional += try JSONEncoder().encode(field).count - 2 + (poolCount == 0 ? 0 : 1)
                poolCount += 1
            }
            guard additional <= maximumJournalBytes - encodedBytes else { throw Failure.processingLimit }
            // No mutable state changes until all per-receipt validation and storage admission pass.
            sources = pool; encodedBytes += additional
            if isPending { pending[digest] = record } else { evidence[digest] = record }
            batchBytes += receipt.count; batchCount += 1
            if batchCount >= Self.maximumBatchCount { try await flush() }
            try requireCurrent()
        }
        func finish() async throws -> Data {
            guard !operationActive else { throw Failure.malformed }
            operationActive = true
            defer { operationActive = false }
            try await loadIfNeeded()
            try await flush()
            return archive
        }
        private func requireCurrent() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw LegacyWatchedBitfieldMigrationEvidence.Failure.admissionRevoked }
        }
        private func flush() async throws {
            try await cooperation.boundary()
            var document = host
            document[evidenceKey] = .array(evidence.keys.sorted().map { evidence[$0]! })
            document[pendingKey] = .array(pending.keys.sorted().map { pending[$0]! })
            document[sourcesKey] = .object(sources.mapValues(VortxJSON.string))
            let fields = document.filter { [evidenceKey, pendingKey, sourcesKey].contains($0.key) }
            guard try JSONEncoder().encode(VortxJSON.object(fields)).count == encodedBytes,
                  encodedBytes <= maximumJournalBytes else { throw Failure.malformed }
            let candidate = try VortxNativeBootstrapArchive.replacingHostDocument(in: archive,
                with: JSONEncoder().encode(VortxJSON.object(document)))
            try await cooperation.boundary()
            if let persist { try await persist(candidate) }
            try requireCurrent()
            archive = candidate; host = document; batchBytes = 0; batchCount = 0
        }
    }
}
