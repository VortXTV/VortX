// SIMKLRatingsCoreTests: a standalone, runnable verification of the SIMKL title-ratings feature's PURE parts -
// the merge state core (SourcesShared/SIMKLRatingsCore.swift: the four fold rules ported from TraktRatingsStore)
// and the REAL SIMKL ratings wire types (SourcesShared/SIMKLModels.swift): the submit encode shape, the remove
// shape (ids only, no rating), and the `/sync/ratings/{type}` read-back decode INCLUDING SIMKL's string-vs-int
// tmdb asymmetry and its anime-split-from-shows envelope.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so this
// follows the SIMKLWatchedShadowTests / TraktWatchedFoldTests convention: a self-contained executable run with
// the system toolchain, compiling the REAL sources in. SIMKLRatingsStore itself pulls in SIMKLService /
// SIMKLAuth and cannot link standalone (exactly why its rules were extracted into the pure SIMKLRatingsCore),
// so it is the CORE + the wire MODELS that are exercised here:
//
//     swiftc -o /tmp/simklratings \
//       app/SourcesShared/SIMKLModels.swift \
//       app/SourcesShared/SIMKLRatingsCore.swift \
//       app/Tests/SIMKLRatingsCoreTests.swift && /tmp/simklratings
//
// The load-bearing cases are the four merge rules (a two-authority sync corrupts a user's data in exactly the
// ways these close) and the read-back decode (SIMKL hands tmdb back as a STRING and splits anime out of shows,
// so a naive decode would drop a SIMKL user's anime ratings and typeMismatch on the string id).

import Foundation

var failures: [String] = []
var checks = 0

func expect(_ cond: Bool, _ what: String) {
    checks += 1
    if !cond { failures.append(what) }
}

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    checks += 1
    if got != want { failures.append("\(what): got \(got), want \(want)") }
}

// MARK: - 1. Submit / remove wire shape (`POST /sync/ratings`, `/sync/ratings/remove`)

func jsonString(_ value: some Encodable) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    return (try? String(data: enc.encode(value), encoding: .utf8)) ?? ""
}

func testMovieRatingSubmitShape() {
    let items = SIMKLRatingItems(movies: [SIMKLRatedMovie(ids: SIMKLIDs(imdb: "tt0181852", tmdb: 296),
                                                          rating: 8, ratedAt: "2014-09-01T09:10:11Z")])
    let json = jsonString(items)
    expect(json.contains("\"movies\""), "submit carries a movies array")
    expect(!json.contains("\"shows\""), "a movie-only submit omits the shows array (encodeIfPresent)")
    expect(json.contains("\"rating\":8"), "the rating value rides the item")
    expect(json.contains("\"rated_at\":\"2014-09-01T09:10:11Z\""), "rated_at is the snake_case wire key")
    expect(json.contains("\"imdb\":\"tt0181852\""), "the imdb id rides the ids bag")
    expect(json.contains("\"tmdb\":296"), "the tmdb id encodes as a JSON number on the write path")
}

func testShowRatingSubmitShape() {
    let items = SIMKLRatingItems(shows: [SIMKLRatedShow(ids: SIMKLIDs(imdb: "tt2560140"), rating: 10)])
    let json = jsonString(items)
    expect(json.contains("\"shows\""), "a show rating rides the shows array (anime too)")
    expect(!json.contains("\"movies\""), "a show-only submit omits the movies array")
    expect(json.contains("\"rating\":10"), "the show rating value rides the item")
    expect(!json.contains("rated_at"), "an omitted rated_at is not encoded")
}

func testRemoveShapeHasNoRating() {
    // `/sync/ratings/remove` identifies by ids alone; a `rating` here would be meaningless.
    let items = SIMKLRatingItems(movies: [SIMKLRatedMovie(ids: SIMKLIDs(imdb: "tt0181852"))])
    let json = jsonString(items)
    expect(json.contains("\"imdb\":\"tt0181852\""), "remove carries the ids")
    expect(!json.contains("rating"), "remove omits the rating field entirely")
    expect(!json.contains("rated_at"), "remove omits rated_at entirely")
}

// MARK: - 2. Read-back decode (`POST /sync/ratings/{type}`) + flatten to neutral rows

/// A real-shaped ratings read-back: a movie (tmdb as a STRING, SIMKL's read form), a show (imdb), and an anime
/// row nested under `show` in its OWN array (SIMKL splits anime out of shows).
let readBackJSON = """
{
  "movies": [
    { "user_rating": 6, "user_rated_at": "2021-06-23T13:19:05Z",
      "movie": { "title": "Maleficent", "year": 2014, "ids": { "simkl": 195258, "imdb": "tt1587310", "tmdb": "102651" } } }
  ],
  "shows": [
    { "user_rating": 5, "user_rated_at": "2021-06-23T13:19:05Z",
      "show": { "title": "The Last Ship", "year": 2014, "ids": { "simkl": 42040, "imdb": "tt2402207" } } }
  ],
  "anime": [
    { "user_rating": 10, "user_rated_at": "2021-06-23T13:19:05Z",
      "show": { "title": "Hunter x Hunter", "year": 2011, "ids": { "simkl": 40398, "imdb": "tt2098220" } } }
  ]
}
"""

