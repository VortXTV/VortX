import Foundation

/// Frozen admission for a device-wide log: a failed-profile grant survives presenting Tools,
/// while any credential replacement revokes it, including an account ABA round trip.
struct ProfilePickerToolsDiagnosticGrant: Sendable {
    let allowed: Bool
    let credential: CredentialScopeRegistry.Capture
    private let admission: @MainActor @Sendable () -> Bool
    init(allowed: Bool, credential: CredentialScopeRegistry.Capture,
         admission: @escaping @MainActor @Sendable () -> Bool) {
        self.allowed = allowed; self.credential = credential; self.admission = admission
    }
    @MainActor var permitsExport: Bool {
        allowed && CredentialScopeRegistry.shared.isCurrent(credential) && admission()
    }
    enum Refusal: Error { case permissionChanged }
    func requireForExport() async throws {
        try Task.checkCancellation()
        guard await permitsExport else { throw Refusal.permissionChanged }
    }
}

struct ProfilePickerToolsRoute: Identifiable {
    let id = UUID()
    let diagnostics: ProfilePickerToolsDiagnosticGrant
    let focusDiagnostics: Bool
}
