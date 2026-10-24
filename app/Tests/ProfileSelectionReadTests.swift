import Foundation
import Combine
import os

// RAM-only fixture. The runner inserts the actual scalar namespace, Published observers and initializer
// finish line. The surrounding roster model/startup dependencies are not the production ProfileStore.
// PRODUCTION_PROFILE_SELECTION_READ

private struct UserProfile: Sendable {
    struct Discovery: Sendable {
        var continueWatchingSource: String?
        var continueWatchingWindow: String?
    }
    let id: UUID
    var name: String
    var isOwner: Bool
    var usesOwnAccount: Bool
    var discovery: Discovery? = nil
}

@MainActor private final class SelectionHarness: ObservableObject {
    // PRODUCTION_PROFILE_SELECTION_OBSERVERS
    var retirements = 0
    var onRetire: (() -> Void)?
    var initializationReadsWereUnavailable = true

    init(_ roster: [UserProfile], selected: UUID) {
        // PRODUCTION_PROFILE_SELECTION_INIT_FINISH
        initializationReadsWereUnavailable = ProfileSelectionRead.snapshot() == nil
        replace(roster)
        initializationReadsWereUnavailable = initializationReadsWereUnavailable && ProfileSelectionRead.snapshot() == nil
        select(selected)
        initializationReadsWereUnavailable = initializationReadsWereUnavailable && ProfileSelectionRead.snapshot() == nil
    }
    func retireLegacyHistoryNotices() { retirements += 1; onRetire?() }
    func replace(_ roster: [UserProfile]) { profiles = roster }
    func select(_ id: UUID?) { activeID = id }
    func update(_ profile: UserProfile) { profiles[profiles.firstIndex { $0.id == profile.id }!] = profile }
    func storedSnapshot() -> ProfileSelectionRead.Snapshot { selectionReadSnapshot() }
}

@MainActor @main enum ProfileSelectionReadTests {
    private static var checks = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    static func main() {
        check(ProfileSelectionRead.snapshot() == nil, "no invented/default selection before initialization")
        let a = UUID(), b = UUID()
        let first = UserProfile(id: a, name: "A", isOwner: false, usesOwnAccount: false)
        let second = UserProfile(id: b, name: "B", isOwner: false, usesOwnAccount: true)
        let harness = SelectionHarness([first, second], selected: a)
        check(harness.initializationReadsWereUnavailable, "all synchronous initialization assignments remain unavailable")
        check(ProfileSelectionRead.snapshot() == harness.storedSnapshot(), "initializer finish publishes actual stored selection")
        check(ProfileSelectionRead.snapshot()?.activeProfile?.usesEngineHistory == false, "shared overlay eligibility remains a scalar fact")

        var notifications = 0
        let note = NotificationCenter.default.addObserver(forName: LegacyWatchOwnership.sessionDidChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                notifications += 1
                check(ProfileSelectionRead.snapshot() == harness.storedSnapshot(), "legacy mutation-end notification sees settled selection")
            }
        }

        var publicationReads = 0
        let rosterObserver = harness.$profiles.dropFirst().sink { _ in
            publicationReads += 1
            check(ProfileSelectionRead.snapshot() == nil, "real Combine roster subscriber cannot read proposed/intermediate selection")
        }
        var cosmetic = first; cosmetic.name = "Renamed"
        let oldLegacyEpoch = LegacyWatchOwnership.session()
        harness.update(cosmetic)
        check(publicationReads == 1, "real Published roster subscriber ran synchronously")
        check(LegacyWatchOwnership.session() == oldLegacyEpoch, "cosmetic edit preserves existing legacy authority")
        check(ProfileSelectionRead.snapshot() == harness.storedSnapshot(), "cosmetic edit republishes stored scalar values")
        rosterObserver.cancel()

