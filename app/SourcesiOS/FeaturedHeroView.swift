import SwiftUI

/// The interactive featured hero shown at the top of Home, Library, and Discover — the touch/Mac
/// twin of the tvOS browse hero. It mirrors the `iOSDetailView` hero's visual language exactly:
/// a full-bleed `meta.background` backdrop with the same dual-gradient scrim, a logo-or-serif-title,
/// the ★rating · year · runtime · genres meta row, a 3-line synopsis, and a Play + Trailer action row.
///
/// Unlike the old image-only `iOSHeroBackdrop`, this hero is INTERACTIVE: it reflects the model's
/// auto-rotating / user-pinned featured item, cross-fades on change (keyed on the hero id), and its
/// Play button opens the featured title's detail page. The cross-fade and auto-rotation honour
/// `accessibilityReduceMotion` (the model is seeded with the flag; the view swaps instantly when set).
struct FeaturedHeroView: View {
    @ObservedObject var model: FeaturedHeroModel
    /// Open the featured title's detail page (hero Play button / second-tap router).
    let onOpen: (FeaturedHeroItem) -> Void

    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A trailer to present in the in-app cover, when the user taps the Trailer chip.
    @State private var trailer: TrailerLaunch?

    // MARK: Muted autoplay state (Netflix-style ambient preview behind the hero art)

    /// The YouTube id currently authorized to autoplay muted behind the art. Set only after the
    /// `trailerAutoplayDwell` elapses on a settled, trailer-bearing hero; cleared the instant the
    /// featured item changes, the view disappears, the embed fails, or it times out — so at most one
    /// webview is ever mounted, and only for the currently featured item.
    @State private var autoplayYouTubeID: String?
    /// Cancels the pending dwell so a fast rotation / poster tap never starts a stale trailer.
    @State private var dwellTask: Task<Void, Never>?
    /// Cancels the load-timeout watchdog when the embed reports it started (or on teardown).
    @State private var loadTimeoutTask: Task<Void, Never>?

    /// Hero band height: a touch shorter on phones, taller on the Mac — matches `iOSDetailView`.
    static var heroHeight: CGFloat {
        #if os(macOS)
        return 460
        #else
        return 320
        #endif
    }

    /// How far the first row beneath the hero tucks UP into the hero's lower, faded band, so content
    /// reads as layering under the art (the cinematic "scroll over the backdrop" feel) instead of
    /// starting on a hard edge.
    static let contentOverlap: CGFloat = 72

