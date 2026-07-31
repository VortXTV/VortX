import Foundation

@main
private enum DiagnosticPlaybackIntegrityPolicyTests {
    private struct Token: Equatable {
        let value: Int
    }

    nonisolated(unsafe) private static var passed = 0

    static func main() {
        testExactPreviewFixture()
        testBoundariesAndCounterexamples()
        testMissingEvidenceAndRuntimeVetoes()
        testAttemptOwnershipAndOneShotVerdict()
        testEpisodeResolutionDeadlineOwnership()
        testTrickplayIdentityGates()
        testEOFFailOpenRequiresFirstFrameOwnership()
        testMismatchRecovery()
        testDeferredResumeDelivery()
        testDeferredResumePersistenceFloor()
        testRetryResumeDeliveryAfterInitialLatch()
        testDeferredResumeGenerationOwnership()
        testMismatchRecoveryDeliversOriginalResume()
        testAcceptedDurationSideEffectOwnership()
        testIssuedPendingEpisodeReentryOwnership()
        print("DiagnosticPlaybackIntegrityPolicyTests: \(passed)/\(passed) passed")
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

    private static func evidence(
        isLibMPV: Bool = true,
        season: Int? = 2,
        episode: Int? = 1,
        isLive: Bool = false,
        isTrailer: Bool = false,
        claimedResolutionRank: Int = 1080,
        actualWidth: Int = 1280,
        actualHeight: Int = 720,
        framesPerSecond: Double = 1,
        durationSeconds: Double = 120,
        trackListObserved: Bool = true,
        audioTrackCount: Int = 0,
        expectedRuntimeSeconds: Double? = 3_600
    ) -> EpisodicAssetSanityPolicy.Evidence {
        .init(
            isLibMPV: isLibMPV,
            season: season,
            episode: episode,
            isLive: isLive,
            isTrailer: isTrailer,
            claimedResolutionRank: claimedResolutionRank,
            actualWidth: actualWidth,
            actualHeight: actualHeight,
            framesPerSecond: framesPerSecond,
            durationSeconds: durationSeconds,
            trackListObserved: trackListObserved,
            audioTrackCount: audioTrackCount,
            expectedRuntimeSeconds: expectedRuntimeSeconds
        )
    }

    private static func testExactPreviewFixture() {
        expect(
            EpisodicAssetSanityPolicy.verdict(for: evidence()) == .reject,
            "the diagnostic 13 1080p-labelled, 720p, 1fps, 120s, audio-less episode asset is rejected"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(actualWidth: 720, actualHeight: 1280)
            ) == .reject,
            "dimension comparison is orientation-safe"
        )
    }

