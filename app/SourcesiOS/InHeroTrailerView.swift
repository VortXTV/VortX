import SwiftUI

/// In-hero auto-play trailer for the iOS / iPad / Mac detail page (#44). The static `meta.background`
/// backdrop renders first; a short beat later this view cross-fades a muted, looping YouTube clip OVER
/// that backdrop, the same ambient treatment the Home `FeaturedHeroView` uses. The still art underneath
/// is the permanent fallback, so a missing / slow / blocked clip never leaves the band black.
///
/// Why a delay (`startDelay`): the detail hero exists to show the artwork and let the user read the
/// title / meta first. Slamming a video in on appear fights that. Holding the still backdrop for ~2.5s
/// before the clip dissolves in keeps the page calm and gives slow networks a moment, while the muted
/// clip still rewards anyone who lingers. The Home billboard plays immediately because it is an ambient
/// rotator; a detail page is a destination, so it eases in.
///
/// Mute / unmute: the clip is muted (the only reliably-allowed inline autoplay on iOS / WKWebView). A
/// speaker control sits in the corner; tapping the clip OR the control escalates to the full interactive
/// trailer via `onRequestSound`, which the detail page wires to its existing in-app `TrailerEmbedCover`
/// (full YouTube controls + audio). This reuses the one trailer-with-sound path the app already ships
/// rather than poking JS mute state into the shared embed.
///
/// Reduced-motion: the caller gates on `accessibilityReduceMotion` and simply never mounts this view
/// when motion is reduced, so the hero stays a still backdrop. The view itself is decorative and hidden
/// from VoiceOver; the title / meta / actions carry the accessible content.
///
/// tvOS has no WKWebView, so this lives in `SourcesiOS/` (iOS / iPad / Mac only) and is never built for tvOS.
struct InHeroTrailerView: View {
    /// The resolved YouTube id to play (caller guarantees non-empty).
    let youTubeID: String
    /// The hero band height the clip must fill, matched to the backdrop so the cross-fade is seamless.
    let height: CGFloat
    /// Escalate to the full interactive trailer (sound + controls). Wired to the detail page's in-app
    /// `TrailerEmbedCover` presentation.
    let onRequestSound: () -> Void

    /// Flips true after `startDelay`, which cross-fades the clip in over the still backdrop.
    @State private var showClip = false
    /// Set if the embed reports a failure (embedding disabled, removed video, etc.). Keeps the clip
    /// hidden so the still backdrop underneath stays visible instead of YouTube's error card.
    @State private var failed = false

    /// Seconds the still backdrop holds before the muted clip dissolves in (the "~2-3s after the hero
    /// backdrop shows" beat). A named constant, not a magic number.
    private static let startDelay: Duration = .seconds(2.5)
    /// Cross-fade duration for the clip reveal, matched to the hero's own art cross-fade feel.
    private static let fadeDuration: Double = 0.6

    var body: some View {
        ZStack {
            if showClip, !failed {
                clip
                    .transition(.opacity)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        // Reload the whole view (and restart the delay) when the title changes, so navigating A -> B
        // never leaves A's clip painted over B's backdrop.
        .id(youTubeID)
        .task(id: youTubeID) {
            // Reset for the new title, then hold the still backdrop before easing the clip in.
            showClip = false
            failed = false
            try? await Task.sleep(for: Self.startDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Self.fadeDuration)) { showClip = true }
        }
        // Decorative ambient layer. The hero's title / meta / actions are the accessible content.
        .accessibilityHidden(true)
    }

    /// The muted, looping, chromeless clip plus the same dual scrim the backdrop uses (so the title /
    /// meta stay legible over video and the band still dissolves into the page below), an "Unmute" speaker
    /// affordance, and a full-surface tap target that opens the trailer with sound.
    private var clip: some View {
        // A short ~6-second muted window (started a few seconds in to skip studio/title cards) rather than
        // the full trailer: a quick, ambient "clip" of the title that loops behind the hero art.
        YouTubeEmbedView(youTubeID: youTubeID, mode: .clip(startSeconds: 8, windowSeconds: 6),
                         onFailure: { withAnimation(.easeOut(duration: 0.3)) { failed = true } })
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipped()
            // The embed is ambient: let taps fall through to our own tap layer (below) and to the hero
            // chrome, exactly as the Home hero clip does.
            .allowsHitTesting(false)
            .overlay(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: Theme.Palette.canvas.opacity(0.35), location: 0.55),
                    .init(color: Theme.Palette.canvas.opacity(0.85), location: 0.85),
                    .init(color: Theme.Palette.canvas, location: 1.0),
                ], startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                LinearGradient(colors: [Theme.Palette.canvas.opacity(0.6), .clear],
                               startPoint: .leading, endPoint: .center)
            )
            // A transparent tap layer over the clip: tapping the playing trailer is the natural "give me
            // sound" gesture, so route it to the full interactive trailer. Placed under the visible speaker
            // button so the button keeps its own larger hit target.
            .overlay(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onRequestSound() }
            )
            .overlay(alignment: .topTrailing) { unmuteButton }
    }

    /// The corner speaker affordance. The clip is muted; this signals that and offers the one-tap path to
    /// audio (the full interactive trailer). Styled as the same circular glass control the trailer cover's
    /// close button uses, so the two read as one family.
    private var unmuteButton: some View {
        Button(action: onRequestSound) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(Theme.Space.sm)
        .accessibilityLabel("Play trailer with sound")
    }
}
