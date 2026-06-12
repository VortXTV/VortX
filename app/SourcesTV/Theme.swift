import SwiftUI

/// StremioX design system. One source of truth for color, type, spacing, motion, and the focus
/// treatment, so every tvOS screen reads as one product at ten feet. See DESIGN.md for the rationale.
/// Direction: editorial cinema. Warm near-black chrome so poster art is the only color on screen,
/// one ember accent that means focus / selection / primary / progress, nothing decorative colored.
enum Theme {

    // MARK: Color (warm-neutral chrome + a single ember accent)

    enum Palette {
        private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
            Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
        }
        // Chrome is user-themeable via ThemeManager (warm near-black by default, true black on OLED).
        static var canvas: Color   { ThemeManager.shared.canvas }   // app background
        static var surface1: Color { ThemeManager.shared.surface1 } // rows, cards, panels
        static var surface2: Color { ThemeManager.shared.surface2 } // chips, controls
        static var surface3: Color { ThemeManager.shared.surface3 } // hover / selected fill
        static var hairline: Color { ThemeManager.shared.hairline } // dividers only
        static let textPrimary   = rgb(0.965, 0.945, 0.914) // #F6F1E9
        static let textSecondary = rgb(0.737, 0.694, 0.631) // #BCB1A1
        static let textTertiary  = rgb(0.549, 0.510, 0.451) // #8C8273
        // Accent is user-themeable via ThemeManager (8 curated accents). accentSoft / onAccent follow it.
        static var accent: Color { ThemeManager.shared.accent }             // focus / selection / primary / progress
        static var accentBright: Color { ThemeManager.shared.accentBright } // focus glow highlight
        static var accentSoft: Color { accent.opacity(0.18) }
        static var onAccent: Color { rgb(0.106, 0.067, 0.043) } // dark warm ink on the ember fill
        static let danger = rgb(0.851, 0.318, 0.278)            // #D9514C destructive (log out, remove)
    }

    // MARK: Spacing (8pt base, intentional rhythm)

    enum Space {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 20
        static let lg: CGFloat = 32
        static let xl: CGFloat = 48
        static let xxl: CGFloat = 72
        static let screenEdge: CGFloat = 60
    }

    enum Radius {
        static let card: CGFloat = 16
        static let chip: CGFloat = 12
        static let control: CGFloat = 14
    }

    // MARK: Motion

    enum Motion {
        static let focus = Animation.spring(response: 0.32, dampingFraction: 0.78)
        static let state = Animation.easeOut(duration: 0.18)
    }

    // MARK: Typography (system only: New York serif for editorial moments, SF Pro for UI)

    /// User-tunable UI text scale (Settings, Appearance). Read once at launch: live font
    /// changes would need every screen to re-render, so a relaunch applies it, like the
    /// Performance setting. Base sizes sit one step up from the original ramp (field
    /// feedback: UI text read small at ten feet).
    enum TextScale {
        static let key = "stremiox.ui.textScale"
        static let choices: [(id: String, label: String, factor: CGFloat)] = [
            ("s", "Smaller", 0.92), ("m", "Default", 1.0), ("l", "Larger", 1.12),
        ]
        static let current: CGFloat = {
            let id = UserDefaults.standard.string(forKey: key) ?? "m"
            return choices.first { $0.id == id }?.factor ?? 1.0
        }()
    }

    enum Typography {
        private static func scaled(_ size: CGFloat) -> CGFloat { (size * TextScale.current).rounded() }
        static let hero        = Font.system(size: scaled(64), weight: .heavy, design: .serif)
        static let wordmark    = Font.system(size: scaled(38), weight: .bold, design: .serif)
        static let screenTitle = Font.system(size: scaled(53), weight: .heavy)
        static let sectionTitle = Font.system(size: scaled(31), weight: .semibold)
        static let cardTitle   = Font.system(size: scaled(23), weight: .semibold)
        static let body        = Font.system(size: scaled(25), weight: .regular)
        static let label       = Font.system(size: scaled(21), weight: .medium)
        static let eyebrow     = Font.system(size: scaled(16), weight: .bold)
    }
}

