import Foundation
import OSLog

// The runner inserts actual production policy, completion gate and both chrome methods. No engine,
// network, SwiftUI/AppKit/UIKit loop or real persistence is created by these deterministic replays.
/* __PRODUCTION_POLICY__ */
/* __PRODUCTION_COMPLETION__ */

typealias PlayerLoadToken = Int
enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }
enum TerminalAction { case handleCommitted, handlePending, markSupersededTerminal, ignoreOutgoingError, ignoreStale, persistOutgoingCompletionOnly }
enum TerminalKind { case error }
class Player { var activeLoadToken: Int? = 2 }
final class MPVMetalViewController: Player {
    var park = SeekEOFTerminalParkPolicy<Int>()
    func parkAfterExhaustedSeekEOF(_ exhaustion: SeekEOFRecoveryExhaustion) {
        if let owner = activeLoadToken { park.park(owner: owner, pausedIntent: false) }
    }
}
final class Coordinator { var player: Player? = MPVMetalViewController() }
struct Pending { var terminal = false }
struct Superseded { var pending = Pending() }

@MainActor class ChromeFixture {
    let coordinator = Coordinator()
    var route = TerminalAction.handleCommitted
    var effectivelyLive = false, isCurrentLiveStream = false, isTrailer = false
    var currentPickWasExplicit = true, currentPlaybackIsResume = false
    var hasStartedPlaying = true, reconnecting = true
    var midPlayFailureOwner: Int?, midPlayFailureResume: Double?
    var resumeSeconds = 0.0, resumeIsMidPlayRecovery = false
    var currentTime = 2499.0, loadErrorMsg = ""
    var autoRetryTask: Task<Void,Never>?, loadTimeout: Task<Void,Never>?, recoveryDeadline: Task<Void,Never>?
    var completionEvidence = PlaybackCompletionEvidence<Int>()
    var pendingAdvance: Pending?, supersededAdvance: Superseded?, uncommittedIdentityBlocked = false
    var ordinaryMidPlayCalls = 0, ordinaryStartupCalls = 0, hops = 0, overlays = 0
    var alternateAvailable = true, hoppedResume: Double?
    func terminalAction(for token: Int?, kind: TerminalKind) -> TerminalAction { route }
    func retryResumeTarget(confirmedPositionOverride: Double? = nil) -> Double { confirmedPositionOverride ?? currentTime }
    func recoveryResumeTarget(confirmedPositionOverride: Double? = nil) -> Double { confirmedPositionOverride ?? currentTime }
    func hopToNextSource(reason: String, resumeOverride: Double?) -> Bool {
        hops += 1; hoppedResume = resumeOverride
        return alternateAvailable
    }
    func presentTerminalLoadFailure() { overlays += 1 }
    func handleMidPlayFailure(_ message: String, loadToken: Int?, resumeOverride: Double? = nil) { ordinaryMidPlayCalls += 1 }
    func handleLoadFailure(_ message: String) { ordinaryStartupCalls += 1 }
}
@MainActor final class SharedChrome: ChromeFixture {
    /* __PRODUCTION_SHARED_METHODS__ */
}
@MainActor final class TVChrome: ChromeFixture {
    /* __PRODUCTION_TV_METHODS__ */
}
/* __BASELINE_WITNESS__ */
/* __CONTROLLER_EXTRACTION_REPLAYS__ */

