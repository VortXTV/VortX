import Foundation

/// Additive-READ Trakt shadow: on sign-in and foreground (throttled) it pulls the user's watched
/// history + watchlist into a LOCAL cache (Application Support JSON) and exposes the watched id set
/// (imdb `tt…` AND `tmdb:<id>` forms) so `WatchedIndex` can UNION it into the read path behind the
/// opt-in `traktImportWatched` toggle.
/// It also owns an offline RETRY QUEUE for pushes (watchlist / watched) that failed while offline, drained
/// on the next refresh.
///
/// EPISODE GRAIN: the same `/sync/watched/shows` response Trakt already answers carries a per-season /
/// per-episode breakdown (it is omitted only when a caller asks for `extended=noseasons`, which this one
/// never has). The pull therefore harvests BOTH grains from ONE response: the title-level id set, and a
/// per-episode key set keyed `<showIdentity>|<season>|<episode>`. That gives episode watched-badges and a
/// locally computed next-unwatched episode with NO extra request and NO per-show fan-out. See
/// `TraktEpisodeShadow` for the read side that maps those keys back into the app's opaque video-id space.
///
/// HARD INVARIANT (libraryItem POISON): this NEVER writes an engine `libraryItem`. Nothing here dispatches
/// an engine watched-mark. The shadow set lives only in this cache and is unioned into a read-only badge
/// index; no engine account sync is touched, so a Trakt pull can never poison account sync the way the
/// `ProfileSync.repairPoisonedLibrary` history exists to guard against. The episode grain widens WHAT the
/// shadow knows, not what it writes: it stays additive-read, and the union direction means Trakt can only
/// ever ADD a badge, never clear one VortX recorded. The VortX account stays the authority.
///
/// Fully fail-soft: any pull error / offline / not-configured leaves the last cache intact and never
/// disturbs playback or the UI.
final class TraktSyncEngine {
    static let shared = TraktSyncEngine()

    /// Minimum gap between network refreshes; foreground + rail rebuilds call `refreshIfStale` freely.
    private static let refreshInterval: TimeInterval = 5 * 60
    /// Bound the retry queue so a long offline stretch can't grow it without limit.
    private static let queueCap = 200
    /// Bound the episode key set. A heavy account (hundreds of shows x hundreds of episodes, x3 identity
    /// forms) is the only realistic way this cache grows without limit, and it is held in memory for the
    /// process lifetime. At the cap the pull keeps the keys it already folded and stops adding, so a huge
    /// account degrades to PARTIAL episode badges rather than unbounded memory. 300k keys is roughly a
    /// 100k-episode account at three identity forms each, far beyond any real library.
    private static let episodeKeyCap = 300_000

    private let lock = NSLock()
    /// The watched id set pulled from Trakt (movies + shows), unioned into `WatchedIndex`. Holds BOTH
    /// identity forms per title: imdb `tt…` and `tmdb:<id>` (plus `tmdb:movie:<id>` / `tmdb:tv:<id>`),
    /// so a cover keyed by either identity matches. A cover carries one id; the union covers both.
    private var watchedIDs: Set<String>
    /// Per-episode watched keys, `<showIdentity>|<season>|<episode>` (e.g. `tt0944947|1|1`), holding the
    /// SAME identity forms per show as `watchedIDs` does per title, for the same reason: the reader knows
    /// the show by whatever identity its catalog used, so we index every form Trakt gave us and let the
    /// lookup match on one. Deliberately keyed on (season, episode) rather than the app's video id: video
    /// ids are opaque add-on strings, and Trakt speaks season/number, so mapping through the numbers keeps
    /// us from ever parsing a video id's format.
    private var watchedEpisodeKeys: Set<String>
    /// Persisted retry queue of pushes that failed (offline). Drained on refresh.
    private var pendingPushes: [PendingPush]
    /// `<movies.watched_at>|<episodes.watched_at>` from the last SUCCESSFUL pull, per `/sync/last_activities`.
    /// Present iff a pull succeeded, so it doubles as the "we have pulled before" flag (see `pullWatched`).
    private var lastActivityFingerprint: String?
    private var lastRefresh: Date?
    private var refreshing = false
    /// Set by `refreshNow()` when a force arrives while a refresh is already in flight. The single-flight
    /// guard would otherwise swallow the force, and this refresh's `defer` re-arms the very throttle the
    /// force cleared, so the in-flight refresh honors it once on completion with one more pass. Guarded by
    /// `lock`.
    private var refreshAgain = false
    /// Bumped by `reset()` (disconnect / sign-out). An in-flight refresh captures it before its network
    /// awaits and refuses to write back if it changed meanwhile, so a pull/drain that started before a
    /// disconnect can never resurrect the wiped shadow cache or push queue into the next account.
    private var generation = 0
    /// Exact Trakt credential session that owns every field above.
    private var stateSessionID: TraktSessionID?

