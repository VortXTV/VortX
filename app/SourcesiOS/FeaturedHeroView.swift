import SwiftUI

/// The ambient featured hero shown at the top of Home, Library, and Discover — the touch/Mac twin of
/// the tvOS browse hero. It mirrors the `iOSDetailView` hero's visual language: a full-bleed
/// `meta.background` STILL backdrop with the same dual-gradient scrim, a logo-or-serif-title, the
/// ★rating · year · runtime · genres meta row, a 3-line synopsis, and a Play + Trailer action row.
///
/// This hero is an AMBIENT BILLBOARD, decoupled from the catalog grid: the model rotates it through a
/// random pool of top items as a still backdrop, and rotation quiets while the user interacts. It does
/// NOT auto-select / focus / ring any poster, and tapping a poster opens that title via normal
/// navigation rather than "featuring" it here (issue #53). When the featured item has a trailer id and
/// motion is allowed, a muted, looping YouTube clip plays as the hero backdrop (#44) via the keyless
/// IFrame embed (`YouTubeEmbedView`); the still backdrop underneath is the permanent fallback, so a
/// missing / slow / blocked clip never occludes the art (this is the correct fix for the old "Error 153"
/// autoplay layer that was removed in issue #46/#1/#3). The Play button opens the title's detail and the
/// Trailer chip plays the trailer in-app in a full-screen cover. The cross-fade, rotation, and the hero
/// clip honour `accessibilityReduceMotion` (the view swaps instantly and the clip is skipped when set).
struct FeaturedHeroView: View {
    @ObservedObject var model: FeaturedHeroModel
    /// Open the featured title's detail page (hero Play button).
    let onOpen: (FeaturedHeroItem) -> Void

    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The yt id presented full-screen by the Trailer chip (Bug A in the hero). Drives a cover.
    @State private var trailerEmbedID: String?
    /// Hero ids whose trailer embed reported a failure (owner disabled embedding, removed video, etc.).
    /// The clip is suppressed for these so the still backdrop shows instead of YouTube's error card.
    @State private var failedTrailerIDs: Set<String> = []


    /// Hero band height. iOS is 380: a bit bigger than the 0.3.0 320 (the user wanted a larger billboard),
    /// but NOT the 420 immersive band that bled under the nav bar and felt cramped. The content row is
    /// bottom-anchored, so the extra height just shows more backdrop above it. macOS keeps 460.
    static var heroHeight: CGFloat {
        #if os(macOS)
        return 460
        #else
        return 380
        #endif
    }

    private var heroHeight: CGFloat { Self.heroHeight }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The still backdrop image is the base art layer and the permanent fallback: the muted clip
            // (#44) only paints OVER it when a trailer id resolves, so a missing / slow / blocked embed
            // never leaves the band black — the artwork always shows through. Reduce-motion skips the
            // clip entirely.
            backdrop
            heroClip
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
        // Bug A in the hero: the Trailer chip presents the in-app YouTube embed full-screen (a media
        // cover, so it fills the window on macOS too).
        .platformFullScreenPlayerCover(item: trailerEmbedCoverItem) { item in
            TrailerEmbedCover(youTubeID: item.id, title: model.hero?.name ?? "Trailer",
                              onClose: { trailerEmbedID = nil })
        }
    }

    /// The muted, looping, chromeless in-hero clip (#44). Mounted over the backdrop ONLY when motion is
    /// allowed and the featured item has a resolved trailer id. Keyed on the hero id so it reloads per
    /// item; the still backdrop underneath is the fallback when no clip plays. Decorative — the title /
    /// meta read first for VoiceOver.
    @ViewBuilder private var heroClip: some View {
        if !reduceMotion, let hero = model.hero, let yt = hero.trailerYouTubeID, !yt.isEmpty,
           !failedTrailerIDs.contains(hero.id) {
            YouTubeEmbedView(youTubeID: yt, mode: .background, onFailure: { failedTrailerIDs.insert(hero.id) })
                .frame(height: heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .allowsHitTesting(false)       // the clip is ambient; taps fall through to the chrome
                .id("hero-clip-\(hero.id)")    // reload the embed for each new featured item
                .transition(reduceMotion ? .identity : .opacity)
                .overlay(
                    // Reuse the same dual scrim the backdrop uses so the title/meta stay legible over
                    // video, and the band still dissolves into the page below.
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: Theme.Palette.canvas.opacity(0.35), location: 0.5),
                        .init(color: Theme.Palette.canvas.opacity(0.85), location: 0.82),
                        .init(color: Theme.Palette.canvas, location: 1.0),
                    ], startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    LinearGradient(colors: [Theme.Palette.canvas.opacity(0.6), .clear],
                                   startPoint: .leading, endPoint: .center)
                )
                .accessibilityHidden(true)
        }
    }

    /// Binding of the Identifiable yt-id box that drives the cover. Maps the `String?` state into the
    /// `Binding<TrailerEmbedID?>` the cover modifier expects; clearing it dismisses.
    private var trailerEmbedCoverItem: Binding<TrailerEmbedID?> {
        Binding(
            get: { trailerEmbedID.map(TrailerEmbedID.init) },
            set: { trailerEmbedID = $0?.id }
        )
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
                    case .success(let img):
                        // ONE fill image clipped to the band — the same clean approach as
                        // iOSDetailView.backdrop. The earlier dual layer (a blurred band-filling copy under a
                        // fit copy of the SAME photo) painted the image twice and read as "two overlapping
                        // images". A single scaledToFill covers the band with no second copy and no side gaps.
                        img.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    default: Color.clear   // transparent while loading / on failure so the poster shows through
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
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
        if let yt = hero.trailerYouTubeID, !yt.isEmpty {
            Button {
                // Play the trailer in-app via the keyless YouTube IFrame embed (Bug A) — same as the
                // detail page. No external hand-off, no Error 153.
                trailerEmbedID = yt
            } label: {
                Label("Trailer", systemImage: "play.rectangle.fill")
            }
            .buttonStyle(ChipButtonStyle())
        }
    }
}

/// Identifiable yt-id box for `platformFullScreenCover(item:)` (the hero Trailer chip, Bug A).
private struct TrailerEmbedID: Identifiable { let id: String }
