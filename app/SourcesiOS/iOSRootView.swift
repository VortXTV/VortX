import SwiftUI

/// Native iOS root: a CUSTOM bottom-tab shell over the shared engine. A native `TabView` collapses
/// the 5th+ tabs into a system "More" tab on iPhone, burying Add-ons and Settings; instead we drive
/// the visible screen with a `@State` selection and render our own brand-styled bar so all SEVEN tabs
/// stay visible at once (matching the tvOS pill bar). Surfaces are filled in one at a time during the
/// 0.3.0 rebase; Home is the first real one (poster rails from CoreBridge).
struct iOSRootView: View {
    /// The seven destinations, in display order: Home · Discover · Live · Library · Search · Add-ons
    /// · Settings (Live sits after Discover; Add-ons beside Settings, mirroring tvOS).
    private enum Tab: Int, CaseIterable {
        case home, discover, live, library, search, addons, settings

        var title: String {
            switch self {
            case .home: return "Home"
            case .discover: return "Discover"
            case .live: return "Live"
            case .library: return "Library"
            case .search: return "Search"
            case .addons: return "Add-ons"
            case .settings: return "Settings"
            }
        }

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .discover: return "safari.fill"
            case .live: return "dot.radiowaves.left.and.right"
            case .library: return "books.vertical.fill"
            case .search: return "magnifyingglass"
            case .addons: return "puzzlepiece.extension.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    @State private var tab: Tab = .home

