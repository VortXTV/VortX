// SIMKLWatchedShadowTests: a standalone, runnable verification of the SIMKL watched-history import, mirroring
// TraktWatchedFoldTests. It exercises the two Foundation-only seams the import is built on - the shared
// identity fold (SourcesShared/WatchedFold.swift) applied to SIMKL rows, and the pure state core
// (SourcesShared/SIMKLWatchedCore.swift: fold a completed list, REPLACE, disconnect WIPE, opt-in GATE) - plus
// the REAL SIMKL wire decode (SourcesShared/SIMKLModels.swift), so the string-vs-int tmdb asymmetry the read
// path hits is covered end to end.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so this
// follows the ExternalSyncToggleSyncTests / TraktWatchedFoldTests convention: a self-contained executable run
// with the system toolchain, compiling the REAL sources in. SIMKLWatchedShadow itself pulls in SIMKLService /
// SIMKLAuth / WatchedIndex and cannot link standalone (exactly why its rules were extracted into the pure
// SIMKLWatchedCore), so it is the CORE that is exercised here, the same split TraktSyncEngine/WatchedFold uses:
//
//     swiftc -o /tmp/simklfold \
//       app/SourcesShared/SIMKLModels.swift \
//       app/SourcesShared/WatchedFold.swift \
//       app/SourcesShared/SIMKLWatchedCore.swift \
//       app/Tests/SIMKLWatchedShadowTests.swift && /tmp/simklfold
//
// The load-bearing cases mirror #143: capturing imdb AND tmdb (a SIMKL user's anime-first list carries plenty
// of tmdb-only rows, so dropping them would hide a large slice of their watched history), the movie-vs-show
// typed tmdb form, and the string tmdb ("550") SIMKL's read endpoints send.

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

/// One SIMKL list entry, the flattened shape SIMKLService.list hands the shadow.
func entry(imdb: String? = nil, tmdb: Int? = nil, title: String = "x", series: Bool) -> SIMKLListEntry {
    SIMKLListEntry(imdb: imdb, tmdb: tmdb, title: title, type: series ? "series" : "movie", addedAt: nil)
}

// MARK: - 1. The shared fold on SIMKL-shaped inputs (#143 imdb-AND-tmdb capture)

func testMovieFoldsImdbAndBothTmdbForms() {
    expectEqual(WatchedFold.identities(imdb: "tt0137523", tmdb: 550, isSeries: false),
                ["tt0137523", "tmdb:550", "tmdb:movie:550"],
                "a completed movie folds imdb + tmdb:<id> + tmdb:movie:<id> (#143)")
}

func testShowFoldsImdbAndTypedTvForm() {
    expectEqual(WatchedFold.identities(imdb: "tt0944947", tmdb: 1399, isSeries: true),
                ["tt0944947", "tmdb:1399", "tmdb:tv:1399"],
                "a completed show folds imdb + tmdb:<id> + tmdb:tv:<id> (#143)")
}

func testTmdbOnlyRowStillCaptured() {
    // SIMKL is anime-first and returns many rows with a tmdb id and no imdb id. Dropping them would hide a
    // large slice of a typical SIMKL user's completed history - the exact write-only "I connected it and see
    // nothing" failure this import ends.
    expectEqual(WatchedFold.identities(imdb: nil, tmdb: 12345, isSeries: true),
                ["tmdb:12345", "tmdb:tv:12345"],
                "a tmdb-only show is captured by its tmdb forms, not dropped")
}

func testImdbOnlyRow() {
    expectEqual(WatchedFold.identities(imdb: "tt0175142", tmdb: nil, isSeries: false),
                ["tt0175142"], "an imdb-only title yields just its imdb id")
}

func testNeitherIdYieldsNothing() {
    expectEqual(WatchedFold.identities(imdb: nil, tmdb: nil, isSeries: false), [],
                "no imdb and no tmdb yields an empty identity set (never a guess)")
    expectEqual(WatchedFold.identities(imdb: "", tmdb: nil, isSeries: false), [],
                "an empty imdb string with no tmdb yields nothing")
}

