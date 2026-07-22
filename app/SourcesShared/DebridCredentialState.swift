import Foundation

/// Owns a NotificationCenter block-registration token without exposing Objective-C's non-Sendable
/// `NSObjectProtocol` through an actor-isolated deinitializer. The token is immutable, and its only
/// cross-isolation operation is the thread-safe observer removal performed during destruction.
final class DebridCredentialNotificationToken: @unchecked Sendable {
    private let rawValue: NSObjectProtocol

    init(_ rawValue: NSObjectProtocol) {
        self.rawValue = rawValue
    }

    deinit {
        NotificationCenter.default.removeObserver(rawValue)
    }
}

/// A debrid service VortX can hold an API key for.
enum DebridService: String, CaseIterable, Codable, Identifiable, Sendable {
    case realDebrid, allDebrid, premiumize, torBox

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realDebrid: return "Real-Debrid"
        case .allDebrid:  return "AllDebrid"
        case .premiumize: return "Premiumize"
        case .torBox:     return "TorBox"
        }
    }

    var hint: String {
        switch self {
        case .realDebrid: return "real-debrid.com, My Account then API."
        case .allDebrid:  return "alldebrid.com, Account then API keys."
        case .premiumize: return "premiumize.me, Account then API."
        case .torBox:     return "torbox.app, Settings then API."
        }
    }

    /// The unshipped v2 per-service target is retained as a migration source for this exact successor.
    func keychainAccount(owner: DebridOwnerScope) -> String {
        switch owner {
        case .signedOutDevice:
            return "vortx.debrid." + rawValue + ".local"
        case .account(let uuid):
            return "vortx.debrid.v2." + rawValue + ".account." + uuid.uuidString.lowercased()
        }
    }

    /// The shipped account-scoped entry. It remains a migration source for its exact canonical UUID owner.
    func legacyRawAccountKeychainAccount(_ uuid: UUID) -> String {
        "vortx.debrid." + rawValue + "." + uuid.uuidString.lowercased()
    }

    /// The pre-scoping global entry. It is claimed by one owner and never written again.
    var legacyGlobalKeychainAccount: String { "vortx.debrid." + rawValue }
}

/// Credential ownership is typed so a signed-out device can never alias a signed-in account.
enum DebridOwnerScope: Sendable, Equatable, Hashable {
    case signedOutDevice
    case account(UUID)

    /// The server emits lowercase `crypto.randomUUID()` strings. Foundation renders UUIDs uppercase, so the
    /// comparison lowercases Foundation's round-trip while requiring the input itself to remain exact lowercase.
    static func canonicalAccount(_ raw: String) -> DebridOwnerScope? {
        guard let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() == raw else { return nil }
        return .account(uuid)
    }

    var storageNamespace: String {
        switch self {
        case .signedOutDevice: return "device.local"
        case .account(let uuid): return "account." + uuid.uuidString.lowercased()
        }
    }
}

/// One complete immutable view of credential ownership and values.
struct DebridCredentialSnapshot: Sendable, Equatable {
    let owner: DebridOwnerScope
    let revision: UInt64
    let keys: [DebridService: String]
}

/// Main-owner state mechanics. `DebridKeys` owns and mutates this value on the main actor.
struct DebridCredentialMutableState {
    private(set) var snapshot: DebridCredentialSnapshot

    init(owner: DebridOwnerScope, keys: [DebridService: String], revision: UInt64 = 1) {
        precondition(revision > 0, "debrid credential revision must be positive")
        snapshot = DebridCredentialSnapshot(
            owner: owner, revision: revision, keys: Self.normalized(keys)
        )
    }

    init(snapshot: DebridCredentialSnapshot) {
        self.init(owner: snapshot.owner, keys: snapshot.keys, revision: snapshot.revision)
    }

    var owner: DebridOwnerScope { snapshot.owner }
    var revision: UInt64 { snapshot.revision }
    var keys: [DebridService: String] { snapshot.keys }

