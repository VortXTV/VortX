import SwiftUI

/// H3 / A6 FALLBACK: the muted, looping, chromeless in-hero FULL trailer for the iOS / iPad / Mac detail page,
/// played via the keyless YouTube IFrame embed (`YouTubeEmbedView` in `.background` mode). This is the iOS/Mac
/// LAST-RESORT hero path used ONLY when the native `/yt` resolver is unavailable (the Lite build has no
/// embedded server, so `InHeroTrailerView` cannot mount its loopback `/yt` URL). Per the owner FINAL
/// architecture the PRIMARY detail-hero path is the native `/yt` resolver through `InHeroTrailerView`
/// (libmpv/AVPlayer); this WKWebView twin only runs where that server is absent, and never on tvOS.
///
/// The still backdrop underneath (owned by the hero) is the permanent fallback: this view fades itself in a
/// beat after mount, and on any embed failure (owner disabled embedding, removed video, IFrame error) it hides
/// itself via `onFailure`, so the still art always shows through. Decorative and never in the tap path.
///
/// The whole layer is keyed on the YouTube id by the caller (`.id(...)`), so rotating A -> B rebuilds the
/// embed for B rather than leaving A's trailer over B's backdrop.
struct InHeroYouTubeTrailerView: View {
    /// The YouTube id of the FULL trailer to loop muted.
    let youTubeID: String
    /// The hero band height the clip must fill, matched to the backdrop so the cross-fade is seamless.
    let height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Flips true a short beat after mount so the still backdrop holds briefly, then the muted trailer
    /// cross-fades in. Gated so a slow/blocked embed never flashes.
    @State private var showClip = false
    /// Set if the embed reports it cannot play: keeps the clip hidden so the still backdrop stays visible.
    @State private var failed = false

    /// How long the still backdrop holds before the muted trailer dissolves in (matches `InHeroTrailerView`).
    private static let startDelay: Duration = .milliseconds(400)
    private static let fadeDuration: Double = 0.6

    var body: some View {
        ZStack {
            if !failed {
                // COVER-FILL the whole hero band (A3 fill intent for the YouTube path): the YouTube IFrame
                // renders a 16:9 player letterboxed inside its 100%x100% frame, so on a wide Mac band a plain
                // fit would show black bars top/bottom. Size the embed to a 16:9 box that COVERS the band
                // (max of width and 16:9-of-height on each axis), center it, and clip - so the video fills the
                // band edge to edge, cropping the overflow, the same visual result libmpv's panscan gives the
                // /clip path. GeometryReader reads the actual band size at runtime.
                GeometryReader { geo in
                    let coverW = max(geo.size.width, geo.size.height * 16.0 / 9.0)
                    let coverH = max(geo.size.height, geo.size.width * 9.0 / 16.0)
                    YouTubeEmbedView(youTubeID: youTubeID, mode: .background, onFailure: {
                        // Embed can't play: hide so the still backdrop shows. Never an error flash.
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { failed = true }
                    })
                    .frame(width: coverW, height: coverH)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                .allowsHitTesting(false)   // ambient: never in the tap path
                .opacity(showClip ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: Self.fadeDuration), value: showClip)
                .overlay(scrim)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        // Rebuild the layer when the id changes so A's trailer never lingers over B's backdrop.
        .id(youTubeID)
        .task(id: youTubeID) {
            // Reset for the (possibly new) id, then hold the still backdrop for the start-delay beat.
            showClip = false
            failed = false
            try? await Task.sleep(for: Self.startDelay)
            guard !failed else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: Self.fadeDuration)) { showClip = true }
        }
        // Decorative ambient layer; the hero title / actions carry the accessible content.
        .accessibilityHidden(true)
    }

    /// The same dual scrim the hero backdrop uses, so the title / meta stay legible over the trailer and the
    /// band reads consistently whether the still art or the trailer is showing (mirrors `InHeroTrailerView`).
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
}