func testNonPositiveTmdbIgnored() {
    expectEqual(WatchedFold.identities(imdb: "tt1", tmdb: 0, isSeries: false), ["tt1"],
                "a 0 tmdb is not a real id and contributes no form")
    expectEqual(WatchedFold.identities(imdb: nil, tmdb: -5, isSeries: false), [],
                "a negative tmdb is not a real id")
}

func testMovieAndShowSharingATmdbDoNotCollide() {
    let movie = Set(WatchedFold.identities(imdb: nil, tmdb: 42, isSeries: false))
    let show = Set(WatchedFold.identities(imdb: nil, tmdb: 42, isSeries: true))
    expect(!movie.contains("tmdb:tv:42"), "a movie never emits the tv-typed form")
    expect(!show.contains("tmdb:movie:42"), "a show never emits the movie-typed form")
    expect(movie.contains("tmdb:42") && show.contains("tmdb:42"), "both carry the canonical tmdb:<id>")
}

// MARK: - 2. SIMKLWatchedCore.identities: folding a whole completed list (union across the three legs)

func testCoreUnionsMoviesShowsAndAnime() {
    // The three legs SIMKLService reads (movies / shows / anime completed), each already flattened. Anime
    // rows are "series" to the detail page, so they fold as shows.
    let entries = [
        entry(imdb: "tt0137523", tmdb: 550, series: false),   // movie
        entry(imdb: "tt0944947", tmdb: 1399, series: true),   // show
        entry(imdb: nil, tmdb: 30991, series: true),          // anime (tmdb-only, series)
    ]
    let ids = SIMKLWatchedCore.identities(from: entries)
    expect(ids.contains("tt0137523") && ids.contains("tmdb:movie:550"), "movie leg folded")
    expect(ids.contains("tt0944947") && ids.contains("tmdb:tv:1399"), "show leg folded")
    expect(ids.contains("tmdb:30991") && ids.contains("tmdb:tv:30991"), "anime leg folded as a series")
    expect(!ids.contains("tmdb:movie:30991"), "an anime (series) row never emits the movie-typed form")
    expectEqual(ids.count, 8, "the three legs union to the expected identity count")
}

func testCoreDropsRowsWithNoUsableID() {
    // A row that reached the core with neither id (defensive: SIMKLService already drops these) contributes
    // nothing rather than a guessed identity.
    let ids = SIMKLWatchedCore.identities(from: [entry(imdb: "", tmdb: nil, series: false),
                                                 entry(imdb: "tt5", tmdb: nil, series: false)])
    expectEqual(ids, ["tt5"], "an id-less row contributes nothing to the folded set")
}

// MARK: - 3. The REAL SIMKL wire decode (the string-vs-int tmdb asymmetry the read path hits)

func testDecodesARealCompletedMoviesResponseWithStringTmdb() {
    // SIMKL's READ responses hand numeric ids back as JSON STRINGS ("550"). SIMKLIDs must decode that to an
    // Int so the fold produces the tmdb forms; a naive Int-only decode would throw typeMismatch and take the
    // whole list down (see the SIMKLIDs comment). Prove the whole chain: decode -> flatten -> fold.
    let json = """
    {"movies":[{"status":"completed","added_to_watchlist_at":"2026-07-20T10:00:00Z",
      "movie":{"title":"Fight Club","year":1999,
               "ids":{"simkl":1,"imdb":"tt0137523","tmdb":"550"}}}]}
    """
    let data = Data(json.utf8)
    guard let response = try? JSONDecoder().decode(SIMKLAllItemsResponse.self, from: data),
          let row = response.movies?.first, let movie = row.movie else {
        failures.append("could not decode the sample /sync/all-items/movies/completed response")
        return
    }
    expectEqual(movie.ids.imdb, "tt0137523", "the imdb id decodes")
    expectEqual(movie.ids.tmdb, 550, "a STRING tmdb (\"550\") decodes to an Int (the read-side asymmetry)")
    let folded = SIMKLWatchedCore.identities(from: [entry(imdb: movie.ids.imdb, tmdb: movie.ids.tmdb, series: false)])
    expectEqual(folded, ["tt0137523", "tmdb:550", "tmdb:movie:550"],
                "a real string-tmdb movie row folds to all three forms")
}

