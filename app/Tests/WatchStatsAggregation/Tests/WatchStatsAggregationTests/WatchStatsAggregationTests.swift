import Foundation
import Testing
@testable import WatchStatsAggregation

/// Unit tests for the pure Watch Stats aggregation: history records in -> computed stats out, plus the
/// bucket-item normalization that both the owner (engine bucket / live library) and the fixture paths feed.
/// No engine, no file system, no `@Published` state -- exactly the pure core that decides whether the screen
/// shows real numbers or the honest empty state.

// MARK: - compute: honest empty state

@Test("Empty history computes the honest empty state, not a partial/loader state")
func emptyHistoryIsHonestEmpty() {
    let stats = WatchStats.compute(records: [], genresByID: [:], scopeLabel: "All time",
                                   topTitles: WatchStats.topTitlesLimit, topGenres: WatchStats.topGenresLimit)
    #expect(stats.hasData == false)
    #expect(stats.titlesCount == 0)
    #expect(stats.moviesCount == 0)
    #expect(stats.seriesCount == 0)
    #expect(stats.episodesCount == 0)
    #expect(stats.totalWatchSeconds == 0)
    #expect(stats.topTitles.isEmpty)
    #expect(stats.topGenres.isEmpty)
    #expect(stats.longestBinge == nil)
}

// MARK: - compute: real numbers from records (the owner + overlay paths both funnel WatchRecords here)

private func rec(_ id: String, _ type: String, seconds: Double, plays: Int,
                 year: Int? = nil) -> WatchRecord {
    let date = year.map { y -> Date in
        var c = DateComponents(); c.year = y; c.month = 6; c.day = 1
        return WatchStats.calendar.date(from: c)!
    }
    return WatchRecord(id: id, type: type, name: id, poster: nil,
                       watchSeconds: seconds, plays: plays, lastWatched: date)
}

@Test("A user with real history gets real numbers (counts, totals, binge, ranking)")
func realHistoryProducesRealNumbers() {
    let records = [
        rec("movieA", "movie", seconds: 3600, plays: 1),
        rec("movieB", "movie", seconds: 7200, plays: 1),
        rec("seriesS1", "series", seconds: 36000, plays: 10),
        rec("seriesS2", "series", seconds: 18000, plays: 5),
    ]
    let genres = ["movieA": ["Action"], "seriesS1": ["Drama", "Action"]]
    let stats = WatchStats.compute(records: records, genresByID: genres, scopeLabel: "All time",
                                   topTitles: WatchStats.topTitlesLimit, topGenres: WatchStats.topGenresLimit)

    #expect(stats.hasData == true)
    #expect(stats.titlesCount == 4)
    #expect(stats.moviesCount == 2)
    #expect(stats.seriesCount == 2)
    #expect(stats.episodesCount == 15)                       // 10 + 5 watched episodes
    #expect(stats.totalWatchSeconds == 64800)                // 3600 + 7200 + 36000 + 18000

    // Longest binge: the series with the most watched episodes.
    #expect(stats.longestBinge?.name == "seriesS1")
    #expect(stats.longestBinge?.episodes == 10)

    // Most watched, ranked by time spent.
    #expect(stats.topTitles.map(\.id) == ["seriesS1", "seriesS2", "movieB", "movieA"])

    // Top genres, weighted by time and split evenly across a title's genres so it never double-counts.
    // Action = movieA(3600) + seriesS1 half(18000) = 21600; Drama = seriesS1 half(18000).
    #expect(stats.topGenres.first?.name == "Action")
    #expect(stats.topGenres.first?.seconds == 21600)
    #expect(stats.genreCoverage == 2)                        // only movieA + seriesS1 have known genres
}

@Test("With no series, the longest binge falls back to the most-watched movie")
func bingeFallsBackToTopMovie() {
    let stats = WatchStats.compute(records: [
        rec("m1", "movie", seconds: 3600, plays: 1),
        rec("m2", "movie", seconds: 9000, plays: 2),
    ], genresByID: [:], scopeLabel: "All time",
    topTitles: WatchStats.topTitlesLimit, topGenres: WatchStats.topGenresLimit)
    #expect(stats.longestBinge?.name == "m2")
    #expect(stats.longestBinge?.episodes == 0)
}

// MARK: - record(fromBucketItem:) normalization (owner engine-bucket shape)

@Test("A watched movie bucket item normalizes to a record with engine watch time")
func watchedMovieNormalizes() {
    let item: [String: Any] = [
        "type": "movie", "name": "Harry Potter",
        "poster": "https://example/poster.jpg",
        "state": ["overallTimeWatched": 24_351_047, "timesWatched": 1, "flaggedWatched": 1,
                  "lastWatched": "2026-05-13T05:50:02.786798226Z"],
    ]
    let r = WatchStats.record(fromBucketItem: "tmdb:767", item)
    #expect(r != nil)
    #expect(r?.type == "movie")
    #expect(r?.name == "Harry Potter")
    #expect(r?.plays == 1)
    #expect(r?.watchSeconds == 24_351.047)                   // ms -> seconds
    // Nanosecond fractional ISO must parse (the standard fractional formatter rejects it).
    #expect(r?.lastWatched != nil)
    #expect(WatchStats.calendar.component(.year, from: r!.lastWatched!) == 2026)
}

@Test("A watched series bucket item carries its watched-episode count as plays")
func watchedSeriesNormalizes() {
    let item: [String: Any] = [
        "type": "series", "name": "Breaking Bad",
        "state": ["overallTimeWatched": 320_400_000, "timesWatched": 62, "flaggedWatched": 0],
    ]
    let r = WatchStats.record(fromBucketItem: "tt0903747", item)
    #expect(r?.type == "series")
    #expect(r?.plays == 62)
    #expect(r?.isSeries == true)
}

