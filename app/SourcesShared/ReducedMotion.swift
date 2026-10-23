import SwiftUI

/// True when the interface should not animate: the system's Reduce Motion, or Animations switched off in
/// Settings > Effects and performance. Drop-in for `@Environment(\.accessibilityReduceMotion)`, and like it
/// re-renders the view the moment either changes. The app's half arrives through the environment from one
/// `visualEffectsRoot()` reader, so the many buttons and cards using this add no observers of their own.
@propertyWrapper
struct ReducedMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.effectsMotionReduced) private var app

    var wrappedValue: Bool { system || app }
}

private struct EffectsMotionReducedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Animations switched off in Settings > Effects and performance (or by Auto on a reduced Apple TV).
    var effectsMotionReduced: Bool {
        get { self[EffectsMotionReducedKey.self] }
        set { self[EffectsMotionReducedKey.self] = newValue }
    }
}

private struct VisualEffectsRoot: ViewModifier {
    @AppStorage(VisualEffects.motionKey) private var motionChoice = VisualEffects.auto

    func body(content: Content) -> some View {
        content.environment(\.effectsMotionReduced,
                            !VisualEffects.motion(stored: motionChoice, reduced: VisualEffects.reducedForAuto))
    }
}

extension View {
    /// Reads Settings > Effects and performance once at the app root and hands it to every view below.
    func visualEffectsRoot() -> some View { modifier(VisualEffectsRoot()) }
}
