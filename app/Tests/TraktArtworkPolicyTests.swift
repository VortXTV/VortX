// Standalone contract tests for the Trakt Continue Watching artwork repair:
// alias identity join, source-supplied artwork validation, and old-cache decode.
//
// Run with:
//   swiftc -o /tmp/trakt-artwork-policy \
//     app/SourcesShared/TraktArtworkPolicy.swift \
//     app/SourcesShared/TraktContinueWatchingFold.swift \
//     app/Tests/TraktArtworkPolicyTests.swift && /tmp/trakt-artwork-policy

import Foundation

@MainActor private var failures: [String] = []
@MainActor private var checks = 0

@MainActor
private func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}

@MainActor
private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    checks += 1
    if actual != expected {
        failures.append("\(message): got \(actual), expected \(expected)")
    }
}

@MainActor
private func jsonRows(_ json: String) -> [[String: Any]] {
    let data = Data(json.utf8)
    return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
}

@MainActor
private func movieRow(ids: String, poster: String? = nil) -> String {
    let posterJSON = poster.map { ",\"images\": {\"poster\": [\"\($0)\"]}" } ?? ""
    return """
    {
      "progress": 40,
      "paused_at": "2026-09-10T10:00:00.000Z",
      "type": "movie",
      "movie": {"title": "M", "ids": {\(ids)}\(posterJSON)}
    }
    """
}

@MainActor
private func episodeRow(ids: String) -> String {
    """
    {
      "progress": 40,
      "paused_at": "2026-09-10T10:00:00.000Z",
      "type": "episode",
      "episode": {"season": 1, "number": 2, "runtime": 45},
      "show": {"title": "S", "ids": {\(ids)}}
    }
    """
}

@MainActor
private func testAliasJoinIMDbPlusTMDB() {
    // A row supplying BOTH imdb and tmdb used to collapse to the imdb id alone, so a local row
    // keyed by either tmdb form could never lend its artwork. Now every supplied form is carried.
    let movie = TraktContinueWatchingFold.fold(jsonRows("[\(movieRow(ids: "\"imdb\": \"tt1111111\", \"tmdb\": 11"))]")).first
    expectEqual(movie?.id, "tt1111111", "primary identity is still imdb when supplied")
    expectEqual(movie?.aliases, ["tmdb:movie:11", "tmdb:11"],
                "movie carries its typed and untyped tmdb forms as aliases")

    let series = TraktContinueWatchingFold.fold(jsonRows("[\(episodeRow(ids: "\"imdb\": \"tt2222222\", \"tmdb\": 22"))]")).first
    expectEqual(series?.id, "tt2222222", "episode collapses to the show's imdb id")
    expectEqual(series?.aliases, ["tmdb:tv:22", "tmdb:22"],
                "series carries typed tv and untyped tmdb forms as aliases")

    // The join itself: a local row keyed by the TYPED form lends artwork to an imdb-primary seed.
    let typedJoin = TraktArtworkPolicy.matchedCandidate(
        seedID: "tt2222222",
        seedAliases: series?.aliases ?? [],
        seedType: "series",
        candidates: [TraktArtworkPolicy.Candidate(id: "tmdb:tv:22", type: "series", poster: "https://img/p.jpg")]
    )
    expectEqual(typedJoin?.poster, "https://img/p.jpg",
                "imdb-primary seed joins a local row keyed by tmdb:tv:<n>")

    // And a local row keyed by the UNTYPED form.
    let untypedJoin = TraktArtworkPolicy.matchedCandidate(
        seedID: "tt1111111",
        seedAliases: movie?.aliases ?? [],
        seedType: "movie",
        candidates: [TraktArtworkPolicy.Candidate(id: "tmdb:11", type: "movie", poster: "https://img/m.jpg")]
    )
    expectEqual(untypedJoin?.poster, "https://img/m.jpg",
                "imdb-primary seed joins a local row keyed by untyped tmdb:<n>")
}

@MainActor
private func testUntypedTmdbAmbiguityNeverCrossMatches() {
    // The untyped tmdb:<n> form is shared by movies and series. It must only join same-type rows.
    let seriesSeedAliases = ["tmdb:tv:77", "tmdb:77"]
    let movieCandidate = TraktArtworkPolicy.Candidate(id: "tmdb:77", type: "movie", poster: "https://img/x.jpg")
    expect(TraktArtworkPolicy.matchedCandidate(
        seedID: "tt7777777", seedAliases: seriesSeedAliases, seedType: "series",
        candidates: [movieCandidate]
    ) == nil, "a series seed never joins an untyped tmdb row belonging to a movie")

    let seriesCandidate = TraktArtworkPolicy.Candidate(id: "tmdb:77", type: "series", poster: "https://img/s.jpg")
    expect(TraktArtworkPolicy.matchedCandidate(
        seedID: "tt7777777", seedAliases: seriesSeedAliases, seedType: "series",
        candidates: [seriesCandidate]
    ) != nil, "an untyped tmdb row of the SAME type is a valid join")
}

