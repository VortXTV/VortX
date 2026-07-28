import Foundation

@main
private enum TrickplayUploadPolicyTests {
    nonisolated(unsafe) private static var passed = 0

    static func main() {
        testCapturePressureNeedsMeaningfulDropDelta()
        testCapturePressureTransitionsAreBounded()
        testCaptureRequestOwnershipRejectsStaleCallbacks()
        testOneProgressiveAttempt()
        testStoredProgressiveAllowsOneMateriallyFullerFinal()
        testRejectedAndStoredFinalAreTerminal()
        testFailedProgressiveGetsOneFinalRetry()
        testTeardownWhileProgressiveIsInFlight()
        testThinDeferredFinalIsDiscardedAfterProgressiveStorage()
        testFailedProgressiveDrainsDeferredFinal()
        testOrdinaryKeyRetirementQueuesAndDrainsOldFinal()
        testKeySwitchPreservesAdmittedOldKeyWork()
        testStaleCompletionCannotAffectNewKey()
        testCoverageAndExistingSetGates()
        testOwnedCancellationStopsEveryHeavyStage()
        print("TrickplayUploadPolicyTests: \(passed)/\(passed) passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else {
            fatalError("\(file):\(line): \(message)")
        }
        passed += 1
    }

    private static func started(
        _ admission: TrickplayUploadPolicy.Admission?
    ) -> TrickplayUploadPolicy.Claim? {
        guard case .start(let claim) = admission else { return nil }
        return claim
    }

    private static func deferred(
        _ admission: TrickplayUploadPolicy.Admission?
    ) -> TrickplayUploadPolicy.Claim? {
        guard case .deferred(let claim) = admission else { return nil }
        return claim
    }

    private struct CaptureRequestHarness {
        private(set) var generation: UInt64 = 0
        private(set) var active: UInt64?
        private(set) var recordedFrames = 0

        mutating func begin() -> UInt64 {
            generation &+= 1
            active = generation
            return generation
        }

        mutating func finish(_ token: UInt64, recordsFrame: Bool) -> Bool {
            guard active == token else { return false }
            active = nil
            if recordsFrame { recordedFrames += 1 }
            return true
        }

        mutating func invalidate() {
            generation &+= 1
            active = nil
        }
    }

    private static func testCaptureRequestOwnershipRejectsStaleCallbacks() {
        var completionRace = CaptureRequestHarness()
        let old = completionRace.begin()
        expect(
            completionRace.finish(old, recordsFrame: false),
            "the current watchdog may release its capture request"
        )
        let replacement = completionRace.begin()
        expect(
            !completionRace.finish(old, recordsFrame: false)
                && completionRace.active == replacement,
            "a stale nil completion cannot clear the replacement capture"
        )
        expect(
            !completionRace.finish(old, recordsFrame: true)
                && completionRace.recordedFrames == 0
                && completionRace.active == replacement,
            "a stale success completion cannot record over the replacement capture"
        )
        expect(
            completionRace.finish(replacement, recordsFrame: true)
                && completionRace.recordedFrames == 1
                && completionRace.active == nil,
            "the current success completion records exactly one frame and releases ownership"
        )

        var watchdogRace = CaptureRequestHarness()
        let retired = watchdogRace.begin()
        watchdogRace.invalidate()
        let current = watchdogRace.begin()
        expect(
            !watchdogRace.finish(retired, recordsFrame: false)
                && watchdogRace.active == current,
            "a stale watchdog cannot clear a capture begun after invalidation"
        )
        expect(
            !watchdogRace.finish(retired, recordsFrame: true)
                && watchdogRace.recordedFrames == 0,
            "a teardown-invalidated success callback cannot publish a frame"
        )
    }

    private static func testCapturePressureNeedsMeaningfulDropDelta() {
        var policy = TrickplayCapturePressurePolicy()
        for delta in 0..<TrickplayCapturePressurePolicy.highDropThreshold {
            expect(
                policy.observe(droppedFrames: delta, now: Double(delta)) == .unchanged,
                "an incidental 30-second drop delta cannot suppress local previews"
            )
        }
        expect(
            !policy.isSuppressed(at: 29),
            "ordinary isolated drops leave the ten-second capture cadence enabled"
        )
    }

    private static func testCapturePressureTransitionsAreBounded() {
        var policy = TrickplayCapturePressurePolicy()
        expect(
            policy.observe(
                droppedFrames: TrickplayCapturePressurePolicy.highDropThreshold,
                now: 100
            ) == .entered,
            "a meaningful high-drop interval records entry into temporary backoff"
        )
        expect(
            policy.isSuppressed(at: 159),
            "high-drop backoff remains active inside its bounded window"
        )
        expect(
            policy.observe(
                droppedFrames: TrickplayCapturePressurePolicy.highDropThreshold,
                now: 130
            ) == .extended,
            "continued high-drop evidence records an explicit extension"
        )
        expect(
            policy.isSuppressed(at: 189),
            "the evidence-backed extension remains bounded"
        )
        expect(
            policy.observe(droppedFrames: 0, now: 190) == .exited,
            "the first low-drop receipt after expiry records the exit transition"
        )
        expect(
            !policy.isSuppressed(at: 190),
            "capture resumes after the bounded pressure interval"
        )
    }