    /// Replace an owner and its complete key set as one revision. Equal state is a no-op.
    mutating func replace(owner: DebridOwnerScope, keys: [DebridService: String])
        -> DebridCredentialSnapshot? {
        commit(owner: owner, keys: Self.normalized(keys))
    }

    /// Apply one local edit. Empty or whitespace-only values clear the service.
    mutating func setKey(_ value: String, for service: DebridService) -> DebridCredentialSnapshot? {
        var next = snapshot.keys
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { next.removeValue(forKey: service) }
        else { next[service] = trimmed }
        return commit(owner: snapshot.owner, keys: next)
    }

    /// Apply every present remote service in one envelope while preserving absent services.
    mutating func applyRemoteKeys(_ remote: [DebridService: String]) -> DebridCredentialSnapshot? {
        var next = snapshot.keys
        for (service, value) in remote {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { next.removeValue(forKey: service) }
            else { next[service] = trimmed }
        }
        return commit(owner: snapshot.owner, keys: next)
    }

    private mutating func commit(owner: DebridOwnerScope, keys: [DebridService: String])
        -> DebridCredentialSnapshot? {
        guard owner != snapshot.owner || keys != snapshot.keys else { return nil }
        precondition(snapshot.revision < UInt64.max, "debrid credential revision exhausted")
        snapshot = DebridCredentialSnapshot(owner: owner, revision: snapshot.revision + 1, keys: keys)
        return snapshot
    }

    static func normalized(_ input: [DebridService: String]) -> [DebridService: String] {
        var out: [DebridService: String] = [:]
        for (service, value) in input {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out[service] = trimmed }
        }
        return out
    }
}

/// The only detached-reader view. The lock protects replacement of one immutable envelope.
final class DebridCredentialSnapshotStore: @unchecked Sendable {
    static let didPublishNotification = Notification.Name("vortx.debridCredentialSnapshotDidPublish")

    /// This is the cold-start owner. It reads the signed-out durable envelope synchronously before any caller can
    /// obtain the first snapshot, so resolver startup never depends on `DebridKeys.shared` or a settings view.
    static let shared = DebridCredentialSnapshotStore(
        initial: DebridCredentialPersistence.bootstrapSignedOutSnapshot(read: Keychain.string)
    )

    private let lock = NSLock()
    private var value: DebridCredentialSnapshot

    init(initial: DebridCredentialSnapshot) { value = initial }

    func load() -> DebridCredentialSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Publication is monotonic too, so a delayed owner task cannot replace a newer complete envelope. Every
    /// production writer is MainActor-isolated, which serializes this replacement with observable result mutation.
    @MainActor
    @discardableResult
    func publish(_ snapshot: DebridCredentialSnapshot) -> Bool {
        lock.lock()
        guard snapshot.revision > value.revision else {
            lock.unlock()
            return false
        }
        value = snapshot
        lock.unlock()
        // Posted on MainActor after releasing the lock. Long-lived observable consumers use it to clear
        // revision-scoped UI state even when their input groups do not otherwise change.
        NotificationCenter.default.post(name: Self.didPublishNotification, object: self)
        return true
    }

    /// Checked immediately before a resolver spends its captured credential.
    func isCurrent(revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value.revision == revision
    }

    /// Checked after every provider await and before the result can leave the coordinator.
    func resultIsCurrent(revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value.revision == revision
    }

    /// Linearize an authenticated transport at its irreversible issuance point. The caller creates a suspended
    /// request first, then resumes it inside `issue` while this same lock excludes snapshot publication.
    @discardableResult
    func authorizeAndIssue(revision: UInt64, issue: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value.revision == revision else { return false }
        issue()
        return true
    }

    /// The required caller-publication seam. Every production writer and caller mutation is MainActor-isolated,
    /// so B either runs before A and A is discarded, or runs after A's synchronous mutation. The lock is released
    /// before `mutation` because @Published observers run synchronously and may safely re-enter detached reads.
    @MainActor
    @discardableResult
    func compareAndPublish(revision: UInt64, mutation: @MainActor () -> Void) -> Bool {
        lock.lock()
        let matches = value.revision == revision
        lock.unlock()
        guard matches else { return false }
        mutation()
        return true
    }

