import Foundation

/// The single fan-out point from the players + library actions to every external sync provider (Trakt,
/// SIMKL). Fire-and-forget and fully fail-soft, mirroring `WatchSignalClient`'s shape: each entry point
/// is synchronous, reads the gates on the caller's thread (the players call from the main actor, exactly
/// where `markPlaybackWatched` already reads `activeUsesEngineHistory`), claims its once-latch under a
/// lock, then hops to a detached task for the network fan-out. Nothing here ever blocks playback.
///
/// GATES (every push must pass all three, per the lane invariants):
///   1. OVERLAY/GUEST: `ProfileStore.activeUsesEngineHistory` (MAIN profile only). The provider token is
///      a single device-global Keychain slot, so an overlay/guest profile must never push to the owner's
///      external account. Read at the synchronous entry (main thread) and captured before the detached hop.
///   2. Provider signed-in: `provider.isConnected()` (configured + connected), checked in the fan-out.
///   3. Per-provider toggle: `provider.scrobbleEnabled` / `watchlistEnabled` (the @AppStorage switches).
///
/// ONCE-LATCHES (per item+session, mirroring the players' `markedWatched`): the watch record fires from
/// BOTH the 90% marker and the EOF path (and the shared `markPlaybackWatched` chokepoint), so a single
/// `completed` latch makes the definitive watch record fire EXACTLY once per session; `startSent` makes
/// the scrobble start fire once; `stopSent` makes the sub-completion resume-save stop fire once. SIMKL,
/// which has no live scrobble, only ever sees the completion op, so it can never spam `/sync/history`.
///
/// libraryItem POISON invariant: nothing here touches any engine `libraryItem` field. External state
/// lives only on the providers' own HTTP endpoints; the watch record is a provider history/scrobble call,
/// never an engine watched-mark dispatch.
final class ScrobbleCoordinator {
    static let shared = ScrobbleCoordinator()
    private init() {}

    /// Progress at/above which a stop is a completion (Trakt records a watch at >=80; the app's own
    /// watched marker is 90, so 90 keeps the two in step). The definitive-watch record is always sent at
    /// 100 so a provider that keys off the stop percentage records unambiguously.
    private static let completionThreshold = 90.0

    // MARK: - Session latch state (guarded by `lock`)

    private let lock = NSLock()
    /// The active session's item key. A different key on any entry opens a fresh session.
    private var currentKey = ""
    private var startSent = false
    private var stopSent = false
    private var completed = false

    /// A stable per-item key. Series episodes key by show+season+episode so an episode switch is a new
    /// session (fresh latches); movies key by the library id.
    private func sessionKey(_ meta: PlaybackMeta) -> String {
        "\(meta.libraryId)|\(meta.videoId)|\(meta.season.map(String.init) ?? "")|\(meta.episode.map(String.init) ?? "")"
    }

    // MARK: - Player transitions (called from the player's main-actor handlers)

    /// Playback started (first frame) or an episode began. Opens a FRESH session for this item (resets
    /// every latch) and sends the live scrobble start. When duration is not known yet, progress is 0 and
    /// the real percentage is deferred to later ticks / the stop.
    func playbackStarted(_ meta: PlaybackMeta, position: Double, duration: Double) {
        guard passesOwnerGate() else { return }
        lock.lock()
        currentKey = sessionKey(meta)
        startSent = true; stopSent = false; completed = false
        lock.unlock()
        dispatch(meta, progress: percent(position, duration)) { ref, provider in
            guard provider.capabilities.liveScrobble, provider.scrobbleEnabled else { return }
            await provider.scrobbleStart(ref)
        }
    }

    /// Playback paused. Live scrobble only; providers without it (SIMKL) are skipped by the capability
    /// guard, so a pause never reaches a history endpoint.
    func playbackPaused(_ meta: PlaybackMeta, position: Double, duration: Double) {
        guard passesOwnerGate() else { return }
        attachSession(meta)
        dispatch(meta, progress: percent(position, duration)) { ref, provider in
            guard provider.capabilities.liveScrobble, provider.scrobbleEnabled else { return }
            await provider.scrobblePause(ref)
        }
    }

    /// Playback resumed from pause. In Trakt's model a resume is a fresh scrobble start.
    func playbackResumed(_ meta: PlaybackMeta, position: Double, duration: Double) {
        guard passesOwnerGate() else { return }
        attachSession(meta)
        dispatch(meta, progress: percent(position, duration)) { ref, provider in
            guard provider.capabilities.liveScrobble, provider.scrobbleEnabled else { return }
            await provider.scrobbleStart(ref)
        }
    }

    /// Playback stopped (a genuine exit or EOF). At/above the completion threshold this records the watch
    /// once (shared `completed` latch with `watched`); below it, a one-time live scrobble stop saves the
    /// resume/pause point. Duration unknown => percentage deferred (treated as sub-completion, resume-save
    /// only), never a bogus completion.
    func playbackStopped(_ meta: PlaybackMeta, position: Double, duration: Double) {
        guard passesOwnerGate() else { return }
        attachSession(meta)
        let progress = percent(position, duration)
        if duration > 0, progress >= Self.completionThreshold {
            recordCompletion(meta)
            return
        }
        // Sub-completion exit: save a resume/pause point once (live scrobble only).
        lock.lock()
        let alreadyStopped = stopSent
        stopSent = true
        lock.unlock()
        guard !alreadyStopped else { return }
        dispatch(meta, progress: progress) { ref, provider in
            guard provider.capabilities.liveScrobble, provider.scrobbleEnabled else { return }
            await provider.scrobbleStop(ref)
        }
    }

