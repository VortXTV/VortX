import Foundation

// Ordinary playback fixtures have explicit non-EOF state. Production callers must supply it.
private extension MPVSeekSettlementPolicy {
    mutating func observeRestart(owner: Owner, seeking: Bool?) {
        observeRestart(owner: owner, seeking: seeking, eofReached: false)
    }
    func evidence(owner: Owner, seeking: Bool?) -> MPVSeekSettlementEvidence {
        evidence(owner: owner, seeking: seeking, eofReached: false)
    }
}

@main
enum MPVSeekSettlementPolicyTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        var policy = MPVSeekSettlementPolicy<Int>()
        policy.reset(owner: 1)
        check(policy.evidence(owner: 1, seeking: false).settled, "ordinary sample remains valid")
        let first = policy.beginIssue(owner: 1, seeking: false)!
        policy.completeIssue(first, accepted: true)
        check(!policy.evidence(owner: 1, seeking: false).settled, "command acceptance is not landing")
        policy.observeRestart(owner: 1, seeking: false)
        check(!policy.evidence(owner: 1, seeking: false).settled, "restart before SEEK is not proof")
        policy.observeSeek(owner: 1)
        check(!policy.evidence(owner: 1, seeking: false).settled, "target time-pos after SEEK is not proof")
        policy.observeRestart(owner: 1, seeking: true)
        check(!policy.evidence(owner: 1, seeking: false).settled, "still seeking cannot settle")
        policy.observeRestart(owner: 1, seeking: nil)
        check(!policy.evidence(owner: 1, seeking: false).settled, "unknown seeking cannot settle")
        policy.observeRestart(owner: 1, seeking: false)
        let landed = policy.evidence(owner: 1, seeking: false)
        check(landed.settled && landed.generation == first, "matching restart supplies proof")
        check(!policy.evidence(owner: 1, seeking: true).settled, "active seeking removes sample proof")
        check(policy.accepts(landed, owner: 1), "queued landed event initially belongs")
        check(!policy.evidence(owner: 1, seeking: false, eofReached: true).settled,
              "EOF property samples cannot confirm fallback timestamps")
        check(!policy.evidence(owner: 1, seeking: false, eofReached: nil).settled,
              "unknown EOF state fails closed even after a prior settlement")

        var eofPolicy = MPVSeekSettlementPolicy<Int>()
        eofPolicy.reset(owner: 3)
        let eofSeek = eofPolicy.beginIssue(owner: 3, seeking: false)!
        eofPolicy.completeIssue(eofSeek, accepted: true)
        eofPolicy.observeSeek(owner: 3)
        eofPolicy.observeRestart(owner: 3, seeking: false, eofReached: true)
        check(!eofPolicy.evidence(owner: 3, seeking: false).settled,
              "EOF restart must not settle a synthetic last-seek target")
        eofPolicy.observeRestart(owner: 3, seeking: false, eofReached: nil)
        check(!eofPolicy.evidence(owner: 3, seeking: false).settled,
              "unknown EOF restart must not settle")
        eofPolicy.observeRestart(owner: 3, seeking: false, eofReached: false)
        check(eofPolicy.evidence(owner: 3, seeking: false).settled,
              "non-EOF paused or audio-only restart can settle")

        let rejected = policy.beginIssue(owner: 1, seeking: false)!
        policy.completeIssue(rejected, accepted: false)
        check(policy.accepts(landed, owner: 1), "rejected command preserves prior accepted state")
        policy.completeIssue(rejected, accepted: true)
        check(policy.accepts(landed, owner: 1), "stale completion cannot resurrect rejected lease")
        check(policy.beginIssue(owner: 2, seeking: false) == nil, "wrong owner cannot acquire lease")
        let second = policy.beginIssue(owner: 1, seeking: false)!
        check(policy.beginIssue(owner: 1, seeking: false) == nil, "admission is single flight")
        policy.completeIssue(second, accepted: true)
        check(!policy.accepts(landed, owner: 1), "new command invalidates queued settled evidence")
        let third = policy.beginIssue(owner: 1, seeking: true)!
        policy.completeIssue(third, accepted: true)
        policy.observeSeek(owner: 1)
        policy.observeRestart(owner: 1, seeking: false)
        let overlap = policy.evidence(owner: 1, seeking: false)
        check(overlap.settled && !overlap.attributed, "overlap physically settles without attribution")
        policy.observeSeek(owner: 1)
        policy.observeRestart(owner: 1, seeking: false)
        check(!policy.evidence(owner: 1, seeking: false).attributed,
              "queued native seeks cannot clear overlapping-command ambiguity")
        let manual = policy.beginIssue(owner: 1, seeking: false)!
        policy.completeIssue(manual, accepted: true)
        policy.observeSeek(owner: 1)
        policy.observeRestart(owner: 1, seeking: false)
        let manualEvidence = policy.evidence(owner: 1, seeking: false)
        check(manualEvidence.settled && manualEvidence.attributed, "later manual seek recovers attribution")

        policy.reset(owner: 2)
        check(!policy.accepts(landed, owner: 1), "source replacement retires old proof")
        policy.observeSeek(owner: 1)
        policy.observeRestart(owner: 1, seeking: false)
        check(!policy.evidence(owner: 1, seeking: false).settled, "old source callbacks are inert")
        let paused = policy.beginIssue(owner: 2, seeking: true)!
        policy.completeIssue(paused, accepted: true)
        policy.observeSeek(owner: 2)
        policy.observeRestart(owner: 2, seeking: false)
        check(policy.evidence(owner: 2, seeking: false).settled,
              "paused/audio-only settlement needs neither clock advance nor video counter")
        let beforeStop = policy.evidence(owner: 2, seeking: false)
        policy.reset(owner: nil)
        check(!policy.accepts(beforeStop, owner: 2), "stop invalidates queued proof")

        let owner = PlayerLoadToken()
        let av = PlayerTimePositionEvent(seconds: 366, loadToken: owner)
        check(av.transportSettled && av.positionSettled && av.mpvSeekSettlement == nil, "AV initializer unchanged")
        let ambiguousEvent = PlayerTimePositionEvent(seconds: 99, loadToken: owner,
            mpvSeekSettlement: MPVSeekSettlementEvidence(generation: 7, settled: true, attributed: false))
        check(ambiguousEvent.positionSettled && !ambiguousEvent.transportSettled,
              "ambiguous settled sample confirms position but cannot retire resume")
        let synthetic = PlayerTimePositionEvent(
            seconds: 366, loadToken: owner,
            mpvSeekSettlement: MPVSeekSettlementEvidence(generation: 7, settled: false))
        check(!synthetic.transportSettled, "mpv target-shaped time-pos is unproven")
        var confirmed = 0.368
        if synthetic.transportSettled { confirmed = synthetic.seconds }
        let decision = DeferredResumeSeekReconciliationPolicy.abandonment(
            targetSeconds: 366, actualPositionSeconds: confirmed,
            landingToleranceSeconds: 5, watchdogStillOwnsGeneration: true)
        check(decision?.presentationSeconds == 0.368 && decision?.persistenceFloorSeconds == 366,
              "synthetic target cannot bypass abandonment or regress resume")
        let settledEvent = PlayerTimePositionEvent(
            seconds: 366, loadToken: owner,
            mpvSeekSettlement: MPVSeekSettlementEvidence(generation: 7, settled: true))
        check(settledEvent.transportSettled, "restart sample can retire resume")
        print("MPV seek settlement policy: PASS")
    }
}
