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
/// ONCE-LATCHES (per playback session, mirroring the players' `markedWatched`): the watch record fires
/// from BOTH the 90% marker and the EOF path (and the shared `markPlaybackWatched` chokepoint), so a single
/// `completed` latch makes the definitive watch record fire EXACTLY once per session; `startSent` makes the
/// scrobble start fire once (it gates the start dispatch); `stopSent` makes the sub-completion resume-save
/// stop fire once. SIMKL, which has no live scrobble, only ever sees the completion op, so it can never
/// spam `/sync/history`.
///
/// A session is (item key + playback token). `playbackStarted` resets the latches ONLY when the item OR
/// the token changes, so a same-title recovery re-entry (a stall failover, an AVPlayer->libmpv demote, a
/// same-source retry, a retry reload) re-fires `playbackStarted` with the SAME key + token and the latches
/// SURVIVE: a completion already recorded can never fire a second (duplicate) history record. A genuine
/// rewatch arrives with a fresh per-playback token from the player, so it opens a new session and scrobbles
/// again.
///
/// libraryItem POISON invariant: nothing here touches any engine `libraryItem` field. External state
/// lives only on the providers' own HTTP endpoints; the watch record is a provider history/scrobble call,
/// never an engine watched-mark dispatch.
final class ScrobbleCoordinator {
    static let shared = ScrobbleCoordinator()
    private init() {
        TraktAuthBoundary.observe(key: "scrobble-coordinator") { [weak self] _ in
            self?.invalidateTraktSession()
        }
        SIMKLAuthBoundary.observe(key: "scrobble-coordinator") { [weak self] _ in
            self?.invalidateSIMKLSession()
        }
    }

    /// Progress at/above which a stop is a completion (Trakt records a watch at >=80; the app's own
    /// watched marker is 90, so 90 keeps the two in step). The definitive-watch record is always sent at
    /// 100 so a provider that keys off the stop percentage records unambiguously.
    private static let completionThreshold = 90.0

    // MARK: - Session latch state (guarded by `lock`)

    private let lock = NSLock()
    /// The exact provider sessions captured when this item+player-token lifecycle began. Boundaries clear
    /// only the affected owner, so a later event from an account-A playback can never adopt account B.
    private var sessionOwnership =
        PlaybackScrobbleSessionOwnership<TraktSessionID, SIMKLSessionID>()
    private var startSent = false
    private var stopSent = false
    private var traktCompleted = false
    private var simklCompleted = false
    /// One network lane for Trakt's stateful start/pause/stop lifecycle. In particular, a slow initial
    /// start must finish before a later pause/stop, or its late arrival would erase the saved pause point.
    private let lifecycleQueue = TraktScrobbleLifecycleQueue()

    /// A stable per-item key. Series episodes key by show+season+episode so an episode switch is a new
    /// session (fresh latches); movies key by the library id.
    private func sessionKey(_ meta: PlaybackMeta) -> String {
        "\(meta.libraryId)|\(meta.videoId)|\(meta.season.map(String.init) ?? "")|\(meta.episode.map(String.init) ?? "")"
    }

    // MARK: - Player transitions (called from the player's main-actor handlers)

    /// Playback started (first frame) or an episode began. Opens a FRESH session (resets every latch and
    /// sends the live scrobble start) ONLY when the item or the playback `token` changed; a same-title
    /// recovery re-entry (same key + token) keeps the latches so a completion recorded before the reload
    /// is not re-sent. `token` is the player's per-playback id (a genuine rewatch supplies a fresh one).
    /// When duration is not known yet, progress is 0 and the real percentage is deferred to a later
    /// pause/resume/stop transition. Routine progress ticks never emit `start`.
    func playbackStarted(_ meta: PlaybackMeta, position: Double, duration: Double, sessionToken token: String) {
        guard passesOwnerGate() else { return }
        let currentTraktSessionID = TraktAuth.storedSessionID
        let currentSIMKLSessionID = SIMKLAuth.storedSessionID
        lock.lock()
        let key = sessionKey(meta)
        let isFreshPlayback = sessionOwnership.beginPlayback(
            itemKey: key,
            playbackToken: token,
            traktSessionID: currentTraktSessionID,
            simklSessionID: currentSIMKLSessionID
        )
        if isFreshPlayback {
            startSent = false; stopSent = false
            traktCompleted = false; simklCompleted = false
        }
        let sendStart = !startSent
        startSent = true
        let providerSessions = sessionOwnership.snapshot
        lock.unlock()
        guard sendStart else { return }   // same-session re-entry: the start already fired, do not repeat it
        dispatchLifecycle(
            meta,
            progress: percent(position, duration),
            providerSessions: providerSessions
        ) { ref, provider, session in
            guard provider.capabilities.liveScrobble, provider.scrobbleEnabled else { return }
            await provider.scrobbleStart(ref, session: session)
        }
    }

