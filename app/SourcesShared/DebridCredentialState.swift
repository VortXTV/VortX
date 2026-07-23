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

/// Debrid uses the same typed owner scope as every other credential subsystem. The alias retains the accepted
/// lineage's API spelling for its persistence and proof harness while preventing a second identity grammar from
/// drifting away from `CredentialScope`.
typealias DebridOwnerScope = CredentialScope

extension CredentialScope {
    static func canonicalAccount(_ raw: String) -> CredentialScope? {
        CredentialScope(canonicalRemoteAccountID: raw)
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

    /// Linearize a coordinator-only state swap with snapshot publication. Unlike `compareAndPublish`, this
    /// callback must not invoke observers or escape the coordinator actor. Holding the lock means a newer
    /// credential envelope either publishes before the swap and annuls it, or publishes after the complete swap.
    @discardableResult
    func compareAndInstall(revision: UInt64, mutation: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value.revision == revision else { return false }
        mutation()
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

    func isCurrent() -> Bool {
        store.isCurrent(revision: revision)
    }

    func resultIsCurrent() -> Bool {
        store.resultIsCurrent(revision: revision)
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

/// The single child-entry seam for work derived from an outer credential generation. The returned token is the
/// same revision capability consumed by the coordinator fence and by every resolver's actual issuance fence.
struct DebridCredentialPinnedChildEntry: Sendable {
    let revision: UInt64
    private let store: DebridCredentialSnapshotStore

    init(revision: UInt64, store: DebridCredentialSnapshotStore) {
        self.revision = revision
        self.store = store
    }

    func enter() -> DebridVersionedResult<DebridCredentialRevisionToken?> {
        let token = DebridCredentialRevisionToken(revision: revision, store: store)
        return DebridVersionedResult(
            value: token.isCurrent() ? token : nil,
            revision: revision
        )
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

enum DebridCredentialEnvelopeSlot: String, CaseIterable, Codable, Hashable, Sendable {
    case a, b

    var other: DebridCredentialEnvelopeSlot { self == .a ? .b : .a }
}

struct DebridCredentialStorageAccounts: Equatable, Sendable {
    let envelopeA: String
    let envelopeB: String
    let markerA: String
    let markerB: String
    let recoveryGuard: String

    init(owner: DebridOwnerScope) {
        let base = "vortx.debrid.v3.envelope." + owner.storageNamespace
        envelopeA = base + ".slot.a"
        envelopeB = base + ".slot.b"
        markerA = base + ".commit.a"
        markerB = base + ".commit.b"
        recoveryGuard = base + ".recovery"
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
    let recoveryPhase: DebridCredentialRecoveryPhase?

    init(
        generation: UInt64,
        owner: DebridOwnerScope,
        keys: [DebridService: String],
        recoveryPhase: DebridCredentialRecoveryPhase? = nil
    ) {
        format = Self.currentFormat
        self.generation = generation
        ownerNamespace = owner.storageNamespace
        self.recoveryPhase = recoveryPhase
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
    let recoveryPhase: DebridCredentialRecoveryPhase?

    init(
        generation: UInt64,
        owner: DebridOwnerScope,
        slot: DebridCredentialEnvelopeSlot,
        recoveryPhase: DebridCredentialRecoveryPhase? = nil
    ) {
        format = Self.currentFormat
        self.generation = generation
        ownerNamespace = owner.storageNamespace
        self.slot = slot
        self.recoveryPhase = recoveryPhase
    }
}

enum DebridCredentialRecoveryPhase: String, Codable, Equatable, Sendable {
    case staging
}

/// A non-secret durable barrier used only while replacing a quarantined first-generation write. Its presence
/// keeps every load fail-closed, including after a crash between stale-marker deletion and fresh publication.
struct DebridCredentialRecoveryGuard: Codable, Equatable, Sendable {
    static let currentFormat = 1

    let format: Int
    let ownerNamespace: String

    init(owner: DebridOwnerScope) {
        format = Self.currentFormat
        ownerNamespace = owner.storageNamespace
    }
}

struct DebridCredentialStorageIO {
    let read: (String) -> String?
    let write: (String, String) -> Bool
    let delete: (String) -> Bool
}

struct DebridCredentialCommittedSelection: Equatable, Sendable {
    let slot: DebridCredentialEnvelopeSlot
    let envelope: DebridCredentialPersistedEnvelope
}

struct DebridCredentialQuarantine: Equatable, Sendable {
    let artifactSlots: Set<DebridCredentialEnvelopeSlot>
    let hasRecoveryGuard: Bool
}

enum DebridCredentialEnvelopeLoad: Equatable {
    case none
    case committed(DebridCredentialCommittedSelection)
    case quarantined(DebridCredentialQuarantine)

    var selection: DebridCredentialCommittedSelection? {
        if case .committed(let selection) = self { return selection }
        return nil
    }

    var envelope: DebridCredentialPersistedEnvelope? {
        selection?.envelope
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
    case recoveryGuardWriteFailed
    case recoveryGuardReadbackMismatch
    case recoveryArtifactDeleteFailed
    case recoveryGuardDeleteFailed
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

    private struct SlotObservation {
        let slot: DebridCredentialEnvelopeSlot
        let markerRaw: String?
        let envelopeRaw: String?
        let candidate: Candidate?
        let hasRecoveryStaging: Bool

        var hasArtifact: Bool { markerRaw != nil || envelopeRaw != nil }
    }

    static func load(owner: DebridOwnerScope, read: (String) -> String?)
        -> DebridCredentialEnvelopeLoad {
        let accounts = DebridCredentialStorageAccounts(owner: owner)
        // Two independent reads make a single transient guard miss fail-closed. The staged target pair below is
        // the durable structural barrier once it exists, but this covers the first instruction after guard write.
        let recoveryGuardReadOne = read(accounts.recoveryGuard)
        let recoveryGuardReadTwo = read(accounts.recoveryGuard)
        let recoveryGuardPresent = recoveryGuardReadOne != nil || recoveryGuardReadTwo != nil
        let observations = DebridCredentialEnvelopeSlot.allCases.map { slot in
            observation(owner: owner, slot: slot, accounts: accounts, read: read)
        }
        let artifacts = Set(observations.filter(\.hasArtifact).map(\.slot))
        if recoveryGuardPresent {
            return .quarantined(DebridCredentialQuarantine(
                artifactSlots: artifacts,
                hasRecoveryGuard: true
            ))
        }
        if observations.contains(where: \.hasRecoveryStaging) {
            return .quarantined(DebridCredentialQuarantine(
                artifactSlots: artifacts,
                hasRecoveryGuard: false
            ))
        }
        let candidates = observations.compactMap(\.candidate)
        if let maximum = candidates.map(\.envelope.generation).max() {
            let winners = candidates.filter { $0.envelope.generation == maximum }
            guard winners.count == 1 else {
                return .quarantined(DebridCredentialQuarantine(
                    artifactSlots: artifacts,
                    hasRecoveryGuard: false
                ))
            }
            return .committed(DebridCredentialCommittedSelection(
                slot: winners[0].slot,
                envelope: winners[0].envelope
            ))
        }
        guard artifacts.isEmpty else {
            return .quarantined(DebridCredentialQuarantine(
                artifactSlots: artifacts,
                hasRecoveryGuard: false
            ))
        }
        return .none
    }

    static func loadKeys(owner: DebridOwnerScope, read: (String) -> String?)
        -> [DebridService: String] {
        switch load(owner: owner, read: read) {
        case .committed(let selection):
            return selection.envelope.decodedKeys(owner: owner) ?? [:]
        case .quarantined:
            return [:]
        case .none:
            return legacyFallbackKeys(owner: owner, read: read)
        }
    }

    static func committedKeys(owner: DebridOwnerScope, read: (String) -> String?)
        -> [DebridService: String] {
        guard case .committed(let selection) = load(owner: owner, read: read) else { return [:] }
        return selection.envelope.decodedKeys(owner: owner) ?? [:]
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
        let normalized = DebridCredentialMutableState.normalized(keys)
        let loadResult = load(owner: owner, read: io.read)
        if case .quarantined(let quarantine) = loadResult {
            // Debris alone is not authority to erase or replace credentials. Recovery starts only after a
            // repaste or remote restore supplies at least one concrete credential value.
            guard !normalized.isEmpty else { return .failed(.quarantinedCurrent) }
            return recoverQuarantined(
                owner: owner,
                keys: normalized,
                quarantine: quarantine,
                io: io
            )
        }
        let currentSelection = loadResult.selection
        let current = currentSelection?.envelope
        if let current, current.decodedKeys(owner: owner) == normalized { return .unchanged(current) }
        guard current?.generation != UInt64.max else { return .failed(.generationExhausted) }

        let accounts = DebridCredentialStorageAccounts(owner: owner)
        // The winning slot and envelope are one immutable load result. Re-reading the slots here could turn a
        // transient read failure into a false "no active slot" and make the fallback overwrite the live commit.
        let nextSlot = currentSelection?.slot.other ?? .a
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
        guard case .committed(let verified) = load(owner: owner, read: io.read),
              verified.envelope == next, verified.slot == nextSlot else {
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

    private static func observation(
        owner: DebridOwnerScope,
        slot: DebridCredentialEnvelopeSlot,
        accounts: DebridCredentialStorageAccounts,
        read: (String) -> String?
    ) -> SlotObservation {
        let markerRaw = read(accounts.marker(slot))
        let envelopeRaw = read(accounts.envelope(slot))
        let marker = markerRaw.flatMap {
            decodeCanonical(DebridCredentialCommitMarker.self, from: $0)
        }
        let envelope = envelopeRaw.flatMap {
            decodeCanonical(DebridCredentialPersistedEnvelope.self, from: $0)
        }
        let candidate: Candidate?
        if let marker,
              marker.format == DebridCredentialCommitMarker.currentFormat,
              marker.ownerNamespace == owner.storageNamespace,
              marker.slot == slot,
              marker.recoveryPhase == nil,
              let envelope,
              envelope.generation == marker.generation,
              envelope.recoveryPhase == nil,
              envelope.decodedKeys(owner: owner) != nil {
            candidate = Candidate(slot: slot, envelope: envelope)
        } else {
            candidate = nil
        }
        return SlotObservation(
            slot: slot,
            markerRaw: markerRaw,
            envelopeRaw: envelopeRaw,
            candidate: candidate,
            hasRecoveryStaging: marker?.recoveryPhase == .staging
                || envelope?.recoveryPhase == .staging
        )
    }

    private static func recoverQuarantined(
        owner: DebridOwnerScope,
        keys: [DebridService: String],
        quarantine: DebridCredentialQuarantine,
        io: DebridCredentialStorageIO
    ) -> DebridCredentialCommitResult {
        let accounts = DebridCredentialStorageAccounts(owner: owner)
        let guardValue = DebridCredentialRecoveryGuard(owner: owner)
        guard let guardRaw = encodeCanonical(guardValue),
              io.write(guardRaw, accounts.recoveryGuard) else {
            return .failed(.recoveryGuardWriteFailed)
        }
        guard io.read(accounts.recoveryGuard) == guardRaw else {
            return .failed(.recoveryGuardReadbackMismatch)
        }

        // Prefer a slot with no observed artifact. When both slots contain debris, the durable guard is already
        // exact-readback verified before one marker is removed, so a crash can quarantine but never fall back.
        let target: DebridCredentialEnvelopeSlot
        if !quarantine.artifactSlots.contains(.a) { target = .a }
        else if !quarantine.artifactSlots.contains(.b) { target = .b }
        else { target = .a }

        let targetMarker = accounts.marker(target)
        guard io.delete(targetMarker), io.read(targetMarker) == nil else {
            return .failed(.recoveryArtifactDeleteFailed)
        }

        let staged = DebridCredentialPersistedEnvelope(
            generation: 1,
            owner: owner,
            keys: keys,
            recoveryPhase: .staging
        )
        guard let stagedEnvelopeRaw = encodeCanonical(staged) else {
            return .failed(.envelopeWriteFailed)
        }
        let targetEnvelope = accounts.envelope(target)
        guard io.write(stagedEnvelopeRaw, targetEnvelope) else {
            return .failed(.envelopeWriteFailed)
        }
        guard io.read(targetEnvelope) == stagedEnvelopeRaw else {
            return .failed(.envelopeReadbackMismatch)
        }
        let stagedMarker = DebridCredentialCommitMarker(
            generation: 1,
            owner: owner,
            slot: target,
            recoveryPhase: .staging
        )
        guard let stagedMarkerRaw = encodeCanonical(stagedMarker),
              io.write(stagedMarkerRaw, targetMarker) else {
            return .failed(.markerWriteFailed)
        }
        guard io.read(targetMarker) == stagedMarkerRaw else {
            return .failed(.markerReadbackMismatch)
        }
        guard io.read(targetEnvelope) == stagedEnvelopeRaw,
              io.read(targetMarker) == stagedMarkerRaw else {
            return .failed(.commitValidationFailed)
        }

        // Only a proven staged pair permits stale cleanup. A normal load rejects that pair even if both guard
        // reads miss, so neither the fresh keys nor a surviving older candidate can escape before cleanup.
        for slot in DebridCredentialEnvelopeSlot.allCases where slot != target {
            guard io.delete(accounts.marker(slot)), io.read(accounts.marker(slot)) == nil,
                  io.delete(accounts.envelope(slot)), io.read(accounts.envelope(slot)) == nil else {
                return .failed(.recoveryArtifactDeleteFailed)
            }
        }
        guard io.read(targetEnvelope) == stagedEnvelopeRaw,
              io.read(targetMarker) == stagedMarkerRaw else {
            return .failed(.commitValidationFailed)
        }

        // Convert the envelope first while its marker is still staging. After the guard is removed, the pair
        // remains structurally invalid until the final normal marker exact-readbacks, so every crash stays closed.
        let fresh = DebridCredentialPersistedEnvelope(generation: 1, owner: owner, keys: keys)
        guard let envelopeRaw = encodeCanonical(fresh), io.write(envelopeRaw, targetEnvelope) else {
            return .failed(.envelopeWriteFailed)
        }
        guard io.read(targetEnvelope) == envelopeRaw else {
            return .failed(.envelopeReadbackMismatch)
        }
        guard io.delete(accounts.recoveryGuard), io.read(accounts.recoveryGuard) == nil else {
            return .failed(.recoveryGuardDeleteFailed)
        }
        let marker = DebridCredentialCommitMarker(generation: 1, owner: owner, slot: target)
        guard let markerRaw = encodeCanonical(marker), io.write(markerRaw, targetMarker) else {
            return .failed(.markerWriteFailed)
        }
        guard io.read(targetMarker) == markerRaw,
              case .committed(let verified) = load(owner: owner, read: io.read),
              verified.slot == target, verified.envelope == fresh else {
            return .failed(.commitValidationFailed)
        }
        return .committed(fresh)
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
