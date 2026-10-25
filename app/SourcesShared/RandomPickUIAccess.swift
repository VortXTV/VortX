import Foundation

/// One UI admission witness for every Random Pick caller. A native playback target
/// alone does not describe roster edits (including Kids/PIN) or a pending picker.
/// This snapshot remains in memory only; never log or persist profile fields.
struct RandomPickUIAccess {
    let profile: UserProfile
    let target: PlaybackMutationTarget
    let navigationTarget: CoreBridge.NativeAcceptedNavigationTarget

    @MainActor
    static func capture(profiles: ProfileStore, core: CoreBridge) -> RandomPickUIAccess? {
        guard !profiles.needsPicker, let profile = profiles.active,
              profiles.activeID == profile.id else { return nil }
        let target = PlaybackMutationTarget.capture(core: core)
        guard target.stillOwnsCurrentContext(core: core) else { return nil }
        guard let navigationTarget = core.captureNativeAcceptedNavigationTarget(),
              !profiles.needsPicker, profiles.activeID == profile.id, profiles.active == profile,
              target.stillOwnsCurrentContext(core: core),
              core.nativeAcceptedNavigationTargetIsCurrent(navigationTarget) else { return nil }
        return RandomPickUIAccess(profile: profile, target: target, navigationTarget: navigationTarget)
    }

    @MainActor
    func isCurrent(profiles: ProfileStore, core: CoreBridge) -> Bool {
        !profiles.needsPicker && profiles.activeID == profile.id
            && profiles.active == profile && target.stillOwnsCurrentContext(core: core)
    }

    /// Once navigation is accepted, presentation/playback preferences belong to the normal detail/player.
    /// Keep identity and security boundaries without dismissing playback for a subtitle-style save.
    @MainActor
    func isNavigationCurrent(profiles: ProfileStore, core: CoreBridge) -> Bool {
        !profiles.needsPicker && profiles.activeID == profile.id
            && navigationProfileMatches(profiles.active)
            && core.nativeAcceptedNavigationTargetIsCurrent(navigationTarget)
    }

    func matchesPublishedNavigationProfiles(_ incoming: [UserProfile], pickedThisLaunch: Bool) -> Bool {
        !(incoming.count > 1 && !pickedThisLaunch)
            && navigationProfileMatches(incoming.first(where: { $0.id == profile.id }))
    }

    private func navigationProfileMatches(_ current: UserProfile?) -> Bool {
        guard let current else { return false }
        return current.id == profile.id && current.pin == profile.pin && current.isKids == profile.isKids
            && current.usesOwnAccount == profile.usesOwnAccount && current.isOwner == profile.isOwner
            && current.email == profile.email && current.familyEdit == profile.familyEdit
    }

    /// @Published emits in willSet. Compare the incoming roster, not profiles.active
    /// from the still-old stored roster. Added profiles can also require the picker.
    func matchesPublishedProfiles(_ incoming: [UserProfile], pickedThisLaunch: Bool) -> Bool {
        !(incoming.count > 1 && !pickedThisLaunch)
            && incoming.first(where: { $0.id == profile.id }) == profile
    }
}