    /// Playback paused. Live scrobble only; providers without it (SIMKL) are skipped by the capability
    /// guard, so a pause never reaches a history endpoint.
    func playbackPaused(_ meta: PlaybackMeta, position: Double, duration: Double) {
        guard passesOwnerGate() else { return }
        let providerSessions = attachSession(meta)
        dispatchLifecycle(
            meta,
            progress: percent(position, duration),
            providerSessions: providerSessions
        ) { ref, provider, session in
            guard provider.capabilities.liveScrobble, provider.scrobbleEnabled else { return }
            await provider.scrobblePause(ref, session: session)
        }
    }

    /// Playback resumed from pause. In Trakt's model a resume is a fresh scrobble start.
    func playbackResumed(_ meta: PlaybackMeta, position: Double, duration: Double) {
        guard passesOwnerGate() else { return }
        let providerSessions = attachSession(meta)
        dispatchLifecycle(
            meta,
            progress: percent(position, duration),
            providerSessions: providerSessions
        ) { ref, provider, session in
            guard provider.capabilities.liveScrobble, provider.scrobbleEnabled else { return }
            await provider.scrobbleStart(ref, session: session)
        }
    }

    /// Playback stopped (a genuine exit or EOF). At/above the completion threshold this records the watch
    /// once (shared `completed` latch with `watched`); below it, a one-time live scrobble stop saves the
    /// resume/pause point. Duration unknown => percentage deferred (treated as sub-completion, resume-save
    /// only), never a bogus completion.
    func playbackStopped(_ meta: PlaybackMeta, position: Double, duration: Double) {
        guard passesOwnerGate() else { return }
        let providerSessions = attachSession(meta)
        let progress = percent(position, duration)
        if duration > 0, progress >= Self.completionThreshold {
            recordCompletion(meta, providerSessions: providerSessions)
            return
        }
        // Sub-completion exit: save a resume/pause point once (live scrobble only).
        lock.lock()
        let alreadyStopped = stopSent
        stopSent = true
        lock.unlock()
        guard !alreadyStopped else { return }
        dispatchLifecycle(
            meta,
            progress: progress,
            providerSessions: providerSessions
        ) { ref, provider, session in
            guard provider.capabilities.liveScrobble, provider.scrobbleEnabled else { return }
            await provider.scrobbleStop(ref, session: session)
        }
    }

    /// The shared watched chokepoint (`CoreBridge.markPlaybackWatched`): the 90% marker, the EOF path, or
    /// a manual in-player mark. Records the definitive watch exactly once per session.
    func watched(_ meta: PlaybackMeta) {
        guard passesOwnerGate() else { return }
        let providerSessions = attachSession(meta)
        recordCompletion(meta, providerSessions: providerSessions)
    }

    // MARK: - Library actions (called from the shared detail add/remove chokepoints)

    /// A title was added to the library from a detail page: mirror it to each connected provider's
    /// watchlist. Whole-title intent (movie or show), gated on the watchlist toggle.
    func addedToLibrary(_ meta: PlaybackMeta) {
        guard passesOwnerGate() else { return }
        dispatch(meta, progress: 0) { ref, provider, session in
            guard provider.capabilities.watchlist, provider.watchlistEnabled else { return }
            await provider.addToWatchlist(ref, session: session)
        }
    }

