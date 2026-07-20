import SwiftUI

/// Native tvOS Home, driven by the **stremio-core** engine (via `CoreBridge`): a "Continue Watching"
/// rail plus every catalog of every installed addon, on the StremioX design system (Theme.swift).
struct HomeView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var vortxSync: VortXSyncManager   // VortX-primary front door: a VortX sign-in unlocks the tabs even with no Stremio account connected
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var presenter: PlayerPresenter   // gates the ambient hero trailer off while the player is up
    @StateObject private var focusModel = FocusedItemModel()
    @StateObject private var topPicks = TopPicksModel()   // local recommendations from this profile's history
    @StateObject private var becauseYouWatched = BecauseYouWatchedModel()   // "Because you watched <title>" rail, seeded from recent watches
    @StateObject private var traktRails = TraktRailsModel()   // Trakt watchlist as a client-side rail (dormant with empty creds)
    @StateObject private var simklRails = SIMKLRailsModel()   // SIMKL plan-to-watch as a client-side rail (dormant with empty creds)
    @StateObject private var mediaServerRails = MediaServerCatalogsModel()   // "Recently added" on connected Plex/Jellyfin/Emby servers (dormant with none)
    @StateObject private var releaseCalendar = ReleaseCalendarModel()   // "Upcoming Episodes" from the series library (next 45 days)
    @ObservedObject private var collectionsHub = CollectionsHubModel.shared   // Collections hub (shared singleton): Discover cards + Streaming-service tiles + Genre tiles
    @ObservedObject private var imported = ImportedCatalogs.shared   // user-imported list catalogs, rendered as Home rows
    @ObservedObject private var railPrefs = HomeRailPreferences.shared   // user's Home row order + hidden set (Continue Watching stays pinned first)
    @State private var showCustomize = false   // presents the Home rows reorder/hide manage screen
    @AppStorage("vortx.home.showCollectionsHub") private var showCollectionsHub = true   // toggle the hub on Home (needs a TMDB key)
    @StateObject private var heroTrailer = HomeHeroTrailerModel()   // #44: focus-settled muted hero trailer
    @AppStorage("stremiox.autoplayTrailers") private var autoplayTrailers = true
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared   // #105: rails vs poster-wall Home layout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The owner profile rides the account's Continue Watching; overlay profiles ride their own
    /// private synced history.
    private var continueWatching: [CoreCWItem] {
        profiles.activeUsesEngineHistory ? core.continueWatching : profiles.cwItems
    }

    /// The profile-aware library, used (with Continue Watching) to seed + exclude in Top Picks.
    private var libraryItems: [CoreCWItem] {
        profiles.activeUsesEngineHistory ? (core.library?.catalog ?? []) : profiles.libraryItems
    }

    var body: some View {
        homeChangeHandlers
    }

    /// The Home shell: the hero backdrop, the rail strip, and the header overlay. Split out of
    /// `body` so the change-handler chain applied over it (see `homeChangeHandlers`) type-checks
    /// as its own expression.
    private var homeShell: some View {
        NavigationStack {
            ZStack {
                // The living backdrop: whichever poster is focused fills the screen with its
                // artwork and details. Pure presentation, never focusable, so pressing up from
                // the rails lands straight on the tab bar.
                // detailsBottom = strip height (470) + a breathing gap, so the synopsis can never
                // run into the rail header regardless of tab-bar safe-area shifts.
                BrowseHeroBackdrop(model: focusModel, detailsBottom: 520) {
                    // #44: once focus SETTLES on a catalog item for ~3s, its muted FULL trailer fades in
                    // over the still backdrop but UNDER the logo / meta / synopsis (and under the rails), so
                    // the hero details stay visible OVER the clip exactly as they read over the still art.
                    // (The clip used to be an `.overlay` here, which painted it above the details and blanked
                    // the hero of all its text while the clip played.) Gated on the same autoplay-trailers
                    // setting + reduce-motion as the detail hero, and keyed on the resolved URL so a focus
                    // change (which clears it) tears the libmpv layer down. Non-focusable + no hit-testing
                    // inside the view, so the focus engine is untouched.
                    // Also gated by the RemoteConfig fleet kill-switch `features.trailers`: a remote
                    // `false` force-disables ambient hero trailers fleet-wide (e.g. if the trailer worker
                    // is degraded). Baked default true => absent/null remote is identical to shipping; the
                    // user's "Auto-play trailers" setting still governs.
                    // `presenter.request == nil` (PR #106): the player presents OVER this shell, which stays
                    // mounted (opacity-hidden), so without this gate the hero clip's libmpv instance kept
                    // decoding its looping 1080p trailer under the whole movie (micro stutter + audio crackle
                    // on every stream). Unmounting tears it down the moment the player presents; it remounts
                    // fresh on close.
                    if autoplayTrailers, RemoteConfig.snapshot.isFeatureOn("trailers", default: true),
                       !reduceMotion, presenter.request == nil, let url = heroTrailer.url {
                        TVInHeroTrailerView(url: url)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                }
                // The rails live in a bottom strip. The focus engine centers focused rows inside
                // THIS viewport, so they are geometrically incapable of riding up over the hero.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                        Color.clear.frame(height: 0).scrollToTopAnchor()   // re-select Home tab -> scroll here
                        if !continueWatching.isEmpty {
                            // The long-press menu is safe on every profile now: Details is pure
                            // navigation, and the dismiss routes into the overlay profile's own
                            // history inside CoreBridge.removeFromLibrary.
                            // Continue Watching stays a RAIL at the top in BOTH Home layouts (#105): it is a
                            // queue the user steps through in recency order, not a browse surface, so the
                            // poster-wall option never reshapes it. It is PINNED first (not part of
                            // HomeRailPreferences), so "Customize Home" never moves or hides it.
                            CoreContinueWatchingRow(items: continueWatching, focusModel: focusModel)
                        }
                        // Every other Home section renders in the user's arranged order, minus the hidden ones
                        // (HomeRailPreferences). Default order + nothing hidden == today's Home exactly, so this
                        // is a no-op until the user customizes via the "Customize Home" manage screen.
                        ForEach(railPrefs.arrange(HomeRail.tvDefaultOrder)) { section in
                            if !railPrefs.isHidden(section) {
                                homeSection(section)
                            }
                        }
                        if continueWatching.isEmpty && core.boardRows.isEmpty {
                            if account.isSignedIn || vortxSync.isSignedIn { LoadingRail() } else { CoreEmptyState.signedOut }
                        }
                    }
                    .padding(.top, Theme.Space.sm)
                    .padding(.bottom, Theme.Space.xl)
                }
                .heroBottomStrip()
                // Re-selecting the active Home tab scrolls the rail strip back to the top.
                .scrollToTopOnBump(TabScrollKeys.home)
            }
            .overlay(alignment: .topLeading) {
                header
                    .padding(.top, 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea()   // absolute top-left, clear of the hero title below
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .fullScreenCover(isPresented: $showCustomize) { TVHomeRailEditorView() }
        }
    }

    // The `.onAppear` plus nine `.onChange` handlers used to hang off `body` as one chain, which
    // overran the SwiftUI type checker's budget. They are applied in two passes across `some View`
    // boundaries below so each group type-checks as its own expression; triggers and closures are
    // unchanged, and the pass order preserves the original modifier order.

    /// First pass: initial seed on appear, plus the row / Continue Watching / profile re-seed triggers.
    private var homeSeedHandlers: some View {
        homeShell
        .onAppear { configureMetaSources(); seed(); refreshTopPicks(); refreshReleaseCalendar(); if showCollectionsHub { collectionsHub.load() } }
        .onChange(of: showCollectionsHub) { show in if show { collectionsHub.load() } }   // no clear() on toggle-off: render is gated on showCollectionsHub, and clear() blanked the shared hub for Discover too
        .onChange(of: core.boardRows.first?.id) { seed() }
        .onChange(of: core.continueWatching.first?.id) { seed(); refreshTopPicks() }
        // An overlay profile draws its Continue Watching from `profiles.cwItems`, not the engine, so its own
        // plays must also re-seed the hero and Top Picks (the engine-CW onChange above never fires for them).
        .onChange(of: profiles.cwItems.first?.id) { seed(); refreshTopPicks() }
        .onChange(of: profiles.activeID) { seed(); refreshTopPicks() }
    }

    /// Second pass: the release-calendar / meta-source triggers and the focus-settled hero trailer.
    private var homeChangeHandlers: some View {
        homeSeedHandlers
        // Rebuild "Upcoming Episodes" when the library changes (a new follow) or the meta add-ons hydrate
        // — the same two inputs the model sweeps over. The bases come from `account.addons`, which loads
        // async after sign-in, so key on its count too (matching the notification sweep's input set).
        .onChange(of: core.library?.catalog.count ?? 0) { refreshReleaseCalendar() }
        .onChange(of: account.addons.count) { refreshReleaseCalendar() }
        .onChange(of: core.addons.count) { configureMetaSources(); refreshReleaseCalendar() }
        // Drive the focus-settled hero trailer (#44): every hero change re-arms the 3s debounce and tears
        // down the current trailer, so scrolling catalog-to-catalog never loads a clip.
        .onChange(of: focusModel.hero?.id) { heroTrailer.focusChanged(to: focusModel.hero) }
        // Trakt disconnect: drop the watchlist rail immediately rather than waiting for the refresh window.
        .onReceive(NotificationCenter.default.publisher(for: TraktRailsModel.disconnectedNote)) { _ in traktRails.clear() }
        // SIMKL disconnect: same contract as Trakt above, drop the plan-to-watch rail now.
        .onReceive(NotificationCenter.default.publisher(for: SIMKLRailsModel.disconnectedNote)) { _ in simklRails.clear() }
        // A watchlist bookmark toggle feeds the Upcoming rails (refreshUpcoming folds it in), so rebuild them now.
        .onReceive(NotificationCenter.default.publisher(for: LibraryAutoAdd.watchlistChangedNote)) { _ in refreshReleaseCalendar() }
    }

    /// Recompute the "Top Picks for you" rail from the profile-aware Continue Watching + library.
    /// The model no-ops when the seed set is unchanged, so this is cheap to call on every re-emit.
    private func refreshTopPicks() {
        topPicks.refresh(profileID: profiles.activeID, cw: continueWatching, library: libraryItems)
        becauseYouWatched.refresh(profileID: profiles.activeID, cw: continueWatching, library: libraryItems)   // "Because you watched <title>" rail; no-ops on an unchanged seed set
        traktRails.refresh()   // Trakt watchlist rail; internally throttled + dormant with empty creds
        simklRails.refresh()   // SIMKL plan-to-watch rail; internally throttled + dormant with empty creds
        mediaServerRails.refresh()   // "Recently added" on connected media servers; throttled + dormant with none
    }

    /// Recompute "Upcoming Episodes" from the series library + the installed meta add-on bases — derived
    /// EXACTLY like the new-episode notification sweep (series-typed library ids + names, `providesMeta`
    /// add-on base URLs). The model no-ops when the series set is unchanged, so this is cheap to re-call.
    private func refreshReleaseCalendar() {
        let catalog = core.library?.catalog ?? []
        let bases = account.addons.filter { $0.providesMeta }.map(\.baseUrl)
        let series = catalog.filter { $0.type == "series" }
        let seriesNames = Dictionary(series.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let movies = catalog.filter { $0.type == "movie" }
        let movieNames = Dictionary(movies.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let moviePosters = Dictionary(movies.compactMap { m in m.poster.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
        // Fold the local watchlist into both Upcoming rails (refreshUpcoming) so a bookmarked-but-not-in-library
        // title still surfaces its next air / release date; library ids win on name / poster.
        releaseCalendar.refreshUpcoming(librarySeriesIDs: series.map(\.id), librarySeriesNames: seriesNames,
                                        libraryMovieIDs: movies.map(\.id), libraryMovieNames: movieNames,
                                        libraryMoviePosters: moviePosters, metaBases: bases)
    }

    /// The hero enrichment asks the user's own meta add-ons, so every id scheme resolves.
    private func configureMetaSources() {
        let metaUrls = core.addons.filter(\.providesMeta).map(\.transportUrl)
        FocusedItemModel.configureMetaSources(transportUrls: metaUrls)
        heroTrailer.configureMetaSources(transportUrls: metaUrls)
    }

    /// First render shows the page's actual first item, and Continue Watching pre-fetches its
    /// details so heroes are rich on first focus.
    private func seed() {
        focusModel.seedIfEmpty(continueWatching.first?.focusedHero
                               ?? core.boardRows.first?.items.first?.focusedHero)
        focusModel.warm(continueWatching.map(\.focusedHero))
        // Mirror Continue Watching onto the tvOS Home screen's Top Shelf. Hooked HERE because `seed()`
        // is already the point every input the shelf cares about converges on: it runs on appear and on
        // each of the Continue Watching / overlay-profile-history / active-profile changes, so the shelf
        // tracks the rail (including a profile switch, which must swap whose titles are on show, and a
        // sign-out, which must clear them). The writer resolves the profile-aware history itself and the
        // store diffs content, so an unchanged re-seed writes nothing and wakes no extension.
        TopShelfSnapshotWriter.publishCurrent()
    }

    /// Render one reorderable Home section. Each case is the section's ORIGINAL view, unchanged, moved behind
    /// a stable `HomeRail` key so `HomeRailPreferences` can order + hide it. Continue Watching is pinned
    /// separately (above), so it has no case here. Every internal gate (empty checks, `showCollectionsHub`,
    /// pagination) still applies, so a not-hidden section in default order is byte-identical to today.
    @ViewBuilder
    private func homeSection(_ section: HomeRail) -> some View {
        switch section {
        case .collectionsHub:
            // Collections hub (Discover cards, Streaming-service tiles, Genre tiles). Each tile opens a
            // sub-catalog browse grid. Needs a TMDB key; hidden without one.
            if showCollectionsHub, CollectionsHubModel.isAvailable {
                TVCollectionsHub(model: collectionsHub)
            }
        case .topPicks:
            // Local recommendations seeded from this profile's recent watch history (#0.3.9).
            if !topPicks.items.isEmpty {
                TopPicksRow(items: topPicks.items, focusModel: focusModel)
            }
        case .becauseYouWatched:
            // "Because you watched <title>": recommendations named after the most recent seed.
            if let rail = becauseYouWatched.rail {
                StreamingRow(title: rail.title, items: rail.items, focusModel: focusModel)
            }
        case .traktWatchlist:
            // Trakt watchlist as a client-side rail. Zero engine writes; dormant with empty creds.
            if !traktRails.items.isEmpty {
                ExternalWatchlistRow(eyebrow: String(localized: "From Trakt"),
                                     title: String(localized: "Trakt Watchlist"),
                                     items: traktRails.items, focusModel: focusModel)
            }
        case .simklWatchlist:
            // SIMKL plan-to-watch as a client-side rail. Zero engine writes; dormant with empty creds.
            // The read-back half of SIMKL: before this the app only ever PUSHED to SIMKL and showed the
            // user nothing back.
            if !simklRails.items.isEmpty {
                ExternalWatchlistRow(eyebrow: String(localized: "From SIMKL"),
                                     title: String(localized: "SIMKL Watchlist"),
                                     items: simklRails.items, focusModel: focusModel)
            }
        case .mediaServers:
            // "Recently added on <server>": client-side rails from the user's own Plex/Jellyfin/Emby servers.
            ForEach(mediaServerRails.rails) { rail in
                StreamingRow(title: rail.title, items: rail.items, focusModel: focusModel)
            }
        case .importedLists:
            // Imported lists (Integrations -> Import a list): each imported public list paints as its own row.
            ForEach(imported.catalogs) { catalog in
                if !catalog.isEmpty {
                    StreamingRow(title: catalog.title, items: catalog.previews, focusModel: focusModel)
                }
            }
        case .upcomingEpisodes:
            // "Upcoming Episodes": next-airing episode of each library series within 45 days, soonest first.
            if !releaseCalendar.upcoming.isEmpty {
                UpcomingEpisodesRow(items: releaseCalendar.upcoming, focusModel: focusModel)
            }
        case .upcomingMovies:
            // "Upcoming Movies": library movies with a future release date in the next 45 days.
            if !releaseCalendar.upcomingMovies.isEmpty {
                upcomingMoviesSection
            }
        case .addonCatalogs:
            // Each add-on catalog as a rail (or poster-wall). Per-catalog order/hiding is owned by
            // CatalogPreferences; this section moves the whole block. Vertical pagination stays attached.
            ForEach(core.boardRows) { row in
                boardSection(row)
            }
        case .editorialCollections:
            // No editorial rails on tvOS (iOS-only); never in tvDefaultOrder, so this never renders.
            EmptyView()
        }
    }

    /// "Upcoming Movies" rail (extracted from the body so the section switch stays small).
    private var upcomingMoviesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(eyebrow: String(localized: "Coming soon"), title: String(localized: "Upcoming Movies"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(releaseCalendar.upcomingMovies) { m in
                        PosterCard(title: m.name, poster: m.poster, type: "movie", id: m.id, menu: .catalog,
                                   onFocus: { focusModel.focus(FocusedHero(id: m.id, type: "movie", title: m.name,
                                                                           backdrop: m.poster, metaLine: m.releaseDateLabel,
                                                                           overview: nil, genreLine: nil)) })
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.lg)
            }
        }
    }

    /// One engine board catalog section (rail or poster-wall), with the vertical board-widening trigger on
    /// the LAST populated section. Unchanged from the previous inline `ForEach(core.boardRows)` body; see the
    /// long note there (kept below) for why the `.onAppear` sits at the section level for both layouts.
    @ViewBuilder
    private func boardSection(_ row: CoreBoardRow) -> some View {
        Group {
            if catalogPrefs.homeLayout == .wall {
                CoreCatalogWallSection(row: row, focusModel: focusModel)
            } else {
                CoreCatalogRowView(row: row, focusModel: focusModel)
            }
        }
        // Vertical board widening (mirrors iOS Home): when the LAST populated board section appears, load the
        // next window of Home catalogs. At the SECTION level so it fires in BOTH the rail and wall layouts;
        // repeats are gated inside CoreBridge.loadBoardNextPage (boardHasNextPage + boardPageInFlight).
        .onAppear {
            if row.id == core.boardRows.last(where: { !$0.items.isEmpty })?.id {
                core.loadBoardNextPage()
            }
        }
    }

    /// The brand lockup: serif "Vort" + the gold vortex mark as the "X" (the mark follows the theme accent),
    /// plus a trailing "Customize Home" action that opens the rows manage screen.
    private var header: some View {
        HStack(spacing: 0) {
            VortXWordmark(fontSize: 42)
            Spacer()
            Button { showCustomize = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .accessibilityLabel(Text("Customize Home"))
        }
        .padding(.horizontal, Theme.Space.screenEdge)
    }
}

/// The HOME featured-hero trailer driver (#44): plays the focused catalog item's MUTED FULL trailer behind
/// the hero art, but only once focus has SETTLED on that item for ~3s. The 3s debounce is the whole point:
/// scrolling catalog-to-catalog must never fire a ytdl request, so the timer is re-armed on every focus
/// change and only the item the user actually lands on resolves a trailer. The trailer is torn down the
/// instant focus moves (the URL clears, which unmounts `TVInHeroTrailerView`), so the embedded server is
/// hit at most once per settled item, never on every rotation.
///
/// YouTube trailers resolve to the native `{serverBase}/yt/{id}` full-trailer resolver (the SAME path the
/// Trailer button plays; `StremioServer.trailerResolverBase` picks the in-process route on full builds and
/// the public `trailer.vortx.tv/yt` resolver on Lite, so Lite plays hero trailers too). The retired R2
/// `/clip` snippet is gone (owner directive). A resolve miss 404s into the player's still-backdrop fallback.
@MainActor final class HomeHeroTrailerModel: ObservableObject {
    /// The settled item's resolved trailer URL, or nil while debouncing / when no trailer exists. Mounting
    /// `TVInHeroTrailerView` on this means clearing it tears the libmpv layer down at once.
    @Published private(set) var url: URL?

    /// Seconds focus must rest on one item before its trailer loads, so flicking past catalogs never loads.
    private static let settleDelay: Duration = .seconds(3)

    private var pending: Task<Void, Never>?
    private var currentItemID: String?
    /// Base URLs of the user's meta-serving add-ons (set by HomeView via `configureMetaSources`), walked to
    /// resolve the focused item's meta the same way `FocusedItemModel` enriches the backdrop.
    private var metaSourceBases: [String] = []

    func configureMetaSources(transportUrls: [String]) {
        metaSourceBases = transportUrls.map { url in
            url.hasSuffix("manifest.json") ? String(url.dropLast("manifest.json".count)) : url
        }
    }

    /// Focus settled on (or moved to) an item. Tear down any current trailer immediately, then arm the 3s
    /// settle timer; if focus moves again before it fires the timer is cancelled, so no request is made.
    /// `hero == nil` (focus left the rails) just tears down.
    func focusChanged(to hero: FocusedHero?) {
        guard hero?.id != currentItemID else { return }
        currentItemID = hero?.id
        pending?.cancel()
        // Tear the previous trailer down the moment focus leaves it.
        if url != nil { url = nil }
        guard let hero else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            await self?.resolveTrailer(for: hero)
        }
    }

    /// Settled for the full delay: resolve the focused item's trailer to a playable URL (preferring a direct
    /// stream, else the embedded server's `/yt` redirect) and publish it. Only applies if focus is still on
    /// this item, so a late network reply for a since-abandoned item never paints.
    private func resolveTrailer(for hero: FocusedHero) async {
        guard let request = await fetchTrailer(for: hero), let playable = request.playableURL else { return }
        // yt-direct: try the DEVICE-DIRECT stream first (resolved on the user's own IP). The hero clip is
        // MUTED, so a video-only adaptive pick needs no audio sidecar; a miss keeps the /yt worker URL.
        // A direct (non-YouTube) trailer stream already IS `playable`, so only YouTube ids resolve here.
        var chosen = playable
        if request.directURL == nil, let yt = request.youTubeID, !yt.isEmpty,
           let resolved = await YouTubeDirectResolver.resolve(videoID: yt, maxHeight: 1080) {
            chosen = resolved.videoURL
            NSLog("[yt-direct] tvOS home ambient: %@ h=%d", resolved.isMuxed ? "direct-muxed" : "direct-pair", resolved.height)
        } else if request.directURL == nil {
            NSLog("[yt-direct] tvOS home ambient: fallback-worker")
        }
        guard currentItemID == hero.id, !Task.isCancelled else { return }
        url = chosen
    }

    /// Walk Cinemeta (for tt ids) + every installed meta add-on for this item's meta, building a
    /// `TrailerRequest` from the first response that carries a trailer. Mirrors `FocusedItemModel`'s
    /// enrichment fetch (short timeout, cache-first), so it is cheap and never blocks.
    private func fetchTrailer(for hero: FocusedHero) async -> TrailerRequest? {
        var bases = metaSourceBases
        if hero.id.hasPrefix("tt") { bases.insert("https://v3-cinemeta.strem.io/", at: 0) }
        let candidates = bases.compactMap { URL(string: "\($0)meta/\(hero.type)/\(hero.id).json") }
        let imdbID = hero.id.hasPrefix("tt") ? hero.id : nil
        for url in candidates {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.cachePolicy = .returnCacheDataElseLoad
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(TrailerMetaResponse.self, from: data),
                  let meta = decoded.meta else { continue }
            if var trailer = meta.trailerRequest(title: hero.title) {
                // Attach the hero's id / type / year for any downstream keying; the ambient in-hero clip now
                // plays the meta's own YouTube trailer through the `/yt` native resolver (via `playableURL` ->
                // `nativeFullTrailerURL`), the SAME path the full Trailer button uses. The retired R2 `/clip`
                // pool no longer factors in, so a trailer with no direct stream and no YouTube id resolves to
                // nil and the still backdrop stays (fail-soft).
                trailer.imdbID = imdbID
                trailer.mediaType = hero.type
                trailer.year = meta.year
                return trailer
            }
        }
        // No add-on-listed trailer (or no meta at all, e.g. a hub title Cinemeta doesn't know): with the R2
        // `/clip` pool retired there is no id-only ambient source, so `playableURL` would resolve to nil and
        // the hero keeps its still backdrop + Ken Burns. Return nil rather than a trailer-less request.
        return nil
    }
}

/// The add-on meta response, narrowed to the trailer fields (parity with `TrailerRequest.from(meta:)` over
/// the same shape the engine decodes into `CoreMetaItem`).
private struct TrailerMetaResponse: Decodable {
    struct Stream: Decodable { let ytId: String?; let url: String? }
    struct Link: Decodable { let name: String; let category: String; let url: String? }
    struct Meta: Decodable {
        let trailerStreams: [Stream]?
        let links: [Link]?
        let releaseInfo: String?

        /// 4-digit release year from releaseInfo ("2024", "2024-2025", "2024-"): the /clip resolver's
        /// title+year disambiguator for heroes without an imdb id. Nil when not parseable.
        var year: String? {
            let yr = (releaseInfo?.prefix(4)).map(String.init)
            return (yr?.count == 4 && yr?.allSatisfy(\.isNumber) == true) ? yr : nil
        }

        /// Build a `TrailerRequest`: prefer a direct (non-YouTube) trailer stream, else a YouTube id from
        /// `trailerStreams` or a "Trailer" link. Nil when neither exists (so the still art stays).
        func trailerRequest(title: String) -> TrailerRequest? {
            let direct = (trailerStreams ?? [])
                .compactMap { $0.ytId == nil ? $0.url : nil }
                .compactMap { URL(string: $0) }
                .first
            let yt = (trailerStreams ?? []).compactMap(\.ytId).first { !$0.isEmpty }
                ?? (links ?? []).first { $0.category.caseInsensitiveCompare("Trailer") == .orderedSame }?
                    .url.flatMap(CoreMetaItem.youTubeID(from:))
            guard direct != nil || yt != nil else { return nil }
            return TrailerRequest(title: title, youTubeID: yt, directURL: direct)
        }
    }
    let meta: Meta?
}

/// Eyebrow kicker + section title, the shared header for every rail.
struct RailHeader: View {
    var eyebrow: String? = nil
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let eyebrow { Text(eyebrow).eyebrowStyle() }
            Text(title).sectionTitleStyle()
        }
        .padding(.horizontal, Theme.Space.screenEdge)
    }
}

/// The BIG header for a nested collection GROUP (Streaming / Genres / Top New / New): reuses `RailHeader`'s
/// eyebrow + title styling but a visual tier UP — the screen-title font with an accent rule beneath — so a
/// group reads as a section ABOVE its child rails, distinct from an individual rail's `RailHeader`.
struct GroupHeader: View {
    var eyebrow: String? = nil
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let eyebrow { Text(eyebrow).eyebrowStyle(Theme.Palette.accent) }
            Text(title).screenTitleStyle()
            Rectangle()
                .fill(Theme.Palette.accent)
                .frame(width: 64, height: 4)
                .clipShape(Capsule())
        }
        .padding(.horizontal, Theme.Space.screenEdge)
        .padding(.top, Theme.Space.md)
    }
}