@MainActor
private func testMovieAndSeriesSharingOneTMDBNumberNeverJoin() {
    // A movie and a series can share the same tmdb number; artwork must never cross that divide.
    let movieSeed = TraktContinueWatchingFold.fold(jsonRows("[\(movieRow(ids: "\"tmdb\": 88"))]")).first
    expectEqual(movieSeed?.id, "tmdb:movie:88", "tmdb-only movie keeps its typed primary")
    expectEqual(movieSeed?.aliases, ["tmdb:88"], "movie aliases carry the untyped form only")

    let seriesRowKeyedUntyped = TraktArtworkPolicy.Candidate(id: "tmdb:88", type: "series", poster: "https://img/s.jpg")
    let seriesRowKeyedTyped = TraktArtworkPolicy.Candidate(id: "tmdb:tv:88", type: "series", poster: "https://img/s.jpg")
    expect(TraktArtworkPolicy.matchedCandidate(
        seedID: movieSeed?.id ?? "", seedAliases: movieSeed?.aliases ?? [], seedType: "movie",
        candidates: [seriesRowKeyedUntyped, seriesRowKeyedTyped]
    ) == nil, "a movie seed borrows artwork from neither form of a same-numbered series")

    let seriesSeed = TraktContinueWatchingFold.fold(jsonRows("[\(episodeRow(ids: "\"tmdb\": 88"))]")).first
    let movieRowKeyedUntyped = TraktArtworkPolicy.Candidate(id: "tmdb:88", type: "movie", poster: "https://img/m.jpg")
    expect(TraktArtworkPolicy.matchedCandidate(
        seedID: seriesSeed?.id ?? "", seedAliases: seriesSeed?.aliases ?? [], seedType: "series",
        candidates: [movieRowKeyedUntyped]
    ) == nil, "a series seed never borrows a same-numbered movie's artwork")

    // Same-numbered, same-type: the join works.
    let goodMovie = TraktArtworkPolicy.Candidate(id: "tmdb:88", type: "movie", poster: "https://img/m.jpg")
    expect(TraktArtworkPolicy.matchedCandidate(
        seedID: movieSeed?.id ?? "", seedAliases: movieSeed?.aliases ?? [], seedType: "movie",
        candidates: [goodMovie]
    ) != nil, "same-type same-number rows do join")
}

@MainActor
private func testSourceSuppliedArtworkIsHTTPSOnly() {
    expectEqual(TraktArtworkPolicy.sourceSuppliedArtwork("https://walter.trakt.tv/images/poster.jpg"),
                "https://walter.trakt.tv/images/poster.jpg", "absolute https artwork is accepted")
    expectEqual(TraktArtworkPolicy.sourceSuppliedArtwork("walter.trakt.tv/images/poster.webp"),
                "https://walter.trakt.tv/images/poster.webp", "Trakt scheme-less artwork is normalized to https")
    expect(TraktArtworkPolicy.sourceSuppliedArtwork("http://walter.trakt.tv/images/poster.jpg") == nil,
           "http URLs are rejected")
    expect(TraktArtworkPolicy.sourceSuppliedArtwork("/images/poster.jpg") == nil,
           "relative poster paths are rejected")
    expect(TraktArtworkPolicy.sourceSuppliedArtwork("poster.jpg") == nil,
           "bare filenames are rejected")
    expect(TraktArtworkPolicy.sourceSuppliedArtwork("//walter.trakt.tv/poster.jpg") == nil,
           "scheme-relative URLs are rejected")
    expect(TraktArtworkPolicy.sourceSuppliedArtwork("https://user:pass@walter.trakt.tv/poster.jpg") == nil,
           "userinfo-bearing URLs are rejected")
    expect(TraktArtworkPolicy.sourceSuppliedArtwork("walter.trakt.tv/poster.jpg?x=1") != nil,
           "scheme-less host/path with query is accepted")
    expect(TraktArtworkPolicy.sourceSuppliedArtwork("") == nil, "empty values are rejected")
    expect(TraktArtworkPolicy.sourceSuppliedArtwork(nil) == nil, "nil values are rejected")

    // Through the fold: only a source-supplied https URL can set the seed poster; anything else,
    // including a plausible http image or a relative tmdb-style path, stays nil.
    let httpsSeed = TraktContinueWatchingFold.fold(
        jsonRows("[\(movieRow(ids: "\"imdb\": \"tt1111111\"", poster: "https://img.example/poster.jpg"))]")
    ).first
    expectEqual(httpsSeed?.poster, "https://img.example/poster.jpg",
                "a row-supplied https poster is carried into the seed")
    let httpSeed = TraktContinueWatchingFold.fold(
        jsonRows("[\(movieRow(ids: "\"imdb\": \"tt1111111\"", poster: "http://img.example/poster.jpg"))]")
    ).first
    expect(httpSeed?.poster == nil, "a row-supplied http poster is dropped")
    let pathSeed = TraktContinueWatchingFold.fold(
        jsonRows("[\(movieRow(ids: "\"imdb\": \"tt1111111\"", poster: "/9xjG.jpg"))]")
    ).first
    expect(pathSeed?.poster == nil, "a row-supplied relative path is dropped")
    let plainSeed = TraktContinueWatchingFold.fold(
        jsonRows("[\(movieRow(ids: "\"imdb\": \"tt1111111\""))]")
    ).first
    expect(plainSeed?.poster == nil, "the documented payload (no images) yields a nil poster")
}

