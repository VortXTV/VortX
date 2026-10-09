import Foundation

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
        core.fifoBusy = true
        let captured = PlaybackNavigationOwner(core: core)
        precondition(!core.mutationAvailable && captured.isCurrent(core: core))
        var receipt = EpisodeReturnReceiptState<Int, String>()
        receipt.begin(requestID: 1)
        _ = receipt.recordAttempt("series:2:2", requestID: 1)
        if captured.isCurrent(core: core) { _ = receipt.record("series:2:3", requestID: 1) }
        core.fifoBusy = false
        core.fifoBusy = true
        precondition(captured.isCurrent(core: core))
        _ = receipt.close(requestID: 1)
        precondition(receipt.closedReceipt?.meta == "series:2:3")
        print("PASS held unchanged sync at capture, first frame and close retains accepted E3")
        let original = core.current!
        core.current = .init(credential: original.credential, installation: original.installation,
            profile: original.profile, accountGeneration: original.accountGeneration, profileGeneration: UUID())
        precondition(!captured.isCurrent(core: core))
        print("PASS acknowledged profile ABA retires navigation owner")
        core.current = .init(credential: original.credential, installation: UUID(), profile: original.profile,
            accountGeneration: original.accountGeneration, profileGeneration: original.profileGeneration)
        precondition(!captured.isCurrent(core: core))
        print("PASS same-account installation replacement retires navigation owner")
        core.current = .init(credential: original.credential, installation: original.installation,
            profile: original.profile, accountGeneration: UUID(), profileGeneration: original.profileGeneration)
        precondition(!captured.isCurrent(core: core))
        print("PASS account rebind retires navigation owner")
        core.current = nil
        precondition(!captured.isCurrent(core: core))
        let unavailable = PlaybackNavigationOwner(core: core)
        core.current = original
        precondition(!unavailable.isCurrent(core: core))
        print("PASS logout and unacknowledged capture fail closed")
    }
}
