import Foundation

/// Pure scheduling state for the tvOS next-episode preparation pipeline.
///
/// The player ticks roughly four times a second. A failed preload therefore cannot be represented only by
/// "nothing is currently loading": that shape immediately launches the full add-on, ranking and debrid
/// pipeline again on the next tick. This state machine owns one attempt at a time, bounds ordinary retries,
/// and reserves one last attempt for the credits window.
struct NextEpisodePreloadPolicy: Equatable {
    struct Target: Equatable {
        let episodeID: String
        let generation: Int
    }

    enum AttemptKind: Equatable {
        case regular
        case nearCredits
    }

    struct Attempt: Equatable {
        let target: Target
        let sequence: Int
        let kind: AttemptKind
        let startedAt: TimeInterval
        let deadline: TimeInterval
    }

    enum Completion: Equatable {
        case ready
        case retryScheduled
        case exhausted
        case stale
    }

    static let halfwayFraction = 0.4
    static let durationlessStartSeconds = 90.0
    static let nearCreditsRemainingSeconds = 100.0
    static let durationlessNearCreditsSeconds = 300.0
    static let maxRegularAttempts = 3
    static let retryDelays: [TimeInterval] = [20, 60]
    /// Whole preparation budget. Source settlement consumes at most fourteen seconds; the remaining twenty
    /// seconds cover the sequential debrid cache check and playback-link resolve instead of killing a wanted
    /// source immediately after its measured 9-12 second response finally arrives.
    static let attemptTimeout = NextEpisodePreparationBudget.attemptTimeout
    static let addonConcurrencyLimit = NextEpisodePreparationBudget.addonConcurrencyLimit
    /// Whole-batch budget. The selected aggregator's observed tail is about 9-12 seconds, so the batch keeps
    /// two seconds of margin while remaining below the total attempt deadline.
    static let addonFetchBudget = NextEpisodePreparationBudget.addonFetchBudget
    static let minimumResolutionBudget = NextEpisodePreparationBudget.minimumResolutionBudget
    /// General per-request cap for a preload add-on fetch. The remembered manual source overrides this with
    /// `stickyAddonRequestTimeout`; every OTHER add-on keeps this 6s cap (A3, raised from 2s) so a stream-type
    /// debrid add-on has time to answer, while one slow provider cannot stall the concurrent window (the
    /// batch is still bounded by the 14s `addonFetchBudget`).
    static let addonRequestTimeout = NextEpisodePreparationBudget.addonRequestTimeout
    /// Per-request cap for the WANTED (series-sticky) add-on only. The aggregator the viewer picked by hand
    /// (aiostreams/debridio) answers in the measured 9-12 second window. Thirteen seconds covers that tail
    /// with one second of scheduling margin while remaining below both the batch and attempt deadlines.
    static let stickyAddonRequestTimeout = NextEpisodePreparationBudget.stickyAddonRequestTimeout
    /// How far each bounded retry advances the provider window: the provider REACH of one attempt, concurrency
    /// (5) times the ~4 request waves a bounded attempt completes. Pinned to 5 x 4 = 20 (its long-standing
    /// value) rather than re-derived from `addonFetchBudget`, because the budget now ALSO has to cover the
    /// longer sticky-add-on request timeout, and the fair-rotation contract (NextEpisodePreloadPolicyTests) is
    /// tuned to this reach; re-deriving it from the lifted budget would silently change retry coverage, which
    /// the diag-22 source-memory fix has no reason to touch.
    static let providerRotationStride = NextEpisodePreparationBudget.providerRotationStride

    /// One source of truth for both the work-pool deadline and URLRequest timeout. Keeping these separate
    /// previously gave the sticky provider a seven-second pool lease while its request still died at two
    /// seconds, so the user's remembered add-on could never contribute to the prepared episode.
    static func requestTimeout(addon: String, wantedAddon: String?) -> TimeInterval {
        NextEpisodePreparationBudget.requestTimeout(addon: addon, wantedAddon: wantedAddon)
    }

    private(set) var target: Target?
    private(set) var activeAttempt: Attempt?
    private(set) var ready = false
    private(set) var regularAttempts = 0
    private(set) var nearCreditsAttempted = false
    private(set) var nextRetryAt: TimeInterval?
    private var nextSequence = 0

    mutating func evaluate(
        target requestedTarget: Target,
        position: Double,
        duration: Double,
        now: TimeInterval
    ) -> Attempt? {
        if target != requestedTarget {
            reset(for: requestedTarget)
        }
        guard !ready else { return nil }
        guard Self.isCommitted(position: position, duration: duration) else { return nil }

        // A slow add-on/debrid owner cannot monopolize the policy through the credits. Credits preempt an
        // ordinary attempt immediately; otherwise every attempt has one total wall-clock deadline.
        if let active = activeAttempt {
            if Self.isNearCredits(position: position, duration: duration),
               active.kind == .regular,
               !nearCreditsAttempted {
                activeAttempt = nil
                nearCreditsAttempted = true
                nextRetryAt = nil
                regularAttempts = Self.maxRegularAttempts
                return launch(kind: .nearCredits, now: now)
            }
            guard now >= active.deadline else { return nil }
            activeAttempt = nil
            if active.kind == .nearCredits {
                nextRetryAt = nil
                return nil
            }
            nextRetryAt = now
        }

        // Always give the ordinary halfway preload its first attempt. If playback is already in the credits
        // window and that attempt fails, the next tick gets the separate final attempt.
        if regularAttempts == 0 {
            return launchRegular(now: now)
        }

        if Self.isNearCredits(position: position, duration: duration), !nearCreditsAttempted {
            nearCreditsAttempted = true
            nextRetryAt = nil
            regularAttempts = Self.maxRegularAttempts
            return launch(kind: .nearCredits, now: now)
        }

        guard regularAttempts < Self.maxRegularAttempts,
              let retryAt = nextRetryAt,
              now >= retryAt else { return nil }
        return launchRegular(now: now)
    }

