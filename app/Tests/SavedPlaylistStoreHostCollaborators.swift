import Dispatch
import Foundation

// HOST FIXTURE ONLY. These are controlled Store collaborators, not native, authentication,
// persistence or transport implementations. Production SavedPlaylistStore is compiled in full.
enum PlaylistStoreFixtureFailure: Error {
    case budget, timeout(String), invalidFixture
}

@MainActor final class PlaylistStoreFixtureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var armed = false
    private(set) var entered = false

    func arm() {
        precondition(continuation == nil)
        armed = true
        entered = false
    }
    func wait() async {
        guard armed else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        armed = false
        let old = continuation
        continuation = nil
        old?.resume()
    }
}

@MainActor fileprivate final class PlaylistStoreFixtureLifetime {
    var active = true
}

struct XperiencePreparedExport: Sendable {
    fileprivate let targetID: UUID
}

@MainActor final class ProfileStore {
    static let shared = ProfileStore()
    var activeID: UUID?
}

@MainActor final class CoreBridge {
    static let shared = CoreBridge()
    struct NativePlaylistTarget: Sendable {
        let profileID: UUID
        fileprivate let owner: NativePlaylistReceiptOwner
        fileprivate let identity: UUID
        fileprivate let lifetime: PlaylistStoreFixtureLifetime
    }
    struct Write: Sendable {
        let owner: NativePlaylistReceiptOwner
        let field: String
        let register: VortxJSON
    }

    private(set) var owner: NativePlaylistReceiptOwner?
    private var fieldsByScope: [String: [String: VortxJSON]] = [:]
    private var lifetimes: [PlaylistStoreFixtureLifetime] = []
    private var counter: UInt64 = 0
    private var credentialGeneration: UInt64 = 0
    private let actor = "00000000-0000-4000-8000-000000000001"
    var budgetGate = PlaylistStoreFixtureGate()
    var saveReplyGate = PlaylistStoreFixtureGate()
    var rejectBudget = false
    private(set) var budgetCalls = 0
    private(set) var saveCalls = 0
    private(set) var registerReads = 0
    private(set) var writes: [Write] = []

    private func scope(_ owner: NativePlaylistReceiptOwner) -> String {
        owner.credentialNamespace + ":" + owner.profileKey
    }
    func select(namespace: String, profile: UUID) {
        for lifetime in lifetimes { lifetime.active = false }
        credentialGeneration += 1
        owner = .init(credentialNamespace: namespace, credentialGeneration: credentialGeneration,
            accountGeneration: UUID(), profileID: profile, profileKey: profile.uuidString,
            profileGeneration: UUID(), sessionGeneration: UUID())
        ProfileStore.shared.activeID = profile
    }
    func reset() {
        for lifetime in lifetimes { lifetime.active = false }
        lifetimes.removeAll()
        fieldsByScope.removeAll()
        owner = nil
        ProfileStore.shared.activeID = nil
        counter = 0
        budgetGate = PlaylistStoreFixtureGate()
        saveReplyGate = PlaylistStoreFixtureGate()
        rejectBudget = false
        resetCounters()
    }
    func resetCounters() {
        budgetCalls = 0
        saveCalls = 0
        registerReads = 0
        writes.removeAll()
    }
    func captureNativePlaylistTarget() throws -> NativePlaylistTarget {
        guard let owner else { throw VortxNativeError.closed }
        let lifetime = PlaylistStoreFixtureLifetime()
        lifetimes.append(lifetime)
        return .init(profileID: owner.profileID, owner: owner, identity: UUID(), lifetime: lifetime)
    }
    func retireNativePlaylistTarget(_ target: NativePlaylistTarget) { target.lifetime.active = false }
    func nativePlaylistTargetIsCurrent(_ target: NativePlaylistTarget) -> Bool {
        target.lifetime.active && owner == target.owner && ProfileStore.shared.activeID == target.profileID
    }
    func captureNativePlaylistReceiptOwner() -> NativePlaylistReceiptOwner? { owner }
    func nativePlaylistReceiptOwnerIsCurrent(_ candidate: NativePlaylistReceiptOwner) -> Bool {
        owner == candidate && ProfileStore.shared.activeID == candidate.profileID
    }
    func nativePlaylistRegisters(target: NativePlaylistTarget) throws -> [String: VortxJSON] {
        guard nativePlaylistTargetIsCurrent(target) else { throw VortxNativeError.superseded }
        registerReads += 1
        return fieldsByScope[scope(target.owner)] ?? [:]
    }
    func fieldsForCurrentOwner() -> [String: VortxJSON] {
        owner.flatMap { fieldsByScope[scope($0)] } ?? [:]
    }
    func seed(_ document: VortxNativePlaylist.Document) throws -> String {
        guard let owner else { throw PlaylistStoreFixtureFailure.invalidFixture }
        let field = VortxNativePlaylist.field(document.id)
        try replaceValue(field: field, value: VortxNativePlaylist.encodedValue(document), owner: owner)
        return field
    }
    func peerReplace(_ document: VortxNativePlaylist.Document) throws {
        guard let owner else { throw PlaylistStoreFixtureFailure.invalidFixture }
        try replaceValue(field: VortxNativePlaylist.field(document.id),
            value: VortxNativePlaylist.encodedValue(document), owner: owner)
    }
    private func replaceValue(field: String, value: VortxJSON, owner: NativePlaylistReceiptOwner) throws {
        try VortxNativePlaylist.validateEnvelope(name: field, value: value, global: false)
        guard counter < VortxNativeHostPreferences.maxClock else { throw PlaylistStoreFixtureFailure.invalidFixture }
        counter += 1
        fieldsByScope[scope(owner), default: [:]][field] = .object([
            "clock": .unsigned(counter), "actor": .string(actor), "value": value
        ])
    }
    func prepareNativePlaylistExportBudget(target: NativePlaylistTarget) async throws -> XperiencePreparedExport {
        guard nativePlaylistTargetIsCurrent(target) else { throw VortxNativeError.superseded }
        budgetCalls += 1
        await budgetGate.wait()
        if rejectBudget { throw PlaylistStoreFixtureFailure.budget }
        // Intentionally permit a late prepared-result delivery. The actual Store must reject
        // retirement after this suspension; this fixture result grants no native authority.
        return .init(targetID: target.identity)
    }
    func saveNativePlaylist(_ edit: VortxNativeHostFieldEdit, target: NativePlaylistTarget,
                            validator: XperiencePreparedExport) async throws -> VortxJSON {
        saveCalls += 1
        guard nativePlaylistTargetIsCurrent(target), validator.targetID == target.identity else {
            throw VortxNativeError.superseded
        }
        let current = fieldsByScope[scope(target.owner)] ?? [:]
        try VortxNativePlaylist.validateMutation(edit, fields: current)
        try replaceValue(field: edit.field, value: edit.value, owner: target.owner)
        guard let accepted = fieldsByScope[scope(target.owner)]?[edit.field] else {
            throw PlaylistStoreFixtureFailure.invalidFixture
        }
        writes.append(.init(owner: target.owner, field: edit.field, register: accepted))
        // Commit under A, then hold only its response while the test retires A. There is
        // never an old-target mutation under B. Store must deny a late accepted publication.
        await saveReplyGate.wait()
        if nativePlaylistReceiptOwnerIsCurrent(target.owner) {
            VortXSyncManager.shared.register(owner: target.owner, field: edit.field, register: accepted)
        }
        return accepted
    }
}