    var body: some View {
        VStack(spacing: 0) {
            // Selected screen fills the space above the bar. We keep all six in a ZStack so each
            // screen's own state (scroll position, search query, engine subscriptions) survives a
            // tab switch instead of being torn down and rebuilt every time.
            ZStack {
                // `isActive` gates each browse screen's `.principal` wordmark: on macOS a principal
                // toolbar item is hoisted into the shared window titlebar, and every mounted
                // NavigationStack would otherwise stamp its own — tiling "StremioX" once per screen.
                // Only the visible tab contributes its wordmark (#46 regression).
                iOSHomeView(isActive: tab == .home).opacity(tab == .home ? 1 : 0)
                iOSDiscoverView(isActive: tab == .discover).opacity(tab == .discover ? 1 : 0)
                iOSLiveView().opacity(tab == .live ? 1 : 0)
                iOSLibraryView(isActive: tab == .library).opacity(tab == .library ? 1 : 0)
                iOSSearchView(isActive: tab == .search).opacity(tab == .search ? 1 : 0)
                AddonsView().opacity(tab == .addons ? 1 : 0)
                iOSSettingsView().opacity(tab == .settings ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            customTabBar
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .tint(Theme.Palette.accent)
    }

    /// Brand-styled bottom bar: seven equal items, each a small SF Symbol over a caption label. The
    /// selected item is tinted with the app accent; the rest read as tertiary text. A hairline +
    /// surface fill separates it from the content, and it respects the safe-area bottom inset.
    private var customTabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.rawValue) { item in
                tabButton(item)
            }
        }
        .padding(.top, Theme.Space.xs)
        .background(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.Palette.hairline)
                    .frame(height: 0.5)
                Theme.Palette.surface1
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func tabButton(_ item: Tab) -> some View {
        let selected = tab == item
        return Button {
            tab = item
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 22)
                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Home: Continue Watching + each installed catalog as a horizontal poster rail, from the shared
/// engine, under the interactive featured hero. Signed-out shows a sign-in prompt; the rails populate
/// as the engine hydrates.
struct iOSHomeView: View {
    /// True only when this is the visible tab — gates the macOS window-titlebar wordmark (#46).
    var isActive: Bool = true
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSignIn = false
    @StateObject private var hero = FeaturedHeroModel()
    @State private var path: [FeaturedHeroItem] = []
    /// A Continue-Watching card's direct resume launches the player straight from Home (#11).
    @State private var player: iOSPlayerLaunch?

    /// All Home rail items in display order (Continue Watching first, then catalog rows), as
    /// `RailItem`s carrying the catalog preview fields so the hero seeds richly. CW entries also
    /// carry their in-progress `video_id` so a direct resume can confirm the remembered link
    /// still matches the episode the engine is parked on.
    private var continueWatchingItems: [RailItem] {
        core.continueWatching.map {
            RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: $0.progress,
                     cwVideoId: $0.state.videoId)
        }
    }

    /// The hero's rotation pool: the first ~2-3 of Continue Watching, then the first items of the top
    /// catalog row, capped by the model. These are the titles a Home visitor sees first.
    private var heroCandidates: [FeaturedHeroItem] {
        var items: [FeaturedHeroItem] = core.continueWatching.prefix(3).map(FeaturedHeroItem.from(cw:))
        if let row = core.boardRows.first(where: { !$0.items.isEmpty }) {
            items += row.items.prefix(3).map(FeaturedHeroItem.from(meta:))
        }
        return items
    }

    var body: some View {
        NavigationStack(path: $path) {
            // The hero is the first scrolling element (an ambient billboard header), not a
            // behind-the-scroll backdrop: that keeps its Play / Trailer buttons + the tappable poster
            // cards reachable (a ScrollView layered over a hero would otherwise eat the hero's taps).
            // Its bottom fades cleanly into canvas with a small gap before the first rail (#52) — the
            // old negative-overlap tuck made the hero bleed into Continue Watching.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                    FeaturedHeroView(model: hero, onOpen: { path.append($0) })
                    if !continueWatchingItems.isEmpty {
                        // A CW card tap resumes the exact last-played stream straight into the player
                        // (#11), falling back to opening detail when no remembered link fits. Long-press
                        // offers the engine's "Remove from Continue Watching" (#14).
                        PosterRail(title: "Continue Watching", items: continueWatchingItems,
                                   onTap: handleContinueWatchingTap, menu: .continueWatching)
                    }
                    ForEach(core.boardRows) { row in
                        if !row.items.isEmpty {
                            PosterRail(title: row.title,
                                       items: row.items.map {
                                           RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                    poster: $0.poster, progress: 0,
                                                    background: $0.background, description: $0.description,
                                                    releaseInfo: $0.releaseInfo, imdbRating: $0.imdbRating,
                                                    genres: $0.genres)
                                       },
                                       onTap: handleTap)
                        }
                    }
                    if core.boardRows.isEmpty && core.continueWatching.isEmpty {
                        emptyState
                    }
                }
                .padding(.bottom, Theme.Space.md)
            }
            // A scroll gesture quiets the ambient hero rotation (resumes after inactivity) — the
            // billboard never yanks the page while the user is browsing (#53).
            .scrollDismissesHeroRotation(model: hero)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .stremioWordmarkTitle("Home", isActive: isActive)
            .toolbar {
                if !account.isSignedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Sign In") { showSignIn = true }
                    }
                }
            }
            .sheet(isPresented: $showSignIn) { iOSSignInView() }
            .navigationDestination(for: FeaturedHeroItem.self) { item in
                iOSDetailView(id: item.id, type: item.type, title: item.name)
            }
            .iOSPlayerCover($player, account: account)
        }
        // Reseed the pool as content arrives; the model ignores no-op reseeds so rotation isn't reset
        // by routine engine re-emits.
        .onAppear {
            // Populate the board on appear (mirrors Discover/Library) so the default Cinemeta catalogs
            // fill Home even when SIGNED OUT — the landing screen shows a real backdrop hero + rails
            // instead of a bare empty state. The Sign In button stays in the toolbar. Guarded on empty
            // so a signed-in session (board already loaded at bootstrap) isn't re-fetched.
            if core.boardRows.isEmpty { core.loadBoard() }
            FeaturedHeroModel.configureMetaSources(core.addons)
            hero.seed(heroCandidates, reduceMotion: reduceMotion)
        }
        .onChange(of: core.revision) { _ in hero.seed(heroCandidates, reduceMotion: reduceMotion) }
        .onDisappear { hero.stop() }
    }

    /// Tapping a poster opens that title's detail through normal navigation — it does NOT "feature" it
    /// in the hero. The hero is a decoupled ambient billboard (#53); the only side effect of a tap is
    /// quieting its rotation for a beat.
    private func handleTap(_ item: RailItem) {
        hero.noteInteraction()
        path.append(FeaturedHeroItem.from(rail: item))
    }

    /// Continue-Watching one-tap direct resume (#11): play the exact last-played stream straight away
    /// when one is remembered for this title/episode; otherwise fall back to opening the detail page so
    /// the user picks a source. (Direct resume needs a remembered link, which the player records as it
    /// plays; the first watch from the detail page seeds it.)
    private func handleContinueWatchingTap(_ item: RailItem) {
        hero.noteInteraction()
        // Computing the resume offset may await the account, so resolve the direct-resume launch in a
        // Task; fall back to opening detail when no remembered link fits.
        Task {
            if let launch = await iOSDirectResume(for: item, core: core, account: account) {
                player = launch
            } else {
                path.append(FeaturedHeroItem.from(rail: item))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: account.isSignedIn ? "popcorn" : "person.crop.circle")
                .font(.system(size: 52)).foregroundStyle(Theme.Palette.textSecondary)
            Text(account.isSignedIn ? "Loading your catalogs…" : "Sign in to load your add-ons and library.")
                .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            if !account.isSignedIn {
                Button("Sign In") { showSignIn = true }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 80).padding(.horizontal, Theme.Space.xl)
    }
}

/// Library: the user's saved titles from the engine, as a poster grid, under the interactive featured
/// hero. Refreshes as the library changes; reloads while empty since it syncs asynchronously after
/// sign-in.
struct iOSLibraryView: View {
    /// True only when this is the visible tab — gates the macOS window-titlebar wordmark (#46).
    var isActive: Bool = true
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hero = FeaturedHeroModel()
    @State private var path: [FeaturedHeroItem] = []

