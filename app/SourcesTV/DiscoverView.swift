import SwiftUI

/// Discover, driven by the **stremio-core** engine (`CatalogWithFilters`): pick a type, catalog, and
/// genre, see the full grid. Each chip carries the engine's own `request`, dispatched back on tap.
struct DiscoverView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var vortxSync: VortXSyncManager   // VortX-primary front door: a VortX sign-in unlocks the tabs even with no Stremio account connected
    @AppStorage(TabBarPrefs.hideLive) private var hideLiveTab = false   // also hide Live types from the Discover type filter (#117 per-tab key)
    @StateObject private var focusModel = FocusedItemModel()
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared
    @ObservedObject private var collectionsHub = CollectionsHubModel.shared
    @AppStorage("vortx.discover.showCollectionsHub") private var showCollectionsHub = true   // toggle the hub on Discover (needs a TMDB key)
    /// Presents the advanced filter panel (genre / year / age rating / duration / seasons / upcoming).
    @State private var showFilters = false
    /// Below this many matching cards, while more pages exist, auto-load the next page so a strict filter
    /// still fills the grid instead of stranding two or three cards. Bounded: the engine stops handing out
    /// `discoverHasNextPage` at the end of the catalog.
    private let filterFillFloor = 18
    /// Cinematic landscape cards (TMDB key required) are wider, so fewer per row; portrait keeps 6-up.
    private var columns: [GridItem] {
        catalogPrefs.landscapeCards && apiKeys.hasTMDB
            ? Array(repeating: GridItem(.fixed(kLandscapeCardWidth), spacing: Theme.Space.lg), count: 3)
            : Array(repeating: GridItem(.fixed(kPosterWidth), spacing: Theme.Space.lg), count: 6)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // The living backdrop: art owns the screen, details pinned above the strip. The
                // title, chips, and grid all live in the bottom strip and tuck under the hero.
                BrowseHeroBackdrop(model: focusModel, detailsBottom: 520)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        Color.clear.frame(height: 0).scrollToTopAnchor()   // re-select Discover tab -> scroll here
                        titleRow(hasCatalog: core.discover != nil)
                        if showCollectionsHub, CollectionsHubModel.isAvailable {
                            TVCollectionsHub(model: collectionsHub)
                        }
                        if let discover = core.discover {
                            typeChips(discover.selectable.types)
                            catalogChips(discover.selectable.catalogs)
                            genreChips(discover.selectable.extra)
                            results(discover)
                        } else if account.isSignedIn || vortxSync.isSignedIn {
                            BigSpinner()
                                .padding(Theme.Space.xxl).frame(maxWidth: .infinity)
                        } else {
                            CoreEmptyState.signedOut
                        }
                    }
                    .padding(.top, Theme.Space.sm)
                    .padding(.bottom, Theme.Space.xl)
                }
                .heroBottomStrip()
                // Re-selecting the active Discover tab scrolls back to the top.
                .scrollToTopOnBump(TabScrollKeys.discover)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
        .onAppear { if core.discover == nil { core.loadDiscover() }; seed(); if showCollectionsHub { collectionsHub.load() } }
        .onChange(of: core.discover?.items.first?.id) { seed() }
        .onChange(of: showCollectionsHub) { show in if show { collectionsHub.load() } }   // no clear() on toggle-off: render is gated on showCollectionsHub, and clear() blanked the shared hub for Home too
        // Keep the filtered grid full: when a page settles or the filter set changes, pull the next page
        // while too few cards match and more pages exist (loadDiscoverNextPage self-guards duplicate loads).
        .onChange(of: core.discover?.items.count ?? 0) { _ in autoFillFilteredGrid() }
        .onChange(of: catalogPrefs.discoverFilters) { _ in autoFillFilteredGrid() }
        .sheet(isPresented: $showFilters) {
            if let discover = core.discover {
                DiscoverFilterPanel(prefs: catalogPrefs,
                                    genreOptions: genreOptions(discover),
                                    showSeasons: isSeriesContext(discover)) { showFilters = false }
            }
        }
    }

    /// Load another Discover page when an active filter has left the visible grid thin and the catalog still
    /// has pages. No-op with no filters, at the catalog end, or while a page is already loading.
    private func autoFillFilteredGrid() {
        let filters = catalogPrefs.discoverFilters
        guard filters.isActive, let discover = core.discover, core.discoverHasNextPage else { return }
        let shownCount = discover.items.filter { filters.matches($0, currentYear: Self.currentYear) }.count
        if shownCount < filterFillFloor { core.loadDiscoverNextPage() }
    }

    /// Current calendar year, used by the year-window + upcoming-only filters.
    private static let currentYear = Calendar.current.component(.year, from: Date())

    private func seed() {
        focusModel.seedIfEmpty(core.discover?.items.first?.focusedHero)
    }

    private func typeChips(_ types: [CoreSelectableType]) -> some View {
        // With Live TV turned off, hide its content types (tv / channel / events / ...) from the Discover
        // type filter too, so a disabled Live surface leaves no orphan "Channel" pill (owner report).
        let shown = hideLiveTab ? types.filter { !LiveTypes.contains($0.type) } : types
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(shown) { type in
                    Button { core.selectDiscover(type.request) } label: { Text(type.type.capitalized) }
                        .buttonStyle(ChipButtonStyle(selected: type.selected))
                }
            }
            .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs)
        }
    }

    private func catalogChips(_ catalogs: [CoreSelectableCatalog]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(catalogs) { catalog in
                    Button { core.selectDiscover(catalog.request) } label: { Text(catalog.catalog).lineLimit(1) }
                        .buttonStyle(ChipButtonStyle(selected: catalog.selected))
                }
            }
            .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs)
        }
    }

    /// Genre filter chips, only when the selected catalog declares a "genre" extra.
    @ViewBuilder private func genreChips(_ extra: [CoreSelectableExtra]) -> some View {
        if let genre = extra.first(where: { $0.name.caseInsensitiveCompare("genre") == .orderedSame }),
           !genre.options.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(genre.options) { option in
                        Button { core.selectDiscover(option.request) } label: { Text(AddonTerms.localize(option.label)).lineLimit(1) }
                            .buttonStyle(ChipButtonStyle(selected: option.selected))
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs)
            }
        }
    }

    /// The screen title plus the Filters entry (with an active-count badge). The button appears only once a
    /// catalog is loaded, so it can hand the panel the current catalog's genre + type context.
    @ViewBuilder private func titleRow(hasCatalog: Bool) -> some View {
        let filters = catalogPrefs.discoverFilters
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text("Discover").screenTitleStyle()
            Spacer(minLength: Theme.Space.md)
            if hasCatalog {
                Button { showFilters = true } label: {
                    Label(filters.isActive ? "Filters (\(filters.activeCount))" : "Filters",
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(ChipButtonStyle(selected: filters.isActive))
            }
        }
        .padding(.horizontal, Theme.Space.screenEdge)
    }

    /// The results section: a filtered-grid summary + the poster grid. While the first page is still loading
    /// (no items yet) it shows the spinner; once items exist but a filter matches none of them it shows a
    /// clear empty state instead of an endless spinner.
    @ViewBuilder private func results(_ discover: CoreDiscover) -> some View {
        let filters = catalogPrefs.discoverFilters
        let raw = discover.items
        let shown = filters.isActive ? raw.filter { filters.matches($0, currentYear: Self.currentYear) } : raw
        if filters.isActive, !raw.isEmpty {
            filterSummary(shown: shown.count)
        }
        if raw.isEmpty {
            BigSpinner().padding(Theme.Space.xxl).frame(maxWidth: .infinity)
        } else if shown.isEmpty {
            emptyFiltered
        } else {
            gridOf(shown)
        }
    }

    /// A compact "N shown" line with a one-tap Clear, shown only while a filter is active.
    private func filterSummary(shown: Int) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Text("\(shown) shown").font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            Button { catalogPrefs.discoverFilters = .empty } label: { Text("Clear filters") }
                .buttonStyle(ChipButtonStyle(selected: false))
        }
        .padding(.horizontal, Theme.Space.screenEdge)
    }

    private var emptyFiltered: some View {
        VStack(spacing: Theme.Space.md) {
            Text("No results match your filters.").font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            Button { catalogPrefs.discoverFilters = .empty } label: { Text("Clear filters") }
                .buttonStyle(ChipButtonStyle(selected: false))
        }
        .padding(Theme.Space.xxl).frame(maxWidth: .infinity)
    }

    private func gridOf(_ shown: [CoreMeta]) -> some View {
        LazyVGrid(columns: columns, spacing: Theme.Space.xl) {
            ForEach(shown) { item in
                PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                           width: kPosterWidth, landscapeWidth: kLandscapeCardWidth, menu: .catalog,
                           onFocus: { focusModel.focus(item.focusedHero) })
                    // Infinite scroll: load the next catalog page when focus reaches the last VISIBLE card
                    // (same shared engine path the touch grid uses). With a filter on, the last visible card
                    // is the last MATCH; the auto-fill onChange handlers keep paging past a filtered-out tail.
                    .onAppear { if item.id == shown.last?.id { core.loadDiscoverNextPage() } }
            }
        }
        .padding(.horizontal, Theme.Space.screenEdge)
        .padding(.top, Theme.Space.sm)
    }

    // MARK: - Filter option context

    /// The genre labels offered by the filter panel: the engine's declared genre extra options first, then any
    /// genres present in the loaded items, then a curated anime supplement when the catalog is anime. Deduped
    /// case-insensitively, keeping first-seen order so the engine's own vocabulary leads.
    private func genreOptions(_ discover: CoreDiscover) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ g: String) {
            let trimmed = g.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return }
            out.append(trimmed)
        }
        if let extra = discover.selectable.extra.first(where: { $0.name.caseInsensitiveCompare("genre") == .orderedSame }) {
            for opt in extra.options { if let v = opt.value { add(AddonTerms.localize(v)) } }
        }
        for item in discover.items { for g in (item.genres ?? []) { add(g) } }
        if isAnimeContext(discover) { for g in DiscoverFilterOptions.animeGenres { add(g) } }
        return out
    }

    /// Whether the current catalog is anime: an explicit "anime" type, an anime id scheme on the loaded items,
    /// or an "Anime" genre tag. Drives the anime-genre supplement in `genreOptions`.
    private func isAnimeContext(_ discover: CoreDiscover) -> Bool {
        if discover.selectable.types.first(where: { $0.selected })?.type.caseInsensitiveCompare("anime") == .orderedSame { return true }
        let animeSchemes = ["kitsu:", "anilist:", "mal:", "anidb:"]
        if discover.items.prefix(16).contains(where: { m in animeSchemes.contains { m.id.lowercased().hasPrefix($0) } }) { return true }
        return discover.items.prefix(24).contains { ($0.genres ?? []).contains { $0.caseInsensitiveCompare("anime") == .orderedSame } }
    }

    /// Whether to show the season-count section (series / anime catalogs).
    private func isSeriesContext(_ discover: CoreDiscover) -> Bool {
        guard let t = discover.selectable.types.first(where: { $0.selected })?.type.lowercased() else { return false }
        return t == "series" || t == "anime"
    }
}