func testDecodesARealCompletedShowsResponse() {
    // The shows/anime legs nest under `show`. A numeric (Int) tmdb, the OTHER form SIMKLIDs must tolerate,
    // decodes just as well.
    let json = """
    {"shows":[{"status":"completed","show":{"title":"Game of Thrones","ids":{"imdb":"tt0944947","tmdb":1399}}}]}
    """
    let data = Data(json.utf8)
    guard let response = try? JSONDecoder().decode(SIMKLAllItemsResponse.self, from: data),
          let show = response.shows?.first?.show else {
        failures.append("could not decode the sample /sync/all-items/shows/completed response")
        return
    }
    expectEqual(show.ids.tmdb, 1399, "an Int tmdb decodes on the read path too")
    let folded = SIMKLWatchedCore.identities(from: [entry(imdb: show.ids.imdb, tmdb: show.ids.tmdb, series: true)])
    expect(folded.contains("tmdb:tv:1399"), "a real show row folds to the tv-typed form")
}

func testEmptyCompletedListDecodesToNoRows() {
    // SIMKL omits the key entirely (rather than sending []) for an empty list. The envelope's optionals make
    // that a zero-row success, not a decode error, so the fold is simply empty.
    guard let response = try? JSONDecoder().decode(SIMKLAllItemsResponse.self, from: Data("{}".utf8)) else {
        failures.append("an empty completed response should decode, not throw")
        return
    }
    expect(response.movies == nil && response.shows == nil && response.anime == nil, "an empty list has no rows")
}

// MARK: - 4. The core's state rules: REPLACE (a pull is a replace, not a merge)

func testReplaceReportsChangeAndUpdatesSet() {
    var core = SIMKLWatchedCore()
    expect(core.replace(with: ["tt1", "tmdb:5"]), "replacing an empty set with content is a change")
    expectEqual(core.watchedIDs, ["tt1", "tmdb:5"], "the set holds exactly the replaced ids")
    expect(!core.replace(with: ["tt1", "tmdb:5"]), "replacing with the identical set is NOT a change")
    expect(core.replace(with: ["tt1"]), "replacing with a different set is a change (a pull is a replace, not a merge)")
    expectEqual(core.watchedIDs, ["tt1"], "the replace dropped tmdb:5 (not a union)")
}

// MARK: - 5. Disconnect WIPE (cross-account contamination guard)

func testWipeClearsTheShadow() {
    var core = SIMKLWatchedCore(watchedIDs: ["tt1", "tt2", "tmdb:9"])
    core.wipe()
    expectEqual(core.watchedIDs, [], "disconnect wipes the shadow so one account's history can't badge the next")
}

// MARK: - 6. Opt-in GATE (importing another service's history is opt-in)

func testVisibleIDsAreGatedOnTheImportToggle() {
    let core = SIMKLWatchedCore(watchedIDs: ["tt1", "tmdb:movie:550"])
    expectEqual(core.visibleIDs(importOn: false), [], "import OFF hides the whole shadow from the read path")
    expectEqual(core.visibleIDs(importOn: true), ["tt1", "tmdb:movie:550"], "import ON exposes the shadow set")
    let empty = SIMKLWatchedCore()
    expectEqual(empty.visibleIDs(importOn: true), [], "an empty shadow is empty even with import on")
}

// MARK: - Runner
//
// @main (compiled together with the real SIMKLModels / WatchedFold / SIMKLWatchedCore), matching
// TraktWatchedFoldTests and ExternalSyncToggleSyncTests.

@main
struct SIMKLWatchedShadowTests {
    static func main() {
        testMovieFoldsImdbAndBothTmdbForms()
        testShowFoldsImdbAndTypedTvForm()
        testTmdbOnlyRowStillCaptured()
        testImdbOnlyRow()
        testNeitherIdYieldsNothing()
        testNonPositiveTmdbIgnored()
        testMovieAndShowSharingATmdbDoNotCollide()
        testCoreUnionsMoviesShowsAndAnime()
        testCoreDropsRowsWithNoUsableID()
        testDecodesARealCompletedMoviesResponseWithStringTmdb()
        testDecodesARealCompletedShowsResponse()
        testEmptyCompletedListDecodesToNoRows()
        testReplaceReportsChangeAndUpdatesSet()
        testWipeClearsTheShadow()
        testVisibleIDsAreGatedOnTheImportToggle()

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
