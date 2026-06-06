import SwiftUI

/// A pill/chip button with explicit, high-contrast colours for tvOS.
///
/// Fixes the low-contrast "selected" state of `.bordered` + `.tint`, where the label is drawn in
/// the same hue as the fill (cyan text on a cyan fill, red text on a red fill). Here the fill and
/// text are chosen independently, and focus is shown with a bright white pill + a lift so the
/// focused chip is unmistakable.
///
/// Three states:
/// - **focused**  → white pill, black text (the system focus highlight)
/// - **selected** → accent pill, `accentText` text (cyan is light, so black reads best on it)
/// - **idle**     → subtle dark pill, white text
struct ChipButtonStyle: ButtonStyle {
    var selected: Bool = false
    var accent: Color = .cyan
    var accentText: Color = .black     // text colour to use on the accent fill

    func makeBody(configuration: Configuration) -> some View {
        Chip(selected: selected, accent: accent, accentText: accentText, configuration: configuration)
    }

    private struct Chip: View {
        let selected: Bool
        let accent: Color
        let accentText: Color
        let configuration: Configuration
        @Environment(\.isFocused) private var focused: Bool

        var body: some View {
            configuration.label
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .foregroundStyle(textColor)
                .background(fill, in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.96 : (focused ? 1.08 : 1.0))
                .animation(.easeOut(duration: 0.15), value: focused)
        }

        private var fill: Color {
            if focused { return .white }
            if selected { return accent }
            return Color.white.opacity(0.14)
        }
        private var textColor: Color {
            if focused { return .black }
            if selected { return accentText }
            return .white
        }
    }
}
