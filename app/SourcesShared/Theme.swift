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
        // 10-foot tvOS screen inset. Do NOT use this directly as horizontal padding on shared views
        // that also render on iPhone — 60pt eats ~120pt of a 390pt phone and clips content off the
        // edges (the beta7 server-config / add-ons clipping). Use `screenInset` instead.
        static let screenEdge: CGFloat = 60
        // Platform-aware screen inset: the tvOS 10-foot value on TV, an arm's-length value on
        // phone / iPad / Mac. Shared screens (ServerConfig, Add-ons, Profiles) use this so one token
        // keeps tvOS spacious without clipping the phone.
        #if os(tvOS)
        static let screenInset: CGFloat = screenEdge
        #else
        static let screenInset: CGFloat = md
        #endif
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

    /// Every size is a computed `static var` that multiplies by the LIVE text scale from
    /// ThemeManager (Settings → Appearance → App text size). Because each screen observes
    /// ThemeManager (`@EnvironmentObject theme`), changing the scale fires the manager's
    /// `objectWillChange`, those screens re-evaluate `body`, and these getters re-run against the
    /// new `textScale` — so the app repaints instantly, the same way the accent does, no relaunch.
    ///
    /// IMPORTANT reactivity contract: reading `Theme.Typography.*` does NOT by itself subscribe a
    /// view to text-size changes (the read goes through `ThemeManager.shared`, not the view's
    /// observed reference). A view (or its nearest observing ancestor) must hold
    /// `@EnvironmentObject theme: ThemeManager` for its fonts to repaint live. On iOS/Mac the
    /// browse, detail, player, and Settings screens all declare it; tvOS screens already did, which
    /// is why text size worked there but not on iOS/Mac (#48).
    enum Typography {
        private static func scaled(_ size: CGFloat) -> CGFloat {
            // Base sizes are tvOS 10-foot dimensions. On phone / iPad / Mac, viewed at arm's length,
            // those render far too large, so scale the base down to 62% before applying the user's
            // live textScale. tvOS keeps the full base. (Root cause of the "text too big" report.)
            #if os(tvOS)
            let base = size
            #else
            let base = size * 0.62
            #endif
            return (base * CGFloat(ThemeManager.shared.textScale)).rounded()
        }
        static var hero: Font        { .system(size: scaled(64), weight: .heavy, design: .serif) }
        static var wordmark: Font    { .system(size: scaled(38), weight: .bold, design: .serif) }
        static var screenTitle: Font { .system(size: scaled(52), weight: .heavy) }
        static var sectionTitle: Font { .system(size: scaled(30), weight: .semibold) }
        static var cardTitle: Font   { .system(size: scaled(22), weight: .semibold) }
        static var body: Font        { .system(size: scaled(24), weight: .regular) }
        static var label: Font       { .system(size: scaled(20), weight: .medium) }
        static var eyebrow: Font     { .system(size: scaled(15), weight: .bold) }
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