    mutating func complete(_ attempt: Attempt, success: Bool, now: TimeInterval) -> Completion {
        guard target == attempt.target, activeAttempt == attempt else { return .stale }
        activeAttempt = nil
        if success {
            ready = true
            nextRetryAt = nil
            return .ready
        }
        guard attempt.kind == .regular,
              regularAttempts < Self.maxRegularAttempts else {
            nextRetryAt = nil
            return .exhausted
        }
        let delayIndex = regularAttempts - 1
        guard Self.retryDelays.indices.contains(delayIndex) else {
            nextRetryAt = nil
            return .exhausted
        }
        nextRetryAt = now + Self.retryDelays[delayIndex]
        return .retryScheduled
    }

    /// A URL can resolve successfully at halfway and expire before credits. A failed ranged warm-up reopens
    /// exactly the final credits attempt, without reviving the ordinary retry schedule.
    @discardableResult
    mutating func warmFailed(for requestedTarget: Target) -> Bool {
        guard target == requestedTarget, ready, activeAttempt == nil, !nearCreditsAttempted else {
            return false
        }
        ready = false
        regularAttempts = Self.maxRegularAttempts
        nextRetryAt = nil
        return true
    }

    func accepts(_ attempt: Attempt) -> Bool {
        target == attempt.target && activeAttempt == attempt
    }

    func isReady(for requestedTarget: Target) -> Bool {
        target == requestedTarget && ready
    }

    mutating func invalidate() {
        target = nil
        activeAttempt = nil
        ready = false
        regularAttempts = 0
        nearCreditsAttempted = false
        nextRetryAt = nil
        nextSequence = 0
    }

    private mutating func reset(for requestedTarget: Target) {
        target = requestedTarget
        activeAttempt = nil
        ready = false
        regularAttempts = 0
        nearCreditsAttempted = false
        nextRetryAt = nil
        nextSequence = 0
    }

    private mutating func launchRegular(now: TimeInterval) -> Attempt? {
        regularAttempts += 1
        nextRetryAt = nil
        return launch(kind: .regular, now: now)
    }

    private mutating func launch(kind: AttemptKind, now: TimeInterval) -> Attempt? {
        guard let target else { return nil }
        nextSequence &+= 1
        let attempt = Attempt(
            target: target,
            sequence: nextSequence,
            kind: kind,
            startedAt: now,
            deadline: now + Self.attemptTimeout
        )
        activeAttempt = attempt
        return attempt
    }

    private static func isCommitted(position: Double, duration: Double) -> Bool {
        guard position.isFinite, duration.isFinite, position >= 0 else { return false }
        if duration > 0 {
            return position / duration >= halfwayFraction
        }
        return position >= durationlessStartSeconds
    }

    private static func isNearCredits(position: Double, duration: Double) -> Bool {
        guard position.isFinite, duration.isFinite, position >= 0 else { return false }
        if duration > 0 {
            return duration - position <= nearCreditsRemainingSeconds
        }
        return position >= durationlessNearCreditsSeconds
    }
}

/// Thread-safe lifetime token for the embedded torrent engine prepared behind a
/// next episode. A delayed create completion can inspect the token and remove
/// the engine after invalidation, while an admitted episode marks it adopted.
final class NextEpisodeTorrentPreparationLease: @unchecked Sendable {
    enum Disposition: Equatable {
        case active
        case adopted
        case abandoned
    }

    let target: NextEpisodePreloadPolicy.Target
    let hash: String
    private let lock = NSLock()
    private var disposition: Disposition = .active
    private var createSucceeded = false

    init(target: NextEpisodePreloadPolicy.Target, hash: String) {
        self.target = target
        self.hash = hash
    }

    @discardableResult
    func adopt() -> Bool {
        lock.withLock {
            guard disposition == .active, createSucceeded else { return false }
            disposition = .adopted
            return true
        }
    }

    @discardableResult
    func markCreateSucceeded() -> Bool {
        lock.withLock {
            guard disposition == .active else { return false }
            createSucceeded = true
            return true
        }
    }

    @discardableResult
    func abandon() -> Bool {
        lock.withLock {
            guard disposition == .active else { return false }
            disposition = .abandoned
            return true
        }
    }

    var currentDisposition: Disposition {
        lock.withLock { disposition }
    }

    var requiresCleanupAfterCompletion: Bool {
        currentDisposition == .abandoned
    }

    var canStartRangeWarmup: Bool {
        lock.withLock {
            disposition == .active && createSucceeded
        }
    }
}
