import Foundation

/// The user's 1...10 SIMKL title ratings: a LOCAL shadow store (Application Support JSON) the app reads from,
/// mirrored out to SIMKL over `POST /sync/ratings` and converged with the `POST /sync/ratings/{type}` read-back.
///
/// The SIMKL peer of `TraktRatingsStore`, deliberately the same shape: local-first (so a badge is instant and a
/// rating made offline / with SIMKL disconnected is never lost), SIMKL is a MIRROR WIRE never consulted to
/// answer "what did the user rate?", and every fold rule lives in the pure `SIMKLRatingsCore` (see there). This
/// type owns only the impure edges: `NSLock`, persistence, the change notification, the network mirror, and a
/// generation guard so a disconnect mid-flight can never resurrect the wiped store into the next account.
///
/// Two honest differences from the Trakt store, both rooted in SIMKL's surface, not a shortcut:
///   - No `TraktSyncEngine` exists for SIMKL, so convergence runs here: a throttled `refreshIfStale()`
///     (5-minute gate, like `SIMKLWatchedShadow` / `SIMKLRailsModel`) that DRAINS any unpushed edits then PULLS
///     the read-back. The persisted unpushed entries ARE the durable queue, so there is no separate queue file
///     (matching the rest of the SIMKL write side, which carries no offline push queue).
///   - SIMKL rates whole titles only, so this is movie / show level throughout (anime rides the `shows` array).
final class SIMKLRatingsStore {
    static let shared = SIMKLRatingsStore()

    /// Posted when the shadow changes (a user rating, or an adopted read-back row) so every mounted SIMKL
    /// rating control refreshes. Mirrors `TraktRatingsStore.changedNote`.
    static let changedNote = Notification.Name("vortx.simkl.ratings.changed")

    static let validRange = SIMKLRatingsCore.validRange

    /// Minimum gap between read-back / drain refreshes, matching `SIMKLWatchedShadow`.
    private static let refreshInterval: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var core: SIMKLRatingsCore
    /// Bumped by `reset()`. An in-flight pull/push captures it before its awaits and refuses to write back if it
    /// changed, so a disconnect can never resurrect the wiped store into the next account.
    private var generation = 0
    private var lastRefresh: Date?
    private var refreshing = false

    private init() {
        core = SIMKLRatingsCore(entries: Self.load())
    }

    // MARK: - Read side (the app's ONLY SIMKL-rating source)

