import Foundation

// The runner splices the actual Profiles.swift observer block here; these are only dependencies
// and mutation drivers, not a copied implementation of its lifecycle decisions.
private struct UserProfile {
    let id: UUID
    var name: String
    var isOwner: Bool
    var usesOwnAccount: Bool
}
private final class LegacyProfileLifecycleHarness {
    // INSERT ACTUAL LEGACY WATCH LIFECYCLE PROJECTION
    var retirements = 0
    func retireLegacyHistoryNotices() { retirements += 1 }
    func replace(_ roster: [UserProfile]) { profiles = roster }
    func select(_ id: UUID?) { activeID = id }
    func update(_ profile: UserProfile) { profiles[profiles.firstIndex { $0.id == profile.id }!] = profile }
    func editOwnAccount(_ value: Bool) { profiles[profiles.firstIndex { $0.id == activeID }!].usesOwnAccount = value }
}

enum LegacyProfileLifecycleTests {
    @MainActor static func run(root: URL) async throws {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        let a = UUID(), b = UUID()
        let shared = UserProfile(id: a, name: "A", isOwner: false, usesOwnAccount: false)
        let other = UserProfile(id: b, name: "B", isOwner: false, usesOwnAccount: false)
        let harness = LegacyProfileLifecycleHarness()
        harness.replace([shared, other]); harness.select(a)
        let initial = LegacyWatchOwnership.session(), initialRetirements = harness.retirements
        let queued = LegacyWatchOwnership.Capture(owner: 7, session: initial, profileID: a, slot: "primary", token: "A")
        var cosmetic = shared; cosmetic.name = "Renamed"
        harness.update(cosmetic)
        var inactive = other; inactive.usesOwnAccount = true
        harness.replace([cosmetic, inactive])
        check(LegacyWatchOwnership.session() == initial && harness.retirements == initialRetirements, "cosmetic and inactive-profile edits preserve active authority")
        harness.editOwnAccount(true); harness.editOwnAccount(false)
        check(LegacyWatchOwnership.session() != initial && harness.retirements == initialRetirements + 2, "actual in-place observer retires same-UUID shared-own-shared ABA")
        do {
            _ = try await LegacyWatchOwnership.perform(isCurrent: {
                queued.matches(owner: 7, session: LegacyWatchOwnership.session(), profileID: a,
                               usesEngineHistory: false, slot: "primary", token: "A")
            }) { () -> Int in preconditionFailure("Binding ABA revived queued transport") }
            preconditionFailure("Binding ABA retained authority")
        } catch is CancellationError {}
        let afterElement = LegacyWatchOwnership.session()
        var own = shared; own.usesOwnAccount = true
        harness.update(own); harness.update(shared)
        check(LegacyWatchOwnership.session() != afterElement, "actual editor-style element replacement cannot revive old epoch")
        let afterUpdate = LegacyWatchOwnership.session()
        harness.replace([own, other]); harness.replace([shared, other])
        check(LegacyWatchOwnership.session() != afterUpdate, "actual whole-roster observer covers adopt/restore/merge ABA")
        let afterRoster = LegacyWatchOwnership.session()
        var owner = shared; owner.isOwner = true
        harness.replace([owner, other]); harness.replace([shared, other])
        check(LegacyWatchOwnership.session() != afterRoster, "same-UUID owner mapping ABA retires authority")
        let afterOwner = LegacyWatchOwnership.session()
        harness.replace([other]); harness.replace([shared, other])
        check(LegacyWatchOwnership.session() != afterOwner, "active roster disappearance and restoration cannot revive authority")
        let afterRemoval = LegacyWatchOwnership.session()
        harness.select(b); harness.select(a)
        check(LegacyWatchOwnership.session() != afterRemoval, "actual activeID observer covers profile ABA")

        typealias NoticeOwner = LegacyWatchOwnership.NoticeOwner<Int>
        let session = UUID()
        let origin = NoticeOwner(owner: 7, session: session, profile: .init(id: a, isOwner: false, usesOwnAccount: false), slot: "primary", token: "A")
        let anotherAccount = NoticeOwner(owner: 8, session: session, profile: .init(id: a, isOwner: false, usesOwnAccount: false), slot: "primary", token: "B")
        let anotherProfile = NoticeOwner(owner: 7, session: session, profile: .init(id: b, isOwner: false, usesOwnAccount: false), slot: "primary", token: "A")
        let rejoined = NoticeOwner(owner: 7, session: UUID(), profile: .init(id: a, isOwner: false, usesOwnAccount: false), slot: "primary", token: "A")
        var notices = LegacyProfileRecoveryPolicy.Notices<NoticeOwner>()
        var displayChecks = 0
        check(notices.visible(matching: { _ in displayChecks += 1; return true }) == nil && displayChecks == 0,
              "empty notice presentation does not even resolve its in-memory owner")
        var display = LegacyProfileRecoveryPolicy.Notices<NoticeOwner>()
        display.inspected(.init(salvaged: [:], requiresSafeRepair: true), owner: origin)
        let displayed = display.visible(matching: {
            $0.matchesPresentation(owner: 7, session: session, profile: .init(id: a, isOwner: false, usesOwnAccount: false))
        })
        check(displayed == LegacyProfileRecoveryPolicy.recoveryNotice, "unchanged process-local display binding positive control")
        check(display.visible(matching: {
            $0.matchesPresentation(owner: 8, session: session, profile: .init(id: a, isOwner: false, usesOwnAccount: false))
        }) == nil, "display rejects account-generation change without a backend read")
        check(display.visible(matching: {
            $0.matchesPresentation(owner: 7, session: UUID(), profile: .init(id: a, isOwner: false, usesOwnAccount: false))
        }) == nil, "display rejects credential/session ABA without a backend read")
        check(display.visible(matching: {
            $0.matchesPresentation(owner: 7, session: session, profile: .init(id: a, isOwner: false, usesOwnAccount: true))
        }) == nil, "display rejects same-profile account-binding change without a backend read")
        notices.inspected(.init(salvaged: [:], requiresSafeRepair: true), owner: origin)
        notices.inspected(.unavailable, owner: origin)
        check(notices.visible(for: origin) == LegacyProfileRecoveryPolicy.recoveryNotice, "same-origin unavailable scan preserves unresolved recovery warning")
        check(notices.visible(for: anotherAccount) == nil && notices.visible(for: anotherProfile) == nil && notices.visible(for: rejoined) == nil, "already-published warning is hidden for another account/profile/session")
        notices.inspected(.unavailable, owner: anotherAccount)
        check(notices.visible(for: anotherAccount) == nil && notices.visible(for: origin) == nil, "new binding retires old status; returning to A cannot resurrect it")
        notices.mirrored(.capacity, owner: origin)
        notices.mirrored(.unavailable, owner: origin)
        check(notices.visible(for: origin) == LegacyProfileRecoveryPolicy.mirrorNotice && notices.visible(for: anotherProfile) == nil, "failed mirror retains only originating profile capacity warning")
        notices.inspected(.init(salvaged: [:], requiresSafeRepair: true), owner: origin)
        notices.mirrored(.offered, owner: origin)
        check(notices.visible(for: origin) == LegacyProfileRecoveryPolicy.recoveryNotice, "smaller mirror offer cannot clear independent recovery warning")
        notices.inspected(.init(salvaged: [:], requiresSafeRepair: false), owner: origin)
        check(notices.visible(for: origin) == nil, "clean scan plus completed smaller offer retires both independent warnings")
        for raw in ["{", "{}", "[]", "{\"result\":null}", "{\"result\":{}}", "{\"result\":[]}",
                    "{\"result\":true}", "{\"result\":{\"success\":false}}", "{\"result\":{\"success\":null}}",
                    "{\"result\":{\"success\":1}}", "{\"result\":{\"success\":0}}", "{\"result\":{\"success\":1.0}}",
                    "{\"result\":{\"success\":\"true\"}}", "{\"result\":{\"success\":\"false\"}}",
                    "{\"result\":{\"success\":[]}}", "{\"result\":{\"success\":{}}}",
                    "{\"result\":{\"success\":true},\"error\":null}", "{\"result\":{\"success\":true},\"error\":\"failed\"}",
                    "{\"result\":{\"success\":true},\"extra\":1}"] {
            let completed = LegacyProfileRecoveryPolicy.mirrorOfferCompleted(Data(raw.utf8))
            check(!completed, "only the typed Boolean-true DatastorePut contract can retire capacity: \(raw)")
            var failedNotice = LegacyProfileRecoveryPolicy.Notices<NoticeOwner>()
            failedNotice.mirrored(.capacity, owner: origin)
            failedNotice.mirrored(completed ? .offered : .unavailable, owner: origin)
            check(failedNotice.visible(for: origin) == LegacyProfileRecoveryPolicy.mirrorNotice, "every failed response preserves same-owner capacity warning")
        }
        check(LegacyProfileRecoveryPolicy.mirrorOfferCompleted(Data("{\"result\":{\"success\":true}}".utf8)), "completed non-error offer response positive control, not durability proof")

        let profiles = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/Profiles.swift"), encoding: .utf8)
        for assignment in ["profiles[index] = profile", "profiles = remote", "profiles = list", "profiles = merged"] {
            check(profiles.contains(assignment), "actual editor and replacement paths use the observed roster: \(assignment)")
        }
        let noticeStart = profiles.range(of: "var legacyHistoryRecoveryNotice: String?")!.lowerBound
        let noticeEnd = profiles.range(of: "func retireLegacyHistoryNotices()", range: noticeStart..<profiles.endIndex)!.lowerBound
        let noticeGetter = profiles[noticeStart..<noticeEnd]
        check(noticeGetter.contains("legacyHistoryNoticeState.visible(matching:") && noticeGetter.contains("expected.matchesPresentation"), "actual rendered notice uses process-local display projection")
        check(!noticeGetter.contains("currentLegacyNoticeOwner(") && !noticeGetter.contains("Keychain.") && !noticeGetter.contains("keychainAccount("), "actual notice getter performs no credential backend or slot lookup")
        let certifiedStart = profiles.range(of: "private func currentLegacyNoticeOwner()")!.lowerBound
        let certifiedEnd = profiles.range(of: "#if VORTX_NATIVE_DATA_ENGINE", range: certifiedStart..<profiles.endIndex)!.lowerBound
        check(profiles[certifiedStart..<certifiedEnd].contains("Keychain.confirmedString(slot)"), "certified credential read remains at notice capture/publication boundaries")
        check(profiles.contains("self.currentLegacyNoticeOwner() == owner"), "async inspection/mirror results cannot assign another owner status")
        let view = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/ProfilesView.swift"), encoding: .utf8)
        check(view.contains("if isNew { store.add(draft) } else { store.update(draft) }"), "real legacy editor reaches the observed update path")
        let legacyEvents = view.range(of: "// Owner changes must invalidate an already-rendered warning")!
        let eventEnd = view.range(of: "#endif", range: legacyEvents.upperBound..<view.endIndex)!.lowerBound
        let events = view[legacyEvents.lowerBound..<eventEnd]
        check(events.contains("LegacyWatchOwnership.sessionDidChange") && events.contains("VortXSyncManager.credentialScopeDidChangeNote") && events.components(separatedBy: "store.retireLegacyHistoryNotices()").count == 3, "actual rendered warning retires on both legacy and VortX credential events")
        let sync = try String(contentsOf: root.appendingPathComponent("app/SourcesShared/ProfileSync.swift"), encoding: .utf8)
        let putStart = sync.range(of: "private static func putDocument(")!.lowerBound
        let putEnd = sync.range(of: "private static func post(", range: putStart..<sync.endIndex)!.lowerBound
        let putBody = sync[putStart..<putEnd]
        check(!putBody.contains("String(data:") && !putBody.contains(".prefix(200)") && !putBody.contains("privacy:"), "actual datastorePut log boundary cannot echo response or document fields")
        let logLines = putBody.components(separatedBy: "\n").filter { $0.contains("log.") }.map { $0.trimmingCharacters(in: .whitespaces) }
        check(Set(logLines) == ["log.error(\"datastorePut result=request_failed\")", "log.info(\"datastorePut result=success\")", "log.error(\"datastorePut result=invalid_or_failed_response\")"], "actual datastorePut logs are exactly closed local outcome constants")
        check(sync.contains("let response = await putDocument") && sync.contains("LegacyProfileRecoveryPolicy.mirrorOfferCompleted(response) else { return .unavailable }"), "actual smaller mirror needs a completed non-error response before capacity retirement")
        print("Legacy lifecycle: source-extracted roster/selection observers, binding ABA, cosmetic positives, owner-scoped independent notices and response retirement passed")
    }
}
