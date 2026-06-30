import SwiftUI

/// The ambient featured hero shown at the top of Home, Library, and Discover — the touch/Mac twin of
/// the tvOS browse hero. It mirrors the `iOSDetailView` hero's visual language: a full-bleed
/// `meta.background` STILL backdrop with the same dual-gradient scrim, a logo-or-serif-title, the
/// ★rating · year · runtime · genres meta row, a 3-line synopsis, and a Play + Trailer action row.
///
/// This hero is an AMBIENT BILLBOARD, decoupled from the catalog grid: the model rotates it through a
/// random pool of top items as a still backdrop, and rotation quiets while the user interacts. It does
/// NOT auto-select / focus / ring any poster, and tapping a poster opens that title via normal
/// navigation rather than "featuring" it here (issue #53). When the featured item has a trailer whose
/// `playableURL` resolves and motion is allowed, a muted, looping clip plays as the hero backdrop (#44)
/// through the native libmpv player over the embedded server's `/yt` route (`InHeroTrailerView`), the
/// SAME path tvOS uses — no YouTube web embed (which YouTube's July-2025 Referer enforcement broke). The
/// still backdrop underneath is the permanent fallback, so a missing / slow / blocked clip never occludes
/// the art. The Play button opens the title's detail and the Trailer chip plays the trailer in-app in a
/// full-screen native player cover. The cross-fade, rotation, and the hero clip honour
/// `accessibilityReduceMotion` (the view swaps instantly and the clip is skipped when set).
struct FeaturedHeroView: View {
    @ObservedObject var model: FeaturedHeroModel
    /// Open the featured title's detail page (hero Play button).
    let onOpen: (FeaturedHeroItem) -> Void

    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The "Auto-play trailers" setting, honored by the other three hero clip call sites (tvOS home + both
    /// detail pages). The home billboard clip gates on it too so turning trailers off in Settings actually
    /// stops this ambient clip, not just reduced-motion.
    @AppStorage("stremiox.autoplayTrailers") private var autoplayTrailers = true

    /// The trailer presented full-screen IN-APP by the Trailer chip - a YouTube id handed to the keyless
    /// WKWebView IFrame cover (`TrailerEmbedCover`), the reliable YouTube path now that tokenless extraction
    /// is dead. Drives a cover.
    @State private var trailerEmbed: TrailerEmbedLaunch?
    /// The trailer presented full-screen IN-APP via the NATIVE libmpv player (the /clip mp4, same source as the
    /// ambient hero clip + the detail page). Preferred over the IFrame so nothing in the hero can show a
    /// YouTube error card or hand off to a browser (#103).
    @State private var trailerPlay: TrailerNativeLaunch?


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
        #if os(macOS)
        // With .windowStyle(.hiddenTitleBar) the top safe-area inset collapses; let just the first band
        // bleed into that region so its top isn't clipped. Only .top/.container, so the rails below keep
        // normal insets. The dual scrim (below) keeps the window controls legible over the art.
        .ignoresSafeArea(.container, edges: .top)
        // Mac branding lives in content (the window toolbar is removed to kill the NSToolbar crash). The
        // hero is the first element on Home / Discover / Library, so the wordmark reads on every primary
        // Mac screen. Pure SwiftUI overlay, never a ToolbarItem.
        .overlay(alignment: .topLeading) {
            VortXWordmark(fontSize: 22)
                .padding(.leading, Theme.Space.lg)
                .padding(.top, Theme.Space.lg)
                .allowsHitTesting(false)
        }
        #endif
        // The LazyVStack host has no horizontal padding (each rail insets itself), so the band is
        // already edge-to-edge — a fixed-height ambient scroll-header.
        // Animate the swap on the hero id — the model already wraps content changes in the matching
        // cross-fade, but keying the container guarantees art + overlay move as one.
        .animation(reduceMotion ? nil : .easeOut(duration: FeaturedHeroModel.heroCrossfade),
                   value: model.hero?.id)
        // The Trailer chip presents the trailer IN-APP full-screen via the keyless WKWebView IFrame cover
        // (the reliable YouTube path now that tokenless extraction is dead), filling the window on macOS too.
        .platformFullScreenPlayerCover(item: $trailerEmbed) { launch in
            TrailerEmbedCover(youTubeID: launch.youTubeID, title: launch.title, onClose: { trailerEmbed = nil })
                .ignoresSafeArea()
        }
        // #103: the Trailer chip plays the native /clip mp4 in libmpv (NEVER the YouTube IFrame), so the hero
        // can never show a YouTube error card. The IFrame cover above is the last-resort path only when no
        // clipURL resolves.
        .platformFullScreenPlayerCover(item: $trailerPlay) { launch in
            PlayerScreen(url: launch.url, title: launch.title, headers: nil, resumeSeconds: 0,
                         recordMeta: nil, isTrailer: true, onClose: { trailerPlay = nil })
                .ignoresSafeArea()
        }
    }

