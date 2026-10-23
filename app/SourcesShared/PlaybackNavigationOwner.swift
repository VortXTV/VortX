import Foundation

/// Read-only return navigation survives non-identity sync work. Never use this fence for progress,
/// watched, provider or account writes: those require PlaybackMutationTarget's stronger admission.
@MainActor
struct PlaybackNavigationOwner {
    private let target: CoreBridge.NativeNavigationTarget?
    init(core: CoreBridge, account: StremioAccount) { target = core.captureNativeNavigationTarget() }
    func isCurrent(core: CoreBridge, account: StremioAccount) -> Bool {
        guard let target else { return false }
        return core.nativeNavigationTargetIsCurrent(target)
    }
}
