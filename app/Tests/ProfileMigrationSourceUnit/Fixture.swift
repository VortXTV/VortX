// PRIVATE — G3 SOURCE FIXTURE PROPOSAL. UNCOMPILED / UNRUN.
// Disposable collaborators below do not implement Combine, credentials, storage or CoreBridge.
import Foundation

// A one-shot continuation handshake. The lock also permits a task-local receipt's
// nonisolated deinit to finish it. No timeout, polling, yielding or sleep proves a phase.
private final class CompletionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func finish() {
        lock.lock()
        precondition(!finished, "one-shot completion signaled twice")
        finished = true
        let ready = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in ready { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class InheritedTaskLifetime: @unchecked Sendable {
    private let completion: CompletionSignal
    init(_ completion: CompletionSignal) { self.completion = completion }
    deinit { completion.finish() }
}

private enum InvocationScope {
    @TaskLocal static var lifetime: InheritedTaskLifetime?
}

// Synthetic value shapes, with a deliberately unrelated field to catch candidate loss.
private struct ProfileDiscoveryPreferences: Equatable {
    var continueWatchingSource: String?
    var continueWatchingWindow: Int?
    var untouchedDiscovery = "discovery-kept"
}

private struct UserProfile: Equatable {
    let id: UUID
    var name = "profile-kept"
    var isOwner = true
    var usesOwnAccount = false
    var discovery: ProfileDiscoveryPreferences?
    var usesEngineHistory: Bool { isOwner || usesOwnAccount }
}

// These raw values are fixture values, not a verification of the app enum declarations.
private enum ContinueWatchingService: String { case trakt }
private enum ContinueWatchingWindow: Int { case twenty = 20 }
private struct TraktSessionID: Equatable { let value: UUID }

@MainActor
private final class CoreBridge {
    static let shared = CoreBridge()
    var currentTarget: UUID?
}

private struct PlaybackMutationTarget: Equatable {
    let value: UUID
    @MainActor func stillOwnsCurrentContext(core: CoreBridge) -> Bool {
        core.currentTarget == value
    }
}

@MainActor
private enum TraktAuth { static var storedSessionID: TraktSessionID? }

@MainActor
private final class HeldSave {
    let entered = CompletionSignal()
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var wasReleased = false

    func suspend() async -> Bool {
        await withCheckedContinuation { continuation in
            precondition(self.continuation == nil && !wasReleased)
            self.continuation = continuation
            entered.finish()
        }
    }

    func release(_ result: Bool) {
        guard let continuation else { preconditionFailure("save has not entered") }
        self.continuation = nil
        wasReleased = true
        continuation.resume(returning: result)
    }

    func releaseIfHeld() {
        if continuation != nil { release(false) }
    }
}

@MainActor
private final class SaveProbe {
    struct Call {
        let profile: UserProfile
        let creating: Bool
        let target: PlaybackMutationTarget?
    }
    private(set) var calls: [Call] = []
    private var planned: [HeldSave] = []

    func plan() -> HeldSave {
        let hold = HeldSave()
        planned.append(hold)
        return hold
    }

    func save(_ profile: UserProfile, creating: Bool, target: PlaybackMutationTarget?) async -> Bool {
        precondition(!planned.isEmpty, "unplanned save or automatic retry")
        let hold = planned.removeFirst()
        calls.append(.init(profile: profile, creating: creating, target: target))
        return await hold.suspend()
    }
}

// Synthetic outer shell. Only the marked declarations, helper and reset are literal source.
@MainActor
private final class ProfileStore {
    private var activeID: UUID?
    let probe = SaveProbe()

    // BEGIN literal afterimage 293–301.
    private struct ContinueWatchingMigrationWitness {
        let id = UUID() // Reinstalling equal profile/target/session values is a new witness.
        let profileID: UUID
        let target: PlaybackMutationTarget
        let session: TraktSessionID
    }
    private var continueWatchingMigration: ContinueWatchingMigrationWitness?
    // A retired task may finish after a successor starts; cleanup owns only its attempt.
    private var continueWatchingMigrationAttempt: UUID?
    // END literal afterimage 293–301.

    // BEGIN literal afterimage 492–526, complete corrected helper.
    private func migrateContinueWatchingIfQualified(_ profile: UserProfile) {
        guard let witness = continueWatchingMigration else { return }
        guard profile.discovery?.continueWatchingSource == nil else {
            continueWatchingMigration = nil; return
        }
        guard continueWatchingMigrationAttempt == nil, profile.id == witness.profileID,
              profile.usesEngineHistory, witness.target.stillOwnsCurrentContext(core: .shared),
              TraktAuth.storedSessionID == witness.session else { return }
        let attempt = UUID()
        continueWatchingMigrationAttempt = attempt
        var migrated = profile
        var discovery = profile.discovery ?? ProfileDiscoveryPreferences()
        discovery.continueWatchingSource = ContinueWatchingService.trakt.rawValue
        discovery.continueWatchingWindow = discovery.continueWatchingWindow ?? ContinueWatchingWindow.twenty.rawValue
        migrated.discovery = discovery
        Task { @MainActor in
            defer {
                if self.continueWatchingMigrationAttempt == attempt {
                    self.continueWatchingMigrationAttempt = nil
                }
            }
            guard self.continueWatchingMigrationAttempt == attempt,
                  let currentWitness = self.continueWatchingMigration,
                  currentWitness.id == witness.id,
                  currentWitness.profileID == witness.profileID,
                  currentWitness.target == witness.target,
                  currentWitness.session == witness.session,
                  self.activeID == witness.profileID,
                  witness.target.stillOwnsCurrentContext(core: .shared),
                  TraktAuth.storedSessionID == witness.session else { return }
            // Publication comes only from saveNative's existing checkpoint-acknowledged projection.
            // On failure retain this exact witness for a later same-installation retry.
            _ = await self.saveNative(migrated, creating: false, target: witness.target)
        }
    }
    // END literal afterimage 492–526.

    // Synthetic async seam, replacing the entire real storage/Bridge implementation.
    private func saveNative(_ profile: UserProfile, creating: Bool,
                            target: PlaybackMutationTarget?) async -> Bool {
        await probe.save(profile, creating: creating, target: target)
    }

    func install(profileID: UUID, target: PlaybackMutationTarget, session: TraktSessionID) -> UUID {
        continueWatchingMigration = .init(profileID: profileID, target: target, session: session)
        return continueWatchingMigration!.id
    }

    func setActive(_ id: UUID?) { activeID = id }
    var attempt: UUID? { continueWatchingMigrationAttempt }
    var witnessID: UUID? { continueWatchingMigration?.id }

    func transition(selected: UUID, target: PlaybackMutationTarget) {
        // BEGIN literal afterimage 420–423, entire original reset condition and operation.
        if let witness = continueWatchingMigration,
           witness.profileID != selected || witness.target != target || TraktAuth.storedSessionID != witness.session {
            continueWatchingMigration = nil; continueWatchingMigrationAttempt = nil
        }
        // END literal afterimage 420–423.
    }

    func directEdit(continueWatchingEdited: Bool = true) {
        // BEGIN literal afterimage 1699; the wider captureDiscovery path is not extracted.
        if continueWatchingEdited { continueWatchingMigration = nil }
        // END literal afterimage 1699.
    }

    // This synchronous wrapper returns only the signal, never the lifetime receipt.
    // Its temporary receipt and withValue binding are released before callers can await.
    func invoke(_ profile: UserProfile) -> CompletionSignal {
        let completion = CompletionSignal()
        InvocationScope.$lifetime.withValue(InheritedTaskLifetime(completion)) {
            migrateContinueWatchingIfQualified(profile)
        }
        return completion
    }
}

private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
enum G3ProfileMigrationFixture {
    private struct Context {
        let store: ProfileStore
        let profile: UserProfile
        let target: PlaybackMutationTarget
        let session: TraktSessionID
        let witness: UUID
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw FixtureFailure(description: message) }
    }

    private static func context(window: Int? = nil) -> Context {
        let store = ProfileStore()
        let profile = UserProfile(id: UUID(), discovery: .init(continueWatchingWindow: window))
        let target = PlaybackMutationTarget(value: UUID())
        let session = TraktSessionID(value: UUID())
        CoreBridge.shared.currentTarget = target.value
        TraktAuth.storedSessionID = session
        store.setActive(profile.id)
        let witness = store.install(profileID: profile.id, target: target, session: session)
        return .init(store: store, profile: profile, target: target, session: session, witness: witness)
    }

    private static func checkCandidate(_ call: SaveProbe.Call, from c: Context, window: Int) throws {
        try require(call.profile.id == c.profile.id && call.profile.name == c.profile.name,
                    "candidate changed original profile identity or unrelated name")
        try require(call.profile.isOwner == c.profile.isOwner && call.profile.usesOwnAccount == c.profile.usesOwnAccount,
                    "candidate changed account flags")
        try require(call.profile.discovery?.continueWatchingSource == "trakt", "candidate source")
        try require(call.profile.discovery?.continueWatchingWindow == window, "candidate window")
        try require(call.profile.discovery?.untouchedDiscovery == c.profile.discovery?.untouchedDiscovery,
                    "candidate dropped unrelated discovery field")
        try require(!call.creating && call.target == c.target, "save must receive original target and creating false")
    }

    // Family 1: save holds are the only suspension points establishing A/B entry.
    private static func suspendedSuccessor(oldFinishesFirst: Bool) async throws {
        let c = context()
        let aHold = c.store.probe.plan()
        defer { aHold.releaseIfHeld() }
        let aEnd = c.store.invoke(c.profile)
        let aAttempt = c.store.attempt
        await aHold.entered.wait()
        try require(!aEnd.isFinished && aAttempt != nil, "held A completion canary")

        let bProfile = UserProfile(id: UUID(), discovery: .init())
        let bTarget = PlaybackMutationTarget(value: UUID())
        let bSession = TraktSessionID(value: UUID())
        TraktAuth.storedSessionID = bSession
        c.store.transition(selected: bProfile.id, target: bTarget)
        try require(c.store.attempt == nil && c.store.witnessID == nil, "transition must retire both")
        CoreBridge.shared.currentTarget = bTarget.value
        c.store.setActive(bProfile.id)
        _ = c.store.install(profileID: bProfile.id, target: bTarget, session: bSession)
        let bHold = c.store.probe.plan()
        defer { bHold.releaseIfHeld() }
        let bEnd = c.store.invoke(bProfile)
        let bAttempt = c.store.attempt
        try require(bAttempt != nil && bAttempt != aAttempt, "successor needs fresh attempt UUID")
        await bHold.entered.wait()
        try require(c.store.probe.calls.count == 2 && !bEnd.isFinished, "both saves entered exactly once")
        try require(c.store.probe.calls[0].target == c.target && c.store.probe.calls[1].target == bTarget,
                    "A and B must retain their own original targets")
        let initialBusyEnd = c.store.invoke(bProfile)
        await initialBusyEnd.wait()
        try require(c.store.probe.calls.count == 2 && c.store.attempt == bAttempt,
                    "invocation dispatched while both original saves were held")

        if oldFinishesFirst {
            aHold.release(true)
            await aEnd.wait()
            try require(c.store.attempt == bAttempt && !bEnd.isFinished, "old A cleared held B attempt")
            let busyEnd = c.store.invoke(bProfile)
            await busyEnd.wait()
            try require(c.store.probe.calls.count == 2 && c.store.attempt == bAttempt,
                        "third invocation dispatched while B held")
            bHold.release(true)
            await bEnd.wait()
        } else {
            bHold.release(true)
            await bEnd.wait()
            try require(c.store.attempt == nil && !aEnd.isFinished, "B should clear only its own slot")
            aHold.release(true)
            await aEnd.wait()
        }
        try require(c.store.attempt == nil && c.store.probe.calls.count == 2, "completion order final slot/save count")
    }

    // Family 2: this entire schedule runs on MainActor before its first await.
    private static func queuedSuccessor() async throws {
        let c = context()
        let aEnd = c.store.invoke(c.profile)
        let aAttempt = c.store.attempt
        let bSession = TraktSessionID(value: UUID())
        TraktAuth.storedSessionID = bSession
        c.store.transition(selected: c.profile.id, target: c.target)
        _ = c.store.install(profileID: c.profile.id, target: c.target, session: bSession)
        let bHold = c.store.probe.plan()
        defer { bHold.releaseIfHeld() }
        let bEnd = c.store.invoke(c.profile)
        let bAttempt = c.store.attempt
        try require(aAttempt != nil && bAttempt != nil && bAttempt != aAttempt, "queued successor attempt identity")
        try require(c.store.probe.calls.isEmpty && !aEnd.isFinished, "queued phase before yielding")
        await aEnd.wait()
        await bHold.entered.wait()
        try require(c.store.probe.calls.count == 1 && c.store.attempt == bAttempt,
                    "queued A dispatched or cleared successor")
        bHold.release(true)
        await bEnd.wait()
        try require(c.store.attempt == nil, "queued successor cleanup")
    }

    // Family 3: equal payload reinstall retains A's attempt, independently testing witness UUID.
    private static func equalPayloadReinstall() async throws {
        let c = context()
        let end = c.store.invoke(c.profile)
        let attempt = c.store.attempt
        let replacement = c.store.install(profileID: c.profile.id, target: c.target, session: c.session)
        try require(replacement != c.witness && c.store.attempt == attempt && attempt != nil,
                    "fresh complete witness with original attempt retained")
        await end.wait()
        try require(c.store.probe.calls.isEmpty && c.store.attempt == nil && c.store.witnessID == replacement,
                    "equal payload must reject old witness and clean only its own attempt")
    }

    // Same payload also gets a fresh attempt after the exact reset retires original A.
    private static func equalPayloadWithSuccessorAttempt() async throws {
        let c = context()
        let aEnd = c.store.invoke(c.profile)
        let aAttempt = c.store.attempt
        c.store.transition(selected: UUID(), target: c.target)
        let replacement = c.store.install(profileID: c.profile.id, target: c.target, session: c.session)
        let hold = c.store.probe.plan()
        defer { hold.releaseIfHeld() }
        let bEnd = c.store.invoke(c.profile)
        let bAttempt = c.store.attempt
        try require(replacement != c.witness && bAttempt != nil && bAttempt != aAttempt,
                    "equal-payload successor must replace both identities")
        try require(c.store.probe.calls.isEmpty, "equal-payload setup must stay before Task entry")
        await aEnd.wait()
        await hold.entered.wait()
        try require(c.store.probe.calls.count == 1 && c.store.attempt == bAttempt,
                    "equal-payload retired A dispatched or cleared successor")
        hold.release(true)
        await bEnd.wait()
        try require(c.store.attempt == nil && c.store.witnessID == replacement,
                    "equal-payload successor cleanup")
    }

    // Direct clear before entry also exercises the completion seam with a no-save task.
    private static func directClearBeforeEntry() async throws {
        let c = context()
        let end = c.store.invoke(c.profile)
        let attempt = c.store.attempt
        c.store.directEdit()
        try require(c.store.witnessID == nil && c.store.attempt == attempt && attempt != nil,
                    "direct clear must leave original attempt occupied")
        try require(c.store.probe.calls.isEmpty && !end.isFinished, "queued no-save canary before yielding")
        await end.wait()
        try require(end.isFinished && c.store.probe.calls.isEmpty && c.store.attempt == nil,
                    "queued missing-witness task must terminate without save")
    }

    // Family 4a: reinstall payload mismatches reject, but UUID mismatch precedes field checks.
    private static func replacementPayloadBoundary(_ variant: Int) async throws {
        let c = context()
        let end = c.store.invoke(c.profile)
        let replacement = c.store.install(profileID: variant == 0 ? UUID() : c.profile.id,
                                          target: variant == 1 ? .init(value: UUID()) : c.target,
                                          session: variant == 2 ? .init(value: UUID()) : c.session)
        try require(replacement != c.witness, "replacement must construct a fresh witness")
        await end.wait()
        try require(c.store.probe.calls.isEmpty && c.store.attempt == nil, "replacement payload boundary save")
    }

    // Family 4b: original witness/attempt survive; each downstream authority predicate is reached.
    private static func retainedWitnessBoundary(_ variant: Int) async throws {
        let c = context()
        let end = c.store.invoke(c.profile)
        if variant == 0 { c.store.setActive(UUID()) }
        if variant == 1 { CoreBridge.shared.currentTarget = UUID() }
        if variant == 2 { TraktAuth.storedSessionID = .init(value: UUID()) }
        try require(c.store.witnessID == c.witness && c.store.attempt != nil, "retained-witness boundary setup")
        await end.wait()
        try require(c.store.probe.calls.isEmpty && c.store.attempt == nil, "retained-witness authority boundary save")
    }

    // Family 5: success and failure conserve fields; only a later explicit call may retry.
    private static func healthy(_ result: Bool, window: Int?) async throws {
        let c = context(window: window)
        let hold = c.store.probe.plan()
        defer { hold.releaseIfHeld() }
        let end = c.store.invoke(c.profile)
        let originalAttempt = c.store.attempt
        await hold.entered.wait()
        try require(c.store.probe.calls.count == 1 && !end.isFinished, "held-save lifetime canary")
        try checkCandidate(c.store.probe.calls[0], from: c, window: window ?? 20)
        hold.release(result)
        await end.wait()
        try require(end.isFinished && c.store.attempt == nil && c.store.probe.calls.count == 1,
                    "own cleanup or spontaneous retry after healthy result")
        try require(c.store.witnessID == c.witness, "synthetic save must not alter existing witness")
        if !result {
            let retryHold = c.store.probe.plan()
            defer { retryHold.releaseIfHeld() }
            let retryEnd = c.store.invoke(c.profile)
            try require(c.store.attempt != nil && c.store.attempt != originalAttempt,
                        "explicit retry must acquire a fresh attempt")
            await retryHold.entered.wait()
            try require(c.store.probe.calls.count == 2, "explicit retry save count")
            try checkCandidate(c.store.probe.calls[1], from: c, window: window ?? 20)
            retryHold.release(false)
            await retryEnd.wait()
            try require(c.store.attempt == nil && c.store.probe.calls.count == 2, "explicit failure retried automatically")
        }
    }

    // Direct clear during an entered save does not cancel or free that save's attempt.
    private static func directClearWhileSuspended(_ result: Bool) async throws {
        let c = context()
        let hold = c.store.probe.plan()
        defer { hold.releaseIfHeld() }
        let end = c.store.invoke(c.profile)
        let originalAttempt = c.store.attempt
        await hold.entered.wait()
        c.store.directEdit()
        try require(c.store.witnessID == nil && c.store.attempt == originalAttempt && !end.isFinished,
                    "direct clear canceled or freed an already-entered save")
        let replacement = c.store.install(profileID: c.profile.id, target: c.target, session: c.session)
        let busyEnd = c.store.invoke(c.profile)
        await busyEnd.wait()
        try require(replacement != c.witness && c.store.attempt == originalAttempt && c.store.probe.calls.count == 1,
                    "reinstalled witness bypassed occupied attempt")
        hold.release(result)
        await end.wait()
        try require(c.store.attempt == nil && c.store.witnessID == replacement && c.store.probe.calls.count == 1,
                    "old completion changed replacement witness or automatically retried")
    }

    // Family 6: synchronous admission no-ops/retirement and the occupied attempt branch.
    private static func ineligible(_ variant: Int) async throws {
        let c = context()
        var profile = c.profile
        if variant == 0 { c.store.directEdit() }
        if variant == 1 { profile.discovery?.continueWatchingSource = "local" }
        if variant == 2 { profile.isOwner = false; profile.usesOwnAccount = false }
        if variant == 3 { CoreBridge.shared.currentTarget = UUID() }
        if variant == 4 { TraktAuth.storedSessionID = .init(value: UUID()) }
        if variant == 5 { profile = .init(id: UUID(), discovery: .init()) }
        let end = c.store.invoke(profile)
        await end.wait()
        try require(c.store.probe.calls.isEmpty && c.store.attempt == nil, "ineligible admission dispatched")
        if variant == 1 { try require(c.store.witnessID == nil, "nonnil source must retire witness") }
    }

    private static func occupiedAttempt() async throws {
        let c = context()
        let hold = c.store.probe.plan()
        defer { hold.releaseIfHeld() }
        let end = c.store.invoke(c.profile)
        let attempt = c.store.attempt
        await hold.entered.wait()
        let busyEnd = c.store.invoke(c.profile)
        await busyEnd.wait()
        try require(c.store.attempt == attempt && c.store.probe.calls.count == 1 && !end.isFinished,
                    "busy call dispatched or released owner")
        hold.release(true)
        await end.wait()
        try require(c.store.attempt == nil && c.store.probe.calls.count == 1, "busy case final cleanup")
    }

    static func run() async throws {
        try await suspendedSuccessor(oldFinishesFirst: true)
        try await suspendedSuccessor(oldFinishesFirst: false)
        try await queuedSuccessor()
        try await equalPayloadReinstall()
        try await equalPayloadWithSuccessorAttempt()
        try await directClearBeforeEntry()
        for variant in 0..<3 { try await replacementPayloadBoundary(variant) }
        for variant in 0..<3 { try await retainedWitnessBoundary(variant) }
        try await healthy(true, window: nil)
        try await healthy(true, window: 7)
        try await healthy(false, window: nil)
        try await healthy(false, window: 7)
        try await directClearWhileSuspended(true)
        try await directClearWhileSuspended(false)
        for variant in 0..<6 { try await ineligible(variant) }
        try await occupiedAttempt()
    }
}
