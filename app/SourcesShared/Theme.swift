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
        static let textTertiary  = rgb(0.620, 0.580, 0.520) // #9E9485 — raised from #8C8273 so 10-11pt text clears 4.5:1 on the warm canvas across all 8 accents
        // Accent is user-themeable via ThemeManager (8 curated accents). accentSoft / onAccent follow it.
        static var accent: Color { ThemeManager.shared.accent }             // focus / selection / primary / progress
        static var accentBright: Color { ThemeManager.shared.accentBright } // focus glow highlight
        static var accentSoft: Color { accent.opacity(0.18) }
        static var onAccent: Color { ThemeManager.shared.onAccent } // accent-adaptive ink (was a fixed warm-brown that read orange on every accent)
        static let danger = rgb(0.871, 0.282, 0.337)            // #DE4856 destructive (log out, remove) — a cooler red so it doesn't read as "leftover orange" next to a non-warm accent
        static let ok    = rgb(0.298, 0.769, 0.451)             // #4CC473 healthy/online status (add-on reachable), distinct from the gold accent
        static let warn  = rgb(0.949, 0.659, 0.231)            // #F2A83B caution/slow status, an amber that is not the brand gold
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
        // Readable prose column cap for hero synopsis / credits / language chips on the shared iOS/Mac
        // detail + home surfaces. A phone-narrow 760 looked cramped and left the wide Mac window mostly
        // empty to the right (item-1 "stretched phone layout" report), so the Mac gets a wider measure
        // that still keeps line length readable. iPhone/iPad keep 760. One token = every prose block
        // stays in lockstep.
        #if os(macOS)
        static let readableColumn: CGFloat = 980
        #else
        static let readableColumn: CGFloat = 760
        #endif
        // The full source-heavy content column (sources list, episode list) on a wide iPad/Mac window.
        // The Mac window is far wider than an iPad, so it earns a wider column than the shared 900; the
        // hero stays full-bleed above it.
        #if os(macOS)
        static let contentColumn: CGFloat = 1120
        #else
        static let contentColumn: CGFloat = 900
        #endif
        // Width above which the detail body caps its source / episode column at `contentColumn` (centered)
        // instead of filling the full width — the iPad/Mac regular-width cutover. One token keeps the body
        // and the pushed episode-streams view agreeing on when they widen.
        static let wideLayoutMinWidth: CGFloat = 700
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
        /// The big, soft radius for the full-width hero Play button and continue-watching cards — the
        /// cinematic media-app look (a pronounced pill, not a subtle control corner).
        static let hero: CGFloat = 30
    }

    // MARK: Circular action button sizing (the hero's translucent round icon buttons)

    enum Control {
        /// Diameter of a circular translucent hero action button (mark-watched, download, bookmark, …).
        static let circleButton: CGFloat = 50
        /// Diameter of the small circular chrome buttons overlaid on the hero (back chevron, overflow).
        /// 44pt so the tappable disc meets the HIG minimum touch target; these are the primary detail-page
        /// nav/actions now that the system nav bar is hidden on the pushed hero.
        static let circleChrome: CGFloat = 44
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
    #if os(macOS)
    @State private var isHovered = false   // Mac has no focus engine for cards; pointer hover drives the same lift
    #endif
    var body: some View {
        // On Mac, treat pointer hover as the focus signal so cards light up under the cursor;
        // iOS/tvOS keep using the focus engine (`focused`) untouched.
        #if os(macOS)
        let active = focused || isHovered
        #else
        let active = focused
        #endif
        let lifted = active && !reduceMotion
        let label = configuration.label
            .scaleEffect(lifted ? scale : (configuration.isPressed ? 0.97 : 1))
            // Theme-colored halo on focus: an even accent glow that reads, at a glance and from
            // across the room, which card the focus is on. Sized to sit inside the rails' padding
            // so it never clips at a row edge.
            .shadow(color: Theme.Palette.accent.opacity(active ? 0.75 : 0),
                    radius: active ? 18 : 0, x: 0, y: 0)
            // A soft black depth underneath grounds the lifted card on any artwork or theme.
            .shadow(color: .black.opacity(active ? 0.45 : 0.32),
                    radius: active ? 16 : 12, x: 0, y: active ? 10 : 7)
            .animation(reduceMotion ? nil : Theme.Motion.focus, value: active)
            .animation(Theme.Motion.state, value: configuration.isPressed)
        #if os(macOS)
        return label.onHover { isHovered = $0 }
        #else
        return label
        #endif
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
    #if os(macOS)
    @State private var isHovered = false   // Mac drives the same brighten/scale/glow from pointer hover
    #endif
    var body: some View {
        // On Mac, pointer hover stands in for the focus engine; iOS/tvOS keep using `focused`.
        #if os(macOS)
        let active = focused || isHovered
        #else
        let active = focused
        #endif
        let label = configuration.label
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.onAccent)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.md)
            .background(active ? Theme.Palette.accentBright : Theme.Palette.accent,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .scaleEffect(active && !reduceMotion ? 1.06 : (configuration.isPressed ? 0.97 : 1))
            .shadow(color: Theme.Palette.accent.opacity(active ? 0.55 : 0), radius: 26, y: 12)
            .animation(reduceMotion ? nil : Theme.Motion.focus, value: active)
        #if os(macOS)
        return label.onHover { isHovered = $0 }
        #else
        return label
        #endif
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
    #if os(macOS)
    @State private var isHovered = false   // Mac drives the same fill/ring/lift from pointer hover
    #endif
    var body: some View {
        // On Mac, pointer hover stands in for the focus engine; iOS/tvOS keep using `focused`.
        #if os(macOS)
        let active = focused || isHovered
        #else
        let active = focused
        #endif
        let label = configuration.label
            .background(active ? Theme.Palette.surface2 : Theme.Palette.surface1,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.Palette.accent, lineWidth: active ? 3 : 0)
            )
            .scaleEffect(active && !reduceMotion ? 1.015 : (configuration.isPressed ? 0.99 : 1))
            .shadow(color: active ? Theme.Palette.accent.opacity(0.28) : .clear, radius: 22, y: 10)
            .animation(reduceMotion ? nil : Theme.Motion.focus, value: active)
        #if os(macOS)
        return label.onHover { isHovered = $0 }
        #else
        return label
        #endif
    }
}

