import Foundation

@main
private enum TrickplayUploadPolicyTests {
    nonisolated(unsafe) private static var passed = 0

    static func main() {
        testFixedCaptureCadenceContinuesDuringActivePlayback()
        testCaptureCadenceKeepsWorkBounded()
        testBackwardSeekRestartsCaptureCadence()
        testCaptureSessionIdentityBoundaries()
        testCommunityDurationRekeyPreservesSessionFramesWiring()
        testSameMediaDiskCacheSurvivesRemount()
        testCaptureRequestOwnershipRejectsStaleCallbacks()
        testOneProgressiveAttempt()
        testStoredProgressiveAllowsOneMateriallyFullerFinal()
        testProgressiveDeclineAllowsMateriallyFullerFinal()
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
        testLocalCaptureBreakerOpensAndResets()
        testPlayerSourceHierarchyAndLaunchSafetyWiring()
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

    private static func testFixedCaptureCadenceContinuesDuringActivePlayback() {
        let interval = 10.0
        var lastCaptureTime = 0.0
        for playbackTime in stride(from: interval, through: 120.0, by: interval) {
            expect(
                TrickplayCaptureCadencePolicy.shouldCapture(
                    playbackTime: playbackTime,
                    lastCaptureTime: lastCaptureTime,
                    intervalSeconds: interval,
                    playbackActive: true,
                    isScrubbing: false,
                    captureInFlight: false
                ),
                "every active ten-second slot remains capturable regardless of frame-drop telemetry"
            )
            lastCaptureTime = playbackTime
        }
    }

    private static func testCaptureCadenceKeepsWorkBounded() {
        expect(
            !TrickplayCaptureCadencePolicy.shouldCapture(
                playbackTime: 9.999,
                lastCaptureTime: 0,
                intervalSeconds: 10,
                playbackActive: true,
                isScrubbing: false,
                captureInFlight: false
            ),
            "capture remains bounded to one attempt per ten playback seconds"
        )
        expect(
            !TrickplayCaptureCadencePolicy.shouldCapture(
                playbackTime: 10,
                lastCaptureTime: 0,
                intervalSeconds: 10,
                playbackActive: true,
                isScrubbing: false,
                captureInFlight: true
            ),
            "one in-flight capture coalesces later eligibility ticks"
        )
        expect(
            !TrickplayCaptureCadencePolicy.shouldCapture(
                playbackTime: 10,
                lastCaptureTime: 0,
                intervalSeconds: 10,
                playbackActive: false,
                isScrubbing: false,
                captureInFlight: false
            ),
            "paused or buffering playback does not capture"
        )
        expect(
            !TrickplayCaptureCadencePolicy.shouldCapture(
                playbackTime: 10,
                lastCaptureTime: 0,
                intervalSeconds: 10,
                playbackActive: true,
                isScrubbing: true,
                captureInFlight: false
            ),
            "interactive scrubbing does not compete with background capture"
        )
    }

    private static func testBackwardSeekRestartsCaptureCadence() {
        expect(
            TrickplayCaptureCadencePolicy.shouldCapture(
                playbackTime: 40,
                lastCaptureTime: 120,
                intervalSeconds: 10,
                playbackActive: true,
                isScrubbing: false,
                captureInFlight: false
            ),
            "a backward seek is immediately eligible instead of waiting to catch the old playhead"
        )
        expect(
            !TrickplayCaptureCadencePolicy.shouldCapture(
                playbackTime: 49.999,
                lastCaptureTime: 40,
                intervalSeconds: 10,
                playbackActive: true,
                isScrubbing: false,
                captureInFlight: false
            ),
            "the capture taken after a rewind starts a fresh bounded cadence"
        )
        expect(
            TrickplayCaptureCadencePolicy.shouldCapture(
                playbackTime: 50,
                lastCaptureTime: 40,
                intervalSeconds: 10,
                playbackActive: true,
                isScrubbing: false,
                captureInFlight: false
            ),
            "capture resumes ten playback seconds after the rewind frame"
        )
        expect(
            !TrickplayCaptureCadencePolicy.shouldCapture(
                playbackTime: 110.001,
                lastCaptureTime: 120,
                intervalSeconds: 10,
                playbackActive: true,
                isScrubbing: false,
                captureInFlight: false
            ),
            "sub-interval backward position jitter cannot trigger an extra capture"
        )
        expect(
            TrickplayCaptureCadencePolicy.shouldCapture(
                playbackTime: 110,
                lastCaptureTime: 120,
                intervalSeconds: 10,
                playbackActive: true,
                isScrubbing: false,
                captureInFlight: false
            ),
            "a rewind of exactly one configured interval is immediately eligible"
        )
    }

    private static func testCaptureSessionIdentityBoundaries() {
        let episodeA = "v:tt-series:tt-series:1:1"
        let episodeB = "v:tt-series:tt-series:1:2"
        expect(
            TrickplayCaptureSessionPolicy.transition(
                from: episodeA,
                to: episodeA
            ) == .preserve,
            "an engine or physical-source remount preserves same-episode captures"
        )
        expect(
            TrickplayCaptureSessionPolicy.transition(
                from: episodeA,
                to: episodeB
            ) == .reset,
            "a new episode timeline starts a fresh capture session"
        )
        expect(
            TrickplayCaptureSessionPolicy.transition(
                from: episodeA,
                to: "v:tt-movie:tt-movie"
            ) == .reset,
            "a true media change cannot inherit prior captures"
        )
        expect(
            TrickplayCaptureSessionPolicy.transition(
                from: nil,
                to: episodeA
            ) == .reset,
            "the first stable media identity starts a capture session"
        )
    }

    private static func testCommunityDurationRekeyPreservesSessionFramesWiring() {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent(
            "app/SourcesShared/ScrubThumbnails.swift"
        )
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
              let localStart = source.range(of: "func configure(localCacheKey: String?)"),
              let communityStart = source.range(of: "func configureCommunity("),
              let communityEnd = source.range(
                of: "private var communityResolveTriedFor",
                range: communityStart.upperBound..<source.endIndex
              ) else {
            fatalError("cannot verify ScrubThumbnails capture-session wiring")
        }
        let localConfigure = source[localStart.lowerBound..<communityStart.lowerBound]
        let communityConfigure = source[communityStart.lowerBound..<communityEnd.lowerBound]
        expect(
            localConfigure.contains("TrickplayCaptureSessionPolicy.transition")
                && localConfigure.contains("sessionFrames = []"),
            "a true stable media-key change must clear captured session frames"
        )
        expect(
            communityConfigure.contains("let rekeying = communityKey != nil")
                && !communityConfigure.contains("sessionFrames =")
                && !communityConfigure.contains("sessionFrames.remove"),
            "a provisional-to-real community duration re-key must preserve time-indexed session frames"
        )
    }

    private static func testSameMediaDiskCacheSurvivesRemount() {
        let directory = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent(
            "vortx-trickplay-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let episodeA = "v:tt-series:tt-series:1:1"
        let episodeB = "v:tt-series:tt-series:1:2"
        let frame = Data([0xff, 0xd8, 0x01, 0x02, 0xff, 0xd9])
        let legacyFile = directory.appendingPathComponent(
            "djp0dC1zZXJpZXM6dHQtc2VyaWVzOjE6MQ-41.jpg"
        )
        try! frame.write(to: legacyFile, options: .atomic)
        let firstSession = TrickplayFrameDiskStore(directory: directory)
        try! firstSession.write(frame, mediaKey: episodeA, bucket: 42)

        let remountedSession = TrickplayFrameDiskStore(directory: directory)
        expect(
            remountedSession.data(mediaKey: episodeA, bucket: 41) == frame,
            "the extracted reader preserves the pre-existing cache filename format"
        )
        expect(
            remountedSession.data(mediaKey: episodeA, bucket: 42) == frame,
            "a remounted same-media cache reads the prior session's frame bytes"
        )
        expect(
            remountedSession.data(mediaKey: episodeB, bucket: 42) == nil,
            "a true episode timeline change cannot read the prior identity's frame"
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
        var rejectedFinal = TrickplayUploadPolicy()
        let rejected = started(rejectedFinal.request(
            key: "episode-a", kind: .final,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        _ = rejectedFinal.complete(rejected, outcome: .rejected)
        expect(rejectedFinal.isTerminal, "a rejected teardown set should be terminal")

        var storedFinal = TrickplayUploadPolicy()
        let stored = started(storedFinal.request(
            key: "episode-a", kind: .final,
            frameCount: 20, existingFrameCount: 0, coverageReady: true
        ))!
        _ = storedFinal.complete(stored, outcome: .stored)
        expect(storedFinal.isTerminal, "a stored teardown set should be terminal")
    }

    private static func testProgressiveDeclineAllowsMateriallyFullerFinal() {
        var policy = TrickplayUploadPolicy()
        let progressive = started(policy.request(
            key: "field-episode", kind: .progressive,
            frameCount: 68, existingFrameCount: 67, coverageReady: true
        ))!
        _ = policy.complete(progressive, outcome: .rejected)
        expect(
            !policy.isTerminal,
            "a not_better progressive decline cannot terminally discard later coverage"
        )
        expect(
            policy.request(
                key: "field-episode", kind: .progressive,
                frameCount: 281, existingFrameCount: 67, coverageReady: true
            ) == nil,
            "the declined progressive attempt remains one-shot"
        )
        expect(
            policy.request(
                key: "field-episode", kind: .final,
                frameCount: 84, existingFrameCount: 67, coverageReady: true
            ) == nil,
            "a final must materially exceed the declined 68-frame progressive baseline"
        )
        let final = started(policy.request(
            key: "field-episode", kind: .final,
            frameCount: 281, existingFrameCount: 67, coverageReady: true
        ))
        expect(
            final?.frameCount == 281,
            "the field-shaped 281-frame teardown must survive a 68-frame not_better progressive"
        )
        _ = policy.complete(final!, outcome: .stored)
        expect(policy.isTerminal, "the stored materially fuller final remains terminal")
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

    private static func testLocalCaptureBreakerOpensAndResets() {
        var breaker = TrickplayLocalCaptureBreaker()
        expect(!breaker.recordCapture(hadData: false) && !breaker.isOpen,
               "first nil capture stays below the local-capture breaker threshold")
        expect(!breaker.recordCapture(hadData: false) && !breaker.isOpen,
               "second nil capture stays below the local-capture breaker threshold")
        expect(breaker.recordCapture(hadData: false) && breaker.isOpen,
               "third consecutive nil capture opens the breaker exactly once")
        expect(!breaker.recordCapture(hadData: false),
               "an already-open breaker emits no duplicate transition")
        _ = breaker.recordCapture(hadData: true)
        expect(!breaker.isOpen && breaker.consecutiveNilCaptures == 0,
               "a successful capture resets the local breaker for later captures")
    }

    private static func testPlayerSourceHierarchyAndLaunchSafetyWiring() {
        let tv = try? String(contentsOfFile: "app/SourcesTV/TVPlayerView.swift", encoding: .utf8)
        let detail = try? String(contentsOfFile: "app/SourcesTV/DetailView.swift", encoding: .utf8)
        let sourceRows = tv.flatMap { sourceSection($0, from: "private func sourceRows()", to: "private func audioLanguageFilterRows()") }
        expect(sourceContainsInOrder(sourceRows, [
            "OptionRow(label: \"Quality\"", "OptionRow(label: \"Audio\"", "OptionRow(label: \"Sources\", isHeader: true)"
        ]) && sourceRows?.contains("var rows: [OptionRow] = audioLanguageFilterRows()") == false,
        "in-player source panel must present quality, then audio, then source rows without Audio-first flattening")
        expect(detail?.contains("initialEnginePreference: launchEnginePreference") == true
                   && tv?.contains("initialEnginePreference == .avfoundation, canUseAVPlayerEngine") == true
                   && tv?.contains("if let forced = manualEngineAVPlayer { return forced }") == true,
               "detail launch preference must be threaded before the route latch, conservatively gated, and superseded by live picker changes")
        expect(detail?.contains("AVPlayer when compatible") == true
                   && detail?.contains("Other sources use the safe player route.") == true
                   && sourceContainsInOrder(detail, [
                    "headers: entry.headers,", "initialEnginePreference: launchEnginePreference,", "debridRef: ref"
                   ]),
               "the selector must describe AV compatibility honestly and thread its launch preference before later request members")
    }

    private static func sourceSection(_ source: String, from start: String, to end: String) -> String? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else { return nil }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private static func sourceContainsInOrder(_ source: String?, _ needles: [String]) -> Bool {
        guard let source else { return false }
        var cursor = source.startIndex
        for needle in needles {
            guard let range = source.range(of: needle, range: cursor..<source.endIndex) else { return false }
            cursor = range.upperBound
        }
        return true
    }
}