    private var libraryItems: [RailItem] {
        (core.library?.catalog ?? []).map {
            RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: $0.progress)
        }
    }

    /// The hero pool: the first few saved titles. Library entries carry no backdrop field, so (like
    /// tvOS) the hero derives 16:9 art from metahub for IMDB ids and enriches the rest in the background.
    private var heroCandidates: [FeaturedHeroItem] {
        (core.library?.catalog ?? []).prefix(5).map(FeaturedHeroItem.from(cw:))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if let lib = core.library, !lib.catalog.isEmpty {
                    // Hero is an ambient billboard scroll-header above the grid (shown only when there
                    // are saved titles), so its Play / Trailer buttons stay tappable. Type + sort
                    // filter chip rows (#15) sit between the hero and the grid, mirroring the Discover
                    // chips and the tvOS Library filters; long-press on a card offers the engine's
                    // library actions (#14). A clean gap separates the hero from the chips (#52).
                    // LazyVStack (not VStack): the nested horizontal filter-chip ScrollView would let a
                    // plain VStack adopt the chips' wider-than-screen content width and shift the whole
                    // column left/clipped (the beta7 "weird viewport"). Greedy-width LazyVStack pins it
                    // to the viewport, matching Home. See the iOSDiscoverView note for the full rationale.
                    LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                        FeaturedHeroView(model: hero, onOpen: { path.append($0) })
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            filterChips(lib.selectable)
                            PosterGrid(items: libraryItems, onTap: handleTap, menu: .library)
                        }
                    }
                    .padding(.bottom, Theme.Space.md)
                } else {
                    ContentUnavailableViewCompat(title: "Library", systemImage: "books.vertical",
                        message: "Titles you add to your library in Stremio show up here.")
                        .frame(minHeight: 420)
                }
            }
            .scrollDismissesHeroRotation(model: hero)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .stremioWordmarkTitle("Library", isActive: isActive)
            .navigationDestination(for: FeaturedHeroItem.self) { item in
                iOSDetailView(id: item.id, type: item.type, title: item.name)
            }
            .onAppear { if core.library?.catalog.isEmpty != false { core.loadLibrary() } }
        }
        .onAppear {
            FeaturedHeroModel.configureMetaSources(core.addons)
            hero.seed(heroCandidates, reduceMotion: reduceMotion)
        }
        .onChange(of: core.revision) { _ in hero.seed(heroCandidates, reduceMotion: reduceMotion) }
        .onDisappear { hero.stop() }
    }

    /// Tapping a card opens its detail (decoupled hero, #53); it only quiets the billboard rotation.
    private func handleTap(_ item: RailItem) {
        hero.noteInteraction()
        path.append(FeaturedHeroItem.from(rail: item))
    }

    /// Type + sort chip rows (#15), mirroring the tvOS `LibraryView.filters`: each chip carries the
    /// engine's own `request` and dispatches it back via `core.selectLibrary` on tap. The library
    /// re-emits and the grid + hero refresh on their own.
    @ViewBuilder private func filterChips(_ selectable: CoreLibrarySelectable) -> some View {
        chipScroll { ForEach(selectable.types) { t in
            chip(t.label, t.selected) { core.selectLibrary(t.request) } } }
        chipScroll { ForEach(selectable.sorts) { s in
            chip(s.label, s.selected) { core.selectLibrary(s.request) } } }
    }

    private func chipScroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) { content() }
                .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.xs)
        }
    }

    private func chip(_ label: String, _ selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).lineLimit(1).font(Theme.Typography.label)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
                .background(selected ? Theme.Palette.accent : Theme.Palette.surface2, in: Capsule())
                .foregroundStyle(selected ? .white : Theme.Palette.textSecondary)
        }
        .buttonStyle(.plain)
    }
}

/// Search across every installed add-on, on the engine (debounced). Mirrors the tvOS `SearchView`:
/// results are grouped into Movies / Series / Other rail sections (#16) rather than one flat grid, a
/// "Play a link or magnet" entry sits at the top (the touch/Mac `OpenLinkView`), search suggestions
/// feed `.searchSuggestions`, and the empty / "No results" state is gated at ≥2 characters (the
/// engine's `CoreBridge.search` hard-gates at 2 chars, so a single-char query would otherwise read as
/// a misleading empty state).
struct iOSSearchView: View {
    /// True only when this is the visible tab — gates the macOS window-titlebar wordmark (#46).
    var isActive: Bool = true
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var searchDebouncePending = false
    @State private var path: [FeaturedHeroItem] = []
    @State private var showOpenLink = false
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    // Stremio's "paste a link" feature, at the top like tvOS.
                    Button { showOpenLink = true } label: {
                        Label(directLinksOnly ? "Play a direct link" : "Play a link or magnet", systemImage: "link")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .padding(.horizontal, Theme.Space.md)

                    results
                }
                .padding(.vertical, Theme.Space.md)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .stremioWordmarkTitle("Search", isActive: isActive)
            .navigationDestination(for: FeaturedHeroItem.self) { item in
                iOSDetailView(id: item.id, type: item.type, title: item.name)
            }
            .searchable(text: $query, prompt: "Movies or series")
            .searchSuggestions {
                ForEach(suggestionTitles, id: \.self) { title in
                    Text(title).searchCompletion(title)
                }
            }
            .onSubmit(of: .search) {
                searchTask?.cancel()
                searchDebouncePending = false
                core.suggestSearch(query)
                core.search(query)
            }
            .onAppear { core.loadSearchSuggestions() }
            .onChange(of: query) { value in scheduleSearch(value) }   // iOS 16 single-param onChange
            .onDisappear { searchTask?.cancel() }
            .sheet(isPresented: $showOpenLink) { iOSOpenLinkView() }
        }
    }

    /// Below ≥2 chars the engine never searches, so the page reads as "start typing"; once the query
    /// is long enough it groups the results into rail sections, falling back to a loading / no-results
    /// line. Gating at ≥2 chars stops a single-char query showing a misleading "No results".
    @ViewBuilder private var results: some View {
        if !hasSearchQuery {
            ContentUnavailableViewCompat(title: "Search", systemImage: "magnifyingglass",
                message: "Search across everything your add-ons cover.").frame(minHeight: 360)
        } else if core.searchResults.isEmpty {
            ContentUnavailableViewCompat(
                title: isWaitingForCurrentQuery ? "Searching…" : "No results",
                systemImage: "magnifyingglass",
                message: isWaitingForCurrentQuery ? "" : "Nothing matched what you typed.")
                .frame(minHeight: 360)
        } else {
            // Search has no hero; cards tap straight through to detail and long-press offers the
            // catalog actions (#14).
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                ForEach(resultSections, id: \.title) { section in
                    PosterRail(title: section.title,
                               items: section.items.map {
                                   RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0)
                               },
                               onTap: { path.append(FeaturedHeroItem.from(rail: $0)) },
                               menu: .catalog)
                }
            }
        }
    }

    /// Group results into Movies / Series / Other, dropping empty sections — the tvOS `resultSections`.
    private var resultSections: [(title: String, items: [CoreMeta])] {
        let movies = core.searchResults.filter { $0.type == "movie" }
        let series = core.searchResults.filter { $0.type == "series" }
        let other = core.searchResults.filter { $0.type != "series" && $0.type != "movie" }
        return [("Movies", movies), ("Series", series), ("Other", other)].filter { !$0.items.isEmpty }
    }

    /// Autocomplete titles for `.searchSuggestions`, from the engine's LocalSearch index plus any
    /// loaded result / Continue-Watching / board titles that substring-match — the tvOS approach.
    private var suggestionTitles: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var seen = Set<String>()

        let coreSuggestions = core.searchSuggestions.map(\.name).filter { title in
            guard title.caseInsensitiveCompare(trimmed) != .orderedSame else { return false }
            return seen.insert(title).inserted
        }
        let localTitles = core.searchResults.map(\.name)
            + core.continueWatching.map(\.name)
            + core.boardRows.flatMap { $0.items.map(\.name) }
        let localMatches = localTitles.filter { title in
            guard title.caseInsensitiveCompare(trimmed) != .orderedSame else { return false }
            guard title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                return false
            }
            return seen.insert(title).inserted
        }
        return Array((coreSuggestions + localMatches).prefix(10))
    }

    private var hasSearchQuery: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    private var isWaitingForCurrentQuery: Bool {
        hasSearchQuery && (searchDebouncePending || core.searchIsLoading)
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        let q = value.trimmingCharacters(in: .whitespaces)
        searchDebouncePending = q.count >= 2
        guard !q.isEmpty else { searchDebouncePending = false; core.search(""); return }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            core.suggestSearch(q)
            core.search(q)
            searchDebouncePending = false
        }
    }
}

