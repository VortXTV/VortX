// Executable harness for the producer-lead pause/resume hysteresis decision (root-cause report section 6).
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/producer-lead-policy-test \
//     app/Sources/Player/VortXRemuxProducerLeadPolicy.swift \
//     app/Tests/VortXRemuxProducerLeadPolicyTests.swift && /tmp/producer-lead-policy-test
//
// Pure policy harness: no threads, no NSCondition timing. It only checks the boundary/hysteresis MATH the
// concurrency gate delegates to, plus the gate's pause/resume/cancel state machine on the main thread (no
// blocking calls exercised here - `waitAtClosedSegmentBoundaryIfPaused` would hang a single-threaded harness
// while genuinely paused, so this suite only calls it in states proven not to block).

import Foundation

@MainActor private var failures = 0

@MainActor private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

@main
@MainActor
enum VortXRemuxProducerLeadPolicyTests {
    static func main() {
        staysUnpausedBelowThePauseThreshold()
        pausesAtExactlyTheThreshold()
        staysPausedInsideTheHysteresisBand()
        resumesOnlyOnceBelowTheResumeThreshold()
        nonFiniteLeadFailsClosedToCurrentState()
        boundaryConstantsHaveARealHysteresisGap()
        gateStartsUnpausedAndTracksSetPaused()
        gateSetPausedIsIdempotent()
        gateCancelForcesUnpausedAndSticks()

        print("===== FAILURES: \(failures) =====")
        exit(failures == 0 ? 0 : 1)
    }

    static func staysUnpausedBelowThePauseThreshold() {
        check("59s lead stays unpaused",
              !VortXRemuxProducerLeadPolicy.shouldPauseProducer(leadSeconds: 59, currentlyPaused: false))
        check("89.9s lead stays unpaused (just under the pause line)",
              !VortXRemuxProducerLeadPolicy.shouldPauseProducer(leadSeconds: 89.9, currentlyPaused: false))
    }

    static func pausesAtExactlyTheThreshold() {
        check("90s lead pauses (>= pauseAheadSeconds)",
              VortXRemuxProducerLeadPolicy.shouldPauseProducer(leadSeconds: 90, currentlyPaused: false))
        check("120s lead pauses",
              VortXRemuxProducerLeadPolicy.shouldPauseProducer(leadSeconds: 120, currentlyPaused: false))
    }

    static func staysPausedInsideTheHysteresisBand() {
        // 60-90s is the band: once paused, staying anywhere in it must NOT resume yet.
        check("75s lead stays paused if already paused",
              VortXRemuxProducerLeadPolicy.shouldPauseProducer(leadSeconds: 75, currentlyPaused: true))
        check("60.1s lead stays paused if already paused",
              VortXRemuxProducerLeadPolicy.shouldPauseProducer(leadSeconds: 60.1, currentlyPaused: true))
        check("exactly 60s still counts as paused (resume is STRICTLY below)",
              VortXRemuxProducerLeadPolicy.shouldPauseProducer(leadSeconds: 60, currentlyPaused: true))
    }

    static func resumesOnlyOnceBelowTheResumeThreshold() {
        check("59.9s lead resumes",
              !VortXRemuxProducerLeadPolicy.shouldPauseProducer(leadSeconds: 59.9, currentlyPaused: true))
        check("0s lead resumes",
              !VortXRemuxProducerLeadPolicy.shouldPauseProducer(leadSeconds: 0, currentlyPaused: true))
    }

    static func nonFiniteLeadFailsClosedToCurrentState() {
        check("NaN lead leaves an unpaused producer unpaused",
              !VortXRemuxProducerLeadPolicy.shouldPauseProducer(leadSeconds: .nan, currentlyPaused: false))
        check("NaN lead leaves a paused producer paused (never silently lifts a real pause)",
              VortXRemuxProducerLeadPolicy.shouldPauseProducer(leadSeconds: .nan, currentlyPaused: true))
        check("+infinity lead leaves current state alone too",
              VortXRemuxProducerLeadPolicy.shouldPauseProducer(leadSeconds: .infinity, currentlyPaused: false)
                  == false)
    }

    static func boundaryConstantsHaveARealHysteresisGap() {
        check("resume threshold is strictly below the pause threshold (no every-cycle oscillation)",
              VortXRemuxProducerLeadPolicy.resumeBelowSeconds < VortXRemuxProducerLeadPolicy.pauseAheadSeconds)
        check("pause threshold is exactly 90s per the recovery policy",
              VortXRemuxProducerLeadPolicy.pauseAheadSeconds == 90)
        check("resume threshold is exactly 60s per the recovery policy",
              VortXRemuxProducerLeadPolicy.resumeBelowSeconds == 60)
    }

    static func gateStartsUnpausedAndTracksSetPaused() {
        let gate = VortXRemuxProducerLeadGate()
        check("gate starts unpaused", !gate.isPaused)
        gate.setPaused(true)
        check("gate reports paused after setPaused(true)", gate.isPaused)
        gate.setPaused(false)
        check("gate reports unpaused after setPaused(false)", !gate.isPaused)
    }

    static func gateSetPausedIsIdempotent() {
        let gate = VortXRemuxProducerLeadGate()
        gate.setPaused(true)
        gate.setPaused(true)
        check("repeated setPaused(true) stays paused", gate.isPaused)
    }

    static func gateCancelForcesUnpausedAndSticks() {
        let gate = VortXRemuxProducerLeadGate()
        gate.setPaused(true)
        gate.cancel()
        check("cancel() forces isPaused false even from a paused state", !gate.isPaused)
        gate.setPaused(true)
        check("setPaused(true) after cancel() is a no-op (never re-parks a torn-down session)", !gate.isPaused)
    }
}
