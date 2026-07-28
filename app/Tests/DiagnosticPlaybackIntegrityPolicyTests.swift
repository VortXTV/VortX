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
}