func decodedReadBack() -> SIMKLRatingsResponse {
    (try? JSONDecoder().decode(SIMKLRatingsResponse.self, from: Data(readBackJSON.utf8)))
        ?? SIMKLRatingsResponse(movies: nil, shows: nil, anime: nil)
}

func testReadBackDecodesAllThreeArrays() {
    let r = decodedReadBack()
    expectEqual(r.movies?.count ?? -1, 1, "movies array decodes")
    expectEqual(r.shows?.count ?? -1, 1, "shows array decodes")
    expectEqual(r.anime?.count ?? -1, 1, "anime array decodes (SIMKL splits it out of shows)")
    expectEqual(r.movies?.first?.userRating ?? -1, 6, "user_rating maps off the row")
    expectEqual(r.movies?.first?.movie?.ids.tmdb ?? -1, 102651, "a STRING tmdb (\"102651\") decodes via flexibleInt")
}

func testRemoteRatingsFlattenFoldsAnimeAsSeries() {
    let rows = SIMKLRatingsCore.remoteRatings(from: decodedReadBack())
    expectEqual(rows.count, 3, "all three rows flatten")
    let movie = rows.first { $0.imdb == "tt1587310" }
    let show = rows.first { $0.imdb == "tt2402207" }
    let anime = rows.first { $0.imdb == "tt2098220" }
    expectEqual(movie?.isSeries, false, "the movie row folds as a movie")
    expectEqual(show?.isSeries, true, "the show row folds as a series")
    expectEqual(anime?.isSeries, true, "the anime row folds as a series (anime is series to the detail page)")
    expectEqual(anime?.rating, 10, "the anime rating carries through")
    expect(movie?.ratedAt != nil, "a whole-second user_rated_at parses (not distantPast)")
}

// MARK: - 3. Merge rules (SIMKLRatingsCore)

func testFillInsertsAnUnseenTitle() {
    var core = SIMKLRatingsCore()
    let row = SIMKLRatingsCore.RemoteRating(imdb: "tt100", tmdb: nil, isSeries: false, rating: 7, ratedAt: Date())
    let result = core.merge([row])
    expect(result.valueChanged, "a fill is a visible change")
    expectEqual(core.rating(imdb: "tt100", tmdb: nil), 7, "the filled rating reads back")
}

func testUnpushedLocalEditIsImmune() {
    var core = SIMKLRatingsCore()
    _ = core.write(rating: 9, imdb: "tt200", tmdb: nil, isSeries: false)   // unpushed
    // A read-back claiming a DIFFERENT rating must not touch the still-unpushed local value (rule 3).
    let row = SIMKLRatingsCore.RemoteRating(imdb: "tt200", tmdb: nil, isSeries: false, rating: 3,
                                            ratedAt: Date().addingTimeInterval(9_999))
    let result = core.merge([row])
    expect(!result.valueChanged, "an unpushed edit is immune to a read-back")
    expectEqual(core.rating(imdb: "tt200", tmdb: nil), 9, "the local (unpushed) rating stands")
}

func testStrictlyNewerWinsAfterPush() {
    var core = SIMKLRatingsCore()
    guard let entry = core.write(rating: 4, imdb: "tt300", tmdb: nil, isSeries: false) else {
        failures.append("write returned no entry"); return
    }
    expect(core.markPushed(entry), "the entry flips to pushed")
    // Strictly newer -> adopted.
    let newer = SIMKLRatingsCore.RemoteRating(imdb: "tt300", tmdb: nil, isSeries: false, rating: 8,
                                              ratedAt: entry.ratedAt.addingTimeInterval(60))
    expect(core.merge([newer]).valueChanged, "a strictly-newer pushed row is adopted")
    expectEqual(core.rating(imdb: "tt300", tmdb: nil), 8, "the newer rating wins")
    // Equal / older -> idempotent, no flap.
    let older = SIMKLRatingsCore.RemoteRating(imdb: "tt300", tmdb: nil, isSeries: false, rating: 2,
                                              ratedAt: entry.ratedAt)
    expect(!core.merge([older]).valueChanged, "an older/equal row never flaps the value")
    expectEqual(core.rating(imdb: "tt300", tmdb: nil), 8, "the value is unchanged by an older row")
}

func testAbsenceNeverDeletes() {
    var core = SIMKLRatingsCore()
    guard let entry = core.write(rating: 5, imdb: "tt400", tmdb: nil, isSeries: true) else {
        failures.append("write returned no entry"); return
    }
    _ = core.markPushed(entry)
    // A read-back about a DIFFERENT title must not touch tt400 (rule 1).
    let other = SIMKLRatingsCore.RemoteRating(imdb: "tt401", tmdb: nil, isSeries: true, rating: 6, ratedAt: Date())
    _ = core.merge([other])
    expectEqual(core.rating(imdb: "tt400", tmdb: nil), 5, "a title absent from the response is untouched")
}