@MainActor
private func testAliasDedupeNeverContainsPrimary() {
    expectEqual(TraktArtworkPolicy.dedupedAliases(["tmdb:5", "tmdb:5", "tt1", "", "tmdb:5"], primary: "tt1"),
                ["tmdb:5"], "duplicate, empty, and primary forms are removed in order")
    expectEqual(TraktArtworkPolicy.dedupedAliases(["tt1"], primary: "tt1"), [],
                "the primary id itself is never an alias")
    expectEqual(TraktArtworkPolicy.dedupedAliases(nil, primary: "tt1"), [],
                "nil aliases decode path dedupes to empty")

    // The fold's own output must satisfy the same invariant.
    let seed = TraktContinueWatchingFold.fold(
        jsonRows("[\(episodeRow(ids: "\"imdb\": \"tt3333333\", \"tmdb\": 33"))]")
    ).first
    let aliases = seed?.aliases ?? []
    expect(!aliases.contains(seed?.id ?? ""), "fold aliases never include the primary id")
    expect(Set(aliases).count == aliases.count, "fold aliases contain no duplicates")
}

@MainActor
private func testDecodesCachesWrittenBeforeAliasesExisted() {
    // Old cache shape: every field the original TraktContinueWatchingSeed had, and nothing more.
    let oldCacheJSON = """
    {"id":"tt1111111","type":"movie","name":"Old Cache Movie","progress":42,
     "pausedAt":"2026-09-10T10:00:00.000Z","runtimeMinutes":100,"videoID":null,"poster":null}
    """
    let oldSeed = try? JSONDecoder().decode(TraktContinueWatchingSeed.self, from: Data(oldCacheJSON.utf8))
    expectEqual(oldSeed?.aliases, nil, "a cache written before aliases decodes with nil aliases")
    expectEqual(oldSeed?.id, "tt1111111", "old cache seed keeps its primary identity")
    expectEqual(oldSeed?.poster, nil, "old cache seed keeps its nil poster")

    // New caches round-trip the aliases and poster.
    let seed = TraktContinueWatchingSeed(
        id: "tt2222222", type: "series", name: "New", progress: 20,
        pausedAt: "2026-09-10T11:00:00.000Z", runtimeMinutes: 45, videoID: "tt2222222:1:2",
        poster: "https://img.example/s.jpg", aliases: ["tmdb:tv:22", "tmdb:22"]
    )
    let data = try? JSONEncoder().encode(seed)
    let back = try? JSONDecoder().decode(TraktContinueWatchingSeed.self, from: data ?? Data())
    expectEqual(back?.aliases, ["tmdb:tv:22", "tmdb:22"], "aliases survive an encode/decode round trip")
    expectEqual(back?.poster, "https://img.example/s.jpg", "poster survives an encode/decode round trip")
}

@main
struct TraktArtworkPolicyTestRunner {
    @MainActor
    static func main() {
        testAliasJoinIMDbPlusTMDB()
        testUntypedTmdbAmbiguityNeverCrossMatches()
        testMovieAndSeriesSharingOneTMDBNumberNeverJoin()
        testSourceSuppliedArtworkIsHTTPSOnly()
        testAliasDedupeNeverContainsPrimary()
        testDecodesCachesWrittenBeforeAliasesExisted()

        if failures.isEmpty {
            print("PASS: \(checks) Trakt artwork policy checks")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
