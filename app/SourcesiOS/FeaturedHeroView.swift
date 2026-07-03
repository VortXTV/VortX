import SwiftUI
#if canImport(UIKit)
import UIKit   // UIScreen / UIDevice for the screen-proportional hero band height
#endif

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

    @ObservedObject private var l10n = LocalizedMetadataStore.shared   // localized hero title/logo override
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The "Auto-play trailers" setting, honored by the other three hero clip call sites (tvOS home + both
    /// detail pages). The home billboard clip gates on it too so turning trailers off in Settings actually
    /// stops this ambient clip, not just reduced-motion.
    @AppStorage("stremiox.autoplayTrailers") private var autoplayTrailers = true

    /// The trailer presented full-screen IN-APP by the Trailer chip via the keyless WKWebView IFrame cover
    /// (`TrailerEmbedCover`) - the iOS/Mac FALLBACK path only, used when the native `/yt` resolver is
    /// unavailable (Lite build / no embedded server) but a YouTube id exists. Drives a cover.
    @State private var trailerEmbed: TrailerEmbedLaunch?
    /// The trailer presented full-screen IN-APP via the NATIVE libmpv/AVPlayer player - the PRIMARY full-trailer
    /// path (owner FINAL architecture): the server's `/yt/{id}` resolver URL, else the 10s `/clip` mp4 as a last
    /// resort. Native so nothing in the hero can show a YouTube error card or hand off to a browser (#103).
    @State private var trailerPlay: TrailerNativeLaunch?
    /// Transient "trailer is preparing" notice for the rare both-paths-out case (cold /clip AND no
    /// YouTube id): a small auto-dismissing capsule over the hero, never the full source-error screen.
    @State private var trailerNotice = false
    @State private var trailerNoticeTask: Task<Void, Never>?
    /// yt-direct: the ambient hero clip's ATTEMPTED device-direct resolve, keyed by hero id so a stale
    /// resolve never paints another title's clip. `url == nil` = attempted, no direct stream (mount the
    /// /yt worker URL). The clip waits for the attempt so it never remounts mid-loop on a late resolve.
    @State private var heroClipDirect: (heroID: String, url: URL?)?


    /// Hero band height. iPhone: the billboard must command MORE THAN HALF the screen (owner ask), so the
    /// band is a fraction of the device screen height — 0.58 lands 55-60% visible even with the notch /
    /// home-indicator safe areas inside the bounds. The content row is bottom-anchored, so the extra
    /// height shows more backdrop above it. iPad's much taller canvas gets a gentler fraction with a cap
    /// so the hero stays a billboard, not a full page. macOS: taller than the old 460 but a FIXED cap, so
    /// a huge window never becomes all hero.
    static var heroHeight: CGFloat {
        #if os(macOS)
        return 520
        #else
        // Size off the app WINDOW, not the physical screen: in iPad Split View / Slide Over the window is
        // shorter/narrower than UIScreen.main, so keying the band off the whole screen would let the
        // billboard eat a disproportionate share of a narrow multitasking window. Fall back to the full
        // screen when no foreground window scene is resolvable (which is also the full-screen iPhone case,
        // where window == screen, so that path is unchanged).
        let windowScene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        let screenHeight = windowScene?.keyWindow?.bounds.height
            ?? UIScreen.main.bounds.height
        if UIDevice.current.userInterfaceIdiom == .pad {
            return min(screenHeight * 0.45, 560)
        }
        // iPhone: a bit bigger than the prior 0.58 (owner H19b) - the band commands ~62% of the screen.
        // The band bleeds under the top safe area (H19a), so this fraction includes the status-bar region
        // rather than sitting below it, which is what removed the black gap above the hero.
        return screenHeight * 0.62
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
        // Let just the first band bleed to the very top so the hero art runs behind the chrome (the
        // cinematic media-app look) instead of starting below it. On macOS that's behind the hidden
        // title-bar / traffic-light region; on iOS it's behind the frosted status-bar / nav bar. Only
        // .top/.container, so the rails below keep normal insets. This is what removes the BLACK GAP the
        // owner saw above the iPhone hero (H19a): the hero-height bump was double-counting the safe-area
        // inset, leaving the status-bar strip as bare canvas above the band. The dual scrim (below) keeps
        // the status bar / window controls legible over the art.
        .ignoresSafeArea(.container, edges: .top)
        // Mac branding now lives ONLY in the persistent top bar (iOSRootView.macTopBar); the old
        // hero-corner wordmark rendered a SECOND logo on every primary screen (owner report).
        // The rare "no trailer available right now" notice (both trailer paths out). A small capsule,
        // auto-dismissed by `showTrailerNotice`, so the Trailer chip never opens the source-error screen.
        .overlay(alignment: .bottom) {
            if trailerNotice {
                Text("Trailer is preparing, try again shortly")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(.bottom, Theme.Space.md)
                    .transition(reduceMotion ? .identity : .opacity)
                    .allowsHitTesting(false)
            }
        }
        // The LazyVStack host has no horizontal padding (each rail insets itself), so the band is
        // already edge-to-edge — a fixed-height ambient scroll-header.
        // Animate the swap on the hero id — the model already wraps content changes in the matching
        // cross-fade, but keying the container guarantees art + overlay move as one.
        .animation(reduceMotion ? nil : .easeOut(duration: FeaturedHeroModel.heroCrossfade),
                   value: model.hero?.id)
        // FALLBACK cover (iOS/Mac, no server): the keyless WKWebView IFrame, used only when the native /yt
        // resolver is unavailable (Lite build) but a YouTube id exists. Fills the window on macOS too.
        .platformFullScreenPlayerCover(item: $trailerEmbed) { launch in
            TrailerEmbedCover(youTubeID: launch.youTubeID, title: launch.title, onClose: { trailerEmbed = nil })
                .ignoresSafeArea()
        }
        // PRIMARY cover: the FULL trailer via the native /yt resolver (else the 10s /clip mp4) in libmpv/AVPlayer,
        // so the hero can never show a YouTube error card. This is the owner FINAL full-trailer path.
        .platformFullScreenPlayerCover(item: $trailerPlay) { launch in
            PlayerScreen(url: launch.url, title: launch.title, headers: nil, resumeSeconds: 0,
                         recordMeta: nil, isTrailer: true, audioSidecarURL: launch.audioSidecarURL,
                         onClose: { trailerPlay = nil })
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
        // Also gated by the RemoteConfig fleet kill-switch `features.trailers` (baked default true, so an
        // absent/null remote is identical to shipping): a remote `false` force-disables ambient hero trailers
        // fleet-wide; the user's "Auto-play trailers" setting still governs.
        if autoplayTrailers, RemoteConfig.snapshot.isFeatureOn("trailers", default: true),
           !reduceMotion, let hero = model.hero, let clip = hero.ambientTrailerURL {
            // Owner directive: the muted ambient in-hero trailer now plays the SAME full `/yt/{id}` trailer as
            // the Trailer button (`ambientTrailerURL` -> the native resolver), just muted + looping, instead of
            // the retired R2 `/clip` snippet or the flaky YouTube IFrame (the 151/152/153 embedder family). The
            // whole trailer loops (window nil). A miss never reveals, leaving the still backdrop + Ken Burns.
            // The explicit Trailer button still plays YouTube on demand.
            // yt-direct: try the DEVICE-DIRECT stream first (resolved on the user's own IP; the clip is
            // muted, so a video-only adaptive pick needs no audio sidecar). The clip mounts only after the
            // attempt lands so a late resolve never remounts it; a miss mounts the /yt worker URL.
            Group {
                if let attempt = heroClipDirect, attempt.heroID == hero.id {
                    InHeroTrailerView(url: attempt.url ?? clip, height: heroHeight, window: nil)
                        .allowsHitTesting(false)
                        .id("hero-clip-\(hero.id)")    // reload the clip for each new featured item / rotation
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .task(id: hero.id) { await resolveHeroClipDirect(hero) }
        }
    }

    /// yt-direct: one attempt per featured item at resolving the ambient clip on the user's own IP.
    /// Fail-soft: any miss records `url = nil`, which mounts the existing /yt worker URL unchanged.
    private func resolveHeroClipDirect(_ hero: FeaturedHeroItem) async {
        guard heroClipDirect?.heroID != hero.id else { return }
        var direct: URL? = nil
        if let yt = hero.trailerYouTubeID, !yt.isEmpty {
            let resolved = await YouTubeDirectResolver.resolve(videoID: yt, maxHeight: 1080)
            direct = resolved?.videoURL
            NSLog("[yt-direct] hero ambient: %@",
                  resolved.map { $0.isMuxed ? "direct-muxed" : "direct-pair" } ?? "fallback-worker")
        }
        heroClipDirect = (hero.id, direct)
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
            // Smooth multi-stop vertical fade to canvas so the rails / grid below read cleanly and the band
            // dissolves into the page with no hard seam (matches the detail hero's cinematic fade).
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Theme.Palette.canvas.opacity(0.15), location: 0.45),
                .init(color: Theme.Palette.canvas.opacity(0.55), location: 0.72),
                .init(color: Theme.Palette.canvas.opacity(0.88), location: 0.90),
                .init(color: Theme.Palette.canvas, location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        )
        .overlay(
            // Leading fade, the editorial touch the detail hero uses for the title column.
            LinearGradient(colors: [Theme.Palette.canvas.opacity(0.5), .clear],
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
                    .lineLimit(2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Theme.Space.readableColumn, alignment: .leading)
            }
            pagerDots
        }
    }

    /// Pager dots reflecting which of the rotating pool items is showing — the ambient-billboard cue the
    /// reference design uses. Hidden for a single-item pool (nothing to page). The active dot is the ember
    /// accent; the rest are a dim capsule. Decorative, so hidden from VoiceOver.
    @ViewBuilder private var pagerDots: some View {
        if model.pageCount > 1 {
            HStack(spacing: 6) {
                ForEach(0..<model.pageCount, id: \.self) { i in
                    Capsule()
                        .fill(i == model.page ? Theme.Palette.accent : Theme.Palette.textPrimary.opacity(0.28))
                        .frame(width: i == model.page ? 18 : 6, height: 6)
                        .animation(reduceMotion ? nil : Theme.Motion.state, value: model.page)
                }
            }
            .padding(.top, Theme.Space.xs)
            .accessibilityHidden(true)
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
        // Prefer a pooled LOCALIZED logo (user-language clearlogo) over the add-on/metahub logo when one exists.
        ResolvedTitleLogo(id: hero.defaultVideoId ?? hero.id, type: hero.type,
                          fallbackLogo: l10n.logo(for: hero.id) ?? hero.logo,
                          maxWidth: 320, maxHeight: 110, accessibilityName: l10n.title(for: hero.id) ?? hero.name) {
            heroTitle(hero)
        }
    }

    private func heroTitle(_ hero: FeaturedHeroItem) -> some View {
        Text(l10n.title(for: hero.id) ?? hero.name)
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
            // A rounded "View Details" pill: tapping the hero opens the title's detail page (where Play
            // lives), so the label states what the tap does. Ember fill, big radius — the reference pill.
            Button { onOpen(hero) } label: {
                // The tap opens the detail page (where Play lives), not playback, so the glyph is an
                // info/detail cue rather than a play triangle: a filled play icon here reads as "start
                // playback" and contradicts both the label and the outcome (and VoiceOver reads "View
                // Details" while the visual said play).
                Label("View Details", systemImage: "info.circle.fill")
                    .font(Theme.Typography.label.weight(.semibold))
                    .foregroundStyle(Theme.Palette.onAccent)
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.vertical, Theme.Space.sm + 2)
                    .background(Theme.Palette.accent,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
                    .shadow(color: Theme.Palette.accent.opacity(0.35), radius: 18, y: 8)
            }
            .buttonStyle(.plain)

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
                let name = hero.name, clip = hero.clipURL, ytID = yt
                let heroItem = hero, heroID = hero.id, heroType = hero.type
                Task { @MainActor in
                    // A6 (owner FINAL architecture): the Trailer BUTTON plays the FULL trailer ON DEMAND through
                    // the app's own server route (server.js `/yt/:id`, InnerTube -> a direct stream) NATIVELY in
                    // libmpv/AVPlayer - the SAME path our YouTube URL playback uses. The /clip mp4 is ONLY the 10s
                    // ambient billboard loop, so it is the last-resort fallback here, never the primary.
                    // D11 language pick: if the viewer prefers a non-English language and TMDB has a trailer in it,
                    // use that localized id. Only a genuine preferred-language hit (matchedPreferred) overrides,
                    // and only non-English prefs, so an English-default viewer keeps the default id. Fail-soft.
                    var chosenYT = (ytID?.isEmpty == false) ? ytID : nil
                    let prefs = TMDBClient.preferredTrailerLanguages.filter { $0 != "en" }
                    if !prefs.isEmpty {
                        let pick = await TMDBClient.preferredTrailerPick(metaID: heroID, type: heroType, preferredLanguages: prefs)
                        if pick.matchedPreferred, let localized = pick.key, !localized.isEmpty { chosenYT = localized }
                    }
                    let lang = TMDBClient.trailerLanguageBaseCode
                    // 0) DEVICE-DIRECT FIRST (yt-direct): resolve the YouTube stream on the user's own IP
                    //    (InnerTube from the app; a residential IP gets adaptive 1080p+, which plays in
                    //    libmpv with the separate audio stream as an --audio-file sidecar). Fail-soft: a
                    //    miss falls through to the /yt worker exactly as before.
                    if let ytID2 = chosenYT,
                       let resolved = await YouTubeDirectResolver.resolve(videoID: ytID2, maxHeight: 1080) {
                        NSLog("[yt-direct] hero trailer button: %@ h=%d", resolved.isMuxed ? "direct-muxed" : "direct-pair", resolved.height)
                        trailerPlay = TrailerNativeLaunch(url: resolved.videoURL, title: "\(name) Trailer",
                                                          audioSidecarURL: resolved.audioURL)
                    }
                    // 1) The FULL trailer via the native /yt resolver, played in the libmpv player cover.
                    else if let ytID2 = chosenYT, let native = heroItem.nativeTrailerURL(youTubeID: ytID2, languageCode: lang) {
                        NSLog("[yt-direct] hero trailer button: fallback-worker")
                        trailerPlay = TrailerNativeLaunch(url: native, title: "\(name) Trailer")
                    } else if let ytID2 = chosenYT {
                        // 2) FALLBACK (iOS/Mac only, no server / Lite): the FULL YouTube trailer via the keyless
                        //    IFrame embed cover.
                        trailerEmbed = TrailerEmbedLaunch(youTubeID: ytID2, title: "\(name) Trailer")
                    } else if let clip, await TrailerClipProbe.isReady(clip) {
                        // 3) LAST RESORT: no YouTube id at all - play the 10s /clip mp4 in libmpv, but ONLY if it
                        //    is actually warmed in R2 (a cold clip returns 404 clip_warming and libmpv would
                        //    dead-end). The probe miss queues the worker's background extract for a later tap.
                        trailerPlay = TrailerNativeLaunch(url: clip, title: "\(name) Trailer")
                    } else {
                        // 4) Nothing playable yet: a small transient notice, never the full source-error screen.
                        showTrailerNotice()
                    }
                }
            } label: {
                Label("Trailer", systemImage: "play.rectangle.fill")
            }
            .buttonStyle(ChipButtonStyle())
        }
    }

    /// Surface the "no trailer right now" case as a small self-dismissing notice over the hero band
    /// instead of the full source-error screen. The probe miss already queued the worker's background
    /// extract, so a later tap usually plays.
    private func showTrailerNotice() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { trailerNotice = true }
        // The capsule is visual-only (allowsHitTesting false, no focus); speak it so a VoiceOver user who
        // tapped Trailer gets the same feedback instead of the tap appearing to do nothing.
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: "Trailer is preparing, try again shortly")
        #endif
        trailerNoticeTask?.cancel()
        trailerNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { trailerNotice = false }
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
    /// yt-direct adaptive pair: the separate audio stream mpv mounts alongside a video-only `url`.
    var audioSidecarURL: URL? = nil
}
