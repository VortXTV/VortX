import Foundation

/// Additive-READ Trakt playback shadow: pulls `GET /sync/playback/{movies,episodes}` (the positions
/// Trakt holds from OTHER devices) into a LOCAL cache and answers one question for the pre-play UI:
/// "is there a position from elsewhere worth OFFERING the viewer?".
///
/// HARD INVARIANT (resume authority): VortX is the SOLE authority on resume position. That authority is
/// `libraryItem.state.timeOffset`, read through `CoreBridge.engineResumeSeconds` with the account fallback
/// behind it. This type NEVER writes it, never writes `VortXSyncManager`, never writes any engine
/// libraryItem, and is never consulted by `engineResumeSeconds`. It is a SUGGESTION the viewer must tap:
/// nothing here changes what the primary Resume button does. The tap only chooses WHERE this one playback
/// begins (the same seam "Play from start" already uses); the engine then records its own position through
/// its normal path, exactly as if the viewer had scrubbed there by hand.
///
/// Why one-way and no merge: a two-way sync of resume position between two systems that both claim
/// authority silently corrupts progress (each overwrites the other's fresher value on alternating opens).
/// So there is no merge, no write-back, and no DELETE of Trakt's playback entries. Trakt drifting stale
/// costs a suggestion the viewer ignores; it can never cost a saved position.
///
/// This mirrors `TraktSyncEngine`'s watched-shadow pattern (local JSON cache, generation guard, fail-soft)
/// and deliberately reuses its identity-union approach: a title is stored under EVERY id form Trakt gives
/// (imdb `tt…` AND `tmdb:<id>`), because covers/library items are keyed by whichever identity their source
/// used. Capturing only imdb is what broke the watched badges in issue #143.
///
/// Fully fail-soft and dormant: unconfigured / not connected / toggle off does nothing and touches no network.
final class TraktPlaybackShadow {
    static let shared = TraktPlaybackShadow()
    /// Posted after the authoritative Trakt Continue Watching snapshot changes or is cleared.
    static let changedNote = Notification.Name("vortx.trakt.playbackShadow.changed")

    /// Minimum gap between network refreshes. The pre-play views call `refreshIfStale` freely.
    private static let refreshInterval: TimeInterval = 5 * 60
    /// Never suggest a position below this: under a minute in, "resume" is not worth a tap over "Watch".
    private static let minimumSuggestionSeconds: Double = 60
    /// Never suggest past this fraction of the runtime. A percent applied to a PROVISIONAL runtime can
    /// overshoot; landing the viewer in the credits (where a stop would record a completion) is the one
    /// way this feature could touch real state, so the offer is capped well short of the end.
    private static let maximumSuggestionFraction: Double = 0.95
    /// Only offer Trakt's position when it is ahead of the local one by more than this. Inside this band
    /// the two devices agree closely enough that a chip would be noise, and swapping a local position for a
    /// near-identical remote one buys the viewer nothing.
    private static let staleLocalThresholdSeconds: Double = 120

    private let lock = NSLock()
    /// Trakt's paused positions as PERCENT (0...100) keyed by every id form of the title/episode. Percent,
    /// not seconds, because that is literally all `/sync/playback` returns; the caller supplies the runtime.
    private var progressByID: [String: Double]
    /// Ordered paused titles used only when the user explicitly selects Trakt as the Home rail source.
    private var continueWatchingSeeds: [TraktContinueWatchingSeed]
    /// Distinguishes a truthful successful empty snapshot from "not loaded yet".
    private var hasContinueWatchingSnapshot: Bool
    /// The movie and episode `paused_at` stamps from `/sync/last_activities` at the last successful pull.
    /// They stay separate because one kind can advance while the other has the lexicographically newer stamp.
    private var lastActivityStamps: TraktPlaybackActivityStamps?
    private var lastRefresh: Date?
    /// Auth session that owns every value above. A nil or mismatched session makes the state unreadable.
    private var stateSessionID: TraktSessionID?
    /// The generation currently refreshing. Reset clears it so a newly connected account can start
    /// immediately; a superseded task may only clear its own matching generation.
    private var refreshingGeneration: Int?
    /// Bumped by `reset()` (disconnect). An in-flight refresh captures it before its network awaits and
    /// refuses to write back if it changed meanwhile, so a pull that started before a disconnect can never
    /// resurrect the wiped cache into the next account. Same guard as TraktSyncEngine.
    private var generation = 0