@main struct SeekEOFRecoveryReplayTests {
    @MainActor static func main() async {
        var failures = 0, checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        func restored(_ owner: Int, _ replacement: Int, _ target: Double = 2497.479) -> SeekEOFRecoveryPolicy<Int> {
            var policy = SeekEOFRecoveryPolicy<Int>()
            policy.begin(owner: owner, target: target, wasPaused: false, duration: 2608, origin: .viewer, now: 100)
            _ = policy.observeSeek(owner: owner)
            policy.observePosition(owner: owner, position: target + 0.016, now: 100.1)
            check(policy.shouldRecoverEOF(owner: owner, now: 104), "observed owned mid-file seek admits one reopen")
            _ = policy.consumeEOFForReload(owner: owner)
            _ = policy.adoptReload(owner: replacement)
            _ = policy.beginReloadSeek(owner: replacement)
            _ = policy.observeSeek(owner: replacement)
            check(policy.completeReloadAtPosition(owner: replacement, position: target + 0.016) != nil,
                  "owned attributed restored landing finishes transport transaction")
            return policy
        }
        func seed(_ view: ChromeFixture, position: Double, duration: Double? = 2608) {
            view.completionEvidence.begin(owner: 2, mountGeneration: 0)
            view.completionEvidence.recordPosition(position, owner: 2)
            if let duration { view.completionEvidence.recordDuration(duration, owner: 2) }
        }

        // Incident A: target2499, internal reopen times out. It has already consumed the one retry;
        // cancelling transport bookkeeping must not erase the queued failure's ownership receipt.
        var timeout = SeekEOFRecoveryPolicy<Int>()
        timeout.begin(owner: 1, target: 2499, wasPaused: false, duration: 2608, origin: .viewer, now: 0)
        _ = timeout.observeSeek(owner: 1)
        timeout.observePosition(owner: 1, position: 2499, now: 0.1)
        _ = timeout.consumeEOFForReload(owner: 1)
        _ = timeout.adoptReload(owner: 2)
        let timeoutFailure = timeout.exhaustion(owner: 2, reason: "same-source reopen did not restore target")!
        timeout.cancel(owner: 2)
        check(timeout.acceptsExhaustion(timeoutFailure, owner: 2), "timeout retains exact spent attempt through queued delivery")
        check(!timeout.acceptsExhaustion(timeoutFailure, owner: 1), "old source cannot accept replacement exhaustion")
        let timeoutShared = SharedChrome()
        check(timeoutShared.handleExhaustedSeekEOFRecovery(timeoutFailure, loadToken: 2), "shared chrome handles proven timeout")
        check(timeoutShared.overlays == 1 && timeoutShared.hops == 0 && timeoutShared.ordinaryStartupCalls == 0,
              "explicit pick timeout exposes choice without another same-source reload")
        check(timeoutShared.midPlayFailureResume == 2499 && timeoutShared.currentTime == 2499,
              "timeout preserves resume intent without overwriting observed progress")
        check((timeoutShared.coordinator.player as? MPVMetalViewController)?.park.owner == 2,
              "timeout terminal branch parks reusable MPV instead of playing behind overlay")
        let timeoutTV = TVChrome()
        check(timeoutTV.handleExhaustedSeekEOFRecovery(timeoutFailure, loadToken: 2), "TV chrome handles proven timeout")
        check(timeoutTV.overlays == 1 && timeoutTV.resumeSeconds == 2499 && timeoutTV.resumeIsMidPlayRecovery,
              "TV timeout retains exact resume target and explicit source choice")

        // Incident B:2497.479 -> restored2497.495 -> EOF2498.579 after about4seconds.
        var repeatEOF = restored(1, 2)
        repeatEOF.observeRecoveredProgress(owner: 2, position: 2497.495, now: 111.644, settled: true)
        repeatEOF.observeRecoveredProgress(owner: 2, position: 2498.579, now: 115.551, settled: true)
        let repeated = repeatEOF.exhaustion(owner: 2, reason: "source ended again after its seek reopen")!
        check(repeatEOF.current == nil && repeated.target == 2497.479,
              "a first restored frame does not replenish the same seek's reopen budget")
        var maintenance = repeatEOF
        maintenance.begin(owner: 2, target: 2498.579, wasPaused: false, duration: 2608,
                          origin: .cacheReanchor, now: 116)
        _ = maintenance.observeSeek(owner: 2)
        maintenance.observePosition(owner: 2, position: 2498.579, now: 116.1)
        check(!maintenance.shouldRecoverEOF(owner: 2, now: 116.2)
                && maintenance.acceptsExhaustion(repeated, owner: 2),
              "cache maintenance cannot replenish a spent viewer recovery budget")
        let shared = SharedChrome(); seed(shared, position: 2498.579)
        check(shared.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: repeated), "shared completion gate rejects incident EOF")
        check(shared.overlays == 1 && shared.hops == 0 && shared.ordinaryMidPlayCalls == 0,
              "restored-then-EOF cannot nest the shared mid-play retry ladder")
        check(shared.midPlayFailureResume == 2498.579 && shared.currentTime == 2499,
              "repeated EOF parks observed completion evidence without progress deletion")
        let tv = TVChrome(); seed(tv, position: 2498.579)
        check(tv.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: repeated), "TV completion gate rejects incident EOF")
        check(tv.overlays == 1 && tv.hops == 0 && tv.ordinaryMidPlayCalls == 0 && tv.resumeSeconds == 2498.579,
              "TV repeated EOF exposes explicit choice and preserves actual last position")
        let missingSharedDuration = SharedChrome(); seed(missingSharedDuration, position: 2498.579, duration: nil)
        check(missingSharedDuration.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: repeated)
                && missingSharedDuration.overlays == 1 && missingSharedDuration.ordinaryMidPlayCalls == 0,
              "shared finite source receipt blocks early EOF before replacement duration arrives")
        let missingTVDuration = TVChrome(); seed(missingTVDuration, position: 2498.579, duration: nil)
        check(missingTVDuration.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: repeated)
                && missingTVDuration.overlays == 1 && missingTVDuration.ordinaryMidPlayCalls == 0,
              "TV finite source receipt blocks early EOF before replacement duration arrives")

        let automatic = SharedChrome(); automatic.currentPickWasExplicit = false; seed(automatic, position: 2498.579)
        _ = automatic.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: repeated)
        check(automatic.hops == 1 && automatic.overlays == 0 && automatic.hoppedResume == 2498.579,
              "automatic playback may choose one bounded alternate for the same episode")
        check((automatic.coordinator.player as? MPVMetalViewController)?.park.owner == nil,
              "successful automatic alternate is not terminal-parked")
        let resume = TVChrome(); resume.currentPlaybackIsResume = true; seed(resume, position: 2498.579)
        _ = resume.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: repeated)
        check(resume.hops == 1 && resume.overlays == 0, "saved resume retains existing automatic alternate-source policy")
        let none = SharedChrome(); none.currentPickWasExplicit = false; none.alternateAvailable = false
        _ = none.handleExhaustedSeekEOFRecovery(timeoutFailure, loadToken: 2)
        check(none.hops == 1 && none.overlays == 1, "missing alternate ends on choice instead of reopening failed region")

        // Settled progress, not elapsed buffering/paused time, earns a later independent retry.
        var healthy = restored(1, 2, 200)
        healthy.observeRecoveredProgress(owner: 2, position: 200.016, now: 1, settled: true)
        healthy.observeRecoveredProgress(owner: 2, position: 200.016, now: 1000, settled: true)
        check(healthy.exhaustion(owner: 2, reason: "paused") != nil, "paused wall time does not replenish recovery")
        healthy.observeRecoveredProgress(owner: 2, position: 800, now: 1001, settled: false)
        healthy.observeRecoveredProgress(owner: 99, position: 800, now: 1001, settled: true)
        check(healthy.exhaustion(owner: 2, reason: "unowned") != nil, "unsettled and stale-owner positions cannot prove healing")
        for second in 1...31 {
            healthy.observeRecoveredProgress(owner: 2, position: 200.016 + Double(second), now: 1000 + Double(second), settled: true)
        }
        check(healthy.exhaustion(owner: 2, reason: "later failure") == nil,
              "thirty seconds of actual settled forward progress retire exhausted classification")
        check(!healthy.acceptsExhaustion(repeated, owner: 2), "retired receipt rejects previously queued exhaustion")
        let later = SharedChrome(); seed(later, position: 1200)
        check(later.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: nil) && later.ordinaryMidPlayCalls == 1,
              "unrelated later source failure keeps ordinary recovery after healing")

        // An explicit new seek is a new intent even though the source token is the same.
        var newer = repeatEOF
        _ = newer.supersedeForNewExplicitSeek()
        check(!newer.acceptsExhaustion(repeated, owner: 2), "explicit supersession immediately retires queued same-file exhaustion")
        newer.begin(owner: 2, target: 600, wasPaused: true, duration: 2608, origin: .viewer, now: 200)
        check(!newer.acceptsExhaustion(repeated, owner: 2), "new seek transport generation cannot inherit old failure")
        _ = newer.observeSeek(owner: 2); newer.observePosition(owner: 2, position: 600, now: 200.1)
        check(newer.shouldRecoverEOF(owner: 2, now: 200.2), "deliberate new seek earns its own bounded attempt")
        newer.reset()
        check(newer.exhaustion(owner: 2, reason: "old source") == nil && !newer.acceptsExhaustion(repeated, owner: 2),
              "accepted Retry/new source/episode resets the old source domain")
        var park = SeekEOFTerminalParkPolicy<Int>()
        park.park(owner: 2, pausedIntent: false)
        check(park.owner == 2 && park.pausedIntent == false, "terminal park preserves original playing intent")
        check(park.updateIntent(paused: true) && park.pausedIntent == true,
              "Pause while terminal-parked updates intent without releasing park")
        check(park.updateIntent(paused: false) && park.owner == 2,
              "Play while terminal-parked records intent while keeping source parked")
        check(park.owner == 2, "refused fresh load has no authority to release terminal park")
        check(park.acceptedFreshLoad() == false && park.owner == nil,
              "accepted Retry releases park with viewer's latest playing intent")
        park.park(owner: 3, pausedIntent: true)
        check(park.acceptedFreshLoad() == true, "accepted source replacement retains prior paused intent")

