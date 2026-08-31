import Foundation

/// Pure ownership gate for player callbacks. It is deliberately independent of SwiftUI and the
/// engine so the profile-switch cases can be tested without a running player.
enum PlaybackMutationOwnershipPolicy {
    enum Target: Hashable {
        case engine(profileID: UUID?, keychainAccount: String, uid: String?)
        case overlay(profileID: UUID)
    }

    struct Context: Equatable {
        let activeProfileID: UUID?
        let activeUsesEngineHistory: Bool
        let activeKeychainAccount: String
        let activeUID: String?
        let extantOverlayProfileIDs: Set<UUID>
    }

    /// A credential may be used for an account write only after the engine has emitted an
    /// authenticated context for the exact profile/account/token tuple that initiated auth.
    /// This is intentionally stronger than looking at the currently selected profile and UID:
    /// during A -> B, those can briefly describe B while the engine still contains A.
    struct SettledAccountBinding: Equatable {
        let profileID: UUID
        let keychainAccount: String
        let credentialFingerprint: String
        let uid: String
        let generation: UInt64
    }

    /// Receipt from an authenticated `getUser` request using the exact token that initiated an
    /// engine auth. It is not derived from token contents and can therefore prove both restored
    /// sessions and a same-UID reauthentication.
    struct AuthenticatedAccountProof: Equatable {
        let profileID: UUID
        let keychainAccount: String
        let credentialFingerprint: String
        let uid: String
        let generation: UInt64
    }

    static func settle(_ proof: AuthenticatedAccountProof, activeProfileID: UUID?,
                       activeUsesEngineHistory: Bool, activeKeychainAccount: String,
                       activeCredentialFingerprint: String?, engineUID: String?) -> SettledAccountBinding? {
        guard proof.profileID == activeProfileID,
              activeUsesEngineHistory,
              proof.keychainAccount == activeKeychainAccount,
              proof.credentialFingerprint == activeCredentialFingerprint,
              proof.uid == engineUID else { return nil }
        return .init(profileID: proof.profileID, keychainAccount: proof.keychainAccount,
                     credentialFingerprint: proof.credentialFingerprint, uid: proof.uid,
                     generation: proof.generation)
    }

    static func bindingIsCurrent(_ captured: SettledAccountBinding,
                                 current: SettledAccountBinding?) -> Bool {
        captured == current
    }

    /// Resolver writes are account mutations, so a profile/uid-only player target is insufficient.
    /// The target must be paired with the immutable credential binding captured before suspension.
    static func allowsResolverDispatch(target: Target?, binding: SettledAccountBinding?) -> Bool {
        guard let binding, case let .engine(profileID, account, uid) = target else { return false }
        return profileID == binding.profileID && account == binding.keychainAccount && uid == binding.uid
    }

    static func allowsLocalOnlyRecovery(engineSignedIn: Bool, engineUID: String?, switchInFlight: Bool,
                                        hasPendingBinding: Bool, authMigration: Bool,
                                        activeProfileIsOwner: Bool, activeUsesEngineHistory: Bool,
                                        credentialCurrent: Bool) -> Bool {
        !engineSignedIn && engineUID == nil && !switchInFlight && !hasPendingBinding
            && !authMigration && activeProfileIsOwner && activeUsesEngineHistory && credentialCurrent
    }

    static func blocksEnginePublication(hasPendingBinding: Bool, credentialRejected: Bool,
                                        signedOutRepairPending: Bool = false) -> Bool {
        hasPendingBinding || credentialRejected || signedOutRepairPending
    }

    static func allowsRepairHydration(engineSignedIn: Bool, hasSettledBinding: Bool) -> Bool {
        !engineSignedIn || hasSettledBinding
    }

    static func mayPublish(capturedGeneration: UInt64, currentGeneration: UInt64, blocked: Bool) -> Bool {
        capturedGeneration == currentGeneration && !blocked
    }

    static func allows(_ target: Target, in context: Context) -> Bool {
        switch target {
        case .overlay(let profileID):
            // An overlay player owns its captured cache even after it stops being the active view.
            return context.extantOverlayProfileIDs.contains(profileID)
        case .engine(let profileID, let account, let uid):
            guard context.activeProfileID == profileID,
                  context.activeUsesEngineHistory,
                  context.activeKeychainAccount == account else { return false }
            // `nil` is an identity too. Treating a missing launch uid as a wildcard would let a
            // later sign-in in the same profile/keychain slot inherit an old callback.
            return context.activeUID == uid
        }
    }

    static func allowsAccountMutation(_ target: Target, in context: Context) -> Bool {
        guard case .engine = target else { return false }
        return allows(target, in: context)
    }

    static func allowsQueuedAccountReplay(profileID: UUID, account: String, credentialFingerprint: String,
                                          binding: SettledAccountBinding?) -> Bool {
        guard let binding else { return false }
        return profileID == binding.profileID
            && account == binding.keychainAccount
            && credentialFingerprint == binding.credentialFingerprint
    }

    /// An inactive overlay may not have been played before, hence no cache file exists yet. Its
    /// first callback must start from an empty dictionary rather than being silently discarded.
    static func overlayEntries<Entry: Decodable>(from data: Data?, as: Entry.Type) -> [String: Entry] {
        guard let data, let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return entries
    }
}
