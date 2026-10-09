import Foundation

/// One read selection for Apple Home and Top Shelf. Native history remains the local
/// authority for every profile; the saved Trakt choice changes only this read surface.
enum HomeContinueWatchingSelection {
    /// PlaybackMutationTarget is an immutable value of UUIDs and credential captures. Its
    /// native identity must survive the detached Top Shelf artwork pass without recapture.
    struct Context: Hashable, @unchecked Sendable {
        let profileID: UUID?
        let usesNativeProfileState: Bool
        let usesEngineHistory: Bool
        let nativeTarget: PlaybackMutationTarget?
        var preferences: ContinueWatchingPreferences.Value = ContinueWatchingPreferences.current()
        var preferenceEpoch: UInt64 = ContinueWatchingPreferences.selectionEpoch
        var legacyCredential: CredentialScopeRegistry.Capture? = nil
        var legacyTarget: PlaybackMutationTarget? = nil

        func isCurrent(core: CoreBridge, profiles: ProfileStore) -> Bool {
            guard profileID != nil, profiles.activeID == profileID,
                  profiles.activeUsesEngineHistory == usesEngineHistory,
                  core.usesNativeProfileState == usesNativeProfileState else { return false }
            guard preferences == ContinueWatchingPreferences.current() else { return false }
            guard preferenceEpoch == ContinueWatchingPreferences.selectionEpoch, preferences.isSupported else { return false }
            guard usesNativeProfileState else {
                guard let legacyCredential, let legacyTarget else { return false }
                return CredentialScopeRegistry.shared.isCurrent(legacyCredential) && legacyTarget.stillOwnsCurrentContext(core: core)
            }
            guard let nativeTarget else { return false }
            // A UI edit can be queued or fail. Service history must not be published through
            // the new flat choice until that exact profile's durable projection acknowledges it.
            let stored = profiles.active?.discovery
            guard preferences == ContinueWatchingPreferences.value(source: stored?.continueWatchingSource,
                                                                    window: stored?.continueWatchingWindow) else { return false }
            return nativeTarget.stillOwnsCurrentContext(core: core)
        }
    }

    struct Snapshot {
        let selection: TraktPlaybackShadow.ContinueWatchingSelection
        let context: Context
        var intent: Intent { Intent(context: context, source: selection.source,
                                    traktSessionID: selection.sessionID, simklSessionID: selection.simklSessionID) }
    }
    struct Intent: Hashable, @unchecked Sendable {
        let context: Context
        let source: ContinueWatchingService
        let traktSessionID: TraktSessionID?
        let simklSessionID: SIMKLSessionID?
        func unavailableReason(id: String, type: String, videoID: String?) -> String? {
            source == .simkl ? SIMKLContinueWatchingFold.unavailableReason(id: id, type: type, videoID: videoID) : nil
        }
        func permitsDetails(id: String, type: String, videoID: String?) -> Bool {
            isCurrent() && unavailableReason(id: id, type: type, videoID: videoID) == nil
        }
        func isCurrent(core: CoreBridge = .shared, profiles: ProfileStore = .shared) -> Bool {
            guard context.isCurrent(core: core, profiles: profiles) else { return false }
            switch source {
            case .local: return traktSessionID == nil && simklSessionID == nil
            case .trakt: return traktSessionID != nil && TraktAuth.storedSessionID == traktSessionID
            case .simkl: return simklSessionID != nil && SIMKLAuth.storedSessionID == simklSessionID
            }
        }
    }
    static func refreshCurrent(core: CoreBridge = .shared, profiles: ProfileStore = .shared) {
        let snapshot = current(core: core, profiles: profiles)
        if snapshot.context.preferences.source == .simkl { SIMKLContinueWatchingShadow.shared.refresh(context: snapshot.context) }
        else if snapshot.context.preferences.source == .trakt { TraktPlaybackShadow.shared.refreshIfStale() }
    }