    /// The shared watched chokepoint (`CoreBridge.markPlaybackWatched`): the 90% marker, the EOF path, or
    /// a manual in-player mark. Records the definitive watch exactly once per session.
    func watched(_ meta: PlaybackMeta) {
        guard passesOwnerGate() else { return }
        attachSession(meta)
        recordCompletion(meta)
    }

    // MARK: - Library actions (called from the shared detail add/remove chokepoints)

    /// A title was added to the library from a detail page: mirror it to each connected provider's
    /// watchlist. Whole-title intent (movie or show), gated on the watchlist toggle.
    func addedToLibrary(_ meta: PlaybackMeta) {
        guard passesOwnerGate() else { return }
        dispatch(meta, progress: 0) { ref, provider in
            guard provider.capabilities.watchlist, provider.watchlistEnabled else { return }
            await provider.addToWatchlist(ref)
        }
    }

    /// A title was removed from the library from a detail page: remove it from each provider's watchlist.
    func removedFromLibrary(_ meta: PlaybackMeta) {
        guard passesOwnerGate() else { return }
        dispatch(meta, progress: 0) { ref, provider in
            guard provider.capabilities.watchlist, provider.watchlistEnabled else { return }
            await provider.removeFromWatchlist(ref)
        }
    }

    // MARK: - Internals

    /// The OWNER/MAIN-profile gate. Read synchronously on the caller (main) thread, the same read
    /// `markPlaybackWatched` already does at these call sites. An overlay/guest profile pushes nothing.
    private func passesOwnerGate() -> Bool { ProfileStore.shared.activeUsesEngineHistory }

    /// Ensure a session exists for `meta` without resetting a matching one. If the key differs from the
    /// active session (an entry arriving with no prior start), open a fresh session so its latches apply.
    private func attachSession(_ meta: PlaybackMeta) {
        let key = sessionKey(meta)
        lock.lock()
        if currentKey != key {
            currentKey = key
            startSent = false; stopSent = false; completed = false
        }
        lock.unlock()
    }

    /// Claim the completion latch and, if won, fan out the definitive watch record at 100% progress.
    private func recordCompletion(_ meta: PlaybackMeta) {
        lock.lock()
        let alreadyDone = completed
        completed = true
        lock.unlock()
        guard !alreadyDone else { return }
        dispatch(meta, progress: 100) { ref, provider in
            guard provider.capabilities.history, provider.scrobbleEnabled else { return }
            await provider.recordWatched(ref)
        }
    }

    /// Progress percentage 0...100, or 0 when duration is not known yet (deferred).
    private func percent(_ position: Double, _ duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration * 100, 0), 100)
    }

    /// Resolve the neutral media ref (identity resolution: tt directly, tmdb: via the cached/async
    /// resolver, else the numeric tmdb fallback) and run `op` for every provider, off the main thread.
    /// A ref with no usable id (kitsu-only / pasted magnet) is dropped. Fully fail-soft.
    private func dispatch(_ meta: PlaybackMeta, progress: Double,
                          _ op: @escaping @Sendable (ExternalMediaRef, ExternalScrobbleProvider) async -> Void) {
        // Snapshot the plain value fields on the caller thread (PlaybackMeta is a Sendable-safe value).
        let isSeries = meta.type == "series"
        let libraryId = meta.libraryId
        let season = meta.season, episode = meta.episode
        let title = meta.name
        Task.detached(priority: .utility) {
            guard let ref = await Self.makeRef(libraryId: libraryId, isSeries: isSeries,
                                               season: season, episode: episode,
                                               title: title, progress: progress) else { return }
            for provider in ExternalScrobbleRegistry.providers {
                guard await provider.isConnected() else { continue }
                await op(ref, provider)
            }
        }
    }

    /// Build an `ExternalMediaRef`, resolving the play identity to a Trakt/SIMKL-usable id set. A `tt…`
    /// id is used directly; a `tmdb:…` id resolves to its tt (cached, else one async lookup) and keeps the
    /// numeric tmdb as a fallback; anything else yields no usable id. `nil` when nothing is usable.
    private static func makeRef(libraryId: String, isSeries: Bool, season: Int?, episode: Int?,
                                title: String?, progress: Double) async -> ExternalMediaRef? {
        var imdb: String?
        var tmdb: Int?
        if libraryId.range(of: #"^tt\d{6,}$"#, options: .regularExpression) != nil {
            imdb = libraryId
        } else if libraryId.lowercased().hasPrefix("tmdb") {
            if let cached = CommunityTrickplay.cachedIMDbID(for: libraryId) {
                imdb = cached
            } else {
                imdb = await CommunityTrickplay.resolveIMDbID(rawId: libraryId, seriesHint: isSeries)
            }
            tmdb = numericTMDB(libraryId)
        }
        let ref = ExternalMediaRef(isSeries: isSeries, imdb: imdb, tmdb: tmdb,
                                   season: season, episode: episode, title: title, year: nil,
                                   progress: progress)
        return ref.hasUsableID ? ref : nil
    }

    /// Extract the numeric TMDB id from "tmdb:12345" (tolerating "tmdb:movie:12345" / "tmdb:tv:12345").
    private static func numericTMDB(_ raw: String) -> Int? {
        raw.lowercased().split(separator: ":").compactMap { Int($0) }.first
    }
}
