// Behavior tests for Apple Add-to-Library and watched mutation routing.
//
// Run from the repository root:
//
//   xcrun swiftc -warnings-as-errors -o /tmp/library-watched-contract \
//     app/SourcesShared/LibraryWatchedMutationPolicy.swift \
//     app/Tests/LibraryWatchedMutationContractTests.swift && \
//   /tmp/library-watched-contract

import Foundation

private typealias Policy = LibraryWatchedMutationPolicy
private var failures = 0

private func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

@main
private struct LibraryWatchedMutationContractTests {
    static func main() {
        let movie = Policy.MetaPreview(id: "tt0000001", type: "movie", name: "Movie", poster: nil)
        let series = Policy.MetaPreview(id: "tt0000002", type: "series", name: "Series", poster: "poster")
        let stale = Policy.MetaPreview(id: "tt0000003", type: "movie", name: "Stale", poster: nil)
        let episodes = [
            Policy.Video(id: "ttseries:1:1", season: 1, episode: 1),
            Policy.Video(id: "ttseries:1:2", season: 1, episode: 2),
        ]

        // Owner and overlay take mutually exclusive durable routes.
        check(Policy.route(usesEngineHistory: true) == .engineAccount, "owner mutations route to the engine account")
        check(Policy.route(usesEngineHistory: false) == .profileOverlay, "overlay mutations remain private profile state")

        let expectedSeries = Policy.DetailTarget(id: series.id, type: series.type)
        check(Policy.residentMatches(expectedSeries, residentID: series.id, residentType: series.type),
              "rendered detail target matches its resident meta")
        check(!Policy.residentMatches(expectedSeries, residentID: stale.id, residentType: stale.type),
              "stale detail closure rejects a replacement resident meta")
        check(!Policy.residentMatches(expectedSeries, residentID: series.id, residentType: "movie"),
              "detail target requires matching type as well as id")
        check(Policy.renderedDetailTarget(routeID: "tmdb:7", routeType: "movie",
                                          residentID: series.id, residentType: series.type) == expectedSeries,
              "recovered detail uses its rendered resident identity")
        check(Policy.renderedDetailTarget(routeID: "tmdb:7", routeType: "movie",
                                          residentID: nil, residentType: nil) == .init(id: "tmdb:7", type: "movie"),
              "preload detail retains route identity only as a fallback")
        check(Policy.canDispatchCatalogAdd(metaID: series.id, expectedType: series.type,
                                           previewID: series.id, previewType: series.type),
              "auto add confirms an exact catalog dispatch target")
        check(!Policy.canDispatchCatalogAdd(metaID: series.id, expectedType: series.type,
                                            previewID: series.id, previewType: "movie"),
              "auto add refuses a catalog preview with the wrong type")
        check(!Policy.canDispatchCatalogAdd(metaID: series.id, expectedType: series.type,
                                            previewID: nil, previewType: nil),
              "auto add does not claim dispatch without a catalog preview")
        check(Policy.isCanonicalCatalogID("tt0137523"), "IMDb catalog title id is accepted")
        check(Policy.isCanonicalCatalogID("tmdb:movie:550"), "typed TMDB catalog title id is accepted")
        check(Policy.isCanonicalCatalogID("tmdb:1399"), "legacy TMDB catalog title id is accepted")
        for unsafe in ["tt../1", "tmdb:../1", "tmdb:movie:55/extra", "tmdb:movie:55\\extra", "tt 123", "tt123\\n", "kitsu:123", "tt١٢٣"] {
            check(!Policy.isCanonicalCatalogID(unsafe), "unsafe catalog id is rejected: \(unsafe.debugDescription)")
        }
        check(!Policy.canDispatchCatalogAdd(metaID: series.id, expectedType: "series",
                                            previewID: stale.id, previewType: "series"),
              "resolver response id must exactly match the requested catalog id")
        check(!Policy.canDispatchCatalogAdd(metaID: series.id, expectedType: "series",
                                            previewID: series.id, previewType: "movie"),
              "resolver response type must normalize to the requested type")
        check(Policy.canDispatchCatalogAdd(metaID: "tmdb:tv:1399", expectedType: "series",
                                           previewID: "tmdb:tv:1399", previewType: "tv"),
              "exact resolver response dispatches only after normalized type validation")

        // Movie and series, watched and unwatched, produce deterministic engine action sequences.
        for watched in [false, true] {
            check(Policy.wholeTitleActions(videos: [], isWatched: watched) == [.title(watched)],
                  "movie \(watched ? "watch" : "unwatch") emits aggregate action only")
            check(Policy.wholeTitleActions(videos: episodes, isWatched: watched) == [
                .video(episodes[0], watched), .video(episodes[1], watched), .title(watched),
            ], "series \(watched ? "watch" : "unwatch") updates each episode before aggregate state")
        }

        // A stale ready response must never be used for the title currently on screen.
        check(Policy.detailPreview(targetID: series.id, ready: [stale, series], catalog: nil, decoded: nil) == series,
              "owner add selects matching ready meta")
        check(Policy.detailPreview(targetID: series.id, ready: [stale], catalog: nil, decoded: nil) == nil,
              "owner add rejects stale nonmatching ready meta")
        check(Policy.detailPreview(targetID: series.id, ready: [stale], catalog: series, decoded: nil) == series,
              "owner add falls back to matching catalog preview")
        check(Policy.detailPreview(targetID: series.id, ready: [], catalog: nil, decoded: series) == series,
              "owner add falls back to exact decoded detail preview")
        check(Policy.detailPreview(targetID: series.id, ready: [], catalog: movie, decoded: stale) == nil,
              "owner add rejects mismatched catalog and decoded fallbacks")

        // Sets make reordering a no-op but retain equal-count episode replacements.
        check(Policy.watchedMembershipChanged(["e1", "e2"], ["e2", "e1"]) == false,
              "watched-id ordering alone does not republish")
        check(Policy.watchedMembershipChanged(["e1", "e2"], ["e1", "e3"]) == true,
              "equal-count watched-id replacement republishes")

        if failures > 0 { exit(1) }
    }
}