// MARK: - Text role helpers (font + tracking + default color in one place)

extension View {
    func eyebrowStyle(_ color: Color = Theme.Palette.textTertiary) -> some View {
        font(Theme.Typography.eyebrow).tracking(1.5).textCase(.uppercase).foregroundStyle(color)
    }
    func sectionTitleStyle() -> some View {
        font(Theme.Typography.sectionTitle).tracking(-0.3).foregroundStyle(Theme.Palette.textPrimary)
    }
    func screenTitleStyle() -> some View {
        font(Theme.Typography.screenTitle).tracking(-1).foregroundStyle(Theme.Palette.textPrimary)
    }
}

// MARK: - Focus treatment (the core tvOS interaction)

/// Crafted card focus: scale + lift + warm ember glow, spring-eased, Reduce-Motion aware.
/// Reads `isFocused` from the enclosing Button (the nearest focusable ancestor).
struct CardFocusStyle: ButtonStyle {
    var scale: CGFloat = 1.08
    func makeBody(configuration: Configuration) -> some View {
        CardFocusContent(configuration: configuration, scale: scale)
    }
}

private struct CardFocusContent: View {
    let configuration: ButtonStyleConfiguration
    let scale: CGFloat
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var theme: ThemeManager   // observe so a theme change repaints this style
    var body: some View {
        let lifted = focused && !reduceMotion
        configuration.label
            .scaleEffect(lifted ? scale : (configuration.isPressed ? 0.97 : 1))
            // Theme-colored halo on focus: an even accent glow that reads, at a glance and from
            // across the room, which card the focus is on. Sized to sit inside the rails' padding
            // so it never clips at a row edge.
            .shadow(color: Theme.Palette.accent.opacity(focused ? 0.75 : 0),
                    radius: focused ? 18 : 0, x: 0, y: 0)
            // A soft black depth underneath grounds the lifted card on any artwork or theme.
            .shadow(color: .black.opacity(focused ? 0.45 : 0.32),
                    radius: focused ? 16 : 12, x: 0, y: focused ? 10 : 7)
            .animation(reduceMotion ? nil : Theme.Motion.focus, value: focused)
            .animation(Theme.Motion.state, value: configuration.isPressed)
    }
}

/// Primary action (play / resume): ember fill, brighten + scale on focus.
struct PrimaryActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryActionContent(configuration: configuration)
    }
}

private struct PrimaryActionContent: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var theme: ThemeManager   // observe so a theme change repaints this style
    var body: some View {
        configuration.label
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.onAccent)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.md)
            .background(focused ? Theme.Palette.accentBright : Theme.Palette.accent,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .scaleEffect(focused && !reduceMotion ? 1.06 : (configuration.isPressed ? 0.97 : 1))
            .shadow(color: Theme.Palette.accent.opacity(focused ? 0.55 : 0), radius: 26, y: 12)
            .animation(reduceMotion ? nil : Theme.Motion.focus, value: focused)
    }
}

// Chips live in ChipButtonStyle.swift (its API is used across 12 call sites).

/// List row (stream, episode, addon): a surface card that brightens and gains an ember ring on focus.
struct RowFocusStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowFocusContent(configuration: configuration)
    }
}

private struct RowFocusContent: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var theme: ThemeManager   // observe so a theme change repaints this style
    var body: some View {
        configuration.label
            .background(focused ? Theme.Palette.surface2 : Theme.Palette.surface1,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.Palette.accent, lineWidth: focused ? 3 : 0)
            )
            .scaleEffect(focused && !reduceMotion ? 1.015 : (configuration.isPressed ? 0.99 : 1))
            .shadow(color: focused ? Theme.Palette.accent.opacity(0.28) : .clear, radius: 22, y: 10)
            .animation(reduceMotion ? nil : Theme.Motion.focus, value: focused)
    }
}
