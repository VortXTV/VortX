// Standalone contract tests for the Trakt Continue Watching fold.
//
// Run with:
//   swiftc -o /tmp/trakt-cw-fold \
//     app/SourcesShared/TraktContinueWatchingFold.swift \
//     app/Tests/TraktContinueWatchingFoldTests.swift && /tmp/trakt-cw-fold

import Foundation

@MainActor var failures: [String] = []
@MainActor var checks = 0

@MainActor
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    checks += 1
    if actual != expected {
        failures.append("\(message): got \(actual), expected \(expected)")
    }
}

@MainActor
func jsonRows(_ json: String) -> [[String: Any]] {
    let data = Data(json.utf8)
    return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
}

@MainActor
func testFoldsMovieAndEpisodeInPausedOrder() {
    let rows = jsonRows("""
    [
      {
        "progress": 42.5,
        "paused_at": "2026-07-27T10:00:00.000Z",
        "type": "movie",
        "movie": {
          "title": "Movie One",
          "runtime": 120,
          "ids": {"imdb": "tt1111111", "tmdb": 11}
        }
      },
      {
        "progress": 25,
        "paused_at": "2026-07-28T10:00:00.000Z",
        "type": "episode",
        "episode": {"season": 2, "number": 3, "runtime": 48},
        "show": {
          "title": "Show One",
          "ids": {"imdb": "tt2222222", "tmdb": 22}
        }
      }
    ]
    """)

    let seeds = TraktContinueWatchingFold.fold(rows)
    expectEqual(seeds.count, 2, "movie and episode both survive")
    expectEqual(seeds[0].id, "tt2222222", "newest paused item sorts first")
    expectEqual(seeds[0].type, "series", "episode maps to series detail identity")
    expectEqual(seeds[0].videoID, "tt2222222:2:3", "episode video id keeps season and episode")
    expectEqual(seeds[0].runtimeMinutes, 48, "episode runtime is preserved")
    expectEqual(seeds[0].resumeSeconds, 720, "displayed 25 percent maps to the exact 12-minute resume offset")
    expectEqual(seeds[1].id, "tt1111111", "movie identity uses imdb")
    expectEqual(seeds[1].type, "movie", "movie type is preserved")
}

@MainActor
func testUsesTypedTmdbFallbacks() {
    let rows = jsonRows("""
    [
      {
        "progress": 10,
        "paused_at": "2026-07-28T10:00:00.000Z",
        "type": "movie",
        "movie": {"title": "Movie", "ids": {"tmdb": 44}}
      },
      {
        "progress": 20,
        "paused_at": "2026-07-28T11:00:00.000Z",
        "type": "episode",
        "episode": {"season": 0, "number": 1},
        "show": {"title": "Show", "ids": {"tmdb": 55}}
      }
    ]
    """)

    let seeds = TraktContinueWatchingFold.fold(rows)
    expectEqual(seeds[0].id, "tmdb:tv:55", "show uses typed tv fallback")
    expectEqual(seeds[0].videoID, "tmdb:tv:55:0:1", "special episode keeps season zero")
    expectEqual(seeds[1].id, "tmdb:movie:44", "movie uses typed movie fallback")
}

@MainActor
func testKeepsOnlyNewestEpisodePerShow() {
    let rows = jsonRows("""
    [
      {
        "progress": 60,
        "paused_at": "2026-07-27T10:00:00.000Z",
        "type": "episode",
        "episode": {"season": 1, "number": 1, "runtime": 50},
        "show": {"title": "Show", "ids": {"imdb": "tt3333333"}}
      },
      {
        "progress": 30,
        "paused_at": "2026-07-28T10:00:00.000Z",
        "type": "episode",
        "episode": {"season": 1, "number": 2, "runtime": 50},
        "show": {"title": "Show", "ids": {"imdb": "tt3333333"}}
      }
    ]
    """)

    let seeds = TraktContinueWatchingFold.fold(rows)
    expectEqual(seeds.count, 1, "one Continue Watching card is emitted per show")
    expectEqual(seeds[0].videoID, "tt3333333:1:2", "newest episode wins")
    expectEqual(seeds[0].progress, 30, "newest episode progress wins")
}

@MainActor
func testRejectsUnusableAndFinishedRows() {
    let rows = jsonRows("""
    [
      {
        "progress": 0,
        "type": "movie",
        "movie": {"title": "Zero", "ids": {"imdb": "tt4444444"}}
      },
      {
        "progress": 95,
        "type": "movie",
        "movie": {"title": "Credits", "ids": {"imdb": "tt5555555"}}
      },
      {
        "progress": 20,
        "type": "movie",
        "movie": {"title": "No identity", "ids": {"trakt": 99}}
      }
    ]
    """)

    expect(TraktContinueWatchingFold.fold(rows).isEmpty,
           "zero, near-finished, and identity-less rows are excluded")
}

@MainActor
func testTracksMovieAndEpisodeActivitySeparately() {
    let known = TraktPlaybackActivityStamps(
        movies: "2026-07-27T09:00:00.000Z",
        episodes: "2026-07-28T10:00:00.000Z"
    )
    let movieAdvanced = TraktPlaybackActivityStamps(
        movies: "2026-07-28T09:00:00.000Z",
        episodes: "2026-07-28T10:00:00.000Z"
    )

    expect(known != movieAdvanced,
           "a movie activity change is visible even while the newer episode timestamp is unchanged")
    expectEqual(known.legacyMaximum, "2026-07-28T10:00:00.000Z",
                "the downgrade-compatible cursor keeps the newest legacy value")
}

@main
struct TraktContinueWatchingFoldTestRunner {
    @MainActor
    static func main() {
        testFoldsMovieAndEpisodeInPausedOrder()
        testUsesTypedTmdbFallbacks()
        testKeepsOnlyNewestEpisodePerShow()
        testRejectsUnusableAndFinishedRows()
        testTracksMovieAndEpisodeActivitySeparately()

        if failures.isEmpty {
            print("PASS: \(checks) Trakt Continue Watching fold checks")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
