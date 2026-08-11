// Standalone strict-concurrency contract for the bounded next-episode preparation scheduler.
//
//   xcrun swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/next-episode-preload-policy \
//     app/SourcesShared/NextEpisodePreparationWork.swift \
//     app/SourcesTV/NextEpisodePreloadPolicy.swift \
//     app/Tests/NextEpisodePreloadPolicyTests.swift && /tmp/next-episode-preload-policy

import Foundation

@main
struct NextEpisodePreloadPolicyTests {
    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var failed = 0

    static func main() async {
        tickStormIsBounded()
        retriesAreBounded()
        nearCreditsGetsOneFinalAttempt()
        successLatches()
        generationRejectsStaleCompletion()
        warmFailureGetsOneRefresh()
        creditsPreemptAnInFlightAttempt()
        timedOutAttemptCannotOwnThePolicyForever()
        requestTimeoutMatchesThePoolLease()
        stickyProviderBudgetCoversMeasuredSettlement()
        delayedTorrentPrepareHonorsInvalidation()
        admittedTorrentPrepareIsNotRemoved()
        rangeWarmupWaitsForCreateSuccess()
        await addonFanoutIsBoundedAndRetainsPartialResults()
        await addonResultsRetainInputOrder()
        await hungFirstWindowAdvancesToLaterAddons()
        await boundedRetriesRotateWithoutChangingAccountOrder()
        productionAttemptWiringRotatesEveryRetry()
        stickyAtTailStartsFirstAndRestoresAccountOrder()
        await cancellationStopsSchedulingNewAddons()
        await absoluteDeadlineCancelsTheWrappedOperation()

        print("")
        print(failed == 0 ? "ALL PASS (\(passed) checks)" : "FAILURES: \(failed) of \(passed + failed) checks")
        exit(failed == 0 ? 0 : 1)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
            print("PASS  \(message)")
        } else {
            failed += 1
            print("FAIL  \(message)")
        }
    }

    private static func target(_ generation: Int = 1) -> NextEpisodePreloadPolicy.Target {
        .init(episodeID: "tt-test:1:2", generation: generation)
    }

    private static func tickStormIsBounded() {
        var policy = NextEpisodePreloadPolicy()
        var launches = 0
        var now = 0.0
        for _ in 0..<2_400 {
            if let attempt = policy.evaluate(
                target: target(), position: 1_000, duration: 2_000, now: now
            ) {
                launches += 1
                _ = policy.complete(attempt, success: false, now: now)
            }
            now += 0.25
        }
        expect(launches == NextEpisodePreloadPolicy.maxRegularAttempts,
               "2,400 player ticks launch only the three bounded regular attempts")
    }

    private static func retriesAreBounded() {
        var policy = NextEpisodePreloadPolicy()
        var now = 0.0
        var launches: [NextEpisodePreloadPolicy.Attempt] = []
        while now < 1_000 {
            if let attempt = policy.evaluate(
                target: target(), position: 1_000, duration: 2_000, now: now
            ) {
                launches.append(attempt)
                _ = policy.complete(attempt, success: false, now: now)
            }
            now += 1
        }
        expect(launches.count == 3, "ordinary failures stop after a finite retry budget")
        expect(launches.allSatisfy { $0.kind == .regular },
               "ordinary retries do not consume the separate credits attempt")
    }

    private static func nearCreditsGetsOneFinalAttempt() {
        var policy = NextEpisodePreloadPolicy()
        let first = policy.evaluate(target: target(), position: 1_000, duration: 2_000, now: 0)
        expect(first?.kind == .regular, "the halfway attempt remains the first attempt")
        if let first { _ = policy.complete(first, success: false, now: 0) }

        let final = policy.evaluate(target: target(), position: 1_910, duration: 2_000, now: 1)
        expect(final?.kind == .nearCredits, "the credits window gets a final attempt before auto-advance")
        if let final { _ = policy.complete(final, success: false, now: 1) }

        var laterLaunches = 0
        for tick in 0..<1_000 {
            if policy.evaluate(
                target: target(), position: 1_950, duration: 2_000, now: 2 + Double(tick) * 0.25
            ) != nil {
                laterLaunches += 1
            }
        }
        expect(laterLaunches == 0, "the final credits attempt cannot turn into a per-tick loop")
    }

    private static func successLatches() {
        var policy = NextEpisodePreloadPolicy()
        let attempt = policy.evaluate(target: target(), position: 1_000, duration: 2_000, now: 0)
        if let attempt { _ = policy.complete(attempt, success: true, now: 0) }
        var laterLaunches = 0
        for tick in 0..<2_000 {
            if policy.evaluate(
                target: target(), position: 1_999, duration: 2_000, now: Double(tick) * 0.25
            ) != nil {
                laterLaunches += 1
            }
        }
        expect(policy.isReady(for: target()), "a successful next episode stays ready")
        expect(laterLaunches == 0, "a successful preload remains latched across every later tick")
    }

    private static func generationRejectsStaleCompletion() {
        var policy = NextEpisodePreloadPolicy()
        let old = policy.evaluate(target: target(1), position: 1_000, duration: 2_000, now: 0)!
        let replacement = policy.evaluate(target: target(2), position: 1_000, duration: 2_000, now: 1)!
        expect(policy.complete(old, success: true, now: 2) == .stale,
               "an old generation cannot publish a ready source")
        expect(policy.accepts(replacement), "the replacement generation keeps ownership")
    }

    private static func warmFailureGetsOneRefresh() {
        var policy = NextEpisodePreloadPolicy()
        let first = policy.evaluate(target: target(), position: 1_000, duration: 2_000, now: 0)!
        _ = policy.complete(first, success: true, now: 0)
        expect(policy.warmFailed(for: target()), "a failed ranged warm-up reopens preparation")
        let refresh = policy.evaluate(target: target(), position: 1_920, duration: 2_000, now: 1)
        expect(refresh?.kind == .nearCredits, "an expired ready URL is refreshed in the credits window")
        if let refresh { _ = policy.complete(refresh, success: false, now: 1) }
        expect(!policy.warmFailed(for: target()), "the refresh path is one-shot")
    }

    private static func creditsPreemptAnInFlightAttempt() {
        var policy = NextEpisodePreloadPolicy()
        let halfway = policy.evaluate(
            target: target(), position: 1_000, duration: 2_000, now: 0
        )!
        let credits = policy.evaluate(
            target: target(), position: 1_910, duration: 2_000, now: 1
        )
        expect(credits?.kind == .nearCredits, "credits preempt a slow halfway owner")
        expect(policy.complete(halfway, success: true, now: 2) == .stale,
               "the preempted halfway owner cannot publish late")
    }

    private static func timedOutAttemptCannotOwnThePolicyForever() {
        var policy = NextEpisodePreloadPolicy()
        let first = policy.evaluate(
            target: target(), position: 1_000, duration: 2_000, now: 0
        )!
        expect(
            policy.evaluate(
                target: target(), position: 1_000, duration: 2_000,
                now: first.deadline - 0.01
            ) == nil,
            "an in-flight attempt keeps ownership until its bounded deadline"
        )
        let replacement = policy.evaluate(
            target: target(), position: 1_000, duration: 2_000,
            now: first.deadline
        )
        expect(replacement?.sequence != first.sequence,
               "a timed-out attempt is replaced instead of blocking through EOF")
    }

    private static func requestTimeoutMatchesThePoolLease() {
        expect(
            NextEpisodePreloadPolicy.requestTimeout(
                addon: "Debridio", wantedAddon: "debridio"
            ) == NextEpisodePreloadPolicy.stickyAddonRequestTimeout,
            "the remembered add-on gets the sticky request timeout case-insensitively"
        )
        expect(
            NextEpisodePreloadPolicy.requestTimeout(
                addon: "Cinemeta", wantedAddon: "Debridio"
            ) == NextEpisodePreloadPolicy.addonRequestTimeout,
            "other add-ons keep the ordinary bounded request timeout"
        )
    }

    private static func stickyProviderBudgetCoversMeasuredSettlement() {
        expect(
            NextEpisodePreloadPolicy.stickyAddonRequestTimeout >= 12,
            "the sticky provider timeout covers the measured 9-12 second settlement tail"
        )
        expect(
            NextEpisodePreloadPolicy.stickyAddonRequestTimeout
                < NextEpisodePreloadPolicy.addonFetchBudget,
            "the sticky provider remains bounded by the whole add-on batch"
        )
        expect(
            NextEpisodePreloadPolicy.addonFetchBudget
                < NextEpisodePreloadPolicy.attemptTimeout,
            "the add-on batch leaves time for ranking and resolution before the attempt deadline"
        )
        expect(
            NextEpisodePreloadPolicy.attemptTimeout
                - NextEpisodePreloadPolicy.addonFetchBudget
                >= NextEpisodePreloadPolicy.minimumResolutionBudget,
            "the post-settlement budget covers cache check plus playback-link resolution"
        )
    }

    private static func delayedTorrentPrepareHonorsInvalidation() {
        let lease = NextEpisodeTorrentPreparationLease(
            target: target(),
            hash: String(repeating: "a", count: 40)
        )
        expect(lease.abandon(), "invalidation owns the active torrent preparation")
        expect(lease.requiresCleanupAfterCompletion,
               "a delayed create completion remains obligated to remove the engine")
        expect(!lease.adopt(), "an abandoned preparation cannot be adopted later")
    }

    private static func admittedTorrentPrepareIsNotRemoved() {
        let lease = NextEpisodeTorrentPreparationLease(
            target: target(),
            hash: String(repeating: "b", count: 40)
        )
        expect(lease.markCreateSucceeded(), "tracker-aware create marks the owned engine ready")
        expect(lease.adopt(), "successful load admission adopts the prepared engine")
        expect(!lease.requiresCleanupAfterCompletion,
               "an adopted engine survives its delayed prepare completion")
        expect(!lease.abandon(), "an adopted engine cannot be abandoned by stale cleanup")
    }

    private static func rangeWarmupWaitsForCreateSuccess() {
        let lease = NextEpisodeTorrentPreparationLease(
            target: target(),
            hash: String(repeating: "c", count: 40)
        )
        expect(!lease.canStartRangeWarmup,
               "a raw torrent cannot issue its ranged file GET before create succeeds")
        expect(!lease.adopt(),
               "an engine whose tracker-aware create has not succeeded cannot be adopted")
        expect(lease.markCreateSucceeded(),
               "a successful tracker-aware create advances the lease")
        expect(lease.canStartRangeWarmup,
               "the ranged file GET becomes eligible only after create success")
    }

    private actor ConcurrencyCounter {
        private(set) var active = 0
        private(set) var maximum = 0
        private(set) var started: [Int] = []

        func begin(_ value: Int) {
            active += 1
            maximum = max(maximum, active)
            started.append(value)
        }

        func end() {
            active -= 1
        }

        func snapshot() -> (maximum: Int, started: [Int]) {
            (maximum, started)
        }
    }

    private static func addonFanoutIsBoundedAndRetainsPartialResults() async {
        let counter = ConcurrencyCounter()
        let results: [Int?] = await BoundedPreloadWorkPool.map(
            Array(0..<50),
            limit: 5,
            timeoutNanoseconds: 80_000_000
        ) { value in
            await counter.begin(value)
            if value < 5 {
                try? await Task<Never, Never>.sleep(nanoseconds: 10_000_000)
            } else {
                try? await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
            }
            await counter.end()
            guard !Task.isCancelled else { return nil }
            return value
        }
        let snapshot = await counter.snapshot()
        expect(snapshot.maximum <= 5,
               "fifty add-ons never exceed the five-request sliding window")
        expect(results.prefix(5).compactMap { $0 } == Array(0..<5),
               "fast completed add-ons survive the attempt deadline")
        expect(results.dropFirst(5).allSatisfy { $0 == nil },
               "unfinished add-ons do not fabricate results after the deadline")
    }

    private static func addonResultsRetainInputOrder() async {
        let results = await BoundedPreloadWorkPool.map(
            Array(0..<12),
            limit: 4,
            timeoutNanoseconds: 1_000_000_000
        ) { value in
            try? await Task<Never, Never>.sleep(
                nanoseconds: UInt64(12 - value) * 1_000_000
            )
            return "addon-\(value)"
        }
        expect(
            results.compactMap { $0 } == (0..<12).map { "addon-\($0)" },
            "out-of-order completions are reassembled in account add-on order"
        )
    }

    private static func hungFirstWindowAdvancesToLaterAddons() async {
        let counter = ConcurrencyCounter()
        let results: [Int?] = await BoundedPreloadWorkPool.map(
            Array(0..<12),
            limit: 5,
            timeoutNanoseconds: 300_000_000,
            operationTimeoutNanoseconds: 40_000_000
        ) { value in
            await counter.begin(value)
            do {
                if value < 5 {
                    try await Task<Never, Never>.sleep(
                        nanoseconds: 1_000_000_000
                    )
                } else {
                    try await Task<Never, Never>.sleep(
                        nanoseconds: 5_000_000
                    )
                }
            } catch {
                await counter.end()
                return nil
            }
            await counter.end()
            guard !Task.isCancelled else { return nil }
            return value
        }
        let snapshot = await counter.snapshot()
        expect(snapshot.maximum <= 5,
               "timed add-on slices never exceed the five-request window")
        expect(snapshot.started.contains(5),
               "five hung account-leading add-ons do not block the next provider")
        expect(results[5] == 5,
               "a later working add-on survives after the hung first window")
    }

    private static func boundedRetriesRotateWithoutChangingAccountOrder() async {
        let counter = ConcurrencyCounter()
        var firstAttemptStarted: [Int] = []
        var secondAttemptResults: [Int] = []

        for sequence in 1...2 {
            let order = PreloadProviderRotation.order(
                count: 50,
                attemptSequence: sequence,
                stride: NextEpisodePreloadPolicy.providerRotationStride
            )
            let rotatedInputs = order.map { $0 }
            let rotatedResults: [Int?] = await BoundedPreloadWorkPool.map(
                rotatedInputs,
                limit: NextEpisodePreloadPolicy.addonConcurrencyLimit,
                timeoutNanoseconds: 190_000_000,
                operationTimeoutNanoseconds: 40_000_000
            ) { value in
                await counter.begin(value)
                do {
                    if value == 23 || value == 37 {
                        try await Task<Never, Never>.sleep(
                            nanoseconds: 5_000_000
                        )
                    } else {
                        try await Task<Never, Never>.sleep(
                            nanoseconds: 1_000_000_000
                        )
                    }
                } catch {
                    await counter.end()
                    return nil
                }
                await counter.end()
                guard !Task.isCancelled else { return nil }
                return value
            }
            let restored = PreloadProviderRotation.restoreOriginalOrder(
                rotatedResults,
                order: order,
                count: 50
            )
            if sequence == 1 {
                firstAttemptStarted = await counter.snapshot().started
            } else {
                secondAttemptResults = restored.compactMap { $0 }
            }
        }

        let snapshot = await counter.snapshot()
        expect(!firstAttemptStarted.contains(37),
               "the working provider is beyond the first bounded attempt window")
        expect(snapshot.started.contains(37),
               "a bounded retry rotates far enough to attempt the later provider")
        expect(secondAttemptResults == [23, 37],
               "rotated fetch results return to original account order before ranking")
        expect(snapshot.maximum <= NextEpisodePreloadPolicy.addonConcurrencyLimit,
               "fair retry rotation preserves the five-request concurrency limit")
    }

    private static func stickyAtTailStartsFirstAndRestoresAccountOrder() {
        let order = PreloadProviderRotation.order(
            count: 50,
            attemptSequence: 1,
            stride: NextEpisodePreloadPolicy.providerRotationStride,
            prioritizedIndex: 49
        )
        expect(order.first == 49,
               "a remembered provider at the account tail enters the first request window")
        expect(Set(order) == Set(0..<50) && order.count == 50,
               "sticky prioritization keeps every provider exactly once")
        let rotated = order.map { Optional("addon-\($0)") }
        let restored = PreloadProviderRotation.restoreOriginalOrder(
            rotated,
            order: order,
            count: 50
        )
        expect(restored.compactMap { $0 } == (0..<50).map { "addon-\($0)" },
               "sticky-first fetching restores account order before ranking")
    }

    private static func productionAttemptWiringRotatesEveryRetry() {
        let expectedLeadingProviders = [0, 20, 40, 10]
        let stickyIndex = 49
        let observed = (1...4).map { sequence -> Int? in
            let request = NextEpisodePreparationRequest(
                episodeID: "tt-test:1:2",
                attemptSequence: sequence,
                deadline: 100,
                nearCredits: sequence == 4,
                protectedTorrentHash: nil
            )
            let order = PreloadProviderRotation.order(
                count: 50,
                request: request,
                stride: NextEpisodePreloadPolicy.providerRotationStride,
                prioritizedIndex: stickyIndex
            )
            expect(order.first == stickyIndex,
                   "attempt \(sequence) keeps the sticky provider in the first window")
            return order.dropFirst().first
        }
        expect(
            observed.compactMap { $0 } == expectedLeadingProviders,
            "player attempts 1, 2, 3 and 4 reach the exact production rotation windows"
        )

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let player = try? String(
            contentsOf: root.appendingPathComponent("app/Sources/PlayerScreen.swift"),
            encoding: .utf8
        )
        let detail = try? String(
            contentsOf: root.appendingPathComponent("app/SourcesiOS/iOSDetailView.swift"),
            encoding: .utf8
        )
        expect(
            player?.contains("let request = attempt.preparationRequest") == true
                && player?.contains("let result = await warm(request)") == true,
            "PlayerScreen passes the admitted attempt request into production warming"
        )
        expect(
            detail?.contains("request: request,\n        stride: NextEpisodePreparationBudget.providerRotationStride") == true,
            "iOS/macOS production warming rotates providers from the player request sequence"
        )
    }

    private static func cancellationStopsSchedulingNewAddons() async {
        let counter = ConcurrencyCounter()
        let task = Task {
            await BoundedPreloadWorkPool.map(
                Array(0..<50),
                limit: 5,
                timeoutNanoseconds: 5_000_000_000
            ) { value in
                await counter.begin(value)
                try? await Task<Never, Never>.sleep(nanoseconds: 1_000_000_000)
                await counter.end()
                return value
            }
        }
        try? await Task<Never, Never>.sleep(nanoseconds: 20_000_000)
        task.cancel()
        _ = await task.value
        let snapshot = await counter.snapshot()
        expect(snapshot.started.count <= 5,
               "canceling an attempt prevents the sliding window from launching more add-ons")
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func mark() {
            lock.withLock { value = true }
        }

        func snapshot() -> Bool {
            lock.withLock { value }
        }
    }

    private static func absoluteDeadlineCancelsTheWrappedOperation() async {
        let flag = CancellationFlag()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let value: Int? = await BoundedPreloadWorkPool.valueBeforeDeadline(
            startedAt + 0.03
        ) {
            await withTaskCancellationHandler {
                do {
                    try await Task<Never, Never>.sleep(nanoseconds: 5_000_000_000)
                    return 7
                } catch {
                    return -1
                }
            } onCancel: {
                flag.mark()
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        expect(value == nil,
               "the absolute preparation deadline returns no late phase value")
        expect(flag.snapshot(),
               "the absolute preparation deadline cancels the wrapped operation")
        expect(elapsed < 0.5,
               "a cooperative wrapped operation cannot hold the owner past its deadline")
    }
}
