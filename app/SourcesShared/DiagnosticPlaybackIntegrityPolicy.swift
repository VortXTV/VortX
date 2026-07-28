import Foundation

/// Exact ownership for work that resolves an episode before a player command has been admitted.
/// The owner includes every mutable selector that can supersede an in-flight resolve.
struct EpisodeResolutionOwner: Equatable, Sendable {
    let episodeGeneration: Int
    let sourceGeneration: Int
    let videoID: String
}

enum EpisodeResolutionDeadlinePolicy {
    enum Decision: Equatable {
        case ignore
        case keepWaiting
        case timeOut
    }

    /// A deadline may fail only the exact, still-unadmitted attempt that armed it.
    static func decision(
        captured: EpisodeResolutionOwner,
        current: EpisodeResolutionOwner?,
        pendingVideoID: String?,
        admitted: Bool,
        exited: Bool
    ) -> Decision {
        guard !exited, captured == current, pendingVideoID == captured.videoID else {
            return .ignore
        }
        return admitted ? .ignore : .timeOut
    }
}

enum EpisodeTrickplayIdentityPolicy {
    /// A physical source change does not change episode identity. Only the successful first-frame
    /// commit of a parked episode advance may re-key the episode-scoped trickplay stores.
    static func shouldRekey(committedPendingAdvance: Bool) -> Bool {
        committedPendingAdvance
    }
}

/// Small generation gate used by asynchronous TMDB to IMDb identity resolution. A result may
/// publish only while the exact local-cache identity that requested it is still current.
struct TrickplayIdentityGeneration: Equatable, Sendable {
    private(set) var value: UInt64 = 0

    mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }

    func accepts(_ captured: UInt64) -> Bool {
        captured == value
    }
}

enum EpisodicAssetSanityPolicy {
    static let incompleteEvidenceGraceSeconds: Double = 5

    struct Evidence: Equatable {
        let isLibMPV: Bool
        let season: Int?
        let episode: Int?
        let isLive: Bool
        let isTrailer: Bool
        let claimedResolutionRank: Int
        let actualWidth: Int
        let actualHeight: Int
        let framesPerSecond: Double
        let durationSeconds: Double
        let trackListObserved: Bool
        let audioTrackCount: Int
        let expectedRuntimeSeconds: Double?
    }

    enum Verdict: Equatable {
        case wait
        case accept
        case reject
    }

    enum Recovery: Equatable {
        case hop(originalResumeSeconds: Double)
        case showMismatch
    }

    /// Reject only the narrow preview-shaped false asset confirmed in diagnostic 13. Every unknown
    /// or counterexample is fail-open for playback and fail-closed for rejection.
    static func verdict(for evidence: Evidence) -> Verdict {
        guard evidence.isLibMPV,
              let season = evidence.season, season >= 0,
              let episode = evidence.episode, episode > 0,
              !evidence.isLive, !evidence.isTrailer,
              evidence.claimedResolutionRank >= 1080 else {
            return .accept
        }

        guard evidence.actualWidth > 0, evidence.actualHeight > 0,
              evidence.framesPerSecond.isFinite, evidence.framesPerSecond > 0,
              evidence.durationSeconds.isFinite, evidence.durationSeconds > 0,
              evidence.trackListObserved else {
            return .wait
        }

        let longEdge = max(evidence.actualWidth, evidence.actualHeight)
        let shortEdge = min(evidence.actualWidth, evidence.actualHeight)
        guard longEdge <= 1280, shortEdge <= 720,
              evidence.framesPerSecond <= 1.5,
              evidence.durationSeconds <= 180,
              evidence.audioTrackCount == 0 else {
            return .accept
        }

        if let expected = evidence.expectedRuntimeSeconds, expected.isFinite, expected > 0 {
            guard expected >= 600, evidence.durationSeconds <= expected * 0.25 else {
                return .accept
            }
        }
        return .reject
    }

    static func recovery(
        explicitPick: Bool,
        continueWatching: Bool,
        hasAlternative: Bool,
        originalResumeSeconds: Double
    ) -> Recovery {
        if hasAlternative, !explicitPick || continueWatching {
            return .hop(originalResumeSeconds: max(0, originalResumeSeconds))
        }
        return .showMismatch
    }

    /// EOF may close an incomplete-evidence window only after the exact load has rendered a
    /// first frame. A zero-frame EOF is a load failure, never successful playback completion.
    static func canAcceptIncompleteEvidenceAtEOF<Token: Equatable>(
        callbackOwner: Token,
        deferredFirstFrameOwner: Token?,
        hasStartedPlaying: Bool
    ) -> Bool {
        hasStartedPlaying && callbackOwner == deferredFirstFrameOwner
    }
}

/// One logical load owns one terminal sanity verdict. Missing evidence can be re-evaluated, while a
/// stale callback and any callback after a terminal verdict are inert.
struct EpisodicAssetSanityAttempt<Token: Equatable> {
    enum Evaluation: Equatable {
        case stale
        case waiting
        case accepted
        case rejected
        case settled(EpisodicAssetSanityPolicy.Verdict)
    }

    private(set) var owner: Token?
    private(set) var verdict: EpisodicAssetSanityPolicy.Verdict?

    mutating func begin(owner: Token) {
        guard self.owner != owner else { return }
        self.owner = owner
        verdict = nil
    }

    mutating func invalidate() {
        owner = nil
        verdict = nil
    }

    mutating func evaluate(
        owner callbackOwner: Token,
        evidence: EpisodicAssetSanityPolicy.Evidence
    ) -> Evaluation {
        guard callbackOwner == owner else { return .stale }
        if let verdict { return .settled(verdict) }
        switch EpisodicAssetSanityPolicy.verdict(for: evidence) {
        case .wait:
            return .waiting
        case .accept:
            verdict = .accept
            return .accepted
        case .reject:
            verdict = .reject
            return .rejected
        }
    }

    /// A bounded observation window may fail open only for the exact current load. A later callback
    /// cannot reverse that terminal acceptance into a rejection.
    mutating func acceptIncompleteEvidence(owner callbackOwner: Token) -> Evaluation {
        guard callbackOwner == owner else { return .stale }
        if let verdict { return .settled(verdict) }
        verdict = .accept
        return .accepted
    }

    func isAccepted(owner callbackOwner: Token?) -> Bool {
        guard let callbackOwner else { return false }
        return callbackOwner == owner && verdict == .accept
    }

    func isRejected(owner callbackOwner: Token?) -> Bool {
        guard let callbackOwner else { return false }
        return callbackOwner == owner && verdict == .reject
    }
}
