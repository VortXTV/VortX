import Foundation

// Inert collaborators exercise the extracted production syncNow method. No app,
// account transport, credential store, or device runtime is instantiated.
@MainActor final class CredentialScopeRegistry {
    static let shared = CredentialScopeRegistry()
    var generation = 1
    func capture() -> Int { generation }
    func isCurrent(_ value: Int) -> Bool { generation == value }
}
enum Conflict { case conflict, unreachable, noConflict }
@MainActor final class TestSync {
    var restored = true
    var conflict = Conflict.noConflict
    var pushed = true
    var backupUploadFailure: String?
    var synchronizationIsComplete = true
    var pauseAt: Int?
    var reached = 0
    var continuation: CheckedContinuation<Void, Never>?
    func pause(_ stage: Int) async {
        reached = stage
        if pauseAt == stage { await withCheckedContinuation { continuation = $0 } }
    }
    func retryAccountRestore() async -> Bool { await pause(1); return restored }
    func rosterConflictWithAccount() async -> Conflict { await pause(2); return conflict }
    func pushThisDevice() async -> Bool { await pause(3); return pushed }
}
@MainActor final class TestView {
    let sync = TestSync()
    var syncing = false
    var syncNote: String?
    var showConflict = false
    func begin() { syncNow() }
    func receivedScopeChange() {
        /* PRODUCTION_SCOPE_RESET */
    }
    func receivedNewStamp(_ stamp: Date?) {
        /* PRODUCTION_STAMP_RECOVERY */
    }
    /* PRODUCTION_SYNC_NOW */
}
@main enum Checks {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError(label) }
        count += 1
    }
    @MainActor static func settle() async { for _ in 0..<100 { await Task.yield() } }
    @MainActor static func run() async {
        let successful = TestView(); successful.syncNote = "earlier failure"
        successful.begin(); await settle()
        check(successful.syncNote == nil && !successful.syncing, "successful manual receipt retires failure")
        let restore = TestView(); restore.sync.restored = false
        restore.begin(); await settle()
        check(restore.syncNote?.contains("Couldn't load") == true, "restore failure survives historical success")
        check(!restore.syncing && restore.sync.reached == 1, "restore failure cannot upload")
        let unreachable = TestView(); unreachable.sync.conflict = .unreachable
        unreachable.begin(); await settle()
        check(unreachable.syncNote?.contains("Could not reach") == true, "reachability failure survives historical success")
        check(!unreachable.syncing && unreachable.sync.reached == 2, "unreachable roster cannot upload")
        let conflict = TestView(); conflict.sync.conflict = .conflict
        conflict.begin(); await settle()
        check(conflict.showConflict && !conflict.syncing && conflict.sync.reached == 2, "conflict needs explicit resolution")
        let transport = TestView(); transport.sync.pushed = false
        transport.sync.backupUploadFailure = "live failure"
        transport.begin(); await settle()
        check(transport.syncNote == nil && transport.sync.backupUploadFailure != nil, "transport failure is not copied into a stale note")
        let local = TestView(); local.sync.pushed = false
        local.begin(); await settle()
        check(local.syncNote?.contains("still saved") == true, "local unacknowledged failure remains visible")
        for stage in 1...3 {
            let replaced = TestView(); replaced.sync.pauseAt = stage
            replaced.sync.restored = true; replaced.sync.conflict = .noConflict
            replaced.sync.pushed = false
            replaced.begin(); await settle()
            check(replaced.sync.continuation != nil, "reached awaited stage")
            CredentialScopeRegistry.shared.generation += 1
            replaced.receivedScopeChange()
            replaced.sync.continuation?.resume(); replaced.sync.continuation = nil
            await settle()
            check(replaced.syncNote == nil && !replaced.syncing && !replaced.showConflict,
                  "old account completion cannot repaint replacement session")
            check(replaced.sync.reached == stage, "old account cannot continue into another await")
        }
        let expired = TestView(); expired.begin()
        CredentialScopeRegistry.shared.generation += 1
        await settle()
        check(expired.sync.reached == 0 && !expired.syncing, "account replacement before task start is fenced")
        let stamp = TestView(); stamp.syncNote = "current failure"
        stamp.receivedNewStamp(nil)
        check(stamp.syncNote != nil, "nil stamp cannot hide failure")
        stamp.sync.synchronizationIsComplete = false
        stamp.receivedNewStamp(Date())
        check(stamp.syncNote != nil, "incomplete durable outcome cannot hide failure")
        stamp.sync.synchronizationIsComplete = true
        stamp.receivedNewStamp(Date())
        check(stamp.syncNote == nil, "new complete receipt can retire local failure")
        print("SyncSettingsOutcomeTests: \(count) checks passed; no authoritative writes")
    }
    static func main() async { await run() }
}
