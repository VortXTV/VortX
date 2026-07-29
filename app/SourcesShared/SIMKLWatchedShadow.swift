import Foundation

/// Additive-READ SIMKL shadow: the SIMKL analog of `TraktSyncEngine`'s watched-history import. On refresh
/// (throttled) it pulls the user's COMPLETED movies / shows / anime from SIMKL into a LOCAL cache
/// (Application Support JSON) and exposes the watched id set (imdb `tt…` AND `tmdb:<id>` forms) so
/// `WatchedIndex` can UNION it into the read path behind the opt-in `simklImportWatched` toggle.
///
/// SIMKL was WRITE-MOSTLY before this: it pushed watched-on-finish + plan-to-watch and read back ONLY the
/// plan-to-watch rail, so a connected user's actual SIMKL WATCH HISTORY was invisible inside VortX. This is
/// that missing read side, and it is the SIMKL half of the "sync does not work all the way" report (the
/// Trakt half was #143 / the refreshNow throttle fix in `TraktSyncEngine`).
///
/// Deliberately SIMPLER than `TraktSyncEngine`: SIMKL has no live scrobble, no ratings, and this import
/// carries no offline push queue (the write side already owns pushes via `SIMKLProvider`). It also stays
/// TITLE-LEVEL: `completed` is a whole-title signal and `SIMKLService.list` returns title-level entries, so
/// there is no per-episode grain to harvest (see `SIMKLWatchedCore`). Every rule about WHAT the shadow knows
/// lives in that pure `SIMKLWatchedCore`; this type owns only the impure edges (network, persistence,
/// throttle, WatchedIndex notify).
///
/// HARD INVARIANT (libraryItem POISON): like the Trakt shadow, this NEVER writes an engine `libraryItem`.
/// The set lives only in this cache and is unioned into a read-only badge index, so a SIMKL pull can only
/// ever ADD a badge, never clear one VortX recorded. The VortX account stays the authority.
///
/// Token access goes through `SIMKLService` / `SIMKLAuth.isSignedIn` exactly as `SIMKLRailsModel` does;
/// this type never touches SIMKLAuth's credential / token storage (that surface is frozen).
///
/// Fully fail-soft: any pull error / offline / not-configured leaves the last cache intact and never
/// disturbs playback or the UI.
final class SIMKLWatchedShadow {
    static let shared = SIMKLWatchedShadow()

    /// Minimum gap between network refreshes; foreground + rail rebuilds call `refreshIfStale` freely.
    /// Matches the plan-to-watch rail's own interval, so a connected user does at most a few SIMKL GETs
    /// per interval across both features.
    private static let refreshInterval: TimeInterval = 5 * 60

    private let lock = NSLock()
    /// Pure state core (fold / replace / wipe / gate). Guarded by `lock`.
    private var core: SIMKLWatchedCore
    private var lastRefresh: Date?
    private var refreshing = false
    /// Set by `refreshNow()` when a force arrives while a refresh is already in flight, so the in-flight
    /// refresh honors it once on completion instead of the single-flight guard swallowing it. Guarded by
    /// `lock`. Same coalescing latch as `TraktSyncEngine.refreshAgain`.
    private var refreshAgain = false
    /// Bumped by `reset()` (disconnect / sign-out). An in-flight pull captures it before its network awaits
    /// and refuses to write back if it changed meanwhile, so a pull that started before a disconnect can
    /// never resurrect the wiped shadow into the next account.
    private var generation = 0
    private var stateSessionID: SIMKLSessionID?

    private struct PersistedSnapshot: Codable {
        let sessionID: SIMKLSessionID
        let watchedIDs: [String]
    }

    private static let storage = try? PrivateExternalSyncStorage.live(
        provider: "SIMKL",
        file: "watched.json",
        legacyFiles: ["simkl-shadow-watched.json"]
    )

    private init() {
        let initialSession = SIMKLAuth.storedSessionID
        stateSessionID = initialSession
        core = SIMKLWatchedCore(
            watchedIDs: initialSession.map { Set(Self.loadWatched(for: $0)) } ?? []
        )
        SIMKLAuthBoundary.observe(key: "simkl-watched-shadow") { [weak self] sessionID in
            self?.reset(to: sessionID)
        }
        let currentSession = SIMKLAuth.storedSessionID
        if currentSession != initialSession { reset(to: currentSession) }
    }

    // MARK: - Read side (WatchedIndex consumes this)

    /// The shadow watched id set (imdb + tmdb forms), or empty when the import toggle is off. Synchronous +
    /// lock-guarded so `WatchedIndex.rebuild` can union it inline. The opt-in gate lives in the core's
    /// `visibleIDs`, so a single call site in WatchedIndex stays clean.
    func shadowWatchedIDs() -> Set<String> {
        let on = ExternalSyncToggle.isOn(ExternalSyncToggle.simklImportWatched, default: false)
        guard let currentSession = SIMKLAuth.storedSessionID else { return [] }
        lock.lock(); defer { lock.unlock() }
        guard stateSessionID == currentSession,
              SIMKLAuth.storedSessionID == currentSession else { return [] }
        return core.visibleIDs(importOn: on)
    }

    // MARK: - Disconnect

    /// Wipe ALL local SIMKL shadow state (memory + disk) so the imported watched badges drop immediately on
    /// disconnect / sign-out and one account's SIMKL history can never badge covers for the NEXT account that
    /// connects on this device. The caller notifies `WatchedIndex` so the read path rebuilds.
    func reset() {
        reset(to: SIMKLAuth.storedSessionID)
    }

    private func reset(to sessionID: SIMKLSessionID?) {
        lock.lock()
        core.wipe()
        lastRefresh = nil
        stateSessionID = sessionID
        generation &+= 1   // invalidate any in-flight pull so it cannot write its pre-reset result back
        try? Self.storage?.reset()
        lock.unlock()
        DispatchQueue.main.async { WatchedIndex.shared.externalShadowChanged() }
    }