/// Discover, driven by the stremio-core engine (CatalogWithFilters): type, catalog, and genre
/// chips carrying the engine's own request, dispatched back on tap, over a poster grid — under the
/// interactive featured hero (shown once a catalog has loaded).
struct iOSDiscoverView: View {
    /// True only when this is the visible tab — gates the macOS window-titlebar wordmark (#46).
    var isActive: Bool = true
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hero = FeaturedHeroModel()
    @State private var path: [FeaturedHeroItem] = []

    /// The hero pool: the first few items of the currently selected catalog. Catalog metas carry their
    /// own `background` + preview fields, so the hero is rich immediately and enriches for logo/trailer.
    private var heroCandidates: [FeaturedHeroItem] {
        (core.discover?.items.prefix(5).map(FeaturedHeroItem.from(meta:))) ?? []
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // LazyVStack (not VStack): a vertical ScrollView proposes the viewport width, but a
                // plain VStack sizes to its WIDEST child — and the nested horizontal chip ScrollViews
                // below let it adopt their (wider-than-screen) content width, pushing the whole column
                // off-axis so the hero + chips + grid render shifted-left and clipped on both edges
                // (the intermittent beta7 "weird viewport" on Discover/Library). LazyVStack is greedy
                // on the cross axis — it always takes the full viewport width — so it can't overflow.
                // Home already uses LazyVStack and never exhibited the shift.
                LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                    if let discover = core.discover {
                        // Hero is an ambient billboard scroll-header above the chips + grid, shown once
                        // a catalog has loaded; its Play / Trailer buttons stay tappable. It fades
                        // cleanly into the chip rows below — no negative overlap, so the filter pills
                        // no longer ride up into the hero's title/synopsis band (#52, #7).
                        FeaturedHeroView(model: hero, onOpen: { path.append($0) })
                        // The filter rows are their own vertically-stacked band: each chip row gets its
                        // own line with consistent spacing so a row's pills can never be drawn on top
                        // of the row above it (#7).
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            chipScroll { ForEach(discover.selectable.types) { t in
                                chip(t.type.capitalized, t.selected) { core.selectDiscover(t.request) } } }
                            chipScroll { ForEach(discover.selectable.catalogs) { c in
                                chip(c.catalog, c.selected) { core.selectDiscover(c.request) } } }
                            if let genre = discover.selectable.extra.first(where: { $0.name.caseInsensitiveCompare("genre") == .orderedSame }),
                               !genre.options.isEmpty {
                                chipScroll { ForEach(genre.options) { o in
                                    chip(o.label, o.selected) { core.selectDiscover(o.request) } } }
                            }
                        }
                        PosterGrid(items: discover.items.map {
                            RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0,
                                     background: $0.background, description: $0.description,
                                     releaseInfo: $0.releaseInfo, imdbRating: $0.imdbRating, genres: $0.genres)
                        }, onTap: handleTap)
                    } else if account.isSignedIn {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 100)
                    } else {
                        ContentUnavailableViewCompat(title: "Discover", systemImage: "safari",
                            message: "Sign in to browse your add-ons' catalogs.").frame(minHeight: 420)
                    }
                }
                .padding(.top, core.discover != nil ? 0 : Theme.Space.md)
                .padding(.bottom, Theme.Space.md)
            }
            .scrollDismissesHeroRotation(model: hero)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .stremioWordmarkTitle("Discover", isActive: isActive)
            .navigationDestination(for: FeaturedHeroItem.self) { item in
                iOSDetailView(id: item.id, type: item.type, title: item.name)
            }
            .onAppear { if core.discover == nil { core.loadDiscover() } }
        }
        .onAppear {
            FeaturedHeroModel.configureMetaSources(core.addons)
            hero.seed(heroCandidates, reduceMotion: reduceMotion)
        }
        // The grid changes whenever a different type/catalog/genre is selected, which bumps revision —
        // reseed so the hero pool tracks the visible catalog.
        .onChange(of: core.revision) { _ in hero.seed(heroCandidates, reduceMotion: reduceMotion) }
        .onDisappear { hero.stop() }
    }

    /// Tapping a card opens its detail (decoupled hero, #53); it only quiets the billboard rotation.
    private func handleTap(_ item: RailItem) {
        hero.noteInteraction()
        path.append(FeaturedHeroItem.from(rail: item))
    }

    private func chipScroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) { content() }
                .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.xs)
        }
    }

    private func chip(_ label: String, _ selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).lineLimit(1).font(Theme.Typography.label)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
                .background(selected ? Theme.Palette.accent : Theme.Palette.surface2, in: Capsule())
                .foregroundStyle(selected ? .white : Theme.Palette.textSecondary)
        }
        .buttonStyle(.plain)
    }
}

