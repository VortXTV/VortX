import Combine
import Foundation

// Only application-global surfaces are fixtures. Credential ownership/outbox, JSON parsing,
// legacy/rich models, credential-exclusion and transport implementations are actual sources.
// No real application, native session, credential backend or account is installed by this harness.
@MainActor final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()
    @Published var activeID: UUID?
}

@MainActor final class VortXSyncManager: ObservableObject {
    static let shared = VortXSyncManager()
    static let credentialScopeDidChangeNote = Notification.Name("fixture.credentialScopeDidChange")
    @Published var isSignedIn = false
}

enum CoreBridge {
    struct NativeXperienceTarget: Sendable {}
    static let xperienceContextChangedNote = Notification.Name("fixture.xperienceContextChanged")
}
