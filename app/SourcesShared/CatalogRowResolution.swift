// CatalogRowResolution: the pure rules that decide what a browse/rail card carries when a TMDB discover
// row has been resolved, and how an empty grid explains itself. Kept here, Foundation-only and free of any
// app type, so the standalone test (app/Tests/CatalogRowResolutionTests.swift) compiles THESE EXACT
// functions rather than a mirror of them.
//
// Why it exists: JioHotstar (2336) and ZEE5 (232) are India-regional services whose TMDB catalog rows very
// often have NO IMDb `tt` id. The historic gate dropped every row without a `tt` id, so those provider grids
// and Home rails thinned to empty even though each row had a TMDB name + poster. A `tmdb:<id>` id is
// playable in this app ONLY when an installed add-on can resolve `tmdb:` meta (tvOS/iOS both dispatch the
// detail meta load to the engine, which resolves `tmdb:` ids exclusively through an installed meta add-on
// that declares the `tmdb:` id-prefix), so a provider path keeps a `tt`-less title as `tmdb:<id>` only when
// such an add-on is installed; otherwise the tile would dead-tap and the row is dropped instead.
import Foundation

enum CatalogRowResolution {
    /// The engine-playable id for a discover row that already passed the poster check, or nil to DROP it.
    ///
    /// A real IMDb `tt` id always wins: Cinemeta meta, stream add-ons and the ratings service key on it, and
    /// iOS/Mac detail can skip the resolve round-trip. When TMDB has no `tt` id the general grids (genre,
    /// decade, Discover lists) still DROP the row, so they never surface a source-less foreign title. Only the
    /// PROVIDER paths pass `providerFallback: true`: there an India-regional title with no IMDb id falls back
    /// to the `tmdb:<id>` form the hub detail path already resolves and plays, so the title survives to the
    /// grid and stays tappable instead of vanishing and leaving the tile blank.
    ///
    /// This is the CONFIRMED-id core: it assumes the caller already knows whether an IMDb id exists (a nil
    /// `imdbID` here means "confirmed none", never "lookup failed"). The typed resolver `resolvedRowID`
    /// layers the transient-vs-confirmed distinction and the `tmdb:` add-on gate on top of this rule.
    static func playableID(imdbID: String?, tmdbID: Int, providerFallback: Bool) -> String? {
        if let imdbID, imdbID.hasPrefix("tt") { return imdbID }
        return providerFallback ? "tmdb:\(tmdbID)" : nil
    }

    /// The FINAL outcome of resolving a discover row's TMDB id to an external IMDb id, AFTER any retries.
    /// The whole point of the type is to keep a transient hiccup from masquerading as "no IMDb id":
    ///   - `.imdb`       a confirmed `tt` id (best identity).
    ///   - `.none`       TMDB answered and there is genuinely NO IMDb id for this title.
    ///   - `.unresolved` the lookup kept failing transiently (429 / transport / unreadable body) and the id
    ///                   is simply unknown right now. It might really have a `tt` id, so we must never
    ///                   downgrade it to a weaker `tmdb:` identity on this basis.
    enum ExternalIDResolution: Equatable {
        case imdb(String)
        case none
        case unresolved
    }

    /// Decide the id one discover row ships (or nil to DROP it) from the TYPED external-id outcome, whether
    /// this path allows the `tmdb:` provider fallback, and whether a `tmdb:`-capable meta add-on is installed
    /// so a `tmdb:` tile is actually openable.
    ///
    ///   - `.imdb`       -> the `tt` id, always (identity we trust; no add-on needed).
    ///   - `.none`       -> the `tmdb:` fallback, but ONLY on a provider path AND ONLY when a `tmdb:` meta
    ///                      add-on is installed (else the tile would dead-tap, so DROP). General grids
    ///                      (no provider fallback) still DROP a `tt`-less row.
    ///   - `.unresolved` -> DROP. Falling back to `tmdb:` here could silently downgrade a title that truly
    ///                      has an IMDb id just because the lookup was throttled; the row returns on the next
    ///                      load once TMDB is reachable.
    static func resolvedRowID(_ resolution: ExternalIDResolution,
                              tmdbID: Int,
                              providerFallback: Bool,
                              tmdbMetaAddonInstalled: Bool) -> String? {
        switch resolution {
        case .imdb(let tt):
            return playableID(imdbID: tt, tmdbID: tmdbID, providerFallback: providerFallback)
        case .none:
            guard tmdbMetaAddonInstalled else { return nil }
            return playableID(imdbID: nil, tmdbID: tmdbID, providerFallback: providerFallback)
        case .unresolved:
            return nil
        }
    }

    /// True when a meta add-on whose declared id-prefixes are `idPrefixes` can resolve a `tmdb:` catalog id:
    /// it must expose a `meta` resource AND declare an id-prefix that a `tmdb:` id starts with (Stremio
    /// matches an id to an add-on when some id-prefix is a prefix of the id). The pure core of
    /// `CoreDescriptor.providesTMDBMeta`, kept here so the standalone test proves the `tmdb:` add-on gate
    /// without the engine model.
    static func metaHandlesTMDB(providesMeta: Bool, idPrefixes: [String]) -> Bool {
        guard providesMeta else { return false }
        return idPrefixes.contains { !$0.isEmpty && "tmdb:0".hasPrefix($0) }
    }