    func isConfigured(_ service: DebridService) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value.keys[service]?.isEmpty == false
    }
}

/// A revision captured with a credential-bearing resolver. Every authenticated transport validates it again at
/// its actual send call, including later requests in a multi-await provider flow.
struct DebridCredentialRevisionToken: Sendable {
    let revision: UInt64
    private let store: DebridCredentialSnapshotStore

    init(revision: UInt64, store: DebridCredentialSnapshotStore) {
        self.revision = revision
        self.store = store
    }

    func authorizeAndIssue(_ issue: () -> Void) -> Bool {
        store.authorizeAndIssue(revision: revision, issue: issue)
    }
}

/// Result shape required by the out-of-lease caller conversion. The value remains unusable for publication until
/// its revision is atomically compared at the caller's actual mutation through `compareAndPublish`.
struct DebridVersionedResult<Value: Sendable>: Sendable {
    let value: Value
    let revision: UInt64

    func map<Output: Sendable>(_ transform: (Value) -> Output) -> DebridVersionedResult<Output> {
        DebridVersionedResult<Output>(value: transform(value), revision: revision)
    }
}

/// Coordinator-side acceptance state. The first envelope is accepted; later equal or older ones are not.
struct DebridCredentialRevisionFence {
    private(set) var appliedRevision: UInt64?

    mutating func accept(_ snapshot: DebridCredentialSnapshot) -> Bool {
        if let appliedRevision, snapshot.revision <= appliedRevision { return false }
        appliedRevision = snapshot.revision
        return true
    }
}

// MARK: - Durable versioned envelope

enum DebridCredentialEnvelopeSlot: String, CaseIterable, Codable, Sendable {
    case a, b

    var other: DebridCredentialEnvelopeSlot { self == .a ? .b : .a }
}

struct DebridCredentialStorageAccounts: Equatable, Sendable {
    let envelopeA: String
    let envelopeB: String
    let markerA: String
    let markerB: String

    init(owner: DebridOwnerScope) {
        let base = "vortx.debrid.v3.envelope." + owner.storageNamespace
        envelopeA = base + ".slot.a"
        envelopeB = base + ".slot.b"
        markerA = base + ".commit.a"
        markerB = base + ".commit.b"
    }

    func envelope(_ slot: DebridCredentialEnvelopeSlot) -> String {
        slot == .a ? envelopeA : envelopeB
    }

    func marker(_ slot: DebridCredentialEnvelopeSlot) -> String {
        slot == .a ? markerA : markerB
    }
}

struct DebridCredentialPersistedEnvelope: Codable, Equatable, Sendable {
    static let currentFormat = 1

    let format: Int
    let generation: UInt64
    let ownerNamespace: String
    let keys: [String: String]

    init(generation: UInt64, owner: DebridOwnerScope, keys: [DebridService: String]) {
        format = Self.currentFormat
        self.generation = generation
        ownerNamespace = owner.storageNamespace
        self.keys = Dictionary(uniqueKeysWithValues: DebridCredentialMutableState.normalized(keys).map {
            ($0.key.rawValue, $0.value)
        })
    }

    func decodedKeys(owner: DebridOwnerScope) -> [DebridService: String]? {
        guard format == Self.currentFormat, generation > 0,
              ownerNamespace == owner.storageNamespace else { return nil }
        var decoded: [DebridService: String] = [:]
        for (raw, value) in keys {
            guard let service = DebridService(rawValue: raw) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            decoded[service] = trimmed
        }
        return decoded
    }
}

struct DebridCredentialCommitMarker: Codable, Equatable, Sendable {
    static let currentFormat = 1

    let format: Int
    let generation: UInt64
    let ownerNamespace: String
    let slot: DebridCredentialEnvelopeSlot

