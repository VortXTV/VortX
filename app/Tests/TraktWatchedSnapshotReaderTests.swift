import Foundation

// Compile with the ACTUAL TraktWatchedSnapshotReader + WatchedFold. No live network, auth, defaults,
// Application Support or account state is used. See the packet README for the separate engine gate.
enum WatchedTestFailure: Error { case check(String), transport }

func watchedExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw WatchedTestFailure.check(message) }
}

final class WatchedSessionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    func isCurrent() -> Bool { lock.lock(); defer { lock.unlock() }; return current }
    func retire() { lock.lock(); current = false; lock.unlock() }
}

actor WatchedPageFixture {
    struct Step: Sendable {
        let path: String
        let data: Data
        var fails = false
    }
    let steps: [Step]
    let pauseIndex: Int?
    private var calls: [String] = []
    private var paused = false
    private var pauseWaiter: CheckedContinuation<Void, Error>?
    private var resumeWaiter: CheckedContinuation<Void, Error>?
    private var pauseTimeout: Task<Void, Never>?
    private var resumeTimeout: Task<Void, Never>?
    private let timeoutNanoseconds: UInt64

    init(_ steps: [Step], pauseIndex: Int? = nil, timeoutNanoseconds: UInt64 = 10_000_000_000) {
        self.steps = steps; self.pauseIndex = pauseIndex; self.timeoutNanoseconds = timeoutNanoseconds
    }
    func request(_ path: String) async throws -> Data {
        let index = calls.count
        calls.append(path)
        guard index < steps.count, steps[index].path == path else {
            throw WatchedTestFailure.check("unexpected request \(path)")
        }
        if pauseIndex == index {
            // Deliberately ignores cancellation: the production post-await fence must reject this.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                resumeWaiter = continuation
                paused = true
                pauseTimeout?.cancel()
                pauseWaiter?.resume()
                pauseWaiter = nil
                resumeTimeout = Task {
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
                    expireResume()
                }
            }
        }
        if steps[index].fails { throw WatchedTestFailure.transport }
        return steps[index].data
    }
    func waitForPause() async throws {
        if paused { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pauseWaiter = continuation
            pauseTimeout = Task {
                do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
                expirePause()
            }
        }
    }
    private func expirePause() {
        pauseWaiter?.resume(throwing: WatchedTestFailure.check("fixture did not reach suspension before deadline"))
        pauseWaiter = nil
    }
    private func expireResume() {
        resumeWaiter?.resume(throwing: WatchedTestFailure.check("fixture was not resumed before deadline"))
        resumeWaiter = nil
    }
    func resume() { resumeTimeout?.cancel(); resumeWaiter?.resume(); resumeWaiter = nil }
    func paths() -> [String] { calls }
}

enum WatchedReaderCases {
    static let activity = #"{"movies":{"watched_at":"movie-stamp"},"episodes":{"watched_at":"episode-stamp"}}"#
    static let fingerprint = "movie-stamp|episode-stamp"

