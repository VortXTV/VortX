import SwiftUI

/// The ambient featured hero shown at the top of Home, Library, and Discover — the touch/Mac twin of
/// the tvOS browse hero. It mirrors the `iOSDetailView` hero's visual language: a full-bleed
/// `meta.background` STILL backdrop with the same dual-gradient scrim, a logo-or-serif-title, the
/// ★rating · year · runtime · genres meta row, a 3-line synopsis, and a Play + Trailer action row.
///
/// This hero is an AMBIENT BILLBOARD, decoupled from the catalog grid: the model rotates it through a
/// random pool of top items as a still backdrop, and rotation quiets while the user interacts. It does
/// NOT auto-select / focus / ring any poster, and tapping a poster opens that title via normal
/// navigation rather than "featuring" it here (issue #53). The hero never plays a trailer inline — the
/// dead in-hero YouTube autoplay layer (issue #46/#1/#3, "Error 153" widget that occluded the art) was
/// removed; the Play button opens the title's detail and the Trailer chip plays in a full-screen cover.
/// The cross-fade and rotation honour `accessibilityReduceMotion` (the view swaps instantly when set).
struct FeaturedHeroView: View {
    @ObservedObject var model: FeaturedHeroModel
    /// Open the featured title's detail page (hero Play button).
    let onOpen: (FeaturedHeroItem) -> Void

    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A trailer to present in the in-app cover, when the user taps the Trailer chip. (Detail-page
    /// trailers live here only as an explicit, user-initiated full-screen cover — never inline.)
    @State private var trailer: TrailerLaunch?

    /// Hero band height: a touch shorter on phones, taller on the Mac — matches `iOSDetailView`.
    static var heroHeight: CGFloat {
        #if os(macOS)
        return 460
        #else
        return 320
        #endif
    }

    private var heroHeight: CGFloat { Self.heroHeight }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The still backdrop image — the only art layer. No trailer webview is ever mounted over
            // it, so nothing can occlude the artwork (issue #46/#1/#3).
            backdrop
            if let hero = model.hero {
                content(hero)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.bottom, Theme.Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Key the overlay on the id so the text block cross-fades together with the art.
                    .id("hero-overlay-\(hero.id)")
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        // The LazyVStack host has no horizontal padding (each rail insets itself), so the band is
        // already edge-to-edge — a fixed-height ambient scroll-header.
        // Animate the swap on the hero id — the model already wraps content changes in the matching
        // cross-fade, but keying the container guarantees art + overlay move as one.
        .animation(reduceMotion ? nil : .easeOut(duration: FeaturedHeroModel.heroCrossfade),
                   value: model.hero?.id)
        .platformFullScreenPlayerCover(item: $trailer) { launch in
            TrailerPlayerScreen(launch: launch, onClose: { trailer = nil })
        }
    }

    // MARK: Backdrop (full-bleed still art + dual scrim, lifted from iOSDetailView.backdrop)

    private var backdrop: some View {
        AsyncImage(url: URL(string: model.hero?.backdrop ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default: Theme.Palette.canvas
            }
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        // Cross-fade the artwork itself on id change so a new featured title dissolves in.
        .id(model.hero?.id)
        .transition(reduceMotion ? .identity : .opacity)
        .overlay(
            // Vertical fade to canvas so the rails / grid below read cleanly and the band dissolves
            // into the page instead of ending in a hard edge.
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Theme.Palette.canvas.opacity(0.35), location: 0.5),
                .init(color: Theme.Palette.canvas.opacity(0.85), location: 0.82),
                .init(color: Theme.Palette.canvas, location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        )
        .overlay(
            // Leading fade, the editorial touch the detail hero uses for the title column.
            LinearGradient(colors: [Theme.Palette.canvas.opacity(0.6), .clear],
                           startPoint: .leading, endPoint: .center)
        )
    }

    // MARK: Overlay (logo-or-title · meta row · synopsis · actions)

    private func content(_ hero: FeaturedHeroItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            titleOrLogo(hero)
            metaRow(hero)
            actionRow(hero)
            if let overview = hero.description, !overview.isEmpty {
                Text(overview)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }

    /// The add-on logo when enrichment surfaced one (the editorial signature), else the serif hero
    /// type — mirrors `iOSDetailView.titleOrLogo`.
    @ViewBuilder private func titleOrLogo(_ hero: FeaturedHeroItem) -> some View {
        if let logo = hero.logo, let url = URL(string: logo), !logo.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320, maxHeight: 110, alignment: .leading)
                        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                default:
                    heroTitle(hero)
                }
            }
        } else {
            heroTitle(hero)
        }
    }

    private func heroTitle(_ hero: FeaturedHeroItem) -> some View {
        Text(hero.name)
            .font(Theme.Typography.hero).tracking(-1)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(2).minimumScaleFactor(0.6)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }

    /// ★ imdb · year · runtime · genres — same order and tokens as `iOSDetailView.metaRow`.
    private func metaRow(_ hero: FeaturedHeroItem) -> some View {
        HStack(spacing: Theme.Space.md) {
            if let imdb = hero.imdbRating {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.accent)
                    Text(imdb)
                }
            }
            if let r = hero.releaseInfo { Text(r) }
            if let rt = hero.runtime { Text(rt) }
            if !hero.genres.isEmpty { Text(hero.genres.prefix(3).joined(separator: " · ")).lineLimit(1) }
        }
        .font(Theme.Typography.label)
        .foregroundStyle(Theme.Palette.textSecondary)
    }

    /// Play (opens detail) + a Trailer chip shown only when a playable trailer resolves.
    private func actionRow(_ hero: FeaturedHeroItem) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Button { onOpen(hero) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryActionStyle())

            trailerButton(hero)
            Spacer(minLength: 0)
        }
        .padding(.top, Theme.Space.xs)
    }

    /// The Trailer chip — shown only when the enriched hero carries a trailer whose `playableURL`
    /// resolves (so the Lite build, with no proxy, auto-hides it the same way the detail page does).
    /// Tapping it opens an explicit full-screen player cover; it never autoplays inline.
    @ViewBuilder private func trailerButton(_ hero: FeaturedHeroItem) -> some View {
        if let yt = hero.trailerYouTubeID,
           TrailerRequest(title: hero.name, youTubeID: yt, directURL: nil).playableURL != nil {
            Button {
                trailer = TrailerLaunch(youTubeID: yt, title: hero.name)
            } label: {
                Label("Trailer", systemImage: "play.rectangle.fill")
            }
            .buttonStyle(ChipButtonStyle())
        }
    }
}