    static func current(
        core: CoreBridge,
        profiles: ProfileStore,
        shadow: TraktPlaybackShadow? = nil
    ) -> Snapshot {
        var context = Context(
            profileID: profiles.activeID,
            usesNativeProfileState: core.usesNativeProfileState,
            usesEngineHistory: profiles.activeUsesEngineHistory,
            nativeTarget: core.usesNativeProfileState ? .capture(core: core) : nil
        )
        if !context.usesNativeProfileState {
            context.legacyCredential = CredentialScopeRegistry.shared.capture()
            context.legacyTarget = .capture(core: core)
        }
        var unavailable = TraktPlaybackShadow.ContinueWatchingSelection(items: [], source: .local, sessionID: nil)
        unavailable.status = "Waiting for this profile's acknowledged account and Continue Watching settings…"
        if !context.preferences.isSupported { unavailable.status = "This Continue Watching source is unsupported. Choose Local / VortX, Trakt, or SIMKL in Settings." }
        guard context.isCurrent(core: core, profiles: profiles) else {
            return Snapshot(selection: unavailable, context: context)
        }

        // A native shared profile has its own core bucket too. Never fall back to its
        // retired legacy overlay, including while a native session is unavailable.
        let localItems = context.usesNativeProfileState || context.usesEngineHistory
            ? core.continueWatching : profiles.cwItems
        var selection: TraktPlaybackShadow.ContinueWatchingSelection
        let requested = context.preferences.source
        if !context.usesEngineHistory || requested == .local {
            selection = .init(items: localItems, source: .local, sessionID: nil)
            if requested != .local { selection.status = "This profile uses Local / VortX history. A service rail needs this profile's own account." }
        } else if requested == .trakt {
            selection = (shadow ?? .shared).continueWatchingSelection(
                fallback: localItems,
                libraryItems: core.library?.catalog ?? []
            )
            if selection.source != .trakt {
                selection = .init(items: [], source: .trakt, sessionID: TraktAuth.storedSessionID)
                selection.status = !TraktAuth.isConfigured ? "Trakt is unavailable in this build." : TraktAuth.storedSessionID == nil ? "Connect Trakt in Integrations to use this rail." : "Loading a complete Trakt snapshot…"
            }
        } else {
            selection = .init(items: [], source: .simkl, sessionID: nil)
            if !SIMKLAuth.isConfigured { selection.status = "SIMKL is unavailable in this build." }
            else if let session = SIMKLAuth.storedSessionID {
                let state = SIMKLContinueWatchingShadow.shared.snapshot(context: context, session: session)
                selection.simklSessionID = session
                selection.items = state.items.map {
                    CoreCWItem(id: $0.id, type: $0.type, name: $0.name,
                        poster: TraktArtworkPolicy.matchedCandidate(seedID: $0.id, seedAliases: $0.aliases, seedType: $0.type,
                            candidates: (localItems + (core.library?.catalog ?? [])).map { .init(id: $0.id, type: $0.type, poster: $0.poster) })?.poster,
                        state: CoreLibState(timeOffset: 0, duration: 0, videoId: $0.videoID, lastWatched: $0.activity))
                }
                selection.displayProgress = Dictionary(state.items.compactMap { seed in seed.progress.map { (seed.id, $0) } }, uniquingKeysWith: { first, _ in first })
                selection.captions = Dictionary(state.items.compactMap { seed in seed.caption.map { (seed.id, $0) } }, uniquingKeysWith: { first, _ in first })
                for seed in state.items where SIMKLContinueWatchingFold.unavailableReason(id: seed.id, type: seed.type, videoID: seed.videoID) != nil {
                    selection.captions[seed.id] = [seed.caption, "Playback unavailable"].compactMap { $0 }.joined(separator: " · ")
                }
                selection.status = state.failed ? "SIMKL refresh failed. Showing the last complete snapshot, if available." : state.hasSnapshot ? nil : "Loading a complete SIMKL snapshot…"
            } else { selection.status = "Connect SIMKL in Integrations to use this rail." }
        }
        selection.items = ContinueWatchingPreferences.bounded(selection.items, window: context.preferences.window, now: Date(),
            activity: { $0.state.lastWatched }, identity: { $0.type + "|" + $0.id })
        guard context.isCurrent(core: core, profiles: profiles) else {
            return Snapshot(selection: unavailable, context: context)
        }
        if selection.source == .trakt, let sessionID = selection.sessionID {
            guard TraktAuth.storedSessionID == sessionID else {
                return Snapshot(selection: unavailable, context: context)
            }
        }
        if selection.source == .simkl, let sessionID = selection.simklSessionID {
            guard SIMKLAuth.storedSessionID == sessionID else {
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
            && context.preferences.source == .trakt
            && TraktAuth.storedSessionID == sessionID
    }
}