    private static func testOneProgressiveAttempt() {
        var policy = TrickplayUploadPolicy()
        let first = started(policy.request(
            key: "episode-a", kind: .progressive,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))
        expect(first != nil, "first storable progressive capture should upload")
        expect(
            policy.request(
                key: "episode-a", kind: .progressive,
                frameCount: 21, existingFrameCount: 0, coverageReady: true
            ) == nil,
            "an in-flight upload must coalesce later capture ticks"
        )
        _ = policy.complete(first!, outcome: .failed)
        expect(
            policy.request(
                key: "episode-a", kind: .progressive,
                frameCount: 30, existingFrameCount: 0, coverageReady: true
            ) == nil,
            "a failed progressive attempt must not rebuild every minute"
        )
    }

    private static func testStoredProgressiveAllowsOneMateriallyFullerFinal() {
        var policy = TrickplayUploadPolicy()
        let progressive = started(policy.request(
            key: "episode-a", kind: .progressive,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        expect(
            policy.complete(progressive, outcome: .stored).applied,
            "current completion should apply"
        )
        expect(
            policy.request(
                key: "episode-a", kind: .final,
                frameCount: 25, existingFrameCount: 0, coverageReady: true
            ) == nil,
            "small growth should not spend another full-sheet build"
        )
        let final = started(policy.request(
            key: "episode-a", kind: .final,
            frameCount: 26, existingFrameCount: 0, coverageReady: true
        ))
        expect(final != nil, "materially fuller teardown coverage should replace the thin sheet")
        expect(
            policy.complete(final!, outcome: .stored).applied,
            "stored final should complete"
        )
        expect(policy.isTerminal, "stored final should be terminal")
    }

    private static func testRejectedAndStoredFinalAreTerminal() {
        var rejected = TrickplayUploadPolicy()
        let declined = started(rejected.request(
            key: "episode-a", kind: .progressive,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        _ = rejected.complete(declined, outcome: .rejected)
        expect(
            rejected.request(
                key: "episode-a", kind: .final,
                frameCount: 100, existingFrameCount: 0, coverageReady: true
            ) == nil,
            "a deliberate server decline should be terminal for the exact key"
        )

        var finalOnly = TrickplayUploadPolicy()
        let final = started(finalOnly.request(
            key: "episode-a", kind: .final,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        _ = finalOnly.complete(final, outcome: .stored)
        expect(finalOnly.isTerminal, "a stored teardown set should be terminal")
    }

    private static func testFailedProgressiveGetsOneFinalRetry() {
        var policy = TrickplayUploadPolicy()
        let progressive = started(policy.request(
            key: "episode-a", kind: .progressive,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        _ = policy.complete(progressive, outcome: .failed)
        let final = started(policy.request(
            key: "episode-a", kind: .final,
            frameCount: 40, existingFrameCount: 0, coverageReady: true
        ))
        expect(final != nil, "a transient progressive failure should get a teardown retry")
        _ = policy.complete(final!, outcome: .failed)
        expect(
            policy.request(
                key: "episode-a", kind: .final,
                frameCount: 50, existingFrameCount: 0, coverageReady: true
            ) == nil,
            "the teardown retry itself must be once-only"
        )
    }

    private static func testTeardownWhileProgressiveIsInFlight() {
        var policy = TrickplayUploadPolicy()
        let progressive = started(policy.request(
            key: "episode-a", kind: .progressive,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        let final = deferred(policy.request(
            key: "episode-a", kind: .final,
            frameCount: 30, existingFrameCount: 0, coverageReady: true
        ))
        expect(final != nil, "teardown must reserve one final behind an in-flight progressive")
        expect(
            policy.inFlight == progressive && policy.deferredFinals == [final!],
            "deferring teardown must not replace the active progressive claim"
        )
        expect(
            policy.request(
                key: "episode-a", kind: .final,
                frameCount: 40, existingFrameCount: 0, coverageReady: true
            ) == nil,
            "the same key may reserve only one final snapshot"
        )
        let completion = policy.complete(progressive, outcome: .stored)
        expect(
            completion.applied && completion.nextClaim == final,
            "materially fuller deferred coverage must drain after progressive storage"
        )
        expect(
            policy.inFlight == final && policy.deferredFinals.isEmpty,
            "drain starts exactly one final and empties its queue slot"
        )
    }

    private static func testFailedProgressiveDrainsDeferredFinal() {
        var policy = TrickplayUploadPolicy()
        let progressive = started(policy.request(
            key: "episode-a", kind: .progressive,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        let final = deferred(policy.request(
            key: "episode-a", kind: .final,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        let completion = policy.complete(progressive, outcome: .failed)
        expect(
            completion.nextClaim == final && policy.inFlight == final,
            "a failed progressive must drain its one reserved teardown retry"
        )
    }

    private static func testThinDeferredFinalIsDiscardedAfterProgressiveStorage() {
        var policy = TrickplayUploadPolicy()
        let progressive = started(policy.request(
            key: "episode-a", kind: .progressive,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        expect(
            deferred(policy.request(
                key: "episode-a", kind: .final,
                frameCount: 25, existingFrameCount: 0, coverageReady: true
            )) != nil,
            "teardown may reserve a snapshot before the progressive result is known"
        )
        let completion = policy.complete(progressive, outcome: .stored)
        expect(
            completion.applied
                && completion.nextClaim == nil
                && policy.inFlight == nil
                && policy.deferredFinals.isEmpty,
            "stored progressive coverage must discard a deferred final without material growth"
        )
    }

    private static func testKeySwitchPreservesAdmittedOldKeyWork() {
        var policy = TrickplayUploadPolicy()
        let old = started(policy.request(
            key: "episode-a", kind: .progressive,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        let oldFinal = deferred(policy.request(
            key: "episode-a", kind: .final,
            frameCount: 40, existingFrameCount: 0, coverageReady: true
        ))!
        policy.reset(for: "episode-b")
        expect(
            policy.inFlight == old && policy.deferredFinals == [oldFinal],
            "a key switch must preserve admitted old-key work and its immutable final reservation"
        )
        expect(
            policy.request(
                key: "episode-b", kind: .progressive,
                frameCount: 20, existingFrameCount: 0, coverageReady: true
            ) == nil,
            "the new key cannot overlap the single bounded upload owner"
        )
        let oldCompletion = policy.complete(old, outcome: .failed)
        expect(
            oldCompletion.nextClaim == oldFinal && policy.inFlight == oldFinal,
            "old-key failure must drain the old-key final after the key switch"
        )
        _ = policy.complete(oldFinal, outcome: .stored)
        expect(
            started(policy.request(
                key: "episode-b", kind: .progressive,
                frameCount: 20, existingFrameCount: 0, coverageReady: true
            )) != nil,
            "the new key may start after admitted old-key work drains"
        )
    }

    private static func testOrdinaryKeyRetirementQueuesAndDrainsOldFinal() {
        var policy = TrickplayUploadPolicy()
        let progressive = started(policy.request(
            key: "episode-a", kind: .progressive,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        let retiredFinal = deferred(policy.retireCurrent(
            frameCount: 40,
            existingFrameCount: 0,
            coverageReady: true,
            selecting: "episode-b"
        ))
        expect(
            retiredFinal?.key == "episode-a"
                && retiredFinal?.frameCount == 40
                && policy.key == "episode-b",
            "ordinary key retirement must reserve the old final before selecting the new content"
        )
        expect(
            policy.inFlight == progressive && policy.deferredFinals == [retiredFinal!],
            "retirement must preserve the old progressive and queue one old-key final behind it"
        )
        expect(
            policy.retireCurrent(
                frameCount: 0,
                existingFrameCount: 0,
                coverageReady: false,
                selecting: "episode-b"
            ) == nil && policy.deferredFinals.count == 1,
            "a repeated configure or disappearance cannot duplicate the retired final"
        )
        let completion = policy.complete(progressive, outcome: .failed)
        expect(
            completion.nextClaim == retiredFinal
                && policy.inFlight == retiredFinal
                && policy.key == "episode-b"
                && !policy.isTerminal,
            "old-key retirement must drain after failure without mutating the selected key"
        )
    }

    private static func testStaleCompletionCannotAffectNewKey() {
        var policy = TrickplayUploadPolicy()
        let old = started(policy.request(
            key: "episode-a", kind: .progressive,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        policy.reset(for: "episode-b")
        _ = policy.complete(old, outcome: .failed)
        let current = started(policy.request(
            key: "episode-b", kind: .progressive,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        let stale = policy.complete(old, outcome: .rejected)
        expect(
            !stale.applied && stale.nextClaim == nil,
            "a duplicate old completion must be rejected as stale"
        )
        expect(
            policy.key == "episode-b"
                && policy.inFlight == current
                && !policy.isTerminal,
            "a stale old-key completion cannot mutate or terminate the new key"
        )
    }

    private static func testCoverageAndExistingSetGates() {
        var policy = TrickplayUploadPolicy()
        expect(
            policy.request(
                key: "episode-a", kind: .progressive,
                frameCount: 20, existingFrameCount: 0, coverageReady: false
            ) == nil,
            "sub-floor capture should not spend build or network work"
        )
        expect(
            policy.request(
                key: "episode-a", kind: .progressive,
                frameCount: 20, existingFrameCount: 20, coverageReady: true
            ) == nil,
            "a capture that cannot beat the fetched set should not upload"
        )
    }

    private static func testOwnedCancellationStopsEveryHeavyStage() {
        expect(
            TrickplayOwnedWorkGate.permitsStage(taskIsCancelled: false),
            "an active owned upload may enter composition"
        )
        for stage in ["composition", "jpeg", "post"] {
            expect(
                !TrickplayOwnedWorkGate.permitsStage(taskIsCancelled: true),
                "task cancellation blocks \(stage)"
            )
        }
    }
}
