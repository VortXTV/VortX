import SwiftUI

/// In-hero auto-play trailer for the **tvOS** detail page (#44), the parity twin of the iOS / iPad / Mac
/// `InHeroTrailerView`. tvOS has no WKWebView, so the YouTube IFrame embed the touch surfaces use cannot
/// run here; this plays whatever DIRECT URL it is handed through **libmpv**. NOTE: tokenless YouTube
/// extraction is dead, so `TrailerRequest.playableURL` now yields only a direct (non-YouTube) stream here
/// (the dead `/yt` route was removed); a YouTube-only trailer has no URL and the layer simply never mounts
/// (still backdrop stays) until the `trailer.vortx.tv` resolver lands. See TrailerRequest.swift.
///
/// A muted, looping, chromeless libmpv layer fades in OVER the still backdrop a short beat after the hero
/// appears, the same ambient treatment iOS gives. The still art underneath is the permanent fallback, so a
/// missing / slow / blocked clip never leaves the band black.
///
/// Two loop modes (the owner's clip-scope answer): pass `window` for a short SILENT WINDOW (the DETAIL hero
/// shows a ~8s snippet, the parity of the iOS detail's `.clip(start:window:)`), or leave it nil for the whole
/// muted trailer on a built-in `loop-file=inf` loop (the HOME featured hero). The same view serves both so
/// the home + detail heroes share one decorative libmpv layer.
///
/// Gating + fallback (mirrors iOS exactly):
///   • The caller gates on the `stremiox.autoplayTrailers` setting + `accessibilityReduceMotion`, and only
///     mounts this view when a trailer exists, so reduced-motion / setting-off never starts a clip.
///   • The clip plays only when the embedded server is reachable (checked async on appear). On the Lite
///     build (`STREMIOX_NO_EMBEDDED_SERVER`) there is no `/yt` route, so `TrailerRequest.playableURL` is
///     nil and the caller never builds this view — it cleanly no-ops to the still backdrop.
///   • If libmpv reports a load failure (`endFileError`, e.g. ytdl extraction failed), the clip hides and
///     the still backdrop stays.
///
/// tvOS focus / RemoteCatcher invariant: this layer is purely decorative. It is NON-focusable, takes no
/// hit-testing, and holds no `@FocusState`, so it never enters the focus path or competes with the player's
/// focus engine. The hero's title / actions remain the focusable, accessible content.
///
/// Lifecycle: a dedicated lightweight libmpv `Coordinator` is created per mounted instance and torn down
/// when the view disappears (SwiftUI dismantles `MPVMetalPlayerView`, which calls `stop()`), so the preview
/// never leaks a player or holds the streaming server busy. Keyed on the trailer URL so navigating A -> B
/// rebuilds the layer for B rather than painting A's clip over B's backdrop.
struct TVInHeroTrailerView: View {
    /// The resolved trailer playable URL ({serverBase}/yt/{id} or a direct stream). The caller guarantees
    /// it is non-nil (so the Lite build, where it is nil, never reaches here).
    let url: URL

    /// When set, play a short SILENT WINDOW instead of the whole trailer: seek to `start` on reveal and
    /// re-seek back to `start` every time playback passes `start + length`, so the band shows a brief
    /// ambient snippet that loops. The detail hero uses this (owner: detail = short window). When nil,
    /// the whole trailer loops via mpv's own `loop-file=inf` (the HOME hero uses that, full muted trailer).
    var window: (start: Double, length: Double)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A muted, looping libmpv instance for the ambient clip. Owned here so it is created and torn down with
    /// the view, never shared with the main player's coordinator.
    @StateObject private var coordinator = MPVMetalPlayerView.Coordinator()

    /// Flips true once the clip has actually started decoding AND the start-delay beat has passed, which
    /// cross-fades it in over the still backdrop. Gating the reveal on real playback means a clip that never
    /// loads (offline server, ytdl miss) simply never appears, leaving the still art.
    @State private var showClip = false
    /// True once libmpv produced its first frame / time-pos, so we only reveal a clip that actually plays.
    @State private var didStart = false
    /// Set if libmpv reports a load failure: keeps the clip hidden so the still backdrop stays visible
    /// instead of a frozen black surface.
    @State private var failed = false
    /// Set after the async reachability probe confirms the embedded server is up. The clip is only mounted
    /// when the server is online (a YouTube `/yt` trailer needs the server to resolve via ytdl-core).
    @State private var serverReady = false
    /// Gate so the start-delay beat is armed exactly once per mounted URL.
    @State private var startedDelay = false

    /// Seconds the still backdrop holds before the muted clip dissolves in, matched to the iOS detail beat.
    /// A detail page is a destination, so the trailer eases in rather than slamming on appear.
    private static let startDelay: Duration = .seconds(2.5)
    /// Cross-fade duration for the clip reveal.
    private static let fadeDuration: Double = 0.6

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
                    .onPropertyChange { engine, name, data in handleProperty(engine, name, data) }
                    .allowsHitTesting(false)   // ambient: never in the focus / hit path
                    .opacity(showClip ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: Self.fadeDuration), value: showClip)
                    .overlay(scrim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Rebuild the whole layer (new coordinator, restarted delay) when the trailer changes, so A's clip
        // never lingers over B's backdrop.
        .id(url)
        .task(id: url) {
            // Reset state for the (possibly new) URL, then confirm the server is reachable before mounting.
            // On a custom/offline server or a slow boot this stays false and the still backdrop holds.
            serverReady = false
            showClip = false
            didStart = false
            failed = false
            startedDelay = false
            if await StremioServer.isOnline() {
                serverReady = true
            }
        }
        // Decorative ambient layer; the hero title / actions carry the accessible content.
        .accessibilityHidden(true)
    }

    /// The same dual scrim the tvOS `FullBleedBackdrop` uses, so the title / meta stay legible over video
    /// and the band reads consistently whether the still art or the clip is showing.
    private var scrim: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Theme.Palette.canvas.opacity(0.18), location: 0.50),
                .init(color: Theme.Palette.canvas.opacity(0.55), location: 0.78),
                .init(color: Theme.Palette.canvas.opacity(0.88), location: 1.0),
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
            // ytdl extraction failed / dead link: hide the clip so the still backdrop shows.
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