#if BASELINE_WITNESS
        var old = BaselineSeekEOFRecoveryPolicy<Int>()
        old.begin(owner: 1, target: 2497.479, wasPaused: false, duration: 2608, origin: .viewer, now: 100)
        _ = old.observeSeek(owner: 1); old.observePosition(owner: 1, position: 2497.495, now: 100.1)
        _ = old.consumeEOFForReload(owner: 1); _ = old.adoptReload(owner: 2)
        _ = old.beginReloadSeek(owner: 2); _ = old.observeSeek(owner: 2)
        _ = old.completeReloadAtPosition(owner: 2, position: 2497.495)
        let oldView = BaselineSharedChrome(); seed(oldView, position: 2498.579)
        _ = oldView.rejectPrematureEOFIfNeeded(loadToken: 2)
        let forbiddenOuterRetry = oldView.ordinaryMidPlayCalls
        print("BASELINE_EXPECTED_RED sameSourceOuterRetries=\(forbiddenOuterRetry) restoredReceiptCleared=\(old.current == nil)")
        check(old.current == nil && forbiddenOuterRetry == 1,
              "actual old policy and UI gateway reproduce nested retry shape without missing-symbol failures")
#endif

        for route in [TerminalAction.handlePending, .ignoreOutgoingError, .ignoreStale, .persistOutgoingCompletionOnly] {
            let outgoing = SharedChrome(); outgoing.route = route
            check(!outgoing.handleExhaustedSeekEOFRecovery(repeated, loadToken: 2)
                    && outgoing.hops == 0 && outgoing.overlays == 0,
                  "uncommitted/outgoing routing cannot borrow committed seek failure")
        }
        let stale = SharedChrome()
        check(!stale.handleExhaustedSeekEOFRecovery(repeated, loadToken: 1) && stale.overlays == 0,
              "stale source failure cannot alter active player")
        let pending = SharedChrome(); pending.route = .handlePending; pending.pendingAdvance = Pending(); seed(pending, position: 2498.579)
        _ = pending.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: repeated)
        check(pending.pendingAdvance?.terminal == true && pending.uncommittedIdentityBlocked && pending.ordinaryStartupCalls == 1,
              "pending episode retains original terminal/recovery ownership")

        let natural = SharedChrome(); seed(natural, position: 2607)
        check(!natural.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: repeated) && natural.overlays == 0,
              "normal EOF after real near-end progress retains completion semantics")
        let nearEndWithoutDuration = SharedChrome(); seed(nearEndWithoutDuration, position: 2607, duration: nil)
        check(!nearEndWithoutDuration.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: repeated)
                && nearEndWithoutDuration.overlays == 0,
              "finite duration fallback still permits actually observed near-end completion")
        let actualDurationWins = SharedChrome(); seed(actualDurationWins, position: 2509, duration: 2510)
        check(!actualDurationWins.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: repeated),
              "actual current owned duration takes precedence over fallback source metadata")
        let live = SharedChrome(); live.effectivelyLive = true; seed(live, position: 2498.579)
        check(!live.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: repeated) && live.overlays == 0,
              "live EOF semantics remain unchanged")
        let trailer = TVChrome(); trailer.isTrailer = true; seed(trailer, position: 2498.579)
        check(!trailer.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: repeated) && trailer.overlays == 0,
              "trailer EOF semantics remain unchanged")
        let unknown = SharedChrome(); seed(unknown, position: 2498.579, duration: nil)
        check(!unknown.rejectPrematureEOFIfNeeded(loadToken: 2, seekEOF: nil) && unknown.overlays == 0,
              "genuinely unknown-duration source has no finite receipt and keeps EOF semantics")
        await runControllerExtractionReplays(check)
        print("SEEK_EOF_REPLAY_CHECKS=\(checks) FAILURES=\(failures)")
        if failures > 0 { exit(1) }
    }
}
