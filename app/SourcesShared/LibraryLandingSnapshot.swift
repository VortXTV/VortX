import Foundation

/// A Library read owns the same immutable profile/account/native epoch as its rendered actions.
/// Saved membership is deliberately absent from the native history path.
enum LibraryLandingSnapshot {
    struct Context: Hashable {
        let profileID: UUID?
        let usesNativeProfileState: Bool
        let usesEngineHistory: Bool
        let credential: CredentialScopeRegistry.Capture
        let target: PlaybackMutationTarget

        func isCurrent(core: CoreBridge, profiles: ProfileStore) -> Bool {
            profileID != nil && profiles.activeID == profileID
                && profiles.activeUsesEngineHistory == usesEngineHistory
                && core.usesNativeProfileState == usesNativeProfileState
                && CredentialScopeRegistry.shared.isCurrent(credential)
                && target.stillOwnsCurrentContext(core: core)
        }
    }

    struct Entry: Identifiable {
        let item: CoreCWItem
        /// The same show may have several watched episodes. Keep physical video identity in the grid.
        var id: String { [item.type, item.id, item.state.videoId ?? item.id].map { "\($0.utf8.count):\($0)" }.joined() }
        var episodeCaption: String? {
            guard let video = item.state.videoId, video.hasPrefix(item.id + ":") else { return nil }
            let suffix = video.dropFirst(item.id.count + 1).split(separator: ":", omittingEmptySubsequences: false)
            guard suffix.count == 2, let season = Int(suffix[0]), let episode = Int(suffix[1]),
                  season >= 0, episode > 0 else { return nil }
            return "S\(season) · E\(episode)"
        }
    }

    struct Snapshot {
        let context: Context
        /// nil means unavailable; [] is a successfully read, genuinely empty history.
        let history: [Entry]?
        let continueWatching: HomeContinueWatchingSelection.Snapshot
    }

    @MainActor
    static func current(core: CoreBridge, profiles: ProfileStore) -> Snapshot {
        let context = Context(profileID: profiles.activeID, usesNativeProfileState: core.usesNativeProfileState,
                              usesEngineHistory: profiles.activeUsesEngineHistory,
                              credential: CredentialScopeRegistry.shared.capture(), target: .capture(core: core))
        let cw = HomeContinueWatchingSelection.current(core: core, profiles: profiles)
        guard context.isCurrent(core: core, profiles: profiles) else {
            return .init(context: context, history: nil, continueWatching: cw)
        }
        let rows: [CoreCWItem]?
        if context.usesNativeProfileState {
            #if VORTX_NATIVE_DATA_ENGINE
            rows = core.nativeHistorySnapshot(target: context.target)?.items
            #else
            rows = nil
            #endif
        } else if !context.usesEngineHistory {
            rows = overlayHistory(profiles.watch)
        } else {
            rows = acceptedLegacyHistory(core: core, context: context)
        }
        let history = rows.flatMap(completeHistory)
        guard context.isCurrent(core: core, profiles: profiles) else {
            return .init(context: context, history: nil, continueWatching: cw)
        }
        return .init(context: context, history: history, continueWatching: cw)
    }

    /// Reject the complete snapshot on invalid identity/numbers instead of quietly dropping rows.
    static func completeHistory(_ rows: [CoreCWItem]) -> [Entry]? {
        guard rows.allSatisfy({ !$0.id.isEmpty && !$0.type.isEmpty && !$0.name.isEmpty
            && $0.state.timeOffset.isFinite && $0.state.timeOffset >= 0
            && $0.state.duration.isFinite && $0.state.duration >= 0 }) else { return nil }
        var seen = Set<String>()
        return rows.sorted {
            if $0.state.lastWatched != $1.state.lastWatched { return ($0.state.lastWatched ?? "") > ($1.state.lastWatched ?? "") }
            return Entry(item: $0).id < Entry(item: $1).id
        }.map(Entry.init).filter { seen.insert($0.id).inserted }
    }

    /// A saved-only overlay row has zero duration/progress and no watched videos; it is not history.
    static func overlayHistory(_ watch: [String: WatchEntry]) -> [CoreCWItem] {
        watch.compactMap { id, entry in
            guard entry.durationMs > 0 || entry.timeOffsetMs > 0 || !entry.watchedVideoIds.isEmpty else { return nil }
            return CoreCWItem(id: id, type: entry.type, name: entry.name, poster: entry.poster,
                state: CoreLibState(timeOffset: Double(entry.timeOffsetMs), duration: Double(entry.durationMs),
                    videoId: entry.videoId, lastWatched: entry.lastWatched, timesWatched: entry.watchedVideoIds.count))
        }
    }

    @MainActor
    private static func acceptedLegacyHistory(core: CoreBridge, context: Context) -> [CoreCWItem]? {
        if let accepted = core.acceptedLocalRecommendationHistory(),
           accepted.receipt.owner?.profileID == context.profileID {
            return (accepted.library + accepted.continueWatching).filter {
                $0.isWatched || ($0.state.lastWatched != nil && $0.state.duration > 0)
            }
        }
        // The ordinary signed-in owner's playback ledger is membership-neutral too. Admit it only
        // after the exact authenticated binding has a published history receipt.
        guard case .engine(let profile, let slot, let uid, let historyCapture?) = context.target,
              historyCapture == context.credential,
              let binding = core.settledActiveAccountBinding(), binding.profileID == profile,
              binding.keychainAccount == slot, binding.uid == uid,
              let receipt = core.lastAcceptedHistoryReceipt, let owner = receipt.owner,
              owner.profileID == binding.profileID, owner.keychainAccount == binding.keychainAccount,
              owner.uid == binding.uid, owner.generation == binding.generation else { return nil }
        return OwnerHistoryStore.validRows().compactMap { row in
            guard let id = row["id"] as? String, let type = row["type"] as? String,
                  let name = row["name"] as? String, let video = row["v"] as? String,
                  let offset = row["t"] as? Double, let duration = row["d"] as? Double else { return nil }
            return CoreCWItem(id: id, type: type, name: name, poster: row["poster"] as? String,
                state: .init(timeOffset: offset * 1000, duration: duration * 1000, videoId: video,
                             lastWatched: row["lastWatched"] as? String))
        }
    }
}
