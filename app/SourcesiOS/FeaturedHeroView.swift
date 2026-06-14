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


    /// Hero band height: a touch shorter on phones, taller on the Mac — matches `iOSDetailView`.
    static var heroHeight: CGFloat {
        #if os(macOS)
        return 460
        #else
        return 320
        #endif
    }

    /// macOS only: the hero tracks a fixed ~2:1 billboard ratio of the window WIDTH instead of a fixed
    /// height, so a wide window doesn't squash a 16:9 still into a thin sliver (the over-zoom / heavy
    /// side-letterbox reports). A 16:9 backdrop then nearly fills the band, with only a hair of blurred
    /// ambient fill at the edges. iPhone / iPad keep the fixed band (portrait widths are already tall).
    static let macHeroAspect: CGFloat = 2.0

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
        #if os(macOS)
        // Track a ~2:1 billboard ratio of the WINDOW WIDTH (not a fixed short height) so a wide window
        // can't squash a 16:9 still into a sliver. The backdrop then fills the band edge-to-edge with only
        // a gentle crop — the reference home-screen look — instead of letterbox bars or a heavy zoom.
        .frame(maxWidth: .infinity)
        .aspectRatio(Self.macHeroAspect, contentMode: .fit)
        #else
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        #endif
        // The LazyVStack host has no horizontal padding (each rail insets itself), so the band is
        // already edge-to-edge — a fixed-height ambient scroll-header.
        // Animate the swap on the hero id — the model already wraps content changes in the matching
        // cross-fade, but keying the container guarantees art + overlay move as one.
        .animation(reduceMotion ? nil : .easeOut(duration: FeaturedHeroModel.heroCrossfade),
                   value: model.hero?.id)
    }

    // MARK: Backdrop (full-bleed still art + dual scrim, lifted from iOSDetailView.backdrop)

    private var backdrop: some View {
        // GeometryReader pins BOTH art layers to the EXACT band size so `scaledToFill` always covers the
        // whole band at any window width. Without it, the AsyncImage sat unframed inside the ZStack (the
        // frame was on the ZStack, not the image), so it sized to the loaded image's natural width and the
        // rest of the wide macOS band stayed bare scrim — the "backdrop only fills part of the band" report.
        // (On the narrow iPhone the image width happened to exceed the band, so the gap never showed.)
        GeometryReader { geo in
            ZStack {
                // Poster fallback layer: a slow or failed backdrop request must never leave a flat black
                // band (the iPhone "no backdrop" report — AsyncImage fell straight to the black canvas on
                // a load miss while the iPad had it cached). The poster is the catalog art the screen
                // already loaded, so it's almost always available; the backdrop paints over it on success.
                posterFallback
                AsyncImage(url: URL(string: model.hero?.backdrop ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                    default: Color.clear   // transparent while loading / on failure so the poster shows through
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        #if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // fill the responsive billboard band set by body
        #else
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        #endif
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
        // Purely decorative art + scrims — hide from VoiceOver so the title/meta read first.
        .accessibilityHidden(true)
    }

    /// The poster painted behind the backdrop so the band is never flat black. Falls to canvas only
    /// when there is no poster at all (rare; the catalog/CW seed almost always carries one).
    @ViewBuilder private var posterFallback: some View {
        if let poster = model.hero?.poster, let url = URL(string: poster) {
            AsyncImage(url: url) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.Palette.canvas
                }
            }
            // Decorative backdrop filler — never announced by VoiceOver.
            .accessibilityHidden(true)
        } else {
            Theme.Palette.canvas
                .accessibilityHidden(true)
        }
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
                        // The logo is the title in image form — read the name, not the URL.
                        .accessibilityLabel(hero.name)
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
        // Combine the rating/year/runtime/genre tokens into one VoiceOver phrase.
        .accessibilityElement(children: .combine)
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
        if let yt = hero.trailerYouTubeID, let watch = URL(string: "https://www.youtube.com/watch?v=\(yt)") {
            Button {
                // Open the trailer in the YouTube app / browser. The in-app `/yt` resolver (ytdl-core)
                // currently 403s, so external open is the reliable path (no WKWebView "Error 153").
                TrailerOpener.open(watch)
            } label: {
                Label("Trailer", systemImage: "play.rectangle.fill")
            }
            .buttonStyle(ChipButtonStyle())
        }
    }
}
