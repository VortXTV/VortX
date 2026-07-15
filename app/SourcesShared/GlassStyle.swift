import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// VortX "liquid glass": the warm-dark translucent material that is now VortX's ELEVATION LANGUAGE
/// across the app's chrome. It began as the floating nav bar / pill material from the approved redesign
/// mockups; it now also backs chips, rows, primary actions, panels, fields, toasts, on-poster badges,
/// settings cards, edge strips, and the native top / bottom bars, so every raised surface reads as one
/// system rather than a run of unrelated fills.
///
/// It is a CUSTOM material that renders the same on every OS version and platform: a translucent
/// warm-dark fill over a blur, a 1px top-highlight border, and a soft drop shadow. Where Apple's real
/// Liquid Glass exists (iOS / tvOS / macOS 26) that becomes the blur layer, so the look only UPGRADES on
/// newer systems, it never diverges: the warm tint, top highlight, ember active / prominent state, and
/// shadow are VortX's own and ride ON TOP of whichever blur renders. Under Reduce Transparency the whole
/// thing stands down to an opaque warm surface (an opaque accent surface for the prominent variant) so
/// the chrome stays legible.
///
/// Still deliberately NOT for scrolling content, poster art, backdrops, cast headshots, provider logo
/// plates, episode thumbnails, or opaque status / meaning surfaces (LIVE / CACHED / health dots, QR and
/// one-time-secret plates, diagnostic monospace logs): those keep their solid fills so their legibility
/// and meaning contracts hold. Every preset below reuses the ONE OS-26 gate plus the Reduce-Transparency
/// fallback (`blurLayer`), so the upgrade and the fallback are identical everywhere. These presets are
/// the shared foundation: the shared button / row styles in Theme.swift and ChipButtonStyle.swift build
/// on them, so the app's chip / row / disc / primary-action call sites all flip from here.
///
/// See docs/DESIGN-SYSTEM.md ("Radius / elevation / motion") and the redesign mockups for the visual target.
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
    /// Inline scroll-column cards / rows: the same warm fill a touch lighter than a floating pill, since
    /// these sit ON the canvas rather than floating high over content.
    static let cardFillAlpha = 0.50
    /// The focused / selected state of a glass row: a small alpha lift over `cardFillAlpha` so the row
    /// brightens under focus the way the old opaque surface1 -> surface2 step did, with the ember ring
    /// carrying the rest of the focus signal on top.
    static let rowFocusFillAlpha = 0.64
    /// Large modal / side-panel glass: HIGH alpha so text stays legible even when the panel floats over
    /// bright, moving video (a hero backdrop or the player), where a thin fill would wash out.
    static let panelFillAlpha = 0.74
    /// On-poster badges (quality tag, add-on chip laid over artwork): higher alpha than a pill so the
    /// badge holds its own against saturated poster art underneath.
    static let badgeFillAlpha = 0.72
    /// Text-entry field glass: tuned higher than a pill so typed text keeps contrast over the blur.
    static let fieldFillAlpha = 0.62
    /// The accent tint alpha for the PROMINENT (primary-action) glass: near-opaque so the surface reads as
    /// ember and the existing onAccent-vs-accent AA contrast is preserved, while the glass blur (and OS-26
    /// Liquid Glass) still bend light at the edges for the glass look.
    static let prominentTintAlpha = 0.94

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

    /// The ember active / selected fill for a nav item (mockups: `rgba(245,158,11,.16)`). The accent
    /// shorthand for `activeTint`; uses the themeable accent so a chosen accent flows through, exactly
    /// like the rest of the selection language.
    static var activeFill: Color { activeTint(Theme.Palette.accent) }

    /// The active / selected overlay fill at a caller-chosen tint. Defaults to the accent (the `activeFill`
    /// shorthand); a warn / amber or destructive tint can be passed so one active-state path serves every
    /// meaning without hardcoding the accent.
    static func activeTint(_ tint: Color = Theme.Palette.accent) -> Color { tint.opacity(0.16) }

    // MARK: Shadow presets (soft drop shadow under a raised element)

    struct Shadow {
        var color: Color
        var radius: CGFloat
        var y: CGFloat
        /// Horizontal offset, so an edge-docked panel / strip can throw its shadow inward, away from the
        /// screen edge it hugs. Defaults to 0 so every existing preset is unchanged.
        var x: CGFloat = 0
        static let bar = Shadow(color: .black.opacity(0.50), radius: 22, y: 14)   // floating tab bar / nav pill
        static let pill = Shadow(color: .black.opacity(0.45), radius: 16, y: 8)   // smaller floating pill / field
        static let disc = Shadow(color: .black.opacity(0.35), radius: 12, y: 6)   // round icon button
        /// Inline scroll-column card / row: a lighter shadow than a floating pill, since these sit on the
        /// canvas rather than hovering high above it.
        static let card = Shadow(color: .black.opacity(0.28), radius: 10, y: 5)
        /// Large modal / side panel floating over content: a deep, wide shadow that grounds the panel.
        static let panel = Shadow(color: .black.opacity(0.55), radius: 30, y: 18)
        /// Compact non-interactive notice (toast): a soft mid shadow so the notice floats but does not
        /// shout.
        static let toast = Shadow(color: .black.opacity(0.40), radius: 18, y: 10)
        /// Full-width edge-flush strip (banner / edge bar): minimal, so the strip reads as flush chrome
        /// rather than a floating card. Direction is set by `vortxGlassStrip(edge:)`.
        static let strip = Shadow(color: .black.opacity(0.30), radius: 12, y: 4)
        /// Near-zero shadow for surfaces that must NOT float or that already get their lift elsewhere:
        /// chips, focus rows (RowFocusStyle owns the lift), and list rows clipped by row insets.
        static let flat = Shadow(color: .clear, radius: 0, y: 0)

        /// A `panel` shadow thrown inward from the edge a docked panel hugs, so an edge-docked player /
        /// side panel casts toward the content, not off the screen.
        static func panelDocked(_ edge: Edge) -> Shadow {
            switch edge {
            case .leading:  return Shadow(color: .black.opacity(0.55), radius: 30, y: 0, x: 16)
            case .trailing: return Shadow(color: .black.opacity(0.55), radius: 30, y: 0, x: -16)
            case .top:      return Shadow(color: .black.opacity(0.55), radius: 30, y: 16, x: 0)
            case .bottom:   return Shadow(color: .black.opacity(0.55), radius: 30, y: -16, x: 0)
            }
        }
    }

    // MARK: The shared blur gate (ONE definition every preset reuses)

    /// The blur layer under every VortX glass preset: real Apple Liquid Glass on OS 26, the frosted
    /// `.ultraThinMaterial` on older systems, and an opaque warm `surface1` under Reduce Transparency so
    /// the surface stays legible. Extracting it here means the OS-26 upgrade and the Reduce-Transparency
    /// fallback are byte-identical across every preset instead of re-derived per modifier.
    @ViewBuilder
    static func blurLayer<S: InsettableShape>(in shape: S, reduceTransparency: Bool) -> some View {
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

    #if canImport(UIKit)
    /// The glass fill as a `UIColor`, so the tvOS native `UITabBarAppearance` (which cannot host a SwiftUI
    /// material) can tint its system-blurred background with the SAME warm fill the SwiftUI material uses.
    static func fillUIColor(_ alpha: Double) -> UIColor { UIColor(fill(alpha)) }
    #endif

    #if os(iOS)
    /// A `UIToolbarAppearance` built from the SAME warm glass fill as the tvOS tab bar (RootTabView), so
    /// the iOS top nav bar / toolbar reads as VortX glass and matches the bottom tab bar. Under Reduce
    /// Transparency it stands down to an opaque warm `surface1` surface for legibility. Re-skin only: the
    /// caller keeps its bar's items, tint, and behavior; this only supplies the background material.
    static func toolbarAppearance() -> UIToolbarAppearance {
        let appearance = UIToolbarAppearance()
        if UIAccessibility.isReduceTransparencyEnabled {
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(Theme.Palette.surface1)
        } else {
            appearance.configureWithDefaultBackground()
            appearance.backgroundColor = fillUIColor(barFillAlpha)
        }
        return appearance
    }
    #endif
}

