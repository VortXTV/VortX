import Foundation

// Inert, deterministic fixture around mechanically extracted production control. No app graph,
// customer credentials, defaults, Keychain, network, provider, device, UIKit or native SDK is linked.
private struct UIBackgroundTaskIdentifier: Hashable, Sendable {
    let raw: Int
    static let invalid = Self(raw: -1)
}
@MainActor private final class UIApplication {
    static let shared = UIApplication()
    var next = 0
    var expirations: [UIBackgroundTaskIdentifier: () -> Void] = [:]
    var ended: [UIBackgroundTaskIdentifier] = []
    func reset() { next = 0; expirations = [:]; ended = [] }
    func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        next += 1
        let id = UIBackgroundTaskIdentifier(raw: next)
        expirations[id] = expirationHandler
        return id
    }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) { ended.append(id); expirations[id] = nil }
    func expire() { for handler in Array(expirations.values) { handler() } }
}
@MainActor private final class Gate {
    var continuation: CheckedContinuation<Void, Never>?
    var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}
private enum CredentialScopeRegistry {
    struct Capture: Equatable, Sendable { let account: String; let generation: UInt64 }
}
@MainActor private final class Authority {
    var current = CredentialScopeRegistry.Capture(account: "A", generation: 1)
    func capture() -> CredentialScopeRegistry.Capture { current }
}
private enum NativeForegroundSyncPolicy {
    /* PRODUCTION_PUSH_QUEUE */
}
@MainActor private final class CoreBridge {
    static let shared = CoreBridge()
    func hydrateAddonsFromAccount(_ descriptors: [String]) {}
    func rebuildContinueWatching() {}
}
/* PRODUCTION_PULL_POLICY */

@MainActor private final class VortXSyncManager {
    let credentialAuthority = Authority()
    var dataKey: Data? = Data([1])
    var isSignedIn = true
    var hasAppliedAccountDoc = true
    var pendingApply = false
    var isApplyingRemote = false
    var pendingAddonOrderIntent: String?
    var activeSyncUp: (id: UUID, capture: CredentialScopeRegistry.Capture)?
    var activeSyncDown: (id: UUID, capture: CredentialScopeRegistry.Capture)?
    var syncUpCompletionWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    var nativePushQueue = NativeForegroundSyncPolicy.PushQueue()
    var nativeDurablePushPending = false
    var hasPendingPush: Bool { nativePushQueue.hasPendingPush || nativeDurablePushPending }
    var uploadStarts = 0
    var uploadedGenerations: [UInt64] = []
    var uploadAccepted = true
    var keepAccepted = true
    var uploadGate: Gate?
    var pullGate: Gate?
    var settleGate: Gate?
    var hydrationCount = 0
    var lastSyncedVersion = 10
    var pendingProviderApply: String?
    var fixtureRestored = false
    var pullOutcomes: [ConflictResolutionOutcome] = []
    enum VersionedPull { case doc(doc: [String: Any], version: Int), empty, failed }
    var pull: VersionedPull = .doc(doc: [:], version: 10)
    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { capture == credentialAuthority.current }
    func requestSyncSoon() { nativePushQueue.request(); nativeDurablePushPending = true }
    func hasPendingAccountDocApply(for capture: CredentialScopeRegistry.Capture) -> Bool { pendingApply }
    func settleNativeProviderJournal(capture: CredentialScopeRegistry.Capture) async -> Bool {
        if let gate = settleGate { settleGate = nil; await gate.wait() }
        return true
    }
    func restoreAccountDocIfNeeded(credentialCapture: CredentialScopeRegistry.Capture) async -> Bool { false }
    func withRemoteApplySuppressed(_ work: () -> Void) { work() }
    func pullDocVersionedRetrying(credentialCapture: CredentialScopeRegistry.Capture) async -> VersionedPull {
        if let gate = pullGate { await gate.wait() }
        return pull
    }
    static func ownedAddons(from doc: [String: Any]) -> [String] { [] }
    func persistLastSyncedVersion() {}
    func stampSyncSuccess() {}
    func hydrateEngineFromOwnedAddons() async { hydrationCount += 1 }
    @discardableResult func keepThisDeviceOverridingAccount() async -> Bool { keepAccepted }
    func startExternalUpload() -> UUID {
        let id = UUID(); activeSyncUp = (id, credentialAuthority.capture()); return id
    }
    func releaseExternalUpload(_ id: UUID) {
        /* RELEASE_WRAPPER */
    }
    func attemptPull(force: Bool = false) async -> Bool { /* PULL_WRAPPER */ }
    func accountOutcome() async -> ConflictResolutionOutcome? { /* ACCOUNT_WRAPPER */ }
    /* PRODUCTION_MANAGER */
}

@MainActor private final class ConflictViewFixture {
    let sync: VortXSyncManager
    var syncing = false
    var syncNote: String?
    init(_ sync: VortXSyncManager) { self.sync = sync }
    func run(_ outcome: VortXSyncManager.ConflictResolutionOutcome) { /* RESOLUTION_WRAPPER */ }
    func runMerge() { let sync = self.sync; /* MERGE_ACTION */ }
    func runKeep() { let sync = self.sync; /* KEEP_ACTION */ }
    func runUse() { let sync = self.sync; /* USE_ACTION */ }
    /* PRODUCTION_RESOLUTION */
}