    private init() {
        let sessionID = TraktAuth.storedSessionID
        let cached = Self.loadCache(for: sessionID)
        progressByID = cached.progress
        lastActivityStamps = cached.activity
        continueWatchingSeeds = cached.items
        hasContinueWatchingSnapshot = cached.hasSnapshot
        stateSessionID = cached.sessionID
        TraktAuthBoundary.observe(key: "trakt-playback-shadow") { [weak self] sessionID in
            self?.handleAuthBoundary(sessionID)
        }
        // Close the small load-to-observer registration window. If an account changed there, clear now.
        if TraktAuth.storedSessionID != stateSessionID {
            handleAuthBoundary(TraktAuth.storedSessionID)
        }
    }

    // MARK: - Read side (the pre-play chip consumes this)

    enum ContinueWatchingSource: Sendable, Equatable {
        case local
        case trakt
    }

    struct ContinueWatchingSelection {
        let items: [CoreCWItem]
        let source: ContinueWatchingSource
        /// Exact account that owns remote rows and resume values. Nil for local engine rows.
        let sessionID: TraktSessionID?
    }

    /// A resume point Trakt holds that is worth offering, or nil. THE single decision point, so iOS and
    /// tvOS cannot drift apart on the policy.
    ///
    /// - Parameters:
    ///   - meta: the title/episode about to play.
    ///   - localSeconds: VortX's OWN resume position (the authority), or nil when it has none.
    ///   - durationSeconds: the runtime used to turn Trakt's percent into a timecode. Pass the engine's real
    ///     duration when there is one; a provisional runtime is accepted but is why the result is clamped.
    /// - Returns: the seconds to offer, or nil when there is nothing worth offering.
    ///
    /// Returns nil (no chip) whenever: the toggle is off, no runtime is known (we will not invent a
    /// timecode we cannot compute), Trakt has no entry, the position is trivially early or near the end, or
    /// VortX's own position is already at/ahead of Trakt's. Never throws, never blocks: a pure cache read.
    func suggestionSeconds(for meta: PlaybackMeta, localSeconds: Double?, durationSeconds: Double?) -> Double? {
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.traktResumeSuggestion, default: false) else { return nil }
        // OWNER/GUEST gate, the READ-side mirror of ScrobbleCoordinator's gate 1. The Trakt token is a single
        // device-global Keychain slot, so everything it returns belongs to the OWNER. Offering it to an
        // overlay/guest profile would show one person's private position ("Resume from 41:23") inside another
        // person's session on the family device. The coordinator already refuses to PUSH from an overlay
        // profile for exactly this reason; reading it back without the same gate would leak the owner's
        // viewing in the other direction.
        guard ProfileStore.shared.activeUsesEngineHistory else { return nil }
        // No trustworthy runtime means no honest timecode: /sync/playback gives a percent and nothing else.
        // Showing "Resume from 41:23" off a guessed runtime would be a fabricated number, so we stay silent.
        guard let duration = durationSeconds, duration.isFinite, duration > 0 else { return nil }
        let key: String
        if meta.usesSeriesLifecycle {
            guard let season = meta.season, let episode = meta.episode else { return nil }
            key = Self.episodeKey(meta.libraryId, season: season, episode: episode)
        } else {
            key = meta.libraryId
        }
        lock.lock()
        defer { lock.unlock() }
        guard let currentSession = TraktAuth.storedSessionID,
              TraktPlaybackSnapshotPolicy.canRead(
                snapshotSession: stateSessionID,
                currentSession: currentSession
              ),
              let percent = progressByID[key],
              percent.isFinite,
              percent > 0 else { return nil }

        let seconds = duration * (percent / 100)
        guard seconds.isFinite,
              seconds >= Self.minimumSuggestionSeconds,
              seconds <= duration * Self.maximumSuggestionFraction else { return nil }

