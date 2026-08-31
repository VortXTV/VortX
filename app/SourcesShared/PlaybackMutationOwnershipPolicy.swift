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

    /// An inactive overlay may not have been played before, hence no cache file exists yet. Its
    /// first callback must start from an empty dictionary rather than being silently discarded.
    static func overlayEntries<Entry: Decodable>(from data: Data?, as: Entry.Type) -> [String: Entry] {
        guard let data, let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return entries
    }
}
