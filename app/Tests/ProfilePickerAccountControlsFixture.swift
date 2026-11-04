import SwiftUI

@MainActor final class VortXSyncManager: ObservableObject {
    static let shared = VortXSyncManager()
    static let credentialScopeDidChangeNote = Notification.Name("fixture-credential-change")
    struct Account { let id: String; let username: String }
    @Published var isSignedIn = true
    @Published var account: Account? = Account(id: "fixture", username: "fixture")
    @Published var accountReconnectRequired = false
    func signOut() {}
}
@MainActor final class CredentialScopeRegistry {
    static let shared = CredentialScopeRegistry()
    struct Capture: Sendable, Equatable { let generation: Int }
    func capture() -> Capture { Capture(generation: 1) }
    func isCurrent(_ capture: Capture) -> Bool { capture.generation == 1 }
}
enum Theme {
    enum Space { static let sm = 8.0; static let md = 12.0 }
    enum Typography { static let label = Font.caption }
    enum Palette { static let textSecondary = Color.secondary }
}
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