// MARK: - Premium hero components (shared by iOS/Mac detail + home)

/// A circular translucent icon button, the cinematic-media-app chrome affordance: a frosted disc with a
/// centered SF Symbol that scales + brightens on press (and on Mac pointer hover). Used for the hero back
/// chevron / overflow control and the row of secondary actions (mark-watched, download, bookmark, rate,
/// remove). Fail-soft: purely presentational, no state of its own.
struct CircleIconButton: View {
    let systemName: String
    var diameter: CGFloat = Theme.Control.circleButton
    var tint: Color = Theme.Palette.textPrimary
    var label: String? = nil                 // optional caption under the disc (secondary actions)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.xs) {
                CircleIconDisc(systemName: systemName, diameter: diameter, tint: tint)
                if let label {
                    Text(label)
                        .font(Theme.Typography.eyebrow)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(CircleIconButtonStyle())
    }
}

/// The frosted disc itself, split out so the button style can animate the whole label. Also reused
/// directly as a `Menu` label where a `ButtonStyle` can't apply (e.g. the detail hero overflow disc).
struct CircleIconDisc: View {
    let systemName: String
    let diameter: CGFloat
    let tint: Color
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: diameter * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: diameter, height: diameter)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().fill(Theme.Palette.canvas.opacity(0.28)))
            )
            .overlay(Circle().strokeBorder(Theme.Palette.textPrimary.opacity(0.10), lineWidth: 1))
            .contentShape(Circle())
    }
}

/// Press / hover feedback for a circular icon button: subtle scale + a soft accent glow. Animates only
/// transform + shadow (compositor-friendly), never layout.
struct CircleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Content(configuration: configuration) }
    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        #if os(macOS)
        @State private var isHovered = false
        #endif
        var body: some View {
            #if os(macOS)
            let active = isHovered
            #else
            let active = false
            #endif
            let label = configuration.label
                .scaleEffect(configuration.isPressed ? 0.92 : (active && !reduceMotion ? 1.06 : 1))
                .shadow(color: Theme.Palette.accent.opacity(active ? 0.35 : 0), radius: 14, y: 0)
                .animation(reduceMotion ? nil : Theme.Motion.state, value: configuration.isPressed)
            #if os(macOS)
            return label.onHover { isHovered = $0 }
            #else
            return label
            #endif
        }
    }
}

/// A full-width, big-radius primary Play button: high-contrast ember fill, bold label, press + hover
/// feedback. The cinematic-media-app hero CTA. Animates transform/opacity/shadow only.
struct HeroPlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Content(configuration: configuration) }
    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @EnvironmentObject private var theme: ThemeManager
        #if os(macOS)
        @State private var isHovered = false
        #endif
        var body: some View {
            #if os(macOS)
            let active = isHovered
            #else
            let active = false
            #endif
            let label = configuration.label
                .font(Theme.Typography.cardTitle.weight(.bold))
                .foregroundStyle(Theme.Palette.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.md)
                .background(active ? Theme.Palette.accentBright : Theme.Palette.accent,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .shadow(color: Theme.Palette.accent.opacity(active ? 0.55 : 0.30), radius: 22, y: 10)
                .animation(reduceMotion ? nil : Theme.Motion.state, value: configuration.isPressed)
            #if os(macOS)
            return label.onHover { isHovered = $0 }
            #else
            return label
            #endif
        }
    }
}

/// A small rounded metadata box (age rating, quality tag): a hairline-bordered rounded rect with compact
/// bold text. Reads as an intentional badge rather than plain inline text. Fail-soft on empty input.
struct MetaBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.Typography.eyebrow)
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Theme.Palette.textTertiary.opacity(0.6), lineWidth: 1)
            )
    }
}
