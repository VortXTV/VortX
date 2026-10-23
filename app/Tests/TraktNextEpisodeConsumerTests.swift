import Foundation

// UNRUN. Link the real consumer, TraktNextEpisodeProgress, TraktModels,
// TraktSessionID and the complete Trakt watched-inventory proposal. These tests use only
// in-memory continuations and injected closures. They never create a provider transport,
// credential, persistence, native engine, account, device or network request.
@main
enum TraktNextEpisodeConsumerTests {
    private typealias Consumer = TraktNextEpisodeConsumer<String>
    private typealias Progress = TraktNextEpisodeProgress
    private static let session = TraktSessionID(rawValue: "fixture-consumer-session-A")
    private static let owner = "fixture-home-intent-A"
    private static let otherOwner = "fixture-home-intent-B"

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
        func write(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
        func update(_ body: (inout Value) -> Void) { lock.lock(); body(&value); lock.unlock() }
    }

    /// A deterministic continuation gate. `signal()` records the event; `wait()` never uses a timer.
    private actor Signal {
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func signal() {
            signalled = true
            let waiting = waiters
            waiters.removeAll()
            waiting.forEach { $0.resume() }
        }
        func wait() async {
            if signalled { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private enum ProgressMode: Sendable { case next, caughtUp, unavailable, failure }

    private static func entry(_ traktID: Int, imdb: String, title: String = "Fixture show") -> TraktWatchedShowInventoryEntry {
        let raw = Data("""
        {"show":{"title":"\(title)","ids":{"trakt":\(traktID),"imdb":"\(imdb)"}},"last_watched_at":"2026-10-01T09:00:00Z","opaque":{"fixture":true}}
        """.utf8)
        return try! TraktWatchedShowInventoryEntry(rawRowJSON: raw)
    }

    private static func inventory(_ entries: [TraktWatchedShowInventoryEntry], revision: UUID = UUID()) -> TraktWatchedShowInventory {
        .init(sessionID: session, revision: revision, readVersion: 1,
              activityFingerprint: "fixture-activity", entries: entries)
    }

    private static func metadata(_ id: String, episodeID: String = "tt100:2:4", season: Int? = 2, episode: Int? = 4) -> TraktNextEpisodeOwnedMetadata {
        .init(id: id, type: "series", videos: [.init(id: episodeID, season: season, episode: episode)])
    }

    private static func candidate(show: Int = 10, episodeID: Int = 204, id: String = "tt100",
                                  aliases: [String] = [], season: Int = 2, episode: Int = 4,
                                  activity: String? = "2026-10-01T09:00:00Z") -> Progress.Candidate {
        .init(showTraktID: show, episodeTraktID: episodeID, id: id, aliases: aliases,
              name: "Fixture show", season: season, episode: episode, lastWatchedAt: activity)
    }

    private static func lease(
        metadata: [TraktNextEpisodeOwnedMetadata],
        current: Locked<Bool>,
        query: @escaping @Sendable ([TraktNextEpisodeTarget]) async throws -> [TraktNextEpisodeVerdict]
    ) -> TraktNextEpisodeNativeLease {
        .init(metadata: metadata, isCurrent: { current.read() }, query: query)
    }

    private static func dependencies(
        inventoryBox: Locked<TraktWatchedShowInventory?>,
        ownerCurrent: Locked<Bool>,
        clock: Locked<TimeInterval>,
        progressMode: Locked<ProgressMode>,
        progressCalls: Locked<Int>,
        progressGate: Signal? = nil,
        progressRelease: Signal? = nil,
        refreshGate: Signal? = nil,
        refreshRelease: Signal? = nil,
        changed: Locked<Int> = Locked(0),
        error: Error = FixtureError.failed
    ) -> Consumer.Dependencies {
        .init(
            inventory: { _, _ in inventoryBox.read() },
            refreshInventory: { _, current in
                if let refreshGate, let refreshRelease {
                    await refreshGate.signal()
                    await refreshRelease.wait()
                }
                guard current() else { throw CancellationError() }
            },
            progress: { _, _ in
                progressCalls.update { $0 += 1 }
                if let progressGate, let progressRelease {
                    await progressGate.signal()
                    await progressRelease.wait()
                }
                switch progressMode.read() {
                case .next: return .next(candidate())
                case .caughtUp: return .caughtUp
                case .unavailable: return .unavailable(.incompleteEpisodeEvidence)
                case .failure: throw error
                }
            },
            ownerIsCurrent: { _, _ in ownerCurrent.read() },
            uptime: { clock.read() },
            changed: { changed.update { $0 += 1 } }
        )
    }

    private enum FixtureError: Error { case failed }

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    private static func pureMappingCases() {
        let exact = Consumer.map(candidate(), metadata: [metadata("tt100")])
        require(exact?.videoID == "tt100:2:4" && exact?.metaID == "tt100",
                "mapping retains the accepted opaque CoreVideo id")
        let alias = Consumer.map(candidate(id: "tmdb:tv:42", aliases: ["tmdb:42"]),
                                 metadata: [metadata("tmdb:42", episodeID: "episode-real")])
        require(alias?.videoID == "episode-real", "mapping accepts the retained title alias but never invents a video id")
        require(Consumer.map(candidate(season: 0), metadata: [metadata("tt100")]) == nil,
                "invalid season coordinates remain unresolved")
        require(Consumer.map(candidate(), metadata: [metadata("tt100", season: nil)]) == nil,
                "missing metadata season coordinates remain unresolved")
        require(Consumer.map(candidate(), metadata: [metadata("tt100", episode: nil)]) == nil,
                "missing metadata episode coordinates remain unresolved")
        let movieMetadata = TraktNextEpisodeOwnedMetadata(
            id: "tt100", type: "movie", videos: [.init(id: "movie-video", season: 2, episode: 4)]
        )
        require(Consumer.map(candidate(), metadata: [movieMetadata]) == nil,
                "movie metadata cannot satisfy a series next-episode candidate")
        require(Consumer.map(candidate(), metadata: [metadata("tt100"), metadata("tt100", episodeID: "episode-other")]) == nil,
                "duplicate accepted coordinate rows remain unresolved")
        let reusedVideoID = TraktNextEpisodeOwnedMetadata(
            id: "tt100", type: "series",
            videos: [
                .init(id: "reused-video", season: 2, episode: 3),
                .init(id: "reused-video", season: 2, episode: 4)
            ]
        )
        require(Consumer.map(candidate(), metadata: [reusedVideoID]) == nil,
                "a video id reused across episode coordinates remains unresolved")
        require(Consumer.map(candidate(), metadata: [metadata("tt100", episodeID: "")]) == nil,
                "a missing opaque CoreVideo id remains unresolved")
        require(Consumer.map(candidate(id: "unbound"), metadata: [metadata("tt100")]) == nil,
                "unbound provider identity cannot select local metadata")
    }

    private static func seedConsumer(
        inventoryBox: Locked<TraktWatchedShowInventory?>,
        ownerCurrent: Locked<Bool>,
        clock: Locked<TimeInterval>,
        nativeCurrent: Locked<Bool>,
        progressMode: Locked<ProgressMode> = Locked(.next),
        progressCalls: Locked<Int> = Locked(0),
        changed: Locked<Int> = Locked(0),
        queryDisposition: TraktNextEpisodeVerdict.Disposition = .eligible
    ) async -> (Consumer, Consumer.Dependencies, TraktNextEpisodeNativeLease) {
        let deps = dependencies(inventoryBox: inventoryBox, ownerCurrent: ownerCurrent, clock: clock,
                                progressMode: progressMode, progressCalls: progressCalls, changed: changed)
        let native = lease(metadata: [metadata("tt100")], current: nativeCurrent) { targets in
            targets.map { .init(key: $0.key, disposition: queryDisposition) }
        }
        let consumer = Consumer(dependencies: deps)
        await consumer.refresh(owner: owner, session: session, native: native)
        return (consumer, deps, native)
    }

    private static func healthyFlightSurvivesPreCancelledCompetitors() async {
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory([entry(10, imdb: "tt100")]))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let progressCalls = Locked(0), changed = Locked(0), holdRefresh = Locked(false)
        let refreshEntered = Signal(), refreshRelease = Signal()
        let deps = dependencies(inventoryBox: inventoryBox, ownerCurrent: ownerCurrent, clock: clock,
                                progressMode: Locked(.next), progressCalls: progressCalls, changed: changed)
        // Rebuild the tiny dependency value with a continuation-controlled inventory leg. The
        // first refresh seeds the row; only the second visible pulse is suspended.
        let gated = Consumer.Dependencies(
            inventory: deps.inventory,
            refreshInventory: { _, current in
                if holdRefresh.read() {
                    await refreshEntered.signal()
                    await refreshRelease.wait()
                }
                guard current() else { throw CancellationError() }
            },
            progress: deps.progress,
            ownerIsCurrent: deps.ownerIsCurrent,
            uptime: deps.uptime,
            changed: deps.changed
        )
        let consumer = Consumer(dependencies: gated)
        let seedNative = lease(metadata: [metadata("tt100")], current: nativeCurrent) { targets in
            targets.map { .init(key: $0.key, disposition: .eligible) }
        }
        await consumer.refresh(owner: owner, session: session, native: seedNative)
        require(consumer.rows(owner: owner, session: session).count == 1, "seed creates one eligible next row")
        let changedBefore = changed.read()
        let progressBefore = progressCalls.read()
        clock.write(300)
        holdRefresh.write(true)
        let healthy = Task { await consumer.refresh(owner: owner, session: session, native: seedNative) }
        await refreshEntered.wait()
        let same = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await consumer.refresh(owner: owner, session: session, native: seedNative)
        }
        await same.value
        let other = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await consumer.refresh(owner: otherOwner, session: session, native: seedNative)
        }
        await other.value
        require(consumer.rows(owner: owner, session: session).count == 1,
                "pre-cancelled same and different owner calls preserve the prior cache while healthy flight is suspended")
        await refreshRelease.signal()
        await healthy.value
        require(consumer.rows(owner: owner, session: session).count == 1,
                "healthy suspended flight survives pre-cancelled competitors and commits")
        require(changed.read() == changedBefore + 1,
                "healthy suspended flight publishes exactly one post-resume change")
        require(progressCalls.read() == progressBefore + 1,
                "healthy suspended flight performs exactly one bounded provider read after resuming")
    }

