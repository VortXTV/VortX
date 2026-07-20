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

    /// What a glass surface is compositing AGAINST, which decides which way its fill has to move it.
    ///
    /// This distinction is the whole point. A translucent fill does not have an appearance of its own, it has
    /// a DIRECTION: it drags whatever is behind it toward its own tone. So one tone cannot serve two opposite
    /// jobs, and the app has exactly two:
    ///
    /// * `.lift`: the surface sits on VortX's OWN dark chrome (chips, cards, rows, bars, fields, toasts).
    ///   Nothing is behind it but a flat dark fill, so the glass has no light to bend and no bright backdrop
    ///   to hold back. Its only job is to read as a RAISED plane, which means it must end up BRIGHTER than
    ///   the chrome. That takes a mid-tone veil.
    /// * `.scrim`: the surface floats over BRIGHT, arbitrary media (poster art, moving video). Here the
    ///   glass must hold that media back so a white glyph or label stays legible, which means it must end up
    ///   DARKER than the backdrop. That takes a dark wash.
    ///
    /// The old code had ONE near-black fill and used it for both. That value is CORRECT for `.scrim` and is
    /// preserved unchanged below, so no player / on-art chrome moves. Applied to `.lift` it was a category
    /// error rather than a bad number: composited at 50% over `canvas` it landed the surface 0.9/255 from the
    /// background (1.008:1), while the 1px highlight landed 33/255 away, so the EDGE was ~37x more visible
    /// than the SURFACE. That is precisely "a bright border with nothing inside": the fill was not weak, it
    /// was pointed the wrong way. Measured on the CEO's own Apple TV screen, the glass keyword fields
    /// rendered 18/255 on a 33/255 card, i.e. a DENT, not a raised plane.
    enum Tone {
        /// Over VortX's own dark chrome: must read as a raised plane, so it LIFTS. Accent-hued.
        case lift
        /// Over bright media (poster art / video): must protect legibility, so it DARKENS. Fixed warm.
        case scrim
    }

    /// The fixed warm near-black SCRIM (mockups: `rgba(20,17,16,~.5)`). Fixed sRGB, NOT the user-themeable
    /// `canvas`: a scrim sits over arbitrary poster art and video, never over the chrome, so it must stay a
    /// stable VortX identity that does not swing with the accent or the OLED switch. This is the ORIGINAL
    /// glass constant, kept byte-identical, now scoped to the one role it was always right for.
    private static let scrimRGB = (r: 0.078, g: 0.067, b: 0.063)   // ≈ #141110

    /// The glass fill at a given alpha, for the given backdrop role. `.lift` (the default, and every surface
    /// that sits on the app's own chrome) resolves to the themeable `glassVeil` so the surface rises one step
    /// up the SAME ladder as `surface1` / `surface2` / `surface3` and stays hue-coherent across all 9 accents
    /// and both chrome modes. `.scrim` resolves to the fixed warm near-black above.
    static func fill(_ alpha: Double, tone: Tone = .lift) -> Color {
        switch tone {
        case .lift:
            return Theme.Palette.glassVeil.opacity(alpha)
        case .scrim:
            return Color(.sRGB, red: scrimRGB.r, green: scrimRGB.g, blue: scrimRGB.b, opacity: alpha)
        }
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
    /// Player transport / top-bar discs (play-pause, seek, top-row icon buttons) that float over BRIGHT,
    /// moving video: heavier than a bar or pill so the white glyph reads crisp against a hot backdrop. A
    /// touch above `fieldFillAlpha` since a disc sits over live video, not just a blur. Discs use the
    /// `vortxGlassDisc` path (`hugsTightly`), so the blur is ALWAYS a shape-clipped material, NEVER Apple's
    /// `glassEffect`: on a tight ~44pt circle glassEffect's un-clipped ambient bloom draws a dark rounded
    /// halo larger than the disc, so a clipped material keeps the disc a tight puck.
    static let discFillAlpha = 0.66
    /// The accent tint alpha for the PROMINENT (primary-action) glass overlay fill. Raised from the earlier
    /// 0.66 (which read washed out on the OS-26 real-glass path, where the neutral glass showed straight
    /// through a thin accent) to a vibrant ember that still leaves a faint frost rim, staying shy of a flat
    /// opaque slab. On OS 26 this fill now rides OVER glass that is itself accent-tinted
    /// (`glassEffect(.regular.tint(accent))`), so the button reads as ember GLASS, not neutral glass under a
    /// wash; on older systems the fill carries the ember over a `.thinMaterial` frost. The onAccent label
    /// still clears AA over the fill. Under Reduce Transparency the modifier forces this to a full 1.0
    /// opaque accent instead, so the accessibility path stays a solid, maximally legible ember CTA.
    static let prominentTintAlpha = 0.90
    /// The selected-chip ember tint alpha. Set a touch above the old direct `accent.opacity(0.18)` chip
    /// fill because the tint now sits OVER the 50% warm glass fill (which slightly mutes it), so the
    /// selected-unfocused chip reads at least as strongly as before.
    static let chipSelectedAlpha = 0.20

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
        // Tight, close shadow: a 12pt blur on a ~44pt disc smears a dark halo/ring around the button, so
        // this stays small and close so round transport / top-bar discs read grounded, not haloed.
        static let disc = Shadow(color: .black.opacity(0.26), radius: 6, y: 3)   // round icon button
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

    /// The blur layer under every VortX glass preset: real Apple Liquid Glass on OS 26, a frosted
    /// `material` (default `.ultraThinMaterial`) on older systems, and an opaque warm `surface1` under
    /// Reduce Transparency so the surface stays legible. Extracting it here means the OS-26 upgrade and the
    /// Reduce-Transparency fallback are byte-identical across every preset instead of re-derived per
    /// modifier. `material` lets a preset pick a heavier frost (the prominent primary-action glass passes
    /// `.thinMaterial`); all chrome keeps the default, so those call sites are untouched.
    ///
    /// `glassTint` (OS 26 only) tints Apple's Liquid Glass ITSELF, so the prominent primary-action path
    /// renders ember-colored glass rather than neutral glass showing through a thin accent fill.
    /// `hugsTightly` forces the shape-clipped `material` on EVERY OS (never `glassEffect`) for tight small
    /// circular controls (discs): glassEffect's ambient shadow / lensing bloom is not clipped to the shape,
    /// so on a ~44pt disc it draws a dark rounded halo larger than the disc and reads over-blurred.
    @ViewBuilder
    static func blurLayer<S: InsettableShape>(in shape: S, reduceTransparency: Bool,
                                              material: Material = .ultraThinMaterial,
                                              glassTint: Color? = nil,
                                              hugsTightly: Bool = false) -> some View {
        if reduceTransparency {
            // No blur when transparency is reduced: an opaque warm surface keeps the chrome legible.
            shape.fill(Theme.Palette.surface1)
        } else if hugsTightly {
            // Tight small circular controls (transport / hero discs): NEVER Apple glassEffect. Its ambient
            // shadow / lensing bloom is not clipped to the shape, so on a tight disc it paints a dark
            // rounded halo. A material fill on the `Circle` clips cleanly: a tight puck, no bloom.
            shape.fill(material)
        } else if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
            // Real Apple Liquid Glass as the blur (the same idiom as the existing player chrome), upgraded
            // in place. VortX's tint + highlight + shadow still layer on top, so identity is preserved.
            // For the prominent path `glassTint` colors the glass itself so ember reads through the gloss.
            if let glassTint {
                shape.fill(.clear).glassEffect(.regular.tint(glassTint), in: shape)
            } else {
                shape.fill(.clear).glassEffect(.regular, in: shape)
            }
        } else {
            // Custom material on every older OS: the frosted blur that carries the warm tint above. The
            // caller-chosen `material` defaults to `.ultraThinMaterial` (chrome), heavier for prominent.
            shape.fill(material)
        }
    }

    #if canImport(UIKit)
    /// The glass fill as a `UIColor`, so the tvOS native `UITabBarAppearance` (which cannot host a SwiftUI
    /// material) can tint its system-blurred background with the SAME warm fill the SwiftUI material uses.
    static func fillUIColor(_ alpha: Double) -> UIColor { UIColor(fill(alpha)) }
    #endif

    #if os(tvOS)
    // MARK: The tvOS floating tab bar's glass

    /// The tvOS tab bar's VortX glass background, as a resizable `UIImage` for `UITabBarAppearance`.
    ///
    /// This is the answer to the old "the tvOS tab bar cannot host a SwiftUI material" note: true, it
    /// cannot, but `UIBarAppearance` composites `backgroundEffect` (the system blur) -> `backgroundImage`,
    /// so DRAWING the VortX treatment and handing it over as the background image puts the real design
    /// language on the native bar. The blur underneath is kept, so content scrolling behind the bar is
    /// still sampled; this image supplies the two parts the system blur has no concept of: the VortX glass
    /// veil and its 1px lit top edge (`highlight()`'s white-at-.14 top stop, the same value the SwiftUI
    /// `strokeBorder` uses). The image is a 1pt-wide column stretched across the bar, so the fill stays flat
    /// and only the top cap is preserved, which keeps the highlight exactly 1pt at the top edge no matter
    /// how wide or tall the bar is laid out.
    ///
    /// The bar is `.lift`, not `.scrim`, and that is the whole reason it was invisible. It floats over the
    /// app's OWN dark chrome, so its job is to read as a RAISED plane, not to hold media back. It used to be
    /// painted with the fixed near-black scrim (via `backgroundColor = fillUIColor(barFillAlpha)`), which
    /// dragged the bar TOWARD the canvas it was already sitting on. Measured on Apple TV 4K (tvOS 26.5)
    /// before the fix: bar rgb(21,18,17) against canvas rgb(22,18,14), a contrast ratio of 1.002:1 and a
    /// luminance delta of -0.21, i.e. the app's highest chrome rendered a hair DARKER than its background,
    /// while an inline settings card behind it read at 1.102:1. The only reason the bar had any outline was
    /// the system's own 1px edge (rgb(28,24,20), luminance +6.0): an edge ~30x more visible than the surface
    /// it encloses is exactly the CEO's "barely there", and it was a direction error, not a weak number.
    static func tabBarBackgroundImage() -> UIImage {
        let highlightTop = 0.14
        let size = CGSize(width: 1, height: 4)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(fill(barFillAlpha, tone: .lift)).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 1, alpha: highlightTop).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 1))
        }
        // Preserve the top 2pt (the highlight plus a pixel of fill under it) and stretch the single middle
        // row; the fill is flat, so stretching it is lossless.
        return image.resizableImage(withCapInsets: UIEdgeInsets(top: 2, left: 0, bottom: 1, right: 0),
                                    resizingMode: .stretch)
    }

    /// Stand the tvOS system text-field chrome DOWN so VortX's own field surface is the one that renders.
    ///
    /// On tvOS a SwiftUI `TextField` is backed by a `UITextField` that paints an OPAQUE near-white
    /// (~#EAE9E9) card of its own, and `.textFieldStyle(.plain)` does NOT remove it (unlike iOS / macOS,
    /// where `.plain` really is background-free). That system card drew straight OVER whatever VortX put
    /// behind the field, so a warm `surface1` (LoginView) or a `vortxGlassField` (ServerConfigView,
    /// StremioImportView, AddonStoreView) was painted and then completely hidden, and the field read as a
    /// full-width white slab in otherwise warm-dark chrome. It also broke legibility, not just looks:
    /// `textPrimary` (#F6F1E9) typed onto that near-white card lands at ~1.08:1, far under the 4.5:1 AA
    /// floor, so typed text was effectively invisible.
    ///
    /// Clearing the appearance proxy is the same tactic `applyTabBarAccent` already uses for the tab bar's
    /// system-white focused pill: neutralize the tvOS default, then let the VortX surface show. Every VortX
    /// field background is preserved exactly as authored, so this reveals the design system rather than
    /// changing it.
    static func applyTextFieldAppearance() {
        UITextField.appearance().backgroundColor = .clear
        UITextField.appearance().borderStyle = .none
    }
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
    /// An optional active / selected tint composited INSIDE this background subtree, ABOVE the warm fill
    /// (and the blur) but BELOW the content. Kept nil for plain glass; the chip passes its ember here so the
    /// selection cue reads on top of the glass instead of being buried beneath the frost + warm fill.
    var activeFill: Color? = nil
    /// Tight small circular control (disc): forward to `blurLayer` so the blur is a shape-clipped material
    /// on every OS, never `glassEffect` (which would draw an un-clipped halo around the disc). Default off.
    var hugsTightly: Bool = false
    /// tvOS ONLY: a fully OPAQUE warm fill for focusable / scrolling / on-art surfaces (rows, chips,
    /// badges). When set, tvOS renders this opaque fill in place of the live blur + translucent warm tint,
    /// so the Apple TV GPU does not composite a per-frame backdrop blur (the ~5fps focus-scroll regression)
    /// and the content behind reads at full vibrance (no desaturating sample). nil on iOS / macOS, where the
    /// real glass is kept byte-identical. Default off.
    var opaqueTVFill: Color? = nil
    /// What this surface composites against, which decides whether its fill lifts or scrims (see
    /// `VortXGlass.Tone`). Defaults to `.lift` because the large majority of glass in the app sits on VortX's
    /// own dark chrome; the three presets that float over bright media (disc / badge / panel) pass `.scrim`.
    var tone: VortXGlass.Tone = .lift
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background { glass }
    }

    /// The tvOS opaque fill to use, or nil to keep the glass path. nil off tvOS (iOS / macOS keep glass,
    /// byte-identical) and under Reduce Transparency (blurLayer's own opaque `surface1` takes over there).
    private var resolvedOpaqueTVFill: Color? {
        #if os(tvOS)
        return reduceTransparency ? nil : opaqueTVFill
        #else
        return nil
        #endif
    }

    private var glass: some View {
        ZStack {
            if let resolvedOpaqueTVFill {
                // tvOS cheap path: an OPAQUE warm base (no glassEffect, no material blur), with the
                // active / selected tint riding on top exactly as it does on the glass path.
                shape.fill(resolvedOpaqueTVFill)
                if let activeFill {
                    shape.fill(activeFill)
                }
            } else {
                VortXGlass.blurLayer(in: shape, reduceTransparency: reduceTransparency, hugsTightly: hugsTightly)
                // The warm-dark VortX tint over the blur is what makes Apple's neutral Liquid Glass read as
                // VortX chrome. Skipped under Reduce Transparency, where `blurLayer` is already an opaque warm fill.
                if !reduceTransparency {
                    shape.fill(VortXGlass.fill(fillAlpha, tone: tone))
                }
                // The active / selected ember tint sits ON TOP of the warm fill and the blur, but still inside
                // the background (so it stays below the content). Rendered in both modes so the selection cue
                // survives Reduce Transparency too.
                if let activeFill {
                    shape.fill(activeFill)
                }
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
/// fallback as the neutral glass, but tinted with a GLASS-range `tint` (accent) over a heavier
/// `.thinMaterial` frost, so the button reads as tinted ember GLASS (more frosted than chrome) rather than
/// a near-flat ember slab, Apple's prominent-glass pattern. The tint stays light enough for the frost to
/// show yet keeps the onAccent label AA-legible over the tinted fill; the blur (and real Liquid Glass on
/// OS 26) bends light at the edges for the glass look. Under Reduce Transparency it falls back to an
/// OPAQUE accent surface (tint forced to 1.0, not surface1): a primary CTA must stay ember and fully
/// legible, and surface1 would demote it to a neutral chip.
private struct VortXGlassProminentModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background { glass }
    }

    private var glass: some View {
        ZStack {
            // Heavier `.thinMaterial` frost (vs chrome's `.ultraThinMaterial`) so the tinted ember still
            // reads as GLASS with the label legible over it, per the "more glass on buttons" direction. On
            // OS 26 `glassTint: tint` colors Apple's Liquid Glass itself so the ember reads through the
            // gloss instead of a neutral glass showing through the fill; older systems tint via the fill.
            VortXGlass.blurLayer(in: shape, reduceTransparency: reduceTransparency,
                                 material: .thinMaterial, glassTint: reduceTransparency ? nil : tint)
            // Ember accent fill raised to a vibrant `prominentTintAlpha` (still shy of an opaque slab, so a
            // faint frost rim survives) over the now accent-tinted glass. Forced fully opaque under Reduce
            // Transparency so the CTA falls back to a solid, maximally legible ember slab.
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
        shadow: VortXGlass.Shadow = .bar,
        tone: VortXGlass.Tone = .lift
    ) -> some View {
        // On tvOS, on-art badges (the only `vortxGlass` callers at `badgeFillAlpha`) drop to a cheap OPAQUE
        // warm capsule: over poster art a live glass badge sampled + desaturated the artwork under it, and
        // on the scrolling focus surfaces it added another per-frame backdrop blur. Opaque warm #141110 =
        // full-vibrance art underneath, zero blur cost. `opaqueTVFill` is inert on iOS / macOS and off
        // tvOS, so every other `vortxGlass` surface (player pills / panels / toasts, the offline strip)
        // keeps its glass. The tvOS badge alpha (0.72) is distinct from the pill / field / panel alphas.
        //
        // This opaque capsule is pinned to `.scrim` REGARDLESS of the caller's `tone`, and that is deliberate:
        // at alpha 1.0 nothing composites, so the "a mid veil lifts darks and holds brights back" argument
        // does not apply, it would just be a flat mid-grey slab sitting on the artwork. A badge over poster
        // art needs to stay a dark plate so its white label keeps contrast, so it keeps the original #141110.
        let opaqueTVFill: Color? = (fillAlpha == VortXGlass.badgeFillAlpha)
            ? VortXGlass.fill(1.0, tone: .scrim) : nil
        return modifier(VortXGlassModifier(shape: shape, fillAlpha: fillAlpha, highlightTop: highlight,
                                           shadow: shadow, opaqueTVFill: opaqueTVFill, tone: tone))
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

    /// The ONE chip path: the neutral glass base plus a parameterized active tint. Idle = glass pill;
    /// `selected` = glass pill + the `tint` ember composited ABOVE the glass warm fill but BELOW the label
    /// (accent by default; a warn / amber or destructive tint is supported). Building the modifier directly
    /// keeps the ember tint inside the ONE background subtree, so it is NOT buried under the frost + warm
    /// fill the way a second, outer `.background` would be. No drop shadow: chips sit inline, and their
    /// focus ring / scale ride on top from ChipButtonStyle.
    func vortxGlassChip(selected: Bool, tint: Color = Theme.Palette.accent) -> some View {
        modifier(VortXGlassModifier(
            shape: Capsule(style: .continuous),
            fillAlpha: VortXGlass.pillFillAlpha,
            highlightTop: 0.14,
            shadow: .flat,
            activeFill: selected ? tint.opacity(VortXGlass.chipSelectedAlpha) : nil,
            // tvOS: ~80 filter chips scroll under the focus engine, so they take the cheap OPAQUE warm
            // capsule (idle = surface2) instead of a live glass blur per chip; the ember selection tint
            // (activeFill above) and ChipButtonStyle's ring / scale still ride on top. Inert on iOS / macOS.
            opaqueTVFill: Theme.Palette.surface2
        ))
    }

    /// A list-row / stream-row glass fill that renders BELOW the caller's ember focus / selection ring and
    /// scale (RowFocusStyle applies those on top). `focused` lifts the fill alpha so the row brightens on
    /// focus the way the old surface1 -> surface2 step did. Uses a `flat` (near-zero) shadow because
    /// RowFocusStyle owns the focus lift shadow, so the two never fight.
    func vortxGlassRow(focused: Bool) -> some View {
        modifier(VortXGlassModifier(
            shape: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
            fillAlpha: focused ? VortXGlass.rowFocusFillAlpha : VortXGlass.cardFillAlpha,
            highlightTop: 0.14,
            shadow: .flat,
            // tvOS: a single "All sources" list is dozens of focusable rows, so each row takes the cheap
            // OPAQUE warm fill (rest = surface1, focused = surface2, the old surface1 -> surface2 focus
            // step) instead of a live glass blur, which is what tanked the Apple TV GPU to ~5fps and
            // desaturated the backdrop it sampled. RowFocusStyle's accent ring / scale / lift ride on top
            // unchanged. Inert on iOS / macOS, so their glass rows are byte-identical.
            opaqueTVFill: focused ? Theme.Palette.surface2 : Theme.Palette.surface1
        ))
    }

    /// The tight, small circular-control glass (player transport discs, hero back / overflow chevrons): the
    /// shared warm glass at `discFillAlpha`, but the blur is ALWAYS a shape-clipped material, NEVER Apple's
    /// `glassEffect`, on every OS. `glassEffect` draws an ambient shadow / lensing bloom that is not clipped
    /// to the shape, so on a ~44pt disc it paints a dark rounded halo larger than the disc and reads
    /// over-blurred; a material fill on the `Circle` clips cleanly, so the disc stays a tight puck with only
    /// the close `.disc` shadow. Warm fill at `discFillAlpha` so the white glyph holds over bright, moving
    /// video. Defaults to a `Circle`; pass another tight shape if a control is not circular.
    func vortxGlassDisc<S: InsettableShape>(in shape: S = Circle()) -> some View {
        modifier(VortXGlassModifier(
            shape: shape,
            fillAlpha: VortXGlass.discFillAlpha,
            highlightTop: 0.14,
            shadow: .disc,
            hugsTightly: true,
            // SCRIM: a transport / hero disc only ever floats over bright, moving video, and its whole job is
            // to keep the white glyph crisp against a hot backdrop. Lifting it would push it toward the video
            // it is supposed to hold back (worst case, over near-white video, a white glyph falls from ~6.1:1
            // to ~4.1:1). This is the role the original near-black fill was designed for, so it keeps it.
            tone: .scrim
        ))
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
        // SCRIM: this preset exists specifically for the panel that floats over a bright hero backdrop or the
        // player, which is why its alpha is the highest in the ladder. Its contract is "text stays legible
        // over moving video", so it must darken what is behind it, not lift it.
        vortxGlass(in: shape, fillAlpha: VortXGlass.panelFillAlpha,
                   shadow: edge.map { VortXGlass.Shadow.panelDocked($0) } ?? .panel,
                   tone: .scrim)
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
        modifier(VortXGlassModifier(
            shape: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous),
            fillAlpha: VortXGlass.cardFillAlpha,
            highlightTop: 0.14,
            shadow: .card,
            // tvOS: a settings card sits on the app's OWN canvas, never over poster art or video, and that
            // is where this glass collapses. The warm glass tint (#141110, brightness ~.078) is DARKER than
            // `canvas` (tintedDark(.085)), so compositing it at `cardFillAlpha` over the canvas lands the
            // card back at roughly the canvas: measured 1.016:1 against the background on Apple TV, i.e. no
            // visible card at all, only its 1px highlight. The blur has nothing to bend either, because what
            // is behind is a flat dark fill rather than art. The pre-glass design raised these surfaces to
            // `surface1` (.130) for a clear step above `canvas` (.085), so take the same cheap OPAQUE path
            // `vortxGlassRow` already uses on tvOS: elevation is restored, a live per-frame backdrop blur is
            // dropped, and the ONE highlight + shadow still ride on top. Inert on iOS / macOS, where these
            // cards do float over art and the real glass stays byte-identical.
            opaqueTVFill: Theme.Palette.surface1
        ))
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