/// One catalog row's tappable poster. Beyond the poster + progress the card needs, it carries the
/// catalog preview fields (`background`, `description`, `releaseInfo`, `imdbRating`, `genres`) so the
/// detail route opened on tap arrives with rich seed data — they're present on `CoreMeta` but were
/// previously dropped at the `.map`. Continue Watching / Library entries lack a `background`, so the
/// hero derives 16:9 art from metahub-by-IMDB-id (see `FeaturedHeroItem.from`).
struct RailItem: Identifiable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let progress: Double
    var background: String? = nil
    var description: String? = nil
    var releaseInfo: String? = nil
    var imdbRating: String? = nil
    var genres: [String]? = nil
    /// The Continue-Watching entry's in-progress video id (`state.video_id`), carried so a
    /// direct resume can confirm the remembered link still matches the episode the engine
    /// is parked on (mirrors the tvOS `directResume` series guard). Nil for catalog/library cards.
    var cwVideoId: String? = nil
}

// MARK: - Poster context menu (#14, ported from tvOS PosterCard.menuItems)

/// Which long-press (context) menu a `PosterCardiOS` shows, mirroring the tvOS `PosterMenu`.
/// `.continueWatching` offers a dismiss; `.catalog` offers add-to-library plus mark watched /
/// unwatched; `.library` swaps add for remove-from-library; `.none` attaches no menu at all. The
/// actions fire straight at the engine (`CoreBridge.shared`); Continue Watching and the catalogs
/// both refresh on their own when the engine re-emits the affected fields.
enum iOSPosterMenu { case none, continueWatching, catalog, library }

// MARK: - Direct resume + paste-a-link playback (#11 / #16, the iOS player launch path)

/// A resolved stream ready to hand to `PlayerScreen`, the value the iOS browse screens pass into
/// `iOSPlayerCover`. Mirrors `iOSDetailView.PlayerLaunch` so the launch path is identical: the same
/// native `PlayerScreen` over the same `platformFullScreenCover`, with progress saved through the
/// account just like the detail page. Used by Continue-Watching direct resume and the paste-a-link
/// flow (both reach playback WITHOUT routing through the detail page / re-resolving sources).
struct iOSPlayerLaunch: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var headers: [String: String]? = nil
    var resume: Double = 0
    /// nil for a paste-a-link play (no library item to record progress against).
    var meta: PlaybackMeta? = nil
    /// Quality signature + torrent flag of the launching stream, re-recorded into LastStreamStore on
    /// playback start so a CW resume refreshes its memory. Carried from the remembered entry on a CW
    /// direct-resume; nil for paste-a-link (which has no `meta`, so nothing is recorded anyway).
    var qualityText: String? = nil
    var isTorrent: Bool = false
}

extension View {
    /// Present `PlayerScreen` for an `iOSPlayerLaunch` over the browse screen, saving progress to
    /// the account (the same wiring `iOSDetailView` uses) when the launch carries a `PlaybackMeta`.
    @ViewBuilder func iOSPlayerCover(_ launch: Binding<iOSPlayerLaunch?>,
                                     account: StremioAccount) -> some View {
        platformFullScreenPlayerCover(item: launch) { item in
            PlayerScreen(
                url: item.url, title: item.title, headers: item.headers, resumeSeconds: item.resume,
                recordMeta: item.meta, recordQualityText: item.qualityText, recordIsTorrent: item.isTorrent,
                onProgress: { pos, dur in
                    guard let meta = item.meta else { return }
                    Task { await account.saveProgress(for: meta, positionSeconds: pos, durationSeconds: dur) }
                },
                onSeek: { pos, dur in
                    guard let meta = item.meta else { return }
                    Task { await account.saveProgress(for: meta, positionSeconds: pos, durationSeconds: dur) }
                },
                onClose: { launch.wrappedValue = nil }
            )
            .ignoresSafeArea()
        }
    }
}

