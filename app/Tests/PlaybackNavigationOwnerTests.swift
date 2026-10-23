import Foundation

@MainActor
final class StremioAccount {
    var credentialBoundaryGeneration: UInt64 = 0
}

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
        let original = core.current!
        core.current = .init(credential: UUID(), installation: original.installation,
            profile: original.profile, accountGeneration: original.accountGeneration, profileGeneration: original.profileGeneration)
        precondition(!captured.isCurrent(core: core, account: account))
        print("PASS credential epoch replacement retires navigation owner")
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
    }
}
