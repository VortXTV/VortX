// Deterministic contract for AVPlayer's item-replacement admission policy.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/avplayer-mid-playback-recovery-policy-test \
//     app/Sources/Player/PlayerStallPolicy.swift \
//     app/Tests/AVPlayerMidPlaybackRecoveryPolicyTests.swift \
//     && /tmp/avplayer-mid-playback-recovery-policy-test

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
enum AVPlayerMidPlaybackRecoveryPolicyTests {
    private static let generation: UInt64 = 41

    static func main() {
        waitingProducerProgressRetainsCurrentItem()
        userPauseIsAbsoluteRetain()
        insufficientPublishedTailRetainsCurrentItem()
        terminalEvidenceStaysTerminal()
        onlyOneReplacementIsAllowedUntilRecovery()
        producerProgressHasWatchdogIntervalMeaning()
        consumerWedgeAndSourceStarvationAreDistinct()
        eventOwnedProducerReceiptsRequirePostEventAdvance()
        boundedHardStallEscalates()
        hardStallProgressResetsEscalationOrigin()
        newGenerationAndTimeBasedStableProgressResetBudget()
        staleOwnershipIsFenced()

        print("===== FAILURES: \(failures) =====")
        exit(failures == 0 ? 0 : 1)
    }

    private static func evidence(
        ownershipMatches: Bool = true,
        playbackRequested: Bool = true,
        hasPreviousProgressSample: Bool = true,
        producerProgressed: Bool = false,
        inputOpenInFlight: Bool = false,
        playlistProgressed: Bool = false,
        surfaceStalled: Bool = true,
        surfaceStallElapsedSeconds: TimeInterval = 0,
        publishedAheadSeconds: Double = 15,
        terminalProof: AVPlayerMidPlaybackRecoveryPolicy.TerminalProof = .none
    ) -> AVPlayerMidPlaybackRecoveryPolicy.Evidence {
        .init(
            generation: generation,
            ownershipMatches: ownershipMatches,
            playbackRequested: playbackRequested,
            isLocalRemux: true,
            hasPreviousProgressSample: hasPreviousProgressSample,
            producerProgressed: producerProgressed,
            inputOpenInFlight: inputOpenInFlight,
            playlistProgressed: playlistProgressed,
            surfaceStalled: surfaceStalled,
            surfaceStallElapsedSeconds: surfaceStallElapsedSeconds,
            publishedAheadSeconds: publishedAheadSeconds,
            terminalProof: terminalProof)
    }

