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
        newGenerationAndSustainedProgressResetBudget()
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

    private static func newGenerationAndSustainedProgressResetBudget() {
        var budget = AVPlayerMidPlaybackRecoveryPolicy.RecoveryBudget()
        budget.recordReplacement(for: generation)
        check("replacement records a spent generation budget", budget.replacementUsed)
        budget.reset(for: generation + 1)
        check("a new generation owns a fresh recovery budget", !budget.replacementUsed)

        budget.recordReplacement(for: generation + 1)
        for position in 0...AVPlayerMidPlaybackRecoveryPolicy.RecoveryBudget.sustainedProgressSamplesToReset {
            budget.recordMediaPosition(Double(position), generation: generation + 1)
        }
        check("sustained forward media progress reopens one recovery budget", !budget.replacementUsed)
    }

    private static func staleOwnershipIsFenced() {
        check(
            "a stale caller generation cannot replace the current item",
            AVPlayerMidPlaybackRecoveryPolicy.action(
                evidence: evidence(ownershipMatches: false),
                replacementAlreadyUsed: false) == .retain(.staleOwnership))
    }
}