/// One nested collection group on tvOS: a `GroupHeader` over its child rails. Each child rail reuses the
/// existing `StreamingRow` (MetaPreview -> PosterCard -> DetailView routing + the focused-card backdrop),
/// so a grouped rail behaves identically to the flat streaming/editorial rails. A group with no rails is
/// never built (see `HomeGroupsModel`), so this always has content.
struct CollectionGroupSection: View {
    let group: CollectionGroup
    var focusModel: FocusedItemModel? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            GroupHeader(eyebrow: group.eyebrow, title: group.title)
            ForEach(group.rails) { rail in
                StreamingRow(title: rail.title, items: rail.items, focusModel: focusModel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Target for opening a full detail page from a Continue Watching card's long-press menu.
struct CWDetailTarget: Identifiable, Hashable { let id: String; let type: String }

/// "Continue Watching" rail from the engine (`continue_watching_preview`), newest first, with a
/// resume-progress stripe on each poster.
struct CoreContinueWatchingRow: View {
    let items: [CoreCWItem]
    var focusModel: FocusedItemModel? = nil
    var menu: PosterMenu = .continueWatching   // .none on overlay-profile rails (engine menu doesn't apply)
    @EnvironmentObject private var theme: ThemeManager   // observe so the rail's cards repaint on a theme change
    @EnvironmentObject private var presenter: PlayerPresenter
    @EnvironmentObject private var profiles: ProfileStore
    @State private var detailTarget: CWDetailTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(eyebrow: String(localized: "Pick up where you left off"), title: String(localized: "Continue Watching"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(items) { item in
                        PosterCard(title: item.name, poster: item.poster,
                                   type: item.type, id: item.id, progress: item.progress,
                                   resumeSeconds: item.resumeSeconds,
                                   menu: menu,
                                   onFocus: focusModel.map { model in
                                       { model.focus(item.focusedHero) }
                                   },
                                   directPlay: directResume(item),
                                   onDetails: { detailTarget = CWDetailTarget(id: item.id, type: item.type) })
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)   // room for the focus halo
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationDestination(item: $detailTarget) { DetailView(type: $0.type, id: $0.id) }
    }

    /// Continue Watching resumes the exact link that was playing last time, straight
    /// into the player, instead of routing through the detail page and re-resolving
    /// sources. Falls back to the detail page when no remembered link fits: never
    /// played here, or the engine moved the series on to a different episode.
    private func directResume(_ item: CoreCWItem) -> (() -> Void)? {
        let pid = profiles.activeID
        guard let entry = LastStreamStore.entry(for: item.id, profileID: pid) else {
            LastStreamStore.logResume("noEntry", libraryId: item.id, profileID: pid); return nil
        }
        guard URL(string: entry.url) != nil else {   // validity gate; CWResume re-parses entry.url itself
            LastStreamStore.logResume("badURL", libraryId: item.id, profileID: pid); return nil
        }
        if PlaybackSettings.torrentsDisabled && entry.torrent == true {
            LastStreamStore.logResume("torrentDisabled", libraryId: item.id, profileID: pid); return nil
        }
        let hasEpisodicPhysicalIdentity = EpisodePlaybackIdentity.isEpisodicContext(
            type: entry.type, season: entry.season, episode: entry.episode,
            videoID: entry.videoId
        )
        let usesSeriesLifecycle = EpisodePlaybackIdentity.usesSeriesLifecycle(type: entry.type)
        if hasEpisodicPhysicalIdentity, let cwVideo = item.state.videoId, cwVideo != entry.videoId {
            LastStreamStore.logResume("episodeMoved:\(cwVideo)|\(entry.videoId)", libraryId: item.id, profileID: pid); return nil
        }
        LastStreamStore.logResume("hit", libraryId: item.id, profileID: pid)
        return {
            let meta = PlaybackMeta(libraryId: item.id, videoId: entry.videoId, type: entry.type,
                                    name: entry.name, poster: entry.poster,
                                    season: entry.season, episode: entry.episode)
            // Reresolve the EXACT stored source FIRST (same debrid file, fresh link), so the card tap resumes
            // the source the user chose instead of replaying a stale, expired URL and dead-ending into the
            // cross-source auto-pick ("Tried N sources / this source didn't load"). CWResume mints a fresh
            // link for the SAME file when the entry carries debrid provenance; a non-debrid entry returns the
            // stored url unchanged (refreshed == false), so those paths are byte-identical to before.
            // Seed the community pool with the FULL assembled source groups this resume produces. A card resume
            // never opens the detail view, so the detail-view hoard never runs for it; the resume kicks a
            // background loadMeta (below, on every branch) that fills streamGroups, and this polls for that then
            // fires the same full-group hoard the detail view uses. The older single-source hoard no-op'd for
            // debrid/direct resumes (the common case), so those playbacks seeded nothing. Fire-and-forget,
            // deduped per content, gated inside SourceIndexClient (consent + fleet flag). No-op when the library
            // id is not a real imdb id or no groups assemble.
            if let cid = SourceIndexClient.contentID(imdbId: item.id, season: entry.season, episode: entry.episode) {
                let streamId = entry.videoId
                Task.detached {
                    await SourceIndexClient.hoardResumedGroups(contentID: cid) {
                        CoreBridge.shared.streamGroups(forStreamId: streamId)
                    }
                }
            }
            Task { @MainActor in
                let hashShort = (entry.infoHash?.prefix(8)).map(String.init) ?? "-"
                let (resolvedURL, refreshed) = await CWResume.resolvedURL(for: entry)
                let bridge = CoreBridge.shared   // this row has no `core` env-object; use the shared engine bridge
                if hasEpisodicPhysicalIdentity, entry.torrent == true,
                   entry.fileIdx == nil, !refreshed {
                    LastStreamStore.logResume(
                        "episodeTorrentMissingFileIdx", libraryId: item.id, profileID: pid
                    )
                    return
                }
                if refreshed, let service = entry.debridService.flatMap(DebridService.init(rawValue:)),
                   let hash = entry.infoHash, !hash.isEmpty {
                    // Fresh link for the SAME source: play it as an EXPLICIT pick (no silent hop) so the resume
                    // honors the user's chosen source, exactly as a manual source-row tap would. Carry the debrid
                    // provenance so the play-record re-stores it and the NEXT resume can reresolve again.
                    NSLog("[cw-probe] tv directResume: svc=%@ hash=%@ fileIdx=%@ reresolve=FRESH path=exact-source", service.rawValue, hashShort, entry.fileIdx.map(String.init) ?? "-")
                    let requestType = usesSeriesLifecycle ? "series" : entry.type
                    bridge.loadMeta(type: requestType, id: item.id,
                                    streamType: requestType, streamId: entry.videoId)
                    let eps = await prefetchEpisodes(bridge, itemID: item.id,
                                                     usesSeriesLifecycle: usesSeriesLifecycle)
                    let groups = bridge.streamGroups(forStreamId: entry.videoId)
                    let source = resumeSource(entry: entry, url: resolvedURL, groups: groups,
                                              forceDirect: true)
                    let engineVideoID = source.flatMap {
                        bindResumeEngine(bridge, source: $0, entry: entry,
                                         hasEpisodicPhysicalIdentity: hasEpisodicPhysicalIdentity,
                                         groups: groups, resolvedURL: resolvedURL)
                    }
                    let ref = DebridPlaybackRef(url: resolvedURL, service: service, infoHash: hash,
                                                torrentId: entry.debridTorrentId, fileId: entry.debridFileId,
                                                fileIdx: entry.fileIdx)
                    presenter.request = PlaybackRequest(
                        url: resolvedURL, title: entry.title, meta: meta, episodes: eps,
                        sourceHint: entry.qualityText, torrent: false,
                        bingeGroup: entry.bingeGroup, headers: entry.headers,
                        debridRef: ref, sourceStream: source,
                        enginePlayerVideoId: engineVideoID,
                        wasExplicitPick: true, wasResume: true)
                    return
                }
                // No fresh link (non-debrid entry, or the source is genuinely gone): replay the stored url as
                // before. Kick off a background load of the title's streams so a stale stored link auto-hops to a
                // FRESH source instead of dead-ending; the stored link still plays immediately. This runs for
                // BOTH movie and series so every resume branch assembles the title's stream groups, which also
                // gives the resume-path community hoard (above) the groups it polls for (series was previously
                // left unloaded here, so a series fallback resume seeded nothing).
                NSLog("[cw-probe] tv directResume: svc=%@ hash=%@ fileIdx=%@ reresolve=NIL path=fallback-stored-url", entry.debridService ?? "-", hashShort, entry.fileIdx.map(String.init) ?? "-")
                if bridge.metaDetails?.meta?.id != item.id
                    || bridge.streamGroups(forStreamId: entry.videoId).isEmpty
                    || (usesSeriesLifecycle && (bridge.metaDetails?.meta?.videos?.isEmpty ?? true)) {
                    let requestType = usesSeriesLifecycle ? "series" : entry.type
                    bridge.loadMeta(type: requestType, id: item.id,
                                    streamType: requestType, streamId: entry.videoId)
                }
                let eps = await prefetchEpisodes(bridge, itemID: item.id,
                                                 usesSeriesLifecycle: usesSeriesLifecycle)
                let groups = bridge.streamGroups(forStreamId: entry.videoId)
                let source = resumeSource(entry: entry, url: resolvedURL, groups: groups)
                let engineVideoID = source.flatMap {
                    bindResumeEngine(bridge, source: $0, entry: entry,
                                     hasEpisodicPhysicalIdentity: hasEpisodicPhysicalIdentity,
                                     groups: groups, resolvedURL: nil)
                }
                if let source { tvPrimeTorrentStream(source) }
                presenter.request = PlaybackRequest(
                    url: resolvedURL, title: entry.title, meta: meta,
                    episodes: eps, sourceHint: entry.qualityText, torrent: entry.torrent ?? false,
                    headers: entry.headers, sourceStream: source,
                    enginePlayerVideoId: engineVideoID, wasResume: true)
            }
        }
    }

    private func resumeSource(entry: LastStreamStore.Entry, url: URL,
                              groups: [CoreStreamSourceGroup], forceDirect: Bool = false) -> CoreStream? {
        let streams = groups.flatMap(\.streams)
        if let hash = entry.infoHash {
            let matches = streams.filter {
                $0.infoHash?.caseInsensitiveCompare(hash) == .orderedSame
            }
            if let fileIdx = entry.fileIdx,
               let exact = matches.first(where: { $0.fileIdx == fileIdx }) { return exact }
        }
        if let direct = streams.first(where: { $0.url == entry.url || $0.url == url.absoluteString }) {
            return direct
        }
        var json: [String: Any] = ["name": entry.title]
        if forceDirect || entry.torrent != true {
            json["url"] = url.absoluteString
        } else if let hash = entry.infoHash, let fileIdx = entry.fileIdx, fileIdx >= 0 {
            json["infoHash"] = hash
            json["fileIdx"] = fileIdx
        } else {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(CoreStream.self, from: data)
    }

    private func bindResumeEngine(_ bridge: CoreBridge, source: CoreStream,
                                  entry: LastStreamStore.Entry,
                                  hasEpisodicPhysicalIdentity: Bool,
                                  groups: [CoreStreamSourceGroup], resolvedURL: URL?) -> String? {
        guard hasEpisodicPhysicalIdentity else {
            bridge.loadEnginePlayer(for: source)
            return nil
        }
        let rawBase = groups.first(where: { $0.streams.contains(source) })?.id
        let base = rawBase.flatMap { URL(string: $0)?.scheme == nil ? nil : $0 }
        let succeeded = bridge.loadEnginePlayer(
            for: source, videoId: entry.videoId, base: base, resolvedURL: resolvedURL
        )
        return EpisodePlaybackIdentity.boundVideoID(
            requestedVideoID: entry.videoId, bindingSucceeded: succeeded
        )
    }

    /// Direct-resume episode prefetch (mirrors iOSRootView's CW-resume prefetch): hand the player its
    /// episode list BEFORE it mounts so auto-advance never depends on the in-player backfill race.
    /// Bounded ~1.5s; a miss returns [] and playback starts exactly as today (the player's own loader
    /// plus the EOF last-chance retry remain the backstop). The raw unsorted videos are byte-equivalent
    /// to what the in-player backfill sets (loadedEpisodes = vids), the proven 0.3.11 behavior.
    @MainActor
    private func prefetchEpisodes(_ bridge: CoreBridge, itemID: String,
                                  usesSeriesLifecycle: Bool) async -> [CoreVideo] {
        guard usesSeriesLifecycle else { return [] }
        for _ in 0 ..< 6 {
            if let meta = bridge.metaDetails?.meta, meta.id == itemID,
               let vids = meta.videos, !vids.isEmpty { return vids }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return []
    }
}

/// One engine catalog row from the board (all installed-addon catalogs).
struct CoreCatalogRowView: View {
    let row: CoreBoardRow
    var focusModel: FocusedItemModel? = nil
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var core: CoreBridge   // for per-row horizontal pagination (#95)
    // Watched check + dim on catalog covers (#111): one shared per-profile id set, O(1) per card.
    @ObservedObject private var watchedIndex = WatchedIndex.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(title: row.title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(row.items) { item in
                        PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                                   isWatched: watchedIndex.ids.contains(item.id),
                                   menu: .catalog,
                                   onFocus: focusModel.map { model in
                                       { model.focus(item.focusedHero) }
                                   })
                            // #95: horizontal infinite scroll. The last card asks the engine for this
                            // catalog's next page, so a Home row keeps loading instead of capping at ~20.
                            .onAppear { if item.id == row.items.last?.id { core.loadBoardRowNextPage(engineIndex: row.engineIndex) } }
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)   // room for the focus halo
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One engine catalog section in the POSTER-WALL Home layout (#105): the same `RailHeader` (so the
/// localized title + any eyebrow treatment survive the mode switch) over a vertical `LazyVGrid` of the
/// row's items, instead of `CoreCatalogRowView`'s horizontal rail. Column math is SHARED with
/// `TVCategoryBrowse` through `TVGridMetrics` (#104): FIXED cells with the card told its EXACT cell
/// width, so cards can never overlap their neighbours regardless of the user's width preset; 4 landscape
/// / 7 portrait per row, the densest grid already proven safe against edge clipping on the TV.
/// Compositor-cheap by construction: `LazyVGrid` only materializes cells near the viewport, and
/// `PosterCard` is reused unchanged (no extra shadows). Each wall's grid is a `.focusSection()`; see the
/// comment on that modifier below for why grids get one while rails deliberately do not.
struct CoreCatalogWallSection: View {
    let row: CoreBoardRow
    var focusModel: FocusedItemModel? = nil
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var core: CoreBridge   // for per-catalog pagination (#95), same as the rail
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared

    /// Cell widths and counts come from `TVGridMetrics` (SharedUI.swift), the single source shared with
    /// `TVCategoryBrowse` so the wall and the browse grid can never drift apart; see its doc comment for
    /// the #104 footprint math and the 145 cell-vs-card overlap regression.
    private var columns: [GridItem] {
        catalogPrefs.landscapeCards && apiKeys.hasTMDB
            ? Array(repeating: GridItem(.fixed(TVGridMetrics.landscapeCellWidth), spacing: Theme.Space.lg), count: TVGridMetrics.landscapeColumns)
            : Array(repeating: GridItem(.fixed(TVGridMetrics.posterCellWidth), spacing: Theme.Space.lg), count: TVGridMetrics.posterColumns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(title: row.title)
            LazyVGrid(columns: columns, spacing: Theme.Space.xl) {
                ForEach(row.items) { item in
                    PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                               width: TVGridMetrics.posterCellWidth, landscapeWidth: TVGridMetrics.landscapeCellWidth,
                               menu: .catalog,
                               onFocus: focusModel.map { model in
                                   { model.focus(item.focusedHero) }
                               })
                        // #95 pagination, wall form: the SAME trailing-item trigger as the rail. LazyVGrid
                        // materializes cells as D-pad focus scrolls the section toward its end, so the last
                        // card's onAppear asks the engine for this catalog's next page and the section grows
                        // in place (no-op while in flight / once exhausted, gated inside CoreBridge).
                        .onAppear { if item.id == row.items.last?.id { core.loadBoardRowNextPage(engineIndex: row.engineIndex) } }
                }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.vertical, Theme.Space.lg)   // room for the focus halo, matching the rail
            // FOCUS: this MULTI-ROW grid is deliberately a focus section, and that is NOT the same case as
            // the hub rails. The BrowseGridView hub lesson (see `section(title:eyebrow:)` there) applies to
            // stacked 1-ROW rails: giving each single row its own focus section made tvOS route D-pad moves
            // by REGION heuristics and skip rows, so rails carry NO focusSection. A multi-row LazyVGrid is
            // the opposite shape: Apple's guidance is to bound the grid in `.focusSection()` so vertical
            // moves inside the wall stay tile-to-tile and the UP/DOWN hand-off at the grid's edges lands on
            // the neighbouring section predictably instead of a far-away nearest-neighbour hit. The only
            // pre-existing LazyVGrid screens (TVCategoryBrowse, LibraryView) live alone on their screens and
            // never needed this; a wall section is the first grid STACKED against other focusable sections.
            // Do not strip this as "inconsistent with the rails": rails without, grids with, is the intent.
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Top Picks for you": local recommendations seeded from the active profile's recent watch history
/// (see `TopPicksModel`). Mirrors `CoreCatalogRowView`, but its items are `MetaPreview`s from the
/// recommender, so it builds a lightweight `FocusedHero` (metahub backdrop) for the living backdrop.
struct TopPicksRow: View {
    let items: [MetaPreview]
    var focusModel: FocusedItemModel? = nil
    @EnvironmentObject private var theme: ThemeManager
    // Watched check + dim on catalog covers (#111): one shared per-profile id set, O(1) per card.
    @ObservedObject private var watchedIndex = WatchedIndex.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(eyebrow: String(localized: "Based on what you watch"), title: String(localized: "Top Picks for you"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(items) { item in
                        PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                                   isWatched: watchedIndex.ids.contains(item.id),
                                   menu: .catalog,
                                   onFocus: focusModel.map { model in
                                       { model.focus(hero(for: item)) }
                                   })
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)   // room for the focus halo
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A bare hero for the backdrop; the FocusedItemModel enriches it (rating/synopsis/real backdrop)
    /// from the session cache or Cinemeta a beat after focus, exactly like a library card.
    private func hero(for item: MetaPreview) -> FocusedHero {
        FocusedHero(id: item.id, type: item.type, title: item.name,
                    backdrop: item.poster, metaLine: item.type.capitalized,
                    overview: nil, genreLine: nil)
    }
}

/// An external service's watchlist as a Home rail (Trakt's watchlist, SIMKL's plan-to-watch).
/// Structurally identical to `TopPicksRow` (MetaPreview cards that open the normal detail page by imdb
/// id); only the header differs, so the header is a PARAMETER rather than the reason to fork this view
/// per service. Zero engine writes.
struct ExternalWatchlistRow: View {
    let eyebrow: String
    let title: String
    let items: [MetaPreview]
    var focusModel: FocusedItemModel? = nil
    @ObservedObject private var watchedIndex = WatchedIndex.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(eyebrow: eyebrow, title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(items) { item in
                        PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                                   isWatched: watchedIndex.ids.contains(item.id),
                                   menu: .catalog,
                                   onFocus: focusModel.map { model in
                                       { model.focus(FocusedHero(id: item.id, type: item.type, title: item.name,
                                                                 backdrop: item.poster, metaLine: item.type.capitalized,
                                                                 overview: nil, genreLine: nil)) }
                                   })
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A "browse by streaming service" Home rail (Netflix, Disney+, ...): titles available on the service
/// in-region, from TMDB watch providers. Mirrors `TopPicksRow`; cards carry resolved Cinemeta (tt) ids so
/// they play through the engine like any catalog card. The service name is the rail title.
struct StreamingRow: View {
    let title: String
    let items: [MetaPreview]
    var focusModel: FocusedItemModel? = nil
    @EnvironmentObject private var theme: ThemeManager
    // Watched check + dim on catalog covers (#111): one shared per-profile id set, O(1) per card.
    @ObservedObject private var watchedIndex = WatchedIndex.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(eyebrow: String(localized: "Streaming now"), title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(items) { item in
                        PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                                   isWatched: watchedIndex.ids.contains(item.id),
                                   menu: .catalog,
                                   onFocus: focusModel.map { model in
                                       { model.focus(hero(for: item)) }
                                   })
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)   // room for the focus halo
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A bare hero for the backdrop; the FocusedItemModel enriches it (rating/synopsis/real backdrop) from
    /// the session cache or Cinemeta a beat after focus, exactly like a Top Picks card.
    private func hero(for item: MetaPreview) -> FocusedHero {
        FocusedHero(id: item.id, type: item.type, title: item.name,
                    backdrop: item.poster, metaLine: item.type.capitalized,
                    overview: nil, genreLine: nil)
    }
}

/// "Upcoming Episodes": the next-airing episode of each series in the library within the next 45 days,
/// soonest first (see `ReleaseCalendarModel`). Mirrors `TopPicksRow`/`StreamingRow` — each card is the
/// series' `PosterCard` (so it routes to the series `DetailView` like any catalog card and resolves its
/// poster through `PosterArtwork`), with a small "S2E5 · Jun 30" caption under it. Series-only.
struct UpcomingEpisodesRow: View {
    let items: [ReleaseCalendarModel.UpcomingEpisode]
    var focusModel: FocusedItemModel? = nil
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared

    /// Match `PosterCard`'s landscape-vs-portrait width so the per-card caption lines up under the card.
    /// Portrait cards follow the user's Poster Style width preset (#105), same mapping as `PosterCard.cardWidth`.
    private var captionWidth: CGFloat {
        (catalogPrefs.landscapeCards && apiKeys.hasTMDB) ? kLandscapeCardWidth : catalogPrefs.posterWidth.tvWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(eyebrow: String(localized: "Coming soon"), title: String(localized: "Upcoming Episodes"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            PosterCard(title: item.seriesName, poster: item.video.thumbnail,
                                       type: "series", id: item.seriesId,
                                       menu: .catalog,
                                       onFocus: focusModel.map { model in
                                           { model.focus(hero(for: item)) }
                                       })
                            // The episode + air date for THIS card (the series name is the poster title).
                            Text("\(item.episodeLabel) · \(item.airDateLabel)")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(1)
                                .frame(width: captionWidth, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)   // room for the focus halo
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A bare hero for the backdrop; the FocusedItemModel enriches it from the session cache or Cinemeta a
    /// beat after focus, exactly like a Top Picks card.
    private func hero(for item: ReleaseCalendarModel.UpcomingEpisode) -> FocusedHero {
        FocusedHero(id: item.seriesId, type: "series", title: item.seriesName,
                    backdrop: item.video.thumbnail, metaLine: "Series",
                    overview: nil, genreLine: nil)
    }
}

/// Skeleton rail shown while the engine is still loading (signed in). Calmer than a spinner.
struct LoadingRail: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(title: String(localized: "Loading your library"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.Space.lg) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .fill(Theme.Palette.surface1)
                            .frame(width: kPosterWidth, height: kPosterWidth * 1.5)
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)   // room for the focus halo
            }
        }
    }
}

/// tvOS manage screen to reorder + hide the Home rows. No drag on tvOS, so each row carries Up / Down and a
/// Show/Hide toggle (the same pattern as `TVReorderServicesView`), each row its own `.focusSection()`. Writes
/// straight to `HomeRailPreferences`, so the live Home re-lays out on dismiss. Continue Watching is pinned
/// first and is intentionally not listed. Presented as a full-screen cover; the remote's Menu button (or the
/// Done chip) closes it.
struct TVHomeRailEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var prefs = HomeRailPreferences.shared
    private let defaults = HomeRail.tvDefaultOrder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .center) {
                    Text("Customize Home").screenTitleStyle()
                    Spacer()
                    Button { dismiss() } label: { Text("Done") }
                        .buttonStyle(ChipButtonStyle(selected: false))
                }
                .padding(.horizontal, Theme.Space.screenEdge)

                Text("Reorder or hide the rows on your Home screen. Continue Watching always stays at the top.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, Theme.Space.screenEdge).padding(.bottom, Theme.Space.sm)

                let rails = prefs.arrange(defaults)
                LazyVStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ForEach(Array(rails.enumerated()), id: \.element.id) { index, rail in
                        row(index: index, rail: rail, count: rails.count)
                    }
                }

                Button { prefs.reset() } label: {
                    Label("Reset to default", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                .padding(.horizontal, Theme.Space.screenEdge).padding(.top, Theme.Space.md)
            }
            .padding(.vertical, Theme.Space.lg)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onExitCommand { dismiss() }   // remote Menu button closes the cover
    }

    private func row(index: Int, rail: HomeRail, count: Int) -> some View {
        let hidden = prefs.isHidden(rail)
        return HStack(spacing: Theme.Space.md) {
            Text("\(index + 1)").font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.Palette.textTertiary).frame(width: 44)
            Image(systemName: rail.systemImage)
                .foregroundStyle(hidden ? Theme.Palette.textTertiary : Theme.Palette.accent)
            Text(rail.title).font(.system(size: 22, weight: .medium))
                .foregroundStyle(hidden ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
            Spacer()
            Button { prefs.setHidden(rail, !hidden) } label: {
                Label(hidden ? "Hidden" : "Shown", systemImage: hidden ? "eye.slash" : "eye")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            Button { prefs.moveUp(rail, defaults: defaults) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(ChipButtonStyle(selected: false)).disabled(index == 0)
            Button { prefs.moveDown(rail, defaults: defaults) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(ChipButtonStyle(selected: false)).disabled(index == count - 1)
        }
        .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.sm)
        .focusSection()
    }
}
