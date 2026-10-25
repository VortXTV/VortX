import SwiftUI

/// Shared, decorative pre-start layer. Existing spinner/status, error, controls and escape routes stay above it.
/// Artwork never delays playback: removing this view cancels its existing finite logo/poster loader tasks.
struct PlayerFirstFrameArtwork: View {
    let visible: Bool
    let id: String?
    let type: String
    let title: String
    let poster: String?
    @ReducedMotion private var reduceMotion

    private var maxPixel: CGFloat {
        #if os(tvOS)
        return CGFloat(HeroArtworkQualityPolicy.fullHDLongEdge)
        #else
        return CGFloat(HeroArtworkQualityPolicy.mobileLongEdge)
        #endif
    }

    private var resolvedPoster: String? {
        guard let id else { return poster }
        return PosterArtwork.poster(id: id, fallback: poster)
    }

    var body: some View {
        ZStack {
            if visible {
                GeometryReader { geometry in
                    ZStack(alignment: .top) {
                        Color.black
                        // Existing provider precedence/signing/cache/decoding; one still, never a trailer or timer.
                        FallbackArtwork(urls: [resolvedPoster, poster], maxPixel: maxPixel)
                            .opacity(0.32)
                        LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.72)],
                                       startPoint: .top, endPoint: .bottom)
                        ResolvedTitleLogo(id: id, type: type,
                                          fallbackLogo: PosterArtwork.metahubLogo(forID: id),
                                          maxWidth: min(geometry.size.width * 0.72, 480),
                                          maxHeight: min(geometry.size.height * 0.20, 160),
                                          accessibilityName: title) {
                            Text(title)
                                .font(Theme.Typography.hero)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.65)
                        }
                        // Leave the existing centered spinner/status and both bars unobstructed.
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, max(24, geometry.size.height * 0.15))
                    }
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: visible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
