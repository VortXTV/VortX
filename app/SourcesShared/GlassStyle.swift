import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// VortX "liquid glass": the warm-dark floating-chrome material from the approved redesign mockups.
///
/// It is a CUSTOM material that renders the same on every OS version and platform: a translucent
/// warm-dark fill over a blur, a 1px top-highlight border, and a soft drop shadow. Where Apple's real
/// Liquid Glass exists (iOS / tvOS / macOS 26), that becomes the blur layer, so the look only UPGRADES
/// on newer systems, it never diverges: the warm tint, top highlight, ember active state, and shadow are
/// VortX's own and ride ON TOP of whichever blur renders. Under Reduce Transparency the whole thing stands
/// down to an opaque warm surface so the chrome stays legible.
///
/// Belongs on chrome that floats OVER content: the floating nav bar / pill and its round icon buttons. It
/// is deliberately NOT for scrolling content, poster art, or opaque backgrounds (those keep the flat warm
/// surfaces in `Theme.Palette`). This is the shared Phase A primitive; it complements Theme.swift's
/// `glassChrome` OS-26 gate (which swaps the whole material) by keeping VortX's identity layers on top.
///
/// See DESIGN.md ("Radius & Elevation") and the redesign mockups for the visual target.
enum VortXGlass {

    // MARK: Tokens (single source of truth, shared by the SwiftUI material and the tvOS UIKit tab bar)

    /// The warm near-black glass fill (mockups: `rgba(20,17,16,~.5)`). Fixed sRGB, NOT the user-themeable
    /// `canvas`, so the glass reads warm even under the OLED true-black chrome setting, staying a
    /// stable identity surface, not the app background.
    private static let fillRGB = (r: 0.078, g: 0.067, b: 0.063)   // ≈ #141110

    /// The warm-dark translucent glass fill at a given alpha.
    static func fill(_ alpha: Double) -> Color {
        Color(.sRGB, red: fillRGB.r, green: fillRGB.g, blue: fillRGB.b, opacity: alpha)
    }

    /// Default fill alphas per surface, matching the mockups (bar ~.55, pill/field ~.5).
    static let barFillAlpha = 0.55
    static let pillFillAlpha = 0.50

    /// The 1px edge treatment: a bright top highlight (`inset 0 1px 0 rgba(255,255,255,~.12)`) fading into
    /// a faint warm hairline border (`1px solid rgba(242,236,226,~.14)`) toward the bottom. One gradient
    /// stroke reads as both, so a single `strokeBorder` gives the mockups' lit top edge.
    static func highlight(_ top: Double = 0.14) -> LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(top),
                Color(.sRGB, red: 0.949, green: 0.925, blue: 0.886, opacity: top * 0.42)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// The ember active/selected fill for a nav item (mockups: `rgba(245,158,11,.16)`). Uses the themeable
    /// accent so a chosen accent flows through, exactly like the rest of the selection language.
    static var activeFill: Color { Theme.Palette.accent.opacity(0.16) }

    // MARK: Shadow presets (soft drop shadow under a FLOATING element)

    struct Shadow {
        var color: Color
        var radius: CGFloat
        var y: CGFloat
        static let bar = Shadow(color: .black.opacity(0.50), radius: 22, y: 14)   // floating tab bar / nav pill
        static let pill = Shadow(color: .black.opacity(0.45), radius: 16, y: 8)   // smaller floating pill / field
        static let disc = Shadow(color: .black.opacity(0.35), radius: 12, y: 6)   // round icon button
    }

    #if canImport(UIKit)
    /// The glass fill as a `UIColor`, so the tvOS native `UITabBarAppearance` (which cannot host a SwiftUI
    /// material) can tint its system-blurred background with the SAME warm fill the SwiftUI material uses.
    static func fillUIColor(_ alpha: Double) -> UIColor { UIColor(fill(alpha)) }
    #endif
}

// MARK: - The reusable SwiftUI material

/// Renders the VortX glass as a `background` behind its content: blur layer + warm tint + top highlight +
/// soft shadow, in the given `shape`. Availability-gated so OS 26 uses real Liquid Glass as the blur while
/// older systems use `.ultraThinMaterial`; Reduce Transparency drops both for an opaque warm surface.
private struct VortXGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let fillAlpha: Double
    let highlightTop: Double
    let shadow: VortXGlass.Shadow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background { glass }
    }

    private var glass: some View {
        ZStack {
            blur
            // The warm-dark VortX tint over the blur is what makes Apple's neutral Liquid Glass read as
            // VortX chrome. Skipped under Reduce Transparency, where `blur` is already an opaque warm fill.
            if !reduceTransparency {
                shape.fill(VortXGlass.fill(fillAlpha))
            }
        }
        // 1px lit top edge / hairline border.
        .overlay { shape.strokeBorder(VortXGlass.highlight(highlightTop), lineWidth: 1) }
        // Flatten first so the soft drop shadow is cast by the whole glass silhouette, then float it.
        .compositingGroup()
        .shadow(color: shadow.color, radius: shadow.radius, x: 0, y: shadow.y)
    }

    @ViewBuilder private var blur: some View {
        if reduceTransparency {
            // No blur when transparency is reduced: an opaque warm surface keeps the chrome legible.
            shape.fill(Theme.Palette.surface1)
        } else if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
            // Real Apple Liquid Glass as the blur (the same idiom as the existing player chrome), upgraded
            // in place. VortX's tint + highlight + shadow still layer on top, so identity is preserved.
            shape.fill(.clear).glassEffect(.regular, in: shape)
        } else {
            // Custom material on every older OS: the frosted blur that carries the warm tint above.
            shape.fill(.ultraThinMaterial)
        }
    }
}

extension View {
    /// Apply the VortX floating-glass material in `shape` (the Phase A nav-chrome primitive). Renders the
    /// same warm glass on every OS/platform and upgrades to real Liquid Glass on OS 26. `fillAlpha` /
    /// `highlight` / `shadow` tune it per surface (defaults suit a floating bar or pill).
    func vortxGlass<S: InsettableShape>(
        in shape: S,
        fillAlpha: Double = VortXGlass.barFillAlpha,
        highlight: Double = 0.14,
        shadow: VortXGlass.Shadow = .bar
    ) -> some View {
        modifier(VortXGlassModifier(shape: shape, fillAlpha: fillAlpha, highlightTop: highlight, shadow: shadow))
    }

    /// The ember active/selected variant for a nav item: fills `shape` with the accent-soft ember when
    /// `active`, nothing when not. One definition so every platform's selected tab/pill reads identically.
    @ViewBuilder func vortxGlassActive<S: InsettableShape>(_ active: Bool, in shape: S) -> some View {
        background { if active { shape.fill(VortXGlass.activeFill) } }
    }
}
