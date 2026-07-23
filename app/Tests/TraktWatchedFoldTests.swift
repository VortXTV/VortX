// TraktWatchedFoldTests: a standalone, runnable verification of the Trakt watched-import identity fold
// (SourcesShared/TraktWatchedFold.swift) - the issue #143 contract that a title watched on Trakt must match
// its catalog cover by imdb AND by tmdb identity.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so this
// follows the ExternalSyncToggleSyncTests / HouseholdCryptoTests convention: a self-contained executable run
// with the system toolchain, compiling the REAL source in. TraktWatchedFold.swift is Foundation-only and has
// no app dependencies, so unlike TraktSyncEngine (which pulls in TraktAuth / TraktService / WatchedIndex and
// cannot link standalone) it compiles directly, and it is what gets exercised here:
//
//     swiftc -o /tmp/traktfold \
//       app/SourcesShared/TraktWatchedFold.swift \
//       app/Tests/TraktWatchedFoldTests.swift && /tmp/traktfold
//
// The load-bearing cases are the identity forms: capturing ONLY imdb is exactly what broke the watched
// badges in #143 (every tmdb-keyed hub cover, and every Trakt record with no imdb id, showed as unwatched),
// and the movie-vs-show typed tmdb form is what keeps a movie and a show that share a tmdb number apart.

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

// MARK: - titleIdentities: the #143 imdb-AND-tmdb capture

func testMovieCapturesImdbAndBothTmdbForms() {
    // A watched movie carrying both ids (the common Cinemeta/TMDB case). The set must let a cover keyed by
    // imdb `tt…`, by the canonical `tmdb:<id>`, OR by the typed `tmdb:movie:<id>` all match.
    let ids: [String: Any] = ["imdb": "tt0120616", "tmdb": 564]
    expectEqual(TraktWatchedFold.titleIdentities(ids, isSeries: false),
                ["tt0120616", "tmdb:564", "tmdb:movie:564"],
                "a movie folds imdb + tmdb:<id> + tmdb:movie:<id> (#143)")
}

func testShowCapturesImdbAndTypedTvForm() {
    let ids: [String: Any] = ["imdb": "tt0944947", "tmdb": 1399]
    expectEqual(TraktWatchedFold.titleIdentities(ids, isSeries: true),
                ["tt0944947", "tmdb:1399", "tmdb:tv:1399"],
                "a show folds imdb + tmdb:<id> + tmdb:tv:<id> (#143)")
}

func testTmdbOnlyTitleStillCaptured() {
    // The regression #143 named: a Trakt record with NO imdb id used to be dropped entirely, so a title
    // whose only cover is tmdb-keyed showed as unwatched. It must still yield the tmdb forms.
    let ids: [String: Any] = ["tmdb": 12345]
    expectEqual(TraktWatchedFold.titleIdentities(ids, isSeries: false),
                ["tmdb:12345", "tmdb:movie:12345"],
                "a tmdb-only movie is captured by its tmdb forms, not dropped (#143)")
}

func testImdbOnlyTitle() {
    let ids: [String: Any] = ["imdb": "tt0175142"]   // Scary Movie
    expectEqual(TraktWatchedFold.titleIdentities(ids, isSeries: false),
                ["tt0175142"],
                "an imdb-only title yields just its imdb id")
}

func testNeitherIdYieldsNothing() {
    // A row with neither imdb nor tmdb cannot be matched to any cover, so we never guess an identity.
    let ids: [String: Any] = ["trakt": 99, "slug": "some-movie"]
    expectEqual(TraktWatchedFold.titleIdentities(ids, isSeries: false), [],
                "no imdb and no tmdb yields an empty identity set (never a guess)")
}

func testEmptyImdbStringIsIgnored() {
    let ids: [String: Any] = ["imdb": "", "tmdb": 7]
    expectEqual(TraktWatchedFold.titleIdentities(ids, isSeries: false),
                ["tmdb:7", "tmdb:movie:7"],
                "an empty imdb string contributes no identity")
}

func testMovieAndShowSharingATmdbNumberDoNotCollide() {
    // The typed form is what keeps a movie and a show that happen to share a tmdb number apart in the set.
    let movie = TraktWatchedFold.titleIdentities(["tmdb": 42], isSeries: false)
    let show = TraktWatchedFold.titleIdentities(["tmdb": 42], isSeries: true)
    expect(!Set(movie).contains("tmdb:tv:42"), "a movie never emits the tv-typed form")
    expect(!Set(show).contains("tmdb:movie:42"), "a show never emits the movie-typed form")
    // They still share the canonical form (that ambiguity is intentional; the typed form disambiguates).
    expect(Set(movie).contains("tmdb:42") && Set(show).contains("tmdb:42"), "both carry the canonical tmdb:<id>")
}

