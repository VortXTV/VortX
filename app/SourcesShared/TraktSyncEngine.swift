import Foundation
import os

/// Additive-READ Trakt shadow: on sign-in and foreground (throttled) it pulls the user's watched
/// history + watchlist into a LOCAL cache (Application Support JSON) and exposes the watched id set
/// (imdb `tt…` AND `tmdb:<id>` forms) so `WatchedIndex` can UNION it into the read path behind the
/// opt-in `traktImportWatched` toggle.
/// It also owns an offline RETRY QUEUE for pushes (watchlist / watched) that failed while offline, drained
/// on the next refresh.
///
/// EPISODE GRAIN: explicitly paginated `/sync/watched/shows?extended=progress` pages carry the
/// per-season / per-episode breakdown. The default response no longer includes that progress.
/// Both complete title legs and all episode keys commit together; incomplete or oversized pulls keep
/// the previous cache. Presence is positive watched-badge evidence, not absence-as-unwatched or
/// authoritative next-episode evidence. No per-show fan-out is needed for this badge import.
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
final class TraktSyncEngine: Sendable {
    static let shared = TraktSyncEngine()

    /// Minimum gap between network refreshes; foreground + rail rebuilds call `refreshIfStale` freely.
    private static let refreshInterval: TimeInterval = 5 * 60
    /// Bound the retry queue so a long offline stretch can't grow it without limit.
    private static let queueCap = 200
    /// The reader fails closed at this key cap; it never commits a truncated episode history.
    private static let episodeKeyCap = TraktWatchedSnapshotReader.Limits().episodeKeys

    private struct State: Sendable {
        /// The watched id set pulled from Trakt (movies + shows), unioned into `WatchedIndex`. Holds BOTH
        /// identity forms per title: imdb `tt…` and `tmdb:<id>` (plus `tmdb:movie:<id>` / `tmdb:tv:<id>`),
        /// so a cover keyed by either identity matches. A cover carries one id; the union covers both.
        var watchedIDs: Set<String> = []
        /// Per-episode watched keys, `<showIdentity>|<season>|<episode>` (e.g. `tt0944947|1|1`), holding the
        /// SAME identity forms per show as `watchedIDs` does per title, for the same reason: the reader knows
        /// the show by whatever identity its catalog used, so we index every form Trakt gave us and let the
        /// lookup match on one. Deliberately keyed on (season, episode) rather than the app's video id: video
        /// ids are opaque add-on strings, and Trakt speaks season/number, so mapping through the numbers keeps
        /// us from ever parsing a video id's format.
        var watchedEpisodeKeys: Set<String> = []
        /// Persisted retry queue of pushes that failed (offline). Drained on refresh.
        var pendingPushes: [PendingPush] = []
        /// `<movies.watched_at>|<episodes.watched_at>` from the last SUCCESSFUL pull, per `/sync/last_activities`.
        /// It can skip a read only when paired with the current complete-pagination read version.
        var lastActivityFingerprint: String?
        var watchedReadVersion: Int?
        var watchedShowInventory: [TraktWatchedShowInventoryEntry]?
        var watchedInventoryRevision: UUID?
        /// Never carries raw state across an account boundary; guarded by the same lock as the cache.
        var snapshotRetention: TraktSyncSnapshotEnvelope?
        var snapshotPersistenceBlocked = false
        /// One watched read across badge and selected-CW callers. A reset invalidates its owner token;
        /// the retired flight's defer cannot release a successor flight.
        var watchedReadFlight: UUID?
        var lastWatchedRead: Date?
        var lastRefresh: Date?
        var refreshing = false
        /// Set by `refreshNow()` when a force arrives while a refresh is already in flight. The single-flight
        /// guard would otherwise swallow the force, and this refresh's `defer` re-arms the very throttle the
        /// force cleared, so the in-flight refresh honors it once on completion with one more pass. Guarded by
        /// the checked state lock.
        var refreshAgain = false
        /// Bumped by `reset()` (disconnect / sign-out). An in-flight refresh captures it before its network
        /// awaits and refuses to write back if it changed meanwhile, so a pull/drain that started before a
        /// disconnect can never resurrect the wiped shadow cache or push queue into the next account.
        var generation = 0
        /// Exact Trakt credential session that owns every field above.
        var stateSessionID: TraktSessionID?
    }
    private let cache: OSAllocatedUnfairLock<State>