    private static func testBoundariesAndCounterexamples() {
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(framesPerSecond: 1.5, durationSeconds: 180)
            ) == .reject,
            "the strict fps and duration boundaries reject"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(actualWidth: 1281)
            ) == .accept,
            "a dimension above the preview ceiling is not rejected"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(framesPerSecond: 1.501)
            ) == .accept,
            "motion above the strict ceiling is not rejected"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(durationSeconds: 180.001)
            ) == .accept,
            "longer media is not rejected"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(audioTrackCount: 1)
            ) == .accept,
            "an audio-bearing asset is not rejected"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(isLibMPV: false)
            ) == .accept,
            "AVPlayer is outside this libmpv-only guard"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(season: nil)
            ) == .accept,
            "movies and unnumbered media are outside the guard"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(isLive: true)
            ) == .accept,
            "live media is outside the guard"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(isTrailer: true)
            ) == .accept,
            "trailers are outside the guard"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(claimedResolutionRank: 720)
            ) == .accept,
            "a source that only claimed 720p is not a quality mismatch"
        )
    }

    private static func testMissingEvidenceAndRuntimeVetoes() {
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(actualWidth: 0)
            ) == .wait,
            "missing dimensions wait"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(framesPerSecond: 0)
            ) == .wait,
            "missing fps waits"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(durationSeconds: 0)
            ) == .wait,
            "missing duration waits"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(trackListObserved: false)
            ) == .wait,
            "an empty but unobserved track list cannot prove zero audio"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(expectedRuntimeSeconds: 599)
            ) == .accept,
            "a genuinely short expected episode vetoes rejection"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(durationSeconds: 151, expectedRuntimeSeconds: 600)
            ) == .accept,
            "an actual duration above 25 percent of expected vetoes rejection"
        )
        expect(
            EpisodicAssetSanityPolicy.verdict(
                for: evidence(durationSeconds: 150, expectedRuntimeSeconds: 600)
            ) == .reject,
            "the exact 25 percent boundary remains eligible"
        )
    }

    private static func testAttemptOwnershipAndOneShotVerdict() {
        let first = Token(value: 1)
        let second = Token(value: 2)
        var attempt = EpisodicAssetSanityAttempt<Token>()
        attempt.begin(owner: first)
        expect(
            attempt.evaluate(owner: second, evidence: evidence()) == .stale,
            "a stale callback cannot settle another load"
        )
        expect(
            attempt.evaluate(
                owner: first,
                evidence: evidence(trackListObserved: false)
            ) == .waiting,
            "missing evidence leaves the current attempt open"
        )
        expect(
            attempt.evaluate(owner: first, evidence: evidence()) == .rejected,
            "later complete evidence settles the current attempt"
        )
        expect(
            attempt.evaluate(
                owner: first,
                evidence: evidence(audioTrackCount: 1)
            ) == .settled(.reject),
            "a terminal verdict is one-shot and cannot reverse"
        )
        attempt.begin(owner: second)
        expect(
            attempt.evaluate(
                owner: second,
                evidence: evidence(audioTrackCount: 1)
            ) == .accepted,
            "a new logical load resets the verdict"
        )
        expect(
            attempt.evaluate(owner: first, evidence: evidence()) == .stale,
            "the reset makes every old callback inert"
        )

        var incomplete = EpisodicAssetSanityAttempt<Token>()
        incomplete.begin(owner: first)
        expect(
            incomplete.evaluate(
                owner: first,
                evidence: evidence(trackListObserved: false)
            ) == .waiting,
            "incomplete evidence waits during the bounded observation window"
        )
        expect(
            incomplete.acceptIncompleteEvidence(owner: second) == .stale,
            "a stale observation deadline cannot accept another load"
        )
        expect(
            incomplete.acceptIncompleteEvidence(owner: first) == .accepted,
            "the exact load fails open after its bounded observation window"
        )
        expect(
            incomplete.evaluate(owner: first, evidence: evidence()) == .settled(.accept),
            "late preview-shaped evidence cannot reverse a fail-open terminal verdict"
        )
    }

    private static func testEpisodeResolutionDeadlineOwnership() {
        let owner = EpisodeResolutionOwner(
            episodeGeneration: 3,
            sourceGeneration: 7,
            videoID: "tt:2:1"
        )
        expect(
            EpisodeResolutionDeadlinePolicy.decision(
                captured: owner,
                current: owner,
                pendingVideoID: owner.videoID,
                admitted: false,
                exited: false
            ) == .timeOut,
            "the exact still-unadmitted owner times out"
        )
        expect(
            EpisodeResolutionDeadlinePolicy.decision(
                captured: owner,
                current: owner,
                pendingVideoID: owner.videoID,
                admitted: true,
                exited: false
            ) == .ignore,
            "admission atomically retires the deadline"
        )
        expect(
            EpisodeResolutionDeadlinePolicy.decision(
                captured: owner,
                current: .init(
                    episodeGeneration: 4,
                    sourceGeneration: 7,
                    videoID: owner.videoID
                ),
                pendingVideoID: owner.videoID,
                admitted: false,
                exited: false
            ) == .ignore,
            "a superseded episode generation cannot be failed by the old deadline"
        )
        expect(
            EpisodeResolutionDeadlinePolicy.decision(
                captured: owner,
                current: .init(
                    episodeGeneration: 3,
                    sourceGeneration: 8,
                    videoID: owner.videoID
                ),
                pendingVideoID: owner.videoID,
                admitted: false,
                exited: false
            ) == .ignore,
            "a superseded source generation cannot be failed by the old deadline"
        )
        let rearmedOwner = EpisodeResolutionOwner(
            episodeGeneration: owner.episodeGeneration,
            sourceGeneration: owner.sourceGeneration + 1,
            videoID: owner.videoID
        )
        expect(
            EpisodeResolutionDeadlinePolicy.decision(
                captured: rearmedOwner,
                current: rearmedOwner,
                pendingVideoID: rearmedOwner.videoID,
                admitted: false,
                exited: false
            ) == .timeOut,
            "a replacement source can re-arm the same episode under its newly claimed generation"
        )
        expect(
            EpisodeResolutionDeadlinePolicy.decision(
                captured: owner,
                current: nil,
                pendingVideoID: owner.videoID,
                admitted: false,
                exited: false
            ) == .ignore,
            "an invalidated resolution owner makes the old deadline inert"
        )
        expect(
            EpisodeResolutionDeadlinePolicy.decision(
                captured: owner,
                current: owner,
                pendingVideoID: "tt:2:2",
                admitted: false,
                exited: false
            ) == .ignore,
            "a different pending video is not owned by the old deadline"
        )
        expect(
            EpisodeResolutionDeadlinePolicy.decision(
                captured: owner,
                current: owner,
                pendingVideoID: owner.videoID,
                admitted: false,
                exited: true
            ) == .ignore,
            "exit makes the old deadline inert"
        )
    }

    private static func testTrickplayIdentityGates() {
        expect(
            !EpisodeTrickplayIdentityPolicy.shouldRekey(
                committedPendingAdvance: false
            ),
            "a physical source switch does not re-key episode trickplay"
        )
        expect(
            EpisodeTrickplayIdentityPolicy.shouldRekey(
                committedPendingAdvance: true
            ),
            "the incoming first-frame identity commit re-keys exactly once"
        )
        var generation = TrickplayIdentityGeneration()
        let outgoing = generation.advance()
        let incoming = generation.advance()
        expect(
            !generation.accepts(outgoing),
            "a slow outgoing TMDB identity result cannot publish after re-key"
        )
        expect(
            generation.accepts(incoming),
            "the current identity result remains admissible"
        )
    }

    private static func testEOFFailOpenRequiresFirstFrameOwnership() {
        let current = Token(value: 1)
        let stale = Token(value: 2)
        expect(
            !EpisodicAssetSanityPolicy.canAcceptIncompleteEvidenceAtEOF(
                callbackOwner: current,
                deferredFirstFrameOwner: nil,
                hasStartedPlaying: false
            ),
            "a zero-frame EOF cannot fail open"
        )
        expect(
            !EpisodicAssetSanityPolicy.canAcceptIncompleteEvidenceAtEOF(
                callbackOwner: current,
                deferredFirstFrameOwner: stale,
                hasStartedPlaying: true
            ),
            "a stale first-frame owner cannot authorize EOF fail-open"
        )
        expect(
            !EpisodicAssetSanityPolicy.canAcceptIncompleteEvidenceAtEOF(
                callbackOwner: current,
                deferredFirstFrameOwner: current,
                hasStartedPlaying: false
            ),
            "the exact token still requires an observed first frame"
        )
        expect(
            EpisodicAssetSanityPolicy.canAcceptIncompleteEvidenceAtEOF(
                callbackOwner: current,
                deferredFirstFrameOwner: current,
                hasStartedPlaying: true
            ),
            "the exact started load may fail open at EOF"
        )
    }

    private static func testMismatchRecovery() {
        expect(
            EpisodicAssetSanityPolicy.recovery(
                explicitPick: false,
                continueWatching: false,
                hasAlternative: true,
                originalResumeSeconds: 5_400
            ) == .hop(originalResumeSeconds: 5_400),
            "automatic mismatch preserves the original requested resume"
        )
        expect(
            EpisodicAssetSanityPolicy.recovery(
                explicitPick: true,
                continueWatching: true,
                hasAlternative: true,
                originalResumeSeconds: 5_400
            ) == .hop(originalResumeSeconds: 5_400),
            "Continue Watching may recover even though its exact first source is honored"
        )
        expect(
            EpisodicAssetSanityPolicy.recovery(
                explicitPick: true,
                continueWatching: false,
                hasAlternative: true,
                originalResumeSeconds: 5_400
            ) == .showMismatch,
            "an explicit source pick surfaces the mismatch"
        )
        expect(
            EpisodicAssetSanityPolicy.recovery(
                explicitPick: false,
                continueWatching: false,
                hasAlternative: false,
                originalResumeSeconds: 5_400
            ) == .showMismatch,
            "an automatic mismatch with no alternative surfaces the mismatch"
        )
    }

    private static func testDeferredResumeDelivery() {
        expect(
            DeferredResumePolicy.decision(
                targetSeconds: 5_400,
                observedDurationSeconds: 0,
                engineDurationSeconds: 0,
                deadlineReached: false
            ) == .wait,
            "an unknown duration keeps the resume pending"
        )
        expect(
            DeferredResumePolicy.decision(
                targetSeconds: 5_400,
                observedDurationSeconds: 0,
                engineDurationSeconds: 7_200,
                deadlineReached: false
            ) == .seek(to: 5_400),
            "the engine duration can release a resume when the surface duration is still unknown"
        )
        expect(
            DeferredResumePolicy.decision(
                targetSeconds: 5_400,
                observedDurationSeconds: 5_405,
                engineDurationSeconds: 7_200,
                deadlineReached: false
            ) == .clear,
            "a known near-end target clears without seeking"
        )
        expect(
            DeferredResumePolicy.decision(
                targetSeconds: 5_400,
                observedDurationSeconds: 0,
                engineDurationSeconds: 0,
                deadlineReached: true
            ) == .clear,
            "the bounded deadline clears an unresolved resume"
        )
    }

    private static func testDeferredResumePersistenceFloor() {
        var floor = DeferredResumeFloorPolicy.armedFloor(targetSeconds: 5_400)
        expect(
            floor == 5_400,
            "arming a delayed resume immediately installs its persistence floor"
        )
        floor = DeferredResumeFloorPolicy.floorAfterDecision(
            currentFloor: floor,
            targetSeconds: 5_400,
            decision: .wait
        )
        expect(
            floor == 5_400
                && !DeferredResumeFloorPolicy.allowsPersistence(
                    positionSeconds: 1, currentFloor: floor
                ),
            "a low first frame cannot persist while delayed resume waits for duration"
        )
        floor = DeferredResumeFloorPolicy.floorAfterDecision(
            currentFloor: floor,
            targetSeconds: 5_400,
            decision: .seek(to: 5_400)
        )
        expect(
            floor == 5_400,
            "issuing the seek retains the floor until playback confirms it landed"
        )
        floor = DeferredResumeFloorPolicy.floorAfterAcceptedPlayback(
            currentFloor: floor,
            positionSeconds: 5_399
        )
        expect(
            floor == 5_400,
            "a pre-target playback tick cannot release the persistence floor"
        )
        floor = DeferredResumeFloorPolicy.floorAfterAcceptedPlayback(
            currentFloor: floor,
            positionSeconds: 5_400
        )
        expect(
            floor == nil
                && DeferredResumeFloorPolicy.allowsPersistence(
                    positionSeconds: 5_400, currentFloor: floor
                ),
            "the exact accepted post-seek tick releases persistence"
        )
        let abandoned = DeferredResumeFloorPolicy.floorAfterDecision(
            currentFloor: 5_400,
            targetSeconds: 5_400,
            decision: .clear
        )
        expect(
            abandoned == nil,
            "an explicit invalid-target or deadline clear retires its own floor"
        )
        expect(
            DeferredResumeFloorPolicy.floorAfterDecision(
                currentFloor: 7_200,
                targetSeconds: 5_400,
                decision: .clear
            ) == 7_200,
            "a stale clear cannot retire another resume floor"
        )
    }

    private static func testRetryResumeDeliveryAfterInitialLatch() {
        let appliedInitialResume = true
        let owner = Token(value: 1)
        let newerOwner = Token(value: 2)
        expect(
            RetryResumeTargetPolicy.ownedRequestedResume(
                activeOwner: Optional<Token>.none,
                attemptOwner: Optional<Token>.none,
                terminalRetiredOwner: Optional<Token>.none,
                requestedResumeSeconds: 5_400
            ) == nil,
            "nil owner equality cannot revive stale retry state"
        )
        expect(
            RetryResumeTargetPolicy.ownedRequestedResume(
                activeOwner: owner,
                attemptOwner: owner,
                terminalRetiredOwner: nil,
                requestedResumeSeconds: 5_400
            ) == 5_400,
            "the exact active attempt owns its requested retry origin"
        )
        expect(
            RetryResumeTargetPolicy.ownedRequestedResume(
                activeOwner: Optional<Token>.none,
                attemptOwner: owner,
                terminalRetiredOwner: owner,
                requestedResumeSeconds: 5_400
            ) == 5_400,
            "manual Retry preserves the exact source-hop origin after native terminal retirement"
        )
        expect(
            RetryResumeTargetPolicy.ownedRequestedResume(
                activeOwner: newerOwner,
                attemptOwner: owner,
                terminalRetiredOwner: owner,
                requestedResumeSeconds: 5_400
            ) == nil,
            "a newer active command rejects a previously retired attempt owner"
        )
        let retryTarget = RetryResumeTargetPolicy.target(
            isLive: false,
            hasStartedPlaying: false,
            currentTimeSeconds: 0,
            activeRequestedResumeSeconds: 5_400,
            fallbackResumeSeconds: 120,
            persistenceFloorSeconds: nil
        )
        expect(
            appliedInitialResume && retryTarget == 5_400,
            "a consumed initial-resume latch cannot replace the active load's retry origin"
        )

        var attempt = DeferredResumeAttempt()
        let ticket = attempt.begin(targetSeconds: retryTarget)
        var floor = DeferredResumeFloorPolicy.armedFloor(
            targetSeconds: ticket.targetSeconds
        )
        let unknownDuration = DeferredResumePolicy.decision(
            targetSeconds: ticket.targetSeconds,
            observedDurationSeconds: 0,
            engineDurationSeconds: 0,
            deadlineReached: false
        )
        floor = DeferredResumeFloorPolicy.floorAfterDecision(
            currentFloor: floor,
            targetSeconds: ticket.targetSeconds,
            decision: unknownDuration
        )
        expect(
            unknownDuration == .wait
                && !DeferredResumeFloorPolicy.allowsPersistence(
                    positionSeconds: 2, currentFloor: floor
                ),
            "an initially durationless retry blocks low progress persistence"
        )

        let laterDuration = DeferredResumePolicy.decision(
            targetSeconds: ticket.targetSeconds,
            observedDurationSeconds: 0,
            engineDurationSeconds: 7_200,
            deadlineReached: false
        )
        floor = DeferredResumeFloorPolicy.floorAfterDecision(
            currentFloor: floor,
            targetSeconds: ticket.targetSeconds,
            decision: laterDuration
        )
        expect(
            laterDuration == .seek(to: 5_400)
                && floor == 5_400
                && attempt.complete(ticket),
            "a later engine duration delivers the exact retry resume once and retains its floor"
        )
        expect(
            !attempt.complete(ticket),
            "the accepted retry cannot deliver its deferred seek twice"
        )

        expect(
            RetryResumeTargetPolicy.target(
                isLive: false,
                hasStartedPlaying: false,
                currentTimeSeconds: 0,
                activeRequestedResumeSeconds: 3_600,
                fallbackResumeSeconds: 900,
                persistenceFloorSeconds: 5_400
            ) == 5_400,
            "an existing forward-only persistence floor remains the highest retry authority"
        )
        expect(
            RetryResumeTargetPolicy.target(
                isLive: false,
                hasStartedPlaying: true,
                currentTimeSeconds: 2_400,
                activeRequestedResumeSeconds: 5_400,
                fallbackResumeSeconds: 900,
                persistenceFloorSeconds: nil
            ) == 2_400,
            "a started playback retry resumes from its live clock instead of a stale requested origin"
        )
        expect(
            RetryResumeTargetPolicy.target(
                isLive: true,
                hasStartedPlaying: false,
                currentTimeSeconds: 0,
                activeRequestedResumeSeconds: 5_400,
                fallbackResumeSeconds: 900,
                persistenceFloorSeconds: 5_400
            ) == 0,
            "a live retry never inherits a stale VOD origin or persistence floor"
        )
    }

    private static func testDeferredResumeGenerationOwnership() {
        var attempt = DeferredResumeAttempt()
        let first = attempt.begin(targetSeconds: 5_400)
        let replacement = attempt.begin(targetSeconds: 5_400)
        expect(
            !attempt.owns(first) && attempt.owns(replacement),
            "a newer same-target generation retires the stale resume task"
        )
        expect(
            !attempt.complete(first),
            "a stale generation cannot complete the replacement resume"
        )
        expect(
            attempt.complete(replacement),
            "the current generation completes once"
        )
        expect(
            !attempt.complete(replacement),
            "a completed resume cannot seek twice"
        )
    }

    private static func testMismatchRecoveryDeliversOriginalResume() {
        guard case .hop(let originalResume) = EpisodicAssetSanityPolicy.recovery(
            explicitPick: false,
            continueWatching: true,
            hasAlternative: true,
            originalResumeSeconds: 5_400
        ) else {
            fatalError("automatic mismatch must hop")
        }
        var attempt = DeferredResumeAttempt()
        let ticket = attempt.begin(targetSeconds: originalResume)
        expect(
            DeferredResumePolicy.decision(
                targetSeconds: ticket.targetSeconds,
                observedDurationSeconds: 0,
                engineDurationSeconds: 0,
                deadlineReached: false
            ) == .wait,
            "mismatch recovery retains the original resume through slow source startup"
        )
        expect(
            DeferredResumePolicy.decision(
                targetSeconds: ticket.targetSeconds,
                observedDurationSeconds: 7_200,
                engineDurationSeconds: 0,
                deadlineReached: false
            ) == .seek(to: 5_400),
            "mismatch recovery delivers the original 5400-second resume once duration arrives"
        )
        expect(
            attempt.complete(ticket),
            "the delivered mismatch resume completes its exact generation"
        )
    }

    private static func testAcceptedDurationSideEffectOwnership() {
        let current = Token(value: 1)
        let stale = Token(value: 2)
        expect(
            !EpisodicAssetSanityPolicy.canPublishDurationSideEffects(
                callbackOwner: current,
                acceptedOwner: nil,
                durationSeconds: 120
            ),
            "preview duration side effects wait until asset sanity accepts the load"
        )
        expect(
            !EpisodicAssetSanityPolicy.canPublishDurationSideEffects(
                callbackOwner: stale,
                acceptedOwner: current,
                durationSeconds: 3_600
            ),
            "a stale load cannot publish duration-keyed community state"
        )
        expect(
            EpisodicAssetSanityPolicy.canPublishDurationSideEffects(
                callbackOwner: current,
                acceptedOwner: current,
                durationSeconds: 3_600
            ),
            "the exact accepted load may publish duration-keyed community state"
        )
        expect(
            !EpisodicAssetSanityPolicy.canPublishDurationSideEffects(
                callbackOwner: current,
                acceptedOwner: current,
                durationSeconds: 0
            ),
            "a non-positive duration cannot publish duration-keyed community state"
        )
    }

    private static func testIssuedPendingEpisodeReentryOwnership() {
        expect(
            IssuedPendingEpisodeReentryPolicy.shouldPreserve(
                issued: true,
                terminal: false
            ),
            "an issued uncommitted episode is preserved before a newer resolve starts"
        )
        expect(
            !IssuedPendingEpisodeReentryPolicy.shouldPreserve(
                issued: false,
                terminal: false
            ),
            "an unissued pending episode has no active player command to preserve"
        )
        expect(
            !IssuedPendingEpisodeReentryPolicy.shouldPreserve(
                issued: true,
                terminal: true
            ),
            "a terminal pending episode is not restored"
        )
    }
}