    /// The user's SIMKL rating for a title, or nil. Synchronous + lock-guarded so a detail-page body can read
    /// it inline. Never touches the network.
    func rating(imdb: String?, tmdb: Int?) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return core.rating(imdb: imdb, tmdb: tmdb)
    }

    // MARK: - Write side (user action)

    /// Record the user's rating locally (FIRST, unconditionally) then mirror it to SIMKL. Out-of-range refused.
    func setRating(_ rating: Int, imdb: String?, tmdb: Int?, isSeries: Bool) {
        guard Self.validRange.contains(rating) else { return }
        write(rating: rating, imdb: imdb, tmdb: tmdb, isSeries: isSeries)
    }

    /// Clear the user's rating: a TOMBSTONE locally (not a delete), mirrored as a removal.
    func clearRating(imdb: String?, tmdb: Int?, isSeries: Bool) {
        write(rating: nil, imdb: imdb, tmdb: tmdb, isSeries: isSeries)
    }

    private func write(rating: Int?, imdb: String?, tmdb: Int?, isSeries: Bool) {
        lock.lock()
        guard let entry = core.write(rating: rating, imdb: imdb, tmdb: tmdb, isSeries: isSeries) else {
            lock.unlock(); return
        }
        let snapshot = core.entries
        let gen = generation
        lock.unlock()
        Self.save(snapshot)
        notifyChanged()
        mirror(entry, gen: gen)
    }

    // MARK: - Mirror (push one entry to SIMKL)

    /// Push one entry to SIMKL. Gated on the ratings toggle + a configured account; when the gate is closed the
    /// local value simply stands (and is not force-pushed the moment an account connects later). On success the
    /// entry is flipped to `pushed`; a failure leaves it unpushed, so the next `refreshIfStale` drain retries it
    /// (the unpushed entry is the durable queue). Fully fail-soft.
    private func mirror(_ entry: SIMKLRatingsCore.RatingEntry, gen: Int) {
        guard SIMKLAuth.isConfigured,
              ExternalSyncToggle.isOn(ExternalSyncToggle.simklRatings) else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self, await SIMKLAuth.shared.isSignedIn else { return }
            await self.push(entry, gen: gen)
        }
    }

    /// The actual SIMKL write for one entry (a set or a clear), flipping `pushed` on success. No-throw.
    private func push(_ entry: SIMKLRatingsCore.RatingEntry, gen: Int) async {
        let ids = SIMKLIDs(imdb: entry.imdb, tmdb: entry.tmdb)
        do {
            if let rating = entry.rating {
                let stamp = SIMKLRatedAt.string(from: entry.ratedAt)
                let items = entry.isSeries
                    ? SIMKLRatingItems(shows: [SIMKLRatedShow(ids: ids, rating: rating, ratedAt: stamp)])
                    : SIMKLRatingItems(movies: [SIMKLRatedMovie(ids: ids, rating: rating, ratedAt: stamp)])
                _ = try await SIMKLService.shared.addRatings(items)
            } else {
                let items = entry.isSeries
                    ? SIMKLRatingItems(shows: [SIMKLRatedShow(ids: ids)])
                    : SIMKLRatingItems(movies: [SIMKLRatedMovie(ids: ids)])
                _ = try await SIMKLService.shared.removeRatings(items)
            }
            markPushed(entry, gen: gen)
        } catch {
            // Leave the entry unpushed so the next drain retries it. Nothing else to do (no queue file).
        }
    }

    /// Flip an entry to `pushed` once SIMKL has it, under the generation guard.
    private func markPushed(_ entry: SIMKLRatingsCore.RatingEntry, gen: Int) {
        lock.lock()
        guard gen == generation, core.markPushed(entry) else { lock.unlock(); return }
        let snapshot = core.entries
        lock.unlock()
        Self.save(snapshot)
    }

    // MARK: - Convergence (throttled drain + read-back)

    /// Drain any unpushed edits, then pull the SIMKL read-back and fold it in, at most once per interval. A
    /// no-op when SIMKL is unconfigured, the ratings toggle is off, or not signed in. Called on detail-page
    /// appear (via the chip) and on connect; `refreshNow` forces it past the throttle when the user just turned
    /// the toggle on or just connected.
    func refreshIfStale() {
        guard SIMKLAuth.isConfigured,
              ExternalSyncToggle.isOn(ExternalSyncToggle.simklRatings) else { return }
        lock.lock()
        if refreshing { lock.unlock(); return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.refreshInterval { lock.unlock(); return }
        refreshing = true
        let gen = generation
        let unpushed = core.entries.values.filter { !$0.pushed }
        lock.unlock()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.refreshing = false
                // Only stamp when no disconnect happened mid-refresh, matching the other SIMKL refreshers.
                if self.generation == gen { self.lastRefresh = Date() }
                self.lock.unlock()
            }
            guard await SIMKLAuth.shared.isSignedIn else { return }
            for entry in unpushed { await self.push(entry, gen: gen) }
            await self.pull(gen: gen)
        }
    }

    /// Force an immediate convergence past the throttle (on connect / toggle-on). Mirrors the other refreshers.
    func refreshNow() {
        lock.lock()
        let inFlight = refreshing
        if !inFlight { lastRefresh = nil }
        lock.unlock()
        if !inFlight { refreshIfStale() }
    }

    /// Pull `POST /sync/ratings` and fold every row through the core. A failed / empty pull contributes nothing
    /// (rule 2): the read-back only reaches `merge` on a decoded 200.
    private func pull(gen: Int) async {
        guard let response = try? await SIMKLService.shared.ratings() else { return }
        let rows = SIMKLRatingsCore.remoteRatings(from: response)
        guard !rows.isEmpty else { return }
        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        let result = core.merge(rows)
        guard result.dirty else { lock.unlock(); return }
        let snapshot = core.entries
        lock.unlock()
        Self.save(snapshot)
        if result.valueChanged { notifyChanged() }
    }

    // MARK: - Disconnect

    /// Wipe the shadow (memory + disk) on disconnect / sign-out and invalidate any in-flight pull / push.
    func reset() {
        lock.lock()
        core.wipe()
        lastRefresh = nil
        generation &+= 1
        lock.unlock()
        Self.save([:])
        notifyChanged()
    }

    private func notifyChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changedNote, object: nil) }
    }

    // MARK: - Persistence (Application Support JSON)

    private static let file = "simkl-ratings-shadow.json"

    private static func fileURL() -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(file)
    }

    private static func load() -> [String: SIMKLRatingsCore.RatingEntry] {
        guard let url = fileURL(), let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: SIMKLRatingsCore.RatingEntry].self, from: data) else { return [:] }
        return decoded
    }

    private static func save(_ entries: [String: SIMKLRatingsCore.RatingEntry]) {
        guard let url = fileURL(), let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
