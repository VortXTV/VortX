import Foundation

/// Home-only navigation evidence. This is not a CoreCWItem, paused seed, resume value or watch event.
struct TraktNextEpisodeOffer: Identifiable, Sendable {
    let name: String
    let target: TraktNextEpisodeTarget
    let activity: String?
    let intent: HomeContinueWatchingSelection.Intent
    let sessionID: TraktSessionID
    let owner: CoreBridge.NativePlaybackReadCapability
    let isCurrent: @Sendable () -> Bool
    var id: String { target.type + "|" + target.metaID }

    /// Source pages must validate the current accepted selection, not authorize a launch from an
    /// older immutable episode array after a different metadata response became resident.
    func matchingVideo(details: CoreMetaDetails?) -> CoreVideo? {
        guard let details, details.selected?.metaPath.id == target.metaID,
              details.selected?.metaPath.type == target.type, let resident = details.meta,
              resident.id == target.metaID, resident.type == target.type,
              let videos = resident.videos else { return nil }
        return matchingVideo(metaID: resident.id, type: resident.type, videos: videos)
    }

    /// A later metadata response cannot silently reinterpret the originally offered opaque ID.
    func matchingVideo(metaID: String, type: String, videos: [CoreVideo]) -> CoreVideo? {
        guard isCurrent(), intent.isCurrent(owner: owner), intent.traktSessionID == sessionID,
              TraktAuth.storedSessionID == sessionID, target.metaID == metaID,
              target.type == type, target.season > 0, target.episode > 0 else { return nil }
        let matches = videos.filter {
            $0.id == target.videoID && $0.season == target.season && $0.episode == target.episode
        }
        guard matches.count == 1,
              videos.filter({ $0.id == target.videoID }).count == 1,
              videos.filter({ $0.season == target.season && $0.episode == target.episode }).count == 1 else { return nil }
        return matches[0]
    }
}

/// Production wiring uses only actual proposed inventory APIs and the new host adapter. It cannot
/// activate against the shipping SDK; the adapter must return unavailable until its real route exists.
final class TraktHomeNextEpisodeProducer: @unchecked Sendable {
    private enum Failure: Error { case inventoryUnavailable }
    /// The cache key remains the existing Intent; capability witnesses are not new key identity.
    /// A row/attempt always closes over its ORIGINAL Owner, never the currently queried wrapper.
    private struct Owner: Hashable, Sendable {
        let intent: HomeContinueWatchingSelection.Intent
        let capability: CoreBridge.NativePlaybackReadCapability
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.intent == rhs.intent }
        func hash(into hasher: inout Hasher) { hasher.combine(intent) }
    }
    static let shared = TraktHomeNextEpisodeProducer()
    static let changedNote = Notification.Name("vortx.trakt.nextEpisodeHome.changed")
    private let consumer: TraktNextEpisodeConsumer<Owner>

    init() {
        consumer = .init(dependencies: .init(
            inventory: { owner, session in
                TraktSyncEngine.shared.currentWatchedShowInventory(expectedSession: session,
                    purpose: .selectedContinueWatching(isCurrent: {
                        owner.intent.isCurrent(owner: owner.capability)
                    }))
            },
            refreshInventory: { session, isCurrent in
                guard await TraktSyncEngine.shared.refreshWatchedShowInventory(expectedSession: session,
                    purpose: .selectedContinueWatching(isCurrent: isCurrent)) != nil else {
                    throw Failure.inventoryUnavailable
                }
            },
            progress: { entry, session in
                try await TraktService.shared.nextEpisodeProgress(show: entry.show, expectedSession: session)
            },
            ownerIsCurrent: { owner, session in
                owner.intent.source == .trakt && owner.intent.traktSessionID == session
                    && owner.intent.isCurrent(owner: owner.capability)
                    && owner.intent.context.usesNativeProfileState && owner.intent.context.usesEngineHistory
            },
            uptime: { ProcessInfo.processInfo.systemUptime },
            changed: {
                Task { @MainActor in
                    NotificationCenter.default.post(name: TraktHomeNextEpisodeProducer.changedNote, object: nil)
                }
            }
        ))
        TraktAuthBoundary.observe(key: "trakt-next-episode-home") { [weak self] _ in
            self?.consumer.retire()
            Task { @MainActor in NotificationCenter.default.post(name: Self.changedNote, object: nil) }
        }
    }

    /// Called only by a visible/foreground Home trigger. No timer or background scheduler lives here.
    @MainActor
    func requestRefresh(intent: HomeContinueWatchingSelection.Intent, core: CoreBridge) {
        guard intent.source == .trakt, let session = intent.traktSessionID,
              intent.context.usesNativeProfileState, intent.context.usesEngineHistory,
              let target = intent.context.nativeTarget,
              let capability = core.captureNativePlaybackReadCapability(target),
              intent.isCurrent(owner: capability),
              let lease = core.captureNativeExternalCWRead(target: target), lease.isCurrent(),
              intent.isCurrent(owner: capability) else { return }
        let original = Owner(intent: intent, capability: capability)
        // Both original native admissions precede the Task/provider hop. No mixed Bridge capture.
        Task(priority: .utility) { @MainActor [consumer] in
            guard !Task.isCancelled, original.intent.isCurrent(owner: original.capability),
                  lease.isCurrent() else { return }
            // Capture the native queue-head and accepted metadata BEFORE the inventory/provider awaits.
            await consumer.refresh(owner: original, session: session, native: lease)
        }
    }

    func offers(intent: HomeContinueWatchingSelection.Intent, owner: CoreBridge.NativePlaybackReadCapability,
                paused: [CoreCWItem], now: Date) -> [TraktNextEpisodeOffer] {
        guard intent.source == .trakt, let session = intent.traktSessionID,
              intent.isCurrent(owner: owner) else { return [] }
        let original = Owner(intent: intent, capability: owner)
        let rows = consumer.rows(owner: original, session: session).filter { row in
            // A genuine paused seed wins for the same verified title. This never rewrites paused data.
            !paused.contains { item in
                item.type == row.target.type && row.target.titleSpellings.contains(item.id)
            }
        }.map { row in
            TraktNextEpisodeOffer(name: row.name, target: row.target, activity: row.activity,
                intent: intent, sessionID: session, owner: owner, isCurrent: row.isCurrent)
        }
        let bounded = ContinueWatchingPreferences.bounded(rows, window: intent.context.preferences.window,
            now: now, activity: { $0.activity }, identity: { $0.id })
        if let cap = intent.context.preferences.window.cap {
            // Existing paused entries retain their window and precedence; next offers use remaining room.
            return Array(bounded.prefix(max(0, cap - paused.count)))
        }
        return bounded
    }
}