@main private enum SyncBackgroundConflictTests {
    @MainActor static var failures = 0
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ label: String) {
        checks += 1
        if value { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
    }
    // Bounded scheduling turns, not timed sleeps. The production uploader waits on explicit gates.
    @MainActor static func drain(_ turns: Int = 30) async { for _ in 0..<turns { await Task.yield() } }
    @MainActor static func main() async {
        let app = UIApplication.shared
        app.reset()
        let joined = VortXSyncManager()
        let prior = joined.startExternalUpload()
        joined.syncUpOnBackground()
        await drain()
        check(app.ended.isEmpty, "background grace remains while exact prior upload is in flight")
        check(joined.uploadStarts == 0, "in-flight upload is joined without overlapping export")
        joined.releaseExternalUpload(prior)
        await drain()
        check(joined.uploadStarts == 1, "queued generation flushes after prior upload completes")
        check(app.ended.count == 1, "background lease ends once after completion")

        app.reset()
        let replaced = VortXSyncManager(); let oldID = replaced.startExternalUpload()
        replaced.syncUpOnBackground(); await drain()
        let replacementID = replaced.startExternalUpload()
        replaced.releaseExternalUpload(oldID); await drain()
        check(replaced.activeSyncUp?.id == replacementID && replaced.uploadStarts == 0,
              "old completion cannot clear or overlap a replacement upload")
        replaced.releaseExternalUpload(replacementID); await drain()
        check(replaced.uploadStarts == 1 && app.ended.count == 1, "background rejoins exact replacement without spin")

        app.reset()
        let raced = VortXSyncManager(); let settleHold = Gate(); raced.settleGate = settleHold
        raced.syncUpOnBackground(); await drain()
        let raceWinner = raced.startExternalUpload()
        settleHold.release(); await drain()
        check(app.ended.isEmpty && raced.uploadStarts == 0,
              "upload that wins during async admission inherits background grace")
        raced.releaseExternalUpload(raceWinner); await drain()
        check(raced.uploadStarts == 1 && app.ended.count == 1, "admission race queues then flushes after exact winner")

        app.reset()
        let newer = VortXSyncManager()
        let hold = Gate(); newer.uploadGate = hold
        newer.requestSyncSoon(); newer.syncUpOnBackground()
        await drain()
        check(newer.uploadStarts == 1 && app.ended.isEmpty, "positive control own upload retains grace")
        newer.requestSyncSoon()
        hold.release()
        await drain()
        check(newer.uploadStarts == 2, "new generation during upload is exported before grace ends")
        check(!newer.nativeDurablePushPending, "ACK clears only the final accepted generation")

        app.reset()
        let expired = VortXSyncManager()
        let expiredPrior = expired.startExternalUpload()
        expired.syncUpOnBackground(); await drain()
        app.expire(); await drain()
        check(app.ended.count == 1, "expiration ends bounded lease once")
        check(expired.activeSyncUp?.id == expiredPrior, "expiration never cancels original uploader")
        check(expired.syncUpCompletionWaiters.isEmpty, "expiration retires the suspended continuation")
        expired.releaseExternalUpload(expiredPrior); await drain()
        check(expired.uploadStarts == 0 && expired.nativeDurablePushPending, "expiration leaves queued edits durable without another export")

        for keyABA in [false, true] {
            app.reset()
            let stale = VortXSyncManager(); let id = stale.startExternalUpload()
            stale.syncUpOnBackground(); await drain()
            if keyABA {
                stale.dataKey = Data([2])
                stale.credentialAuthority.current = .init(account: "A", generation: 2)
            } else {
                stale.credentialAuthority.current = .init(account: "B", generation: 2)
                stale.credentialAuthority.current = .init(account: "A", generation: 3)
            }
            stale.releaseExternalUpload(id); await drain()
            check(stale.uploadStarts == 0, "\(keyABA ? "key" : "account") ABA cannot export after suspended prior upload")
            check(app.ended.count == 1, "superseded grace ends once")
        }

        app.reset()
        let keyMismatch = VortXSyncManager(); let keyPrior = keyMismatch.startExternalUpload()
        keyMismatch.syncUpOnBackground(); await drain()
        keyMismatch.dataKey = Data([2])
        keyMismatch.releaseExternalUpload(keyPrior); await drain()
        check(keyMismatch.uploadStarts == 0 && app.ended.count == 1, "changed data key alone fences suspended background export")

        app.reset()
        let refused = VortXSyncManager(); refused.uploadAccepted = false
        refused.requestSyncSoon(); refused.syncUpOnBackground(); await drain()
        check(refused.uploadStarts == 1 && app.ended.count == 1, "failed upload exits without immediate retry spin")
        check(refused.nativeDurablePushPending, "failed upload retains durable pending generation")

        app.reset()
        let coldPending = VortXSyncManager(); coldPending.uploadAccepted = false
        coldPending.nativeDurablePushPending = true
        coldPending.syncUpOnBackground(); await drain()
        check(coldPending.nativeDurablePushPending, "failed cold upload preserves durable pending without an in-memory generation")

        app.reset()
        let deferredOwner = VortXSyncManager(); _ = deferredOwner.startExternalUpload()
        deferredOwner.syncUpOnBackground()
        deferredOwner.credentialAuthority.current = .init(account: "B", generation: 2)
        await drain()
        check(deferredOwner.nativePushQueue.generation == 0, "stale scheduled background task cannot queue work for new owner")

        app.reset()
        let multiple = VortXSyncManager(); _ = multiple.startExternalUpload()
        multiple.syncUpOnBackground(); multiple.syncUpOnBackground(); await drain()
        app.expire(); await drain()
        check(multiple.syncUpCompletionWaiters.isEmpty && app.ended.count == 2,
              "expiration cleans every exact waiter and each independent lease once")

        let clean = VortXSyncManager()
        check(await clean.attemptPull() == false, "positive control equal pull preserves restored=false contract")
        check(clean.pullOutcomes == [.completed], "equal no-op pull reports one completed receipt")
        clean.pull = .doc(doc: [:], version: 11)
        check(await clean.attemptPull(force: true) == false, "positive control settled clean apply preserves restored=false")
        check(clean.pullOutcomes.last == .completed, "settled clean apply reports completion despite restored=false")
        clean.fixtureRestored = true
        check(await clean.attemptPull(force: true), "positive control restored=true remains true after explicit outcome addition")
        clean.pull = .empty
        check(await clean.accountOutcome() == .completed, "definitively empty account is clean success")
        clean.pull = .failed
        check(await clean.accountOutcome() == .failed, "genuine pull failure is not clean no-op success")
        check(await clean.mergeBoth() == false && clean.uploadStarts == 0, "failed merge pull cannot start a composite upload")
        clean.pull = .doc(doc: [:], version: 1)
        _ = await clean.attemptPull()
        check(clean.pullOutcomes.last == .failed, "lower-version refusal is not equal-version success")

        let busy = VortXSyncManager(); _ = busy.startExternalUpload()
        check(await busy.accountOutcome() == .pending, "busy account adoption reports pending")
        let swapped = VortXSyncManager(); let pullHold = Gate(); swapped.pullGate = pullHold
        let swapTask = Task { @MainActor in await swapped.attemptPull(force: true) }
        await drain()
        swapped.credentialAuthority.current = .init(account: "B", generation: 2)
        swapped.credentialAuthority.current = .init(account: "A", generation: 3)
        pullHold.release(); _ = await swapTask.value
        check(swapped.pullOutcomes == [.failed], "pull owner ABA reports exactly one failed receipt")

        let cancelled = VortXSyncManager(); let cancelHold = Gate(); cancelled.pullGate = cancelHold
        let cancelledTask = Task { @MainActor in await cancelled.attemptPull(force: true) }
        await drain(); cancelledTask.cancel(); cancelHold.release(); _ = await cancelledTask.value
        check(cancelled.pullOutcomes == [.failed], "cancelled pull reports exactly one failure receipt")
        let cancelledBeforeStart = VortXSyncManager()
        let beforeTask = Task { @MainActor in await cancelledBeforeStart.attemptPull(force: true) }
        beforeTask.cancel(); _ = await beforeTask.value
        check(cancelledBeforeStart.pullOutcomes == [.failed], "already-cancelled pull cannot report completed")

        for outcome in [VortXSyncManager.ConflictResolutionOutcome.failed, .pending, .completed] {
            let model = VortXSyncManager(); let ui = ConflictViewFixture(model)
            ui.run(outcome); await drain()
            check(!ui.syncing, "conflict action leaves working state for \(outcome)")
            check((ui.syncNote == nil) == (outcome == .completed), "conflict \(outcome) result determines truthful status")
            check(model.hydrationCount == (outcome == .completed ? 1 : 0), "secondary hydrate requires completed conflict action")
        }
        let failedMergeModel = VortXSyncManager(); failedMergeModel.pull = .failed
        let failedMergeUI = ConflictViewFixture(failedMergeModel); failedMergeUI.runMerge(); await drain()
        check(failedMergeUI.syncNote != nil, "production merge button preserves its failed Boolean result")
        let failedKeepModel = VortXSyncManager(); failedKeepModel.keepAccepted = false
        let failedKeepUI = ConflictViewFixture(failedKeepModel); failedKeepUI.runKeep(); await drain()
        check(failedKeepUI.syncNote != nil, "production keep-device button preserves its failed Boolean result")
        let useModel = VortXSyncManager(); useModel.pull = .empty
        let useUI = ConflictViewFixture(useModel); useUI.runUse(); await drain()
        check(useUI.syncNote == nil, "production use-account button accepts a clean no-op pull")
        useModel.pull = .failed; useUI.runUse(); await drain()
        check(useUI.syncNote != nil, "production use-account button surfaces genuine pull failure")
        _ = useModel.startExternalUpload(); useUI.runUse(); await drain()
        check(useUI.syncNote?.contains("waiting") == true, "production use-account button surfaces pending adoption")
        print("\(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }
}
