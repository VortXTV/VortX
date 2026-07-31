import Foundation

@main
private enum SourceContributionWorkPolicyTests {
    nonisolated(unsafe) private static var passed = 0

    static func main() {
        testStormCollapsesToOneFollowup()
        testCompletedSnapshotDoesNotResubmit()
        testChangedFingerprintSubmits()
        testDeferredAttemptRetriesSameSnapshot()
        testCancelRejectsStaleCompletion()
        testLateCompletionCannotClearNewOwner()
        testPlaybackGateDefersTheWholeRefresh()
        testContinueWatchingHoardWaitsForPlaybackExit()
        testContinueWatchingHoardAbandonsWhenPlayerNeverMounts()
        print("SourceContributionWorkPolicyTests: \(passed)/\(passed) passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else { fatalError("\(file):\(line): \(message)") }
        passed += 1
    }

    private static func testStormCollapsesToOneFollowup() {
        var policy = SourceContributionWorkPolicy()
        guard case .launch(let claim) = policy.request() else {
            fatalError("first request did not launch")
        }
        for _ in 0..<10_000 {
            expect(policy.request() == .coalesced, "an active operation must own the whole request storm")
        }
        expect(
            policy.complete(
                claim,
                target: nil,
                acceptedByProcess: false
            ) == .current(needsNewestSnapshot: true),
            "one newest-snapshot refresh should remain after the storm"
        )
        guard case .launch = policy.request() else {
            fatalError("followup did not launch")
        }
        passed += 1
    }

    private static func testCompletedSnapshotDoesNotResubmit() {
        var policy = SourceContributionWorkPolicy()
        let target = SourceContributionWorkPolicy.Target(
            contentID: "tt0000001:1:1", descriptorFingerprint: "abc"
        )
        guard case .launch(let first) = policy.request() else { fatalError() }
        expect(policy.shouldSubmit(target, for: first), "new snapshot should submit")
        expect(
            policy.complete(
                first,
                target: target,
                acceptedByProcess: true
            ) == .current(needsNewestSnapshot: false),
            "a process-accepted attempt needs no followup"
        )

        guard case .launch(let second) = policy.request() else { fatalError() }
        expect(!policy.shouldSubmit(target, for: second), "identical completed snapshot should be skipped")
    }

    private static func testChangedFingerprintSubmits() {
        var policy = SourceContributionWorkPolicy()
        let firstTarget = SourceContributionWorkPolicy.Target(
            contentID: "tt0000001:1:1", descriptorFingerprint: "abc"
        )
        guard case .launch(let first) = policy.request() else { fatalError() }
        _ = policy.complete(
            first,
            target: firstTarget,
            acceptedByProcess: true
        )

        let changed = SourceContributionWorkPolicy.Target(
            contentID: "tt0000001:1:1", descriptorFingerprint: "def"
        )
        guard case .launch(let second) = policy.request() else { fatalError() }
        expect(policy.shouldSubmit(changed, for: second), "a changed descriptor set should remain eligible")
    }

    private static func testDeferredAttemptRetriesSameSnapshot() {
        var policy = SourceContributionWorkPolicy()
        var gate = SourceRefreshPlaybackGate()
        let target = SourceContributionWorkPolicy.Target(
            contentID: "tt0000001:1:1",
            descriptorFingerprint: "abc"
        )
        guard case .launch(let first) = policy.request() else { fatalError() }
        expect(
            policy.shouldSubmit(target, for: first),
            "a new snapshot is eligible before playback starts"
        )

        gate.playbackStarted()
        expect(
            policy.complete(
                first,
                target: target,
                acceptedByProcess: false
            ) == .current(needsNewestSnapshot: false),
            "a pre-commit playback stop must not latch the snapshot"
        )
        expect(
            gate.playbackEnded(),
            "playback exit releases the deferred detail refresh"
        )

        guard case .launch(let retry) = policy.request() else {
            fatalError("deferred snapshot did not get a new claim")
        }
        expect(
            policy.shouldSubmit(target, for: retry),
            "the exact deferred snapshot remains eligible on refresh"
        )
    }

    private static func testCancelRejectsStaleCompletion() {
        var policy = SourceContributionWorkPolicy()
        guard case .launch(let claim) = policy.request() else { fatalError() }
        policy.cancel()
        expect(
            policy.complete(
                claim,
                target: nil,
                acceptedByProcess: false
            ) == .stale,
            "a canceled owner's late completion must be stale"
        )
    }

    private static func testLateCompletionCannotClearNewOwner() {
        var policy = SourceContributionWorkPolicy()
        guard case .launch(let first) = policy.request() else { fatalError() }
        policy.cancel()
        guard case .launch(let second) = policy.request() else {
            fatalError("replacement contribution did not launch")
        }

        expect(
            policy.complete(
                first,
                target: nil,
                acceptedByProcess: false
            ) == .stale,
            "late completion from the canceled owner is rejected"
        )
        expect(
            policy.activeClaim == second,
            "late completion leaves the replacement contribution owned"
        )
        policy.cancel()
        expect(
            policy.activeClaim == nil,
            "the replacement contribution remains independently cancellable"
        )
    }

    private static func testPlaybackGateDefersTheWholeRefresh() {
        var gate = SourceRefreshPlaybackGate()
        var permitted = 0
        for _ in 0..<10_000 {
            if gate.permitsRefresh(playerActive: true) { permitted += 1 }
        }
        expect(permitted == 0, "active playback blocks every expensive source refresh request")
        expect(gate.hasDeferredRefresh, "blocked refreshes collapse into one deferred refresh")
        expect(gate.playbackEnded(), "leaving playback releases the deferred refresh once")
        expect(!gate.playbackEnded(), "the deferred refresh cannot be released twice")
        expect(gate.permitsRefresh(playerActive: false), "ordinary detail refresh remains enabled off playback")
        gate.playbackStarted()
        gate.reset()
        expect(!gate.hasDeferredRefresh, "page teardown clears deferred refresh ownership")
    }

    private static func testContinueWatchingHoardWaitsForPlaybackExit() {
        var gate = ContinueWatchingHoardDeferral(activationCheckLimit: 4)
        expect(gate.observe(playerActive: false) == .wait,
               "home hoard does not race descriptor extraction before presentation")
        expect(gate.observe(playerActive: true) == .wait,
               "home hoard remains deferred throughout playback")
        for _ in 0..<10_000 {
            expect(gate.observe(playerActive: true) == .wait,
                   "long playback never releases contribution work")
        }
        expect(gate.observe(playerActive: false) == .run,
               "playback exit releases the owned home hoard exactly once")
        expect(gate.observe(playerActive: false) == .abandon,
               "a released home hoard cannot run twice")
    }

    private static func testContinueWatchingHoardAbandonsWhenPlayerNeverMounts() {
        var gate = ContinueWatchingHoardDeferral(activationCheckLimit: 3)
        expect(gate.observe(playerActive: false) == .wait,
               "activation window starts bounded")
        expect(gate.observe(playerActive: false) == .wait,
               "activation window allows presentation latency")
        expect(gate.observe(playerActive: false) == .abandon,
               "a failed presentation cannot retain an immortal background task")
    }
}
