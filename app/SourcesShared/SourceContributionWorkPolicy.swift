import Foundation

/// Per-detail-view ownership for source contribution work. Calls that arrive while
/// one snapshot is being extracted or uploaded collapse into one dirty bit. When the
/// owner finishes, the caller performs at most one refresh using the newest groups.
struct SourceContributionWorkPolicy {
    struct Target: Equatable, Sendable {
        let contentID: String
        let descriptorFingerprint: String
    }

    struct Claim: Equatable, Sendable {
        let generation: UInt64
        let revision: UInt64
    }

    enum RequestDecision: Equatable, Sendable {
        case launch(Claim)
        case coalesced
    }

    enum CompletionDecision: Equatable, Sendable {
        case stale
        case current(needsNewestSnapshot: Bool)
    }

    private(set) var activeClaim: Claim?
    private(set) var lastCompletedTarget: Target?
    private var revision: UInt64 = 0
    private var generation: UInt64 = 0

    mutating func request() -> RequestDecision {
        revision &+= 1
        guard activeClaim == nil else { return .coalesced }
        generation &+= 1
        let claim = Claim(generation: generation, revision: revision)
        activeClaim = claim
        return .launch(claim)
    }

    func shouldSubmit(_ target: Target, for claim: Claim) -> Bool {
        activeClaim == claim && lastCompletedTarget != target
    }

    /// A stale owner cannot finish a newer claim. Current completion reports
    /// whether calls arrived during the operation and need one newest snapshot.
    mutating func complete(
        _ claim: Claim,
        target: Target?,
        acceptedByProcess: Bool
    ) -> CompletionDecision {
        guard activeClaim == claim else { return .stale }
        if acceptedByProcess, let target { lastCompletedTarget = target }
        activeClaim = nil
        return .current(needsNewestSnapshot: revision != claim.revision)
    }

    mutating func cancel() {
        revision &+= 1
        generation &+= 1
        activeClaim = nil
    }
}

/// Stops the detail page's full source refresh pipeline while playback owns the
/// device. Every request received in that interval collapses into one deferred
/// refresh, which is released once playback ends.
struct SourceRefreshPlaybackGate: Equatable {
    private(set) var hasDeferredRefresh = false

    mutating func permitsRefresh(playerActive: Bool) -> Bool {
        guard !playerActive else {
            hasDeferredRefresh = true
            return false
        }
        return true
    }

    mutating func playbackStarted() {
        hasDeferredRefresh = true
    }

    /// Returns true exactly once when playback releases deferred work.
    mutating func playbackEnded() -> Bool {
        guard hasDeferredRefresh else { return false }
        hasDeferredRefresh = false
        return true
    }

    mutating func reset() {
        hasDeferredRefresh = false
    }
}

/// A Continue-Watching contribution starts beside player presentation, but must
/// not extract or upload while video owns the device. The owned task observes one
/// playback cycle, then releases exactly once after playback exits. If the player
/// never mounts, the bounded activation window abandons the work.
struct ContinueWatchingHoardDeferral: Equatable {
    enum Decision: Equatable {
        case wait
        case run
        case abandon
    }

    let activationCheckLimit: Int
    private(set) var sawPlayback = false
    private(set) var completed = false
    private var inactiveChecks = 0

    init(activationCheckLimit: Int) {
        self.activationCheckLimit = max(1, activationCheckLimit)
    }

    mutating func observe(playerActive: Bool) -> Decision {
        guard !completed else { return .abandon }
        if playerActive {
            sawPlayback = true
            return .wait
        }
        if sawPlayback {
            completed = true
            return .run
        }
        inactiveChecks += 1
        if inactiveChecks >= activationCheckLimit {
            completed = true
            return .abandon
        }
        return .wait
    }
}
