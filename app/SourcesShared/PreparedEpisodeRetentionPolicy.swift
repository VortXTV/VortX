import Foundation

/// Pure identity policy for retaining a prepared next episode across the player transition.
/// The value itself remains view-owned; this policy makes the generation and target fences testable.
enum PreparedEpisodeRetentionPolicy {
    static func ownsCompletion(
        capturedGeneration: Int,
        currentGeneration: Int,
        capturedOriginEpisodeID: String?,
        currentOriginEpisodeID: String?,
        canceled: Bool
    ) -> Bool {
        !canceled
            && capturedGeneration == currentGeneration
            && capturedOriginEpisodeID == currentOriginEpisodeID
    }

    static func admitsPreparedValue(
        requestedEpisodeID: String,
        returnedEpisodeID: String?
    ) -> Bool {
        requestedEpisodeID == returnedEpisodeID
    }

    static func consumes(requestedEpisodeID: String, preparedEpisodeID: String?) -> Bool {
        requestedEpisodeID == preparedEpisodeID
    }

    /// The exact CoreBridge stream identity that must be advanced before admitting a retained source.
    /// A mismatched value produces no target, so failover can never remain scoped to the outgoing episode.
    static func sourceIdentityTarget(
        requestedEpisodeID: String,
        preparedEpisodeID: String?
    ) -> String? {
        consumes(requestedEpisodeID: requestedEpisodeID, preparedEpisodeID: preparedEpisodeID)
            ? requestedEpisodeID : nil
    }

    /// A second request for the exact issued, still-live pending episode is a reentry, not a superseding
    /// transition. It must leave the retained slot untouched instead of consuming it into work that no-ops.
    static func isPendingReentry(
        requestedEpisodeID: String,
        pendingEpisodeID: String?,
        pendingIssued: Bool,
        pendingTerminal: Bool,
        activeLoadMatches: Bool
    ) -> Bool {
        requestedEpisodeID == pendingEpisodeID
            && pendingIssued
            && !pendingTerminal
            && activeLoadMatches
    }
}

/// Bounded retry state for the retained next-episode preparation on iOS and macOS. The player calls
/// `evaluate` on every accepted playback tick, but one active attempt, two delayed retries, and one final
/// near-credits attempt are the only work it can admit for a target.
struct PreparedEpisodeAttemptPolicy: Equatable {
    struct Attempt: Equatable {
        let targetEpisodeID: String
        let sequence: Int
        let nearCredits: Bool
        let deadline: TimeInterval

        func preparationRequest(
            protectedTorrentHash: String?,
            preparedRemuxGeneration: UInt64 = 0,
            prepareLocalAVPlayerRemux: Bool = false
        ) -> NextEpisodePreparationRequest {
            NextEpisodePreparationRequest(
                episodeID: targetEpisodeID,
                attemptSequence: sequence,
                deadline: deadline,
                nearCredits: nearCredits,
                protectedTorrentHash: protectedTorrentHash,
                preparedRemuxGeneration: preparedRemuxGeneration,
                prepareLocalAVPlayerRemux: prepareLocalAVPlayerRemux
            )
        }
    }

    enum Completion: Equatable {
        case ready
        case retryScheduled
        case exhausted
        case stale
    }

    static let maxRegularAttempts = 3
    static let retryDelays: [TimeInterval] = [20, 60]
    static let halfwayFraction = 0.5
    static let durationlessStartSeconds = 120.0
    static let nearCreditsRemainingSeconds = 100.0
    static let durationlessNearCreditsSeconds = 300.0

    private(set) var targetEpisodeID: String?
    private(set) var activeAttempt: Attempt?
    private(set) var regularAttempts = 0
    private(set) var nearCreditsAttempted = false
    private(set) var nextRetryAt: TimeInterval?
    private(set) var ready = false
    private var nextSequence = 0

    static func isCommitted(position: Double, duration: Double) -> Bool {
        duration > 0
            ? position / duration >= halfwayFraction
            : position >= durationlessStartSeconds
    }

    static func isNearCredits(position: Double, duration: Double) -> Bool {
        duration > 0
            ? duration - position <= nearCreditsRemainingSeconds
            : position >= durationlessNearCreditsSeconds
    }

    static func shouldRearmAfterSourceSwitch(
        hasPendingAdvance: Bool,
        isEpisodePlayback: Bool,
        position: Double,
        duration: Double
    ) -> Bool {
        !hasPendingAdvance
            && isEpisodePlayback
            && isCommitted(position: position, duration: duration)
    }

