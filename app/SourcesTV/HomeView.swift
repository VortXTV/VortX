import SwiftUI

/// Native tvOS Home, driven by the **stremio-core** engine (via `CoreBridge`): a "Continue Watching"
/// rail plus every catalog of every installed addon, on the StremioX design system (Theme.swift).
struct HomeView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var profiles: ProfileStore
    @StateObject private var focusModel = FocusedItemModel()

    /// The owner profile rides the account's Continue Watching; overlay profiles ride their own
    /// private synced history.
    private var continueWatching: [CoreCWItem] {
        profiles.activeUsesEngineHistory ? core.continueWatching : profiles.cwItems
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
                // The rails live in a bottom strip. The focus engine centers focused rows inside
                // THIS viewport, so they are geometrically incapable of riding up over the hero.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                        if !continueWatching.isEmpty {
                            CoreContinueWatchingRow(items: continueWatching, focusModel: focusModel,
                                                    // the long-press menu mutates the ACCOUNT library;
                                                    // overlay rails manage their own history
                                                    menu: profiles.activeUsesEngineHistory ? .continueWatching : .none)
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
            }
            .overlay(alignment: .topLeading) {
                header
                    .padding(.top, 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea()   // absolute top-left, clear of the hero title below
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
        .onAppear { configureMetaSources(); seed() }
        .onChange(of: core.boardRows.first?.id) { seed() }
        .onChange(of: core.continueWatching.first?.id) { seed() }
        .onChange(of: profiles.activeID) { seed() }
        .onChange(of: core.addons.count) { configureMetaSources() }
    }

    /// The hero enrichment asks the user's own meta add-ons, so every id scheme resolves.
    private func configureMetaSources() {
        FocusedItemModel.configureMetaSources(
            transportUrls: core.addons.filter(\.providesMeta).map(\.transportUrl))
    }

    /// First render shows the page's actual first item, and Continue Watching pre-fetches its
    /// details so heroes are rich on first focus.
    private func seed() {
        focusModel.seedIfEmpty(continueWatching.first?.focusedHero
                               ?? core.boardRows.first?.items.first?.focusedHero)
        focusModel.warm(continueWatching.map(\.focusedHero))
    }

    /// Serif wordmark, the editorial signature: warm-white "Stremio" with an ember "X".
    private var header: some View {
        HStack(spacing: 0) {
            Text("Stremio").foregroundStyle(Theme.Palette.textPrimary)
            Text("X").foregroundStyle(Theme.Palette.accent)
            Spacer()
        }
        .font(Theme.Typography.wordmark)
        .padding(.horizontal, Theme.Space.screenEdge)
    }
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
        guard let entry = LastStreamStore.entry(for: item.id, profileID: profiles.activeID),
              let url = URL(string: entry.url) else { return nil }
        if PlaybackSettings.torrentsDisabled && entry.torrent == true { return nil }
        if item.type == "series", let cwVideo = item.state.videoId, cwVideo != entry.videoId { return nil }
        return {
            presenter.request = PlaybackRequest(
                url: url, title: entry.title,
                meta: PlaybackMeta(libraryId: item.id, videoId: entry.videoId, type: entry.type,
                                   name: entry.name, poster: entry.poster,
                                   season: entry.season, episode: entry.episode),
                episodes: [], sourceHint: entry.qualityText, torrent: entry.torrent ?? false)
        }
    }
}

/// One engine catalog row from the board (all installed-addon catalogs).
struct CoreCatalogRowView: View {
    let row: CoreBoardRow
    var focusModel: FocusedItemModel? = nil
    @EnvironmentObject private var theme: ThemeManager

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
                    }
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)   // room for the focus halo
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