    private static func nonCooperatingFinalQueryDoesNotCommit() async {
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory([entry(10, imdb: "tt100")]))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let progressCalls = Locked(0), changed = Locked(0)
        let seeded = await seedConsumer(inventoryBox: inventoryBox, ownerCurrent: ownerCurrent, clock: clock,
                                        nativeCurrent: nativeCurrent, progressCalls: progressCalls, changed: changed)
        let queryEntered = Signal(), queryRelease = Signal(), queryMode = Locked(true)
        let native = lease(metadata: [metadata("tt100")], current: nativeCurrent) { targets in
            if queryMode.read() { await queryEntered.signal(); await queryRelease.wait() }
            return targets.map { .init(key: $0.key, disposition: .eligible) }
        }
        let consumer = seeded.0
        clock.write(300)
        let before = consumer.rows(owner: owner, session: session)
        let changedBefore = changed.read()
        let flight = Task { await consumer.refresh(owner: owner, session: session, native: native) }
        await queryEntered.wait()
        flight.cancel()
        await queryRelease.signal()
        await flight.value
        require(consumer.rows(owner: owner, session: session).map(\.id) == before.map(\.id),
                "cancelled noncooperating final query cannot replace the prior row snapshot")
        require(changed.read() == changedBefore,
                "cancelled noncooperating final query does not publish a change")
        queryMode.write(false)
    }

    private static func inventoryRevisionInvalidatesProgress() async {
        let first = entry(10, imdb: "tt100"), second = entry(11, imdb: "tt101")
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory([first]))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let progressEntered = Signal(), progressRelease = Signal(), calls = Locked(0), mode = Locked<ProgressMode>(.next)
        let deps = dependencies(inventoryBox: inventoryBox, ownerCurrent: ownerCurrent, clock: clock,
                                progressMode: mode, progressCalls: calls, progressGate: progressEntered,
                                progressRelease: progressRelease)
        let native = lease(metadata: [metadata("tt100")], current: nativeCurrent) { targets in
            targets.map { .init(key: $0.key, disposition: .eligible) }
        }
        let consumer = Consumer(dependencies: deps)
        let flight = Task { await consumer.refresh(owner: owner, session: session, native: native) }
        await progressEntered.wait()
        inventoryBox.write(inventory([second], revision: UUID()))
        await progressRelease.signal()
        await flight.value
        require(consumer.rows(owner: owner, session: session).isEmpty,
                "inventory revision replacement during progress await cannot commit a stale candidate")
    }

    private static func inventoryRevisionInvalidatesNativeQuery() async {
        let initial = entry(10, imdb: "tt100", title: "Initial show")
        let replacement = entry(10, imdb: "tt100", title: "Replaced show")
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory([initial]))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let changed = Locked(0)
        let deps = dependencies(inventoryBox: inventoryBox, ownerCurrent: ownerCurrent, clock: clock,
                                progressMode: Locked(.next), progressCalls: Locked(0), changed: changed)
        let seedNative = lease(metadata: [metadata("tt100")], current: nativeCurrent) { targets in
            targets.map { .init(key: $0.key, disposition: .eligible) }
        }
        let consumer = Consumer(dependencies: deps)
        await consumer.refresh(owner: owner, session: session, native: seedNative)
        let before = consumer.rows(owner: owner, session: session).map(\.id)
        require(before.count == 1, "native-query revision witness starts with a cached row")

        let queryEntered = Signal(), queryRelease = Signal()
        let native = lease(metadata: [metadata("tt100")], current: nativeCurrent) { targets in
            await queryEntered.signal()
            await queryRelease.wait()
            return targets.map { .init(key: $0.key, disposition: .eligible) }
        }
        clock.write(300)
        let flight = Task { await consumer.refresh(owner: owner, session: session, native: native) }
        await queryEntered.wait()
        inventoryBox.write(inventory([replacement], revision: UUID()))
        await queryRelease.signal()
        await flight.value
        require(consumer.rows(owner: owner, session: session).isEmpty,
                "inventory replacement during native query hides the prior row receipt at the old revision")
        require(changed.read() == 1,
                "inventory replacement during native query does not publish a stale transaction")
    }

    private static func nativeRetirementWithdrawsCachedRows() async {
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory([entry(10, imdb: "tt100")]))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let seeded = await seedConsumer(inventoryBox: inventoryBox, ownerCurrent: ownerCurrent, clock: clock,
                                        nativeCurrent: nativeCurrent)
        require(seeded.0.rows(owner: owner, session: session).count == 1, "native seed row is visible")
        nativeCurrent.write(false)
        require(seeded.0.rows(owner: owner, session: session).isEmpty,
                "queued/native owner retirement withdraws an old row without service refresh")
        nativeCurrent.write(true)
        ownerCurrent.write(false)
        require(seeded.0.rows(owner: owner, session: session).isEmpty,
                "retired Home intent withdraws a cached row even when native state becomes current again")
    }

    private static func retireClearsSeededRows() async {
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory([entry(10, imdb: "tt100")]))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let seeded = await seedConsumer(inventoryBox: inventoryBox, ownerCurrent: ownerCurrent, clock: clock,
                                        nativeCurrent: nativeCurrent)
        require(seeded.0.rows(owner: owner, session: session).count == 1,
                "retire witness starts with one seeded row")
        seeded.0.retire()
        require(seeded.0.rows(owner: owner, session: session).isEmpty,
                "synchronous retirement clears private rows for the old owner and session")
    }

    private static func retireInvalidatesSuspendedHealthyFlight() async {
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory([entry(10, imdb: "tt100")]))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let holdRefresh = Locked(false), entered = Signal(), release = Signal(), changed = Locked(0)
        let base = dependencies(inventoryBox: inventoryBox, ownerCurrent: ownerCurrent, clock: clock,
                                progressMode: Locked(.next), progressCalls: Locked(0), changed: changed)
        let gated = Consumer.Dependencies(
            inventory: base.inventory,
            refreshInventory: { _, current in
                if holdRefresh.read() {
                    await entered.signal()
                    await release.wait()
                }
                guard current() else { throw CancellationError() }
            },
            progress: base.progress,
            ownerIsCurrent: base.ownerIsCurrent,
            uptime: base.uptime,
            changed: base.changed
        )
        let native = lease(metadata: [metadata("tt100")], current: nativeCurrent) { targets in
            targets.map { .init(key: $0.key, disposition: .eligible) }
        }
        let consumer = Consumer(dependencies: gated)
        await consumer.refresh(owner: owner, session: session, native: native)
        require(consumer.rows(owner: owner, session: session).count == 1,
                "suspended-flight retirement witness starts with one seeded row")
        let changedBefore = changed.read()
        holdRefresh.write(true)
        clock.write(300)
        let healthy = Task { await consumer.refresh(owner: owner, session: session, native: native) }
        await entered.wait()
        consumer.retire()
        require(consumer.rows(owner: owner, session: session).isEmpty,
                "retire hides the old row before the suspended flight resumes")
        await release.signal()
        await healthy.value
        require(consumer.rows(owner: owner, session: session).isEmpty,
                "a suspended pre-retirement flight cannot repopulate private rows")
        require(changed.read() == changedBefore,
                "a suspended pre-retirement flight cannot publish after synchronous retirement")
    }

    private static func failingFirstShowAdvancesAttemptCursorOnly() async {
        let entries = (1...9).map { entry($0, imdb: "tt\($0)") }
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory(entries))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let order = Locked<[Int]>([]), changed = Locked(0)
        let deps = Consumer.Dependencies(
            inventory: { _, _ in inventoryBox.read() },
            refreshInventory: { _, current in guard current() else { throw CancellationError() } },
            progress: { entry, _ in
                order.update { $0.append(entry.traktID) }
                if entry.traktID == 1 { throw FixtureError.failed }
                return .caughtUp
            },
            ownerIsCurrent: { _, _ in ownerCurrent.read() },
            uptime: { clock.read() },
            changed: { changed.update { $0 += 1 } }
        )
        let native = lease(metadata: (1...9).map { metadata("tt\($0)") }, current: nativeCurrent) { _ in [] }
        let consumer = Consumer(dependencies: deps)

        await consumer.refresh(owner: owner, session: session, native: native)
        require(order.read() == [1], "the persistently failing first show is attempted first")
        require(consumer.rows(owner: owner, session: session).isEmpty,
                "a progress failure publishes no cache or next row")
        require(changed.read() == 0, "a progress failure does not publish a success change")

        clock.write(300)
        await consumer.refresh(owner: owner, session: session, native: native)
        require(order.read() == [1, 2, 3, 4, 5, 6, 7, 8, 9],
                "the next five-minute pulse starts at the later known show after the failed attempt")
        require(changed.read() == 1,
                "the later caught-up batch alone publishes the successful transaction")
    }

    private static func admissionRecheckPreservesHealthyOwner() async {
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory([entry(10, imdb: "tt100")]))
        let activeOwner = Locked(otherOwner), clock = Locked<TimeInterval>(0)
        let nativeACurrent = Locked(true), nativeBCurrent = Locked(true), flipDuringUptime = Locked(false)
        let changed = Locked(0)
        let deps = Consumer.Dependencies(
            inventory: { _, _ in inventoryBox.read() },
            refreshInventory: { _, current in guard current() else { throw CancellationError() } },
            progress: { _, _ in .next(candidate()) },
            ownerIsCurrent: { expected, _ in activeOwner.read() == expected },
            uptime: {
                if flipDuringUptime.read() {
                    flipDuringUptime.write(false)
                    activeOwner.write(otherOwner)
                    nativeACurrent.write(false)
                }
                return clock.read()
            },
            changed: { changed.update { $0 += 1 } }
        )
        let nativeB = lease(metadata: [metadata("tt100")], current: nativeBCurrent) { targets in
            targets.map { .init(key: $0.key, disposition: .eligible) }
        }
        let nativeA = lease(metadata: [metadata("tt100")], current: nativeACurrent) { targets in
            targets.map { .init(key: $0.key, disposition: .eligible) }
        }
        let consumer = Consumer(dependencies: deps)
        await consumer.refresh(owner: otherOwner, session: session, native: nativeB)
        require(consumer.rows(owner: otherOwner, session: session).count == 1,
                "the healthy owner has a seeded current row")

        activeOwner.write(owner)
        flipDuringUptime.write(true)
        await consumer.refresh(owner: owner, session: session, native: nativeA)
        activeOwner.write(otherOwner)
        require(consumer.rows(owner: otherOwner, session: session).count == 1,
                "inside-lock admission recheck preserves the healthy owner cache")
        require(changed.read() == 1,
                "an owner/native retirement during admission does not publish or retire the healthy seed")
    }

    private static func sameSessionOwnerChangesRespectAttemptBudget() async {
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory([entry(10, imdb: "tt100")]))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let calls = Locked(0)
        let seeded = await seedConsumer(inventoryBox: inventoryBox, ownerCurrent: ownerCurrent, clock: clock,
                                        nativeCurrent: nativeCurrent, progressCalls: calls)
        require(calls.read() == 1, "owner-budget witness begins with one provider progress read")

        clock.write(100)
        await seeded.0.refresh(owner: otherOwner, session: session, native: seeded.2)
        clock.write(200)
        await seeded.0.refresh(owner: owner, session: session, native: seeded.2)
        require(calls.read() == 1,
                "same-session Home intent changes retire old rows without bypassing the 300-second provider attempt budget")
        require(seeded.0.rows(owner: owner, session: session).isEmpty,
                "same-session owner replacement does not resurrect the retired cached row")
    }

    private static func sameSessionOwnerRepublishPreservesRotationCursor() async {
        let entries = (1...9).map { entry($0, imdb: "tt\($0)") }
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory(entries))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let calls = Locked(0), order = Locked<[Int]>([]), changed = Locked(0)
        let deps = Consumer.Dependencies(
            inventory: { _, _ in inventoryBox.read() },
            refreshInventory: { _, current in guard current() else { throw CancellationError() } },
            progress: { entry, _ in
                calls.update { $0 += 1 }
                order.update { $0.append(entry.traktID) }
                return .caughtUp
            },
            ownerIsCurrent: { _, _ in ownerCurrent.read() },
            uptime: { clock.read() },
            changed: { changed.update { $0 += 1 } }
        )
        let native = lease(metadata: (1...9).map { metadata("tt\($0)") }, current: nativeCurrent) { _ in [] }
        let consumer = Consumer(dependencies: deps)
        await consumer.refresh(owner: owner, session: session, native: native)
        clock.write(100)
        await consumer.refresh(owner: otherOwner, session: session, native: native)
        require(calls.read() == Consumer.requestsPerRefresh,
                "same-session owner republish preserves the last-attempt throttle")
        clock.write(300)
        await consumer.refresh(owner: otherOwner, session: session, native: native)
        require(calls.read() == Consumer.requestsPerRefresh * 2,
                "the later same-session owner pulse admits one bounded refresh")
        require(order.read() == Array(1...8) + [9, 1, 2, 3, 4, 5, 6, 7],
                "same-session owner republish preserves the rotation cursor at show eight")
        require(changed.read() == 2,
                "only the two admitted owner pulses publish changes")
    }

    private static func duplicateProviderShowsForOneNativeTitleHold() async {
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory([
            entry(10, imdb: "tt100"), entry(11, imdb: "tt100")
        ]))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let progressCalls = Locked(0), nativeCalls = Locked(0), changed = Locked(0)
        let deps = Consumer.Dependencies(
            inventory: { _, _ in inventoryBox.read() },
            refreshInventory: { _, current in guard current() else { throw CancellationError() } },
            progress: { entry, _ in
                progressCalls.update { $0 += 1 }
                return .next(candidate(show: entry.traktID, id: "tt100"))
            },
            ownerIsCurrent: { _, _ in ownerCurrent.read() },
            uptime: { clock.read() },
            changed: { changed.update { $0 += 1 } }
        )
        let native = lease(metadata: [metadata("tt100")], current: nativeCurrent) { targets in
            nativeCalls.update { $0 += 1 }
            return targets.map { .init(key: $0.key, disposition: .eligible) }
        }
        let consumer = Consumer(dependencies: deps)
        await consumer.refresh(owner: owner, session: session, native: native)
        require(progressCalls.read() == 2, "duplicate-title witness evaluates both bounded provider candidates")
        require(nativeCalls.read() == 0,
                "duplicate native title identities are rejected before any native eligibility query")
        require(consumer.rows(owner: owner, session: session).isEmpty,
                "different provider shows mapped to one native title never publish ambiguous rows")
        require(changed.read() == 0, "ambiguous duplicate-title batch does not mutate the published snapshot")
    }

    private static func budgetAndRotation() async {
        let entries = (1...9).map { entry($0, imdb: "tt\($0)") }
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory(entries))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let calls = Locked(0), order = Locked<[Int]>([])
        let deps = Consumer.Dependencies(
            inventory: { _, _ in inventoryBox.read() },
            refreshInventory: { _, current in guard current() else { throw CancellationError() } },
            progress: { entry, _ in
                calls.update { $0 += 1 }
                order.update { $0.append(entry.traktID) }
                return .next(candidate(show: entry.traktID, id: "tt\(entry.traktID)"))
            },
            ownerIsCurrent: { _, _ in ownerCurrent.read() },
            uptime: { clock.read() },
            changed: {}
        )
        let native = lease(metadata: (1...9).map { metadata("tt\($0)", episodeID: "episode-\($0)") }, current: nativeCurrent) { targets in
            targets.map { .init(key: $0.key, disposition: .suppressed) }
        }
        let consumer = Consumer(dependencies: deps)
        await consumer.refresh(owner: owner, session: session, native: native)
        require(calls.read() == Consumer.requestsPerRefresh,
                "one visible refresh stays within the bounded eight-show progress budget")
        require(consumer.rows(owner: owner, session: session).isEmpty,
                "suppressed service results never publish a fabricated next row")
        clock.write(300)
        await consumer.refresh(owner: owner, session: session, native: native)
        require(calls.read() == Consumer.requestsPerRefresh * 2,
                "each admitted refresh stays within the eight-show budget")
        require(order.read() == Array(1...8) + [9, 1, 2, 3, 4, 5, 6, 7],
                "the next refresh rotates to show nine then resumes at show one")
        require(consumer.rows(owner: owner, session: session).isEmpty,
                "suppressed rotated candidates never publish next rows")
    }

    private static func finalNativeQueryFailurePreservesRows() async {
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory([entry(10, imdb: "tt100")]))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let changed = Locked(0)
        let seeded = await seedConsumer(inventoryBox: inventoryBox, ownerCurrent: ownerCurrent, clock: clock,
                                        nativeCurrent: nativeCurrent, changed: changed)
        let before = seeded.0.rows(owner: owner, session: session).map(\.id)
        clock.write(300)
        let failingNative = lease(metadata: [metadata("tt100")], current: nativeCurrent) { _ in
            throw FixtureError.failed
        }
        await seeded.0.refresh(owner: owner, session: session, native: failingNative)
        require(seeded.0.rows(owner: owner, session: session).map(\.id) == before,
                "final native query failure preserves the prior current row snapshot")
        require(changed.read() == 1,
                "final native query failure does not publish a replacement snapshot")
    }

    private static func outcomesAndFailurePreserveRows() async {
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory([entry(10, imdb: "tt100")]))
        let ownerCurrent = Locked(true), clock = Locked<TimeInterval>(0), nativeCurrent = Locked(true)
        let mode = Locked<ProgressMode>(.next), calls = Locked(0)
        let seeded = await seedConsumer(inventoryBox: inventoryBox, ownerCurrent: ownerCurrent, clock: clock,
                                        nativeCurrent: nativeCurrent, progressMode: mode, progressCalls: calls)
        let consumer = seeded.0
        let before = consumer.rows(owner: owner, session: session).map(\.id)
        clock.write(300)
        mode.write(.failure)
        await consumer.refresh(owner: owner, session: session, native: seeded.2)
        require(consumer.rows(owner: owner, session: session).map(\.id) == before,
                "provider failure preserves prior rows and never commits an empty success")
        for disposition in [TraktNextEpisodeVerdict.Disposition.suppressed, .unresolved] {
            clock.update { $0 += 300 }
            mode.write(.next)
            let native = lease(metadata: [metadata("tt100")], current: nativeCurrent) { targets in
                targets.map { .init(key: $0.key, disposition: disposition) }
            }
            await consumer.refresh(owner: owner, session: session, native: native)
            require(consumer.rows(owner: owner, session: session).isEmpty,
                    "\(disposition.rawValue) native verdict never publishes a next row")
        }
        clock.update { $0 += 300 }
        mode.write(.unavailable)
        await consumer.refresh(owner: owner, session: session, native: seeded.2)
        require(consumer.rows(owner: owner, session: session).isEmpty,
                "incomplete provider evidence never publishes a next row")
    }

    private static func initialHomePreparesMetadataWithoutResidentDetail() async {
        let inventoryBox = Locked<TraktWatchedShowInventory?>(inventory([entry(10, imdb: "tt100")]))
        let ownerCurrent = Locked(true), nativeCurrent = Locked(true), clock = Locked<TimeInterval>(1000)
        let calls = Locked<[String]>([])
        let consumer = Consumer(dependencies: .init(inventory: { _, _ in inventoryBox.read() },
            refreshInventory: { _, current in require(current(), "original inventory authority") },
            progress: { _, _ in calls.update { $0.append("progress") }; return .next(candidate()) },
            ownerIsCurrent: { _, _ in ownerCurrent.read() }, uptime: { clock.read() }, changed: {}))
        let native = TraktNextEpisodeNativeLease(metadata: [], isCurrent: { nativeCurrent.read() },
            query: { targets in
                calls.update { $0.append("query") }
                require(targets.first?.videoID == "provider-opaque-episode", "no synthesized video ID")
                return targets.map { .init(key: $0.key, disposition: .eligible) }
            }, prepareMetadata: { id in
                calls.update { $0.append("metadata") }
                return metadata(id, episodeID: "provider-opaque-episode")
            })
        await consumer.refresh(owner: owner, session: session, native: native)
        require(calls.read() == ["metadata", "progress", "query"], "bounded initial-Home production call order")
        require(consumer.rows(owner: owner, session: session).first?.target.videoID == "provider-opaque-episode",
                "initial Home does not require pre-existing resident metadata")
        await consumer.refresh(owner: owner, session: session, native: native)
        require(calls.read().count == 3, "metadata preparation shares existing attempt throttle")
    }

    private static func originalNativeReadRetiresDuringInitialMetadata() async {
        let nativeCurrent = Locked(true), progressCalls = Locked(0)
        let started = Signal(), release = Signal()
        // Keep one immutable complete inventory revision across reads.
        let heldInventory = inventory([entry(10, imdb: "tt100")])
        let fixed = Consumer(dependencies: .init(inventory: { _, _ in heldInventory },
            refreshInventory: { _, _ in }, progress: { _, _ in
                progressCalls.update { $0 += 1 }; return .next(candidate())
            }, ownerIsCurrent: { _, _ in true }, uptime: { 1000 }, changed: {}))
        let native = TraktNextEpisodeNativeLease(metadata: [], isCurrent: { nativeCurrent.read() },
            query: { _ in preconditionFailure("retired metadata must not reach query") },
            prepareMetadata: { id in await started.signal(); await release.wait(); return metadata(id) })
        let task = Task { await fixed.refresh(owner: owner, session: session, native: native) }
        await started.wait(); nativeCurrent.write(false); await release.signal(); await task.value
        require(progressCalls.read() == 0, "queued native retirement blocks later provider progress")
        require(fixed.rows(owner: owner, session: session).isEmpty, "stale preparation publishes no offer")
    }

    static func main() async {
        await initialHomePreparesMetadataWithoutResidentDetail()
        await originalNativeReadRetiresDuringInitialMetadata()
        pureMappingCases()
        await healthyFlightSurvivesPreCancelledCompetitors()
        await nonCooperatingFinalQueryDoesNotCommit()
        await inventoryRevisionInvalidatesProgress()
        await inventoryRevisionInvalidatesNativeQuery()
        await nativeRetirementWithdrawsCachedRows()
        await retireClearsSeededRows()
        await retireInvalidatesSuspendedHealthyFlight()
        await failingFirstShowAdvancesAttemptCursorOnly()
        await admissionRecheckPreservesHealthyOwner()
        await sameSessionOwnerChangesRespectAttemptBudget()
        await duplicateProviderShowsForOneNativeTitleHold()
        await budgetAndRotation()
        await sameSessionOwnerRepublishPreservesRotationCursor()
        await finalNativeQueryFailurePreservesRows()
        await outcomesAndFailurePreserveRows()
        print("UNRUN: Trakt next-episode consumer component checks authored")
    }
}
