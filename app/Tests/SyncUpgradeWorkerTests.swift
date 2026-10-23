import Foundation

private enum CredentialScopeRegistry { struct Capture: Equatable { let generation: Int } }
@MainActor private struct Authority { func capture() -> CredentialScopeRegistry.Capture { .init(generation: 1) } }
@MainActor private enum FixtureSleep {
    static var calls = 0
    static func sleep(nanoseconds: UInt64) async throws {
        calls += 1
        // An old infinite-retry worker terminates at the fixture boundary and fails the
        // attempts assertion below. Clock delay is the only replaced production dependency.
        if calls > 3 { throw CancellationError() }
        await Task.yield()
    }
}
@MainActor private final class WorkerHarness {
    let credentialAuthority = Authority()
    var isSignedIn = true
    var isApplyingRemote = false
    var realtimeActive = true
    var pendingSync: Task<Void, Never>?
    var pendingSyncCapture: CredentialScopeRegistry.Capture?
    var pendingSyncID: UUID?
    var pendingSyncAwaitsProgressWindow = false
    var nativePushQueue = NativeForegroundSyncPolicy.PushQueue()
    var nativeDurablePushPending = false
    var hasPendingPush = false
    var backupUploadFailure: SyncBackupUploadFailure?
    var attempts = 0
    var dataKey: Data? = Data([1])
    var upgradeDuringRead = false
    var receiveEffects = 0
    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { capture == credentialAuthority.capture() }
    @discardableResult func syncUp() async -> Bool { attempts += 1; backupUploadFailure = .upgradeRequired; return false }
    func pullDocVersionedRetrying(credentialCapture: CredentialScopeRegistry.Capture, ifNoneMatch: Int?) async -> Int {
        await Task.yield()
        if upgradeDuringRead { backupUploadFailure = .upgradeRequired }
        return 0
    }
    func delayedReceive() async -> Bool {
        let capture = credentialAuthority.capture()
        let capturedDataKey = dataKey
        let conditionalVersion: Int? = nil
        /* PRODUCTION_RECEIVE_ADMISSION */
        _ = received
        receiveEffects += 1
        return true
    }
    func delayedSettlement() async -> Bool {
        let capture = credentialAuthority.capture()
        let capturedDataKey = dataKey
        let providerSettlement = (superseded: false, completed: true)
        await Task.yield()
        backupUploadFailure = .upgradeRequired
        /* PRODUCTION_SETTLEMENT_ADMISSION */
        receiveEffects += 1
        return true
    }
    /* PRODUCTION_WORKER */
}
@main @MainActor private enum UpgradeWorkerChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { print("FAIL \(label)"); exit(1) }; print("PASS \(label)")
    }
    static func main() async {
        let worker = WorkerHarness()
        worker.requestSyncSoon()
        await worker.pendingSync?.value
        expect(worker.attempts == 1 && FixtureSleep.calls == 1, "upgrade response terminates worker after one attempt")
#if VORTX_NATIVE_DATA_ENGINE
        expect(worker.nativePushQueue.hasPendingPush && worker.nativeDurablePushPending && worker.pendingSync == nil,
               "native termination leaves durable queue pending and retires worker")
#else
        expect(worker.hasPendingPush, "Lite termination keeps pending-edit receive guard closed")
#endif
        let calls = FixtureSleep.calls
        worker.requestSyncSoon()
        await worker.pendingSync?.value
        expect(worker.attempts == 1 && FixtureSleep.calls == calls, "new local edit retains intent without rescheduling unsupported writer")
        let receiver = WorkerHarness(); receiver.upgradeDuringRead = true
        let applied = await receiver.delayedReceive()
        expect(!applied && receiver.receiveEffects == 0, "upgrade latched during delayed GET blocks both absent and document receive side effects")
        let settlement = WorkerHarness()
        let acknowledged = await settlement.delayedSettlement()
        expect(!acknowledged && settlement.receiveEffects == 0, "upgrade latched during provider settlement cannot acknowledge/stamp receive")
    }
}