    static func path(_ type: String, _ page: Int, limit: Int = 250) -> String {
        "/sync/watched/\(type)?page=\(page)&limit=\(limit)"
            + (type == "shows" ? "&extended=progress" : "")
    }
    static func step(_ path: String, _ json: String, fails: Bool = false) -> WatchedPageFixture.Step {
        .init(path: path, data: Data(json.utf8), fails: fails)
    }
    static func movie(_ id: Int) -> String {
        #"{"movie":{"ids":{"trakt":\#(id),"imdb":"tt\#(id)","tmdb":\#(id)}}}"#
    }
    static func show(_ id: Int, season: Int = 1, episode: Int = 1) -> String {
        #"{"show":{"ids":{"trakt":\#(id),"imdb":"tt\#(id)","tmdb":\#(id)},"title":"Fixture \#(id)","year":2020,"future":1.2300e+02},"last_watched_at":"original-watch-\#(id)","seasons":[{"number":\#(season),"episodes":[{"number":\#(episode),"plays":0}]}]}"#
    }
    static func fullSteps(limit: Int = 250) -> [WatchedPageFixture.Step] {
        [
            step("/sync/last_activities", activity),
            step(path("movies", 1, limit: limit), "[\(movie(1))]"),
            step(path("movies", 2, limit: limit), "[\(movie(2))]"),
            step(path("movies", 3, limit: limit), "[]"),
            step(path("shows", 1, limit: limit), "[\(show(3, season: 0, episode: 2))]"),
            step(path("shows", 2, limit: limit), "[\(show(4))]"),
            step(path("shows", 3, limit: limit), "[]")
        ]
    }
    static func emptySteps() -> [WatchedPageFixture.Step] {
        [step("/sync/last_activities", activity),
         step(path("movies", 1), "[]"), step(path("shows", 1), "[]")]
    }
    static func read(
        _ fixture: WatchedPageFixture, fingerprint: String? = nil, version: Int? = nil,
        limits: TraktWatchedSnapshotReader.Limits = .init(),
        fence: WatchedSessionFence = WatchedSessionFence()
    ) async throws -> TraktWatchedSnapshotReader.Snapshot? {
        try await TraktWatchedSnapshotReader.read(
            previousFingerprint: fingerprint, previousReadVersion: version, limits: limits,
            isCurrent: { fence.isCurrent() }, parsingIsCurrent: { fence.isCurrent() },
            request: { try await fixture.request($0) }
        )
    }
    static func expectFailure(
        _ steps: [WatchedPageFixture.Step], _ label: String,
        limits: TraktWatchedSnapshotReader.Limits = .init()
    ) async throws {
        let fixture = WatchedPageFixture(steps)
        do {
            _ = try await read(fixture, limits: limits)
            throw WatchedTestFailure.check("accepted \(label)")
        } catch let failure as WatchedTestFailure {
            // Only the intentional fixture transport error is a legitimate expected failure.
            if case .check = failure { throw failure }
        } catch {
            try watchedExpect(error is TraktWatchedSnapshotReader.Failure, "unexpected error for \(label)")
        }
    }

