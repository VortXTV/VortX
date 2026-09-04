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

enum DeferredResumePolicy {
    static let maximumPollCount = 240

    enum Decision: Equatable {
        case wait
        case seek(to: Double)
        case clear
    }

    /// A source switch may publish its duration later than the first polling tick. Keep waiting while both
    /// duration views are unknown, prefer the surface's committed value when present, and use the engine's
    /// direct property only as the durationless-event fallback.
    static func decision(
        targetSeconds: Double,
        observedDurationSeconds: Double,
        engineDurationSeconds: Double,
        deadlineReached: Bool
    ) -> Decision {
        guard !deadlineReached,
              targetSeconds.isFinite,
              targetSeconds > 5 else { return .clear }
        let duration: Double
        if observedDurationSeconds.isFinite, observedDurationSeconds > 0 {
            duration = observedDurationSeconds
        } else if engineDurationSeconds.isFinite, engineDurationSeconds > 0 {
            duration = engineDurationSeconds
        } else {
            return .wait
        }
        return duration > targetSeconds + 5 ? .seek(to: targetSeconds) : .clear
    }
}

enum DeferredResumeFloorPolicy {
    /// Arm the persistence fence synchronously with the deferred seek. A low first-frame or exit callback can
    /// otherwise overwrite the saved resume before the next polling tick observes a usable duration.
    static func armedFloor(targetSeconds: Double) -> Double? {
        guard targetSeconds.isFinite, targetSeconds > 5 else { return nil }
        return targetSeconds
    }

    /// Issuing a seek is not proof that the engine reached it. Keep the floor through wait and seek outcomes,
    /// and clear it only when the target is explicitly abandoned.
    static func floorAfterDecision(
        currentFloor: Double?,
        targetSeconds: Double,
        decision: DeferredResumePolicy.Decision
    ) -> Double? {
        guard currentFloor == targetSeconds else { return currentFloor }
        if decision == .clear { return nil }
        return currentFloor
    }

    /// A provenance-gated player tick at or beyond the floor is the first authoritative proof that the seek
    /// landed. Until then every lower progress value remains fenced from persistence.
    static func floorAfterAcceptedPlayback(
        currentFloor: Double?,
        positionSeconds: Double
    ) -> Double? {
        guard let currentFloor,
              positionSeconds.isFinite,
              positionSeconds >= currentFloor else { return currentFloor }
        return nil
    }

    static func allowsPersistence(positionSeconds: Double, currentFloor: Double?) -> Bool {
        guard positionSeconds.isFinite else { return false }
        guard let currentFloor else { return true }
        return positionSeconds >= currentFloor
    }
}

/// A deferred resume seek is optimistic until an engine tick proves it landed. When its bounded watchdog
/// gives up, presentation and persistence must move together to that proven position: keeping the requested
/// target in either surface makes later scrubs or saves operate on a playhead the engine never reached.
enum DeferredResumeSeekReconciliationPolicy {
    struct Abandonment: Equatable, Sendable {
        let presentationSeconds: Double
        let persistenceSeconds: Double
        let retiresResumeFloor: Bool
    }

    /// Returns a reconciliation only for a finite, trustworthy engine position that is still materially below
    /// the requested target. A near-target tick is proof the seek landed; an absent/invalid raw position is not
    /// evidence strong enough to replace the UI or persistence state.
    static func abandonment(
        targetSeconds: Double,
        actualPositionSeconds: Double,
        landingToleranceSeconds: Double,
        watchdogStillOwnsGeneration: Bool
    ) -> Abandonment? {
        guard watchdogStillOwnsGeneration,
              targetSeconds.isFinite,
              actualPositionSeconds.isFinite,
              actualPositionSeconds >= 0,
              landingToleranceSeconds.isFinite,
              landingToleranceSeconds >= 0,
              targetSeconds - actualPositionSeconds > landingToleranceSeconds else {
            return nil
        }
        return Abandonment(
            presentationSeconds: actualPositionSeconds,
            persistenceSeconds: actualPositionSeconds,
            retiresResumeFloor: true
        )
    }
}

