// RUN through scripts/test-move-seeding-status.sh. The script injects the real
// SyncSettingsView.syncNow implementation into the MainActor harness before compiling.

import Foundation

@MainActor
final class VortXSyncManager {
    static let shared = VortXSyncManager()

    enum RosterResult {
        case conflict
        case unreachable
        case noConflict
    }

    var hasCompletedFirstSync = false
    var pendingSettingsMessage: String?
    var synchronizationIsComplete = false
    var lastSyncAt: Date?
    var rosterResult: RosterResult = .noConflict
    var pushResult = true
    private(set) var pushCalls = 0

    func rosterConflictWithAccount() async -> RosterResult {
        await Task.yield()
        return rosterResult
    }

    @discardableResult
    func pushThisDevice() async -> Bool {
        await Task.yield()
        pushCalls += 1
        return pushResult
    }
}

@MainActor
final class ProfileStore {
    static let shared = ProfileStore()
    var needsPicker = false
}

@main
@MainActor
struct MoveSeedingStatusTests {
    private static var failures = 0

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS: \(name)")
        } else {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    private static func settle(_ harness: SyncSettingsViewStatusHarness) async {
        var started = false
        for _ in 0..<100 {
            await Task.yield()
            if harness.syncing {
                started = true
                break
            }
        }
        check("SyncSettingsView.syncNow starts its operation", started)
        for _ in 0..<100 where harness.syncing {
            await Task.yield()
        }
        check("SyncSettingsView.syncNow finishes its operation", !harness.syncing)
    }

    private static func testBackedUpLineStates() {
        let backup = "Your data is backed up to your VortX account."
        let pending = "Some changes still need to sync."
        let waiting = "Waiting for the first sync to finish…"

        check(
            "complete sync shows the backup claim",
            MoveSeeding.backedUpLine(synchronizationIsComplete: true, pendingSettingsMessage: nil) == backup
        )
        check(
            "pending settings replace the backup claim",
            MoveSeeding.backedUpLine(synchronizationIsComplete: false, pendingSettingsMessage: pending) == pending
        )
        check(
            "pending settings win even over a contradictory complete flag",
            MoveSeeding.backedUpLine(synchronizationIsComplete: true, pendingSettingsMessage: pending) == pending
        )
        check(
            "no accepted sync uses the waiting fallback",
            MoveSeeding.backedUpLine(synchronizationIsComplete: false, pendingSettingsMessage: nil) == waiting
        )
        check(
            "an empty pending message still uses the waiting fallback",
            MoveSeeding.backedUpLine(synchronizationIsComplete: false, pendingSettingsMessage: "") == waiting
        )
        check("last-sync line stays truthful without an accepted timestamp", MoveSeeding.lastSyncLine(nil) == waiting)
        check("last-sync line reports a current accepted timestamp", MoveSeeding.lastSyncLine(Date()) == "Last synced just now")
    }

    private static func testSyncNowStates() async {
        let pushFailure = SyncSettingsViewStatusHarness()
        pushFailure.sync.rosterResult = .noConflict
        pushFailure.sync.pushResult = false
        pushFailure.syncNote = "Previous sync problem"
        pushFailure.syncNow()
        await settle(pushFailure)
        check(
            "a false push keeps a visible failure",
            pushFailure.syncNote == "Could not save your latest changes. Check your connection and try again."
        )
        check("a no-conflict push calls the manager once", pushFailure.sync.pushCalls == 1)

        let networkFailure = SyncSettingsViewStatusHarness()
        networkFailure.sync.rosterResult = .unreachable
        networkFailure.syncNote = "Previous sync problem"
        networkFailure.syncNow()
        await settle(networkFailure)
        check(
            "an unreachable account keeps a visible failure",
            networkFailure.syncNote == "Could not reach VortX sync. Check your connection and try again."
        )
        check("an unreachable account does not push", networkFailure.sync.pushCalls == 0)

        let successfulPush = SyncSettingsViewStatusHarness()
        successfulPush.sync.rosterResult = .noConflict
        successfulPush.sync.pushResult = true
        successfulPush.syncNote = "Previous sync problem"
        successfulPush.syncNow()
        await settle(successfulPush)
        check("a successful no-conflict push clears the old failure", successfulPush.syncNote == nil)
    }

    static func main() async {
        testBackedUpLineStates()
        await testSyncNowStates()
        if failures > 0 {
            print("\n\(failures) MoveSeeding status test(s) FAILED.")
            exit(1)
        }
        print("\nALL PASS")
    }
}
