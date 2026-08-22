// Executable harness for the producer-lead pause/resume hysteresis decision (root-cause report section 6).
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/producer-lead-policy-test \
//     app/Sources/Player/VortXRemuxBuffer.swift \
//     app/Sources/Player/VortXRemuxProducerLeadPolicy.swift \
//     app/Tests/VortXRemuxProducerLeadPolicyTests.swift && /tmp/producer-lead-policy-test
//
// Pure policy harness: no threads, no NSCondition timing. It only checks the boundary/hysteresis MATH the
// concurrency gate delegates to, plus the gate's pause/resume/cancel state machine on the main thread (no
// blocking calls exercised here - `waitAtClosedSegmentBoundaryIfPaused` would hang a single-threaded harness
// while genuinely paused, so this suite only calls it in states proven not to block).

import Foundation

/// Standalone harness stubs for the buffer's configuration and failure funnel.
struct RemoteConfig {
    struct Snapshot { let dvRemuxWindowMiB: Int }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}

enum DiagnosticsLog {
    static func log(_ tag: String, _ message: String) {}
}

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
        highThroughputProducerCannotConsumeTheRetainedWindowBudget()
        clocklessStartupStillHonoursByteReservation()
        monotonicLedgerRejectsStaleReceipts()
        anchorModeCannotBypassTheProducerGate()
        couplesPlayerTargetUnderTheCeilingAtFieldBitrate()
        leavesThirtySecondTargetWhenBudgetAffordsIt()
        unknownBitrateKeepsCurrentBehaviour()
        extremeBitrateRespectsTheViableFloor()
        coupledTargetPlusMarginNeverReachesTheCeilingAcrossFieldBitrates()
        fieldLoopSimulationOldTargetStarvesNewTargetDoesNot()

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

    static func highThroughputProducerCannotConsumeTheRetainedWindowBudget() {
        // 86,444,640 bit/s is the declared field-stream bandwidth. A 6-second segment at that rate is about
        // 64.8 MiB; a producer that checks only every playlist reload reaches the 1 GiB spool near 144 s.
        let bytesPerSecond = 86_444_640 / 8
        let segmentBytes = bytesPerSecond * 6
        var aheadBytes = 0
        var paused = false
        var producedSeconds = 0.0
        for _ in 0..<30 {
            if !paused {
                aheadBytes += segmentBytes
                producedSeconds += 6
            }
            paused = VortXRemuxProducerLeadPolicy.shouldPauseProducer(
                leadSeconds: producedSeconds,
                aheadBytes: aheadBytes,
                currentlyPaused: paused)
        }
        check("86 Mb/s producer parks before the 1 GiB session spool can freeze its tail",
              paused && aheadBytes <= VortXRemuxProducerLeadPolicy.maximumAheadBytes + segmentBytes)
        check("byte budget leaves both retained-generation windows and operating headroom intact",
              VortXRemuxProducerLeadPolicy.maximumAheadBytes
                <= VortXHLSConsumptionWindowPolicy.retainedWindowMaximumBytes)
    }

    static func anchorModeCannotBypassTheProducerGate() {
        check("anchor-on local remux drives the producer gate",
              VortXRemuxProducerLeadPolicy.shouldDriveProducerGate(
                consumptionAnchored: true, retainsFullTimeline: false, reachedEndOfStream: false))
        check("anchor-off fast producer still drives the gate before it can freeze the consumer tail",
              VortXRemuxProducerLeadPolicy.shouldDriveProducerGate(
                consumptionAnchored: false, retainsFullTimeline: false, reachedEndOfStream: false))
        check("only host retention and real EOF exempt the producer gate",
              !VortXRemuxProducerLeadPolicy.shouldDriveProducerGate(
                consumptionAnchored: false, retainsFullTimeline: true, reachedEndOfStream: false)
                && !VortXRemuxProducerLeadPolicy.shouldDriveProducerGate(
                    consumptionAnchored: false, retainsFullTimeline: false, reachedEndOfStream: true))
    }

    static func clocklessStartupStillHonoursByteReservation() {
        check("unknown playhead cannot bypass the producer byte cap",
              VortXRemuxProducerLeadPolicy.shouldPauseProducer(
                leadSeconds: .nan,
                aheadBytes: VortXRemuxProducerLeadPolicy.maximumAheadBytes,
                currentlyPaused: false))
        check("unknown playhead cannot release a byte-cap pause",
              VortXRemuxProducerLeadPolicy.shouldPauseProducer(
                leadSeconds: .nan,
                aheadBytes: VortXRemuxProducerLeadPolicy.maximumAheadBytes,
                currentlyPaused: true))
    }

    static func monotonicLedgerRejectsStaleReceipts() {
        var ledger = VortXRemuxProducerLeadLedger()
        ledger.recordProduced(.init(id: 11, end: 12, byteLength: 100))
        ledger.recordProduced(.init(id: 10, end: 6, byteLength: 100))
        ledger.recordPlayback(8)
        ledger.recordPlayback(4)
        check("producer ledger keeps the newest physical boundary", ledger.producedEnd == 12)
        check("producer ledger never rolls its consumer frontier back", ledger.playbackSeconds == 8)
        check("producer ledger retains exactly the still-ahead byte reservation", ledger.outstandingBytes == 100)
    }

    // MARK: - Player-target <-> producer-ceiling coupling (Beta 25 diag 6)

    /// The declared field-stream bandwidth from the 86 Mb/s harness above.
    private static let fieldBitsPerSecond = 86_444_640.0

    static func couplesPlayerTargetUnderTheCeilingAtFieldBitrate() {
        let budget = VortXRemuxProducerLeadPolicy.maximumAheadBytes
        let target = VortXRemuxForwardBufferCoupling.steadyStateDuration(
            aheadByteBudget: budget,
            observedBitsPerSecond: fieldBitsPerSecond,
            unconstrainedDuration: VortXRemuxForwardBufferCouplingStubs.unconstrainedSteadyStateSeconds)
        let affordableSeconds = Double(budget) * 8 / fieldBitsPerSecond
        check("field-bitrate target is capped below the unconstrained 30 s",
              target < VortXRemuxForwardBufferCouplingStubs.unconstrainedSteadyStateSeconds)
        check("field-bitrate target leaves the full safety margin under the ceiling",
              target + VortXRemuxForwardBufferCoupling.safetySeconds <= affordableSeconds)
        check("field-bitrate target never falls under one full safety margin of media",
              target >= VortXRemuxForwardBufferCoupling.minimumSteadyStateSeconds)
    }

    static func leavesThirtySecondTargetWhenBudgetAffordsIt() {
        let target = VortXRemuxForwardBufferCoupling.steadyStateDuration(
            aheadByteBudget: VortXRemuxProducerLeadPolicy.maximumAheadBytes,
            observedBitsPerSecond: 20_000_000,
            unconstrainedDuration: VortXRemuxForwardBufferCouplingStubs.unconstrainedSteadyStateSeconds)
        check("20 Mb/s stream keeps the unconstrained 30 s target", target == 30)
    }

    static func unknownBitrateKeepsCurrentBehaviour() {
        let budget = VortXRemuxProducerLeadPolicy.maximumAheadBytes
        for bps in [nil, 0.0 as Double?, .some(-1), .some(.nan), .some(.infinity)] {
            let target = VortXRemuxForwardBufferCoupling.steadyStateDuration(
                aheadByteBudget: budget,
                observedBitsPerSecond: bps,
                unconstrainedDuration: VortXRemuxForwardBufferCouplingStubs.unconstrainedSteadyStateSeconds)
            check("unmeasurable bitrate fails open to 30 s", target == 30)
        }
        check("zero budget fails open too",
              VortXRemuxForwardBufferCoupling.steadyStateDuration(
                aheadByteBudget: 0,
                observedBitsPerSecond: fieldBitsPerSecond,
                unconstrainedDuration: 30) == 30)
    }

    static func extremeBitrateRespectsTheViableFloor() {
        let target = VortXRemuxForwardBufferCoupling.steadyStateDuration(
            aheadByteBudget: VortXRemuxProducerLeadPolicy.maximumAheadBytes,
            observedBitsPerSecond: 200_000_000,
            unconstrainedDuration: VortXRemuxForwardBufferCouplingStubs.unconstrainedSteadyStateSeconds)
        check("200 Mb/s stream floors at the minimum viable target", target == 8)
    }

    static func coupledTargetPlusMarginNeverReachesTheCeilingAcrossFieldBitrates() {
        // Across every bitrate where the margin itself still fits, target + safety must stay at or under
        // what the producer ceiling affords. That invariant is exactly "AVPlayer's ask can no longer exceed
        // production's legal supply".
        for mbps in [50.0, 65.0, 86.44464, 98.0, 130.0] {
            let bps = mbps * 1_000_000
            let budget = VortXRemuxProducerLeadPolicy.maximumAheadBytes
            let target = VortXRemuxForwardBufferCoupling.steadyStateDuration(
                aheadByteBudget: budget,
                observedBitsPerSecond: bps,
                unconstrainedDuration: VortXRemuxForwardBufferCouplingStubs.unconstrainedSteadyStateSeconds)
            let affordable = Double(budget) * 8 / bps
            let floored = affordable - VortXRemuxForwardBufferCoupling.safetySeconds
                < VortXRemuxForwardBufferCoupling.minimumSteadyStateSeconds
            if !floored {
                check("\(mbps) Mb/s: target + safety <= ceiling-affordable seconds",
                      target + VortXRemuxForwardBufferCoupling.safetySeconds <= affordable + 0.000001)
            } else {
                check("\(mbps) Mb/s (floored): floor stays within affordable seconds",
                      target <= affordable)
            }
        }
    }

    /// Deterministic replay of the diag-6 failure loop: the player holds exactly its target and consumes at
    /// 1x while the producer publishes 6-second segments until the byte cap parks it. The starvation
    /// precondition is SLACK: while parked, the gap between the produced lead and the player's held buffer.
    /// With the OLD uncoupled 30 s target the deepest parked point leaves less than one segment of slack, so
    /// a single parked cycle (resume needs a full segment consumed) reaches the player's edge. The coupled
    /// target keeps more than a full segment of slack even at the deepest parked point.
    static func fieldLoopSimulationOldTargetStarvesNewTargetDoesNot() {
        let budget = VortXRemuxProducerLeadPolicy.maximumAheadBytes
        let bytesPerSecond = fieldBitsPerSecond / 8
        let segmentSeconds = 6.0
        let segmentBytes = Int(bytesPerSecond * segmentSeconds)

        func simulate(playerTargetSeconds: Double) -> Double {
            var producedAheadBytes = 0
            var producedAheadSeconds = 0.0   // un-consumed produced media == AVPlayer's held buffer here
            var paused = false
            var minParkedSlack = Double.greatestFiniteMagnitude
            // 90 simulated minutes at one-second ticks.
            for _ in 0..<5400 {
                // Player consumes one second per tick out of its held buffer.
                producedAheadBytes = max(0, producedAheadBytes - Int(bytesPerSecond))
                producedAheadSeconds = max(0, producedAheadSeconds - 1)
                // Producer publishes one segment when running.
                if !paused {
                    producedAheadBytes += segmentBytes
                    producedAheadSeconds += segmentSeconds
                }
                paused = VortXRemuxProducerLeadPolicy.shouldPauseProducer(
                    leadSeconds: producedAheadSeconds,
                    aheadBytes: producedAheadBytes,
                    currentlyPaused: paused)
                if paused {
                    minParkedSlack = min(minParkedSlack,
                                         producedAheadSeconds - playerTargetSeconds)
                }
            }
            return minParkedSlack
        }

        let oldSlack = simulate(playerTargetSeconds: 30)
        check("OLD uncoupled 30 s target: deepest parked point leaves under one segment of slack (reproduces diag 6)",
              oldSlack < segmentSeconds)

        let newTarget = VortXRemuxForwardBufferCoupling.steadyStateDuration(
            aheadByteBudget: budget,
            observedBitsPerSecond: fieldBitsPerSecond,
            unconstrainedDuration: VortXRemuxForwardBufferCouplingStubs.unconstrainedSteadyStateSeconds)
        let coupledSlack = simulate(playerTargetSeconds: newTarget)
        check("COUPLED target: deepest parked point keeps at least one full segment of slack",
              coupledSlack >= segmentSeconds)
    }
}

/// Harness-local stand-in for `VortXRemuxForwardBufferPolicy.steadyStateSeconds` so this file keeps compiling
/// standalone (DVPlaybackPolicy.swift drags in UIKit/AVFoundation and cannot join the swiftc line).
enum VortXRemuxForwardBufferCouplingStubs {
    static let unconstrainedSteadyStateSeconds: TimeInterval = 30
}