    /// A title was removed from the library from a detail page: remove it from each provider's watchlist.
    func removedFromLibrary(_ meta: PlaybackMeta) {
        guard passesOwnerGate() else { return }
        dispatch(meta, progress: 0) { ref, provider, session in
            guard provider.capabilities.watchlist, provider.watchlistEnabled else { return }
            await provider.removeFromWatchlist(ref, session: session)
        }
    }

    // MARK: - Internals

    /// The OWNER/MAIN-profile gate. Read synchronously on the caller (main) thread, the same read
    /// `markPlaybackWatched` already does at these call sites. An overlay/guest profile pushes nothing.
    private func passesOwnerGate() -> Bool { ProfileStore.shared.activeUsesEngineHistory }

    /// Ensure a session exists for `meta` without resetting a matching one. If the key differs from the
    /// active session (an entry arriving with no prior start), open a fresh session so its latches apply.
    private func attachSession(
        _ meta: PlaybackMeta
    ) -> PlaybackProviderSessionSnapshot<TraktSessionID, SIMKLSessionID> {
        let key = sessionKey(meta)
        lock.lock()
        if sessionOwnership.attach(itemKey: key) {
            startSent = false; stopSent = false
            traktCompleted = false; simklCompleted = false
        }
        let providerSessions = sessionOwnership.snapshot
        lock.unlock()
        return providerSessions
    }

    /// Boundaries invalidate only that provider's owner. Latches and the item+token identity survive, so
    /// same-player recovery cannot rebind to the replacement account or duplicate the unaffected provider.
    private func invalidateTraktSession() {
        lock.lock()
        sessionOwnership.invalidateTrakt()
        lock.unlock()
    }

    private func invalidateSIMKLSession() {
        lock.lock()
        sessionOwnership.invalidateSIMKL()
        lock.unlock()
    }

