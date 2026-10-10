import Foundation

@MainActor
final class StremioAccount {
    var credentialBoundaryGeneration: UInt64 = 0
}

#if !VORTX_NATIVE_DATA_ENGINE
@MainActor
final class ProfileStore {
    static let shared = ProfileStore()
    var activeID: UUID? = UUID()
    var activeKeychainAccount = "fixture.account"
}
@MainActor
enum ContinueWatchingPreferences {
    static var selectionEpoch: UInt64 = 0
}
@MainActor
final class CredentialScopeRegistry {
    struct Capture: Equatable { let epoch: UInt64 }
    static let shared = CredentialScopeRegistry()
    var epoch: UInt64 = 0
    func capture() -> Capture { .init(epoch: epoch) }
    func isCurrent(_ capture: Capture) -> Bool { capture.epoch == epoch }
}
#endif

/// The production navigation wrapper is compiled below against a held-FIFO projection. Mutation
/// readiness intentionally becomes unavailable, while the acknowledged navigation receipt does not.
@MainActor
final class CoreBridge {
    struct NativeNavigationTarget: Equatable {
        let credential: UUID
        let installation: UUID
        let profile: UUID
        let accountGeneration: UUID
        let profileGeneration: UUID
    }
    var current: NativeNavigationTarget? = .init(credential: UUID(), installation: UUID(), profile: UUID(),
        accountGeneration: UUID(), profileGeneration: UUID())
    var fifoBusy = false
    var mutationAvailable: Bool { !fifoBusy && current != nil }
    func captureNativeNavigationTarget() -> NativeNavigationTarget? { current }
    func nativeNavigationTargetIsCurrent(_ target: NativeNavigationTarget) -> Bool { current == target }
}

@main @MainActor
enum PlaybackNavigationOwnerTests {
    static func main() {
        let core = CoreBridge()
        let account = StremioAccount()
        core.fifoBusy = true
        let captured = PlaybackNavigationOwner(core: core, account: account)
        precondition(!core.mutationAvailable && captured.isCurrent(core: core, account: account))
        var receipt = EpisodeReturnReceiptState<Int, String>()
        receipt.begin(requestID: 1)
        _ = receipt.recordAttempt("series:2:2", requestID: 1)
        if captured.isCurrent(core: core, account: account) { _ = receipt.record("series:2:3", requestID: 1) }
        core.fifoBusy = false
        core.fifoBusy = true
        precondition(captured.isCurrent(core: core, account: account))
        _ = receipt.close(requestID: 1)
        precondition(receipt.closedReceipt?.meta == "series:2:3")
        print("PASS held unchanged sync at capture, first frame and close retains accepted E3")
        #if VORTX_NATIVE_DATA_ENGINE
        let original = core.current!
        core.current = .init(credential: original.credential, installation: original.installation,
            profile: original.profile, accountGeneration: original.accountGeneration, profileGeneration: UUID())
        precondition(!captured.isCurrent(core: core, account: account))
        print("PASS acknowledged profile ABA retires navigation owner")
        core.current = .init(credential: original.credential, installation: UUID(), profile: original.profile,
            accountGeneration: original.accountGeneration, profileGeneration: original.profileGeneration)
        precondition(!captured.isCurrent(core: core, account: account))
        print("PASS same-account installation replacement retires navigation owner")
        core.current = .init(credential: original.credential, installation: original.installation,
            profile: original.profile, accountGeneration: UUID(), profileGeneration: original.profileGeneration)
        precondition(!captured.isCurrent(core: core, account: account))
        print("PASS account rebind retires navigation owner")
        core.current = nil
        precondition(!captured.isCurrent(core: core, account: account))
        let unavailable = PlaybackNavigationOwner(core: core, account: account)
        core.current = original
        precondition(!unavailable.isCurrent(core: core, account: account))
        print("PASS logout and unacknowledged capture fail closed")
        #else
        precondition(!captured.isCurrent(core: core, account: StremioAccount()))
        print("PASS replacement account instance cannot reuse the legacy receipt")
        account.credentialBoundaryGeneration &+= 1
        precondition(!captured.isCurrent(core: core, account: account))
        print("PASS same-slot credential boundary retires the legacy receipt")
        let afterAccountChange = PlaybackNavigationOwner(core: core, account: account)
        let originalProfile = ProfileStore.shared.activeID
        ProfileStore.shared.activeID = UUID()
        precondition(!afterAccountChange.isCurrent(core: core, account: account))
        ProfileStore.shared.activeID = originalProfile
        ContinueWatchingPreferences.selectionEpoch &+= 1
        precondition(!afterAccountChange.isCurrent(core: core, account: account))
        print("PASS profile ABA retires the legacy receipt")
        let afterProfileChange = PlaybackNavigationOwner(core: core, account: account)
        ProfileStore.shared.activeKeychainAccount = "fixture.other"
        precondition(!afterProfileChange.isCurrent(core: core, account: account))
        ProfileStore.shared.activeKeychainAccount = "fixture.account"
        CredentialScopeRegistry.shared.epoch &+= 1
        precondition(!afterProfileChange.isCurrent(core: core, account: account))
        print("PASS account-slot and credential-generation changes retire the legacy receipt")
        #endif
    }
}
