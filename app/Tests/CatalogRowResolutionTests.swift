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
//   3. WITH provider fallback, a tt-less row survives as a playable `tmdb:<id>` id ONLY when a tmdb: meta
//      add-on is installed (else it is dropped, never a dead tile) - this is what keeps the India-regional
//      provider grids/rails from thinning to empty while still never leaving an unopenable tile.
//   4. A transient external-id failure is NOT downgraded to a weaker tmdb: identity (retry, do not degrade).
//   5. Service region resolution puts the viewer's OWN region first, appends the SELECTED provider's carried
//      regions bounded + de-duped, queries the user region ALONE for an empty or transiently-failed lookup, and
//      preserves the transient lookup's typed cause (no hardcoded country list anywhere).
//   6. The empty-state copy reflects the REAL cause (region / network / 429 / missing key / parse / filtered /
//      add-on required), and every message is em-dash-free.
import Foundation

@main
struct CatalogRowResolutionTests {
    static func main() {
        var failures = 0
        func check(_ label: String, _ cond: Bool) {
            print(cond ? "ok   - \(label)" : "FAIL - \(label)")
            if !cond { failures += 1 }
        }

        typealias R = CatalogRowResolution
        typealias Cause = CatalogRowResolution.CatalogEmptyCause

        // MARK: playableID (the confirmed-id core resolveRows + streamingProviderTitles still share)
        check("tt id passes through without provider fallback",
              R.playableID(imdbID: "tt0111161", tmdbID: 999, providerFallback: false) == "tt0111161")
        check("tt id preferred over tmdb even with provider fallback",
              R.playableID(imdbID: "tt0111161", tmdbID: 999, providerFallback: true) == "tt0111161")
        check("no tt + no fallback DROPS the row (general grids stay tt-only)",
              R.playableID(imdbID: nil, tmdbID: 12345, providerFallback: false) == nil)
        check("no tt + provider fallback KEEPS the title as playable tmdb:<id>",
              R.playableID(imdbID: nil, tmdbID: 12345, providerFallback: true) == "tmdb:12345")
        check("empty imdb string counts as no tt (fallback -> tmdb:)",
              R.playableID(imdbID: "", tmdbID: 12345, providerFallback: true) == "tmdb:12345")
        check("empty imdb string with no fallback drops",
              R.playableID(imdbID: "", tmdbID: 12345, providerFallback: false) == nil)
        check("a non-tt id (bare number) is not treated as playable without fallback",
              R.playableID(imdbID: "12345", tmdbID: 12345, providerFallback: false) == nil)

        // MARK: resolvedRowID (typed external-id + the tmdb: add-on gate, items 3 and 4)
        // A confirmed IMDb id always wins - no add-on needed, provider or not.
        check("confirmed imdb wins regardless of add-on / provider flags (a)",
              R.resolvedRowID(.imdb("tt0111161"), tmdbID: 9, providerFallback: false, tmdbMetaAddonInstalled: false) == "tt0111161")
        check("confirmed imdb wins regardless of add-on / provider flags (b)",
              R.resolvedRowID(.imdb("tt0111161"), tmdbID: 9, providerFallback: true, tmdbMetaAddonInstalled: false) == "tt0111161")
        // Confirmed-none, provider path: tmdb: survives ONLY with a tmdb: meta add-on installed (item 4).
        check("confirmed-none + provider + add-on installed -> tmdb: tile (openable)",
              R.resolvedRowID(.none, tmdbID: 2336, providerFallback: true, tmdbMetaAddonInstalled: true) == "tmdb:2336")
        check("confirmed-none + provider + NO add-on -> DROP (no dead tile)",
              R.resolvedRowID(.none, tmdbID: 2336, providerFallback: true, tmdbMetaAddonInstalled: false) == nil)
        check("confirmed-none + NO provider -> DROP even with an add-on (general grids stay tt-only)",
              R.resolvedRowID(.none, tmdbID: 2336, providerFallback: false, tmdbMetaAddonInstalled: true) == nil)
        // Transient failure must NEVER downgrade a possibly-tt title to tmdb: (item 3): drop and retry later.
        check("transient (unresolved) + provider + add-on -> DROP, never a downgraded tmdb: tile",
              R.resolvedRowID(.unresolved, tmdbID: 2336, providerFallback: true, tmdbMetaAddonInstalled: true) == nil)
        check("transient (unresolved) + no provider -> DROP",
              R.resolvedRowID(.unresolved, tmdbID: 2336, providerFallback: false, tmdbMetaAddonInstalled: false) == nil)

        // MARK: metaHandlesTMDB (the pure core of CoreDescriptor.providesTMDBMeta, item 4)
        check("a meta add-on with a tmdb: id-prefix handles tmdb: ids",
              R.metaHandlesTMDB(providesMeta: true, idPrefixes: ["tmdb:"]) == true)
        check("a bare 'tmdb' prefix also matches a tmdb: id",
              R.metaHandlesTMDB(providesMeta: true, idPrefixes: ["tmdb"]) == true)
        check("Cinemeta (tt only, no meta for tmdb:) does NOT handle tmdb:",
              R.metaHandlesTMDB(providesMeta: true, idPrefixes: ["tt"]) == false)
        check("no meta resource -> cannot handle tmdb: even with a tmdb: prefix",
              R.metaHandlesTMDB(providesMeta: false, idPrefixes: ["tmdb:"]) == false)
        check("no id-prefixes -> cannot handle tmdb:",
              R.metaHandlesTMDB(providesMeta: true, idPrefixes: []) == false)
        check("an empty-string prefix is ignored (never a false match)",
              R.metaHandlesTMDB(providesMeta: true, idPrefixes: [""]) == false)

        // MARK: serviceRegions (viewer's own region PRIMARY + the SELECTED provider's carried regions, item 1)
        // The viewer's OWN region is ALWAYS first (home relevance), ahead of any provider-carried region.
        check("the viewer's own region is always first, then the provider's carried regions",
              R.serviceRegions(base: "GB", lookup: .resolved(["IN", "US"])).regions == ["GB", "IN", "US"])
        check("a viewer outside the provider's markets still keeps their own region first",
              R.serviceRegions(base: "DE", lookup: .resolved(["IN", "AE"])).regions == ["DE", "IN", "AE"])
        // Bounded: at most maxExtraRegions carried regions beyond the base, most-prominent first.
        check("carried regions are capped at maxExtraRegions beyond the base (most-prominent kept)",
              R.serviceRegions(base: "GB", lookup: .resolved(["IN", "US", "AE", "SA", "SG"]), maxExtraRegions: 3).regions
                == ["GB", "IN", "US", "AE"])
        check("the default cap keeps the base plus three carried regions",
              R.serviceRegions(base: "GB", lookup: .resolved(["IN", "US", "AE", "SA", "SG"])).regions.count == 4)
        // De-duped: the base appearing in the carried list is not repeated, nor is a repeated carried region.
        check("the base region is not duplicated when the provider also lists it",
              R.serviceRegions(base: "IN", lookup: .resolved(["IN", "AE", "GB"])).regions == ["IN", "AE", "GB"])
        check("a repeated carried region is de-duplicated",
              R.serviceRegions(base: "GB", lookup: .resolved(["IN", "IN", "US"])).regions == ["GB", "IN", "US"])
        // An EMPTY carried-region list -> the user region ALONE, and no lookup cause (never a hardcoded union).
        check("an empty carried-region list queries the user region alone",
              R.serviceRegions(base: "GB", lookup: .resolved([])).regions == ["GB"])
        check("an empty carried-region list contributes no lookup cause",
              R.serviceRegions(base: "GB", lookup: .resolved([])).lookupCause == nil)
        check("a resolved-but-empty lookup never invents a country union (US viewer)",
              R.serviceRegions(base: "US", lookup: .resolved([])).regions == ["US"])
        // A TRANSIENT provider-region lookup failure -> user region ALONE, and the typed cause carried forward.
        check("a transient (rateLimited) provider-region failure queries the user region alone",
              R.serviceRegions(base: "GB", lookup: .failed(.rateLimited)).regions == ["GB"])
        check("a transient (rateLimited) provider-region failure preserves its typed cause",
              R.serviceRegions(base: "GB", lookup: .failed(.rateLimited)).lookupCause == .rateLimited)
        check("a network provider-region failure preserves its typed cause",
              R.serviceRegions(base: "GB", lookup: .failed(.network)).lookupCause == .network)

        // MARK: bucketEmptyCause (per-bucket honest reason, item 2)
        check("survivors present -> not empty (nil cause)",
              R.bucketEmptyCause(noUsableKey: false, fetchFailure: nil, rowsSeen: 10, survivors: 3, droppedAddonGated: 0, droppedTransient: 0) == nil)
        check("no usable key short-circuits to missingKey",
              R.bucketEmptyCause(noUsableKey: true, fetchFailure: .region, rowsSeen: 0, survivors: 0, droppedAddonGated: 0, droppedTransient: 0) == .missingKey)
        check("a fetch failure reports itself (network)",
              R.bucketEmptyCause(noUsableKey: false, fetchFailure: .network, rowsSeen: 0, survivors: 0, droppedAddonGated: 0, droppedTransient: 0) == .network)
        check("TMDB answered with zero rows -> region",
              R.bucketEmptyCause(noUsableKey: false, fetchFailure: nil, rowsSeen: 0, survivors: 0, droppedAddonGated: 0, droppedTransient: 0) == .region)
        check("rows existed but all add-on gated -> addonRequired",
              R.bucketEmptyCause(noUsableKey: false, fetchFailure: nil, rowsSeen: 8, survivors: 0, droppedAddonGated: 8, droppedTransient: 0) == .addonRequired)
        check("rows existed but all stayed transient -> rateLimited",
              R.bucketEmptyCause(noUsableKey: false, fetchFailure: nil, rowsSeen: 8, survivors: 0, droppedAddonGated: 0, droppedTransient: 8) == .rateLimited)
        check("rows existed but all filtered (no imdb / posterless) -> filteredOut",
              R.bucketEmptyCause(noUsableKey: false, fetchFailure: nil, rowsSeen: 8, survivors: 0, droppedAddonGated: 0, droppedTransient: 0) == .filteredOut)
        check("add-on gated takes precedence over transient within one bucket",
              R.bucketEmptyCause(noUsableKey: false, fetchFailure: nil, rowsSeen: 8, survivors: 0, droppedAddonGated: 3, droppedTransient: 5) == .addonRequired)

        // MARK: mergeCauses (across movie/tv buckets and the region union, item 1 + 2)
        check("any bucket with items -> merged grid is not empty (nil)",
              R.mergeCauses([.region, nil, .network]) == nil)
        check("empty union of causes -> nil",
              R.mergeCauses([]) == nil)
        check("addonRequired outranks a flat region across the union",
              R.mergeCauses([.region, .region, .addonRequired]) == .addonRequired)
        check("a transient (rateLimited) region outranks a plain region-empty region",
              R.mergeCauses([.region, .rateLimited]) == .rateLimited)
        check("network outranks parseFailure and region",
              R.mergeCauses([.parseFailure, .network, .region]) == .network)
        check("missingKey outranks everything",
              R.mergeCauses([.addonRequired, .network, .missingKey]) == .missingKey)
        check("all region -> region",
              R.mergeCauses([.region, .region, .region]) == .region)

        // MARK: emptyGridMessage (the cause-typed empty-state copy, item 2)
        check("region service empty-state points at the region setting",
              R.emptyGridMessage(cause: .region, isServiceTarget: true)
                == "Not available in your region. Change your Discover region in Settings.")
        check("region non-service empty-state keeps the neutral message",
              R.emptyGridMessage(cause: .region, isServiceTarget: false) == "Nothing here yet.")
        check("network cause tells the user to check their connection",
              R.emptyGridMessage(cause: .network, isServiceTarget: true).lowercased().contains("connection"))
        check("rateLimited cause asks the user to try again in a moment",
              R.emptyGridMessage(cause: .rateLimited, isServiceTarget: true).lowercased().contains("moment"))
        check("missingKey cause mentions a TMDB key",
              R.emptyGridMessage(cause: .missingKey, isServiceTarget: false).contains("TMDB key"))
        check("addonRequired cause mentions a TMDB metadata add-on",
              R.emptyGridMessage(cause: .addonRequired, isServiceTarget: true).contains("TMDB metadata add-on"))
        check("parseFailure cause is distinct from the region copy",
              R.emptyGridMessage(cause: .parseFailure, isServiceTarget: true)
                != R.emptyGridMessage(cause: .region, isServiceTarget: true))
        check("filteredOut cause is the neutral message, never the region one",
              R.emptyGridMessage(cause: .filteredOut, isServiceTarget: true) == "Nothing here yet.")

        // MARK: legacy emptyGridMessage(isServiceTarget:) still holds (kept for the confirmed-id path + copy)
        check("legacy service empty-state points at the region setting",
              R.emptyGridMessage(isServiceTarget: true)
                == "Not available in your region. Change your Discover region in Settings.")
        check("legacy non-service empty-state keeps the neutral message",
              R.emptyGridMessage(isServiceTarget: false) == "Nothing here yet.")

        // MARK: no empty-state copy contains an em dash (a HARD writing rule)
        let allCauses: [Cause] = [.region, .network, .rateLimited, .missingKey, .parseFailure, .filteredOut, .addonRequired]
        let emDashFree = allCauses.allSatisfy { cause in
            !R.emptyGridMessage(cause: cause, isServiceTarget: true).contains("\u{2014}")
                && !R.emptyGridMessage(cause: cause, isServiceTarget: false).contains("\u{2014}")
        }
        check("no cause-typed empty-state message contains an em dash", emDashFree)
        check("legacy empty-state messages contain no em dash",
              !R.emptyGridMessage(isServiceTarget: true).contains("\u{2014}")
                && !R.emptyGridMessage(isServiceTarget: false).contains("\u{2014}"))

        if failures == 0 {
            print("\nAll CatalogRowResolution tests passed.")
        } else {
            print("\n\(failures) CatalogRowResolution test(s) FAILED.")
            exit(1)
        }
    }
}
