import Foundation

/// One read selection for Apple Home and Top Shelf. Native history remains the local
/// authority for every profile; the saved Trakt choice changes only this read surface.
enum HomeContinueWatchingSelection {
    /// PlaybackMutationTarget is an immutable value of UUIDs and credential captures. Its
    /// native identity must survive the detached Top Shelf artwork pass without recapture.
    struct Context: Hashable, Sendable {
        let profileID: UUID?
        let usesNativeProfileState: Bool
        let usesEngineHistory: Bool
        let nativeTarget: PlaybackMutationTarget?
        var preferences: ContinueWatchingPreferences.Value = ContinueWatchingPreferences.current()
        var preferenceEpoch: UInt64 = ContinueWatchingPreferences.selectionEpoch
        var legacyCredential: CredentialScopeRegistry.Capture? = nil
        var legacyTarget: PlaybackMutationTarget? = nil

        /// Worker-safe validation of the ORIGINAL captured owner. The scalar projection is
        /// eligibility evidence only; it never substitutes a new native/legacy target.
        func isCurrent(core: CoreBridge) -> Bool {
            guard let selection = ProfileSelectionRead.snapshot(),
                  let profile = selection.activeProfile, selection.activeID == profile.id,
                  profileID == profile.id, profile.usesEngineHistory == usesEngineHistory,
                  core.usesNativeProfileState == usesNativeProfileState else { return false }
            guard preferences == ContinueWatchingPreferences.current() else { return false }
            guard preferenceEpoch == ContinueWatchingPreferences.selectionEpoch, preferences.isSupported else { return false }
            let ownsTarget: Bool
            if usesNativeProfileState {
                guard let nativeTarget else { return false }
                // A queued/failed UI choice cannot authorize the new service rail. These
                // fields belong to the extant selected member's settled stored projection.
                guard preferences == ContinueWatchingPreferences.value(source: profile.continueWatchingSource,
                                                                        window: profile.continueWatchingWindow) else { return false }
                ownsTarget = nativeTarget.stillOwnsCurrentContext(core: core)
            } else {
                guard let legacyCredential, let legacyTarget else { return false }
                ownsTarget = CredentialScopeRegistry.shared.isCurrent(legacyCredential)
                    && legacyTarget.stillOwnsCurrentContext(core: core)
            }
            // No projection lock spans bridge/credential/defaults access. Re-read after the
            // target check so a concurrent setter or preference edit cannot supply a torn view.
            return ownsTarget && ProfileSelectionRead.snapshot() == selection
                && preferences == ContinueWatchingPreferences.current()
                && preferenceEpoch == ContinueWatchingPreferences.selectionEpoch
        }

        /// Native-only original-owner worker predicate. A missing native capture
        /// is unavailable; it never upgrades a retained legacy target or owner.
        func isCurrent(owner: CoreBridge.NativePlaybackReadCapability) -> Bool {
            guard usesNativeProfileState, owner.owns(nativeTarget), owner.isCurrent(),
                  let selection = ProfileSelectionRead.snapshot(),
                  let profile = selection.activeProfile, selection.activeID == profile.id,
                  profileID == profile.id, profile.id == owner.binding.profileID,
                  profile.usesEngineHistory == usesEngineHistory,
                  preferences == ContinueWatchingPreferences.current(),
                  preferenceEpoch == ContinueWatchingPreferences.selectionEpoch,
                  preferences.isSupported,
                  preferences == ContinueWatchingPreferences.value(source: profile.continueWatchingSource,
                      window: profile.continueWatchingWindow) else { return false }
            return owner.isCurrent() && ProfileSelectionRead.snapshot() == selection
                && preferences == ContinueWatchingPreferences.current()
                && preferenceEpoch == ContinueWatchingPreferences.selectionEpoch
        }

        /// Existing UI callsites retain their supplied owner. Worker callers use the overload
        /// above and never construct/access ProfileStore.shared from a provider or cache lock.
        @MainActor func isCurrent(core: CoreBridge, profiles: ProfileStore) -> Bool {
            guard let profile = profiles.active, profiles.activeID == profile.id,
                  profile.id == profileID, profile.usesEngineHistory == usesEngineHistory else { return false }
            return isCurrent(core: core)
        }
    }