        cosmetic.discovery = .init(continueWatchingSource: "trakt", continueWatchingWindow: "40")
        harness.update(cosmetic)
        check(ProfileSelectionRead.snapshot()?.activeProfile?.continueWatchingSource == "trakt",
              "stored source edit publishes acknowledged value, not a flat preference")
        check(ProfileSelectionRead.snapshot()?.activeProfile?.continueWatchingWindow == "40",
              "stored window edit publishes acknowledged value")
        check(LegacyWatchOwnership.session() == oldLegacyEpoch,
              "source/window-only edit does not retire unchanged legacy identity")

        var nestedSelection = false
        let crossObserver = harness.$profiles.dropFirst().sink { _ in
            guard !nestedSelection else { return }
            nestedSelection = true
            check(ProfileSelectionRead.snapshot() == nil, "outer roster setter retires reads before callback")
            harness.select(b)
            check(ProfileSelectionRead.snapshot() == nil, "nested selection completion cannot reopen outer roster mutation")
        }
        harness.replace([cosmetic, second])
        crossObserver.cancel()
        check(nestedSelection && ProfileSelectionRead.snapshot()?.activeID == harness.activeID && harness.activeID == b,
              "cross-property reentry publishes the actual final selection")

        var nestedSameProperty = false
        let selectionObserver = harness.$activeID.dropFirst().sink { _ in
            guard !nestedSameProperty else { return }
            nestedSameProperty = true
            check(ProfileSelectionRead.snapshot() == nil, "selection mirror closes before real Published selection callback")
            harness.select(b)
            check(ProfileSelectionRead.snapshot() == nil, "same-property nested setter cannot open the outer publication")
        }
        harness.select(a)
        selectionObserver.cancel()
        check(nestedSameProperty && ProfileSelectionRead.snapshot() == harness.storedSnapshot() && harness.activeID == a,
              "outer stored selection, not the nested proposed value, wins after Published reentry")

        var retiredReentry = false
        harness.onRetire = {
            guard !retiredReentry else { return }
            retiredReentry = true
            check(ProfileSelectionRead.snapshot() == nil, "notice retirement does not open selection early")
            harness.select(b)
            check(ProfileSelectionRead.snapshot() == nil, "notice callback reentry remains within outer depth")
        }
        var own = cosmetic; own.usesOwnAccount = true
        harness.update(own)
        harness.onRetire = nil
        check(retiredReentry && ProfileSelectionRead.snapshot() == harness.storedSnapshot() && harness.activeID == b,
              "retirement callbacks finish before actual final scalar publication")

        let workerRead = OSAllocatedUnfairLock(initialState: Optional<Bool>.none)
        let workerDone = DispatchSemaphore(value: 0)
        let workerObserver = harness.$profiles.dropFirst().sink { _ in
            DispatchQueue.global(qos: .utility).async {
                workerRead.withLock { $0 = ProfileSelectionRead.snapshot() == nil }
                workerDone.signal()
            }
            check(workerDone.wait(timeout: .now() + 5) == .success, "worker can read without a lock held across Published callback")
        }
        harness.replace([own, second])
        workerObserver.cancel()
        check(workerRead.withLock { $0 } == true, "worker observes unavailable throughout synchronous mutation")

        harness.select(a)
        harness.replace([second])
        check(ProfileSelectionRead.snapshot()?.activeID == a && ProfileSelectionRead.snapshot()?.activeProfile == nil,
              "removed selected roster member stays explicitly absent; no default or other profile substituted")
        harness.replace([own, second])
        check(ProfileSelectionRead.snapshot()?.activeProfile?.usesOwnAccount == true, "same-ID restoration publishes actual eligibility")
        harness.select(b); harness.select(a)
        check(ProfileSelectionRead.snapshot() == harness.storedSnapshot(), "selection A-B-A carries current values, not new target authority")
        check(notifications > 0, "actual mutation-end notification path exercised")
        NotificationCenter.default.removeObserver(note)
        print("Profile selection: \(checks) checks passed with actual Combine publication/reentry, initializer finish and checked worker reads. Full owner/native integration remains separate.")
    }
}
