import SwiftUI

/// In-hero auto-play trailer for the iOS / iPad / Mac detail page and Home billboard (#44). It plays a
/// libmpv-playable trailer URL: a DIRECT (non-YouTube) trailer stream, or the server's `/yt/{id}` resolver
/// URL (owner FINAL architecture: the FULL trailer resolved on demand through the app's own server route and
/// played NATIVELY, the same path our YouTube URL playback uses). The muted ambient loop is now that same
/// full `/yt` trailer; the retired R2 `/clip` billboard snippet is gone (owner directive).
/// This is the PRIMARY iOS/Mac hero-trailer path on every server-capable build; the WKWebView IFrame twin
/// (`InHeroYouTubeTrailerView`) is only the Lite/no-server fallback. (The tvOS twin `TVInHeroTrailerView` is
/// the only libmpv hero-clip path on its platform, since tvOS has no web view.)
///
/// A muted, looping, chromeless libmpv layer fades in OVER the still backdrop a short beat after the hero
/// settles. The still art underneath is the permanent fallback, so a missing / slow / blocked clip never
/// leaves the band black.
///
/// Two loop modes (matching tvOS): pass `window` for a short SILENT WINDOW (the DETAIL hero shows a brief
/// snippet), or leave it nil for the whole muted trailer on a built-in `loop-file=inf` loop (the HOME
/// featured hero). The same view serves both so the home + detail heroes share one decorative libmpv layer.
///
/// Gating + fallback (mirrors tvOS exactly):
///   • The caller gates on the `stremiox.autoplayTrailers` setting + `accessibilityReduceMotion`, and only
///     mounts this view when a trailer's `playableURL` resolved, so reduced-motion / setting-off / no-server
///     never starts a clip.
///   • The clip plays only when the embedded server is reachable (checked async on appear). On the Lite
///     build there is no `/yt` route, so `TrailerRequest.playableURL` is nil and the caller never builds
///     this view: it cleanly no-ops to the still backdrop.
///   • If libmpv reports a load failure (`endFileError`, e.g. resolution failed), the clip hides and the
///     still backdrop stays. No error is ever surfaced.
///
/// Lifecycle: a dedicated lightweight libmpv `Coordinator` is created per mounted instance and torn down
/// when the view disappears. Keyed on the trailer URL so rotating A -> B rebuilds the layer for B rather
/// than painting A's clip over B's backdrop.
struct InHeroTrailerView: View {
    /// The resolved trailer playable URL ({serverBase}/yt/{id} or a direct stream). The caller guarantees
    /// it is non-nil (so the Lite build, where it is nil, never reaches here).
    let url: URL
    /// The hero band height the clip must fill, matched to the backdrop so the cross-fade is seamless.
    let height: CGFloat

    /// When set, play a short SILENT WINDOW instead of the whole trailer: seek to `start` on reveal and
    /// re-seek back to `start` every time playback passes `start + length`, so the band shows a brief
    /// ambient snippet that loops. The detail hero uses this. When nil, the whole trailer loops via mpv's
    /// own `loop-file=inf` (the HOME hero uses that, full muted trailer).
    var window: (start: Double, length: Double)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A muted, looping libmpv instance for the ambient clip. Owned here so it is created and torn down with
    /// the view, never shared with the main player's coordinator.
    @StateObject private var coordinator = MPVMetalPlayerView.Coordinator()

    /// Flips true once the clip has actually started decoding AND the start-delay beat has passed, which
    /// cross-fades it in over the still backdrop. Gating the reveal on real playback means a clip that never
    /// loads (offline server, resolver miss) simply never appears, leaving the still art.
    @State private var showClip = false
    /// True once libmpv produced its first frame / time-pos, so we only reveal a clip that actually plays.
    @State private var didStart = false
    /// Set if libmpv reports a load failure: keeps the clip hidden so the still backdrop stays visible
    /// instead of a frozen black surface.
    @State private var failed = false
    /// Set after the async reachability probe confirms the embedded server is up. The clip is only mounted
    /// when the server is online (a YouTube `/yt` trailer needs the server to resolve it).
    @State private var serverReady = false
    /// Gate so the start-delay beat is armed exactly once per mounted URL.
    @State private var startedDelay = false

    /// How long the still backdrop holds before the muted clip dissolves in. Kept short (owner: the clip must
    /// start within ~1s); the reveal is still gated on the clip actually decoding a frame, so a slow/failed
    /// clip never flashes. (Was 3s, which - stacked on the old server probe - felt sluggish.)
    private static let startDelay: Duration = .milliseconds(400)
    /// Cross-fade duration for the clip reveal.
    private static let fadeDuration: Double = 0.6