    private struct PersistedSnapshot: Codable {
        let sessionID: TraktSessionID
        let watchedIDs: [String]
        let watchedEpisodeKeys: [String]
        let pendingPushes: [PendingPush]
        let lastActivityFingerprint: String?
    }

    private static let storage = try? PrivateExternalSyncStorage.live(
        provider: "Trakt",
        file: "sync-state.json",
        legacyFiles: [
            "trakt-shadow-watched.json",
            "trakt-shadow-watched-episodes.json",
            "trakt-retry-queue.json",
            "trakt-shadow-activity.json"
        ]
    )

    private init() {
        let initialSession = TraktAuth.storedSessionID
        stateSessionID = initialSession
        let snapshot = initialSession.flatMap(Self.load(for:))
        watchedIDs = Set(snapshot?.watchedIDs ?? [])
        watchedEpisodeKeys = Set((snapshot?.watchedEpisodeKeys ?? []).prefix(Self.episodeKeyCap))
        pendingPushes = (snapshot?.pendingPushes ?? []).filter { $0.sessionID == initialSession }
        lastActivityFingerprint = snapshot?.lastActivityFingerprint
        TraktAuthBoundary.observe(key: "trakt-sync-engine") { [weak self] sessionID in
            self?.reset(to: sessionID)
        }
        let currentSession = TraktAuth.storedSessionID
        if currentSession != initialSession { reset(to: currentSession) }
    }

    // MARK: - Read side (WatchedIndex consumes this)