enum RetryResumeTargetPolicy {
    /// Select the requested origin only when its attempt has a provable owner. A native terminal failure
    /// retires the exact active token before presenting Retry, so that one recorded retirement remains valid
    /// while the engine has no active token. A newer active token always wins and rejects the retired owner.
    static func ownedRequestedResume<Owner: Equatable>(
        activeOwner: Owner?,
        attemptOwner: Owner?,
        terminalRetiredOwner: Owner?,
        requestedResumeSeconds: Double
    ) -> Double? {
        guard let attemptOwner else { return nil }
        if let activeOwner {
            guard activeOwner == attemptOwner else { return nil }
        } else {
            guard terminalRetiredOwner == attemptOwner else { return nil }
        }
        return requestedResumeSeconds
    }

    /// A pre-first-frame retry belongs to the active load's requested origin, not necessarily the immutable
    /// launch resume. Source hops and pending episode loads can each carry a different requested origin.
    static func target(
        isLive: Bool,
        hasStartedPlaying: Bool,
        currentTimeSeconds: Double,
        activeRequestedResumeSeconds: Double?,
        fallbackResumeSeconds: Double,
        persistenceFloorSeconds: Double?
    ) -> Double {
        guard !isLive else { return 0 }
        let requested: Double
        if hasStartedPlaying {
            requested = sanitized(currentTimeSeconds)
        } else if let activeRequestedResumeSeconds,
                  activeRequestedResumeSeconds.isFinite {
            requested = sanitized(activeRequestedResumeSeconds)
        } else {
            requested = sanitized(fallbackResumeSeconds)
        }
        return max(requested, sanitized(persistenceFloorSeconds ?? 0))
    }

    private static func sanitized(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return max(0, seconds)
    }
}

/// One logical deferred seek owns one generation, even when a replacement asks for the same second. This
/// prevents an older polling task from becoming valid again merely because the target value was reused.
struct DeferredResumeAttempt: Equatable, Sendable {
    struct Ticket: Equatable, Sendable {
        fileprivate let generation: UInt64
        let targetSeconds: Double
    }

    private(set) var generation: UInt64 = 0
    private(set) var targetSeconds: Double?

    mutating func begin(targetSeconds: Double) -> Ticket {
        generation &+= 1
        let sanitized = targetSeconds.isFinite ? max(0, targetSeconds) : 0
        self.targetSeconds = sanitized
        return Ticket(generation: generation, targetSeconds: sanitized)
    }

    mutating func invalidate() {
        generation &+= 1
        targetSeconds = nil
    }

    func owns(_ ticket: Ticket) -> Bool {
        generation == ticket.generation && targetSeconds == ticket.targetSeconds
    }

    @discardableResult
    mutating func complete(_ ticket: Ticket) -> Bool {
        guard owns(ticket) else { return false }
        targetSeconds = nil
        return true
    }
}

enum IssuedPendingEpisodeReentryPolicy {
    /// An issued, non-terminal replacement still owns the active player token until first frame. Preserve it
    /// before a newer episode resolve starts so a timeout can restore that exact pending identity.
    static func shouldPreserve(issued: Bool, terminal: Bool) -> Bool {
        issued && !terminal
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
        // A5b: a stream far shorter than its expected runtime is a wrong or placeholder asset, whether it is a
        // movie or an episode and at any frame rate. This catches the decoy the preview shape below misses: a
        // movie has no episode number (so the episodic guard fails open) and an 18fps 8s clip is not the
        // <=1.5fps preview shape. Reuse the same runtime heuristic (expected known and long, observed at or
        // under a quarter of it). Only decide on a settled duration (a track list has been observed) so an
        // early zero-duration tick never rejects; otherwise fall through and keep the prior fail-open behavior.
        if evidence.isLibMPV, !evidence.isLive, !evidence.isTrailer,
           evidence.trackListObserved,
           evidence.durationSeconds.isFinite, evidence.durationSeconds > 0,
           let expected = evidence.expectedRuntimeSeconds, expected.isFinite, expected >= 600,
           evidence.durationSeconds <= expected * 0.25 {
            return .reject
        }
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

    /// Duration-derived shared keys and release fingerprints may publish only for the exact load whose sanity
    /// verdict is accepted. This keeps a rejected preview's short runtime out of the real episode's stores.
    static func canPublishDurationSideEffects<Token: Equatable>(
        callbackOwner: Token?,
        acceptedOwner: Token?,
        durationSeconds: Double
    ) -> Bool {
        guard let callbackOwner, callbackOwner == acceptedOwner else { return false }
        return durationSeconds.isFinite && durationSeconds > 0
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