    init(generation: UInt64, owner: DebridOwnerScope, slot: DebridCredentialEnvelopeSlot) {
        format = Self.currentFormat
        self.generation = generation
        ownerNamespace = owner.storageNamespace
        self.slot = slot
    }
}

struct DebridCredentialStorageIO {
    let read: (String) -> String?
    let write: (String, String) -> Bool
    let delete: (String) -> Bool
}

enum DebridCredentialEnvelopeLoad: Equatable {
    case none
    case committed(DebridCredentialPersistedEnvelope)
    case quarantined

    var envelope: DebridCredentialPersistedEnvelope? {
        if case .committed(let envelope) = self { return envelope }
        return nil
    }
}

enum DebridCredentialCommitFailure: Equatable {
    case quarantinedCurrent
    case generationExhausted
    case inactiveMarkerDeleteFailed
    case envelopeWriteFailed
    case envelopeReadbackMismatch
    case markerWriteFailed
    case markerReadbackMismatch
    case commitValidationFailed
}

enum DebridCredentialCommitResult: Equatable {
    case unchanged(DebridCredentialPersistedEnvelope)
    case committed(DebridCredentialPersistedEnvelope)
    case failed(DebridCredentialCommitFailure)

    var succeeded: Bool {
        switch self {
        case .unchanged, .committed: return true
        case .failed: return false
        }
    }
}

enum DebridCredentialPersistence {
    private struct Candidate {
        let slot: DebridCredentialEnvelopeSlot
        let envelope: DebridCredentialPersistedEnvelope
    }

    static func load(owner: DebridOwnerScope, read: (String) -> String?)
        -> DebridCredentialEnvelopeLoad {
        let accounts = DebridCredentialStorageAccounts(owner: owner)
        let candidates = DebridCredentialEnvelopeSlot.allCases.compactMap { slot in
            candidate(owner: owner, slot: slot, accounts: accounts, read: read)
        }
        if let maximum = candidates.map(\.envelope.generation).max() {
            let winners = candidates.filter { $0.envelope.generation == maximum }
            guard winners.count == 1 else { return .quarantined }
            return .committed(winners[0].envelope)
        }
        let hasMarker = DebridCredentialEnvelopeSlot.allCases.contains {
            read(accounts.marker($0)) != nil
        }
        return hasMarker ? .quarantined : .none
    }

    static func loadKeys(owner: DebridOwnerScope, read: (String) -> String?)
        -> [DebridService: String] {
        switch load(owner: owner, read: read) {
        case .committed(let envelope):
            return envelope.decodedKeys(owner: owner) ?? [:]
        case .quarantined:
            return [:]
        case .none:
            return legacyFallbackKeys(owner: owner, read: read)
        }
    }

    static func committedKeys(owner: DebridOwnerScope, read: (String) -> String?)
        -> [DebridService: String] {
        guard case .committed(let envelope) = load(owner: owner, read: read) else { return [:] }
        return envelope.decodedKeys(owner: owner) ?? [:]
    }

    static func bootstrapSignedOutSnapshot(read: (String) -> String?) -> DebridCredentialSnapshot {
        DebridCredentialSnapshot(
            owner: .signedOutDevice,
            revision: 1,
            keys: loadKeys(owner: .signedOutDevice, read: read)
        )
    }