    // MARK: - Refresh (throttled) + force

    /// Pull the completed history, at most once per `refreshInterval`. A no-op when SIMKL is unconfigured or
    /// the import toggle is off. On a pull that changes the set it nudges `WatchedIndex` to rebuild so
    /// imported badges appear without waiting for an engine event.
    func refreshIfStale() {
        guard SIMKLAuth.isConfigured else { return }
        // Import is opt-in, and while the toggle is OFF this shadow has nothing else to do (no push queue,
        // no ratings, unlike Trakt). Gate the WHOLE refresh here, BEFORE the throttle stamp: nothing stamps
        // `lastRefresh` while import is off, so flipping it on is never deferred by a stamp armed during the
        // off period (the exact trap the Trakt refreshNow fix exists for, avoided at the root here).
        // `refreshNow` still exists for the flip-off-then-on-within-the-interval case (an earlier ON period's
        // stamp is still fresh) and to pull the instant the user asks rather than on the next rebuild tick.
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.simklImportWatched, default: false) else { return }
        guard let sessionID = SIMKLAuth.storedSessionID else { return }
        lock.lock()
        guard stateSessionID == sessionID,
              SIMKLAuth.storedSessionID == sessionID else { lock.unlock(); return }
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
                // Only stamp when no disconnect happened mid-refresh: a reset bumps generation and nulls
                // lastRefresh, and re-stamping here would make refreshIfStale early-return for up to
                // refreshInterval, delaying the reconnected account's first pull. Leaving it nil on a stale
                // generation lets the next call pull immediately.
                if self.generation == gen,
                   self.stateSessionID == sessionID,
                   SIMKLAuth.storedSessionID == sessionID {
                    self.lastRefresh = Date()
                }
                // A force (refreshNow) arrived mid-refresh and was swallowed by the single-flight guard; its
                // throttle clear was re-armed by the stamp above. Honor it now with one more pass.
                let force = self.refreshAgain
                self.refreshAgain = false
                self.lock.unlock()
                if force { self.refreshNow() }
            }
            guard SIMKLAuth.storedSessionID == sessionID else { return }
            await self.pullCompleted(expectedSession: sessionID, gen: gen)
        }
    }

    /// Force an immediate refresh, bypassing the `refreshInterval` throttle. Called when the user just
    /// turned import ON so the just-enabled SIMKL badges import immediately rather than on the next unrelated
    /// rebuild tick. If a refresh is already in flight, latch `refreshAgain` so it re-runs on completion
    /// instead of being lost to the single-flight guard. Still gated on config / sign-in / import-toggle
    /// downstream: this forces the SCHEDULE, never the gates.
    func refreshNow() {
        lock.lock()
        lastRefresh = nil
        let inFlight = refreshing
        if inFlight { refreshAgain = true }
        lock.unlock()
        if !inFlight { refreshIfStale() }
    }

    /// Pull `GET /sync/all-items/{movies,shows,anime}/completed` through `SIMKLService.list` and REPLACE the
    /// shadow with the folded identity set. Reads are not rate-gated (SIMKL's limit is on writes; see
    /// `SIMKLService`), and each leg is independent + fail-soft.
    private func pullCompleted(expectedSession: SIMKLSessionID, gen: Int) async {
        guard ExternalSyncToggle.isOn(ExternalSyncToggle.simklImportWatched, default: false) else { return }
        var next = Set<String>()
        var allOK = true
        // Three independent legs. A leg that throws contributes nothing AND blocks the commit below, because
        // a pull is a REPLACE: committing shows+anime while movies failed offline would silently drop every
        // movie badge until the next good pull. Requiring every leg to answer keeps the last good cache whole
        // on a partial failure (the same discipline `TraktSyncEngine`'s two-leg commit gate uses).
        for type in SIMKLListType.allCases {
            do {
                let entries = try await SIMKLService.shared.list(
                    type: type,
                    status: .completed,
                    expectedSession: expectedSession
                )
                for id in SIMKLWatchedCore.identities(from: entries) { next.insert(id) }
            } catch {
                allOK = false
            }
        }
        // Commit whenever every leg answered. An empty `next` is a truthful empty account result and must
        // replace a populated cache, otherwise removed history remains visible forever.
        guard allOK else { return }
        lock.lock()
        // A disconnect while this pull was in flight wiped the set and bumped generation; do NOT write the
        // pre-reset result back, or the imported badges would resurrect after the user disconnected.
        guard generation == gen,
              stateSessionID == expectedSession,
              SIMKLAuth.storedSessionID == expectedSession else { lock.unlock(); return }
        let changed = core.replace(with: next)
        if changed { persistLocked() }
        lock.unlock()
        if changed {
            await MainActor.run { WatchedIndex.shared.externalShadowChanged() }
        }
    }

    // MARK: - Protected persistence

    private static func loadWatched(for sessionID: SIMKLSessionID) -> [String] {
        guard let storage else { return [] }
        let data: Data
        do {
            guard let stored = try storage.load() else { return [] }
            data = stored
        } catch {
            try? storage.reset()
            return []
        }
        guard let snapshot = try? JSONDecoder().decode(PersistedSnapshot.self, from: data),
              snapshot.sessionID == sessionID else {
            try? storage.reset()
            return []
        }
        return snapshot.watchedIDs
    }

    private func persistLocked() {
        guard let storage = Self.storage, let stateSessionID else {
            try? Self.storage?.reset()
            return
        }
        let snapshot = PersistedSnapshot(
            sessionID: stateSessionID,
            watchedIDs: Array(core.watchedIDs)
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? storage.save(data)
    }
}
