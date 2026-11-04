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
    var pin: String? = nil
    var isKids = false
    // PRODUCTION_PROFILE_PIN_PRESENCE
}

// Explicit in-memory account-epoch collaborator; these cases exercise actual profile publication,
// not credential persistence or PIN verification (the picker routing suite owns verifier coverage).
@MainActor private final class CredentialScopeRegistry {
    struct Capture: Equatable, Sendable { let generation: Int }
    static let shared = CredentialScopeRegistry()
    private let generation = 0
    func capture() -> Capture { .init(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { capture.generation == generation }
}

@MainActor private final class SelectionHarness: ObservableObject {
    // PRODUCTION_PROFILE_SELECTION_OBSERVERS
    // PRODUCTION_MANUAL_PICKER_STATE
    // PRODUCTION_PICKER_REQUIREMENT
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

        // Actual Published setters and original manual request code. Direct capability activation
        // is fixture setup only; actual PIN input/verification remains in the routing suite.
        var protected = first; protected.pin = "fixture-stored-pin"
        harness.replace([protected]); harness.select(a); harness.requestPicker()
        let metadataGrant = harness.pickerPresentation()
        check(metadataGrant.unlockPIN?() == true, "setup protected original request")
        var metadata = protected; metadata.name = "Cosmetic rename"
        metadata.discovery = .init(continueWatchingSource: "trakt", continueWatchingWindow: "90")
        harness.update(metadata)
        check(metadataGrant.permitsPresentation() && metadataGrant.permitsTools(),
              "name and discovery metadata retain the exact unlocked manual request")

        for change in ["pin", "removed-pin", "kids", "active", "removed-profile", "roster-count"] {
            harness.replace([protected]); harness.select(a); harness.requestPicker()
            let original = harness.pickerPresentation()
            check(original.unlockPIN?() == true && original.permitsTools(), "fresh protected request before ABA")
            var invalid = protected
            // No grant/root/UI reads occur between the two actual setter publications.
            switch change {
            case "pin":
                invalid.pin = "fixture-other-pin"; harness.update(invalid); harness.update(protected)
            case "removed-pin":
                invalid.pin = nil; harness.update(invalid); harness.update(protected)
            case "kids":
                invalid.isKids = true; harness.update(invalid); harness.update(protected)
            case "active":
                harness.select(b); harness.select(a)
            case "removed-profile":
                harness.replace([]); harness.replace([protected])
            case "roster-count":
                harness.replace([protected, second]); harness.replace([protected])
            default: preconditionFailure()
            }
            check(!original.permitsPresentation() && !original.permitsTools() && original.unlockPIN?() == false,
                  "actual publication retires unobserved eligible-ineligible-eligible " + change)
            check(!harness.needsPicker, "revoked manual route cannot fall back to ordinary mode")
            harness.requestPicker()
            let fresh = harness.pickerPresentation()
            check(fresh.permitsPresentation() && fresh.unlockPIN?() == true && fresh.permitsTools()
                  && !original.permitsTools(), "only a fresh explicit request can retry after " + change)
        }

        harness.replace([first]); harness.select(a); harness.requestPicker()
        let unprotectedGrant = harness.pickerPresentation()
        harness.update(protected); harness.update(first)
        check(!unprotectedGrant.permitsTools(), "adding then removing a PIN retires an unprotected manual route")
        harness.replace([]); harness.select(nil); harness.requestPicker()
        let emptyGrant = harness.pickerPresentation()
        harness.select(a); harness.select(nil)
        check(!emptyGrant.permitsTools(), "empty route cannot revive after transient stale active ID")

        harness.replace([protected]); harness.select(a); harness.requestPicker()
        let publicationGrant = harness.pickerPresentation()
        check(publicationGrant.unlockPIN?() == true, "setup subscriber boundary")
        var subscriberRan = false
        let manualObserver = harness.$profiles.dropFirst().sink { _ in
            guard !subscriberRan else { return }
            subscriberRan = true
            check(harness.profiles.first?.pin == protected.pin,
                  "real Published callback still sees outgoing stored values")
            check(!publicationGrant.permitsTools(), "invalid proposal retires before synchronous subscriber use")
            harness.requestPicker()
            check(!harness.pickerPresentation().permitsPresentation(),
                  "subscriber cannot mint a replacement from intermediate outgoing values")
        }
        var changedPIN = protected; changedPIN.pin = "fixture-published-pin"
        harness.update(changedPIN)
        manualObserver.cancel()
        harness.update(protected)
        check(subscriberRan && !publicationGrant.permitsTools(), "subscriber boundary remains retired after ABA")
        harness.requestPicker()
        let nestedGrant = harness.pickerPresentation()
        check(nestedGrant.unlockPIN?() == true, "publication depth balanced for a fresh request")
        var nestedManualSelection = false
        let nestedManualObserver = harness.$profiles.dropFirst().sink { _ in
            guard !nestedManualSelection else { return }
            nestedManualSelection = true
            harness.select(b); harness.select(a)
        }
        harness.update(metadata)
        nestedManualObserver.cancel()
        check(nestedManualSelection && !nestedGrant.permitsTools(),
              "nested active-ID ABA retires original during a cosmetic outer publication")
        harness.requestPicker()
        check(harness.pickerPresentation().permitsPresentation(), "nested publication releases only its own depth")
        print("Profile selection: \(checks) checks passed with actual Combine publication/reentry, manual request retirement, initializer finish and checked worker reads. Full owner/native integration remains separate.")
    }
}