    /// A loopback URL (the in-process `/yt` resolver) needs the embedded server up; a remote URL (the public
    /// `trailer.vortx.tv/yt` resolver or a direct stream) does not, so it can mount immediately.
    private var isLoopbackURL: Bool {
        let host = (url.host ?? "").lowercased()
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    var body: some View {
        ZStack {
            if serverReady, !failed {
                // The muted, looping libmpv surface. Opacity-gated (not conditionally mounted) so the
                // player keeps decoding behind the scrim while we wait for the start-delay beat; revealing
                // it is a pure cross-fade with no reload.
                MPVMetalPlayerView(coordinator: coordinator)
                    .play(url)
                    // Windowed mode does its OWN re-seek loop in the property handler, so it must NOT
                    // hand mpv `loop-file=inf` (that would replay the whole trailer). Full mode keeps
                    // mpv's built-in inf loop. Muted either way: a silent ambient clip.
                    .muted(true, loop: window == nil)
                    .videoFill(true)   // fill the WHOLE hero band, never a small letterboxed box (owner ask)
                    .onPropertyChange { engine, name, data in handleProperty(engine, name, data) }
                    .allowsHitTesting(false)   // ambient: never in the tap path
                    .opacity(showClip ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: Self.fadeDuration), value: showClip)
                    .overlay(scrim)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        // Rebuild the whole layer (new coordinator, restarted delay) when the trailer changes, so A's clip
        // never lingers over B's backdrop.
        .id(url)
        .task(id: url) {
            // Reset state for the (possibly new) URL.
            serverReady = false
            showClip = false
            didStart = false
            failed = false
            startedDelay = false
            // A REMOTE url (the public trailer.vortx.tv/yt resolver or a direct CDN stream) does NOT need the
            // embedded server, so mount it IMMEDIATELY. Only a loopback /yt URL (resolved by the in-process
            // server) waits on the reachability probe. iOS previously gated even remote clips on the localhost probe, adding 0-4s of
            // start latency; tvOS already scopes this to loopback - this ports that fix (owner: start < 1s).
            if isLoopbackURL {
                if await StremioServer.isOnline() { serverReady = true }
            } else {
                serverReady = true
            }
        }
        // Decorative ambient layer; the hero title / actions carry the accessible content.
        .accessibilityHidden(true)
    }

    /// The same dual scrim the hero backdrop uses, so the title / meta stay legible over video and the band
    /// reads consistently whether the still art or the clip is showing.
    private var scrim: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Theme.Palette.canvas.opacity(0.35), location: 0.55),
                .init(color: Theme.Palette.canvas.opacity(0.85), location: 0.85),
                .init(color: Theme.Palette.canvas, location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [Theme.Palette.canvas.opacity(0.6), .clear],
                           startPoint: .leading, endPoint: .center)
        }
        .allowsHitTesting(false)
    }

    /// libmpv property bus: reveal the clip once it actually starts, hide it on a load failure, and (in
    /// windowed mode) re-seek so only a short snippet loops. Full mode lets mpv's own `loop-file=inf`
    /// handle repetition, so EOF never reaches here.
    private func handleProperty(_ engine: any PlayerEngine, _ name: String, _ data: Any?) {
        switch name {
        case MPVProperty.timePos:
            // First decoded time-pos means the clip really started; seek into the window (if any) and
            // arm the reveal beat exactly once.
            if !didStart {
                didStart = true
                if let window { engine.seek(to: window.start) }
                armReveal()
            }
            // Windowed mode: keep the snippet looping by re-seeking to the start once playback runs past
            // the window. A small guard band absorbs the time-pos event granularity so we never thrash.
            if let window, let pos = data as? Double, pos >= window.start + window.length {
                engine.seek(to: window.start)
            }
        case MPVProperty.endFileError:
            // Resolution failed / dead link: hide the clip so the still backdrop shows. Never an error flash.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { failed = true }
        default:
            break
        }
    }

    /// Hold the still backdrop for the start-delay beat after the clip starts, then cross-fade it in. Once
    /// per mounted URL (guarded by `startedDelay`).
    private func armReveal() {
        guard !startedDelay else { return }
        startedDelay = true
        Task { @MainActor in
            try? await Task.sleep(for: Self.startDelay)
            guard !failed else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: Self.fadeDuration)) { showClip = true }
        }
    }
}
