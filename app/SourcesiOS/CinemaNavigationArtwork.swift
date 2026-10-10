import SwiftUI
import CoreGraphics
import QuartzCore

/// The shell only borrows an immutable image already accepted by the visible hero's loader.
/// A title/route change publishes nil immediately; no shell request, decode or scroll observer exists.
struct CinemaNavigationArtwork: Equatable {
    let owner: String
    let identity: String
    let image: CGImage
    let height: CGFloat
    let contentMode: ContentMode
    let panEpoch: CFTimeInterval?
    let reduceMotion: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner == rhs.owner && lhs.identity == rhs.identity && lhs.image === rhs.image
            && lhs.height == rhs.height && lhs.contentMode == rhs.contentMode
            && lhs.panEpoch == rhs.panEpoch && lhs.reduceMotion == rhs.reduceMotion
    }
}

struct CinemaNavigationArtworkKey: PreferenceKey {
    static var defaultValue: CinemaNavigationArtwork? { nil }
    static func reduce(value: inout CinemaNavigationArtwork?, nextValue: () -> CinemaNavigationArtwork?) {
        if let next = nextValue() { value = next }
    }
}

struct CinemaNavigationHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct CinemaNavigationArtworkInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct CinemaNavigationArtworkOwnerKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var cinemaNavigationArtworkInset: CGFloat {
        get { self[CinemaNavigationArtworkInsetKey.self] }
        set { self[CinemaNavigationArtworkInsetKey.self] = newValue }
    }
    var cinemaNavigationArtworkOwner: String {
        get { self[CinemaNavigationArtworkOwnerKey.self] }
        set { self[CinemaNavigationArtworkOwnerKey.self] = newValue }
    }
}

/// Both slices use the same expanded image rectangle. The menu retains real layout space;
/// only the decorative image continues upward across that space.
enum CinemaArtworkGeometry {
    static func expandedHeight(band: CGFloat, navigation: CGFloat) -> CGFloat {
        max(0, band) + max(0, navigation)
    }
}

/// The decorative continuation cannot change this layout reservation or the controls' viewport.
struct CinemaNavigationReservedShell<Navigation: View, Content: View>: View {
    let navigation: Navigation
    let content: Content

    init(@ViewBuilder navigation: () -> Navigation, @ViewBuilder content: () -> Content) {
        self.navigation = navigation()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            navigation
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CinemaHeroDissolve: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .white, location: 0),
            .init(color: .white, location: 0.68),
            .init(color: .white.opacity(0.72), location: 0.86),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

struct CinemaNavigationArtworkStrip: View {
    let artwork: CinemaNavigationArtwork?
    let reduceTransparency: Bool
    let highContrast: Bool

    var body: some View {
        ZStack {
            Theme.Palette.canvas
            if let artwork {
                CinemaNavigationArtworkLayerHost(artwork: artwork)
                    .id("\(artwork.owner):\(artwork.identity)")
                // Keep the full wordmark, capsule, profile and search chrome legible, while
                // retaining the same leading scrim as the adjoining hero image.
                LinearGradient(colors: [Theme.Palette.canvas.opacity(0.5), .clear],
                               startPoint: .leading, endPoint: .center)
                Theme.Palette.canvas.opacity(reduceTransparency || highContrast ? 0.60 : 0.45)
            } else {
                Theme.Palette.accent.opacity(HomeAtmospherePolicy.alpha(
                    reduceTransparency: reduceTransparency, highContrast: highContrast))
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