    private struct PersistedSnapshot: Codable, Sendable {
        let sessionID: TraktSessionID
        let watchedIDs: [String]
        let watchedEpisodeKeys: [String]
        let pendingPushes: [PendingPush]
        let lastActivityFingerprint: String?
        /// Optional for backward-compatible decoding. A missing/old version invalidates only the
        /// skip cursor, preserving old badge sets and same-session pending pushes until a good read.
        let watchedReadVersion: Int?
        let watchedShowInventory: [TraktWatchedShowInventoryEntry]?
        let watchedInventoryRevision: UUID?
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
        let loaded = initialSession.map(Self.load(for:))
        let snapshot = loaded?.snapshot
        var initial = State()
        initial.stateSessionID = initialSession
        initial.watchedIDs = Set(snapshot?.watchedIDs ?? [])
        initial.watchedEpisodeKeys = Set((snapshot?.watchedEpisodeKeys ?? []).prefix(Self.episodeKeyCap))
        initial.pendingPushes = (snapshot?.pendingPushes ?? []).filter { $0.sessionID == initialSession }
        initial.lastActivityFingerprint = snapshot?.lastActivityFingerprint
        initial.watchedReadVersion = snapshot?.watchedReadVersion
        initial.watchedShowInventory = snapshot?.watchedShowInventory
        initial.watchedInventoryRevision = snapshot?.watchedInventoryRevision
        initial.snapshotRetention = loaded?.retention
        initial.snapshotPersistenceBlocked = loaded?.blocked ?? false
        cache = OSAllocatedUnfairLock(initialState: initial)
        TraktAuthBoundary.observe(key: "trakt-sync-engine") { [weak self] sessionID in
            self?.reset(to: sessionID)
        }
        let currentSession = TraktAuth.storedSessionID
        if currentSession != initialSession { reset(to: currentSession) }
    }

    // MARK: - Read side (WatchedIndex consumes this)

    /// nil is unavailable/not yet complete; a returned empty entries array is a proven empty
    /// account inventory. Consumers must recheck session, revision and membership after awaits.
    func currentWatchedShowInventory(
        expectedSession: TraktSessionID, purpose: TraktWatchedReadPurpose = .badgeImport
    ) -> TraktWatchedShowInventory? {
        guard Self.watchedPurposeIsCurrent(purpose) else { return nil }
        return cache.withLock { state in
            guard !state.snapshotPersistenceBlocked, state.stateSessionID == expectedSession,
                  TraktAuth.storedSessionID == expectedSession,
                  state.watchedReadVersion == TraktWatchedSnapshotReader.readVersion,
                  let entries = state.watchedShowInventory, let revision = state.watchedInventoryRevision else { return nil }
            return .init(sessionID: expectedSession, revision: revision,
                         readVersion: TraktWatchedSnapshotReader.readVersion,
                         activityFingerprint: state.lastActivityFingerprint, entries: entries)
        }
    }

    /// Read-only refresh for a captured caller purpose. Never drains provider writes, pulls ratings,
    /// or changes the badge-import toggle. An existing flight is not joined by an unrelated intent:
    /// return the current complete cache (or nil), and let a later visible-lane read retry.
    func refreshWatchedShowInventory(
        expectedSession: TraktSessionID, purpose: TraktWatchedReadPurpose
    ) async -> TraktWatchedShowInventory? {
        guard TraktAuth.isConfigured, Self.watchedPurposeIsCurrent(purpose),
              TraktAuth.storedSessionID == expectedSession else { return nil }
        let context: (generation: Int, recent: Bool)? = cache.withLock { state in
            guard state.stateSessionID == expectedSession else { return nil }
            let recent = state.lastWatchedRead.map { Date().timeIntervalSince($0) < Self.refreshInterval } ?? false
            return (state.generation, recent)
        }
        guard let context else { return nil }
        if !context.recent { await pullWatched(expectedSession: expectedSession, gen: context.generation, purpose: purpose) }
        guard watchedPullIsCurrent(expectedSession: expectedSession, gen: context.generation, purpose: purpose) else { return nil }
        return currentWatchedShowInventory(expectedSession: expectedSession, purpose: purpose)
    }