    /// The shadow watched id set (imdb + tmdb forms), or empty when the import toggle is off. Synchronous
    /// + lock-guarded so `WatchedIndex.rebuild` can union it inline. Gated on the toggle here so a single
    /// call site in WatchedIndex stays clean.
    func shadowWatchedIDs() -> Set<String> {
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.traktImportWatched, default: false) else { return [] }
        guard let currentSession = TraktAuth.storedSessionID else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard stateSessionID == currentSession,
              TraktAuth.storedSessionID == currentSession else { return [] }
        return watchedIDs
    }

    /// True when Trakt records `season`x`episode` of the show known by `showIdentity` as watched. Gated on
    /// the same opt-in toggle as the title-level shadow, so import-off answers false everywhere. Synchronous
    /// + lock-guarded to match `shadowWatchedIDs`; callers batch a series' episodes through
    /// `TraktEpisodeShadow` rather than calling this per cell.
    func shadowWatchedEpisode(showIdentity: String, season: Int, episode: Int) -> Bool {
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.traktImportWatched, default: false) else { return false }
        guard let currentSession = TraktAuth.storedSessionID else { return false }
        lock.lock(); defer { lock.unlock() }
        guard stateSessionID == currentSession,
              TraktAuth.storedSessionID == currentSession else { return false }
        guard !watchedEpisodeKeys.isEmpty else { return false }
        return watchedEpisodeKeys.contains(TraktWatchedFold.episodeKey(showIdentity, season, episode))
    }

    /// True when the episode shadow holds anything at all. Lets a caller skip per-episode work entirely
    /// (the overwhelmingly common import-off / never-pulled case) without hashing a single key.
    func hasEpisodeShadow() -> Bool {
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.traktImportWatched, default: false) else { return false }
        guard let currentSession = TraktAuth.storedSessionID else { return false }
        lock.lock(); defer { lock.unlock() }
        guard stateSessionID == currentSession,
              TraktAuth.storedSessionID == currentSession else { return false }
        return !watchedEpisodeKeys.isEmpty
    }

    // MARK: - Disconnect

    /// Wipe ALL local Trakt shadow state (memory + disk): the watched shadow caches (title AND episode),
    /// the activity fingerprint, AND the pending push queue. Called on disconnect / sign-out so (1) the
    /// imported watched badges drop immediately and (2) a queued push can never drain into the NEXT account
    /// that signs in on this device (cross-account contamination). Clearing the fingerprint matters as much
    /// as clearing the data: it is what tells the next account's first pull that it has never run, so the
    /// `/sync/last_activities` gate cannot mistake the NEW account's timestamps for the old one's and skip
    /// the pull. The caller notifies `WatchedIndex` so the read path rebuilds.
    func reset() {
        reset(to: TraktAuth.storedSessionID)
    }

    private func reset(to sessionID: TraktSessionID?) {
        lock.lock()
        watchedIDs = []
        watchedEpisodeKeys = []
        pendingPushes = []
        lastActivityFingerprint = nil
        lastRefresh = nil
        stateSessionID = sessionID
        generation &+= 1   // invalidate any in-flight refresh so it cannot write its pre-reset result back
        try? Self.storage?.reset()
        lock.unlock()
        DispatchQueue.main.async { WatchedIndex.shared.externalShadowChanged() }
    }

    // MARK: - Refresh (sign-in + foreground, throttled)

    /// Pull the watched history + drain the retry queue, at most once per `refreshInterval`. A no-op when
    /// Trakt is unconfigured / not connected. On a successful pull that changes the set, it nudges
    /// `WatchedIndex` to rebuild so imported badges appear without waiting for an engine event.
    func refreshIfStale() {
        guard TraktAuth.isConfigured,
              let sessionID = TraktAuth.storedSessionID else { return }
        lock.lock()
        guard stateSessionID == sessionID,
              TraktAuth.storedSessionID == sessionID else { lock.unlock(); return }
        if refreshing { lock.unlock(); return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.refreshInterval { lock.unlock(); return }
        refreshing = true
        let gen = generation
        lock.unlock()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.refreshing = false
                // Only stamp lastRefresh when no disconnect/reset happened mid-refresh. A reset bumps
                // generation and nulls lastRefresh; re-stamping it here would make refreshIfStale early-
                // return for up to refreshInterval, silently delaying the reconnected account's first
                // watched pull and queue drain. Leaving it nil on a stale generation lets the next call
                // pull immediately.
                if self.generation == gen,
                   self.stateSessionID == sessionID,
                   TraktAuth.storedSessionID == sessionID {
                    self.lastRefresh = Date()
                }
                // A force (refreshNow) arrived mid-refresh and was swallowed by the single-flight guard;
                // its throttle clear was then re-armed by the stamp above. Honor it now with one more pass
                // so a just-enabled import is never deferred to the next unrelated engine event.
                let force = self.refreshAgain
                self.refreshAgain = false
                self.lock.unlock()
                if force { self.refreshNow() }
            }
            guard TraktAuth.storedSessionID == sessionID else { return }
            await self.drainQueue(expectedSession: sessionID, gen: gen)
            await self.pullWatched(expectedSession: sessionID, gen: gen)
            // Ratings convergence runs AFTER the drain on purpose: the drain clears each pushed rating's
            // pending flag, so a rating made offline is already mirrored (and no longer immune) by the time
            // the read-back below could look at it. Pulling first would see it still pending, skip it, and
            // simply defer convergence to the next cycle. Correct either way, just a cycle slower.
            await self.pullRatings(expectedSession: sessionID)
        }
    }

    /// Force an immediate refresh, bypassing the `refreshInterval` staleness throttle. Called when the user
    /// just turned import ON. The subtlety it exists for: while the import toggle is OFF, `refreshIfStale`
    /// still runs on every `WatchedIndex` rebuild (it drains the offline push queue and pulls ratings) and
    /// STAMPS `lastRefresh`, even though its `pullWatched` no-op's on the toggle. So by the time the user
    /// flips import on, the throttle is almost always armed, and a plain `refreshIfStale` would early-return
    /// and defer the FIRST watched pull by up to `refreshInterval` - the just-enabled Trakt badges would not
    /// appear until an unrelated engine event happened to fire minutes later (the "I turned it on and nothing
    /// happened" report). Clearing the stamp lets the pull run now. If a refresh is already in flight, latch
    /// `refreshAgain` so it re-runs on completion rather than being lost to the single-flight guard. Still
    /// gated on config / sign-in / import-toggle downstream: this forces the SCHEDULE, never the gates.
    func refreshNow() {
        lock.lock()
        lastRefresh = nil
        let inFlight = refreshing
        if inFlight { refreshAgain = true }
        lock.unlock()
        if !inFlight { refreshIfStale() }
    }

    /// Pull `GET /sync/ratings/{movies,shows}` and hand each leg to `TraktRatingsStore.merge`, which owns
    /// every rule about what a Trakt row may change (see that type's comment). This function deliberately
    /// contains NO merge policy: it only fetches and forwards, and a leg that fails contributes nothing
    /// rather than an empty array (an empty array is indistinguishable from "the user rated nothing", and
    /// the store must never see a failure as evidence).
    private func pullRatings(expectedSession: TraktSessionID) async {
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.traktRatings) else { return }
        let store = TraktRatingsStore.shared
        // Capture the generation BEFORE the network so a disconnect mid-pull discards the result rather
        // than resurrecting the wiped shadow into the next account.
        let context = store.currentContext
        guard context.sessionID == expectedSession else { return }
        var changed = false
        for type in [TraktCollectionType.movies, .shows] {
            guard let rows = try? await TraktService.shared.ratings(
                type: type,
                expectedSession: expectedSession
            ) else { continue }
            if store.merge(
                entries: rows,
                isSeries: type == .shows,
                gen: context.generation,
                sessionID: expectedSession
            ) {
                changed = true
            }
        }
        if changed { await MainActor.run { NotificationCenter.default.post(name: TraktRatingsStore.changedNote, object: nil) } }
    }

    /// Pull GET /sync/watched/{movies,shows} and fold each title's ids (imdb + tmdb forms) into the shadow
    /// cache, plus every watched episode of every show into the episode key set. Reuses `TraktAuth` for a
    /// live bearer so `TraktService` stays untouched. Fail-soft: a failed leg contributes nothing.
    ///
    /// Skipped entirely when `/sync/last_activities` says neither movies nor episodes have been watched
    /// since our last successful pull, so the steady state costs one small request every 5 minutes instead
    /// of re-downloading (and re-parsing) a whole library that did not change.
    private func pullWatched(expectedSession: TraktSessionID, gen: Int) async {
        // Import is opt-in: when the toggle is off, `shadowWatchedIDs()` returns empty anyway, so pulling
        // (and hitting the Trakt read endpoints + refreshing a token) would be pure waste. Skip the network
        // entirely until the user turns import on. The push/drain side is gated by its own toggles upstream.
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.traktImportWatched, default: false) else { return }
        lock.lock()
        guard generation == gen,
              stateSessionID == expectedSession,
              TraktAuth.storedSessionID == expectedSession else { lock.unlock(); return }
        let seenFingerprint = lastActivityFingerprint
        lock.unlock()
        // CHEAP GATE. `fingerprint` is nil when the call failed or Trakt sent neither timestamp: fail OPEN
        // (fall through and pull), because a gate that guesses "nothing changed" from a failure would pin
        // the shadow to a stale set indefinitely. Skip ONLY on a positive match against a fingerprint we
        // stamped after a real success, which is why a nil `seenFingerprint` (fresh install, or a
        // disconnect wipe) always pulls.
        let fingerprint = await watchedActivityFingerprint(expectedSession: expectedSession)
        if let fingerprint, let seenFingerprint, fingerprint == seenFingerprint { return }
        var next = Set<String>()
        var nextEpisodes = Set<String>()
        var moviesOK = false
        var showsOK = false
        for type in ["movies", "shows"] {
            let isSeries = (type == "shows")
            guard let rows = await getWatched(type: type, expectedSession: expectedSession) else { continue }
            if isSeries { showsOK = true } else { moviesOK = true }
            for row in rows {
                let container = (row[isSeries ? "show" : "movie"]) as? [String: Any]
                guard let ids = container?["ids"] as? [String: Any] else { continue }
                // Fold EVERY identity Trakt gives us for this title into the shadow set, not just imdb.
                // The badge read is a plain `ids.contains(item.id)`, and catalog covers are keyed by
                // whatever identity their source uses: Cinemeta covers are `tt…`, but our TMDB-backed
                // hub / Discover covers (and library items added from them) are `tmdb:<id>` (see
                // TMDBClient's `"tmdb:\(id)"`). Capturing ONLY imdb dropped every tmdb-keyed cover AND
                // any Trakt record that lacks an imdb id, so a title watched on Trakt showed as
                // unwatched (issue #143). Same id-mismatch class the trickplay tmdb-identity fix killed.
                //
                // `titleIdentities` is the ONE place that shape is spelled (see `TraktWatchedFold`), reused
                // for the episode keys below so a show's episodes are indexed under exactly the identities
                // its title is, and the two grains can never disagree about how this show is named.
                let identities = TraktWatchedFold.titleIdentities(ids, isSeries: isSeries)
                for identity in identities { next.insert(identity) }
                // A title Trakt returns with NEITHER imdb nor tmdb cannot be matched to any cover, so it
                // is simply absent from the set (no badge). We never guess an identity it did not give us.
                // The same holds for its episodes: no identity means no episode key either, which is why
                // a non-empty episode set always implies a non-empty title set.
                if isSeries, !identities.isEmpty, nextEpisodes.count < Self.episodeKeyCap {
                    Self.foldEpisodes(row["seasons"], identities: identities, into: &nextEpisodes)
                }
            }
        }
        // Stamp the fingerprint once BOTH legs actually answered, even if the account has nothing watched
        // (an empty but truthful result), so the gate can skip the next poll instead of re-pulling forever.
        if moviesOK, showsOK, let fingerprint {
            lock.lock()
            if generation == gen,
               stateSessionID == expectedSession,
               TraktAuth.storedSessionID == expectedSession {
                lastActivityFingerprint = fingerprint
                persistLocked()
            }
            lock.unlock()
        }
        // COMMIT GATE. Both legs must have answered before the caches are replaced. The pull is a REPLACE,
        // not a merge, so committing a half-result (movies 200, shows offline) would silently drop every
        // show badge until the next good pull, contradicting this type's "a failed leg contributes nothing"
        // contract. Requiring both legs keeps the last good cache whole on a partial failure. `next` empty
        // with both legs OK is a truthful empty account result and replaces stale state.
        guard moviesOK, showsOK else { return }
        lock.lock()
        // A disconnect while this pull was in flight wiped watchedIDs and bumped generation; do NOT write
        // the pre-reset set back, or the imported badges would resurrect after the user disconnected.
        guard generation == gen,
              stateSessionID == expectedSession,
              TraktAuth.storedSessionID == expectedSession else { lock.unlock(); return }
        let changed = next != watchedIDs || nextEpisodes != watchedEpisodeKeys
        watchedIDs = next
        watchedEpisodeKeys = nextEpisodes
        if changed { persistLocked() }
        lock.unlock()
        if changed {
            await MainActor.run { WatchedIndex.shared.externalShadowChanged() }
        }
    }

    /// Fold one show row's `seasons` array into `keys`, one key per (identity, season, episode). Trakt only
    /// lists an episode here once it has been watched, so mere PRESENCE is the watched signal; `plays` is
    /// not consulted (a row with 0 plays does not occur, and treating it as unwatched would drop badges).
    /// Tolerant of every shape it does not recognize: a missing / malformed season or episode number is
    /// skipped rather than guessed.
    private static func foldEpisodes(_ seasons: Any?, identities: [String], into keys: inout Set<String>) {
        guard let seasons = seasons as? [[String: Any]] else { return }
        for season in seasons {
            guard let seasonNumber = TraktWatchedFold.nonNegativeInt(season["number"]),
                  let episodes = season["episodes"] as? [[String: Any]] else { continue }
            for episode in episodes {
                guard let episodeNumber = TraktWatchedFold.nonNegativeInt(episode["number"]) else { continue }
                guard keys.count < episodeKeyCap else { return }
                for identity in identities { keys.insert(TraktWatchedFold.episodeKey(identity, seasonNumber, episodeNumber)) }
            }
        }
    }

    /// `<movies.watched_at>|<episodes.watched_at>` from GET /sync/last_activities, or nil on any failure.
    ///
    /// Deliberately NOT the response's `all` timestamp: `all` moves on ANY account activity (a rating, a
    /// comment, a list edit), so gating on it would re-pull the whole library for changes that cannot
    /// affect a watched badge. These two timestamps are exactly the ones that can.
    private func watchedActivityFingerprint(expectedSession: TraktSessionID) async -> String? {
        guard let json = await getJSONObject(
            path: "/sync/last_activities",
            expectedSession: expectedSession
        ) else { return nil }
        let movies = (json["movies"] as? [String: Any])?["watched_at"] as? String
        let episodes = (json["episodes"] as? [String: Any])?["watched_at"] as? String
        guard movies != nil || episodes != nil else { return nil }
        return "\(movies ?? "-")|\(episodes ?? "-")"
    }

    /// Authenticated GET returning the raw JSON array, or nil on any failure.
    ///
    /// NOTE: no `extended` parameter, deliberately. Trakt's default for `/sync/watched/shows` INCLUDES the
    /// per-season / per-episode breakdown that `foldEpisodes` reads; adding `extended=noseasons` here would
    /// silently strip it and reduce the episode shadow to nothing. If a future caller wants a lighter
    /// response, it must not do it by narrowing this request.
    private func getWatched(
        type: String,
        expectedSession: TraktSessionID
    ) async -> [[String: Any]]? {
        await getJSON(
            path: "/sync/watched/\(type)",
            expectedSession: expectedSession
        ) as? [[String: Any]]
    }

    /// Authenticated GET returning a raw JSON object, or nil on any failure.
    private func getJSONObject(path: String, expectedSession: TraktSessionID) async -> [String: Any]? {
        await getJSON(path: path, expectedSession: expectedSession) as? [String: Any]
    }

    /// Authenticated GET returning whatever JSON the endpoint sent, or nil on any failure (no token, bad
    /// URL, transport error, non-200, unparseable body). Every read here is fail-soft by contract, so the
    /// callers only ever distinguish "got it" from "did not".
    private func getJSON(path: String, expectedSession: TraktSessionID) async -> Any? {
        guard let token = try? await TraktAuth.shared.validToken(for: expectedSession),
              let url = URL(string: TraktAuth.apiBase + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(TraktAuth.clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let response = try? await AuthenticatedHTTPTransport.shared.send(
                  request,
                  allowedHosts: ["api.trakt.tv"],
                  maxResponseBytes: AuthenticatedHTTPTransport.snapshotResponseLimit
              ),
              response.statusCode == 200,
              await TraktAuth.shared.sessionID == expectedSession,
              let json = try? AuthenticatedHTTPTransport.jsonObject(from: response.data) else { return nil }
        return json
    }

    // MARK: - Retry queue (offline pushes)

    /// A push that must survive an offline stretch: watchlist add/remove, a watched record, or a rating
    /// set/clear. Only the title-level identity is stored, so a replay is idempotent enough for Trakt.
    ///
    /// `rating` / `ratedAtEpoch` are Optionals and carry the ratings payload only. Optionals decode as nil
    /// when the key is absent, so a queue file written before ratings existed still decodes (the whole
    /// array is decoded with one `try?`, so a single un-decodable row would drop every queued push).
    struct PendingPush: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable {
            case watchlistAdd, watchlistRemove, watched
            /// Set a 1...10 rating (`POST /sync/ratings`). Carries `rating` + `ratedAtEpoch`.
            case ratingSet
            /// Clear a rating (`POST /sync/ratings/remove`). Carries `ratedAtEpoch`, `rating` is nil.
            case ratingRemove
        }
        let kind: Kind
        let isSeries: Bool
        let imdb: String?
        let tmdb: Int?
        let season: Int?
        let episode: Int?
        /// Auth session captured when this push was created. nil decodes legacy queue rows, which are
        /// rejected fail closed because their account cannot be proven.
        let sessionID: TraktSessionID?
        /// Ratings only: the 1...10 score to send. nil for every other kind, and for `ratingRemove`.
        var rating: Int?
        /// Ratings only: when the user actually rated, so a push that drains days later still lands on
        /// Trakt with its ORIGINAL stamp. Sending the drain time instead would make Trakt's `rated_at`
        /// newer than the local entry's and let the next read-back adopt a value the user had since
        /// changed on another device. Also the key `TraktRatingsStore.markPushed` matches on.
        var ratedAtEpoch: Double?

        init(
            kind: Kind,
            isSeries: Bool,
            imdb: String?,
            tmdb: Int?,
            season: Int?,
            episode: Int?,
            sessionID: TraktSessionID? = TraktAuth.storedSessionID,
            rating: Int? = nil,
            ratedAtEpoch: Double? = nil
        ) {
            self.kind = kind
            self.isSeries = isSeries
            self.imdb = imdb
            self.tmdb = tmdb
            self.season = season
            self.episode = episode
            self.sessionID = sessionID
            self.rating = rating
            self.ratedAtEpoch = ratedAtEpoch
        }

        /// True for the two ratings kinds. Used to collapse superseded ratings pushes in `enqueue`.
        var isRating: Bool { kind == .ratingSet || kind == .ratingRemove }

        /// Same title (and same movie-vs-show shape) as another push, ignoring the value.
        func sameTitle(as other: PendingPush) -> Bool {
            isSeries == other.isSeries && imdb == other.imdb && tmdb == other.tmdb
        }
    }

    /// Record a push that failed to send, to retry on the next refresh. Bounded + deduped + persisted.
    ///
    /// RATINGS COLLAPSE: a rating is LAST-WRITE-WINS state, not an event, so only the newest queued
    /// rating per title is kept. Without this, rating 7 then 8 while offline queues both, and a drain
    /// where the 7 fails and the 8 succeeds would retry the 7 afterwards and clobber the 8 on Trakt with
    /// a value the user had already replaced. Watchlist/watched pushes stay append-only (they are
    /// idempotent adds, and their existing `contains` dedupe already covers repeats).
    func enqueue(_ push: PendingPush) {
        guard let sessionID = push.sessionID,
              TraktAuth.storedSessionID == sessionID else {
            DiagnosticsLog.log("trakt-queue", "push dropped reason=stale-session")
            return
        }
        lock.lock()
        guard stateSessionID == sessionID,
              TraktAuth.storedSessionID == sessionID else { lock.unlock(); return }
        if push.isRating {
            pendingPushes.removeAll { $0.isRating && $0.sameTitle(as: push) }
            pendingPushes.append(push)
            if pendingPushes.count > Self.queueCap { pendingPushes.removeFirst(pendingPushes.count - Self.queueCap) }
        } else if !pendingPushes.contains(push) {
            pendingPushes.append(push)
            if pendingPushes.count > Self.queueCap { pendingPushes.removeFirst(pendingPushes.count - Self.queueCap) }
        }
        persistLocked()
        lock.unlock()
    }

    /// Re-attempt every queued push; keep the ones that still fail. Runs inside `refreshIfStale`.
    private func drainQueue(expectedSession: TraktSessionID, gen: Int) async {
        lock.lock()
        guard generation == gen,
              stateSessionID == expectedSession,
              TraktAuth.storedSessionID == expectedSession else { lock.unlock(); return }
        let queue = pendingPushes
        lock.unlock()
        guard !queue.isEmpty else { return }
        var stillFailing: [PendingPush] = []
        for push in queue {
            if await send(push, expectedSession: expectedSession) == false { stillFailing.append(push) }
        }
        lock.lock()
        // A disconnect/reset while we were sending bumps generation and wipes the queue. Writing our
        // pre-reset survivors back here would resurrect the wiped queue and let a push drain into the
        // NEXT account that signs in on this device (the cross-account contamination reset() prevents).
        // Drop the stale result; the live (empty) queue stands.
        guard generation == gen,
              stateSessionID == expectedSession,
              TraktAuth.storedSessionID == expectedSession else { lock.unlock(); return }
        // Merge, do not overwrite: enqueue() may have appended pushes while our sends were awaiting
        // (a watched-mark made mid-drain). Overwriting pendingPushes with stillFailing alone would
        // silently drop those for a still-connected provider. Keep the survivors, then append anything
        // added since the drained snapshot, deduped and capped as enqueue() does.
        let appendedDuringDrain = pendingPushes.filter { !queue.contains($0) }
        var merged = stillFailing
        for push in appendedDuringDrain where !merged.contains(push) { merged.append(push) }
        if merged.count > Self.queueCap { merged.removeFirst(merged.count - Self.queueCap) }
        pendingPushes = merged
        persistLocked()
        lock.unlock()
    }

    /// Send one queued push through `TraktService`. Returns true on success (or when the push carries no
    /// usable id, so it is dropped rather than retried forever).
    private func send(_ push: PendingPush, expectedSession: TraktSessionID) async -> Bool {
        // A legacy, signed-out, or old-account row is terminally dropped. Retrying it later could only
        // move one account's media state through another account's credentials.
        guard let sessionID = push.sessionID,
              sessionID == expectedSession,
              TraktAuth.storedSessionID == sessionID else { return true }
        let ids = TraktIDs(imdb: (push.imdb?.isEmpty == false) ? push.imdb : nil, tmdb: push.tmdb)
        guard ids.imdb != nil || ids.tmdb != nil else { return true }
        let items: TraktSyncItems = push.isSeries
            ? TraktSyncItems(shows: [TraktShow(ids: ids)])
            : TraktSyncItems(movies: [TraktMovie(ids: ids)])
        do {
            switch push.kind {
            case .watchlistAdd:
                _ = try await TraktService.shared.addToWatchlist(
                    items,
                    expectedSession: sessionID
                )
            case .watchlistRemove:
                _ = try await TraktService.shared.removeFromWatchlist(
                    items,
                    expectedSession: sessionID
                )
            case .watched:
                if push.isSeries, let s = push.season, let e = push.episode {
                    _ = try await TraktService.shared.scrobbleStop(
                        item: .episodeInShow(show: TraktShow(ids: ids), episode: TraktEpisode(season: s, number: e)),
                        progress: 100,
                        expectedSession: sessionID
                    )
                } else {
                    _ = try await TraktService.shared.scrobbleStop(
                        item: .movie(TraktMovie(ids: ids)),
                        progress: 100,
                        expectedSession: sessionID
                    )
                }
            case .ratingSet:
                // A queued rating with no value is malformed and can never succeed; drop it (return true)
                // rather than retry it forever.
                guard let rating = push.rating else { return true }
                // Send the ORIGINAL rated_at, not "now": the local shadow's newer-wins merge compares
                // against this stamp, and a drain-time stamp would make Trakt look newer than the local
                // entry it came from.
                let stamp = push.ratedAtEpoch.map { TraktRatedAt.string(from: Date(timeIntervalSince1970: $0)) }
                let items = push.isSeries
                    ? TraktRatingItems(shows: [TraktRatedShow(ids: ids, rating: rating, ratedAt: stamp)])
                    : TraktRatingItems(movies: [TraktRatedMovie(ids: ids, rating: rating, ratedAt: stamp)])
                _ = try await TraktService.shared.addRatings(
                    items,
                    expectedSession: sessionID
                )
                guard TraktAuth.storedSessionID == sessionID else { return true }
                // Trakt now has this exact value: clear the entry's pending flag so read-back convergence
                // can apply to it again. No-op if the user has since re-rated (markPushed matches on the
                // value + stamp that were actually sent).
                TraktRatingsStore.shared.markPushed(imdb: push.imdb, tmdb: push.tmdb, isSeries: push.isSeries,
                                                    rating: rating, ratedAtEpoch: push.ratedAtEpoch,
                                                    sessionID: sessionID)
            case .ratingRemove:
                let items = push.isSeries
                    ? TraktRatingItems(shows: [TraktRatedShow(ids: ids)])
                    : TraktRatingItems(movies: [TraktRatedMovie(ids: ids)])
                _ = try await TraktService.shared.removeRatings(
                    items,
                    expectedSession: sessionID
                )
                guard TraktAuth.storedSessionID == sessionID else { return true }
                TraktRatingsStore.shared.markPushed(imdb: push.imdb, tmdb: push.tmdb, isSeries: push.isSeries,
                                                    rating: nil, ratedAtEpoch: push.ratedAtEpoch,
                                                    sessionID: sessionID)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Protected persistence

    private static func load(for sessionID: TraktSessionID) -> PersistedSnapshot? {
        guard let storage else { return nil }
        let data: Data
        do {
            guard let stored = try storage.load() else { return nil }
            data = stored
        } catch {
            try? storage.reset()
            return nil
        }
        guard let snapshot = try? JSONDecoder().decode(PersistedSnapshot.self, from: data),
              snapshot.sessionID == sessionID else {
            try? storage.reset()
            return nil
        }
        return snapshot
    }

    /// Called only with `lock` held, so no stale save can overtake a boundary reset.
    private func persistLocked() {
        guard let storage = Self.storage, let stateSessionID else {
            try? Self.storage?.reset()
            return
        }
        let snapshot = PersistedSnapshot(
            sessionID: stateSessionID,
            watchedIDs: Array(watchedIDs),
            watchedEpisodeKeys: Array(watchedEpisodeKeys),
            pendingPushes: pendingPushes.filter { $0.sessionID == stateSessionID },
            lastActivityFingerprint: lastActivityFingerprint
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? storage.save(data)
    }
}