@Test("Bare library adds, internal docs, and non-VOD types contribute nothing")
func nonWatchedAndInternalAreSkipped() {
    // Added to library but never played: all watch counters zero.
    let addOnly: [String: Any] = ["type": "movie", "name": "Unwatched",
                                  "state": ["overallTimeWatched": 0, "timesWatched": 0, "flaggedWatched": 0]]
    #expect(WatchStats.record(fromBucketItem: "tmdb:999", addOnly) == nil)

    // Internal app doc must never count.
    let internalDoc: [String: Any] = ["type": "other", "name": "StremioX Profiles",
                                      "state": ["overallTimeWatched": 0, "timesWatched": 0]]
    #expect(WatchStats.record(fromBucketItem: "stremiox:profiles", internalDoc) == nil)

    // Non-VOD (live TV / channel / other) is not a "title watched".
    let channel: [String: Any] = ["type": "tv", "name": "Some Channel",
                                  "state": ["overallTimeWatched": 5000, "timesWatched": 3]]
    #expect(WatchStats.record(fromBucketItem: "tv:1", channel) == nil)

    // A flaggedWatched-only movie (marked watched, no accrued time) still counts.
    let flaggedOnly: [String: Any] = ["type": "movie", "name": "Marked",
                                      "state": ["overallTimeWatched": 0, "timesWatched": 0, "flaggedWatched": 1]]
    #expect(WatchStats.record(fromBucketItem: "tmdb:42", flaggedOnly) != nil)
}

// MARK: - end-to-end: two-bucket fixture -> non-empty stats

@Test("Two engine buckets (whole + recent) aggregate to non-empty stats, recent overwrites")
func twoBucketFixtureAggregates() throws {
    // library.json = the whole library (read first), library_recent.json = the fresher subset (overwrites
    // shared ids), exactly the bucketRecords read order.
    let libraryJSON = """
    { "uid": "acct1", "items": {
        "tmdb:1": { "type": "series", "name": "Show One",
                    "state": { "overallTimeWatched": 72000000, "timesWatched": 20, "flaggedWatched": 0,
                               "lastWatched": "2025-11-01T10:00:00Z" } },
        "tmdb:2": { "type": "movie", "name": "Film Two",
                    "state": { "overallTimeWatched": 3600000, "timesWatched": 1, "flaggedWatched": 1,
                               "lastWatched": "2025-01-05T10:00:00Z" } },
        "stremiox:profiles": { "type": "other", "name": "Profiles",
                    "state": { "overallTimeWatched": 0, "timesWatched": 0 } }
    } }
    """
    let recentJSON = """
    { "uid": "acct1", "items": {
        "tmdb:2": { "type": "movie", "name": "Film Two",
                    "state": { "overallTimeWatched": 9000000, "timesWatched": 2, "flaggedWatched": 1,
                               "lastWatched": "2026-02-02T10:00:00Z" } },
        "tmdb:3": { "type": "movie", "name": "Film Three",
                    "state": { "overallTimeWatched": 5400000, "timesWatched": 1, "flaggedWatched": 1,
                               "lastWatched": "2026-03-03T10:00:00Z" } }
    } }
    """
    var records: [String: WatchRecord] = [:]
    for json in [libraryJSON, recentJSON] {   // library first, recent overwrites -- the real read order
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let items = try #require(root["items"] as? [String: Any])
        for (id, value) in items {
            guard let item = value as? [String: Any],
                  let record = WatchStats.record(fromBucketItem: id, item) else { continue }
            records[id] = record
        }
    }

    let stats = WatchStats.compute(records: Array(records.values), genresByID: [:], scopeLabel: "All time",
                                   topTitles: WatchStats.topTitlesLimit, topGenres: WatchStats.topGenresLimit)
    #expect(stats.hasData == true)
    #expect(stats.titlesCount == 3)                          // tmdb:1, tmdb:2, tmdb:3 (profiles dropped)
    #expect(stats.moviesCount == 2)
    #expect(stats.seriesCount == 1)
    #expect(stats.episodesCount == 20)                       // Show One's 20 watched episodes
    // tmdb:2 took the RECENT bucket's 9000s (not the whole-library 3600s).
    let filmTwo = try #require(stats.topTitles.first { $0.id == "tmdb:2" })
    #expect(filmTwo.seconds == 9000)
    #expect(stats.totalWatchSeconds == 72000 + 9000 + 5400)
}

// MARK: - year-in-review scoping derives from the tolerant date parser

@Test("Year scoping reads the calendar year from tolerant ISO timestamps")
func yearScopingParsesTimestamps() {
    #expect(WatchStats.parseISODate(nil) == nil)
    #expect(WatchStats.parseISODate("") == nil)
    let nanos = try! #require(WatchStats.parseISODate("2026-05-13T05:50:02.786798226Z"))
    #expect(WatchStats.calendar.component(.year, from: nanos) == 2026)
    let plain = try! #require(WatchStats.parseISODate("2025-01-05T10:00:00Z"))
    #expect(WatchStats.calendar.component(.year, from: plain) == 2025)
    // Over-precise / truncatable: still yields the leading calendar day's year.
    let dayOnly = try! #require(WatchStats.parseISODate("2024-12-31"))
    #expect(WatchStats.calendar.component(.year, from: dayOnly) == 2024)
}
