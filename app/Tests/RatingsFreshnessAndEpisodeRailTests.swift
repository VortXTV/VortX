import Foundation

// Compiles actual production policies/store; the only fake is the explicitly injected request loader.
enum VortXEdgeAuth { static func sign(_ request: inout URLRequest) {} }

@MainActor protocol DetailRatingsHarness: AnyObject {
    var mdbRatings: MDBListRatings? { get }
    var ratingsTask: Task<Void, Never>? { get }
    func begin(_ key: RatingRequestKey?)
}
@MainActor enum FixtureVortXRatings {
    static let held = HeldRatings()
    static func ratings(imdbID: String, type: String) async -> MDBListRatings? {
        await held.load(id: imdbID, type: type)
    }
}
@MainActor enum FixtureMDBListRatings {
    static func ratings(imdbID: String, type: String) async -> MDBListRatings? { nil }
}

@MainActor final class HeldRatings {
    var starts: [String: Int] = [:]
    var pending: [String: [CheckedContinuation<MDBListRatings?, Never>]] = [:]
    func load(id: String, type: String) async -> MDBListRatings? {
        let key = type + ":" + id
        starts[key, default: 0] += 1
        return await withCheckedContinuation { pending[key, default: []].append($0) }
    }
    func release(id: String, type: String, value: MDBListRatings?) {
        let key = type + ":" + id
        guard var held = pending[key], !held.isEmpty else { preconditionFailure("missing held load") }
        let continuation = held.removeFirst()
        pending[key] = held
        continuation.resume(returning: value)
    }
}