    /// The shadow watched id set (imdb + tmdb forms), or empty when the import toggle is off. Synchronous
    /// + lock-guarded so `WatchedIndex.rebuild` can union it inline. Gated on the toggle here so a single
    /// call site in WatchedIndex stays clean.
    func shadowWatchedIDs() -> Set<String> {
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.traktImportWatched, default: false) else { return [] }
        guard let currentSession = TraktAuth.storedSessionID else { return [] }
        return cache.withLock { state in
            guard state.stateSessionID == currentSession,
                  TraktAuth.storedSessionID == currentSession else { return [] }
            return state.watchedIDs
        }
    }

    /// True when Trakt records `season`x`episode` of the show known by `showIdentity` as watched. Gated on
    /// the same opt-in toggle as the title-level shadow, so import-off answers false everywhere. Synchronous
    /// + lock-guarded to match `shadowWatchedIDs`; callers batch a series' episodes through
    /// `TraktEpisodeShadow` rather than calling this per cell.
    func shadowWatchedEpisode(showIdentity: String, season: Int, episode: Int) -> Bool {
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.traktImportWatched, default: false) else { return false }
        guard let currentSession = TraktAuth.storedSessionID else { return false }
        return cache.withLock { state in
            guard state.stateSessionID == currentSession,
                  TraktAuth.storedSessionID == currentSession else { return false }
            guard !state.watchedEpisodeKeys.isEmpty else { return false }
            return state.watchedEpisodeKeys.contains(TraktWatchedFold.episodeKey(showIdentity, season, episode))
        }
    }

    /// True when the episode shadow holds anything at all. Lets a caller skip per-episode work entirely
    /// (the overwhelmingly common import-off / never-pulled case) without hashing a single key.
    func hasEpisodeShadow() -> Bool {
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.traktImportWatched, default: false) else { return false }
        guard let currentSession = TraktAuth.storedSessionID else { return false }
        return cache.withLock { state in
            guard state.stateSessionID == currentSession,
                  TraktAuth.storedSessionID == currentSession else { return false }
            return !state.watchedEpisodeKeys.isEmpty
        }
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
        cache.withLock { state in
            state.watchedIDs = []
            state.watchedEpisodeKeys = []
            state.pendingPushes = []
            state.lastActivityFingerprint = nil
            state.watchedReadVersion = nil
            state.watchedShowInventory = nil
            state.watchedInventoryRevision = nil
            state.snapshotRetention = nil
            state.snapshotPersistenceBlocked = false
            state.watchedReadFlight = nil
            state.lastWatchedRead = nil
            state.lastRefresh = nil
            state.stateSessionID = sessionID
            state.generation &+= 1   // invalidate any in-flight refresh so it cannot write its pre-reset result back
            try? Self.storage?.reset()
        }
        DispatchQueue.main.async { WatchedIndex.shared.externalShadowChanged() }
    }

    // MARK: - Refresh (sign-in + foreground, throttled)

    /// Pull the watched history + drain the retry queue, at most once per `refreshInterval`. A no-op when
    /// Trakt is unconfigured / not connected. On a successful pull that changes the set, it nudges
    /// `WatchedIndex` to rebuild so imported badges appear without waiting for an engine event.
    func refreshIfStale() {
        guard TraktAuth.isConfigured,
              let sessionID = TraktAuth.storedSessionID else { return }
        let admission: Int? = cache.withLock { state in
            guard state.stateSessionID == sessionID,
                  TraktAuth.storedSessionID == sessionID, !state.refreshing else { return nil }
            if let last = state.lastRefresh, Date().timeIntervalSince(last) < Self.refreshInterval { return nil }
            state.refreshing = true
            return state.generation
        }
        guard let gen = admission else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                let force = self.cache.withLock { state in
                    state.refreshing = false
                    // Only stamp lastRefresh when no disconnect/reset happened mid-refresh. A reset bumps
                    // generation and nulls lastRefresh; re-stamping it here would make refreshIfStale early-
                    // return for up to refreshInterval, silently delaying the reconnected account's first
                    // watched pull and queue drain. Leaving it nil on a stale generation lets the next call
                    // pull immediately.
                    if state.generation == gen,
                       state.stateSessionID == sessionID,
                       TraktAuth.storedSessionID == sessionID {
                        state.lastRefresh = Date()
                    }
                    // A force (refreshNow) arrived mid-refresh and was swallowed by the single-flight guard;
                    // its throttle clear was then re-armed by the stamp above. Honor it now with one more pass
                    // so a just-enabled import is never deferred to the next unrelated engine event.
                    let force = state.refreshAgain
                    state.refreshAgain = false
                    return force
                }
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
        let inFlight = cache.withLock { state in
            state.lastRefresh = nil
            let inFlight = state.refreshing
            if inFlight { state.refreshAgain = true }
            return inFlight
        }
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

    /// Fetch a complete paginated badge snapshot, then publish its sets, cursor, and read version
    /// in one lock-protected persistence transaction. Nothing commits on a failed page/leg/boundary.
    private func pullWatched(
        expectedSession: TraktSessionID, gen: Int, purpose: TraktWatchedReadPurpose = .badgeImport
    ) async {
        guard watchedPullIsCurrent(expectedSession: expectedSession, gen: gen, purpose: purpose) else { return }
        let context: (flight: UUID, fingerprint: String?, version: Int?)? = cache.withLock { state in
            guard !state.snapshotPersistenceBlocked, state.generation == gen, state.stateSessionID == expectedSession,
                  state.watchedReadFlight == nil else { return nil }
            let flight = UUID()
            state.watchedReadFlight = flight
            let seenVersion = state.watchedShowInventory != nil && state.watchedInventoryRevision != nil ? state.watchedReadVersion : nil
            return (flight, state.lastActivityFingerprint, seenVersion)
        }
        guard let context else { return }
        let flight = context.flight
        defer { finishWatchedRead(flight: flight) }
        let snapshot: TraktWatchedSnapshotReader.Snapshot
        do {
            let complete = try await TraktWatchedSnapshotReader.read(
                previousFingerprint: context.fingerprint,
                previousReadVersion: context.version,
                isCurrent: { self.watchedPullIsCurrent(expectedSession: expectedSession, gen: gen, purpose: purpose) },
                parsingIsCurrent: { self.watchedParsingIsCurrent(expectedSession: expectedSession, gen: gen) },
                request: { path in
                    try await self.watchedData(path: path, expectedSession: expectedSession, gen: gen, purpose: purpose)
                }
            )
            guard let complete else {
                guard watchedPullIsCurrent(expectedSession: expectedSession, gen: gen, purpose: purpose) else { return }
                cache.withLock { state in
                    if state.generation == gen, state.stateSessionID == expectedSession, state.watchedReadFlight == flight {
                        state.lastWatchedRead = Date()
                    }
                }
                return
            }
            snapshot = complete
        } catch {
            // Provider failures, oversized/incomplete traversals, stale sessions and cancellation
            // leave the prior complete cache, cursor and pending queue exactly as they were.
            return
        }
        // Evaluate external intent outside the engine lock: a caller predicate is never invoked
        // under our lock. The consumer independently fences its own publication after this await.
        guard Self.watchedPurposeIsCurrent(purpose) else { return }
        let prepared: (candidate: PersistedSnapshot, data: Data, changed: Bool)? = cache.withLock { state in
            guard !Task.isCancelled,
                  state.generation == gen,
                  state.watchedReadFlight == flight,
                  state.stateSessionID == expectedSession,
                  TraktAuth.storedSessionID == expectedSession else { return nil }
            let changed = snapshot.watchedIDs != state.watchedIDs || snapshot.episodeKeys != state.watchedEpisodeKeys
            let revision = UUID()
            // Preflight the complete retained envelope before publishing any part of the transaction.
            // Raw inventory rows can be large; overflow must not become a partial or memory-only cursor.
            let candidate = PersistedSnapshot(sessionID: expectedSession,
                watchedIDs: Array(snapshot.watchedIDs), watchedEpisodeKeys: Array(snapshot.episodeKeys),
                pendingPushes: state.pendingPushes.filter { $0.sessionID == expectedSession },
                lastActivityFingerprint: snapshot.activityFingerprint,
                watchedReadVersion: TraktWatchedSnapshotReader.readVersion,
                watchedShowInventory: snapshot.shows, watchedInventoryRevision: revision)
            guard let data = Self.persistedDataLocked(candidate, state: state) else { return nil }
            return (candidate, data, changed)
        }
        guard let prepared else { return }
        // Recheck Home intent after potentially expensive envelope encoding. If a queue edit or
        // reset wins while unlocked, discard this candidate instead of overwriting the newer state.
        guard Self.watchedPurposeIsCurrent(purpose) else { return }
        let committed = cache.withLock { state in
            guard !Task.isCancelled, state.generation == gen, state.stateSessionID == expectedSession,
                  state.watchedReadFlight == flight, state.pendingPushes == prepared.candidate.pendingPushes,
                  TraktAuth.storedSessionID == expectedSession else { return false }
            guard let storage = Self.storage else { return false }
            do {
                try storage.save(prepared.data)
            } catch {
                // A bounded candidate is not a durable replace acknowledgement. Keep all old memory
                // state/cursors when protected persistence is unavailable; a later pull can retry.
                return false
            }
            state.watchedIDs = snapshot.watchedIDs
            state.watchedEpisodeKeys = snapshot.episodeKeys
            state.lastActivityFingerprint = snapshot.activityFingerprint
            state.watchedReadVersion = TraktWatchedSnapshotReader.readVersion
            state.watchedShowInventory = snapshot.shows
            state.watchedInventoryRevision = prepared.candidate.watchedInventoryRevision
            state.lastWatchedRead = Date()
            // The one saved envelope includes both sets and cursor, even if only its version changed.
            return true
        }
        guard committed else { return }
        if prepared.changed && ExternalSyncToggle.isOn(ExternalSyncToggle.traktImportWatched, default: false) {
            await MainActor.run { WatchedIndex.shared.externalShadowChanged() }
        }
    }

    /// Synchronous fence usable before/after every network/token suspension and immediately at commit.
    private static func watchedPurposeIsCurrent(_ purpose: TraktWatchedReadPurpose) -> Bool {
        guard !Task.isCancelled else { return false }
        switch purpose {
        case .badgeImport: return ExternalSyncToggle.isOn(ExternalSyncToggle.traktImportWatched, default: false)
        case .selectedContinueWatching(let isCurrent): return isCurrent()
        }
    }

    private func finishWatchedRead(flight: UUID) {
        cache.withLock { state in
            if state.watchedReadFlight == flight { state.watchedReadFlight = nil }
        }
    }

    /// Cheap loop fence: no Keychain, defaults, or caller callbacks. The generation preserves ABA
    /// protection even if a reset rebinds to an equal session identifier during parsing.
    private func watchedParsingIsCurrent(expectedSession: TraktSessionID, gen: Int) -> Bool {
        guard !Task.isCancelled else { return false }
        return cache.withLock { $0.generation == gen && $0.stateSessionID == expectedSession }
    }

    private func watchedPullIsCurrent(
        expectedSession: TraktSessionID, gen: Int, purpose: TraktWatchedReadPurpose
    ) -> Bool {
        guard Self.watchedPurposeIsCurrent(purpose) else { return false }
        return cache.withLock { state in
            state.generation == gen && state.stateSessionID == expectedSession
                && TraktAuth.storedSessionID == expectedSession
        }
    }

    /// Keep the existing guarded bearer transport, endpoint, timeout, redirect policy and 8 MiB
    /// streamed response cap. Only constant reader-owned paths/queries are passed to this method.
    private func watchedData(
        path: String, expectedSession: TraktSessionID, gen: Int, purpose: TraktWatchedReadPurpose
    ) async throws -> Data {
        guard watchedPullIsCurrent(expectedSession: expectedSession, gen: gen, purpose: purpose) else {
            throw CancellationError()
        }
        let token = try await TraktAuth.shared.validToken(for: expectedSession)
        guard watchedPullIsCurrent(expectedSession: expectedSession, gen: gen, purpose: purpose),
              let url = URL(string: TraktAuth.apiBase + path) else { throw CancellationError() }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(TraktAuth.clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await AuthenticatedHTTPTransport.shared.send(
            request,
            allowedHosts: ["api.trakt.tv"],
            maxResponseBytes: AuthenticatedHTTPTransport.snapshotResponseLimit
        )
        guard watchedPullIsCurrent(expectedSession: expectedSession, gen: gen, purpose: purpose) else {
            throw CancellationError()
        }
        guard response.statusCode == 200 else { throw AuthenticatedHTTPTransportError.invalidResponse }
        return response.data
    }

    // MARK: - Retry queue (offline pushes)

    /// A push that must survive an offline stretch: watchlist add/remove, a watched record, or a rating
    /// set/clear. Only the title-level identity is stored, so a replay is idempotent enough for Trakt.
    ///
    /// `rating` / `ratedAtEpoch` are Optionals and carry the ratings payload only. Optionals decode as nil
    /// when the key is absent, so a queue file written before ratings existed still decodes. Envelope
    /// admission isolates unknown rows before decoding this executable projection; those rows remain
    /// raw in same-session storage rather than being discarded or interpreted as new actions.
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
        cache.withLock { state in
            guard state.stateSessionID == sessionID,
                  TraktAuth.storedSessionID == sessionID else { return }
            if push.isRating {
                state.pendingPushes.removeAll { $0.isRating && $0.sameTitle(as: push) }
                state.pendingPushes.append(push)
                if state.pendingPushes.count > Self.queueCap { state.pendingPushes.removeFirst(state.pendingPushes.count - Self.queueCap) }
            } else if !state.pendingPushes.contains(push) {
                state.pendingPushes.append(push)
                if state.pendingPushes.count > Self.queueCap { state.pendingPushes.removeFirst(state.pendingPushes.count - Self.queueCap) }
            }
            Self.persistLocked(state)
        }
    }

    /// Re-attempt every queued push; keep the ones that still fail. Runs inside `refreshIfStale`.
    private func drainQueue(expectedSession: TraktSessionID, gen: Int) async {
        let capturedQueue: [PendingPush]? = cache.withLock { state in
            guard state.generation == gen,
                  state.stateSessionID == expectedSession,
                  TraktAuth.storedSessionID == expectedSession else { return nil }
            return state.pendingPushes
        }
        guard let queue = capturedQueue, !queue.isEmpty else { return }
        var stillFailing: [PendingPush] = []
        for push in queue {
            if await send(push, expectedSession: expectedSession) == false { stillFailing.append(push) }
        }
        let failedSnapshot = stillFailing
        cache.withLock { state in
            // A disconnect/reset while we were sending bumps generation and wipes the queue. Writing our
            // pre-reset survivors back here would resurrect the wiped queue and let a push drain into the
            // NEXT account that signs in on this device (the cross-account contamination reset() prevents).
            // Drop the stale result; the live (empty) queue stands.
            guard state.generation == gen,
                  state.stateSessionID == expectedSession,
                  TraktAuth.storedSessionID == expectedSession else { return }
            // Merge, do not overwrite: enqueue() may have appended pushes while our sends were awaiting
            // (a watched-mark made mid-drain). Overwriting pendingPushes with stillFailing alone would
            // silently drop those for a still-connected provider. Keep the survivors, then append anything
            // added since the drained snapshot, deduped and capped as enqueue() does.
            let appendedDuringDrain = state.pendingPushes.filter { !queue.contains($0) }
            var merged = failedSnapshot
            for push in appendedDuringDrain where !merged.contains(push) { merged.append(push) }
            if merged.count > Self.queueCap { merged.removeFirst(merged.count - Self.queueCap) }
            state.pendingPushes = merged
            Self.persistLocked(state)
        }
    }

    /// Send one queued push through `TraktService`. Returns true on success (or when the push carries no
    /// usable id, so it is dropped rather than retried forever).
    private func send(_ push: PendingPush, expectedSession: TraktSessionID) async -> Bool {
        // A legacy, signed-out, or old-account row is terminally dropped. Retrying it later could only
        // move one account's media state through another account's credentials.
        guard let sessionID = push.sessionID,
              sessionID == expectedSession,
              TraktAuth.storedSessionID == sessionID else { return true }
        // Disk admission already quarantines these. This extra fence also prevents an unusable
        // in-memory caller value from becoming a different action or a successful no-send deletion.
        guard Self.usablePendingAction(push) else { return false }
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
                guard let rating = push.rating else { return false }
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

    private struct LoadedSnapshot {
        let snapshot: PersistedSnapshot?
        let retention: TraktSyncSnapshotEnvelope?
        let blocked: Bool
    }
    private static func load(for sessionID: TraktSessionID) -> LoadedSnapshot {
        let empty = LoadedSnapshot(snapshot: nil, retention: nil, blocked: false)
        let blocked = LoadedSnapshot(snapshot: nil, retention: nil, blocked: true)
        guard let storage else { return empty }
        let data: Data
        do {
            guard let stored = try storage.load() else { return empty }
            data = stored
        } catch {
            return blocked
        }
        do {
            let prepared = try TraktSyncSnapshotEnvelope.prepare(data, expectedSession: sessionID) { row in
                Self.pendingRowKey(row, expectedSession: sessionID)
            }
            let snapshot = try JSONDecoder().decode(PersistedSnapshot.self, from: prepared.owned)
            guard snapshot.sessionID == sessionID,
                  snapshot.watchedEpisodeKeys.count <= episodeKeyCap,
                  snapshot.watchedIDs.count <= TraktWatchedSnapshotReader.Limits().rows * 3 else { return blocked }
            if let entries = snapshot.watchedShowInventory {
                guard entries.count <= TraktWatchedSnapshotReader.Limits().rows,
                      Set(entries.map(\.traktID)).count == entries.count else { return blocked }
            }
            return LoadedSnapshot(snapshot: snapshot, retention: prepared.retention, blocked: false)
        } catch TraktSyncSnapshotEnvelope.Failure.wrongSession {
            // Established foreign owner: keep the existing account-boundary reset behavior.
            try? storage.reset()
            return empty
        } catch {
            // Unknown/malformed/over-budget same-file state cannot be retained safely. Do not turn
            // that into permission to erase it or overwrite it with a lossy projection.
            return blocked
        }
    }

    private static func pendingRowKey(_ row: Data, expectedSession: TraktSessionID) -> Data? {
        guard let push = try? JSONDecoder().decode(PendingPush.self, from: row),
              push.sessionID == expectedSession, usablePendingAction(push) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(push)
    }

    /// Codable is only a shape check, not permission to execute a queued action. Unusable source
    /// rows are kept byte-for-byte by the envelope's opaque lane; they never enter pendingPushes.
    private static func usablePendingAction(_ push: PendingPush) -> Bool {
        let imdb = push.imdb ?? ""
        if !imdb.isEmpty {
            guard imdb.utf8.count <= 32, imdb.hasPrefix("tt"), imdb.utf8.count > 2,
                  imdb.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        }
        if let tmdb = push.tmdb, tmdb <= 0 { return false }
        guard !imdb.isEmpty || push.tmdb != nil else { return false }
        if let stamp = push.ratedAtEpoch, !stamp.isFinite { return false }
        switch push.kind {
        case .watched:
            // Actual recordWatched/scrobbleItem callers require episode coordinates for a show.
            // A whole-show watched row must never fall through to a movie with the same numeric id.
            if push.isSeries {
                guard let season = push.season, let episode = push.episode,
                      season >= 0, episode >= 0 else { return false }
            }
            return push.rating == nil && push.ratedAtEpoch == nil
        case .watchlistAdd, .watchlistRemove:
            // Actual watchlist callers queue title-level intent but may copy episode coordinates.
            return push.rating == nil && push.ratedAtEpoch == nil
        case .ratingSet:
            guard let rating = push.rating, (1...10).contains(rating) else { return false }
            return push.season == nil && push.episode == nil
        case .ratingRemove:
            return push.rating == nil && push.season == nil && push.episode == nil
        }
    }

    /// Called only with the checked cache lock held, so no stale save can overtake a boundary reset.
    private static func persistLocked(_ state: State) {
        guard !state.snapshotPersistenceBlocked else { return }
        guard let storage = Self.storage, let stateSessionID = state.stateSessionID else {
            try? Self.storage?.reset()
            return
        }
        let snapshot = PersistedSnapshot(
            sessionID: stateSessionID,
            watchedIDs: Array(state.watchedIDs),
            watchedEpisodeKeys: Array(state.watchedEpisodeKeys),
            pendingPushes: state.pendingPushes.filter { $0.sessionID == stateSessionID },
            lastActivityFingerprint: state.lastActivityFingerprint,
            watchedReadVersion: state.watchedReadVersion,
            watchedShowInventory: state.watchedShowInventory,
            watchedInventoryRevision: state.watchedInventoryRevision
        )
        guard let data = persistedDataLocked(snapshot, state: state) else { return }
        try? storage.save(data)
    }

    private static func persistedDataLocked(_ snapshot: PersistedSnapshot, state: State) -> Data? {
        guard !state.snapshotPersistenceBlocked, let stateSessionID = state.stateSessionID,
              snapshot.sessionID == stateSessionID,
              TraktAuth.storedSessionID == stateSessionID else { return nil }
        guard let owned = try? JSONEncoder().encode(snapshot),
              owned.count <= TraktSyncSnapshotEnvelope.maximumBytes else { return nil }
        let data: Data
        if let snapshotRetention = state.snapshotRetention {
            guard let retained = try? snapshotRetention.merging(owned, expectedSession: stateSessionID, knownRowKey: {
                Self.pendingRowKey($0, expectedSession: stateSessionID)
            }) else { return nil }
            data = retained
        } else {
            data = owned
        }
        return data
    }
}
