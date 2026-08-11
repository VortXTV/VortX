import Foundation

/// One player-owned next-episode attempt. The request is created from the retry policy at the playback tick
/// that admitted the work, then passed unchanged through the detail view and provider rotation. Keeping the
/// sequence and absolute deadline in this value prevents every retry from silently behaving like attempt one.
struct NextEpisodePreparationRequest: Equatable, Sendable {
    let episodeID: String
    let attemptSequence: Int
    let deadline: TimeInterval
    let nearCredits: Bool
    /// A season-pack preload may share the engine that is feeding the current episode. Cleanup must not remove
    /// that hash; the ordinary source-switch/exit lifecycle remains its owner.
    let protectedTorrentHash: String?
    /// Player-owned generation minted before source work begins. Unlike the 34-second source deadline, this
    /// identity survives while an already-selected local AVPlayer remux waits for the one producer slot.
    let preparedRemuxGeneration: UInt64
    /// Snapshot of the mounted playback route. The detail resolver has no player controller of its own, so it
    /// may prepare an on-device AVPlayer transport only when the player that requested this work says so.
    let prepareLocalAVPlayerRemux: Bool

    init(
        episodeID: String,
        attemptSequence: Int,
        deadline: TimeInterval,
        nearCredits: Bool,
        protectedTorrentHash: String?,
        preparedRemuxGeneration: UInt64 = 0,
        prepareLocalAVPlayerRemux: Bool = false
    ) {
        self.episodeID = episodeID
        self.attemptSequence = attemptSequence
        self.deadline = deadline
        self.nearCredits = nearCredits
        self.protectedTorrentHash = protectedTorrentHash
        self.preparedRemuxGeneration = preparedRemuxGeneration
        self.prepareLocalAVPlayerRemux = prepareLocalAVPlayerRemux
    }
}

/// A cancellation-aware sliding window for next-episode add-on work. Only `limit` operations can run at
/// once, completed values retain input order, and the deadline returns every result that finished before it.
enum BoundedPreloadWorkPool {
    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        limit: Int,
        timeoutNanoseconds: UInt64,
        operationTimeoutNanoseconds: UInt64? = nil,
        operationTimeoutFor: (@Sendable (Input) -> UInt64?)? = nil,
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
                let perOperationTimeout = operationTimeoutFor?(input) ?? operationTimeoutNanoseconds
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    return (
                        index,
                        await valueBeforeTimeout(
                            perOperationTimeout,
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
                    try await Task<Never, Never>.sleep(nanoseconds: timeoutNanoseconds)
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
                    try await Task<Never, Never>.sleep(nanoseconds: timeoutNanoseconds)
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

    /// Race one phase against its generation owner's absolute uptime deadline. Structured task-group
    /// cancellation reaches the losing operation, so no provider or resolver survives invalidation.
    static func valueBeforeDeadline<Output: Sendable>(
        _ deadline: TimeInterval,
        operation: @escaping @Sendable () async -> Output
    ) async -> Output? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, !Task.isCancelled else { return nil }
        return await withTaskGroup(of: (Bool, Output?).self) { group in
            group.addTask {
                guard !Task.isCancelled else { return (false, nil) }
                return (true, await operation())
            }
            group.addTask {
                do {
                    try await Task<Never, Never>.sleep(
                        nanoseconds: UInt64(remaining * 1_000_000_000)
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

/// Rotates account add-ons for bounded attempts, optionally putting the user's sticky source into the first
/// window, then maps completed values back to account order before ranking.
enum PreloadProviderRotation {
    static func order(
        count: Int,
        request: NextEpisodePreparationRequest,
        stride: Int,
        prioritizedIndex: Int? = nil
    ) -> [Int] {
        order(
            count: count,
            attemptSequence: request.attemptSequence,
            stride: stride,
            prioritizedIndex: prioritizedIndex
        )
    }

    static func order(
        count: Int,
        attemptSequence: Int,
        stride: Int,
        prioritizedIndex: Int? = nil
    ) -> [Int] {
        guard count > 0 else { return [] }
        let attemptIndex = max(0, attemptSequence - 1) % count
        let offset = (attemptIndex * (stride % count)) % count
        let rotated = (0..<count).map { (offset + $0) % count }
        guard let prioritizedIndex,
              (0..<count).contains(prioritizedIndex) else { return rotated }
        return [prioritizedIndex] + rotated.filter { $0 != prioritizedIndex }
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

/// Shared source and phase budgets for tvOS and iOS/macOS next-episode preparation.
enum NextEpisodePreparationBudget {
    static let attemptTimeout: TimeInterval = 34
    static let addonConcurrencyLimit = 5
    static let addonFetchBudget: TimeInterval = 14
    static let minimumResolutionBudget: TimeInterval = 20
    static let addonRequestTimeout: TimeInterval = 2
    static let stickyAddonRequestTimeout: TimeInterval = 13
    static let providerRotationStride = addonConcurrencyLimit * 4

    static func requestTimeout(addon: String, wantedAddon: String?) -> TimeInterval {
        let isWanted = wantedAddon.map {
            !$0.isEmpty && addon.caseInsensitiveCompare($0) == .orderedSame
        } ?? false
        return isWanted ? stickyAddonRequestTimeout : addonRequestTimeout
    }
}