    static func commit(owner: DebridOwnerScope, keys: [DebridService: String], io: DebridCredentialStorageIO)
        -> DebridCredentialCommitResult {
        let loadResult = load(owner: owner, read: io.read)
        if case .quarantined = loadResult { return .failed(.quarantinedCurrent) }
        let current = loadResult.envelope
        let normalized = DebridCredentialMutableState.normalized(keys)
        if let current, current.decodedKeys(owner: owner) == normalized { return .unchanged(current) }
        guard current?.generation != UInt64.max else { return .failed(.generationExhausted) }

        let accounts = DebridCredentialStorageAccounts(owner: owner)
        let currentSlot = current.flatMap { envelope -> DebridCredentialEnvelopeSlot? in
            DebridCredentialEnvelopeSlot.allCases.first {
                candidate(owner: owner, slot: $0, accounts: accounts, read: io.read)?.envelope == envelope
            }
        }
        let nextSlot = currentSlot?.other ?? .a
        let markerAccount = accounts.marker(nextSlot)
        if io.read(markerAccount) != nil {
            guard io.delete(markerAccount), io.read(markerAccount) == nil else {
                return .failed(.inactiveMarkerDeleteFailed)
            }
        }

        let next = DebridCredentialPersistedEnvelope(
            generation: (current?.generation ?? 0) + 1, owner: owner, keys: normalized
        )
        guard let envelopeString = encodeCanonical(next) else { return .failed(.envelopeWriteFailed) }
        let envelopeAccount = accounts.envelope(nextSlot)
        guard io.write(envelopeString, envelopeAccount) else { return .failed(.envelopeWriteFailed) }
        guard io.read(envelopeAccount) == envelopeString else { return .failed(.envelopeReadbackMismatch) }

        let marker = DebridCredentialCommitMarker(
            generation: next.generation, owner: owner, slot: nextSlot
        )
        guard let markerString = encodeCanonical(marker) else { return .failed(.markerWriteFailed) }
        guard io.write(markerString, markerAccount) else { return .failed(.markerWriteFailed) }
        guard io.read(markerAccount) == markerString else { return .failed(.markerReadbackMismatch) }
        guard case .committed(let verified) = load(owner: owner, read: io.read), verified == next else {
            return .failed(.commitValidationFailed)
        }
        return .committed(next)
    }

    static func encodeCanonical<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeCanonical<T: Codable & Equatable>(_ type: T.Type, from raw: String) -> T? {
        guard let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode(type, from: data),
              encodeCanonical(decoded) == raw else { return nil }
        return decoded
    }

    private static func candidate(
        owner: DebridOwnerScope,
        slot: DebridCredentialEnvelopeSlot,
        accounts: DebridCredentialStorageAccounts,
        read: (String) -> String?
    ) -> Candidate? {
        guard let markerRaw = read(accounts.marker(slot)),
              let marker = decodeCanonical(DebridCredentialCommitMarker.self, from: markerRaw),
              marker.format == DebridCredentialCommitMarker.currentFormat,
              marker.ownerNamespace == owner.storageNamespace,
              marker.slot == slot,
              let envelopeRaw = read(accounts.envelope(slot)),
              let envelope = decodeCanonical(DebridCredentialPersistedEnvelope.self, from: envelopeRaw),
              envelope.generation == marker.generation,
              envelope.decodedKeys(owner: owner) != nil else { return nil }
        return Candidate(slot: slot, envelope: envelope)
    }

    private static func legacyFallbackKeys(
        owner: DebridOwnerScope,
        read: (String) -> String?
    ) -> [DebridService: String] {
        var keys: [DebridService: String] = [:]
        for service in DebridService.allCases {
            var sources = [service.keychainAccount(owner: owner)]
            if case .account(let uuid) = owner {
                sources.append(service.legacyRawAccountKeychainAccount(uuid))
            }
            for source in sources {
                guard let value = read(source)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { continue }
                keys[service] = value
                break
            }
        }
        return keys
    }
}

// MARK: - Verified mutation and one-owner migration

enum DebridCredentialDurableMutationResult: Equatable {
    case unchanged
    case committed(DebridCredentialSnapshot)
    case persistenceFailed
}

enum DebridCredentialDurableMutation {
    static func setKey(
        _ value: String,
        for service: DebridService,
        state: inout DebridCredentialMutableState,
        persist: ([DebridService: String]) -> Bool
    ) -> DebridCredentialDurableMutationResult {
        var candidate = state
        guard let snapshot = candidate.setKey(value, for: service) else { return .unchanged }
        guard persist(snapshot.keys) else { return .persistenceFailed }
        state = candidate
        return .committed(snapshot)
    }

