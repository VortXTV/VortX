// Executable regression contract for AVPlayer late native-subtitle settlement and remount recovery seeks.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/avplayer-recovery-settlement-policy-test \
//     app/Sources/Player/AVPlayerRecoverySettlementPolicy.swift \
//     app/Sources/Player/VortXHLSSeekAnchorState.swift \
//     app/Tests/AVPlayerRecoverySettlementPolicyTests.swift \
//     && /tmp/avplayer-recovery-settlement-policy-test

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
enum AVPlayerRecoverySettlementPolicyTests {
    private static let generation: UInt64 = 71
    private static let mount: UInt64 = 19

    static func main() {
        finalRetrySettlesAfterTimerAndNotificationActivatesExactlyOnce()
        notificationBeforeTimerActivatesExactlyOnce()
        newerOffOrNativeSelectionAndReplacementCancelThePendingExternalIntent()
        recoveryCompletionFailureAndDeadlineRetireOnlyTheirOwnedTicket()
        newerUserSeekSupersedesRecoveryAndPausedRestoreDoesNotRequestPlayback()
        recoveryAdmissionReconcilesLocalHLSAtTheActualLanding()

        print("===== FAILURES: \(failures) =====")
        exit(failures == 0 ? 0 : 1)
    }

    private static func finalRetrySettlesAfterTimerAndNotificationActivatesExactlyOnce() {
        var settlement = AVPlayerRecoverySettlementPolicy.ExternalSubtitleSettlement()
        settlement.request(generation: generation, mountIdentity: mount, revision: 9)
        // The final bounded retry executes, then AVFoundation settles asynchronously at 3.01s.  The matching
        // notification must still consume the retained intent; a later timer/notification cannot re-activate.
        let notification = settlement.consumeIfNativeDeselected(
            generation: generation, mountIdentity: mount, revision: 9, nativeDeselected: true)
        let duplicate = settlement.consumeIfNativeDeselected(
            generation: generation, mountIdentity: mount, revision: 9, nativeDeselected: true)
        check("late post-final-retry notification activates the external subtitle once", notification && !duplicate)
    }

    private static func notificationBeforeTimerActivatesExactlyOnce() {
        var settlement = AVPlayerRecoverySettlementPolicy.ExternalSubtitleSettlement()
        settlement.request(generation: generation, mountIdentity: mount, revision: 10)
        let notification = settlement.consumeIfNativeDeselected(
            generation: generation, mountIdentity: mount, revision: 10, nativeDeselected: true)
        let laterTimer = settlement.consumeIfNativeDeselected(
            generation: generation, mountIdentity: mount, revision: 10, nativeDeselected: true)
        check("notification before a retry timer remains the sole activation", notification && !laterTimer)
    }

    private static func newerOffOrNativeSelectionAndReplacementCancelThePendingExternalIntent() {
        var settlement = AVPlayerRecoverySettlementPolicy.ExternalSubtitleSettlement()
        settlement.request(generation: generation, mountIdentity: mount, revision: 11)
        settlement.clear() // Newer Off/built-in choice.
        let newerChoice = settlement.consumeIfNativeDeselected(
            generation: generation, mountIdentity: mount, revision: 11, nativeDeselected: true)
        settlement.request(generation: generation, mountIdentity: mount, revision: 12)
        let replacement = settlement.consumeIfNativeDeselected(
            generation: generation + 1, mountIdentity: mount + 1, revision: 12, nativeDeselected: true)
        check("newer subtitle choice and replacement cannot activate an old external intent",
              !newerChoice && !replacement && settlement.hasPendingIntent)
        settlement.clear() // Teardown clears the old mount explicitly.
        check("teardown clears the retained external activation intent", !settlement.hasPendingIntent)
    }

    private static func recoveryCompletionFailureAndDeadlineRetireOnlyTheirOwnedTicket() {
        var recovery = AVPlayerRecoverySettlementPolicy.RecoverySeekSettlement()
        let failed = recovery.issue(
            sourceSeconds: 340, playbackRequested: true,
            generation: generation, mountIdentity: mount, revision: 1)
        let failedBound = recovery.bind(requestID: 101, ticket: failed)
        let failedRetired = recovery.fail(requestID: 101)
        let deadline = recovery.issue(
            sourceSeconds: 341, playbackRequested: true,
            generation: generation, mountIdentity: mount, revision: 2)
        let deadlineBound = recovery.bind(requestID: 102, ticket: deadline)
        let deadlineRetired = recovery.fail(requestID: 102)
        check("false completion and deadline retire their recovery tickets without retaining a stale receipt",
              failedBound && failedRetired && deadlineBound && deadlineRetired && recovery.ticket == nil)
    }

    private static func newerUserSeekSupersedesRecoveryAndPausedRestoreDoesNotRequestPlayback() {
        var recovery = AVPlayerRecoverySettlementPolicy.RecoverySeekSettlement()
        let paused = recovery.issue(
            sourceSeconds: 222, playbackRequested: false,
            generation: generation, mountIdentity: mount, revision: 3)
        let bound = recovery.bind(requestID: 103, ticket: paused)
        recovery.supersede() // Newer user seek owns the engine request epoch.
        let staleCompletion = recovery.finish(requestID: 103)
        check("a newer user seek fences the prior recovery completion", bound && !staleCompletion)
        check("a successful paused recovery preserves its actual target without requesting autoplay",
              paused.sourceSeconds == 222 && !paused.playbackRequested)
    }

    private static func recoveryAdmissionReconcilesLocalHLSAtTheActualLanding() {
        var recovery = AVPlayerRecoverySettlementPolicy.RecoverySeekSettlement()
        let ticket = recovery.issue(
            sourceSeconds: 145, playbackRequested: false,
            generation: generation, mountIdentity: mount, revision: 4)
        var anchor = VortXHLSSeekAnchorState()
        anchor.reportPlaybackPosition(400)
        anchor.registerSeek(requestID: 104)
        let bound = recovery.bind(requestID: 104, ticket: ticket)
        let admitted = anchor.admitSeek(
            requestID: 104, playerSeconds: ticket.sourceSeconds, targetIsPublished: true)
        // The native completion may land adjacent to the requested clock. The local-HLS receipt must use that
        // real landing, and only then reopen periodic receipt admission while paused.
        let reconciled = anchor.completeSeek(requestID: 104, playerSeconds: 144.75)
        let finished = recovery.finish(requestID: 104)
        let periodicAccepted = anchor.reportPlaybackPosition(
            144.8, receiptEpoch: anchor.playbackReceiptEpoch)
        check("recovery seek uses local-HLS admission then reconciles the actual paused landing",
              bound && admitted && reconciled && finished && periodicAccepted
                && anchor.currentPlaybackSeconds == 144.8 && !ticket.playbackRequested)
    }
}