    private static func waitingProducerProgressRetainsCurrentItem() {
        check(
            "a waiting local remux whose producer advances retains the current item",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(producerProgressed: true),
                replacementAlreadyUsed: false) == .retain(.producerProgress))
        check(
            "a first watchdog sample records evidence instead of replacing speculatively",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(hasPreviousProgressSample: false),
                replacementAlreadyUsed: false) == .retain(.missingProgressEvidence))
        check(
            "an input open still in flight retains the current item",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(inputOpenInFlight: true),
                replacementAlreadyUsed: false) == .retain(.inputInFlight))
        check(
            "a growing published playlist retains the current item",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(playlistProgressed: true),
                replacementAlreadyUsed: false) == .retain(.playlistProgress))
    }

    private static func userPauseIsAbsoluteRetain() {
        check(
            "a deliberate pause cannot trigger replacement even with a terminal receipt",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(
                    playbackRequested: false,
                    terminalProof: .producerFailed),
                replacementAlreadyUsed: false) == .retain(.userPaused))
    }

    private static func insufficientPublishedTailRetainsCurrentItem() {
        check(
            "a surface stall without ten seconds of published media cannot replace",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(publishedAheadSeconds: 9.999),
                replacementAlreadyUsed: false) == .retain(.insufficientPublishedTail))
    }

    private static func terminalEvidenceStaysTerminal() {
        check(
            "producer completion remains a terminal outcome",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(terminalProof: .producerEnded),
                replacementAlreadyUsed: false) == .terminal(.producerEnded))
        check(
            "failed AVPlayer item remains a terminal outcome",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(terminalProof: .itemFailed),
                replacementAlreadyUsed: false) == .terminal(.itemFailed))
    }

    private static func onlyOneReplacementIsAllowedUntilRecovery() {
        check(
            "a proven surface stall with a published tail authorizes one fresh item",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(),
                replacementAlreadyUsed: false) == .replaceFreshItem)
        check(
            "the same generation cannot spend a second replacement immediately",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(),
                replacementAlreadyUsed: true) == .retain(.replacementAlreadyUsed))
    }

    private static func producerProgressHasWatchdogIntervalMeaning() {
        // The engine samples producer counters at recovery decisions, not at every 4 Hz presentation tick.
        // A same-item rebuffer can therefore prove producer motion across a real interval and retain its
        // selections instead of being mistaken for a frozen renderer.
        check(
            "producer movement suppresses replacement after a real watchdog interval",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(producerProgressed: true, playlistProgressed: true),
                replacementAlreadyUsed: false) == .retain(.producerProgress))
    }

    private static func consumerWedgeAndSourceStarvationAreDistinct() {
        let threshold = AVPlayerMidPlaybackRecoveryPolicy.consumerWedgeRecoverySeconds
        check(
            "a frozen AVPlayer clock with post-sample producer progress admits one consumer-wedge replacement",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(
                    producerProgressed: true,
                    surfaceStallElapsedSeconds: threshold,
                    publishedAheadSeconds: 10),
                replacementAlreadyUsed: false) == .replaceFreshItem)
        check(
            "a frozen clock with a rich published tail admits recovery even without a prior watchdog baseline",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(
                    hasPreviousProgressSample: false,
                    surfaceStallElapsedSeconds: threshold,
                    publishedAheadSeconds: 10),
                replacementAlreadyUsed: false) == .replaceFreshItem)
        check(
            "a source-starved no-progress mount without a useful tail does not reload at the consumer threshold",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(
                    surfaceStallElapsedSeconds: threshold,
                    publishedAheadSeconds: 0),
                replacementAlreadyUsed: false) == .retain(.insufficientPublishedTail))
        check(
            "an input-open producer remains non-destructive even with a frozen surface and rich tail",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(
                    inputOpenInFlight: true,
                    surfaceStallElapsedSeconds: threshold,
                    publishedAheadSeconds: 30),
                replacementAlreadyUsed: false) == .retain(.inputInFlight))
    }

    private static func eventOwnedProducerReceiptsRequirePostEventAdvance() {
        let event = AVPlayerEventRecoveryPolicy.ProducerReceipt(
            producedBytes: 100, inputBytesRead: 100, segmentCount: 2,
            initPublished: true, signalingPublished: true)
        check(
            "an item-end without a post-event producer advance cannot replace",
            !AVPlayerEventRecoveryPolicy.producerAdvanced(from: event, to: event))
        check(
            "a later playlist advance authorizes an event-owned recovery observation",
            AVPlayerEventRecoveryPolicy.playlistAdvanced(
                from: event,
                to: .init(producedBytes: 100, inputBytesRead: 100, segmentCount: 3,
                          initPublished: true, signalingPublished: true)))
        check(
            "event bytes and input reads without a newly closed playlist segment cannot admit immediate replacement",
            !AVPlayerEventRecoveryPolicy.playlistAdvanced(
                from: event,
                to: .init(producedBytes: 200, inputBytesRead: 200, segmentCount: 2,
                          initPublished: true, signalingPublished: true)))
        check(
            "a byte-budget-parked producer with a rich current window remains recoverable after bounded polling",
            AVPlayerEventRecoveryPolicy.admitsFreshItem(
                producerAdvanced: false,
                inputOpenInFlight: false,
                publishedAheadSeconds: 0,
                publishedWindowSeconds: AVPlayerEventRecoveryPolicy.usefulPublishedWindowSeconds))
        check(
            "a source-starved event without advance or useful current window cannot reload",
            !AVPlayerEventRecoveryPolicy.admitsFreshItem(
                producerAdvanced: false,
                inputOpenInFlight: false,
                publishedAheadSeconds: 0,
                publishedWindowSeconds: 0))
        check(
            "an input-open event cannot reload even after a producer advance",
            !AVPlayerEventRecoveryPolicy.admitsFreshItem(
                producerAdvanced: true,
                inputOpenInFlight: true,
                publishedAheadSeconds: 30,
                publishedWindowSeconds: 30))
        check(
            "a stale event receipt cannot manufacture an advance for a newer identical generation",
            !AVPlayerEventRecoveryPolicy.producerAdvanced(
                from: .init(producedBytes: 200, inputBytesRead: 200, segmentCount: 4,
                            initPublished: true, signalingPublished: true),
                to: event))
    }

    private static func boundedHardStallEscalates() {
        let deadline = AVPlayerMidPlaybackRecoveryPolicy.sustainedSurfaceStallEscalationSeconds
        check(
            "a non-local frozen AVPlayer path escalates after the bounded hard-stall window",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(
                    surfaceStallElapsedSeconds: deadline,
                    publishedAheadSeconds: 0
                ).withLocalRemux(false),
                replacementAlreadyUsed: false) == .terminal(.sustainedSurfaceStall))
        check(
            "one instant before the escalation edge still retains the non-local player",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(
                    surfaceStallElapsedSeconds: deadline - 0.001,
                    publishedAheadSeconds: 0
                ).withLocalRemux(false),
                replacementAlreadyUsed: false) == .retain(.nonLocalRemux))
        check(
            "an insufficient published tail escalates instead of retaining forever",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(
                    surfaceStallElapsedSeconds: deadline,
                    publishedAheadSeconds: 0),
                replacementAlreadyUsed: false) == .terminal(.sustainedSurfaceStall))
        check(
            "a spent replacement budget escalates instead of restarting repeatedly",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(surfaceStallElapsedSeconds: deadline),
                replacementAlreadyUsed: true) == .terminal(.sustainedSurfaceStall))
        check(
            "producer movement remains an ordinary rebuffer retain even at the escalation edge",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(
                    producerProgressed: true,
                    surfaceStallElapsedSeconds: deadline),
                replacementAlreadyUsed: true) == .retain(.producerProgress))
    }

    private static func hardStallProgressResetsEscalationOrigin() {
        let deadline = AVPlayerMidPlaybackRecoveryPolicy.sustainedSurfaceStallEscalationSeconds
        var timer = AVPlayerMidPlaybackRecoveryPolicy.HardStallTimer()
        check("hard-stall timer starts at the first frozen no-progress receipt",
              timer.elapsed(generation: generation, hardStallObserved: true, now: 0) == 0)
        check("hard-stall timer measures uninterrupted no-progress evidence",
              timer.elapsed(generation: generation, hardStallObserved: true, now: 59) == 59)
        check("producer/input/playlist progress at t=59 clears the escalation origin",
              timer.elapsed(generation: generation, hardStallObserved: false, now: 59) == 0)
        check("a new freeze at t=120 receives a fresh hard-stall origin",
              timer.elapsed(generation: generation, hardStallObserved: true, now: 120) == 0)
        check("the post-progress freeze cannot escalate before a fresh full window",
              timer.elapsed(generation: generation, hardStallObserved: true, now: 120 + deadline - 0.001)
                < deadline)
        check("only uninterrupted hard-stall evidence reaches the new escalation edge",
              timer.elapsed(generation: generation, hardStallObserved: true, now: 120 + deadline) == deadline)
    }

    private static func newGenerationAndTimeBasedStableProgressResetBudget() {
        var budget = AVPlayerMidPlaybackRecoveryPolicy.RecoveryBudget()
        budget.recordReplacement(for: generation)
        check("replacement records a spent generation budget", budget.replacementUsed)
        budget.reset(for: generation + 1)
        check("a new remux mount owns a fresh recovery budget", !budget.replacementUsed)

        budget.recordReplacement(for: generation + 1)
        budget.reset(for: generation + 1)
        check("a fresh AVPlayer item on the same mount cannot reopen a spent replacement budget", budget.replacementUsed)
        _ = budget.recordMediaPosition(0, mountIdentity: generation + 1, now: 0)
        for position in 1...10 {
            _ = budget.recordMediaPosition(Double(position), mountIdentity: generation + 1,
                                           now: Double(position) * 0.25)
        }
        check("ten fast observer callbacks do not manufacture one minute of stable progress", budget.replacementUsed)
        _ = budget.recordMediaPosition(11, mountIdentity: generation + 1,
                                       now: 0.25 + AVPlayerMidPlaybackRecoveryPolicy.RecoveryBudget.sustainedProgressSecondsToReset)
        check("one monotonic minute of real media progress reopens one recovery budget", !budget.replacementUsed)

        budget.recordReplacement(for: generation + 1)
        _ = budget.recordMediaPosition(20, mountIdentity: generation + 1, now: 100)
        _ = budget.recordMediaPosition(21, mountIdentity: generation + 1, now: 101)
        _ = budget.recordMediaPosition(21, mountIdentity: generation + 1, now: 160)
        check("a frozen clock breaks the stable-progress interval instead of renewing the budget", budget.replacementUsed)
    }

    private static func staleOwnershipIsFenced() {
        check(
            "a stale caller generation cannot replace the current item",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(ownershipMatches: false),
                replacementAlreadyUsed: false) == .retain(.staleOwnership))
    }
}

private extension AVPlayerMidPlaybackRecoveryPolicy.Evidence {
    func withLocalRemux(_ isLocalRemux: Bool) -> Self {
        .init(
            generation: generation,
            ownershipMatches: ownershipMatches,
            playbackRequested: playbackRequested,
            isLocalRemux: isLocalRemux,
            hasPreviousProgressSample: hasPreviousProgressSample,
            producerProgressed: producerProgressed,
            inputOpenInFlight: inputOpenInFlight,
            playlistProgressed: playlistProgressed,
            surfaceStalled: surfaceStalled,
            surfaceStallElapsedSeconds: surfaceStallElapsedSeconds,
            publishedAheadSeconds: publishedAheadSeconds,
            terminalProof: terminalProof)
    }
}
