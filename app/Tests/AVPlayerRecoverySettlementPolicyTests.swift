// Executable regression contract for AVPlayer late native-subtitle settlement and remount recovery seeks.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/avplayer-recovery-settlement-policy-test \
//     app/Sources/Player/AVPlayerRecoverySettlementPolicy.swift \
//     app/Sources/Player/VortXHLSSeekAnchorState.swift \
//     app/Sources/Player/RemuxResumePolicy.swift \
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
        staleFailureCannotRetireTheNewestNormalizedRecoveryTarget()
        newerUserSeekSupersedesRecoveryAndPausedRestoreDoesNotRequestPlayback()
        recoveryAdmissionReconcilesLocalHLSAtTheActualLanding()
        readyContinuationRejectsSynchronousRecoveryRemount()
        recoveryNormalizesAcceptedForwardOriginWithoutWeakeningOutsideTolerance()
        admittedSeekDestinationSurvivesOnlyItsOwnedRecovery()
        seekDestinationWiringRetainsFailedTargetsBeforeQueuedFallback()

        print("===== FAILURES: \(failures) =====")
        exit(failures == 0 ? 0 : 1)
    }

    private static func admittedSeekDestinationSurvivesOnlyItsOwnedRecovery() {
        typealias Ownership = AVPlayerRecoverySettlementPolicy.Ownership
        var destination = AVPlayerRecoverySettlementPolicy.SeekDestination()
        let first = Ownership(generation: 4, mountIdentity: 8, revision: 12)
        let second = Ownership(generation: 4, mountIdentity: 8, revision: 13)
        let failed = Ownership(generation: 4, mountIdentity: 8, revision: 14)
        var nativePosition = 0.4
        destination.record(sourceSeconds: 365.865, ownership: first)
        check("admitted seek fallback keeps 365.865 while native clock remains at 0.4",
              destination.target(ownership: first) == 365.865 && nativePosition == 0.4)
        destination.clear() // supersedeSeekRequest, before the next native seek is issued.
        destination.record(sourceSeconds: 92, ownership: second)
        let retiredCompletion = destination.finish(ownership: first)
        check("late first seek completion cannot clear the newer backward destination",
              !retiredCompletion && destination.target(ownership: second) == 92)
        let repairTarget = destination.target(ownership: second)!
        destination.clear() // Failed request is invalidated before cancelPendingSeeks.
        destination.record(sourceSeconds: repairTarget, ownership: failed)
        check("failed direct seek retains its destination in the new cancellation epoch for fallback",
              destination.target(ownership: failed) == 92 && destination.target(ownership: second) == nil)
        check("different item and mount cannot read a retained destination",
              destination.target(ownership: .init(generation: 5, mountIdentity: 8, revision: 14)) == nil
                && destination.target(ownership: .init(generation: 4, mountIdentity: 9, revision: 14)) == nil)
        destination.clear() // New source or explicit new seek retires the failed request and its error.
        check("source replacement and a newer user seek retire the failed target",
              destination.target(ownership: failed) == nil)
        destination.record(sourceSeconds: 200, ownership: second)
        nativePosition = 200
        let landed = destination.finish(ownership: second)
        check("successful current completion releases target authority to the native clock",
              landed && destination.target(ownership: second) == nil && nativePosition == 200)
        destination.record(sourceSeconds: .nan, ownership: first)
        check("nonfinite requests cannot acquire recovery authority", destination.sourceSeconds == nil)
        destination.record(sourceSeconds: -10, ownership: first)
        check("negative seek destination clamps to the beginning", destination.target(ownership: first) == 0)
    }

    private static func seekDestinationWiringRetainsFailedTargetsBeforeQueuedFallback() {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Player/AVPlayerEngine.swift")
        guard let engine = try? String(contentsOf: path, encoding: .utf8) else {
            check("read production AVPlayer seek wiring", false)
            return
        }
        func section(_ start: String, _ end: String) -> String {
            guard let begin = engine.range(of: start),
                  let finish = engine.range(of: end, range: begin.upperBound..<engine.endIndex) else { return "" }
            return String(engine[begin.lowerBound..<finish.lowerBound])
        }
        let arm = section("private func armSeekCompletionDeadline(", "private func emitUnfinishedSeekFailure(")
        check("every issued seek records its exact destination before the existing deadline",
              arm.contains("guard requestID == seekRequestGeneration")
                && arm.contains("seekDestination.record(sourceSeconds: sourceSeconds, ownership: seekDestinationOwnership)"))
        let failure = section("private func emitUnfinishedSeekFailure(", "private func registerSeekAdmission(")
        check("deadline and false completion share target-preserving scoped failure delivery",
              engine.components(separatedBy: "self.emitUnfinishedSeekFailure(sourceSeconds: repairSourceSeconds").count == 3
                && failure.contains("seekDestination.record(sourceSeconds: sourceSeconds")
                && failure.contains("seekRequestID: seekRequestGeneration"))
        let emission = section("private func emit(_ name:", "private func selectionContextIsCurrent(")
        check("a newer seek cancels the old queued seek error even on the same item",
              emission.contains("seekRequestID == nil || seekRequestID == self.seekRequestGeneration"))
        let load = section("func loadFile(_ url:", "let isIntentRemount")
        let captureIndex = load.range(of: "let carriedSeekTarget = pendingRequestedSourcePositionSeconds")?.lowerBound
        let invalidationIndex = load.range(of: "invalidateSeekRequests()")?.lowerBound
        let ownedRecovery = section("if carriesOwnedRecoveryIntent {", "let isIntentRemount")
        check("same-source recovery captures the pending target before invalidation",
              captureIndex != nil && invalidationIndex != nil
                && captureIndex! < invalidationIndex!
                && ownedRecovery.contains("if let carriedSeekTarget { pendingPlaybackIntent?.updateSourceSeconds(carriedSeekTarget) }"))
        let capture = section("private func capturePlaybackIntent(", "private func releasePendingPlaybackIntentAtReady(")
        check("item and selection recovery prefer the admitted seek over an unchanged native clock",
              capture.contains("let recoverySourceSeconds = pendingRequestedSourcePositionSeconds ?? playbackPositionSeconds")
                && capture.contains("sourceSeconds: recoverySourceSeconds"))
        let exposed = section("var pendingRequestedSourcePositionSeconds:", "var dolbyVisionFallbackInfo:")
        check("engine demotion can capture only the exact current seek destination",
              exposed.contains("guard activeLoadToken != nil")
                && exposed.contains("seekDestination.target(ownership: seekDestinationOwnership)"))
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
        let failedRepair = recovery.fail(requestID: 101)
        let deadline = recovery.issue(
            sourceSeconds: 341, playbackRequested: true,
            generation: generation, mountIdentity: mount, revision: 2)
        let deadlineBound = recovery.bind(requestID: 102, ticket: deadline)
        let deadlineRepair = recovery.fail(requestID: 102)
        check("false completion and deadline yield their owned remount repair instead of only deleting recovery",
              failedBound && failedRepair?.sourceSeconds == 340
                && deadlineBound && deadlineRepair?.sourceSeconds == 341 && recovery.ticket == nil)
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

    private static func staleFailureCannotRetireTheNewestNormalizedRecoveryTarget() {
        var recovery = AVPlayerRecoverySettlementPolicy.RecoverySeekSettlement()
        let oldTicket = recovery.issue(
            sourceSeconds: 340, playbackRequested: true,
            generation: generation, mountIdentity: mount, revision: 1)
        let oldBound = recovery.bind(requestID: 101, ticket: oldTicket)
        let normalizedTarget = AVPlayerRecoverySettlementPolicy.normalizedRecoverySourceSeconds(
            requestedSourceSeconds: 1_200,
            achievedOriginSeconds: 1_200.2,
            acceptedForwardLandingTolerance: RemuxResumePolicy.forwardLandingToleranceSeconds)
        let newTicket = recovery.issue(
            sourceSeconds: normalizedTarget, playbackRequested: false,
            generation: generation + 1, mountIdentity: mount + 1, revision: 2)
        let newBound = recovery.bind(requestID: 102, ticket: newTicket)
        let staleRepair = recovery.fail(requestID: 101)
        check("a stale failure cannot retire the latest recovery ticket",
              oldBound && newBound && staleRepair == nil && recovery.ticket == newTicket)
        let currentRepair = recovery.fail(requestID: 102)
        check("owned repair retains the normalized source target rather than the old mount clock",
              currentRepair?.sourceSeconds == 1_200.2 && recovery.ticket == nil)
        check("a repair target is consumed once, not reissued by a duplicate deadline",
              recovery.fail(requestID: 102) == nil)
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

    private static func readyContinuationRejectsSynchronousRecoveryRemount() {
        let originalReady = AVPlayerRecoverySettlementPolicy.ReadyContinuationOwnership(
            generation: generation, mountIdentity: mount)
        let unchanged = originalReady.isCurrent(generation: generation, mountIdentity: mount)
        // `remountForSeek` replaces both receipts synchronously before the old ready handler returns.
        let afterSynchronousRemount = originalReady.isCurrent(
            generation: generation + 1, mountIdentity: mount + 1)
        check("old ready continuation cannot publish selection or didStart after synchronous remount",
              unchanged && !afterSynchronousRemount)
    }

    private static func recoveryNormalizesAcceptedForwardOriginWithoutWeakeningOutsideTolerance() {
        let acceptedOrigin = AVPlayerRecoverySettlementPolicy.normalizedRecoverySourceSeconds(
            requestedSourceSeconds: 1_200,
            achievedOriginSeconds: 1_200.2,
            acceptedForwardLandingTolerance: RemuxResumePolicy.forwardLandingToleranceSeconds)
        let acceptedAction = RemuxResumePolicy.mountedSeekAction(
            sourceSeconds: acceptedOrigin,
            origin: 1_200.2,
            producedEdgePlayerSeconds: 0)
        let outsideTolerance = AVPlayerRecoverySettlementPolicy.normalizedRecoverySourceSeconds(
            requestedSourceSeconds: 1_200,
            achievedOriginSeconds: 1_200.26,
            acceptedForwardLandingTolerance: RemuxResumePolicy.forwardLandingToleranceSeconds)
        let outsideAction = RemuxResumePolicy.mountedSeekAction(
            sourceSeconds: outsideTolerance,
            origin: 1_200.26,
            producedEdgePlayerSeconds: 0)
        check("accepted forward recovery origin seeks local zero once rather than remounting",
              acceptedOrigin == 1_200.2 && acceptedAction == .seekPlayer(0))
        check("outside forward tolerance remains a remount repair, preserving viewer seek policy",
              outsideTolerance == 1_200 && outsideAction == .remountAtSource(1_200))
    }
}