@MainActor final class VortXSyncManager {
    static let shared = VortXSyncManager()
    private var ledger = NativePlaylistCloudReceiptLedger()
    private(set) var queryCount = 0
    func reset() { ledger = .init(); queryCount = 0 }
    func register(owner: NativePlaylistReceiptOwner, field: String, register: VortxJSON) {
        guard let bytes = VortxNativePlaylist.canonicalReceiptRegister(register) else {
            preconditionFailure("invalid synthetic fixture register")
        }
        precondition(ledger.register(owner: owner, field: field, canonicalRegister: bytes) != nil)
    }
    func acknowledgeAll(version: Int) {
        for (key, pending) in ledger.pending {
            precondition(ledger.acknowledge(key, edit: pending.edit,
                exactAcceptedRegister: pending.register, version: version))
        }
    }
    func forgetReceipts() { ledger.invalidate() }
    func nativePlaylistCloudReceipt(owner: NativePlaylistReceiptOwner, field: String,
                                    fingerprint: NativePlaylistRegisterFingerprint) -> NativePlaylistCloudReceiptState {
        queryCount += 1
        guard CoreBridge.shared.nativePlaylistReceiptOwnerIsCurrent(owner) else { return .unknown }
        return ledger.state(owner: owner, field: field, current: fingerprint)
    }
}

@MainActor final class PlaybackTitleQueue {
    static let shared = PlaybackTitleQueue()
    struct PlaylistImportTarget {
        fileprivate let owner: NativePlaylistReceiptOwner
        fileprivate let attachment: UUID
    }
    struct PlaylistSnapshot {
        let candidates: [PlaybackTitleQueuePolicy.Candidate]
        let remainingCapacity: Int
    }
    private var owner: NativePlaylistReceiptOwner?
    private var attachment = UUID()
    private(set) var policy = PlaybackTitleQueuePolicy()
    private(set) var appendCalls = 0
    var admissionProblem = "The playlist will not fit. Nothing changed."
    func configure(candidates: [PlaybackTitleQueuePolicy.Candidate]) {
        owner = CoreBridge.shared.owner
        attachment = UUID()
        policy = .init()
        precondition(policy.restorePending(candidates.map { .init(id: UUID(), candidate: $0) }))
        appendCalls = 0
    }
    func capturePlaylistImportTarget() -> PlaylistImportTarget? {
        guard let owner, CoreBridge.shared.nativePlaylistReceiptOwnerIsCurrent(owner) else { return nil }
        return .init(owner: owner, attachment: attachment)
    }
    private func current(_ target: PlaylistImportTarget) -> Bool {
        owner == target.owner && attachment == target.attachment
            && CoreBridge.shared.nativePlaylistReceiptOwnerIsCurrent(target.owner)
    }
    func playlistSnapshot(for target: PlaylistImportTarget) -> PlaylistSnapshot? {
        guard current(target) else { return nil }
        return .init(candidates: policy.durableEntries.map(\.candidate),
            remainingCapacity: PlaybackTitleQueuePolicy.capacity - policy.count)
    }
    func appendCandidates(_ candidates: [PlaybackTitleQueuePolicy.Candidate], target: PlaylistImportTarget) -> Bool {
        appendCalls += 1
        guard current(target) else { return false }
        return policy.appendCandidates(candidates)
    }
}

// A bounded test-only executor barrier; it changes no fingerprint implementation. The real
// actor is occupied until the MainActor test retires its owner, then its genuine method runs.
final class PlaylistStoreFingerprintBarrier: Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    func hold() {
        entered.signal()
        precondition(released.wait(timeout: .now() + 10) == .success, "fixture barrier timeout")
    }
    func waitUntilEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
            }
        }
    }
    func release() { released.signal() }
}

extension NativePlaylistCloudReceiptProjectionWorker {
    func hostFixtureHoldExecutor(_ barrier: PlaylistStoreFingerprintBarrier) { barrier.hold() }
}