    static func applyRemoteKeys(
        _ remote: [DebridService: String],
        state: inout DebridCredentialMutableState,
        persist: ([DebridService: String]) -> Bool
    ) -> DebridCredentialDurableMutationResult {
        var candidate = state
        guard let snapshot = candidate.applyRemoteKeys(remote) else { return .unchanged }
        guard persist(snapshot.keys) else { return .persistenceFailed }
        state = candidate
        return .committed(snapshot)
    }
}

struct DebridCredentialMigrationClaim: Codable, Equatable, Sendable {
    static let currentFormat = 1

    let format: Int
    let ownerNamespace: String
    let service: DebridService
    let sourceAccount: String

    init(owner: DebridOwnerScope, service: DebridService, sourceAccount: String) {
        format = Self.currentFormat
        ownerNamespace = owner.storageNamespace
        self.service = service
        self.sourceAccount = sourceAccount
    }
}

enum DebridCredentialMigrationResult: Equatable {
    case noSource
    case targetPresent
    case targetPresentSourceRemoved
    case migrated
    case claimWriteFailed
    case claimReadbackMismatch
    case claimConflict
    case claimedByOtherOwner
    case deleteFailed
    case duplicateTargetRolledBack
    case rollbackFailed
    case targetWriteFailedAfterSourceDeletion
    case targetReadbackMismatch
    case sourceLostAfterClaim
}

enum DebridCredentialMigration {
    static func globalClaimAccount(for service: DebridService) -> String {
        "vortx.debrid.v3.migration.global." + service.rawValue + ".owner"
    }

    /// Migrate one source with delete-source-first ordering. A global source supplies `claimAccount`, which is
    /// written once and retained permanently so a failed or interrupted move can never be reassigned to another
    /// owner after relaunch. The claim contains no credential value.
    static func migrate(
        service: DebridService,
        owner: DebridOwnerScope,
        sourceAccount: String,
        claimAccount: String?,
        targetKeys: () -> [DebridService: String],
        commitTarget: ([DebridService: String]) -> Bool,
        read: (String) -> String?,
        write: (String, String) -> Bool,
        delete: (String) -> Bool
    ) -> DebridCredentialMigrationResult {
        if let claimAccount {
            let expected = DebridCredentialMigrationClaim(
                owner: owner, service: service, sourceAccount: sourceAccount
            )
            if let raw = read(claimAccount) {
                guard let existing = DebridCredentialPersistence.decodeCanonical(
                    DebridCredentialMigrationClaim.self, from: raw
                ), existing.format == DebridCredentialMigrationClaim.currentFormat else {
                    return .claimConflict
                }
                guard existing.ownerNamespace == owner.storageNamespace else {
                    return .claimedByOtherOwner
                }
                guard existing == expected else { return .claimConflict }
            } else {
                guard let encoded = DebridCredentialPersistence.encodeCanonical(expected),
                      write(encoded, claimAccount) else { return .claimWriteFailed }
                guard read(claimAccount) == encoded else { return .claimReadbackMismatch }
            }
        }

        let current = targetKeys()
        let source = read(sourceAccount)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let target = current[service] {
            guard claimAccount != nil, let source, !source.isEmpty else { return .targetPresent }
            guard delete(sourceAccount), read(sourceAccount) == nil else {
                guard source == target else { return .deleteFailed }
                var rollback = current
                rollback.removeValue(forKey: service)
                return commitTarget(rollback) ? .duplicateTargetRolledBack : .rollbackFailed
            }
            return .targetPresentSourceRemoved
        }

        guard let source, !source.isEmpty else {
            return claimAccount == nil ? .noSource : .sourceLostAfterClaim
        }
        guard delete(sourceAccount), read(sourceAccount) == nil else { return .deleteFailed }

        var next = current
        next[service] = source
        guard commitTarget(next) else { return .targetWriteFailedAfterSourceDeletion }
        guard targetKeys()[service] == source else { return .targetReadbackMismatch }
        return .migrated
    }
}
