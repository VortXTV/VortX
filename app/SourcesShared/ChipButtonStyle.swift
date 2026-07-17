import SwiftUI

// MARK: - The VortX button-style family (and why `.buttonStyle(.plain)` is banned on tvOS)
//
// THE TRAP, stated once so nobody has to rediscover it on a device:
// on tvOS a Button does NOT lose the system focus treatment just because you gave it a background.
// `.buttonStyle(.plain)` keeps the OS's own focus platter: a WHITE, rounded slab that is drawn LARGER
// than the button, scaled up, and painted OVER its neighbours. On iOS / macOS `.plain` really is
// chrome-free, which is exactly why this is so easy to ship by accident: the modifier looks harmless,
// reviews clean, and only misbehaves on the one platform whose focus engine you cannot see in a
// SwiftUI preview. It is what put a fat white capsule over the "My audio" chip in
// Settings > Streams > Smart source selection, covering "HDR / DV" and "Stated quality" either side.
//
// WHAT ACTUALLY SUPPRESSES IT (measured on Apple TV 4K / tvOS 26.5, not assumed):
// replacing the button style. A custom `ButtonStyle` gets NO platter, whether or not it also calls
// `.focusEffectDisabled()`. So the cure is to route the button through a VortX style, NOT to sprinkle
// `.focusEffectDisabled()` at the call site. (`ChipButtonStyle` below calls it anyway, belt and braces.)
//
// THE FIX IS STRUCTURAL, in two halves:
//   1. `VortXButtonStyle` + the `vortxChipButton()` / `vortxCardButton()` / `vortxSelfFocusButton()`
//      modifiers below give every "I draw my own surface" button a correct, one-line home.
//   2. The `.plain` shadow at the BOTTOM of this file makes the wrong thing warn at the exact
//      file:line, on tvOS only, at compile time. See the note there.

/// The shared focus treatment for any VortX button that draws its OWN surface (a glass chip, a settings
/// card, a list row). This is the sanctioned replacement for `.buttonStyle(.plain)`.
///
/// It deliberately imposes NO padding, background, or typography: the caller has already composed those
/// (`.vortxGlassChip`, `.vortxSettingsCard`, ...). All this contributes is the part the call site kept
/// getting wrong, in one place:
/// - the system focus platter is gone (by virtue of being a custom style at all, plus `focusEffectDisabled`)
/// - VortX's own ember focus ring is drawn IN THE CALLER'S SHAPE, so it frames the surface instead of
///   fighting it (a capsule chip gets a capsule ring, a card gets a card ring)
/// - the focus lift and press scale match `ChipButtonStyle`, so a chip styled either way is identical
///
/// Pass `ringWidth: 0` when the button already draws its own focus treatment (e.g. tvOS `CastMemberCard`
/// lifts and rings its own circular photo); it then only stands the system platter down.
struct VortXButtonStyle<S: InsettableShape>: ButtonStyle {
    var shape: S
    var accent: Color = Theme.Palette.accent
    /// 0 = the caller owns its focus treatment; this style only suppresses the system platter.
    var ringWidth: CGFloat = 3
    var focusScale: CGFloat = 1.04

    func makeBody(configuration: Configuration) -> some View {
        VortXButtonBody(shape: shape, accent: accent, ringWidth: ringWidth,
                        focusScale: focusScale, configuration: configuration)
    }
}

/// Top-level rather than nested in `VortXButtonStyle` so the `@Environment` read happens in a real View
/// body (a `ButtonStyle.makeBody` is not one), the same split `ChipButtonStyle.Chip` uses below.
private struct VortXButtonBody<S: InsettableShape>: View {
    let shape: S
    let accent: Color
    let ringWidth: CGFloat
    let focusScale: CGFloat
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let styled = configuration.label
            .overlay(shape.strokeBorder(accent, lineWidth: focused && ringWidth > 0 ? ringWidth : 0))
            .scaleEffect(configuration.isPressed ? 0.97 : (focused && !reduceMotion ? focusScale : 1))
            .contentShape(shape)
        // `.focusEffectDisabled()` is tvOS / macOS 14+ / iOS 17+ and the iOS target deploys to 16, so gate
        // it exactly as ChipButtonStyle does. It is redundant on tvOS (a custom style already sheds the
        // platter) and kept as belt-and-braces in case a future OS revives the effect for custom styles.
        #if os(tvOS)
        return styled
            .focusEffectDisabled()
            .animation(reduceMotion ? nil : Theme.Motion.focus, value: focused)
        #else
        return styled
            .animation(reduceMotion ? nil : Theme.Motion.focus, value: focused)
        #endif
    }
}

extension View {
    /// A capsule chip that draws its own `.vortxGlassChip` surface. Ember (or `tint`) ring on focus.
    /// Matches `ChipButtonStyle`'s ring width and 1.06 lift, so the two are visually interchangeable.
    func vortxChipButton(tint: Color = Theme.Palette.accent) -> some View {
        buttonStyle(VortXButtonStyle(shape: Capsule(style: .continuous), accent: tint, focusScale: 1.06))
    }

    /// A settings card / list row that draws its own `.vortxSettingsCard()` (or equivalent) surface. A
    /// gentler 1.02 lift than a chip, because these are full-width and a big scale reads as a jolt.
    func vortxCardButton(radius: CGFloat = Theme.Radius.card,
                         accent: Color = Theme.Palette.accent) -> some View {
        buttonStyle(VortXButtonStyle(shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                                     accent: accent, focusScale: 1.02))
    }

