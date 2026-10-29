import Foundation

// Synthetic playback/native facades only. Authentication, credential authority,
// HTTP response/transport, admission policy, wire codec and Session are real files.
// These values model local ownership identity; they do not instantiate a player.
final class CoreBridge {
    @MainActor static let shared = CoreBridge()
    private init() {}

    // Scalar shape required to compile the unchanged current CredentialScope.
    // No async Session test constructs a subtitle proof or exercises native
    // subtitle ownership/admission. This is not an authentication replacement.
    struct NativeSubtitleOwnerProof: Equatable, Sendable {
        let domain: UUID
        let installation: UUID
        let credential: CredentialScopeRegistry.Capture
        let sourceID: UUID
        let profileID: UUID
        let accountGeneration: UUID
        let originalApplicationEpoch: UUID
    }
}

enum VortxNativeCoreFacade {
    struct NativeSubtitleOwnerProof: Equatable, Sendable {
        let bridge: CoreBridge.NativeSubtitleOwnerProof
        let profileGeneration: UUID
    }
}

struct PlaybackMutationTarget: Hashable, Sendable {
    let syntheticID: UUID
    var isCurrent = true

    @MainActor
    func stillOwnsCurrentContext(core: CoreBridge) -> Bool { isCurrent }
}

struct PlayerLoadToken: Hashable, Sendable {
    let syntheticID: UUID
}
