import SwiftUI

struct CinemaNavigationHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The floating top navigation's height on Mac and wide iPad; zero where there is none (phone, TV).
private struct CinemaNavigationArtworkInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var cinemaNavigationArtworkInset: CGFloat {
        get { self[CinemaNavigationArtworkInsetKey.self] }
        set { self[CinemaNavigationArtworkInsetKey.self] = newValue }
    }
}

/// A hero is a self-contained rounded media card whose artwork stays inside its own viewport.
enum CinemaHeroCardGeometry {
    static let inset: CGFloat = 16
    static let radius: CGFloat = 28
    static func innerWidth(viewport: CGFloat) -> CGFloat { max(1, viewport - inset * 2) }
}

private struct CinemaHeroCardTreatment: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CinemaHeroCardGeometry.radius, style: .continuous)
        content
            .background(shape.fill(Theme.Palette.accent.opacity(reduceTransparency ? 0.022 : 0.045)))
            .overlay {
                LinearGradient(colors: [Theme.Palette.accent.opacity(0.075), .clear,
                                         Theme.Palette.accent.opacity(0.018)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(shape).allowsHitTesting(false)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.Palette.accent.opacity(reduceTransparency ? 0.24 : 0.16), lineWidth: 0.8)
                .allowsHitTesting(false))
            .shadow(color: .black.opacity(0.32), radius: 20, y: 12)
    }
}

extension View {
    func cinemaHeroCard() -> some View { modifier(CinemaHeroCardTreatment()) }
}

/// Floating top navigation. The bar is a top safe-area inset, so screens still start their controls
/// beneath it, while scroll views run underneath and stay visible through it at every scroll position.
struct CinemaNavigationShell<Navigation: View, Content: View>: View {
    let navigation: Navigation
    let content: Content

    init(@ViewBuilder navigation: () -> Navigation, @ViewBuilder content: () -> Content) {
        self.navigation = navigation()
        self.content = content()
    }

    var body: some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(CinemaFloatingNavigationBar(navigation: navigation))
    }
}

/// OS 26 hands the bar to the system, which softly blurs whatever scrolls beneath it (the iOS bar
/// treatment). Older systems and Reduce Transparency draw their own backdrop instead.
private struct CinemaFloatingNavigationBar<Navigation: View>: ViewModifier {
    let navigation: Navigation
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *), !reduceTransparency {
            content
                .safeAreaBar(edge: .top, spacing: 0) { navigation }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                navigation.background { CinemaNavigationBackdrop(reduceTransparency: reduceTransparency) }
            }
        }
    }
}

/// Pre-26 backdrop: material that fades out at its lower edge, so content dissolves under the bar
/// rather than meeting a hard line. Reduce Transparency keeps a near-opaque canvas for legibility.
private struct CinemaNavigationBackdrop: View {
    let reduceTransparency: Bool

    var body: some View {
        Group {
            if reduceTransparency {
                Theme.Palette.canvas.opacity(0.94)
            } else {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Theme.Palette.canvas.opacity(0.35))
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7),
                                                 .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            }
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
