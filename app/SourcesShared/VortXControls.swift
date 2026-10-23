import SwiftUI

/// A choice between a few options, drawn as VortX chips so the selection carries the chosen accent. The system
/// segmented control draws its selected segment in neutral grey (macOS and iOS dark mode alike) and ignores
/// the app's tint, which left these choices as the only uncoloured selections in the app.
struct VortXSegmented<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: LocalizedStringKey
        var id: Value { value }
    }

    let options: [Option]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: { Text(option.title) }
                    .buttonStyle(ChipButtonStyle(selected: selected))
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}

#if !os(tvOS)
/// The VortX slider: an accent-filled capsule track and a knob, drawn here so it carries the chosen accent.
/// The macOS system slider ignores the app's tint and paints in the system colour (the player's volume slider
/// came out white). Drag anywhere on it, or adjust with VoiceOver / the arrow keys in 5% steps.
struct VortXSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false
    @ReducedMotion private var reduceMotion

    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }
    private var fraction: Double { min(max((value - range.lowerBound) / span, 0), 1) }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let knob: CGFloat = dragging ? 14 : 12
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.textPrimary.opacity(0.22)).frame(height: 4)
                Capsule().fill(Theme.Palette.accent).frame(width: width * fraction, height: 4)
                Circle()
                    .fill(Theme.Palette.textPrimary)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: min(max(width * fraction - knob / 2, 0), width - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        let ratio = min(max(gesture.location.x / width, 0), 1)
                        value = range.lowerBound + ratio * span
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
            .animation(reduceMotion ? nil : Theme.Motion.state, value: dragging)
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = span * 0.05
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}
#endif
