import Foundation

/// One read selection for Apple Home and Top Shelf. Native history remains the local
/// authority for every profile; the saved Trakt choice changes only this read surface.
enum HomeContinueWatchingSelection {
    /// PlaybackMutationTarget is an immutable value of UUIDs and credential captures. Its
    /// native identity must survive the detached Top Shelf artwork pass without recapture.
    struct Context: Equatable, @unchecked Sendable {
        let profileID: UUID?
        let usesNativeProfileState: Bool
        let usesEngineHistory: Bool
        let nativeTarget: PlaybackMutationTarget?

        func isCurrent(core: CoreBridge, profiles: ProfileStore) -> Bool {
            guard profiles.activeID == profileID,
                  profiles.activeUsesEngineHistory == usesEngineHistory,
                  core.usesNativeProfileState == usesNativeProfileState else { return false }
            guard usesNativeProfileState else { return true }
            guard let nativeTarget else { return false }
            return nativeTarget.stillOwnsCurrentContext(core: core)
        }
    }

    struct Snapshot {
        let selection: TraktPlaybackShadow.ContinueWatchingSelection
        let context: Context
    }

    static func current(
        core: CoreBridge,
        profiles: ProfileStore,
        shadow: TraktPlaybackShadow? = nil
    ) -> Snapshot {
        let context = Context(
            profileID: profiles.activeID,
            usesNativeProfileState: core.usesNativeProfileState,
            usesEngineHistory: profiles.activeUsesEngineHistory,
            nativeTarget: core.usesNativeProfileState ? .capture(core: core) : nil
        )
        let unavailable = TraktPlaybackShadow.ContinueWatchingSelection(items: [], source: .local, sessionID: nil)
        guard context.isCurrent(core: core, profiles: profiles) else {
            return Snapshot(selection: unavailable, context: context)
        }

        // A native shared profile has its own core bucket too. Never fall back to its
        // retired legacy overlay, including while a native session is unavailable.
        let localItems = context.usesNativeProfileState || context.usesEngineHistory
            ? core.continueWatching : profiles.cwItems
        let selection = context.usesEngineHistory
            ? (shadow ?? .shared).continueWatchingSelection(
                fallback: localItems,
                libraryItems: core.library?.catalog ?? []
            )
            : .init(items: localItems, source: .local, sessionID: nil)
        guard context.isCurrent(core: core, profiles: profiles) else {
            return Snapshot(selection: unavailable, context: context)
        }
        if selection.source == .trakt {
            guard let sessionID = selection.sessionID, TraktAuth.storedSessionID == sessionID else {
                return Snapshot(selection: unavailable, context: context)
            }
        }
        return Snapshot(selection: selection, context: context)
    }

    /// Used at both private-art storage and final publication. A still-connected Trakt
    /// account cannot revive artwork after the native profile/account target retired.
    static func permitsPrivateArtworkCommit(
        context: Context,
        sessionID: TraktSessionID,
        core: CoreBridge,
        profiles: ProfileStore
    ) -> Bool {
        context.isCurrent(core: core, profiles: profiles)
            && context.usesEngineHistory
            && ExternalSyncToggle.isOn(ExternalSyncToggle.traktContinueWatching, default: false)
            && TraktAuth.storedSessionID == sessionID
    }
}
