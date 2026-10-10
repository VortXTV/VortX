import Foundation

/// Read-only return navigation survives non-identity sync work. Never use this fence for progress,
/// watched, provider or account writes: those require PlaybackMutationTarget's stronger admission.
@MainActor
struct PlaybackNavigationOwner {
#if VORTX_NATIVE_DATA_ENGINE
    private let target: CoreBridge.NativeNavigationTarget?
    init(core: CoreBridge, account: StremioAccount) { target = core.captureNativeNavigationTarget() }
    func isCurrent(core: CoreBridge, account: StremioAccount) -> Bool {
        guard let target else { return false }
        return core.nativeNavigationTargetIsCurrent(target)
    }
#else
    private let profileID: UUID?
    private let profileEpoch: UInt64
    private let credential: CredentialScopeRegistry.Capture
    private let accountSlot: String
    private let accountEpoch: UInt64
    private let account: StremioAccount
    init(core: CoreBridge, account: StremioAccount) {
        profileID = ProfileStore.shared.activeID
        profileEpoch = ContinueWatchingPreferences.selectionEpoch
        credential = CredentialScopeRegistry.shared.capture()
        accountSlot = ProfileStore.shared.activeKeychainAccount
        self.account = account
        accountEpoch = account.credentialBoundaryGeneration
    }
    func isCurrent(core: CoreBridge, account: StremioAccount) -> Bool {
        account === self.account
            && ProfileStore.shared.activeID == profileID
            && ContinueWatchingPreferences.selectionEpoch == profileEpoch
            && CredentialScopeRegistry.shared.isCurrent(credential)
            && ProfileStore.shared.activeKeychainAccount == accountSlot
            && account.credentialBoundaryGeneration == accountEpoch
    }
#endif
}