// MARK: - Filter panel (tvOS)

/// The advanced Discover filter sheet: genre include/exclude (tri-state chips), a release-year window (decade
/// chips read as a range), an upcoming-only switch, age ratings, a runtime window, and a season-count window
/// (series). Every control binds to the shared `CatalogPreferences.discoverFilters`, so a change persists and
/// the grid behind the sheet re-filters live. All chips reuse `ChipButtonStyle`, so the panel matches the rest
/// of Discover at ten feet: neutral glass, ember for included/selected, the danger tint for an excluded genre.
struct DiscoverFilterPanel: View {
    @ObservedObject var prefs: CatalogPreferences
    let genreOptions: [String]
    let showSeasons: Bool
    let onClose: () -> Void

    private var f: DiscoverFilters { prefs.discoverFilters }
    private func update(_ change: (inout DiscoverFilters) -> Void) {
        var next = prefs.discoverFilters
        change(&next)
        prefs.discoverFilters = next
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                headerRow
                if !genreOptions.isEmpty { genreSection }
                yearSection
                ageSection
                durationSection
                if showSeasons { seasonSection }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    // MARK: sections

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text("Filters").screenTitleStyle()
            Spacer(minLength: Theme.Space.md)
            if f.isActive {
                Button { prefs.discoverFilters = .empty } label: { Text("Clear all") }
                    .buttonStyle(ChipButtonStyle(selected: false, accent: Theme.Palette.danger, accentText: Theme.Palette.danger))
            }
            Button { onClose() } label: { Text("Done") }
                .buttonStyle(ChipButtonStyle(selected: true))
        }
    }

    private var genreSection: some View {
        section("Genres", caption: "Tap to include, tap again to exclude.") {
            ForEach(genreOptions, id: \.self) { g in
                let state = f.genreState(g)
                Button { update { $0.cycleGenre(g) } } label: {
                    HStack(spacing: 6) {
                        Text(g).lineLimit(1)
                        if state == .include { Image(systemName: "plus") }
                        else if state == .exclude { Image(systemName: "minus") }
                    }
                }
                .buttonStyle(ChipButtonStyle(
                    selected: state != .off,
                    accent: state == .exclude ? Theme.Palette.danger : Theme.Palette.accent,
                    accentText: state == .exclude ? Theme.Palette.danger : Theme.Palette.accent))
            }
        }
    }

    private var yearSection: some View {
        section("Release years", caption: "Pick a decade, or two to span a range. Upcoming keeps this year and later.") {
            ForEach(DiscoverFilterOptions.decades) { d in
                Button { toggleDecade(d) } label: { Text(d.label) }
                    .buttonStyle(ChipButtonStyle(selected: selectedDecades.contains(d.id)))
            }
            Button { update { $0.upcomingOnly.toggle() } } label: {
                Label("Upcoming only", systemImage: "clock")
            }
            .buttonStyle(ChipButtonStyle(selected: f.upcomingOnly))
        }
    }

    private var ageSection: some View {
        section("Age rating", caption: nil) {
            ForEach(DiscoverFilterOptions.ageRatings, id: \.self) { r in
                Button {
                    update { if $0.ageRatings.contains(r) { $0.ageRatings.remove(r) } else { $0.ageRatings.insert(r) } }
                } label: { Text(r) }
                    .buttonStyle(ChipButtonStyle(selected: f.ageRatings.contains(r)))
            }
        }
    }

    private var durationSection: some View {
        section("Duration", caption: nil) {
            ForEach(DiscoverFilterOptions.durationBuckets) { b in
                Button { toggleDuration(b) } label: { Text(b.label) }
                    .buttonStyle(ChipButtonStyle(selected: f.minMinutes == b.min && f.maxMinutes == b.max && (b.min != nil || b.max != nil)))
            }
        }
    }

    private var seasonSection: some View {
        section("Seasons", caption: nil) {
            ForEach(DiscoverFilterOptions.seasonBuckets) { b in
                Button { toggleSeasons(b) } label: { Text(b.label) }
                    .buttonStyle(ChipButtonStyle(selected: f.minSeasons == b.min && f.maxSeasons == b.max && (b.min != nil || b.max != nil)))
            }
        }
    }

    /// A titled block: an eyebrow label + optional caption over a horizontal chip scroller (the established
    /// Discover chip idiom, so focus and rhythm match the type / catalog / genre rows).
    @ViewBuilder private func section<Content: View>(_ title: String, caption: String?, @ViewBuilder _ chips: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(LocalizedStringKey(title)).eyebrowStyle()
            if let caption {
                Text(LocalizedStringKey(caption)).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) { chips() }
                    .padding(.vertical, Theme.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: decade + bucket selection

    /// Decades fully inside the current [minYear, maxYear] window read as selected, so two far-apart picks
    /// light up the whole span between them (a range).
    private var selectedDecades: Set<Int> {
        guard let lo = f.minYear, let hi = f.maxYear else { return [] }
        return Set(DiscoverFilterOptions.decades.filter { $0.start >= lo && $0.end <= hi }.map(\.id))
    }
    private func toggleDecade(_ d: DiscoverFilterOptions.Decade) {
        var sel = selectedDecades
        if sel.contains(d.id) { sel.remove(d.id) } else { sel.insert(d.id) }
        let chosen = DiscoverFilterOptions.decades.filter { sel.contains($0.id) }
        update {
            $0.minYear = chosen.map(\.start).min()
            $0.maxYear = chosen.map(\.end).max()
        }
    }
    private func toggleDuration(_ b: DiscoverFilterOptions.Bucket) {
        let on = f.minMinutes == b.min && f.maxMinutes == b.max
        update { $0.minMinutes = on ? nil : b.min; $0.maxMinutes = on ? nil : b.max }
    }
    private func toggleSeasons(_ b: DiscoverFilterOptions.Bucket) {
        let on = f.minSeasons == b.min && f.maxSeasons == b.max
        update { $0.minSeasons = on ? nil : b.min; $0.maxSeasons = on ? nil : b.max }
    }
}
