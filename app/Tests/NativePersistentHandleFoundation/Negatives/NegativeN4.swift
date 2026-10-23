import Foundation

// N4: no public initializer or raw pointer API exists for a forged capability.
func cannotForgeCapability(_ runtime: VortxNativeRuntime) {
    _ = VortxNativeRuntime.Reservation(owner: runtime, identity: UUID(), generation: UUID())
}
