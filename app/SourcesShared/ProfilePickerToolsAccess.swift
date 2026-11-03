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

/// Live reference, not a SwiftUI Environment snapshot. Retirement is one-way for the route.
@MainActor
final class ProfilePickerToolsRouteAdmission {
    private var foreground: Bool
    private var retired = false
    init(isForeground: Bool) { foreground = isForeground }
    var permits: Bool { foreground && !retired }
    func setForeground(_ value: Bool) { foreground = value }
    func retire() { retired = true; foreground = false }
}

struct ProfilePickerToolsAccountOwner: Equatable, Sendable {
    let credential: CredentialScopeRegistry.Capture
    let accountID: String
}

/// Account-file authority is separate from device-wide diagnostic exception policy.
/// Captured before presenting Tools; admission is a fresh, synchronous route/PIN/foreground read.
struct ProfilePickerToolsAccountGrant: Sendable {
    let owner: ProfilePickerToolsAccountOwner?
    private let admission: @MainActor @Sendable () -> Bool
    init(owner: ProfilePickerToolsAccountOwner?, admission: @escaping @MainActor @Sendable () -> Bool) {
        self.owner = owner; self.admission = admission
    }
    @MainActor func permits(_ supplied: ProfilePickerToolsAccountOwner) -> Bool {
        owner == supplied && CredentialScopeRegistry.shared.isCurrent(supplied.credential) && admission()
    }
}

struct ProfilePickerToolsRoute: Identifiable {
    let id: UUID
    let diagnostics: ProfilePickerToolsDiagnosticGrant
    let focusDiagnostics: Bool
    let accountFiles: ProfilePickerToolsAccountGrant
    let admission: ProfilePickerToolsRouteAdmission?
    init(id: UUID = UUID(), diagnostics: ProfilePickerToolsDiagnosticGrant, focusDiagnostics: Bool,
         accountFiles: ProfilePickerToolsAccountGrant = .init(owner: nil, admission: { false }),
         admission: ProfilePickerToolsRouteAdmission? = nil) {
        self.id = id; self.diagnostics = diagnostics; self.focusDiagnostics = focusDiagnostics
        self.accountFiles = accountFiles; self.admission = admission
    }
}
