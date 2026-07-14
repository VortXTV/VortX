import Foundation

/// Additive-READ Trakt shadow: on sign-in and foreground (throttled) it pulls the user's watched
/// history + watchlist into a LOCAL cache (Application Support JSON) and exposes the watched `tt…` id
/// set so `WatchedIndex` can UNION it into the read path behind the opt-in `traktImportWatched` toggle.
/// It also owns an offline RETRY QUEUE for pushes (watchlist / watched) that failed while offline, drained
/// on the next refresh.
///
/// HARD INVARIANT (libraryItem POISON): this NEVER writes an engine `libraryItem`. Nothing here dispatches
/// an engine watched-mark. The shadow set lives only in this cache and is unioned into a read-only badge
/// index; no engine account sync is touched, so a Trakt pull can never poison account sync the way the
/// `ProfileSync.repairPoisonedLibrary` history exists to guard against.
///
/// Fully fail-soft: any pull error / offline / not-configured leaves the last cache intact and never
/// disturbs playback or the UI.
final class TraktSyncEngine {
    static let shared = TraktSyncEngine()

    /// Minimum gap between network refreshes; foreground + rail rebuilds call `refreshIfStale` freely.
    private static let refreshInterval: TimeInterval = 5 * 60
    /// Bound the retry queue so a long offline stretch can't grow it without limit.
    private static let queueCap = 200

    private let lock = NSLock()
    /// The watched `tt…` id set pulled from Trakt (movies + shows), unioned into `WatchedIndex`.
    private var watchedTT: Set<String>
    /// Persisted retry queue of pushes that failed (offline). Drained on refresh.
    private var pendingPushes: [PendingPush]
    private var lastRefresh: Date?
    private var refreshing = false
    /// Bumped by `reset()` (disconnect / sign-out). An in-flight refresh captures it before its network
    /// awaits and refuses to write back if it changed meanwhile, so a pull/drain that started before a
    /// disconnect can never resurrect the wiped shadow cache or push queue into the next account.
    private var generation = 0

    private init() {
        watchedTT = Self.loadWatched()
        pendingPushes = Self.loadQueue()
    }

    // MARK: - Read side (WatchedIndex consumes this)