// MARK: - The reusable SwiftUI material

/// Renders the VortX glass as a `background` behind its content: blur layer + warm tint + top highlight +
/// soft shadow, in the given `shape`. Availability-gated via `VortXGlass.blurLayer` so OS 26 uses real
/// Liquid Glass as the blur while older systems use `.ultraThinMaterial`; Reduce Transparency drops both
/// for an opaque warm surface.
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
            VortXGlass.blurLayer(in: shape, reduceTransparency: reduceTransparency)
            // The warm-dark VortX tint over the blur is what makes Apple's neutral Liquid Glass read as
            // VortX chrome. Skipped under Reduce Transparency, where `blurLayer` is already an opaque warm fill.
            if !reduceTransparency {
                shape.fill(VortXGlass.fill(fillAlpha))
            }
        }
        // 1px lit top edge / hairline border.
        .overlay { shape.strokeBorder(VortXGlass.highlight(highlightTop), lineWidth: 1) }
        // Flatten first so the soft drop shadow is cast by the whole glass silhouette, then float it.
        .compositingGroup()
        .shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}

// MARK: - The prominent (primary-action) ember glass

/// The PROMINENT variant for a primary action (Play / Resume): the same OS-26 gate + Reduce-Transparency
/// fallback as the neutral glass, but tinted with a near-opaque `tint` (accent) so the button stays
/// ember-forward and prominent, Apple's prominent-glass pattern. The high tint alpha preserves the
/// existing onAccent-vs-accent AA text contrast; the glass blur (and real Liquid Glass on OS 26) still
/// bends light at the edges so the button reads as glass, not a flat slab. Under Reduce Transparency it
/// falls back to an OPAQUE accent surface (not surface1): a primary CTA must stay ember and fully legible,
/// and surface1 would demote it to a neutral chip.
private struct VortXGlassProminentModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background { glass }
    }

    private var glass: some View {
        ZStack {
            VortXGlass.blurLayer(in: shape, reduceTransparency: reduceTransparency)
            // Near-opaque accent tint over the blur. At full alpha under Reduce Transparency the button is
            // a solid ember slab (identical to the pre-glass primary); otherwise a hint of glass shows.
            shape.fill(tint.opacity(reduceTransparency ? 1.0 : VortXGlass.prominentTintAlpha))
        }
        // A slightly brighter top highlight than neutral glass, so the ember surface still reads lit.
        .overlay { shape.strokeBorder(VortXGlass.highlight(0.18), lineWidth: 1) }
        // Flatten the tinted glass so it composites as one surface. The button style owns the drop
        // shadow / glow, so this variant adds no shadow of its own.
        .compositingGroup()
    }
}