    /// The muted, looping, chromeless in-hero clip (#44), now played through libmpv via `InHeroTrailerView`
    /// (the embedded server's `/yt` route), mirroring tvOS. Mounted over the backdrop ONLY when motion is
    /// allowed and the featured item's trailer resolves a PLAYABLE url (nil on the Lite build, so it
    /// no-ops to the still backdrop there). Keyed on the URL so it reloads per item and tears down the
    /// moment the hero rotates to another title; the still backdrop underneath is the fallback when no
    /// clip plays. Decorative — the title / meta read first for VoiceOver.
    @ViewBuilder private var heroClip: some View {
        if autoplayTrailers, !reduceMotion, let hero = model.hero, let clip = hero.clipURL {
            // The muted ambient trailer now plays the VortX /clip mp4 (iTunes -> KinoCheck + Container -> R2)
            // natively in libmpv - the same path tvOS uses - instead of the flaky YouTube IFrame (the
            // 151/152/153 embedder family). A miss never reveals, leaving the still backdrop + Ken Burns.
            // The explicit Trailer button still plays YouTube on demand.
            InHeroTrailerView(url: clip, height: heroHeight, window: nil)
                .allowsHitTesting(false)
                .id("hero-clip-\(hero.id)")    // reload the clip for each new featured item / rotation
                .transition(reduceMotion ? .identity : .opacity)
        }
    }

    // MARK: Backdrop (full-bleed still art + dual scrim, lifted from iOSDetailView.backdrop)

    private var backdrop: some View {
        // GeometryReader pins BOTH art layers to the EXACT band size so `scaledToFill` always covers the
        // whole band at any window width. Without it, the AsyncImage sat unframed inside the ZStack (the
        // frame was on the ZStack, not the image), so it sized to the loaded image's natural width and the
        // rest of the wide macOS band stayed bare scrim — the "backdrop only fills part of the band" report.
        // (On the narrow iPhone the image width happened to exceed the band, so the gap never showed.)
        GeometryReader { geo in
            KenBurnsArt {
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
        // fanart.tv clearlogo first (when enabled), else the ERDB-aware add-on/metahub logo, else serif text.
        // The shared component is used by tvOS + the detail pages too, so the logo behaves identically everywhere.
        // Prefer the imdb id (behaviorHints.defaultVideoId) when enrichment surfaced one: a TMDB/Kitsu catalog
        // title's `id` is tmdb:/kitsu: which fanart.tv/ERDB can't map, so the logo only resolves off the imdb
        // id (mirrors iOSDetailView's `meta.behaviorHints?.defaultVideoId ?? meta.id`).
        ResolvedTitleLogo(id: hero.defaultVideoId ?? hero.id, type: hero.type, fallbackLogo: hero.logo,
                          maxWidth: 320, maxHeight: 110, accessibilityName: hero.name) {
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
    /// Tapping it opens an explicit full-screen IN-APP player cover; it never autoplays inline.
    @ViewBuilder private func trailerButton(_ hero: FeaturedHeroItem) -> some View {
        let yt = hero.trailerYouTubeID
        if hero.clipURL != nil || (yt.map { !$0.isEmpty } ?? false) {
            Button {
                // NATIVE first: play the /clip mp4 in libmpv (same source as the ambient clip + the detail
                // page), so the hero never shows a YouTube error card or hands off to a browser (#103). The
                // IFrame is the last resort only when no clipURL resolves.
                if let clip = hero.clipURL {
                    trailerPlay = TrailerNativeLaunch(url: clip, title: "\(hero.name) Trailer")
                } else if let yt, !yt.isEmpty {
                    trailerEmbed = TrailerEmbedLaunch(youTubeID: yt, title: "\(hero.name) Trailer")
                }
            } label: {
                Label("Trailer", systemImage: "play.rectangle.fill")
            }
            .buttonStyle(ChipButtonStyle())
        }
    }
}

/// A still backdrop that slowly pans + zooms (Ken Burns) so the hero band is never static when no muted
/// clip is playing (Lite build, no trailer, or while the /clip mp4 is still warming). Local `@State` plus
/// the parent's per-title `.id` on the backdrop means each new featured title restarts the pan from
/// neutral. Fully gated off under Reduce Motion. The host frame + `.clipped()` keep the drift inside the
/// band (scale >= 1.05 so the offset never bares an edge). Compositor-only (transform/opacity) per the
/// motion rules — never animates layout.
private struct KenBurnsArt<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = false
    private let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .scaleEffect(active ? 1.08 : 1.0, anchor: .center)
            .offset(x: active ? 12 : -12, y: active ? 8 : -8)
            .animation(reduceMotion ? nil : .easeInOut(duration: 18).repeatForever(autoreverses: true), value: active)
            .onAppear { if !reduceMotion { active = true } }
    }
}

/// Identifiable launch box for the hero Trailer chip's in-app IFrame cover (`platformFullScreenPlayerCover(item:)`).
private struct TrailerEmbedLaunch: Identifiable {
    let id = UUID()
    let youTubeID: String
    let title: String
}

/// Identifiable launch box for the hero Trailer chip's NATIVE libmpv player cover (#103, the /clip mp4 path).
private struct TrailerNativeLaunch: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}