// MARK: - intID / nonNegativeInt: JSON number coercion

func testIntIDAcceptsNumberAndNumericStringRejectsNonPositive() {
    expectEqual(TraktWatchedFold.intID(564), 564, "a plain Int id parses")
    expectEqual(TraktWatchedFold.intID("564"), 564, "a numeric String id parses (defensive)")
    expectEqual(TraktWatchedFold.intID(NSNumber(value: 564)), 564, "an NSNumber id (JSONSerialization shape) parses")
    expect(TraktWatchedFold.intID(0) == nil, "0 is not a valid database id")
    expect(TraktWatchedFold.intID(-5) == nil, "a negative value is not a valid id")
    expect(TraktWatchedFold.intID(nil) == nil, "absent is nil")
    expect(TraktWatchedFold.intID("not-a-number") == nil, "a non-numeric string is nil")
}

func testNonNegativeIntAcceptsSeasonZero() {
    // Season 0 is the real, common specials season - it MUST survive, which is why numbers use
    // nonNegativeInt rather than intID (intID would reject 0 and drop every special's tick).
    expectEqual(TraktWatchedFold.nonNegativeInt(0), 0, "season 0 (specials) is accepted")
    expectEqual(TraktWatchedFold.nonNegativeInt(1), 1, "a regular season number is accepted")
    expectEqual(TraktWatchedFold.nonNegativeInt("0"), 0, "a numeric String 0 is accepted")
    expectEqual(TraktWatchedFold.nonNegativeInt(NSNumber(value: 3)), 3, "an NSNumber number is accepted")
    expect(TraktWatchedFold.nonNegativeInt(-1) == nil, "a negative number is rejected")
    expect(TraktWatchedFold.nonNegativeInt(nil) == nil, "absent is nil")
}

// MARK: - episodeKey: the shared per-episode key shape

func testEpisodeKeyShape() {
    expectEqual(TraktWatchedFold.episodeKey("tt0944947", 1, 1), "tt0944947|1|1",
                "episode key is <identity>|<season>|<episode>")
    expectEqual(TraktWatchedFold.episodeKey("tmdb:tv:1399", 0, 5), "tmdb:tv:1399|0|5",
                "specials (season 0) key cleanly under a tmdb identity")
}

// MARK: - The real JSONSerialization path pullWatched takes

func testFoldsARealTraktWatchedMoviesRow() {
    // Prove the exact NSNumber bridging pullWatched relies on: a Trakt /sync/watched/movies body parsed by
    // JSONSerialization (where `tmdb` is a JSON number, i.e. an NSNumber) folds to the full identity set.
    let json = """
    [{"plays":2,"last_watched_at":"2026-07-20T10:00:00.000Z",
      "movie":{"title":"The Mummy","year":1999,
               "ids":{"trakt":1,"slug":"the-mummy-1999","imdb":"tt0120616","tmdb":564}}}]
    """
    let data = Data(json.utf8)
    guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
          let row = rows.first,
          let movie = row["movie"] as? [String: Any],
          let ids = movie["ids"] as? [String: Any] else {
        failures.append("could not parse the sample /sync/watched/movies row")
        return
    }
    expectEqual(TraktWatchedFold.titleIdentities(ids, isSeries: false),
                ["tt0120616", "tmdb:564", "tmdb:movie:564"],
                "a real JSONSerialization-parsed watched-movies row folds to all three forms")
}

// MARK: - Runner
//
// @main (compiled together with the real TraktWatchedFold.swift), matching ExternalSyncToggleSyncTests.

@main
struct TraktWatchedFoldTests {
    static func main() {
        testMovieCapturesImdbAndBothTmdbForms()
        testShowCapturesImdbAndTypedTvForm()
        testTmdbOnlyTitleStillCaptured()
        testImdbOnlyTitle()
        testNeitherIdYieldsNothing()
        testEmptyImdbStringIsIgnored()
        testMovieAndShowSharingATmdbNumberDoNotCollide()
        testIntIDAcceptsNumberAndNumericStringRejectsNonPositive()
        testNonNegativeIntAcceptsSeasonZero()
        testEpisodeKeyShape()
        testFoldsARealTraktWatchedMoviesRow()

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