// MARK: - The edge-flush strip

/// A full-width, edge-flush strip (banner / edge bar): the shared blur + warm tint, but with a TOP-only
/// 1px highlight (no side / bottom border) and a minimal shadow directed inward from the docked `edge`,
/// so the strip reads as flush chrome rather than a floating card.
private struct VortXGlassStripModifier: ViewModifier {
    let edge: Edge
    let fillAlpha: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background { glass }
    }

    private var glass: some View {
        ZStack {
            VortXGlass.blurLayer(in: Rectangle(), reduceTransparency: reduceTransparency)
            if !reduceTransparency {
                Rectangle().fill(VortXGlass.fill(fillAlpha))
            }
        }
        // Top-highlight ONLY: a 1px lit line along the top edge, no full border, so the strip stays flush.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
        }
        .compositingGroup()
        .shadow(color: VortXGlass.Shadow.strip.color,
                radius: VortXGlass.Shadow.strip.radius,
                x: stripShadowOffset.x, y: stripShadowOffset.y)
    }

    // Push the shadow inward, away from the edge the strip hugs.
    private var stripShadowOffset: (x: CGFloat, y: CGFloat) {
        let d = VortXGlass.Shadow.strip.radius / 3
        switch edge {
        case .top:      return (0,  d)
        case .bottom:   return (0, -d)
        case .leading:  return (d,  0)
        case .trailing: return (-d, 0)
        }
    }
}

extension View {
    /// Apply the VortX glass material in `shape`. Renders the same warm glass on every OS / platform and
    /// upgrades to real Liquid Glass on OS 26. `fillAlpha` / `highlight` / `shadow` tune it per surface
    /// (defaults suit a floating bar or pill).
    func vortxGlass<S: InsettableShape>(
        in shape: S,
        fillAlpha: Double = VortXGlass.barFillAlpha,
        highlight: Double = 0.14,
        shadow: VortXGlass.Shadow = .bar
    ) -> some View {
        modifier(VortXGlassModifier(shape: shape, fillAlpha: fillAlpha, highlightTop: highlight, shadow: shadow))
    }

    /// The ember active / selected overlay for a nav item / chip: fills `shape` with the soft `tint` (accent
    /// by default; pass a warn / amber or destructive tint) when `active`, nothing when not. One definition
    /// so every platform's selected tab / pill / chip reads identically.
    @ViewBuilder func vortxGlassActive<S: InsettableShape>(
        _ active: Bool,
        tint: Color = Theme.Palette.accent,
        in shape: S
    ) -> some View {
        background { if active { shape.fill(VortXGlass.activeTint(tint)) } }
    }

