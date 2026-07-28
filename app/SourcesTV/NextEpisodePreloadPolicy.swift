import Foundation

/// A cancellation-aware sliding window for add-on work. Only `limit` operations
/// can run at once, completed values retain input order, and the deadline returns
/// every result that finished before it instead of discarding the partial set.
enum BoundedPreloadWorkPool {
    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        limit: Int,
        timeoutNanoseconds: UInt64,
        operationTimeoutNanoseconds: UInt64? = nil,
        operation: @escaping @Sendable (Input) async -> Output?
    ) async -> [Output?] {
        guard !inputs.isEmpty else { return [] }
        let width = max(1, min(limit, inputs.count))
        return await withTaskGroup(of: (Int, Output?).self) { group in
            var results = Array<Output?>(repeating: nil, count: inputs.count)
            var nextIndex = 0
            var completedCount = 0

            func launch(_ index: Int) {
                let input = inputs[index]
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    return (
                        index,
                        await valueBeforeTimeout(
                            operationTimeoutNanoseconds,
                            operation: { await operation(input) }
                        )
                    )
                }
            }

            for _ in 0..<width {
                launch(nextIndex)
                nextIndex += 1
            }
            group.addTask {
                do {
                    try await Task<Never, Never>.sleep(
                        nanoseconds: timeoutNanoseconds
                    )
                } catch {
                    return (-2, nil)
                }
                return (-1, nil)
            }

            while let (index, output) = await group.next() {
                if index == -1 {
                    group.cancelAll()
                    break
                }
                if index == -2 {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    continue
                }
                results[index] = output
                completedCount += 1
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if completedCount == inputs.count {
                    group.cancelAll()
                    break
                }
                if nextIndex < inputs.count {
                    launch(nextIndex)
                    nextIndex += 1
                }
            }
            group.cancelAll()
            return results
        }
    }

    private static func valueBeforeTimeout<Output: Sendable>(
        _ timeoutNanoseconds: UInt64?,
        operation: @escaping @Sendable () async -> Output?
    ) async -> Output? {
        guard let timeoutNanoseconds else { return await operation() }
        return await withTaskGroup(of: (Bool, Output?).self) { group in
            group.addTask {
                guard !Task.isCancelled else { return (true, nil) }
                return (true, await operation())
            }
            group.addTask {
                do {
                    try await Task<Never, Never>.sleep(
                        nanoseconds: timeoutNanoseconds
                    )
                } catch {
                    return (false, nil)
                }
                return (false, nil)
            }
            let first = await group.next()
            group.cancelAll()
            guard first?.0 == true else { return nil }
            return first?.1
        }
    }
}

/// Rotates which account add-on gets the first bounded fetch slot on each
/// attempt, then maps completed values back to account order before ranking.
enum PreloadProviderRotation {
    static func order(
        count: Int,
        attemptSequence: Int,
        stride: Int
    ) -> [Int] {
        guard count > 0 else { return [] }
        let attemptIndex = max(0, attemptSequence - 1) % count
        let offset = (attemptIndex * (stride % count)) % count
        return (0..<count).map { (offset + $0) % count }
    }

    static func restoreOriginalOrder<Value>(
        _ rotatedValues: [Value?],
        order: [Int],
        count: Int
    ) -> [Value?] {
        guard count > 0 else { return [] }
        var restored = Array<Value?>(repeating: nil, count: count)
        for (rotatedIndex, originalIndex) in order.enumerated()
        where rotatedValues.indices.contains(rotatedIndex)
            && restored.indices.contains(originalIndex) {
            restored[originalIndex] = rotatedValues[rotatedIndex]
        }
        return restored
    }
}

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

    static let halfwayFraction = 0.5
    static let durationlessStartSeconds = 120.0
    static let nearCreditsRemainingSeconds = 100.0
    static let durationlessNearCreditsSeconds = 300.0
    static let maxRegularAttempts = 3
    static let retryDelays: [TimeInterval] = [20, 60]
    static let attemptTimeout: TimeInterval = 15
    static let addonConcurrencyLimit = 5
    static let addonFetchBudget: TimeInterval = 9
    static let addonRequestTimeout: TimeInterval = 2
    static let providerRotationStride = addonConcurrencyLimit
        * max(1, Int(addonFetchBudget / addonRequestTimeout))

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