@main @MainActor enum RatingsFreshnessAndEpisodeRailTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label); checks += 1
    }
    static func wait(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("held production store did not start")
    }
    static func main() async {
        let rt = MDBListRatings(imdb: nil, rottenTomatoes: 91, metacritic: nil, tmdb: nil)
        let merged = RatingPresentationPolicy.merged(rt, fallbackIMDb: " 8.4 ")
        expect(merged?.imdb == 8.4 && merged?.rottenTomatoes == 91, "RT-only enrichment keeps metadata IMDb")
        expect(RatingPresentationPolicy.merged(nil, fallbackIMDb: nil) == nil, "genuine absence remains absent")
        for invalid in ["", "N/A", "NaN", "inf", "-1", "10.1"] {
            expect(RatingPresentationPolicy.merged(nil, fallbackIMDb: invalid) == nil, "invalid score is absent")
        }
        let supplied = MDBListRatings(imdb: 8.8, rottenTomatoes: nil, metacritic: nil, tmdb: nil)
        expect(RatingPresentationPolicy.merged(supplied, secondary: rt, fallbackIMDb: "7.0")?.imdb == 8.8,
               "service field precedence remains unchanged")
        expect(RatingPresentationPolicy.mergingIMDbLine("2026  ·  Movie", freshLine: "★ 8.4  ·  Movie")
            == "2026  ·  ★ 8.4  ·  Movie", "fresh TV star enters sparse cached line")
        expect(RatingPresentationPolicy.mergingIMDbLine("2026  ·  ★ 8.1  ·  Movie", freshLine: "Movie")
            == "2026  ·  ★ 8.1  ·  Movie", "sparse TV emit retains known score")
        expect(RatingPresentationPolicy.mergingIMDbLine("2026  ·  ★ 8.1  ·  Movie", freshLine: "★ 8.8  ·  Movie")
            == "2026  ·  ★ 8.8  ·  Movie", "fresh TV score replaces, not duplicates, cached star")

        let ids = (1...100).map { "ep\($0)" }
        let watched = Set(ids.prefix(43))
        expect(EpisodeRailInitialPositionPolicy.firstUnwatchedIndex(ids: ids, watched: watched) == 43,
               "43 watched episodes positions episode 44 first")
        expect(EpisodeRailInitialPositionPolicy.firstUnwatchedIndex(ids: ids, watched: Set(ids)) == 0,
               "all watched positions episode 1")
        var rail = EpisodeRailInitialPositionPolicy()
        expect(rail.claim(scope: "A:title", season: 1, ids: ids, watched: [], ready: false) == nil,
               "missing native restore projection never means unwatched")
        expect(rail.claim(scope: "A:title", season: 1, ids: ids, watched: watched, ready: true) == 43,
               "accepted ready history claims initial focus")
        expect(rail.claim(scope: "A:title", season: 1, ids: ids, watched: [], ready: true) == nil,
               "late metadata/history never steals an already claimed position")
        expect(rail.claim(scope: "A:title", season: 2, ids: ["s2e1", "s2e2"], watched: ["s2e1"], ready: true) == 1,
               "each selected season has one independent initial focus")
        rail.userInteracted(scope: "A:title", season: 3)
        expect(rail.claim(scope: "A:title", season: 3, ids: ids, watched: watched, ready: true) == nil,
               "scrolling before restore suppresses a late automatic jump")
        expect(rail.claim(scope: "B:title", season: 1, ids: ids, watched: [], ready: true) == 0,
               "new profile gets its own initial position")

        let held = HeldRatings()
        let store = CardRatingStore(load: { await held.load(id: $0, type: $1) })
        let first = Task { await store.ratings(id: "tt123", type: "movie") }
        await wait { held.starts["movie:tt123"] == 1 }
        let second = Task { await store.ratings(id: "tt123", type: "movie") }
        await Task.yield()
        expect(held.starts["movie:tt123"] == 1, "concurrent cards coalesce one request")
        first.cancel() // A recycled cell does not cancel a shared request needed by the second cell.
        held.release(id: "tt123", type: "movie", value: supplied)
        _ = await first.value
        expect(await second.value == supplied, "remaining cell receives coalesced successful score")
        expect(await store.ratings(id: "tt123", type: "movie") == supplied, "successful typed result is cached")
        expect(held.starts["movie:tt123"] == 1, "warm card uses no second fetch")
        let corrected = Task { await store.ratings(id: "tt123", type: "series") }
        await wait { held.starts["series:tt123"] == 1 }
        held.release(id: "tt123", type: "series", value: rt)
        expect(await corrected.value == rt, "same ID different media type owns a separate request")
        let miss = Task { await store.ratings(id: "tt456", type: "series") }
        await wait { held.starts["series:tt456"] == 1 }
        held.release(id: "tt456", type: "series", value: nil)
        expect(await miss.value == nil, "transient miss stays absent")
        let retry = Task { await store.ratings(id: "tt456", type: "series") }
        await wait { held.starts["series:tt456"] == 2 }
        held.release(id: "tt456", type: "series", value: supplied)
        expect(await retry.value == supplied, "transient miss is not cached forever")

        let details: [any DetailRatingsHarness] = [ProductionIOSDetailRatings(), ProductionTVDetailRatings()]
        for (index, detail) in details.enumerated() {
            let id = "tt90\(index)"
            detail.begin(.init(id: id, type: "movie"))
            await wait { FixtureVortXRatings.held.starts["movie:" + id] == 1 }
            let retired = detail.ratingsTask
            detail.begin(.init(id: id, type: "series"))
            await wait { FixtureVortXRatings.held.starts["series:" + id] == 1 }
            let current = detail.ratingsTask
            FixtureVortXRatings.held.release(id: id, type: "movie", value: supplied)
            await retired?.value
            expect(detail.mdbRatings == nil, "retired movie completion cannot publish into corrected series detail")
            FixtureVortXRatings.held.release(id: id, type: "series", value: rt)
            await current?.value
            expect(detail.mdbRatings == rt, "current typed detail completion publishes")
            detail.begin(.init(id: id, type: "series"))
            expect(detail.ratingsTask == nil, "same successful detail request does not restart")
            detail.begin(.init(id: id + "1", type: "series"))
            await wait { FixtureVortXRatings.held.starts["series:" + id + "1"] == 1 }
            expect(detail.mdbRatings == nil, "new detail request clears previous success and starts replacement")
            let dismissed = detail.ratingsTask
            detail.begin(nil)
            FixtureVortXRatings.held.release(id: id + "1", type: "series", value: supplied)
            await dismissed?.value
            expect(detail.mdbRatings == nil, "missing/retired identity cancels and rejects late completion")
        }
        print("RatingsFreshnessAndEpisodeRailTests: \(checks) actual production checks passed; no live service/device claim")
    }
}