    struct Snapshot {
        let selection: TraktPlaybackShadow.ContinueWatchingSelection
        let context: Context
        var nextEpisodes: [TraktNextEpisodeOffer] = []
        var intent: Intent { Intent(context: context, source: selection.source,
                                    traktSessionID: selection.sessionID, simklSessionID: selection.simklSessionID) }
    }
    struct Intent: Hashable, Sendable {
        let context: Context
        let source: ContinueWatchingService
        let traktSessionID: TraktSessionID?
        let simklSessionID: SIMKLSessionID?
        func unavailableReason(id: String, type: String, videoID: String?) -> String? {
            source == .simkl ? SIMKLContinueWatchingFold.unavailableReason(id: id, type: type, videoID: videoID) : nil
        }
        @MainActor
        func permitsDetails(id: String, type: String, videoID: String?) -> Bool {
            isCurrent() && unavailableReason(id: id, type: type, videoID: videoID) == nil
        }
        @MainActor
        func isCurrent(core: CoreBridge = .shared) -> Bool {
            guard context.isCurrent(core: core) else { return false }
            switch source {
            case .local: return traktSessionID == nil && simklSessionID == nil
            case .trakt: return traktSessionID != nil && TraktAuth.storedSessionID == traktSessionID
            case .simkl: return simklSessionID != nil && SIMKLAuth.storedSessionID == simklSessionID
            }
        }
        func isCurrent(owner: CoreBridge.NativePlaybackReadCapability) -> Bool {
            guard context.isCurrent(owner: owner) else { return false }
            switch source {
            case .local: return traktSessionID == nil && simklSessionID == nil
            case .trakt: return traktSessionID != nil && TraktAuth.storedSessionID == traktSessionID
            case .simkl: return simklSessionID != nil && SIMKLAuth.storedSessionID == simklSessionID
            }
        }

        @MainActor func isCurrent(core: CoreBridge, profiles: ProfileStore) -> Bool {
            guard let profile = profiles.active, profiles.activeID == profile.id,
                  profile.id == context.profileID,
                  profile.usesEngineHistory == context.usesEngineHistory else { return false }
            return isCurrent(core: core)
        }
    }

    /// Capture only immutable admission evidence. Unlike current(...), this does not assemble
    /// Home rows, visit profile overlays or acquire a provider cache while starting a refresh.
    /// A selected UUID without a matching roster member is unavailable, not an owner fallback.
    @MainActor
    static func captureContext(core: CoreBridge = .shared) -> Context? {
        guard let selection = ProfileSelectionRead.snapshot(), let profile = selection.activeProfile,
              selection.activeID == profile.id else { return nil }
        let native = core.usesNativeProfileState
        var context = Context(profileID: profile.id, usesNativeProfileState: native,
            usesEngineHistory: profile.usesEngineHistory,
            nativeTarget: native ? .capture(core: core) : nil)
        if !native {
            context.legacyCredential = CredentialScopeRegistry.shared.capture()
            context.legacyTarget = .capture(core: core)
        }
        guard ProfileSelectionRead.snapshot() == selection, context.isCurrent(core: core) else { return nil }
        return context
    }
    /// A captured native intent that went stale only because its account/session generation moved on (each sync
    /// merge republishes the binding) while the same account, profile, settings and service session remain. The
    /// next history publication re-captures it; a presenter may keep this profile's last row until then.
    @MainActor static func awaitsRecapture(_ intent: Intent, core: CoreBridge = .shared, profiles: ProfileStore? = nil) -> Bool {
        let profiles = profiles ?? .shared
        let context = intent.context
        guard let selection = ProfileSelectionRead.snapshot(), let selected = selection.activeProfile,
              selection.activeID == selected.id,
              let active = profiles.active, profiles.activeID == active.id, active.id == selected.id,
              context.usesNativeProfileState, core.usesNativeProfileState,
              let profileID = context.profileID, selected.id == profileID,
              selected.usesEngineHistory == context.usesEngineHistory,
              active.usesEngineHistory == context.usesEngineHistory,
              context.preferences == ContinueWatchingPreferences.current(),
              context.preferenceEpoch == ContinueWatchingPreferences.selectionEpoch,
              case .native(let binding?) = context.nativeTarget, binding.profileID == profileID,
              CredentialScopeRegistry.shared.isCurrent(binding.credential) else { return false }
        switch intent.source {
        case .local: return intent.traktSessionID == nil && intent.simklSessionID == nil
        case .trakt: return intent.traktSessionID != nil && TraktAuth.storedSessionID == intent.traktSessionID
        case .simkl: return intent.simklSessionID != nil && SIMKLAuth.storedSessionID == intent.simklSessionID
        }
    }
    @MainActor static func refreshCurrent(core: CoreBridge = .shared, profiles: ProfileStore? = nil) {
        let profiles = profiles ?? .shared
        guard let context = captureContext(core: core), context.isCurrent(core: core, profiles: profiles),
              let target = context.nativeTarget,
              let owner = core.captureNativePlaybackReadCapability(target),
              context.isCurrent(owner: owner) else { return }
        if context.preferences.source == .simkl {
            SIMKLContinueWatchingShadow.shared.refresh(context: context, owner: owner)
        } else if context.preferences.source == .trakt {
            TraktPlaybackShadow.shared.refreshIfStale(context: context, owner: owner)
        }
    }