    /// The ONE chip path: the neutral glass base plus a parameterized active overlay. Idle = glass pill;
    /// `selected` = glass pill + the `tint` ember overlay (accent by default; a warn / amber or destructive
    /// tint is supported). No drop shadow: chips sit inline, and their focus ring / scale ride on top from
    /// ChipButtonStyle.
    func vortxGlassChip(selected: Bool, tint: Color = Theme.Palette.accent) -> some View {
        let shape = Capsule(style: .continuous)
        return vortxGlass(in: shape, fillAlpha: VortXGlass.pillFillAlpha, shadow: .flat)
            .vortxGlassActive(selected, tint: tint, in: shape)
    }

    /// A list-row / stream-row glass fill that renders BELOW the caller's ember focus / selection ring and
    /// scale (RowFocusStyle applies those on top). `focused` lifts the fill alpha so the row brightens on
    /// focus the way the old surface1 -> surface2 step did. Uses a `flat` (near-zero) shadow because
    /// RowFocusStyle owns the focus lift shadow, so the two never fight.
    func vortxGlassRow(focused: Bool) -> some View {
        vortxGlass(
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
            fillAlpha: focused ? VortXGlass.rowFocusFillAlpha : VortXGlass.cardFillAlpha,
            shadow: .flat
        )
    }

    /// A glass fill safe inside a SwiftUI `List` / `.listRowBackground`, where row insets clip a normal
    /// drop shadow: near-zero shadow, card-weight fill.
    func vortxGlassListRow<S: InsettableShape>(in shape: S) -> some View {
        vortxGlass(in: shape, fillAlpha: VortXGlass.cardFillAlpha, shadow: .flat)
    }

    /// A text-entry field glass, tuned (`fieldFillAlpha`) so typed text keeps contrast over the blur.
    func vortxGlassField<S: InsettableShape>(in shape: S) -> some View {
        vortxGlass(in: shape, fillAlpha: VortXGlass.fieldFillAlpha, shadow: .pill)
    }

    /// A compact, NON-interactive notice (toast) glass: legible fill + a soft toast shadow. It never opts
    /// into interactive glass, so it does not react to touch / pointer the way a control would.
    func vortxGlassToast<S: InsettableShape>(in shape: S) -> some View {
        vortxGlass(in: shape, fillAlpha: VortXGlass.fieldFillAlpha, shadow: .toast)
    }

    /// A high-alpha large modal / side-panel glass that stays legible over bright, moving video. Pass a
    /// docked `edge` to throw the shadow inward from that edge (edge-docked player / side panels); omit it
    /// for a centered modal.
    func vortxGlassPanel<S: InsettableShape>(in shape: S, dockedTo edge: Edge? = nil) -> some View {
        vortxGlass(in: shape, fillAlpha: VortXGlass.panelFillAlpha,
                   shadow: edge.map { VortXGlass.Shadow.panelDocked($0) } ?? .panel)
    }

    /// A full-width, edge-flush strip (banner / edge bar): top-highlight only, minimal inward shadow.
    func vortxGlassStrip(edge: Edge) -> some View {
        modifier(VortXGlassStripModifier(edge: edge, fillAlpha: VortXGlass.barFillAlpha))
    }

    /// The PROMINENT primary-action glass: ember-tinted glass that stays translucent and upgrades to real
    /// Liquid Glass on OS 26, while preserving the onAccent-vs-accent AA text contrast. Pass the live tint
    /// (accent at rest, accentBright on focus / hover) so the button's focus brighten flows through.
    func vortxGlassProminent<S: InsettableShape>(in shape: S, tint: Color = Theme.Palette.accent) -> some View {
        modifier(VortXGlassProminentModifier(shape: shape, tint: tint))
    }

    /// The settings-card composite: neutral card glass with the settings padding + radius defaults, so a
    /// settings surface is one modifier instead of a hand-rolled fill + padding each time. See `SettingsCard`
    /// for the container view.
    func vortxSettingsCard() -> some View {
        vortxGlass(
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
            fillAlpha: VortXGlass.cardFillAlpha,
            shadow: .card
        )
    }
}

// MARK: - Settings card container

/// A settings surface: content on the shared card glass with the settings padding + radius defaults. One
/// container so every settings block reads identically instead of re-deriving padding + fill per screen.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(Theme.Space.md)
            .vortxSettingsCard()
    }
}