    /// The watch_region set a SERVICE grid queries AT ONCE: the viewer's own region first (home relevance),
    /// then the UK + India + US union, order-stably de-duplicated. Querying several regions simultaneously
    /// (not the old "in-region, then US only if page 1 came back empty") is what surfaces an India-only
    /// provider (JioHotstar 2336 / ZEE5 232) for a viewer under another storefront: TMDB scopes
    /// with_watch_providers to the watch_region, so the provider returns nothing under GB but its real catalog
    /// under IN. Pure so the union is unit-tested without network.
    static func unionRegions(base: String, union: [String] = ["GB", "IN", "US"]) -> [String] {
        var out = [base]
        for region in union where !out.contains(region) { out.append(region) }
        return out
    }

    // MARK: - Empty-state cause (an honest reason, not always "region")

    /// Why a browse/service grid finished loading with ZERO items, so the empty-state tells the truth instead
    /// of always blaming the viewer's region. Distinguished so the copy is actionable when it can be.
    enum CatalogEmptyCause: Equatable {
        /// TMDB answered fine, but nothing streams here (an India-only service under a non-India storefront,
        /// even after the multi-region union). The only case that mentions the region setting.
        case region
        /// The lookup could not reach TMDB (offline / DNS / timeout / a non-throttle HTTP error).
        case network
        /// TMDB throttled us (HTTP 429) or a per-title id lookup stayed transient; retrying should help.
        case rateLimited
        /// No usable TMDB key at all (neither a user key nor the bundled/edge key).
        case missingKey
        /// TMDB answered 200 but the body was not the JSON we expected.
        case parseFailure
        /// Discover returned rows, but every one was dropped by the poster / id gates (no IMDb id on a
        /// general grid, or a posterless row).
        case filteredOut
        /// Discover returned rows that would survive as `tmdb:` tiles, but no `tmdb:`-capable metadata
        /// add-on is installed, so they were dropped to avoid dead tiles. Actionable: install one.
        case addonRequired
    }

    /// The empty-state copy for a given cause. Falls back to the original region/neutral wording for the
    /// region case (so existing behavior and its test are unchanged) and adds honest, action-oriented text
    /// for the rest. No em dashes anywhere.
    static func emptyGridMessage(cause: CatalogEmptyCause, isServiceTarget: Bool) -> String {
        switch cause {
        case .region:       return emptyGridMessage(isServiceTarget: isServiceTarget)
        case .network:      return "Couldn't reach the catalog. Check your connection and try again."
        case .rateLimited:  return "The catalog is busy right now. Give it a moment, then try again."
        case .missingKey:   return "Add a TMDB key in Settings to browse this catalog."
        case .parseFailure: return "The catalog sent back something we could not read. Try again."
        case .filteredOut:  return emptyGridMessage(isServiceTarget: false)
        case .addonRequired: return "These titles need a TMDB metadata add-on installed to open."
        }
    }

    /// The text a browse grid shows once it has finished loading with ZERO items. For a streaming SERVICE the
    /// user explicitly picked, an empty grid means the service just is not carried in the viewer's Discover
    /// region (an India-only service under a US/GB watch_region legitimately returns nothing, even after the
    /// multi-region union), so point them at the region setting instead of a bare "Nothing here yet.". Every
    /// other target (genre / decade / Discover) keeps the neutral message.
    static func emptyGridMessage(isServiceTarget: Bool) -> String {
        isServiceTarget
            ? "Not available in your region. Change your Discover region in Settings."
            : "Nothing here yet."
    }

    /// Derive one bucket's empty cause from what its fetch + resolve produced. `fetchFailure` is the typed
    /// transport/HTTP/parse failure (nil when TMDB answered 200 with a JSON body); the remaining counts
    /// describe the resolve step. Returns nil when the bucket is NOT empty (survivors > 0) or, when empty,
    /// the most specific reason it came up empty. `noUsableKey` short-circuits everything.
    static func bucketEmptyCause(noUsableKey: Bool,
                                 fetchFailure: CatalogEmptyCause?,
                                 rowsSeen: Int,
                                 survivors: Int,
                                 droppedAddonGated: Int,
                                 droppedTransient: Int) -> CatalogEmptyCause? {
        if noUsableKey { return .missingKey }
        if survivors > 0 { return nil }
        if let fetchFailure { return fetchFailure }
        if rowsSeen == 0 { return .region }
        if droppedAddonGated > 0 { return .addonRequired }
        if droppedTransient > 0 { return .rateLimited }
        return .filteredOut
    }

    /// Combine the per-bucket causes (movie + tv, and, for a service target, across the UK/India/US union)
    /// into the ONE cause the grid shows. A nil among them means that bucket produced items, so the merged
    /// grid is NOT empty and the cause is nil. When every bucket is empty, the most actionable cause wins by
    /// this fixed priority, so a title that merely needs an add-on, or a transient throttle, is never hidden
    /// behind a flat "not in your region".
    static func mergeCauses(_ causes: [CatalogEmptyCause?]) -> CatalogEmptyCause? {
        if causes.isEmpty { return nil }
        if causes.contains(where: { $0 == nil }) { return nil }
        let present = causes.compactMap { $0 }
        let priority: [CatalogEmptyCause] = [
            .missingKey, .addonRequired, .rateLimited, .network, .parseFailure, .filteredOut, .region,
        ]
        for cause in priority where present.contains(cause) { return cause }
        return present.first
    }
}