    /// Claim the completion latch and, if won, fan out the definitive watch record at 100% progress.
    private func recordCompletion(
        _ meta: PlaybackMeta,
        providerSessions: PlaybackProviderSessionSnapshot<TraktSessionID, SIMKLSessionID>
    ) {
        lock.lock()
        let sendTrakt = !traktCompleted
        let sendSIMKL = !simklCompleted
        traktCompleted = true
        simklCompleted = true
        lock.unlock()
        guard sendTrakt || sendSIMKL else { return }
        dispatchLifecycle(
            meta,
            progress: 100,
            providerSessions: providerSessions
        ) { ref, provider, session in
            guard provider.capabilities.history, provider.scrobbleEnabled else { return }
            if provider.id == "trakt", !sendTrakt { return }
            if provider.id == "simkl", !sendSIMKL { return }
            await provider.recordWatched(ref, session: session)
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
    private struct DispatchContext: Sendable {
        let isSeries: Bool
        let libraryId: String
        let season: Int?
        let episode: Int?
        let title: String?
        /// Captured synchronously when the operation is enqueued. nil is a fail-closed Trakt operation.
        let traktSessionID: TraktSessionID?
        /// Captured synchronously for SIMKL, preventing a delayed account-A intent from using account B.
        let simklSessionID: SIMKLSessionID?
    }

    private func dispatchContext(
        _ meta: PlaybackMeta,
        providerSessions: PlaybackProviderSessionSnapshot<TraktSessionID, SIMKLSessionID>
    ) -> DispatchContext {
        DispatchContext(
            isSeries: meta.usesSeriesLifecycle,
            libraryId: meta.libraryId,
            season: meta.season,
            episode: meta.episode,
            title: meta.name,
            traktSessionID: providerSessions.traktSessionID,
            simklSessionID: providerSessions.simklSessionID
        )
    }

    private func currentProviderSessions(
    ) -> PlaybackProviderSessionSnapshot<TraktSessionID, SIMKLSessionID> {
        PlaybackProviderSessionSnapshot(
            traktSessionID: TraktAuth.storedSessionID,
            simklSessionID: SIMKLAuth.storedSessionID
        )
    }

    private func dispatch(_ meta: PlaybackMeta, progress: Double,
                          _ op: @escaping @Sendable (
                            ExternalMediaRef,
                            ExternalScrobbleProvider,
                            ExternalProviderSession?
                          ) async -> Void) {
        // DORMANCY (no-keys build): bail synchronously, before spawning any task or resolving any id, when
        // NEITHER provider is configured. `makeRef` can do up to two HTTP lookups to turn a tmdb: id into a
        // tt id, so without this a tmdb-catalog play on the shipped credential-less build would emit resolver
        // traffic. `isConfigured` is a synchronous constant check.
        guard TraktAuth.isConfigured || SIMKLAuth.isConfigured else { return }
        let context = dispatchContext(meta, providerSessions: currentProviderSessions())
        Task.detached(priority: .utility) {
            await Self.performDispatch(context, progress: progress, op)
        }
    }

    /// Enqueue a stateful playback transition. Unlike library/watchlist writes, these operations may not
    /// overtake one another: Trakt `start` clears a paused-playback record, so a late start after pause/stop
    /// would destroy the position the later transition just saved.
    private func dispatchLifecycle(
        _ meta: PlaybackMeta,
        progress: Double,
        providerSessions: PlaybackProviderSessionSnapshot<TraktSessionID, SIMKLSessionID>,
        _ op: @escaping @Sendable (
            ExternalMediaRef,
            ExternalScrobbleProvider,
            ExternalProviderSession?
        ) async -> Void
    ) {
        guard TraktAuth.isConfigured || SIMKLAuth.isConfigured else { return }
        let context = dispatchContext(meta, providerSessions: providerSessions)
        lifecycleQueue.enqueue {
            await Self.performDispatch(context, progress: progress, op)
        }
    }

    private static func performDispatch(
        _ context: DispatchContext,
        progress: Double,
        _ op: @escaping @Sendable (
            ExternalMediaRef,
            ExternalScrobbleProvider,
            ExternalProviderSession?
        ) async -> Void
    ) async {
        // Resolve ids only once at least one provider is actually CONNECTED (configured AND signed in):
        // a configured-but-signed-out provider must not trigger `makeRef`'s network lookups on a routine
        // catalog play. Collect the connected providers here so `op` runs against exactly those.
        var connected: [(ExternalScrobbleProvider, ExternalProviderSession)] = []
        for provider in ExternalScrobbleRegistry.providers {
            if provider.id == "trakt" {
                guard let captured = context.traktSessionID,
                      TraktAuth.storedSessionID == captured else { continue }
                guard await provider.isConnected(),
                      TraktAuth.storedSessionID == captured else { continue }
                connected.append((provider, .trakt(captured)))
                continue
            }
            if provider.id == "simkl" {
                guard let captured = context.simklSessionID,
                      SIMKLAuth.storedSessionID == captured else { continue }
                guard await provider.isConnected(),
                      SIMKLAuth.storedSessionID == captured else { continue }
                connected.append((provider, .simkl(captured)))
            }
        }
        guard !connected.isEmpty else { return }
        guard let ref = await makeRef(
            libraryId: context.libraryId,
            isSeries: context.isSeries,
            season: context.season,
            episode: context.episode,
            title: context.title,
            progress: progress
        ) else { return }
        for (provider, session) in connected {
            await op(ref, provider, session)
        }
    }

    /// Build an `ExternalMediaRef`, resolving the play identity to a Trakt/SIMKL-usable id set. A `tt…`
    /// id is used directly; a `tmdb:…` id resolves to its tt (cached, else one async lookup) and keeps the
    /// numeric tmdb as a fallback; anything else yields no usable id. `nil` when nothing is usable.
    ///
    /// Non-private so the user-initiated check-in path (`TraktCheckinModel`) resolves identity through this
    /// SAME resolver. It is the one place that knows how an engine `libraryId` becomes a service id, and a
    /// second copy would drift the moment either side learned a new id form. Callers outside the fan-out
    /// must apply the gates themselves: this resolves an identity, it does not authorize a push.
    static func makeRef(libraryId: String, isSeries: Bool, season: Int?, episode: Int?,
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