func testClearIsATombstoneNotADelete() {
    var core = SIMKLRatingsCore()
    guard let set = core.write(rating: 7, imdb: "tt500", tmdb: nil, isSeries: false) else { return }
    _ = core.markPushed(set)
    guard let cleared = core.write(rating: nil, imdb: "tt500", tmdb: nil, isSeries: false) else {
        failures.append("clear returned no entry"); return
    }
    expectEqual(core.rating(imdb: "tt500", tmdb: nil), nil, "a cleared rating reads as nil")
    _ = core.markPushed(cleared)
    // A stale read-back at the OLD (older) time must not resurrect the rating over the tombstone.
    let stale = SIMKLRatingsCore.RemoteRating(imdb: "tt500", tmdb: nil, isSeries: false, rating: 7,
                                              ratedAt: cleared.ratedAt.addingTimeInterval(-100))
    _ = core.merge([stale])
    expectEqual(core.rating(imdb: "tt500", tmdb: nil), nil, "an older read-back never resurrects a tombstone")
}

func testTmdbKeyedEntryLearnsImdbFromReadBack() {
    var core = SIMKLRatingsCore()
    // Rate a title known only by tmdb (a tmdb-only catalog page, common on SIMKL's anime-first lists).
    guard let entry = core.write(rating: 6, imdb: nil, tmdb: 550, isSeries: false) else {
        failures.append("tmdb write returned no entry"); return
    }
    _ = core.markPushed(entry)
    expectEqual(core.rating(imdb: nil, tmdb: 550), 6, "the tmdb-keyed rating reads by tmdb")
    // A read-back enriches it with the tt id (same value, newer-or-equal time): id learned, findable by imdb.
    let enrich = SIMKLRatingsCore.RemoteRating(imdb: "tt0137523", tmdb: 550, isSeries: false, rating: 6,
                                               ratedAt: entry.ratedAt)
    let result = core.merge([enrich])
    expect(result.dirty, "an id enrichment is dirty (must reach the alias index + disk)")
    expect(!result.valueChanged, "an id enrichment alone is not a repaint")
    expectEqual(core.rating(imdb: "tt0137523", tmdb: nil), 6, "the entry now resolves from its learned tt id")
}

func testMarkPushedRequiresExactValueAndTime() {
    var core = SIMKLRatingsCore()
    guard let entry = core.write(rating: 4, imdb: "tt600", tmdb: nil, isSeries: false) else { return }
    // A push bookkeeping for a DIFFERENT value must not flip the current (still-unpushed) entry.
    var wrong = entry; wrong.rating = 9
    expect(!core.markPushed(wrong), "markPushed refuses a value that no longer matches")
    // The exact entry flips it.
    expect(core.markPushed(entry), "markPushed accepts the exact value+time that was pushed")
    expect(!core.markPushed(entry), "a second markPushed is a no-op (already pushed)")
}

func testRatedAtParsesBothForms() {
    expect(SIMKLRatedAt.date(from: "2021-06-23T13:19:05Z") != nil, "whole-second Z parses")
    expect(SIMKLRatedAt.date(from: "2014-09-01T09:10:11.000Z") != nil, "fractional .000Z parses")
    expect(SIMKLRatedAt.date(from: "not-a-date") == nil, "garbage yields nil, not distantPast")
}

func testOutOfRangeAndIdlessAreRefused() {
    var core = SIMKLRatingsCore()
    // No usable id -> no entry to key on.
    expect(core.write(rating: 5, imdb: nil, tmdb: nil, isSeries: false) == nil, "an id-less write is refused")
    // An out-of-range remote rating is dropped by the flatten (validRange guard).
    let badEntry = try! JSONDecoder().decode(SIMKLRatingEntry.self, from: Data("""
        {"user_rating": 0, "user_rated_at": "2021-06-23T13:19:05Z", "movie": {"ids": {"imdb": "tt700"}}}
        """.utf8))
    let rows = SIMKLRatingsCore.remoteRatings(from: SIMKLRatingsResponse(movies: [badEntry], shows: nil, anime: nil))
    expect(rows.isEmpty, "a rating outside 1...10 is dropped by the flatten")
}

// MARK: - Runner

@main
struct SIMKLRatingsCoreTests {
    static func main() {
        testMovieRatingSubmitShape()
        testShowRatingSubmitShape()
        testRemoveShapeHasNoRating()
        testReadBackDecodesAllThreeArrays()
        testRemoteRatingsFlattenFoldsAnimeAsSeries()
        testFillInsertsAnUnseenTitle()
        testUnpushedLocalEditIsImmune()
        testStrictlyNewerWinsAfterPush()
        testAbsenceNeverDeletes()
        testClearIsATombstoneNotADelete()
        testTmdbKeyedEntryLearnsImdbFromReadBack()
        testMarkPushedRequiresExactValueAndTime()
        testRatedAtParsesBothForms()
        testOutOfRangeAndIdlessAreRefused()

        if failures.isEmpty {
            print("PASS: \(checks) checks")
            exit(0)
        } else {
            print("FAIL: \(failures.count) of \(checks) checks")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
    }
}