/// Resume the EXACT link a Continue-Watching title last played, straight into the player, instead of
/// routing through the detail page and re-resolving sources — the touch/Mac twin of the tvOS
/// `CoreContinueWatchingRow.directResume`. Returns nil (caller then opens detail) when no remembered
/// link fits: never played on this device, the link is a torrent while torrents are disabled, or the
/// engine moved the series on to a different episode than the one we remembered.
@MainActor
private func iOSDirectResume(for item: RailItem, core: CoreBridge,
                             account: StremioAccount) async -> iOSPlayerLaunch? {
    guard let entry = LastStreamStore.entry(for: item.id, profileID: ProfileStore.shared.activeID),
          let url = URL(string: entry.url) else { return nil }
    if PlaybackSettings.torrentsDisabled && entry.torrent == true { return nil }
    if item.type == "series", let cwVideo = item.cwVideoId, cwVideo != entry.videoId { return nil }
    let meta = PlaybackMeta(libraryId: item.id, videoId: entry.videoId, type: entry.type,
                            name: entry.name, poster: entry.poster,
                            season: entry.season, episode: entry.episode)
    // Resume where the user left off, not 0:00 (#11). The iOS PlayerScreen seeks ONLY to the passed
    // `resume`, so the offset must be computed here — mirroring iOSDetailView.resume(_:):
    // the engine's own offset for engine-history profiles, else the account/overlay offset.
    let resume: Double
    if let engine = core.engineResumeSeconds(for: meta) {
        resume = engine
    } else {
        resume = await account.resumeOffset(for: meta)
    }
    return iOSPlayerLaunch(url: url, title: entry.title, headers: entry.headers,
                           resume: resume, meta: meta,
                           qualityText: entry.qualityText, isTorrent: entry.torrent ?? false)
}

/// Stremio's "paste a link" feature on touch / Mac (#16) — the twin of the tvOS `OpenLinkView`. Plays
/// a direct video URL or a magnet: magnets ride the embedded torrent engine (the `/create` call blocks
/// until the torrent's metadata arrives, then the largest video file plays). The tvOS `OpenLinkView`
/// and its `LinkOpener` live in the tvOS-only target (they depend on `PlayerPresenter`), so this brings
/// its own small parse/resolve built on the shared `TorrentTrackers` + `StremioServer`, and launches
/// the same native `PlayerScreen` the rest of the iOS app uses.
private struct iOSOpenLinkView: View {
    @EnvironmentObject private var account: StremioAccount
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var working = false
    @State private var status: String?
    @State private var player: iOSPlayerLaunch?
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("Play a link")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(directLinksOnly
                 ? "A direct video URL (mp4, mkv, m3u8 and friends), a debrid or usenet link your service resolved to http(s)."
                 : "A direct video URL (mp4, mkv, m3u8 and friends), a debrid or usenet link your service resolved to http(s), or a magnet link.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            TextField(directLinksOnly ? "https://..." : "https://...  or  magnet:?xt=...", text: $input)
                .font(Theme.Typography.body)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: Theme.Space.md) {
                Button(working ? "Working…" : "Play") { play() }
                    .buttonStyle(PrimaryActionStyle())
                    .disabled(working || input.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { dismiss() }
                    .buttonStyle(ChipButtonStyle(selected: false))
            }
            if let status {
                Text(status)
                    .font(Theme.Typography.label)
                    .foregroundStyle(working ? Theme.Palette.textSecondary : Theme.Palette.danger)
            }
            Spacer()
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        // The picked stream plays full-screen over the sheet.
        .iOSPlayerCover($player, account: account)
    }

    private func play() {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("magnet:") {
            guard !PlaybackSettings.torrentsDisabled else {
                status = "Torrenting is disabled. Use a direct or debrid http(s) link."
                return
            }
            guard let magnet = OpenLinkMagnet.parse(text) else {
                status = "That magnet link has no usable info hash."
                return
            }
            playMagnet(magnet)
            return
        }
        // A bare host or path with no scheme is almost always meant as https.
        if !text.contains("://"), text.contains(".") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            status = directLinksOnly
                ? "Not a playable link. Paste a direct http(s) stream link (debrid and usenet links count)."
                : "Not a playable link. Paste a direct http(s) stream link (debrid and usenet links count) or a magnet."
            return
        }
        let title = url.lastPathComponent.isEmpty ? (url.host ?? "Stream") : url.lastPathComponent
        player = iOSPlayerLaunch(url: url, title: title)
    }

    private func playMagnet(_ magnet: OpenLinkMagnet.Magnet) {
        working = true
        status = "Fetching torrent info… this can take up to a minute"
        Task { @MainActor in
            defer { working = false }
            guard let pick = await OpenLinkMagnet.resolve(magnet) else {
                status = "Could not fetch the torrent. No reachable peers, or a dead magnet."
                return
            }
            player = iOSPlayerLaunch(url: pick.url, title: magnet.name ?? pick.fileName)
        }
    }
}

/// Magnet parsing + resolution for the iOS `iOSOpenLinkView`, ported from the tvOS-only `LinkOpener`
/// (which can't be shared because it lives in the tvOS target). Builds on the shared `TorrentTrackers`
/// + `StremioServer`, both compiled into the iOS target.
private enum OpenLinkMagnet {
    struct Magnet { let infoHash: String; let name: String?; let trackers: [String] }