    /// Only the visible Home task invokes this lane; ordinary source/settings refreshes do not.
    @MainActor static func refreshVisibleTraktNextEpisodes(core: CoreBridge = .shared, profiles: ProfileStore? = nil) {
        let profiles = profiles ?? .shared
        let snapshot = current(core: core, profiles: profiles)
        guard snapshot.intent.source == .trakt, snapshot.intent.isCurrent(core: core, profiles: profiles) else { return }
        TraktHomeNextEpisodeProducer.shared.requestRefresh(intent: snapshot.intent, core: core)
    }

    /// A newly mounted presentation has no accepted producer yet. Keep its body empty
    /// without selecting/sorting history; the source refresh installs a captured intent.
    @MainActor static func waitingForPresentation(core: CoreBridge, profiles: ProfileStore) -> Snapshot {
        let context = Context(profileID: profiles.activeID,
            usesNativeProfileState: core.usesNativeProfileState,
            usesEngineHistory: profiles.activeUsesEngineHistory, nativeTarget: nil)
        var selection = TraktPlaybackShadow.ContinueWatchingSelection(items: [], source: .local, sessionID: nil)
        selection.status = "Waiting for this profile's acknowledged account and Continue Watching settings…"
        return Snapshot(selection: selection, context: context)
    }

    @MainActor static func current(
        core: CoreBridge,
        profiles: ProfileStore,
        shadow: TraktPlaybackShadow? = nil,
        localItemsOverride: [CoreCWItem]? = nil
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

        // One original provider read admission for this synchronous presentation assembly.
        let providerOwner = context.nativeTarget.flatMap { core.captureNativePlaybackReadCapability($0) }
        // A native shared profile has its own core bucket too. Never fall back to its
        // retired legacy overlay, including while a native session is unavailable.
        let localItems = localItemsOverride ?? (context.usesNativeProfileState || context.usesEngineHistory
            ? core.continueWatching : profiles.cwItems)
        var selection: TraktPlaybackShadow.ContinueWatchingSelection
        let requested = context.preferences.source
        if !context.usesEngineHistory || requested == .local {
            selection = .init(items: localItems, source: .local, sessionID: nil)
            if requested != .local { selection.status = "This profile uses Local / VortX history. A service rail needs this profile's own account." }
        } else if requested == .trakt {
            guard let owner = providerOwner,
                  context.isCurrent(owner: owner) else { return Snapshot(selection: unavailable, context: context) }
            selection = (shadow ?? .shared).continueWatchingSelection(
                fallback: localItems,
                libraryItems: core.library?.catalog ?? [],
                context: context,
                owner: owner
            )
            if selection.source != .trakt {
                selection = .init(items: [], source: .trakt, sessionID: TraktAuth.storedSessionID)
                selection.status = !TraktAuth.isConfigured ? "Trakt is unavailable in this build." : TraktAuth.storedSessionID == nil ? "Connect Trakt in Integrations to use this rail." : "Loading a complete Trakt snapshot…"
            }
        } else {
            selection = .init(items: [], source: .simkl, sessionID: nil)
            if !SIMKLAuth.isConfigured { selection.status = "SIMKL is unavailable in this build." }
            else if let session = SIMKLAuth.storedSessionID {
                guard let owner = providerOwner,
                      context.isCurrent(owner: owner) else { return Snapshot(selection: unavailable, context: context) }
                let state = SIMKLContinueWatchingShadow.shared.snapshot(context: context, session: session, owner: owner)
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
        var result = Snapshot(selection: selection, context: context)
        if let owner = providerOwner, context.isCurrent(owner: owner) {
            result.nextEpisodes = TraktHomeNextEpisodeProducer.shared.offers(
                intent: result.intent, owner: owner, paused: selection.items, now: Date())
        }
        if selection.source != .local, let owner = providerOwner, !context.isCurrent(owner: owner) {
            return Snapshot(selection: unavailable, context: context)
        }
        guard result.intent.isCurrent(core: core, profiles: profiles) else {
            // A deliberately unavailable/disconnected service has no action capability, but its
            // empty diagnostic is still useful presentation. Never grant this exception to rows,
            // captured service sessions, next-episode offers, or a retired original owner context.
            let serviceUnavailable: Bool
            switch selection.source {
            case .local: serviceUnavailable = false
            case .trakt: serviceUnavailable = !TraktAuth.isConfigured || TraktAuth.storedSessionID == nil
            case .simkl: serviceUnavailable = !SIMKLAuth.isConfigured || SIMKLAuth.storedSessionID == nil
            }
            if serviceUnavailable, selection.items.isEmpty, selection.status != nil,
               selection.sessionID == nil, selection.simklSessionID == nil,
               context.isCurrent(core: core, profiles: profiles) {
                // Construct only the inert presentation: no actionable offers survive this path.
                return Snapshot(selection: selection, context: context)
            }
            return Snapshot(selection: unavailable, context: context)
        }
        return result
    }

    /// Used at both private-art storage and final publication. A still-connected Trakt
    /// account cannot revive artwork after the native profile/account target retired.
    @MainActor static func permitsPrivateArtworkCommit(
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
