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
    /// The `paused_at` stamp from `/sync/last_activities` at the last successful pull. Unchanged means Trakt
    /// has no new pause anywhere, so the two playback fetches are skipped entirely.
    private var lastActivityStamp: String?
    private var lastRefresh: Date?
    private var refreshing = false
    /// Bumped by `reset()` (disconnect). An in-flight refresh captures it before its network awaits and
    /// refuses to write back if it changed meanwhile, so a pull that started before a disconnect can never
    /// resurrect the wiped cache into the next account. Same guard as TraktSyncEngine.
    private var generation = 0

    private init() {
        let cached = Self.loadCache()
        progressByID = cached.progress
        lastActivityStamp = cached.stamp
    }

    // MARK: - Read side (the pre-play chip consumes this)

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
        guard let percent = progress(for: meta), percent.isFinite, percent > 0 else { return nil }

        let seconds = duration * (percent / 100)
        guard seconds.isFinite,
              seconds >= Self.minimumSuggestionSeconds,
              seconds <= duration * Self.maximumSuggestionFraction else { return nil }

        // VortX's own position wins unless Trakt is meaningfully ahead of it. Equal-or-behind means this
        // device already knows as much or more, so there is nothing to offer. This asymmetry is what keeps
        // one authority: we only ever ADD information the local side does not have.
        if let local = localSeconds, local > 0, seconds <= local + Self.staleLocalThresholdSeconds { return nil }
        return seconds
    }

    /// Trakt's stored percent for this title/episode under whichever id form the caller's meta carries.
    private func progress(for meta: PlaybackMeta) -> Double? {
        let key: String
        if meta.usesSeriesLifecycle {
            guard let season = meta.season, let episode = meta.episode else { return nil }
            key = Self.episodeKey(meta.libraryId, season: season, episode: episode)
        } else {
            key = meta.libraryId
        }
        lock.lock(); defer { lock.unlock() }
        return progressByID[key]
    }

    /// The episode key shape shared by the writer and the reader, so the two can never drift.
    private static func episodeKey(_ showID: String, season: Int, episode: Int) -> String {
        "\(showID)|s\(season)e\(episode)"
    }

    // MARK: - Disconnect

    /// Wipe all local playback-shadow state (memory + disk) on disconnect / sign-out, so the next account
    /// on this device can never see the previous account's positions.
    func reset() {
        lock.lock()
        progressByID = [:]
        lastActivityStamp = nil
        lastRefresh = nil
        generation &+= 1
        lock.unlock()
        Self.saveCache(progress: [:], stamp: nil)
    }

    // MARK: - Refresh (pre-play + foreground, throttled)

    /// Refresh the cache at most once per `refreshInterval`. No-op when Trakt is unconfigured, not
    /// connected, or the toggle is off. Safe to call from a view body path: returns immediately and does
    /// the work off-main.
    func refreshIfStale() {
        guard TraktAuth.isConfigured else { return }
        // The suggestion is opt-in, so a user who never turned it on must never pay a network call (or a
        // token refresh) for it. Mirrors TraktSyncEngine.pullWatched's toggle gate.
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.traktResumeSuggestion, default: false) else { return }
        lock.lock()
        if refreshing { lock.unlock(); return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.refreshInterval { lock.unlock(); return }
        refreshing = true
        let gen = generation
        lock.unlock()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                // Only stamp lastRefresh when no disconnect happened mid-refresh, so a reconnected account
                // is not locked out of its first pull for up to refreshInterval (the TraktSyncEngine lesson).
                if self.generation == gen { self.lastRefresh = Date() }
                self.refreshing = false
                self.lock.unlock()
            }
            guard await TraktAuth.shared.isSignedIn else { return }
            await self.pullPlayback(generation: gen)
        }
    }

    /// Gate on `/sync/last_activities`, then pull `/sync/playback/{movies,episodes}`.
    private func pullPlayback(generation gen: Int) async {
        // GATE: one cheap call tells us whether ANY pause changed since our last pull. Unchanged means the
        // two playback fetches would return exactly what we already hold, so we skip them. A nil stamp
        // (call failed / shape changed) falls through and pulls, so the gate can only ever save calls.
        let stamp = await fetchPausedStamp()
        lock.lock()
        let known = lastActivityStamp
        lock.unlock()
        if let stamp, let known, stamp == known { return }

        var next: [String: Double] = [:]
        var allLegsSucceeded = true
        for type in ["movies", "episodes"] {
            guard let rows = await getJSON(path: "/sync/playback/\(type)") else { allLegsSucceeded = false; continue }
            for row in rows {
                guard let percent = Self.double(row["progress"]), percent > 0 else { continue }
                Self.insert(row: row, percent: percent, into: &next)
            }
        }
        // The cache is replaced WHOLESALE, so only a WHOLE result may replace it. If EITHER leg failed
        // (offline / rate limited / 429), keep the last good cache: a partial write would drop every
        // position of the failed type, and since `lastActivityStamp` advances with it, the last_activities
        // gate would then skip the repair pull until someone paused something new on Trakt, leaving those
        // suggestions missing indefinitely. Costs at most one stale suggestion until the next refresh.
        // An EMPTY result when BOTH legs succeeded is meaningful (Trakt holds no paused items), so it is
        // still allowed to clear the cache; that is why this checks the leg outcomes and not `next.isEmpty`.
        guard allLegsSucceeded else { return }

        lock.lock()
        // A disconnect while this pull was in flight wiped the cache and bumped generation. Writing the
        // pre-reset result back would resurrect the previous account's positions.
        guard generation == gen else { lock.unlock(); return }
        progressByID = next
        lastActivityStamp = stamp
        lock.unlock()
        Self.saveCache(progress: next, stamp: stamp)
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

    /// The newest `paused_at` across movies + episodes from `GET /sync/last_activities`, or nil.
    private func fetchPausedStamp() async -> String? {
        guard let token = try? await TraktAuth.shared.validToken(),
              let url = URL(string: TraktAuth.apiBase + "/sync/last_activities"),
              let (data, response) = try? await URLSession.shared.data(for: Self.request(url, token: token)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let movies = (json["movies"] as? [String: Any])?["paused_at"] as? String
        let episodes = (json["episodes"] as? [String: Any])?["paused_at"] as? String
        // Compare the pair as one value: either side moving must invalidate the cache. Lexicographic max is
        // safe here because both are ISO-8601 UTC (`2016-06-01T00:00:00.000Z`), which sorts chronologically.
        return [movies, episodes].compactMap { $0 }.max()
    }

    /// Authenticated GET returning a raw JSON array, or nil on any failure.
    private func getJSON(path: String) async -> [[String: Any]]? {
        guard let token = try? await TraktAuth.shared.validToken(),
              let url = URL(string: TraktAuth.apiBase + path),
              let (data, response) = try? await URLSession.shared.data(for: Self.request(url, token: token)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return json
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

    // MARK: - Persistence (Application Support JSON)

    private static let cacheFile = "trakt-shadow-playback.json"

    /// The on-disk shape: the percent map plus the activity stamp it was pulled at.
    private struct Cache: Codable {
        var progress: [String: Double]
        var stamp: String?
    }

    private static func cacheURL() -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(cacheFile)
    }

    private static func loadCache() -> (progress: [String: Double], stamp: String?) {
        guard let url = cacheURL(), let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return ([:], nil) }
        return (cache.progress, cache.stamp)
    }

    private static func saveCache(progress: [String: Double], stamp: String?) {
        guard let url = cacheURL(),
              let data = try? JSONEncoder().encode(Cache(progress: progress, stamp: stamp)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