        // VortX's own position wins unless Trakt is meaningfully ahead of it. Equal-or-behind means this
        // device already knows as much or more, so there is nothing to offer. This asymmetry is what keeps
        // one authority: we only ever ADD information the local side does not have.
        if let local = localSeconds, local > 0, seconds <= local + Self.staleLocalThresholdSeconds { return nil }
        guard TraktAuth.storedSessionID == currentSession else { return nil }
        return seconds
    }

    /// The episode key shape shared by the writer and the reader, so the two can never drift.
    private static func episodeKey(_ showID: String, season: Int, episode: Int) -> String {
        "\(showID)|s\(season)e\(episode)"
    }

    /// The Home rail source selected by the user. Until the first whole Trakt snapshot succeeds, keep
    /// the local rail visible. After success, even an empty Trakt snapshot is authoritative and stays empty.
    func continueWatchingSelection(
        fallback localItems: [CoreCWItem]
    ) -> ContinueWatchingSelection {
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.traktContinueWatching, default: false),
              ProfileStore.shared.activeUsesEngineHistory else {
            return ContinueWatchingSelection(items: localItems, source: .local, sessionID: nil)
        }
        let existingByID = Dictionary(
            localItems.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        lock.lock()
        defer { lock.unlock() }
        guard let currentSession = TraktAuth.storedSessionID,
              TraktPlaybackSnapshotPolicy.canRead(
                snapshotSession: stateSessionID,
                currentSession: currentSession
              ),
              hasContinueWatchingSnapshot else {
            return ContinueWatchingSelection(items: localItems, source: .local, sessionID: nil)
        }
        let items = continueWatchingSeeds.map { seed in
            let existing = existingByID[seed.id]
            let duration = max(0, (seed.durationSeconds ?? 0) * 1000)
            let offset = max(0, (seed.resumeSeconds ?? 0) * 1000)
            return CoreCWItem(
                id: seed.id,
                type: seed.type,
                name: seed.name,
                // Reuse artwork the app already holds for the same title. A private Trakt playback row
                // must never trigger a new metadata or image request to another service.
                poster: seed.poster ?? existing?.poster,
                state: CoreLibState(
                    timeOffset: offset,
                    duration: duration,
                    videoId: seed.videoID
                )
            )
        }
        guard TraktAuth.storedSessionID == currentSession else {
            return ContinueWatchingSelection(items: localItems, source: .local, sessionID: nil)
        }
        return ContinueWatchingSelection(items: items, source: .trakt, sessionID: currentSession)
    }

    func continueWatchingItems(fallback localItems: [CoreCWItem]) -> [CoreCWItem] {
        continueWatchingSelection(fallback: localItems).items
    }

    // MARK: - Disconnect

    /// Wipe all local playback-shadow state (memory + disk) on disconnect / sign-out, so the next account
    /// on this device can never see the previous account's positions.
    @discardableResult
    func reset() -> Bool {
        resetState(for: TraktAuth.storedSessionID)
    }

    private func handleAuthBoundary(_ sessionID: TraktSessionID?) {
        _ = resetState(for: sessionID)
    }

    /// Clear memory first, then remove every disk location. A failure is logged as a bounded category and
    /// returned to callers. Session mismatch still keeps all read methods fail closed.
    @discardableResult
    private func resetState(for sessionID: TraktSessionID?) -> Bool {
        lock.lock()
        progressByID = [:]
        continueWatchingSeeds = []
        hasContinueWatchingSnapshot = false
        lastActivityStamps = nil
        lastRefresh = nil
        stateSessionID = sessionID
        generation &+= 1
        refreshingGeneration = nil
        lock.unlock()
        let persisted = Self.resetCache()
        Self.postChanged()
        return persisted
    }

    // MARK: - Refresh (pre-play + foreground, throttled)

    /// Refresh the cache at most once per `refreshInterval`. No-op when Trakt is unconfigured, not
    /// connected, or the toggle is off. Safe to call from a view body path: returns immediately and does
    /// the work off-main.
    func refreshIfStale() {
        guard TraktAuth.isConfigured else { return }
        // Both read surfaces are opt-in. A user who enabled neither must never pay a network call or token
        // refresh for this shadow.
        let suggestionOn = ExternalSyncToggle.isOn(ExternalSyncToggle.traktResumeSuggestion, default: false)
        let continueWatchingOn = ExternalSyncToggle.isOn(ExternalSyncToggle.traktContinueWatching, default: false)
        guard suggestionOn || continueWatchingOn else { return }
        guard let sessionID = TraktAuth.storedSessionID else { return }
        lock.lock()
        // This also handles a boundary that occurred before this singleton registered its observer.
        guard stateSessionID == sessionID else {
            lock.unlock()
            handleAuthBoundary(sessionID)
            refreshIfStale()
            return
        }
        if refreshingGeneration == generation { lock.unlock(); return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.refreshInterval { lock.unlock(); return }
        let gen = generation
        refreshingGeneration = gen
        lock.unlock()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let signedIn = await TraktAuth.shared.sessionID == sessionID
            if signedIn {
                await self.pullPlayback(generation: gen, sessionID: sessionID)
            }
            self.finishRefresh(
                generation: gen,
                sessionID: sessionID,
                signedIn: signedIn
            )
        }
    }

    /// Force a pull after the user selects Trakt as the Continue Watching source.
    func refreshNow() {
        lock.lock()
        lastRefresh = nil
        // "Now" also supersedes an in-flight attempt. This matters at successful auth: a signed-out no-op
        // may still be unwinding when the token arrives, and must not block the authenticated first pull.
        if refreshingGeneration != nil {
            generation &+= 1
            refreshingGeneration = nil
        }
        lock.unlock()
        refreshIfStale()
    }

    private func finishRefresh(
        generation gen: Int,
        sessionID: TraktSessionID,
        signedIn: Bool
    ) {
        lock.lock()
        let generationMatches = TraktPlaybackSnapshotPolicy.canCommit(
            capturedSession: sessionID,
            stateSession: stateSessionID,
            currentSession: TraktAuth.storedSessionID,
            capturedGeneration: gen,
            currentGeneration: generation
        )
        if TraktPlaybackRefreshThrottlePolicy.shouldArm(
            signedIn: signedIn,
            generationMatches: generationMatches
        ) {
            lastRefresh = Date()
        }
        if refreshingGeneration == gen {
            refreshingGeneration = nil
        }
        lock.unlock()
    }

    private func activitySnapshot(for sessionID: TraktSessionID) -> (
        known: TraktPlaybackActivityStamps?,
        hasContinueWatchingSnapshot: Bool
    ) {
        lock.lock()
        let readable = TraktPlaybackSnapshotPolicy.canRead(
            snapshotSession: stateSessionID,
            currentSession: sessionID
        )
        let snapshot = readable
            ? (lastActivityStamps, hasContinueWatchingSnapshot)
            : (nil, false)
        lock.unlock()
        return snapshot
    }

    /// Atomically validates the account generation and persists the matching complete snapshot.
    private func commitPlayback(
        progress: [String: Double],
        activity: TraktPlaybackActivityStamps?,
        items: [TraktContinueWatchingSeed],
        generation gen: Int,
        sessionID: TraktSessionID
    ) -> Bool {
        lock.lock()
        // A disconnect while this pull was in flight wiped the cache and bumped generation. Writing the
        // pre-reset result back would resurrect the previous account's positions.
        guard TraktPlaybackSnapshotPolicy.canCommit(
            capturedSession: sessionID,
            stateSession: stateSessionID,
            currentSession: TraktAuth.storedSessionID,
            capturedGeneration: gen,
            currentGeneration: generation
        ) else {
            lock.unlock()
            return false
        }
        // Persist before exposing the new snapshot in memory. A write or protection failure leaves the
        // previous same-session state intact, and a newly connected account stays on local fallback.
        guard Self.saveCache(
            sessionID: sessionID,
            progress: progress,
            activity: activity,
            items: items,
            hasSnapshot: true
        ) else {
            lock.unlock()
            return false
        }
        // Auth can change while the atomic file replacement is in progress. Recheck after persistence
        // before exposing memory, and remove the just-written stale file if the boundary won.
        guard TraktPlaybackSnapshotPolicy.canCommit(
            capturedSession: sessionID,
            stateSession: stateSessionID,
            currentSession: TraktAuth.storedSessionID,
            capturedGeneration: gen,
            currentGeneration: generation
        ) else {
            _ = Self.resetCache()
            lock.unlock()
            return false
        }
        progressByID = progress
        continueWatchingSeeds = items
        hasContinueWatchingSnapshot = true
        lastActivityStamps = activity
        lock.unlock()
        return true
    }

    /// Gate on `/sync/last_activities`, then pull `/sync/playback/{movies,episodes}`.
    private func pullPlayback(generation gen: Int, sessionID: TraktSessionID) async {
        guard let token = try? await TraktAuth.shared.validToken(for: sessionID),
              TraktAuth.storedSessionID == sessionID else { return }
        // GATE: one cheap call tells us whether ANY pause changed since our last pull. Unchanged means the
        // two playback fetches would return exactly what we already hold, so we skip them. A nil stamp
        // (call failed / shape changed) falls through and pulls, so the gate can only ever save calls.
        let activity = await fetchPausedStamps(token: token, sessionID: sessionID)
        guard TraktAuth.storedSessionID == sessionID else { return }
        let snapshot = activitySnapshot(for: sessionID)
        if let activity, let known = snapshot.known,
           activity == known, snapshot.hasContinueWatchingSnapshot { return }

        var next: [String: Double] = [:]
        var playbackRows: [[String: Any]] = []
        var allLegsSucceeded = true
        for type in ["movies", "episodes"] {
            guard let rows = await getJSON(
                path: "/sync/playback/\(type)?extended=full",
                token: token,
                sessionID: sessionID
            ) else {
                allLegsSucceeded = false
                continue
            }
            playbackRows.append(contentsOf: rows)
            for row in rows {
                guard let percent = Self.double(row["progress"]), percent > 0 else { continue }
                Self.insert(row: row, percent: percent, into: &next)
            }
        }
        // The cache is replaced WHOLESALE, so only a WHOLE result may replace it. If EITHER leg failed
        // (offline / rate limited / 429), keep the last good cache: a partial write would drop every
        // position of the failed type, and since `lastActivityStamps` advances with it, the last_activities
        // gate would then skip the repair pull until someone paused something new on Trakt, leaving those
        // suggestions missing indefinitely. Costs at most one stale suggestion until the next refresh.
        // An EMPTY result when BOTH legs succeeded is meaningful (Trakt holds no paused items), so it is
        // still allowed to clear the cache; that is why this checks the leg outcomes and not `next.isEmpty`.
        guard allLegsSucceeded else { return }
        let nextContinueWatching = TraktContinueWatchingFold.fold(playbackRows)

        guard commitPlayback(
            progress: next,
            activity: activity,
            items: nextContinueWatching,
            generation: gen,
            sessionID: sessionID
        ) else { return }
        Self.postChanged()
    }

    /// Fold one `/sync/playback` row into the cache under EVERY id form of its title, so a lookup keyed by
    /// an imdb cover or a tmdb cover both hit. Movies key on the title id; episodes key on show id + SxxExx.
    private static func insert(row: [String: Any], percent: Double, into out: inout [String: Double]) {
        let type = row["type"] as? String
        if type == "episode" {
            guard let episode = row["episode"] as? [String: Any],
                  let season = double(episode["season"]).map({ Int($0) }),
                  let number = double(episode["number"]).map({ Int($0) }),
                  let showIDs = (row["show"] as? [String: Any])?["ids"] as? [String: Any] else { return }
            for id in identities(showIDs, isSeries: true) {
                out[episodeKey(id, season: season, episode: number)] = percent
            }
        } else if type == "movie" {
            guard let ids = (row["movie"] as? [String: Any])?["ids"] as? [String: Any] else { return }
            for id in identities(ids, isSeries: false) { out[id] = percent }
        }
    }

    /// Every id form VortX might key this title by: imdb `tt…`, `tmdb:<id>`, and the typed
    /// `tmdb:movie:<id>` / `tmdb:tv:<id>` shape some metas carry. A title Trakt returns with neither imdb
    /// nor tmdb yields no keys and is simply absent: we never guess an identity it did not give us.
    private static func identities(_ ids: [String: Any], isSeries: Bool) -> [String] {
        var out: [String] = []
        if let imdb = ids["imdb"] as? String, !imdb.isEmpty { out.append(imdb) }
        if let tmdb = double(ids["tmdb"]).map({ Int($0) }), tmdb > 0 {
            out.append("tmdb:\(tmdb)")
            out.append(isSeries ? "tmdb:tv:\(tmdb)" : "tmdb:movie:\(tmdb)")
        }
        return out
    }

    /// Coerce a Trakt JSON number (NSNumber via JSONSerialization, or defensively a numeric String).
    private static func double(_ value: Any?) -> Double? {
        if let n = value as? Double, n.isFinite { return n }
        if let n = value as? Int { return Double(n) }
        if let s = value as? String, let n = Double(s), n.isFinite { return n }
        return nil
    }

    // MARK: - Network (read-only)

    /// Independent movie/episode `paused_at` cursors from `GET /sync/last_activities`, or nil on failure.
    private func fetchPausedStamps(
        token: String,
        sessionID: TraktSessionID
    ) async -> TraktPlaybackActivityStamps? {
        guard let value = await authenticatedJSON(
            path: "/sync/last_activities",
            token: token,
            sessionID: sessionID
        ), let json = value as? [String: Any] else { return nil }
        let movies = (json["movies"] as? [String: Any])?["paused_at"] as? String
        let episodes = (json["episodes"] as? [String: Any])?["paused_at"] as? String
        return TraktPlaybackActivityStamps(movies: movies, episodes: episodes)
    }

    /// Authenticated GET returning a raw JSON array, or nil on any failure.
    private func getJSON(
        path: String,
        token: String,
        sessionID: TraktSessionID
    ) async -> [[String: Any]]? {
        (await authenticatedJSON(
            path: path,
            token: token,
            sessionID: sessionID
        )) as? [[String: Any]]
    }

    /// One captured session and bearer are used for the whole pull. Every leg validates the session both
    /// before and after its await. A 401 clears auth and visibility synchronously before this call returns.
    private func authenticatedJSON(
        path: String,
        token: String,
        sessionID: TraktSessionID
    ) async -> Any? {
        guard TraktAuth.storedSessionID == sessionID,
              let url = URL(string: TraktAuth.apiBase + path) else { return nil }
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: Self.request(url, token: token))
        } catch {
            return nil
        }
        guard TraktAuth.storedSessionID == sessionID else { return nil }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            await TraktAuth.shared.signOut(ifCurrent: sessionID)
            return nil
        }
        guard status == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: result.0)
    }

    /// The four headers Trakt requires. Reuses `TraktAuth` for creds so `TraktService` stays untouched,
    /// exactly as TraktSyncEngine's read path does.
    private static func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(TraktAuth.clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Persistence

    private static func loadCache(for sessionID: TraktSessionID?) -> (
        sessionID: TraktSessionID?,
        progress: [String: Double],
        activity: TraktPlaybackActivityStamps?,
        items: [TraktContinueWatchingSeed],
        hasSnapshot: Bool
    ) {
        do {
            let storage = try TraktPlaybackCacheStorage.live()
            guard let sessionID else {
                try storage.reset()
                return (nil, [:], nil, [], false)
            }
            guard let cache = try storage.load(for: sessionID) else {
                return (sessionID, [:], nil, [], false)
            }
            let activity = cache.activity ?? cache.stamp.map {
                TraktPlaybackActivityStamps(movies: $0, episodes: $0)
            }
            return (
                cache.sessionID,
                cache.progress,
                activity,
                cache.items,
                cache.hasSnapshot
            )
        } catch {
            logCacheFailure("load", error)
            return (sessionID, [:], nil, [], false)
        }
    }

    @discardableResult
    private static func saveCache(
        sessionID: TraktSessionID,
        progress: [String: Double],
        activity: TraktPlaybackActivityStamps?,
        items: [TraktContinueWatchingSeed],
        hasSnapshot: Bool
    ) -> Bool {
        do {
            let storage = try TraktPlaybackCacheStorage.live()
            try storage.save(
                TraktPlaybackCacheSnapshot(
                    sessionID: sessionID,
                    progress: progress,
                    stamp: activity?.legacyMaximum,
                    activity: activity,
                    items: items,
                    hasSnapshot: hasSnapshot
                )
            )
            return true
        } catch {
            logCacheFailure("write", error)
            return false
        }
    }

    @discardableResult
    private static func resetCache() -> Bool {
        do {
            try TraktPlaybackCacheStorage.live().reset()
            return true
        } catch {
            logCacheFailure("reset", error)
            return false
        }
    }

    private static func logCacheFailure(_ operation: String, _ error: Error) {
        let category = (error as? TraktPlaybackCacheError)?.rawValue ?? "unknown"
        DiagnosticsLog.log(
            "trakt-playback-cache",
            "operation=\(operation) failed=\(category)"
        )
    }

    private static func postChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: changedNote, object: nil)
        }
    }
}