    private var heroHeight: CGFloat { Self.heroHeight }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Base layer: the still backdrop. Always present, so it stays as the visible art before
            // dwell, between items, and as the silent fallback whenever autoplay can't run.
            backdrop
            // Ambient muted trailer, layered ABOVE the still art but BELOW the scrim + text overlay,
            // and non-interactive so the hero's Play/Trailer buttons and poster taps still work.
            autoplayLayer
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
        // already edge-to-edge — a fixed-height interactive scroll-header.
        // Animate the swap on the hero id — the model already wraps content changes in the matching
        // cross-fade, but keying the container guarantees art + overlay move as one.
        .animation(reduceMotion ? nil : .easeOut(duration: FeaturedHeroModel.heroCrossfade),
                   value: model.hero?.id)
        .platformFullScreenPlayerCover(item: $trailer) { launch in
            TrailerPlayerScreen(launch: launch, onClose: { trailer = nil })
        }
        // Re-evaluate autoplay whenever the featured item changes (rotation advances OR the user
        // pins a new poster). This cancels any pending dwell + tears down the current layer first,
        // so a fast rotation can never start a stale trailer.
        .onChange(of: model.hero?.id) { _ in scheduleAutoplay() }
        // Async enrichment fills `trailerYouTubeID` in place on the SAME hero id, so the id observer
        // above won't re-fire — watch the trailer id too, else the first/static hero never autoplays.
        .onChange(of: model.hero?.trailerYouTubeID) { _ in scheduleAutoplay() }
        // Honor a live Reduce Motion toggle: switching it on immediately drops the autoplay layer.
        .onChange(of: reduceMotion) { _ in scheduleAutoplay() }
        // Arm autoplay for the first settled hero once the view appears.
        .onAppear { scheduleAutoplay() }
        // Stop + remove the autoplay layer when the hero leaves the screen.
        .onDisappear { cancelAutoplay() }
    }

    // MARK: Autoplay layer + lifecycle

    /// The muted, looping trailer playing behind the art — present only for the currently authorized
    /// featured id. Non-interactive so the hero's buttons/poster taps pass through to the layers
    /// below; on any load failure or timeout it removes itself (via `cancelAutoplay`) so the still
    /// backdrop shows through and nothing broken is ever visible.
    @ViewBuilder private var autoplayLayer: some View {
        if let id = autoplayYouTubeID, let embed = mutedLoopingEmbedURL(forYouTubeID: id) {
            AutoplayTrailerWebView(
                url: embed,
                onStarted: { loadTimeoutTask?.cancel(); loadTimeoutTask = nil },
                onFailure: { cancelAutoplay() })
                .frame(height: heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .allowsHitTesting(false)
                .transition(.opacity)
                // Match the still backdrop's gradients so the scrim + text stay readable over video.
                .overlay(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: Theme.Palette.canvas.opacity(0.35), location: 0.5),
                        .init(color: Theme.Palette.canvas.opacity(0.85), location: 0.82),
                        .init(color: Theme.Palette.canvas, location: 1.0),
                    ], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                )
                .overlay(
                    LinearGradient(colors: [Theme.Palette.canvas.opacity(0.6), .clear],
                                   startPoint: .leading, endPoint: .center)
                    .allowsHitTesting(false)
                )
                .id(id)
        }
    }

    /// Cancel any in-flight dwell + timeout and, after `trailerAutoplayDwell`, fade in the muted
    /// trailer for the currently settled hero — but only when motion is allowed AND the hero carries
    /// a playable trailer. The graceful-fallback gate lives here: no trailer (`trailerYouTubeID` nil
    /// or no playable URL) or reduced motion → we never start, the still backdrop stays.
    private func scheduleAutoplay() {
        // Always tear down first: a change must reset to the still backdrop and never stack webviews.
        cancelAutoplay()

        guard !reduceMotion else { return }
        guard let hero = model.hero, let yt = hero.trailerYouTubeID,
              TrailerRequest(title: hero.name, youTubeID: yt, directURL: nil).playableURL != nil
        else { return }

        dwellTask = Task { @MainActor in
            try? await Task.sleep(for: FeaturedHeroModel.trailerAutoplayDwell)
            guard !Task.isCancelled, !reduceMotion,
                  model.hero?.id == hero.id, model.hero?.trailerYouTubeID == yt else { return }
            withAnimation(.easeOut(duration: FeaturedHeroModel.trailerAutoplayFade)) {
                autoplayYouTubeID = yt
            }
            startLoadTimeout()
        }
    }

    /// Watchdog: if the embed never reports it began loading within `trailerAutoplayLoadTimeout`,
    /// treat it as a failure and silently drop back to the still backdrop (no spinner, no black box).
    private func startLoadTimeout() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: FeaturedHeroModel.trailerAutoplayLoadTimeout)
            guard !Task.isCancelled else { return }
            cancelAutoplay()
        }
    }

    /// Stop + remove the autoplay layer immediately and cancel both timers. Resets to the still
    /// backdrop. Called on item change, disappear, reduced-motion, load failure, and timeout.
    private func cancelAutoplay() {
        dwellTask?.cancel(); dwellTask = nil
        loadTimeoutTask?.cancel(); loadTimeoutTask = nil
        if autoplayYouTubeID != nil {
            if reduceMotion {
                autoplayYouTubeID = nil
            } else {
                withAnimation(.easeOut(duration: FeaturedHeroModel.trailerAutoplayFade)) {
                    autoplayYouTubeID = nil
                }
            }
        }
    }

    // MARK: Backdrop (full-bleed art + dual scrim, lifted from iOSHeroBackdrop / iOSDetailView.backdrop)

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
