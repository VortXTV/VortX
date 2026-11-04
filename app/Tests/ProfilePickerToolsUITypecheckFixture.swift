import SwiftUI

// Compile-only collaborators for unrelated artwork/material state. Theme's actual
// enum and ChipButtonStyle/ReducedMotion/VisualEffects sources are compiler inputs.
// This file is never linked or executed; no appearance/lifecycle result is claimed.
@MainActor final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    var textScale: Double { preconditionFailure("typecheck-only theme") }
    var canvas: Color { preconditionFailure("typecheck-only theme") }
    var surface1: Color { preconditionFailure("typecheck-only theme") }
    var surface2: Color { preconditionFailure("typecheck-only theme") }
    var surface3: Color { preconditionFailure("typecheck-only theme") }
    var hairline: Color { preconditionFailure("typecheck-only theme") }
    var glassVeil: Color { preconditionFailure("typecheck-only theme") }
    var accent: Color { preconditionFailure("typecheck-only theme") }
    var accentBright: Color { preconditionFailure("typecheck-only theme") }
    var playerGlassAccent: Color { preconditionFailure("typecheck-only theme") }
    var playerGlassUsesCrimson: Bool { preconditionFailure("typecheck-only theme") }
    var onAccent: Color { preconditionFailure("typecheck-only theme") }
}
extension View {
    // Unrelated material implementation is deliberately not part of this focused gate.
    func vortxGlassControl<S: InsettableShape>(in shape: S, active: Bool) -> some View { self }
    func vortxGlassChip(selected: Bool, tint: Color) -> some View { self }
}

@MainActor private struct ProfilePickerToolsUITypecheckHost: View {
    private var route: ProfilePickerToolsRoute {
        ProfilePickerToolsRoute(diagnostics: .init(allowed: false,
            credential: .init(scope: .signedOutDevice, generation: 0), admission: { false }),
            focusDiagnostics: false)
    }
    var body: some View {
        VStack {
            ProfilePickerToolsView(route: route,
                services: .live(restore: .live, accountGrant: route.accountFiles), onClose: {})
            DiagnosticLogExportButton(grant: route.diagnostics)
            DiagnosticLogExportButton() // Existing unlocked-settings call sites retain this API.
        }
    }
}
