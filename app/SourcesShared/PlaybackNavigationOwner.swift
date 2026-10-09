import Foundation

/// Read-only return navigation survives non-identity sync work. Never use this fence for progress,
/// watched, provider or account writes: those require PlaybackMutationTarget's stronger admission.
@MainActor
struct PlaybackNavigationOwner {
#if VORTX_NATIVE_DATA_ENGINE
    private let target: CoreBridge.NativeNavigationTarget?
    init(core: CoreBridge) { target = core.captureNativeNavigationTarget() }
    func isCurrent(core: CoreBridge) -> Bool {
        guard let target else { return false }
        return core.nativeNavigationTargetIsCurrent(target)
    }
#else
    private let profileID: UUID?
    private let profileEpoch: UInt64
    private let credential: CredentialScopeRegistry.Capture
    private let accountSlot: String
    private let accountEpoch: UInt64
    init(core: CoreBridge) {
        profileID = ProfileStore.shared.activeID
        profileEpoch = ContinueWatchingPreferences.selectionEpoch
        credential = CredentialScopeRegistry.shared.capture()
        accountSlot = ProfileStore.shared.activeKeychainAccount
        accountEpoch = StremioAccount.shared.credentialBoundaryGeneration
    }
    func isCurrent(core: CoreBridge) -> Bool {
        ProfileStore.shared.activeID == profileID
            && ContinueWatchingPreferences.selectionEpoch == profileEpoch
            && CredentialScopeRegistry.shared.isCurrent(credential)
            && ProfileStore.shared.activeKeychainAccount == accountSlot
            && StremioAccount.shared.credentialBoundaryGeneration == accountEpoch
    }
#endif
}
