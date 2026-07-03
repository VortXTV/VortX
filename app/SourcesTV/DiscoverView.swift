import SwiftUI

/// Discover, driven by the **stremio-core** engine (`CatalogWithFilters`): pick a type, catalog, and
/// genre, see the full grid. Each chip carries the engine's own `request`, dispatched back on tap.
struct DiscoverView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @AppStorage("stremiox.hideLiveTab") private var hideLiveTab = false   // also hide Live types from the Discover type filter
    @StateObject private var focusModel = FocusedItemModel()
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared
    @ObservedObject private var collectionsHub = CollectionsHubModel.shared
    @AppStorage("vortx.discover.showCollectionsHub") private var showCollectionsHub = true   // toggle the hub on Discover (needs a TMDB key)
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
                        Text("Discover").screenTitleStyle().padding(.horizontal, Theme.Space.screenEdge)
                        if showCollectionsHub, CollectionsHubModel.isAvailable {
                            TVCollectionsHub(model: collectionsHub)
                        }
                        if let discover = core.discover {
                            typeChips(discover.selectable.types)
                            catalogChips(discover.selectable.catalogs)
                            genreChips(discover.selectable.extra)
                            grid(discover.items)
                        } else if account.isSignedIn {
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
        .onChange(of: showCollectionsHub) { show in if show { collectionsHub.load() } else { collectionsHub.clear() } }
    }

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

    @ViewBuilder private func grid(_ items: [CoreMeta]) -> some View {
        if items.isEmpty {
            BigSpinner()
                .padding(Theme.Space.xxl).frame(maxWidth: .infinity)
        } else {
            LazyVGrid(columns: columns, spacing: Theme.Space.xl) {
                ForEach(items) { item in
                    PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                               menu: .catalog,
                               onFocus: { focusModel.focus(item.focusedHero) })
                        // Infinite scroll: load the next catalog page when focus reaches the last card
                        // (same shared engine path the touch grid uses). Fixes "next catalog not
                        // loading" on Apple TV too, not just iOS/Mac.
                        .onAppear { if item.id == items.last?.id { core.loadDiscoverNextPage() } }
                }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.top, Theme.Space.sm)
        }
    }
}