    static func parse(_ text: String) -> Magnet? {
        guard let comps = URLComponents(string: text), comps.scheme?.lowercased() == "magnet" else { return nil }
        var hash: String?
        var name: String?
        var trackers: [String] = []
        for item in comps.queryItems ?? [] {
            switch item.name.lowercased() {
            case "xt":
                guard let value = item.value, value.lowercased().hasPrefix("urn:btih:") else { break }
                let raw = String(value.dropFirst("urn:btih:".count))
                if raw.count == 40, raw.allSatisfy(\.isHexDigit) {
                    hash = raw.lowercased()
                } else if raw.count == 32 {
                    hash = base32ToHex(raw)
                }
            case "dn": name = item.value
            case "tr": if let t = item.value, !t.isEmpty { trackers.append("tracker:\(t)") }
            default: break
            }
        }
        guard let hash else { return nil }
        return Magnet(infoHash: hash, name: name, trackers: trackers)
    }

    /// Ask the embedded engine for the torrent; the create call returns once metadata is in (it needs
    /// at least one peer), with the file list, then pick the biggest video file.
    static func resolve(_ magnet: Magnet) async -> (url: URL, fileName: String)? {
        guard !PlaybackSettings.torrentsDisabled else { return nil }
        let sources = TorrentTrackers.sources(forHash: magnet.infoHash, streamSources: nil,
                                              addonTrackers: magnet.trackers)
        guard let createURL = URL(string: "\(StremioServer.base)/\(magnet.infoHash)/create") else { return nil }
        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 75
        let payload: [String: Any] = [
            "torrent": ["infoHash": magnet.infoHash],
            "peerSearch": ["sources": sources, "min": 40, "max": 150],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        struct CreateResponse: Decodable {
            struct File: Decodable { let name: String?; let length: Double? }
            let files: [File]?
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response = try? JSONDecoder().decode(CreateResponse.self, from: data),
              let files = response.files, !files.isEmpty else { return nil }
        let videoExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "ts", "webm", "wmv", "mpg", "mpeg"]
        let indexed = Array(files.enumerated())
        let videos = indexed.filter { entry in
            let ext = (entry.element.name ?? "").split(separator: ".").last.map { String($0).lowercased() } ?? ""
            return videoExtensions.contains(ext)
        }
        guard let best = (videos.isEmpty ? indexed : videos).max(by: { ($0.element.length ?? 0) < ($1.element.length ?? 0) }),
              let url = URL(string: "\(StremioServer.base)/\(magnet.infoHash)/\(best.offset)") else { return nil }
        return (url, best.element.name ?? "Torrent")
    }

    /// RFC 4648 base32 (the older magnet info-hash encoding) to lowercase hex.
    private static func base32ToHex(_ raw: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for ch in raw.uppercased() {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        guard bytes.count == 20 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// A poster grid (Library, Search, Discover) of tappable cards. Cards are `Button`s wired to an
/// `onTap(item)` router (instead of pushing a `NavigationLink` directly), so the SCREEN decides what a
/// tap means — across all three surfaces it now opens the title's detail (the hero is a decoupled
/// ambient billboard, #53), so there is no featured ring here.
///
/// Centering (#47): the adaptive columns are CENTER-aligned and the grid is constrained to the same
/// row width that gives even, balanced columns — a `.leading`-aligned adaptive grid bunched cards to
/// the left and left a ragged right gutter, which read as "left-aligned". Centering the columns and
/// the trailing remainder keeps the grid even across the width at every breakpoint (iPhone → Mac).
private struct PosterGrid: View {
    let items: [RailItem]
    let onTap: (RailItem) -> Void
    /// Which long-press context menu each card shows on this surface (#14). `.none` for surfaces
    /// where no engine action applies.
    var menu: iOSPosterMenu = .none
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    // Center the adaptive tracks so the cards distribute evenly across the available width instead of
    // packing to the leading edge. Min track matches the 120pt card + a little breathing room.
    private let columns = [GridItem(.adaptive(minimum: 116), spacing: Theme.Space.sm, alignment: .center)]
    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: Theme.Space.md) {
            ForEach(items) { item in
                Button { onTap(item) } label: {
                    PosterCardiOS(id: item.id, name: item.name, poster: item.poster,
                                  progress: item.progress, menu: menu)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Space.md)
    }
}

private struct PosterRail: View {
    let title: String
    let items: [RailItem]
    let onTap: (RailItem) -> Void
    /// Which long-press context menu each card shows on this surface (#14).
    var menu: iOSPosterMenu = .none
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Space.md)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.Space.sm) {
                    ForEach(items) { item in
                        Button { onTap(item) } label: {
                            PosterCardiOS(id: item.id, name: item.name, poster: item.poster,
                                          progress: item.progress, menu: menu)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Space.md)
            }
        }
    }
}

// The old image-only `iOSHeroBackdrop` was replaced by the interactive `FeaturedHeroView`
// (FeaturedHeroView.swift) on all three browse screens; its 16:9-art helpers now live on
// `FeaturedHeroItem`.

private struct PosterCardiOS: View {
    let id: String
    let name: String
    let poster: String?
    let progress: Double
    /// Which long-press menu to attach (#14). `.none` attaches none.
    var menu: iOSPosterMenu = .none
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    var body: some View {
        card.modifier(PosterContextMenu(id: id, menu: menu))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                AsyncImage(url: URL(string: poster ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(2/3, contentMode: .fill)
                    default: Theme.Palette.surface1
                    }
                }
                .frame(width: 120, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                if progress > 0.01 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.4))
                            Rectangle().fill(Theme.Palette.accent).frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                }
            }
            .frame(width: 120, height: 180)
            Text(name)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1).frame(width: 120, alignment: .leading)
        }
    }
}

