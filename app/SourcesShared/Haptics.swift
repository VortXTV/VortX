import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A tiny cross-platform haptic helper. On iPhone / iPad it drives the system feedback
/// generators; on macOS and tvOS (which have no Taptic Engine) every call is a no-op, so
/// call sites stay free of `#if` clutter and the shared UI compiles untouched on every
/// Apple target.
///
/// Keep the vocabulary deliberately small and the intent obvious at the call site:
/// - `tap()`     — a light confirmation for a discrete action (toggle, copy, pick).
/// - `success()` — a positive "that worked" notification (accepted a skip, finished a flow).
/// - `warning()` — a soft "heads up" notification (a recoverable miss, a no-op the user tried).
///
/// Use these sparingly. Haptics should punctuate intent, not narrate every state change.
enum Haptics {
    /// A light impact, for confirming a discrete tap-style action.
    static func tap() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    /// A success notification, for "that worked" moments.
    static func success() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
        #endif
    }

    /// A warning notification, for a soft "heads up".
    static func warning() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
        #endif
    }
}