    /// The shadow watched `tt…` id set, or empty when the import toggle is off. Synchronous + lock-guarded
    /// so `WatchedIndex.rebuild` can union it inline. Gated on the toggle here so a single call site in
    /// WatchedIndex stays clean.
    func shadowWatchedIDs() -> Set<String> {
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.traktImportWatched, default: false) else { return [] }
        lock.lock(); defer { lock.unlock() }
        return watchedTT
    }

    // MARK: - Disconnect

    /// Wipe ALL local Trakt shadow state (memory + disk): the watched shadow cache AND the pending push
    /// queue. Called on disconnect / sign-out so (1) the imported watched badges drop immediately and
    /// (2) a queued push can never drain into the NEXT account that signs in on this device
    /// (cross-account contamination). The caller notifies `WatchedIndex` so the read path rebuilds.
    func reset() {
        lock.lock()
        watchedTT = []
        pendingPushes = []
        lastRefresh = nil
        generation &+= 1   // invalidate any in-flight refresh so it cannot write its pre-reset result back
        lock.unlock()
        Self.saveWatched([])
        Self.saveQueue([])
    }

    // MARK: - Refresh (sign-in + foreground, throttled)

    /// Pull the watched history + drain the retry queue, at most once per `refreshInterval`. A no-op when
    /// Trakt is unconfigured / not connected. On a successful pull that changes the set, it nudges
    /// `WatchedIndex` to rebuild so imported badges appear without waiting for an engine event.
    func refreshIfStale() {
        guard TraktAuth.isConfigured else { return }
        lock.lock()
        if refreshing { lock.unlock(); return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.refreshInterval { lock.unlock(); return }
        refreshing = true
        lock.unlock()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock(); self.refreshing = false; self.lastRefresh = Date(); self.lock.unlock()
            }
            guard await TraktAuth.shared.isSignedIn else { return }
            await self.drainQueue()
            await self.pullWatched()
        }
    }

    /// Pull GET /sync/watched/{movies,shows} and fold the tt ids into the shadow cache. Reuses `TraktAuth`
    /// for a live bearer so `TraktService` stays untouched. Fail-soft: a failed leg contributes nothing.
    private func pullWatched() async {
        lock.lock(); let gen = generation; lock.unlock()
        var next = Set<String>()
        for type in ["movies", "shows"] {
            guard let rows = await getWatched(type: type) else { continue }
            for row in rows {
                let container = (row[type == "movies" ? "movie" : "show"]) as? [String: Any]
                if let ids = container?["ids"] as? [String: Any], let imdb = ids["imdb"] as? String, !imdb.isEmpty {
                    next.insert(imdb)
                }
            }
        }
        guard !next.isEmpty else { return }
        lock.lock()
        // A disconnect while this pull was in flight wiped watchedTT and bumped generation; do NOT write
        // the pre-reset set back, or the imported badges would resurrect after the user disconnected.
        guard generation == gen else { lock.unlock(); return }
        let changed = next != watchedTT
        watchedTT = next
        let snapshot = watchedTT
        lock.unlock()
        if changed {
            Self.saveWatched(snapshot)
            await MainActor.run { WatchedIndex.shared.externalShadowChanged() }
        }
    }

    /// Authenticated GET returning the raw JSON array, or nil on any failure.
    private func getWatched(type: String) async -> [[String: Any]]? {
        guard let token = try? await TraktAuth.shared.validToken(),
              let url = URL(string: TraktAuth.apiBase + "/sync/watched/\(type)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(TraktAuth.clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return json
    }

    // MARK: - Retry queue (offline pushes)

    /// A push that must survive an offline stretch: watchlist add/remove or a watched record. Only the
    /// title-level identity is stored, so a replay is idempotent enough for Trakt.
    struct PendingPush: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable { case watchlistAdd, watchlistRemove, watched }
        let kind: Kind
        let isSeries: Bool
        let imdb: String?
        let tmdb: Int?
        let season: Int?
        let episode: Int?
    }

    /// Record a push that failed to send, to retry on the next refresh. Bounded + deduped + persisted.
    func enqueue(_ push: PendingPush) {
        lock.lock()
        if !pendingPushes.contains(push) {
            pendingPushes.append(push)
            if pendingPushes.count > Self.queueCap { pendingPushes.removeFirst(pendingPushes.count - Self.queueCap) }
        }
        let snapshot = pendingPushes
        lock.unlock()
        Self.saveQueue(snapshot)
    }

    /// Re-attempt every queued push; keep the ones that still fail. Runs inside `refreshIfStale`.
    private func drainQueue() async {
        lock.lock()
        let queue = pendingPushes
        let gen = generation
        lock.unlock()
        guard !queue.isEmpty else { return }
        var stillFailing: [PendingPush] = []
        for push in queue {
            if await send(push) == false { stillFailing.append(push) }
        }
        lock.lock()
        // A disconnect/reset while we were sending bumps generation and wipes the queue. Writing our
        // pre-reset survivors back here would resurrect the wiped queue and let a push drain into the
        // NEXT account that signs in on this device (the cross-account contamination reset() prevents).
        // Drop the stale result; the live (empty) queue stands.
        guard generation == gen else { lock.unlock(); return }
        pendingPushes = stillFailing
        let snapshot = pendingPushes
        lock.unlock()
        Self.saveQueue(snapshot)
    }

    /// Send one queued push through `TraktService`. Returns true on success (or when the push carries no
    /// usable id, so it is dropped rather than retried forever).
    private func send(_ push: PendingPush) async -> Bool {
        let ids = TraktIDs(imdb: (push.imdb?.isEmpty == false) ? push.imdb : nil, tmdb: push.tmdb)
        guard ids.imdb != nil || ids.tmdb != nil else { return true }
        let items: TraktSyncItems = push.isSeries
            ? TraktSyncItems(shows: [TraktShow(ids: ids)])
            : TraktSyncItems(movies: [TraktMovie(ids: ids)])
        do {
            switch push.kind {
            case .watchlistAdd: _ = try await TraktService.shared.addToWatchlist(items)
            case .watchlistRemove: _ = try await TraktService.shared.removeFromWatchlist(items)
            case .watched:
                if push.isSeries, let s = push.season, let e = push.episode {
                    _ = try await TraktService.shared.scrobbleStop(
                        item: .episodeInShow(show: TraktShow(ids: ids), episode: TraktEpisode(season: s, number: e)),
                        progress: 100)
                } else {
                    _ = try await TraktService.shared.scrobbleStop(item: .movie(TraktMovie(ids: ids)), progress: 100)
                }
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Persistence (Application Support JSON)

    private static let watchedFile = "trakt-shadow-watched.json"
    private static let queueFile = "trakt-retry-queue.json"

    private static func supportURL(_ name: String) -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(name)
    }

    private static func loadWatched() -> Set<String> {
        guard let url = supportURL(watchedFile), let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    private static func saveWatched(_ set: Set<String>) {
        guard let url = supportURL(watchedFile), let data = try? JSONEncoder().encode(Array(set)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadQueue() -> [PendingPush] {
        guard let url = supportURL(queueFile), let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([PendingPush].self, from: data) else { return [] }
        return arr
    }

    private static func saveQueue(_ queue: [PendingPush]) {
        guard let url = supportURL(queueFile), let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
