// SIMKLUpcomingFoldTests: a standalone, runnable verification of the PURE seed-union fold that folds a SIMKL
// user's plan-to-watch titles into the Upcoming rails (SourcesShared/SIMKLUpcomingSeeds.swift).
//
// The impure half (fetch plan-to-watch, resolve tmdb->tt) lives in ReleaseCalendarModel and cannot link
// standalone; the rule that matters - append only ids the library / local watchlist did not already carry,
// base wins on order and name, anime folds as a series seed - is pure and is what this exercises:
//
//     swiftc -o /tmp/simklupcoming \
//       app/SourcesShared/SIMKLUpcomingSeeds.swift \
//       app/Tests/SIMKLUpcomingFoldTests.swift && /tmp/simklupcoming

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

func seed(_ id: String, _ type: String, _ name: String = "") -> SIMKLUpcomingSeeds.Seed {
    SIMKLUpcomingSeeds.Seed(id: id, type: type, name: name)
}

// MARK: - Fold rules

func testEmptySIMKLLeavesBaseUnchanged() {
    let folded = SIMKLUpcomingSeeds.fold(baseSeriesIDs: ["tt1", "tt2"], baseSeriesNames: ["tt1": "One"],
                                         baseMovieIDs: ["tt9"], baseMovieNames: [:], simkl: [])
    expectEqual(folded.seriesIDs, ["tt1", "tt2"], "no SIMKL seeds leaves the series ids identical")
    expectEqual(folded.movieIDs, ["tt9"], "no SIMKL seeds leaves the movie ids identical")
    expectEqual(folded.seriesNames, ["tt1": "One"], "names are untouched with no SIMKL seeds")
}

func testSIMKLSeriesAppendedAfterBase() {
    let folded = SIMKLUpcomingSeeds.fold(baseSeriesIDs: ["tt1"], baseSeriesNames: [:],
                                         baseMovieIDs: [], baseMovieNames: [:],
                                         simkl: [seed("tt5", "series", "Followed Show")])
    expectEqual(folded.seriesIDs, ["tt1", "tt5"], "a SIMKL series is appended after the base ids")
    expectEqual(folded.seriesNames["tt5"], "Followed Show", "the SIMKL series name is filled")
}

func testAnimeFoldsAsASeriesSeed() {
    // SIMKLListEntry maps anime -> type "series", so an anime plan-to-watch title lands in the series list.
    let folded = SIMKLUpcomingSeeds.fold(baseSeriesIDs: [], baseSeriesNames: [:],
                                         baseMovieIDs: [], baseMovieNames: [:],
                                         simkl: [seed("tt7", "series", "Some Anime")])
    expectEqual(folded.seriesIDs, ["tt7"], "an anime (series-typed) seed folds into the series list")
    expect(folded.movieIDs.isEmpty, "an anime seed does not leak into the movie list")
}

func testSIMKLMovieFoldsIntoMovieList() {
    let folded = SIMKLUpcomingSeeds.fold(baseSeriesIDs: [], baseSeriesNames: [:],
                                         baseMovieIDs: ["tt9"], baseMovieNames: [:],
                                         simkl: [seed("tt8", "movie", "Coming Film")])
    expectEqual(folded.movieIDs, ["tt9", "tt8"], "a SIMKL movie is appended after the base movie ids")
    expectEqual(folded.movieNames["tt8"], "Coming Film", "the SIMKL movie name is filled")
}

func testBaseWinsOnDuplicateIdAndName() {
    // A SIMKL title the library already carries must NOT be appended twice, and the base name must stand.
    let folded = SIMKLUpcomingSeeds.fold(baseSeriesIDs: ["tt1"], baseSeriesNames: ["tt1": "Library Name"],
                                         baseMovieIDs: [], baseMovieNames: [:],
                                         simkl: [seed("tt1", "series", "SIMKL Name")])
    expectEqual(folded.seriesIDs, ["tt1"], "a duplicate id is not appended a second time")
    expectEqual(folded.seriesNames["tt1"], "Library Name", "the base (library) name wins over the SIMKL name")
}

func testDuplicateSIMKLSeedsCollapse() {
    let folded = SIMKLUpcomingSeeds.fold(baseSeriesIDs: [], baseSeriesNames: [:],
                                         baseMovieIDs: [], baseMovieNames: [:],
                                         simkl: [seed("tt5", "series", "A"), seed("tt5", "series", "B")])
    expectEqual(folded.seriesIDs, ["tt5"], "two SIMKL seeds with the same id collapse to one")
    expectEqual(folded.seriesNames["tt5"], "A", "the first SIMKL name wins on a duplicate seed")
}

func testEmptyIdSeedIgnored() {
    let folded = SIMKLUpcomingSeeds.fold(baseSeriesIDs: ["tt1"], baseSeriesNames: [:],
                                         baseMovieIDs: [], baseMovieNames: [:],
                                         simkl: [seed("", "series", "No Id")])
    expectEqual(folded.seriesIDs, ["tt1"], "a seed with an empty id is ignored")
}

func testEmptyNameNotWritten() {
    let folded = SIMKLUpcomingSeeds.fold(baseSeriesIDs: [], baseSeriesNames: [:],
                                         baseMovieIDs: [], baseMovieNames: [:],
                                         simkl: [seed("tt5", "series", "")])
    expectEqual(folded.seriesIDs, ["tt5"], "a nameless SIMKL series still seeds the list")
    expect(folded.seriesNames["tt5"] == nil, "an empty name is not written into the names map")
}

func testDeterministicOrderAcrossMixedTypes() {
    let folded = SIMKLUpcomingSeeds.fold(baseSeriesIDs: ["s0"], baseSeriesNames: [:],
                                         baseMovieIDs: ["m0"], baseMovieNames: [:],
                                         simkl: [seed("s1", "series"), seed("m1", "movie"), seed("s2", "series")])
    expectEqual(folded.seriesIDs, ["s0", "s1", "s2"], "series seeds keep base-first, then SIMKL order")
    expectEqual(folded.movieIDs, ["m0", "m1"], "movie seeds keep base-first, then SIMKL order")
}

// MARK: - Runner

@main
struct SIMKLUpcomingFoldTests {
    static func main() {
        testEmptySIMKLLeavesBaseUnchanged()
        testSIMKLSeriesAppendedAfterBase()
        testAnimeFoldsAsASeriesSeed()
        testSIMKLMovieFoldsIntoMovieList()
        testBaseWinsOnDuplicateIdAndName()
        testDuplicateSIMKLSeedsCollapse()
        testEmptyIdSeedIgnored()
        testEmptyNameNotWritten()
        testDeterministicOrderAcrossMixedTypes()

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