    static func paginationAndVersions() async throws {
        let fixture = WatchedPageFixture(fullSteps())
        let result = try await read(fixture, fingerprint: fingerprint, version: nil)
        try watchedExpect(result?.watchedIDs == Set([
            "tt1", "tmdb:1", "tmdb:movie:1", "tt2", "tmdb:2", "tmdb:movie:2",
            "tt3", "tmdb:3", "tmdb:tv:3", "tt4", "tmdb:4", "tmdb:tv:4"
        ]), "all short pages and all identity forms must be folded")
        try watchedExpect(result?.episodeKeys == Set([
            "tt3|0|2", "tmdb:3|0|2", "tmdb:tv:3|0|2",
            "tt4|1|1", "tmdb:4|1|1", "tmdb:tv:4|1|1"
        ]), "specials and presence-based watched keys must survive")
        try watchedExpect(result?.activityFingerprint == fingerprint, "cursor is original activity, not wall time")
        try watchedExpect(result?.shows.map(\.traktID) == [3, 4] &&
                          result?.shows.first?.show.title == "Fixture 3" &&
                          result?.shows.first?.show.year == 2020 &&
                          result?.shows.first?.lastWatchedAt == "original-watch-3" &&
                          result?.shows.first?.rawRowJSON == Data(show(3, season: 0, episode: 2).utf8),
                          "complete inventory retains real IDs/metadata/activity and exact raw extensions")
        let requests = await fixture.paths()
        try watchedExpect(requests == fullSteps().map(\.path), "short nonempty pages cannot terminate pagination")

        for version in [0, TraktWatchedSnapshotReader.readVersion + 1] {
            let fixture = WatchedPageFixture(emptySteps())
            let result = try await read(fixture, fingerprint: fingerprint, version: version)
            try watchedExpect(result?.watchedIDs.isEmpty == true, "nonmatching read version forces a real empty read")
            let calls = await fixture.paths()
            try watchedExpect(calls.count == 3, "old/future version cannot skip")
        }
        let unchanged = WatchedPageFixture([step("/sync/last_activities", activity)])
        let skipped = try await read(unchanged, fingerprint: fingerprint, version: TraktWatchedSnapshotReader.readVersion)
        try watchedExpect(skipped == nil, "only positively matching current version skips")
        let unchangedCalls = await unchanged.paths()
        try watchedExpect(unchangedCalls == ["/sync/last_activities"], "skip performs no watched request")

        var unavailable = emptySteps()
        unavailable[0].fails = true
        let unknown = try await read(WatchedPageFixture(unavailable), fingerprint: fingerprint,
                                     version: TraktWatchedSnapshotReader.readVersion)
        try watchedExpect(unknown?.activityFingerprint == nil && unknown?.watchedIDs.isEmpty == true,
                          "failed activities remains fail-open and cannot stamp the old cursor")
        let noMatchRows = [step("/sync/last_activities", activity),
            step(path("movies", 1), #"[{"movie":{"ids":{"trakt":50}}}]"#),
            step(path("movies", 2), "[]"), step(path("shows", 1), "[]")]
        let noMatch = try await read(WatchedPageFixture(noMatchRows))
        try watchedExpect(noMatch?.watchedIDs.isEmpty == true, "Trakt-only ids are traversed, never guessed as catalog ids")
    }

    static func rejectIncompleteAndMalformed() async throws {
        for index in 1..<fullSteps().count {
            var steps = fullSteps()
            steps[index].fails = true
            try await expectFailure(steps, "transport failure at page \(index)")
        }
        let prefix = [step("/sync/last_activities", activity)]
        let malformed = [
            "{}", "[null]", #"[{"movie":{}}]"#,
            #"[{"movie":{"ids":{"trakt":true}}}]"#,
            #"[{"movie":{"ids":{"trakt":1.5}}}]"#,
            #"[{"movie":{"ids":{"trakt":0}}}]"#,
            #"[{"movie":{"ids":{"trakt":1,"tmdb":true}}}]"#,
            #"[{"movie":{"ids":{"trakt":1,"imdb":"tt1|1|2"}}}]"#,
            #"[{"movie":{"ids":{"trakt":1,"imdb":"tt123456789012345678901234567890123"}}}]"#
        ]
        for body in malformed {
            try await expectFailure(prefix + [step(path("movies", 1), body)], "malformed movie page")
        }
        try await expectFailure(prefix + [
            step(path("movies", 1), "[\(movie(1)),\(movie(1))]")
        ], "duplicate within a page")
        try await expectFailure(prefix + [
            step(path("movies", 1), "[\(movie(1)),\(movie(2))]"),
            step(path("movies", 2), "[\(movie(2)),\(movie(1))]")
        ], "reordered/nonprogressing next page")
        for body in [
            #"[{"show":{"ids":{"trakt":1,"imdb":"tt1"}}}]"#,
            #"[{"show":{"ids":{"trakt":1}},"seasons":"not-progress"}]"#,
            #"[{"show":{"ids":{"trakt":1}},"seasons":[{"number":true,"episodes":[]}]}]"#,
            #"[{"show":{"ids":{"trakt":1}},"seasons":[{"number":0,"episodes":[{"number":-1}]}]}]"#
        ] {
            try await expectFailure(prefix + [step(path("movies", 1), "[]"),
                step(path("shows", 1), body)], "missing/malformed requested show progress")
        }
    }

    static func exactBounds() async throws {
        var limits = TraktWatchedSnapshotReader.Limits()
        limits.pageSize = 2; limits.pagesPerType = 3; limits.rows = 4; limits.episodeKeys = 6
        let steps = fullSteps(limit: 2)
        limits.pageBytes = steps.map { $0.data.count }.max()!
        limits.aggregateBytes = steps.reduce(0) { $0 + $1.data.count }
        let exact = try await read(WatchedPageFixture(steps), limits: limits)
        try watchedExpect(exact?.episodeKeys.count == 6, "all exact inclusive caps accept the complete snapshot")
        var small = limits
        small.pagesPerType -= 1
        try await expectFailure(steps, "no empty terminal within page budget", limits: small)
        small = limits; small.rows -= 1
        try await expectFailure(steps, "aggregate row cap", limits: small)
        small = limits; small.episodeKeys -= 1
        try await expectFailure(steps, "episode cap rejects, never truncates", limits: small)
        small = limits; small.pageBytes -= 1
        try await expectFailure(steps, "per-page byte cap", limits: small)
        small = limits; small.aggregateBytes -= 1
        try await expectFailure(steps, "aggregate byte cap including final empty page", limits: small)
        small = .init(); small.pageSize = 1
        try await expectFailure([step("/sync/last_activities", activity),
            step(path("movies", 1, limit: 1), "[\(movie(1)),\(movie(2))]")],
            "server row count above requested bound", limits: small)
    }

    static func cancellationAndSessionAtEveryAwait() async throws {
        for index in fullSteps().indices {
            for cancel in [true, false] {
                let fixture = WatchedPageFixture(fullSteps(), pauseIndex: index)
                let fence = WatchedSessionFence()
                let task = Task.detached { try await read(fixture, fence: fence) }
                try await fixture.waitForPause()
                if cancel { task.cancel() } else { fence.retire() }
                await fixture.resume()
                do {
                    _ = try await task.value
                    throw WatchedTestFailure.check("accepted stale/cancelled return at await \(index)")
                } catch let failure as WatchedTestFailure { throw failure }
                catch {
                    try watchedExpect(cancel ? error is CancellationError :
                        (error as? TraktWatchedSnapshotReader.Failure) == .staleSession,
                        "correct cancellation/session failure at await \(index)")
                }
                let paths = await fixture.paths()
                try watchedExpect(paths == Array(fullSteps().prefix(index + 1)).map(\.path),
                                  "no next request after cancelled/retired await")
            }
        }
        let startGate = WatchedPageFixture([step("start", "[]")], pauseIndex: 0)
        let untouched = WatchedPageFixture(emptySteps())
        let preCancelled = Task.detached {
            _ = try await startGate.request("start")
            return try await read(untouched)
        }
        try await startGate.waitForPause()
        preCancelled.cancel()
        await startGate.resume()
        do {
            _ = try await preCancelled.value
            throw WatchedTestFailure.check("pre-cancelled read was accepted")
        } catch let failure as WatchedTestFailure { throw failure }
        catch { try watchedExpect(error is CancellationError, "pre-cancelled failure type") }
        let noRequests = await untouched.paths()
        try watchedExpect(noRequests.isEmpty, "pre-cancelled read issues no request")
    }

    static func run() async throws {
        try await paginationAndVersions()
        try await rejectIncompleteAndMalformed()
        try await exactBounds()
        try await cancellationAndSessionAtEveryAwait()
        // If a regression never reaches the expected suspension, the witness fails instead of
        // hanging the sole test lane. The outer runner independently bounds each child process.
        let missingPause = WatchedPageFixture([], timeoutNanoseconds: 50_000_000)
        do {
            try await missingPause.waitForPause()
            throw WatchedTestFailure.check("missing suspension unexpectedly succeeded")
        } catch WatchedTestFailure.check(let message) {
            try watchedExpect(message.contains("before deadline"), "missing suspension has a finite failure path")
        }
        let parsing = WatchedPageFixture(fullSteps())
        var checks = 0
        do {
            _ = try await TraktWatchedSnapshotReader.read(
                previousFingerprint: nil, previousReadVersion: nil,
                isCurrent: { true },
                parsingIsCurrent: { checks += 1; return checks < 4 },
                request: { try await parsing.request($0) }
            )
            throw WatchedTestFailure.check("retired in-memory parsing generation was accepted")
        } catch let failure as TraktWatchedSnapshotReader.Failure {
            try watchedExpect(failure == .staleSession && checks == 4,
                              "cheap parsing fence rejects a retired generation without needing credential reads")
        }
    }
}

#if TRAKT_WATCHED_RAW_TESTS
enum WatchedRawRangeCases {
    static func rejects(_ body: Data, maximumBytes: Int? = nil, array: Bool = false) throws {
        do {
            if array {
                _ = try VortxNativeBootstrapArchive.rawJSONArrayValues(body, maximumBytes: maximumBytes ?? body.count)
            } else {
                _ = try VortxNativeBootstrapArchive.rawJSONObjectMembers(body, maximumBytes: maximumBytes ?? body.count)
            }
            throw WatchedTestFailure.check("raw utility accepted a forbidden carrier")
        } catch let failure as WatchedTestFailure { throw failure }
        catch {}
    }
    static func run() throws {
        let value = #"[1.2300e+02,18446744073709551615,0.123456789012345678901,{"a":"escaped\/value"}]"#
        let body = Data(#" { "future\u004bey" : \#(value), "owned":null } "#.utf8)
        let members = try VortxNativeBootstrapArchive.rawJSONObjectMembers(body, maximumBytes: body.count)
        try watchedExpect(members.count == 2 && members[0].key == "futureKey", "raw key decode")
        try watchedExpect(members[0].keyJSON == Data(#""future\u004bey""#.utf8) &&
                          members[0].valueJSON == Data(value.utf8), "raw key/value bytes are not reencoded")
        let values = try VortxNativeBootstrapArchive.rawJSONArrayValues(Data(value.utf8), maximumBytes: body.count)
        try watchedExpect(values[0] == Data("1.2300e+02".utf8) &&
                          values[1] == Data("18446744073709551615".utf8) &&
                          values[2] == Data("0.123456789012345678901".utf8), "raw numbers keep precision/spelling")
        try rejects(body, maximumBytes: body.count - 1)
        for invalid in [
            #"{"a":1,"a":2}"#, #"{"a":1,"\u0061":2}"#,
            "{\"é\":1,\"e\\u0301\":2}", #"{"x":{"a":1,"a":2}}"#,
            #"{"x":[{"a":1,"\u0061":2}]}"#, #"{"a":1} trailing"#,
            #"{"a":01}"#, #"{"a":1e}"#, #"{"a":NaN}"#,
            #"{"a":"\uD800"}"#, #"{"a":true,}"#, "[]"
        ] { try rejects(Data(invalid.utf8)) }
        try rejects(Data([0xff, 0xfe, 0x7b, 0x00, 0x7d, 0x00]))
        try rejects(Data(#"{"a":1}"#.utf8), array: true)
        let deep = Data(("{\"v\":" + String(repeating: "[", count: 130)
            + "0" + String(repeating: "]", count: 130) + "}").utf8)
        try rejects(deep)
        do {
            _ = try VortxNativeBootstrapArchive.rawJSONArrayValues(Data("[1,2]".utf8),
                maximumBytes: 5, maximumValues: 1)
            throw WatchedTestFailure.check("raw array cardinality limit ignored")
        } catch let failure as WatchedTestFailure { throw failure }
        catch {}
        do {
            _ = try VortxNativeBootstrapArchive.rawJSONObjectMembers(Data(#"{"a":1}"#.utf8),
                maximumBytes: 7, maximumMembers: 0)
            throw WatchedTestFailure.check("raw member cardinality limit ignored")
        } catch let failure as WatchedTestFailure { throw failure }
        catch {}
    }
}
#endif

@main
struct TraktWatchedSnapshotReaderTests {
    static func main() async {
        do {
            try await WatchedReaderCases.run()
#if TRAKT_WATCHED_RAW_TESTS
            try WatchedRawRangeCases.run()
#endif
#if TRAKT_WATCHED_ENGINE_TESTS
            try await WatchedEngineCases.run()
#endif
            print("PASS: Trakt watched complete-pagination, bounds, cursor and cancellation witnesses")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
