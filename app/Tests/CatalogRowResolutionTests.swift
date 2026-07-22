// CatalogRowResolutionTests: proves the exact resolution rules that fix the empty JioHotstar (2336) and
// ZEE5 (232) catalogs. Unlike most tests here, this one does NOT mirror the logic: it COMPILES AND LINKS the
// real shipped `CatalogRowResolution` (app/SourcesShared/CatalogRowResolution.swift), which is Foundation-only
// and free of app types, so the assertions run against the actual functions the app ships.
//
// Run (compiles the real source file alongside this test):
//
//     swiftc app/SourcesShared/CatalogRowResolution.swift app/Tests/CatalogRowResolutionTests.swift \
//         -o /tmp/catrowtest && /tmp/catrowtest
//
// Properties asserted:
//   1. A real IMDb `tt` id always wins (with or without provider fallback).
//   2. WITHOUT provider fallback, a tt-less row is DROPPED (general genre/decade/Discover grids stay tt-only,
//      so they never surface a source-less foreign title).
//   3. WITH provider fallback, a tt-less row survives as a playable `tmdb:<id>` id (this is what keeps the
//      India-regional provider grids/rails from thinning to empty).
//   4. The service empty-state copy points the user at the Discover region setting; every message is em-dash-free.
import Foundation

@main
struct CatalogRowResolutionTests {
    static func main() {
        var failures = 0
        func check(_ label: String, _ cond: Bool) {
            print(cond ? "ok   - \(label)" : "FAIL - \(label)")
            if !cond { failures += 1 }
        }

        // MARK: playableID (the row-id gate resolveRows + streamingProviderTitles now share)
        check("tt id passes through without provider fallback",
              CatalogRowResolution.playableID(imdbID: "tt0111161", tmdbID: 999, providerFallback: false) == "tt0111161")
        check("tt id preferred over tmdb even with provider fallback",
              CatalogRowResolution.playableID(imdbID: "tt0111161", tmdbID: 999, providerFallback: true) == "tt0111161")
        check("no tt + no fallback DROPS the row (general grids stay tt-only)",
              CatalogRowResolution.playableID(imdbID: nil, tmdbID: 12345, providerFallback: false) == nil)
        check("no tt + provider fallback KEEPS the title as playable tmdb:<id> (JioHotstar/ZEE5 survive)",
              CatalogRowResolution.playableID(imdbID: nil, tmdbID: 12345, providerFallback: true) == "tmdb:12345")
        check("empty imdb string counts as no tt (fallback -> tmdb:)",
              CatalogRowResolution.playableID(imdbID: "", tmdbID: 12345, providerFallback: true) == "tmdb:12345")
        check("empty imdb string with no fallback drops",
              CatalogRowResolution.playableID(imdbID: "", tmdbID: 12345, providerFallback: false) == nil)
        check("a non-tt id (bare number) is not treated as playable without fallback",
              CatalogRowResolution.playableID(imdbID: "12345", tmdbID: 12345, providerFallback: false) == nil)

        // MARK: emptyGridMessage (the honest region empty-state)
        check("service empty-state points at the region setting",
              CatalogRowResolution.emptyGridMessage(isServiceTarget: true)
                == "Not available in your region. Change your Discover region in Settings.")
        check("non-service empty-state keeps the neutral message",
              CatalogRowResolution.emptyGridMessage(isServiceTarget: false) == "Nothing here yet.")
        check("no empty-state message contains an em dash",
              !CatalogRowResolution.emptyGridMessage(isServiceTarget: true).contains("\u{2014}")
                && !CatalogRowResolution.emptyGridMessage(isServiceTarget: false).contains("\u{2014}"))

        if failures == 0 {
            print("\nAll CatalogRowResolution tests passed.")
        } else {
            print("\n\(failures) CatalogRowResolution test(s) FAILED.")
            exit(1)
        }
    }
}