    mutating func evaluate(
        targetEpisodeID requestedTarget: String,
        position: Double,
        duration: Double,
        now: TimeInterval
    ) -> Attempt? {
        if targetEpisodeID != requestedTarget { reset(for: requestedTarget) }
        guard !ready,
              activeAttempt == nil,
              Self.isCommitted(position: position, duration: duration) else { return nil }

        if regularAttempts < Self.maxRegularAttempts {
            if let nextRetryAt, now < nextRetryAt { return nil }
            regularAttempts += 1
            nextSequence += 1
            let attempt = Attempt(
                targetEpisodeID: requestedTarget,
                sequence: nextSequence,
                nearCredits: false,
                deadline: now + NextEpisodePreparationBudget.attemptTimeout
            )
            activeAttempt = attempt
            self.nextRetryAt = nil
            return attempt
        }

        guard !nearCreditsAttempted,
              Self.isNearCredits(position: position, duration: duration) else { return nil }
        nearCreditsAttempted = true
        nextSequence += 1
        let attempt = Attempt(
            targetEpisodeID: requestedTarget,
            sequence: nextSequence,
            nearCredits: true,
            deadline: now + NextEpisodePreparationBudget.attemptTimeout
        )
        activeAttempt = attempt
        return attempt
    }

    mutating func complete(
        _ attempt: Attempt,
        succeeded: Bool,
        now: TimeInterval
    ) -> Completion {
        guard activeAttempt == attempt,
              targetEpisodeID == attempt.targetEpisodeID else { return .stale }
        activeAttempt = nil
        if succeeded {
            ready = true
            nextRetryAt = nil
            return .ready
        }
        if !attempt.nearCredits, regularAttempts < Self.maxRegularAttempts {
            let delayIndex = regularAttempts - 1
            nextRetryAt = now + Self.retryDelays[delayIndex]
            return .retryScheduled
        }
        nextRetryAt = nil
        return .exhausted
    }

    mutating func reset() {
        targetEpisodeID = nil
        activeAttempt = nil
        regularAttempts = 0
        nearCreditsAttempted = false
        nextRetryAt = nil
        ready = false
        nextSequence = 0
    }

    private mutating func reset(for target: String) {
        reset()
        targetEpisodeID = target
    }
}

/// Lifetime and readiness receipt for one tracker-bearing raw-torrent create issued during iOS/macOS
/// next-episode preparation. The view owns the network request; this lock-protected value owns exactly-once
/// cleanup and exact-target adoption across cancellation, replacement and player admission.
final class PreparedTorrentEngineLease: @unchecked Sendable {
    enum Disposition: Equatable {
        case active
        case adopted
        case abandoned
    }

    let request: NextEpisodePreparationRequest
    let hash: String
    private let lock = NSLock()
    private var disposition: Disposition = .active
    private var createSucceeded = false

    init(request: NextEpisodePreparationRequest, hash: String) {
        self.request = request
        self.hash = hash.lowercased()
    }

    @discardableResult
    func markCreateSucceeded() -> Bool {
        lock.withLock {
            guard disposition == .active, !createSucceeded else { return false }
            createSucceeded = true
            return true
        }
    }

    func canWarm(for candidate: NextEpisodePreparationRequest) -> Bool {
        lock.withLock {
            disposition == .active
                && createSucceeded
                && request == candidate
        }
    }

    func canAdmit(episodeID: String, attemptSequence: Int) -> Bool {
        lock.withLock {
            disposition == .active
                && createSucceeded
                && request.episodeID == episodeID
                && request.attemptSequence == attemptSequence
        }
    }

    @discardableResult
    func adopt(episodeID: String, attemptSequence: Int) -> Bool {
        lock.withLock {
            guard disposition == .active,
                  createSucceeded,
                  request.episodeID == episodeID,
                  request.attemptSequence == attemptSequence else { return false }
            disposition = .adopted
            return true
        }
    }

    /// Returns true exactly once. The caller uses that transition to issue at most one `/remove` request.
    @discardableResult
    func abandon() -> Bool {
        lock.withLock {
            guard disposition == .active else { return false }
            disposition = .abandoned
            return true
        }
    }

    var protectsPlayingEngine: Bool {
        request.protectedTorrentHash?.caseInsensitiveCompare(hash) == .orderedSame
    }

    var currentDisposition: Disposition {
        lock.withLock { disposition }
    }
}

enum PreparedTorrentAdmissionPolicy {
    /// An accepted player command transfers practical ownership to normal playback even if the diagnostic
    /// lease transition unexpectedly fails. Removing the engine after acceptance would tear down live media.
    static func shouldRetireLease(playerCommandIssued: Bool, leaseAdopted: Bool) -> Bool {
        !playerCommandIssued && !leaseAdopted
    }

    /// A raw torrent whose tracker-aware preload lease was adopted already has the exact live engine. Calling
    /// the ordinary playback prime again would issue a duplicate `/create`; only a cold raw torrent needs it.
    static func shouldIssuePlaybackCreate(rawTorrent: Bool, leaseAdopted: Bool) -> Bool {
        rawTorrent && !leaseAdopted
    }
}
