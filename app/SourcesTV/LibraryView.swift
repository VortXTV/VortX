import SwiftUI

/// Library, driven by the **stremio-core** engine (`LibraryWithFilters`): the user's saved titles with
/// type + sort filters. Auto-refreshes as the library changes (add/remove/mark watched), no reload.
struct LibraryView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var profiles: ProfileStore   // gate the Library on the active profile's own history
    @StateObject private var focusModel = FocusedItemModel()
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared
    @ObservedObject private var downloads = DownloadStore.shared   // offline downloads section (#30)
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
                // title, filters, and grid all live in the bottom strip and tuck under the hero.
                BrowseHeroBackdrop(model: focusModel, detailsBottom: 520)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        Color.clear.frame(height: 0).scrollToTopAnchor()   // re-select Library tab -> scroll here
                        Text("Library").screenTitleStyle().padding(.horizontal, Theme.Space.screenEdge)
                        // Offline downloads (#30): a section ABOVE the saved-titles grid, shown only when at
                        // least one download exists. Plays from the local file with pause/resume/delete +
                        // total storage used, and carries the storage-eviction caption. Device-local only.
                        if !downloads.records.isEmpty {
                            TVDownloadsView()
                                .padding(.bottom, Theme.Space.lg)
                        }
                        if profiles.activeUsesEngineHistory {
                            // Owner profile: the account library (engine), with its type/sort filters.
                            if let library = core.library {
                                filters(library.selectable)
                                if library.catalog.isEmpty {
                                    hint("Your library is empty. Add titles to your library in Stremio and they will show up here.")
                                } else {
                                    grid(library.catalog)
                                }
                            } else if account.isSignedIn {
                                BigSpinner()
                                    .padding(Theme.Space.xxl).frame(maxWidth: .infinity)
                            } else {
                                CoreEmptyState.signedOut
                            }
                        } else {
                            // Overlay profile: its own private watch overlay (never the account). No
                            // engine `selectable`, so the filter chips are omitted.
                            let items = profiles.libraryItems
                            if items.isEmpty {
                                hint("This profile's library is empty. Titles it watches show up here.")
                            } else {
                                grid(items)
                            }
                        }
                    }
                    .padding(.top, Theme.Space.sm)
                    .padding(.bottom, Theme.Space.xl)
                }
                .heroBottomStrip()
                // Re-selecting the active Library tab scrolls back to the top.
                .scrollToTopOnBump(TabScrollKeys.library)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
        // Reload while empty: the library syncs from the API asynchronously after sign-in, so the
        // first load can land before ctx.library is populated. Revisiting the tab refills it.
        .onAppear { if core.library?.catalog.isEmpty != false { core.loadLibrary() }; seed() }
        .onChange(of: core.library?.catalog.first?.id) { seed() }
        .onChange(of: profiles.activeID) { seed() }
    }

    private func seed() {
        let first = profiles.activeUsesEngineHistory ? core.library?.catalog.first : profiles.libraryItems.first
        focusModel.seedIfEmpty(first?.focusedHero)
    }

    private func filters(_ selectable: CoreLibrarySelectable) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(selectable.types) { type in
                        Button { core.selectLibrary(type.request) } label: { Text(type.label) }
                            .buttonStyle(ChipButtonStyle(selected: type.selected))
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs / 2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(selectable.sorts) { sort in
                        Button { core.selectLibrary(sort.request) } label: { Text(sort.label) }
                            .buttonStyle(ChipButtonStyle(selected: sort.selected))
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs / 2)
            }
        }
    }

    private func grid(_ items: [CoreCWItem]) -> some View {
        LazyVGrid(columns: columns, spacing: Theme.Space.xl) {
            ForEach(items) { item in
                PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                           progress: item.progress > 0 ? item.progress : nil, menu: .library,
                           onFocus: { focusModel.focus(item.focusedHero) })
            }
        }
        .padding(.horizontal, Theme.Space.screenEdge).padding(.top, Theme.Space.sm)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.top, Theme.Space.lg)
    }
}