/// The long-press (`.contextMenu`) actions for a poster, ported from the tvOS `PosterCard.menuItems`.
/// Actions fire straight at the engine (`CoreBridge.shared`), exactly like tvOS; the affected rails
/// (Continue Watching / Library / catalog) refresh on their own when the engine re-emits the changed
/// fields. Only the actions that apply to the card's surface are shown. `.none` attaches no menu, so
/// a plain card on a hero-driven rail keeps its tap-only behaviour.
private struct PosterContextMenu: ViewModifier {
    let id: String
    let menu: iOSPosterMenu

    func body(content: Content) -> some View {
        if menu == .none {
            content
        } else {
            content.contextMenu { items }
        }
    }

    @ViewBuilder private var items: some View {
        switch menu {
        case .none:
            EmptyView()
        case .continueWatching:
            Button(role: .destructive) {
                CoreBridge.shared.removeFromLibrary(id: id)
            } label: {
                Label("Remove from Continue Watching", systemImage: "minus.circle")
            }
        case .catalog:
            Button {
                CoreBridge.shared.addToLibrary(metaId: id)
            } label: {
                Label("Add to Library", systemImage: "plus.circle")
            }
            Button {
                CoreBridge.shared.setCatalogWatched(metaId: id, true)
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
            Button {
                CoreBridge.shared.setCatalogWatched(metaId: id, false)
            } label: {
                Label("Mark as Unwatched", systemImage: "circle")
            }
        case .library:
            Button {
                CoreBridge.shared.setLibraryItemWatched(id: id, true)
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
            Button {
                CoreBridge.shared.setLibraryItemWatched(id: id, false)
            } label: {
                Label("Mark as Unwatched", systemImage: "circle")
            }
            Button(role: .destructive) {
                CoreBridge.shared.removeFromLibrary(id: id)
            } label: {
                Label("Remove from Library", systemImage: "trash")
            }
        }
    }
}

// MARK: - Browse-screen chrome helpers (#46 wordmark, #53 scroll quiets the ambient hero)

extension View {
    /// The accent-tinted brand wordmark in the navigation bar's principal slot — warm-white "Stremio"
    /// with an ember "X", in the serif wordmark face — replacing the plain stock `.navigationTitle`
    /// that fell back to flat white in dark mode (#46). Mirrors the tvOS `HomeView.header` wordmark.
    /// The `pageTitle` is kept only as the bar's inline accessibility identity (and back-button
    /// context); the visible principal item is always the wordmark, applied across Home / Discover /
    /// Library / Search so the brand reads consistently.
    /// `isActive` is the macOS guard: a `.principal` item is hoisted into the shared window titlebar,
    /// and all seven tab screens stay mounted at once (opacity-switched to preserve state), so without
    /// this gate every browse screen stamps its own wordmark and they tile ("StremioX"×4). The
    /// conditional lives *inside* `@ToolbarContentBuilder` — branching the whole view instead would
    /// change the NavigationStack's structural identity and reset its scroll/path on every tab switch.
    func stremioWordmarkTitle(_ pageTitle: String, isActive: Bool = true) -> some View {
        navigationTitle(pageTitle)
            .navigationBarTitleDisplayModeInlineCompat()
            .toolbar {
                if isActive {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 0) {
                            Text("Stremio").foregroundStyle(Theme.Palette.textPrimary)
                            Text("X").foregroundStyle(Theme.Palette.accent)
                        }
                        .font(Theme.Typography.wordmark)
                        // macOS hoists the principal item into the unified titlebar and wraps it in a
                        // system capsule sized to the text's LAYOUT width — but a bold New York (serif)
                        // wordmark's ink overshoots that box (S side-bearing + X/o terminals), so it
                        // spilled past the pill. fixedSize stops the bar squeezing it; the horizontal
                        // padding widens the measured bounds so the capsule clears the serif overhang.
                        .fixedSize()
                        .padding(.horizontal, Theme.Space.xs)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityLabel("StremioX")
                    }
                }
            }
    }

    /// A scroll/drag on a browse screen quiets the ambient hero rotation; the model resumes it after a
    /// spell of inactivity (#53). Implemented as a non-blocking `simultaneousGesture` so it observes
    /// the drag without intercepting the ScrollView's own scrolling.
    func scrollDismissesHeroRotation(model: FeaturedHeroModel) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { _ in model.noteInteraction() }
        )
    }

    /// `.navigationBarTitleDisplayMode(.inline)` is unavailable on macOS; no-op there.
    @ViewBuilder fileprivate func navigationBarTitleDisplayModeInlineCompat() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// Cross-version empty state (ContentUnavailableView is iOS 17+; the deployment target is 16).
private struct ContentUnavailableViewCompat: View {
    let title: String; let systemImage: String; let message: String
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: systemImage).font(.system(size: 48)).foregroundStyle(Theme.Palette.textTertiary)
            Text(title).font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
            Text(message).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}