    /// For a button that ALREADY draws its own focus treatment and just needs the system platter gone.
    /// Adds no ring and no scale of its own, so it cannot double up on the caller's.
    func vortxSelfFocusButton() -> some View {
        buttonStyle(VortXButtonStyle(shape: Rectangle(), ringWidth: 0, focusScale: 1))
    }
}

/// Filter / segment chip (shared across platforms), on the VortX design system (see Theme.swift).
///
/// Now built on the shared glass primitive (`vortxGlassChip`), so every chip flips to VortX's glass
/// elevation from one place. Three states, all warm-neutral with the ember accent reserved for meaning:
/// - **idle**     → neutral glass pill, secondary text
/// - **selected** → glass pill + ember overlay, ember text (pass `accent`/`accentText` to override, e.g. destructive)
/// - **focused**  → ember ring + lift + brightened text ON TOP of the glass, unmistakable at ten feet
struct ChipButtonStyle: ButtonStyle {
    var selected: Bool = false
    var accent: Color = Theme.Palette.accent
    var accentText: Color = Theme.Palette.accent
    private let focusMargin: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        Chip(selected: selected, accent: accent, accentText: accentText,
             focusMargin: focusMargin, configuration: configuration)
    }

    private struct Chip: View {
        let selected: Bool
        let accent: Color
        let accentText: Color
        let focusMargin: CGFloat
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let styled = configuration.label
                .font(Theme.Typography.label)
                .padding(.horizontal, Theme.Space.md)
                .padding(.vertical, Theme.Space.xs + 2)
                .foregroundStyle(textColor)
                // The one glass chip path: neutral glass base, plus the parameterized ember overlay when
                // selected (the style's `accent`, so a destructive / warn chip keeps its own tint). The
                // ember focus ring + scale below still ride ON TOP of the glass.
                .vortxGlassChip(selected: selected, tint: accent)
                .overlay(Capsule(style: .continuous).strokeBorder(accent, lineWidth: focused ? 3 : 0))
                .scaleEffect(configuration.isPressed ? 0.97 : (focused && !reduceMotion ? 1.06 : 1))
                .padding(focusMargin)
                .contentShape(Capsule(style: .continuous))
            // `.focusEffectDisabled()` is tvOS / macOS 14+ / iOS 17+. The iOS target deploys to 16,
            // so gate it. On tvOS it suppresses the system's default focus halo in favour of our ring;
            // on iOS/macOS there is no system focus halo on these chips, so dropping it is a no-op.
            #if os(tvOS)
            return styled
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Theme.Motion.focus, value: focused)
            #else
            return styled
                .animation(reduceMotion ? nil : Theme.Motion.focus, value: focused)
            #endif
        }

        private var textColor: Color {
            if selected { return accentText }
            return focused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
        }
    }
}

// MARK: - Compile-time guard: `.buttonStyle(.plain)` warns on tvOS

#if os(tvOS)
/// Make the wrong thing announce itself, because the wrong thing looks right.
///
/// `.buttonStyle(.plain)` is correct and common on iOS / macOS and silently broken on tvOS (see the note
/// at the top of this file). A reviewer cannot catch it by reading a diff, and a grep cannot be trusted
/// either: `SourceFilterChipsView` mentions "ChipButtonStyle" in a COMMENT, so it hid from a
/// "which files use ChipButtonStyle" audit while being the exact file the platter was screenshotted on.
/// So the guard has to live in the compiler, at the call site, or it does not hold.
///
/// Swift prefers a same-module member over an imported one, so this shadows SwiftUI's `.plain` for the
/// tvOS target ONLY, and every `.buttonStyle(.plain)` compiled into VortXTV now emits a deprecation
/// warning naming this message at its own file:line. iOS / macOS never see it (the attribute is
/// tvOS-scoped and this whole block is `#if os(tvOS)`), so `.plain` stays a first-class citizen there.
///
/// It is `deprecated:` and NOT `unavailable:` on purpose, and this is the part that is easy to get wrong:
/// overload resolution SKIPS an unavailable declaration and silently falls back to SwiftUI's `.plain`, so
/// an `unavailable` shadow compiles clean and warns about nothing. Verified both ways against
/// tvOS 26.5 before shipping this. A deprecated declaration stays in overload resolution, so it is the
/// one form of this trick that actually fires.
///
/// Behaviour is unchanged: this returns the same `PlainButtonStyle()` SwiftUI would have. It is a
/// diagnostic, not a substitution. If you are reading this because the warning pointed you here, use
/// `.vortxChipButton()` / `.vortxCardButton()` / `.vortxSelfFocusButton()` (top of this file). If you
/// genuinely need raw `.plain` on tvOS, `PlainButtonStyle()` spelled out longhand still works and is
/// then a deliberate, greppable, reviewable choice rather than an accident.
extension PrimitiveButtonStyle where Self == PlainButtonStyle {
    @available(tvOS, deprecated: 1.0, message: """
        .buttonStyle(.plain) does NOT suppress the tvOS system focus platter: the OS paints a white slab \
        over this button's neighbours. Use .vortxChipButton() / .vortxCardButton() / \
        .vortxSelfFocusButton() (SourcesShared/ChipButtonStyle.swift) instead.
        """)
    static var plain: PlainButtonStyle { PlainButtonStyle() }
}
#endif
