import SwiftUI

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
