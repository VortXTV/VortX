import SwiftUI

/// Native tvOS Live TV, driven by the **stremio-core** engine (`CoreBridge.liveBoardRows`): the engine's
/// tv / channel / events catalogs rendered as focus-driven rows of square CHANNEL TILES, distinct from
/// the 2:3 poster rails the rest of the app uses. Channel art is a logo on a neutral surface card, not
/// box-art, so a dedicated `ChannelTile` (not a forked `PosterCard`) carries the right shape. Focusing a
/// tile feeds the same `BrowseHeroBackdrop` / `FocusedItemModel` that Home and Discover use; selecting one
/// pushes the standard `DetailView`, which has a Live branch (backdrop + name + LIVE badge + source list,
/// no VOD chrome) and plays through the player's live-tuned path. The screen reuses the engine + player
/// wholesale — no EPG, no M3U import.
///
/// Empty state: when no installed add-on exposes a live catalog there are no live rows, so the screen
/// nudges the user to the Add-ons tab rather than showing a blank surface.
struct LiveView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var account: StremioAccount
    @StateObject private var focusModel = FocusedItemModel()

    var body: some View {
        NavigationStack {
            ZStack {
                // The living backdrop: whichever channel is focused fills the screen with its art and
                // details, exactly like Home/Discover. Pure presentation, never focusable.
                BrowseHeroBackdrop(model: focusModel, detailsBottom: 520)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                        if !core.liveBoardRows.isEmpty {
                            ForEach(core.liveBoardRows) { row in
                                CoreChannelRowView(row: row, focusModel: focusModel)
                            }
                        } else if account.isSignedIn {
                            emptyState
                        } else {
                            CoreEmptyState.signedOut
                        }
                    }
                    .padding(.top, Theme.Space.sm)
                    .padding(.bottom, Theme.Space.xl)
                }
                .heroBottomStrip()
            }
            .overlay(alignment: .topLeading) {
                Text("Live TV").screenTitleStyle()
                    .padding(.horizontal, Theme.Space.screenEdge)
                    .padding(.top, 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea()   // absolute top-left, clear of the hero title below
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
        }
        // Widen the Home board so live catalogs (ordered after an add-on's movie/series catalogs, hence
        // outside the default window) hydrate here; re-run when add-ons finish loading async.
        .onAppear { core.ensureLiveCatalogsLoaded(); configureMetaSources(); seed() }
        .onChange(of: core.liveBoardRows.first?.id) { seed() }
        .onChange(of: core.addons.count) { core.ensureLiveCatalogsLoaded(); configureMetaSources() }
    }

    /// The hero enrichment asks the user's own meta add-ons, so every channel id scheme resolves.
    private func configureMetaSources() {
        FocusedItemModel.configureMetaSources(
            transportUrls: core.addons.filter(\.providesMeta).map(\.transportUrl))
    }

    /// First render shows the first channel's art, so the hero is never an empty canvas.
    private func seed() {
        focusModel.seedIfEmpty(core.liveBoardRows.first?.items.first?.focusedHero)
    }

    /// When no installed add-on exposes a live catalog, point the user at Add-ons rather than a blank page.
    private var emptyState: some View {
        CoreEmptyState(
            systemImage: "dot.radiowaves.left.and.right",
            title: "No Live TV add-ons installed",
            message: "Install an add-on that provides live TV, channels, or events in the Add-ons tab and its channels will show up here."
        )
        .frame(minHeight: 470)
    }
}

/// One Live row from the engine board: a titled, horizontally-scrolling band of square `ChannelTile`s.
/// The Live twin of `CoreCatalogRowView` — same header + spacing language, but square channel tiles
/// instead of 2:3 poster cards, and it feeds the focus model just like the poster rails do.
struct CoreChannelRowView: View {
    let row: CoreBoardRow
    var focusModel: FocusedItemModel? = nil
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(title: row.title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(row.items) { item in
                        ChannelTile(meta: item,
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

/// A focusable square (1:1) channel tile: the channel's logo (preferred) or poster, fit on a neutral
/// surface card so logos with transparency / odd aspect ratios read cleanly — channels rarely have
/// box-art, so a `fit` on a surface beats a `fill` crop. Navigates to the standard `DetailView`, which
/// engages the Live branch via the channel's `type`; crafted focus (scale + ember glow + lift) comes from
/// `CardFocusStyle`, the same component the poster cards use, so the row matches the rest of the app.
struct ChannelTile: View {
    let meta: CoreMeta
    var onFocus: (() -> Void)? = nil

    private let side: CGFloat = kPosterWidth   // square, matching the poster column width

    /// Logo first (the channel mark), else poster — both are channel-identifying art.
    private var artURL: URL? { URL(string: meta.logo ?? meta.poster ?? "") }

    var body: some View {
        NavigationLink { DetailView(type: meta.type, id: meta.id) } label: { tileLabel }
            .buttonStyle(CardFocusStyle())
    }

    private var tileLabel: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ZStack {
                Theme.Palette.surface1
                AsyncImage(url: artURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fit)
                            .padding(Theme.Space.md)
                    default:
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.Palette.hairline, lineWidth: 0.5)
            )
            Text(meta.name)
                .font(.system(size: 18, weight: .medium))
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: side, alignment: .leading)
        }
        .background { if let onFocus { FocusReporter(onFocus: onFocus) } }
    }
}
