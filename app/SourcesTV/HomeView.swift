import SwiftUI

/// Native tvOS Home, driven by the **stremio-core** engine (via `CoreBridge`): a "Continue Watching"
/// rail plus every catalog of every installed addon, on the StremioX design system (Theme.swift).
struct HomeView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var profiles: ProfileStore
    @StateObject private var focusModel = FocusedItemModel()
    @StateObject private var topPicks = TopPicksModel()   // local recommendations from this profile's history
    @StateObject private var releaseCalendar = ReleaseCalendarModel()   // "Upcoming Episodes" from the series library (next 45 days)
    @ObservedObject private var collectionsHub = CollectionsHubModel.shared   // Collections hub (shared singleton): Discover cards + Streaming-service tiles + Genre tiles
    @AppStorage("vortx.home.showCollectionsHub") private var showCollectionsHub = true   // toggle the hub on Home (needs a TMDB key)
    @StateObject private var heroTrailer = HomeHeroTrailerModel()   // #44: focus-settled muted hero trailer
    @AppStorage("stremiox.autoplayTrailers") private var autoplayTrailers = true
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
        NavigationStack {
            ZStack {
                // The living backdrop: whichever poster is focused fills the screen with its
                // artwork and details. Pure presentation, never focusable, so pressing up from
                // the rails lands straight on the tab bar.
                // detailsBottom = strip height (470) + a breathing gap, so the synopsis can never
                // run into the rail header regardless of tab-bar safe-area shifts.
                BrowseHeroBackdrop(model: focusModel, detailsBottom: 520)
                    // #44: once focus SETTLES on a catalog item for ~3s, its muted FULL trailer fades in
                    // behind the hero art (over the still backdrop, under the rails + details). Gated on
                    // the same autoplay-trailers setting + reduce-motion as the detail hero, and keyed on
                    // the resolved URL so a focus change (which clears it) tears the libmpv layer down.
                    // Non-focusable + no hit-testing inside the view, so the focus engine is untouched.
                    .overlay {
                        // Also gated by the RemoteConfig fleet kill-switch `features.trailers`: a remote
                        // `false` force-disables ambient hero trailers fleet-wide (e.g. if the trailer worker
                        // is degraded). Baked default true => absent/null remote is identical to shipping; the
                        // user's "Auto-play trailers" setting still governs.
                        if autoplayTrailers, RemoteConfig.snapshot.isFeatureOn("trailers", default: true),
                           !reduceMotion, let url = heroTrailer.url {
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
                            CoreContinueWatchingRow(items: continueWatching, focusModel: focusModel)
                        }
                        // Collections hub (Discover cards, Streaming-service tiles, Genre tiles), right after
                        // Continue Watching per the owner's row order. Each tile opens a sub-catalog browse grid.
                        // Needs a TMDB key; hidden without one. Replaces the old flat streaming rails + nested groups.
                        if showCollectionsHub, CollectionsHubModel.isAvailable {
                            TVCollectionsHub(model: collectionsHub)
                        }
                        // Local recommendations seeded from this profile's recent watch history (#0.3.9).
                        // Hidden when there's no TMDB key, no history to seed from, or no results.
                        if !topPicks.items.isEmpty {
                            TopPicksRow(items: topPicks.items, focusModel: focusModel)
                        }
                        // "Upcoming Episodes": the next-airing episode of each series in the library within
                        // the next 45 days, soonest first (see ReleaseCalendarModel). Hidden when there is
                        // nothing upcoming, so the default (no dated episodes) renders nothing.
                        if !releaseCalendar.upcoming.isEmpty {
                            UpcomingEpisodesRow(items: releaseCalendar.upcoming, focusModel: focusModel)
                        }
                        // "Upcoming Movies": library movies with a future release date in the next 45 days,
                        // soonest first; hidden when nothing is upcoming. Each card routes to the movie DetailView.
                        if !releaseCalendar.upcomingMovies.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.Space.md) {
                                RailHeader(eyebrow: "Coming soon", title: "Upcoming Movies")
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
                        ForEach(core.boardRows) { row in
                            CoreCatalogRowView(row: row, focusModel: focusModel)
                        }
                        if continueWatching.isEmpty && core.boardRows.isEmpty {
                            if account.isSignedIn { LoadingRail() } else { CoreEmptyState.signedOut }
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
        }
        .onAppear { configureMetaSources(); seed(); refreshTopPicks(); refreshReleaseCalendar(); if showCollectionsHub { collectionsHub.load() } }
        .onChange(of: showCollectionsHub) { show in if show { collectionsHub.load() } else { collectionsHub.clear() } }
        .onChange(of: core.boardRows.first?.id) { seed() }
        .onChange(of: core.continueWatching.first?.id) { seed(); refreshTopPicks() }
        .onChange(of: profiles.activeID) { seed(); refreshTopPicks() }
        // Rebuild "Upcoming Episodes" when the library changes (a new follow) or the meta add-ons hydrate
        // — the same two inputs the model sweeps over. The bases come from `account.addons`, which loads
        // async after sign-in, so key on its count too (matching the notification sweep's input set).
        .onChange(of: core.library?.catalog.count ?? 0) { refreshReleaseCalendar() }
        .onChange(of: account.addons.count) { refreshReleaseCalendar() }
        .onChange(of: core.addons.count) { configureMetaSources(); refreshReleaseCalendar() }
        // Drive the focus-settled hero trailer (#44): every hero change re-arms the 3s debounce and tears
        // down the current trailer, so scrolling catalog-to-catalog never loads a clip.
        .onChange(of: focusModel.hero?.id) { heroTrailer.focusChanged(to: focusModel.hero) }
    }

    /// Recompute the "Top Picks for you" rail from the profile-aware Continue Watching + library.
    /// The model no-ops when the seed set is unchanged, so this is cheap to call on every re-emit.
    private func refreshTopPicks() {
        topPicks.refresh(profileID: profiles.activeID, cw: continueWatching, library: libraryItems)
    }

    /// Recompute "Upcoming Episodes" from the series library + the installed meta add-on bases — derived
    /// EXACTLY like the new-episode notification sweep (series-typed library ids + names, `providesMeta`
    /// add-on base URLs). The model no-ops when the series set is unchanged, so this is cheap to re-call.
    private func refreshReleaseCalendar() {
        let catalog = core.library?.catalog ?? []
        let bases = account.addons.filter { $0.providesMeta }.map(\.baseUrl)
        let series = catalog.filter { $0.type == "series" }
        let names = Dictionary(series.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        releaseCalendar.refresh(seriesIDs: series.map(\.id), seriesNames: names, metaBases: bases)
        let movies = catalog.filter { $0.type == "movie" }
        let movieNames = Dictionary(movies.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let moviePosters = Dictionary(movies.compactMap { m in m.poster.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
        releaseCalendar.refreshMovies(movieIDs: movies.map(\.id), movieNames: movieNames, moviePosters: moviePosters, metaBases: bases)
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
    }

    /// The brand lockup: serif "Vort" + the gold vortex mark as the "X" (the mark follows the theme accent).
    private var header: some View {
        HStack(spacing: 0) {
            VortXWordmark(fontSize: 42)
            Spacer()
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
            RailHeader(eyebrow: "Pick up where you left off", title: "Continue Watching")
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
        guard let url = URL(string: entry.url) else {
            LastStreamStore.logResume("badURL", libraryId: item.id, profileID: pid); return nil
        }
        if PlaybackSettings.torrentsDisabled && entry.torrent == true {
            LastStreamStore.logResume("torrentDisabled", libraryId: item.id, profileID: pid); return nil
        }
        if item.type == "series", let cwVideo = item.state.videoId, cwVideo != entry.videoId {
            LastStreamStore.logResume("episodeMoved:\(cwVideo)|\(entry.videoId)", libraryId: item.id, profileID: pid); return nil
        }
        LastStreamStore.logResume("hit", libraryId: item.id, profileID: pid)
        return {
            // For a MOVIE, kick off a background load of the title's streams so a stale stored link (debrid
            // URLs are time-limited and expire between sessions) auto-hops to a FRESH source instead of
            // dead-ending on the "sources didn't load" overlay. The stored link still plays immediately; the
            // player's failover picks up the fresh streams on a failure.
            let bridge = CoreBridge.shared   // this row has no `core` env-object; use the shared engine bridge
            if entry.type == "movie",
               bridge.metaDetails?.meta?.id != item.id || bridge.streamGroups(forStreamId: entry.videoId).isEmpty {
                bridge.loadMeta(type: "movie", id: item.id, streamType: "movie", streamId: entry.videoId)
            }
            presenter.request = PlaybackRequest(
                url: url, title: entry.title,
                meta: PlaybackMeta(libraryId: item.id, videoId: entry.videoId, type: entry.type,
                                   name: entry.name, poster: entry.poster,
                                   season: entry.season, episode: entry.episode),
                episodes: [], sourceHint: entry.qualityText, torrent: entry.torrent ?? false,
                headers: entry.headers)
        }
    }
}

/// One engine catalog row from the board (all installed-addon catalogs).
struct CoreCatalogRowView: View {
    let row: CoreBoardRow
    var focusModel: FocusedItemModel? = nil
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var core: CoreBridge   // for per-row horizontal pagination (#95)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(title: row.title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(row.items) { item in
                        PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
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

/// "Top Picks for you": local recommendations seeded from the active profile's recent watch history
/// (see `TopPicksModel`). Mirrors `CoreCatalogRowView`, but its items are `MetaPreview`s from the
/// recommender, so it builds a lightweight `FocusedHero` (metahub backdrop) for the living backdrop.
struct TopPicksRow: View {
    let items: [MetaPreview]
    var focusModel: FocusedItemModel? = nil
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(eyebrow: "Based on what you watch", title: "Top Picks for you")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(items) { item in
                        PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
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

/// A "browse by streaming service" Home rail (Netflix, Disney+, ...): titles available on the service
/// in-region, from TMDB watch providers. Mirrors `TopPicksRow`; cards carry resolved Cinemeta (tt) ids so
/// they play through the engine like any catalog card. The service name is the rail title.
struct StreamingRow: View {
    let title: String
    let items: [MetaPreview]
    var focusModel: FocusedItemModel? = nil
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(eyebrow: "Streaming now", title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(items) { item in
                        PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
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
    private var captionWidth: CGFloat {
        (catalogPrefs.landscapeCards && apiKeys.hasTMDB) ? kLandscapeCardWidth : kPosterWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(eyebrow: "Coming soon", title: "Upcoming Episodes")
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
            RailHeader(title: "Loading your library")
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
