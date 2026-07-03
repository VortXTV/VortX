import SwiftUI

/// Live TV: the engine's tv / channel / events catalogs (`CoreBridge.liveBoardRows`) rendered as
/// rows of square CHANNEL TILES, distinct from the 2:3 poster rails the rest of the app uses. Channel
/// art is a logo on a neutral card, not box-art, so a dedicated `ChannelTile` (not a forked poster
/// card) carries the right shape. Tapping a channel pushes the standard `iOSDetailView`, which now has
/// a Live branch (backdrop + name + source list + LIVE badge, no VOD chrome) and plays through the
/// player's live-tuned path. The screen reuses the engine + player wholesale — no EPG, no M3U import.
///
/// Empty state: when no installed add-on exposes a live catalog there are no live rows, so the screen
/// nudges the user to the Add-ons tab rather than showing a blank surface.
struct iOSLiveView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @State private var path: [FeaturedHeroItem] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if core.liveBoardRows.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                        ForEach(core.liveBoardRows) { row in
                            if !row.items.isEmpty {
                                ChannelRail(title: row.title, items: row.items, onTap: handleTap)
                            }
                        }
                    }
                    .padding(.vertical, Theme.Space.md)
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            // navigationTitle bridges into the single shared window toolbar on macOS where every mounted
            // tab stamps its own title, crashing NSToolbar on duplicate inserts. So it is iOS-only.
            #if os(iOS)
            .navigationTitle("Live TV")
            #endif
            .navigationDestination(for: FeaturedHeroItem.self) { item in
                iOSDetailView(id: item.id, type: item.type, title: item.name,
                              seedBackdrop: item.backdrop, seedLogo: item.logo)
            }
            // Live catalogs are usually ordered after an add-on's movie/series catalogs, so they fall
            // outside the Home board's default window. Widen the board so they hydrate here; re-run when
            // add-ons finish loading (their manifests arrive async, after the first appear).
            .onAppear { core.ensureLiveCatalogsLoaded() }
            .onChange(of: core.addons.count) { _ in core.ensureLiveCatalogsLoaded() }
        }
    }

    /// Open the channel's detail page (which engages the Live branch via its `type`). Unlike the
    /// poster surfaces there is no featured hero to pin to, so a tap always pushes detail.
    private func handleTap(_ meta: CoreMeta) {
        path.append(FeaturedHeroItem.from(meta: meta))
    }

    // Route through the shared compat empty state for one consistent layout (#44). No CTA: switching
    // to the Add-ons tab is owned by the root shell, so this stays a nudge rather than a button.
    private var emptyState: some View {
        ContentUnavailableViewCompat(title: "No Live TV add-ons installed",
            systemImage: "dot.radiowaves.left.and.right",
            message: "Install an add-on that provides live TV, channels, or events in the Add-ons tab and its channels will show up here.")
            .frame(minHeight: 420)
    }
}

/// One Live row: a titled, horizontally-scrolling band of square `ChannelTile`s. The twin of
/// `PosterRail` for live content — same header + spacing language, but square tiles instead of
/// 2:3 poster cards.
private struct ChannelRail: View {
    let title: String
    let items: [CoreMeta]
    let onTap: (CoreMeta) -> Void
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Space.md)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.Space.sm) {
                    ForEach(items) { item in
                        Button { onTap(item) } label: { ChannelTile(meta: item) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Space.md)
            }
        }
    }
}

/// A square (1:1) channel tile: the channel's logo (preferred) or poster, fit on a neutral surface
/// card so logos with transparency / odd aspect ratios read cleanly — channels rarely have box-art,
/// so a `fit` on a surface beats a `fill` crop. A square shape (`posterShape == "square"`) fits the
/// logo on the card; any other live item without square art falls back to the same logo-on-surface
/// tile so the row stays uniform. The channel name sits below, like a poster card.
private struct ChannelTile: View {
    let meta: CoreMeta
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live

    private let side: CGFloat = 132

    /// Logo first (the channel mark), else poster — both are channel-identifying art.
    private var artURL: URL? { URL(string: meta.logo ?? meta.poster ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Theme.Palette.surface1
                AsyncImage(url: artURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fit)
                            .padding(Theme.Space.sm)
                    default:
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 32, weight: .semibold))
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
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1).frame(width: side, alignment: .leading)
        }
    }
}
