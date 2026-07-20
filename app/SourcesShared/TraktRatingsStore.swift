import Foundation

/// The user's 1...10 title ratings: a LOCAL shadow store (Application Support JSON) that the app reads
/// from, mirrored out to Trakt over `POST /sync/ratings` and converged with `GET /sync/ratings/{type}`.
///
/// # Why local-first, and why that is not a second authority
///
/// VortX has no native rating store yet, so there is nothing on the VortX side for Trakt to contradict:
/// this shadow IS the VortX side, and it is the app's ONLY read source. Every badge, every "Your rating"
/// chip reads `rating(imdb:tmdb:)` here and never a Trakt response. That keeps three properties:
///   - the feature works offline and with Trakt disconnected (the value is on disk, not on a server);
///   - Trakt is a MIRROR WIRE, never consulted to answer "what did the user rate?";
///   - when the VortX backend gains ratings, this store's contents migrate into it and the merge below
///     is the only code that has to change, because nothing else ever reads Trakt directly.
///
/// # The merge rules (the ONLY place Trakt may change local state)
///
/// A read-back row is allowed to touch a local entry ONLY when all of these hold. Read them as a whole;
/// each one exists to close a specific way a two-authority sync corrupts a user's data:
///
///  1. **Absence never deletes.** A title missing from Trakt's response changes NOTHING. Reading "not in
///     the remote list" as "the user cleared it" is the exact shape that loses data when a response is
///     partial, paginated, rate-limited, or from a half-migrated account. There is no code path here that
///     removes an entry because Trakt did not mention it.
///  2. **A failed or empty pull is not evidence.** `pullRatings` only calls `merge` on a decoded 200. An
///     error, a timeout, or an empty array leaves the store untouched.
///  3. **An unpushed local edit is immune.** While `pushed == false` the user's VortX-side rating has not
///     reached Trakt yet, so anything Trakt says about that title is by definition older than what the
///     user just did here. Local wins; the queued push then converges Trakt to it.
///  4. **Otherwise, strictly-newer wins.** For an entry already mirrored (`pushed == true`), a Trakt row
///     whose `rated_at` is strictly newer is adopted. That is not Trakt overruling VortX; it is the same
///     user's own later action on the mirror (rating from trakt.tv or another client), and adopting it is
///     how the two converge. Equal timestamps change nothing, so a re-pull can never flap.
///
/// A cleared rating is a TOMBSTONE (`rating == nil`), not a deletion, so rule 4 can compare against it.
/// Dropping the row instead would let the next pull happily re-insert the rating the user just cleared.
///
/// # Threading
///
/// `final class` + `NSLock` + a change notification, matching `TraktSyncEngine`: the read is synchronous
/// so a SwiftUI body can call it inline, and the offline-drain callback can run off the main thread.
/// Fully fail-soft: every network path is `try?`-shaped and a failure only ever leaves the local value.
final class TraktRatingsStore {
    static let shared = TraktRatingsStore()

    /// Posted when the shadow changes (a user rating, or an adopted read-back row) so every mounted
    /// rating control refreshes. Each control keeps its own `@State`, like the Trakt rails do.
    static let changedNote = Notification.Name("vortx.trakt.ratings.changed")

    /// Valid Trakt rating range. A value outside this is refused rather than clamped: a clamp would
    /// silently record a rating the user did not choose.
    static let validRange = 1...10

    /// Bound the file. Only PUSHED TOMBSTONES are ever pruned (oldest first): a real rating is the user's
    /// own data and is never auto-dropped, and an unpushed entry still owes Trakt a write.
    private static let entryCap = 5_000

    private let lock = NSLock()
    /// Entries by an opaque, stable primary key. The key never changes once assigned (a later read-back
    /// may enrich an entry's ids, but re-keying would orphan it), so all lookup goes through `aliases`.
    private var entries: [String: RatingEntry]
    /// Every id form an entry can be found by ("tt123…", "tmdb:456") -> its primary key. Rebuilt on any
    /// mutation. Lets a title rated under a `tmdb:` catalog id still resolve once its tt id is known.
    private var aliases: [String: String] = [:]
    /// Bumped by `reset()`. An in-flight pull/push captures it before its awaits and refuses to write back
    /// if it changed, so a disconnect can never resurrect the wiped store into the next account.
    private var generation = 0

    private init() {
        entries = Self.load()
        rebuildAliases()
    }

    /// One rated title. `rating == nil` is a tombstone: the user explicitly cleared their rating, which is
    /// a real state that must outlive a Trakt pull (see rule 1), not an absence.
    struct RatingEntry: Codable, Sendable, Equatable {
        var imdb: String?
        var tmdb: Int?
        var isSeries: Bool
        /// 1...10, or nil for "explicitly unrated" (tombstone).
        var rating: Int?
        /// When the user set (or cleared) this, in whichever client. The merge's newer-wins comparison key.
        var ratedAt: Date
        /// False while this edit still owes Trakt a write. An unpushed entry is immune to read-back.
        var pushed: Bool
    }

    // MARK: - Read side (the app's ONLY rating source)

    /// The user's rating for a title, or nil when unrated / tombstoned / not known. Synchronous and
    /// lock-guarded so a detail-page body can read it inline. Never touches the network.
    func rating(imdb: String?, tmdb: Int?) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let key = primaryKeyLocked(imdb: imdb, tmdb: tmdb) else { return nil }
        return entries[key]?.rating
    }

    // MARK: - Write side (user action)

    /// Record the user's rating locally, then mirror it to Trakt. The local write lands FIRST and
    /// unconditionally, so the badge is instant and a rating made offline (or with Trakt disconnected) is
    /// never lost. Out-of-range values are refused.
    func setRating(_ rating: Int, imdb: String?, tmdb: Int?, isSeries: Bool) {
        guard Self.validRange.contains(rating) else { return }
        write(rating: rating, imdb: imdb, tmdb: tmdb, isSeries: isSeries)
    }

    /// Clear the user's rating: writes a TOMBSTONE locally (not a delete) and mirrors the removal.
    func clearRating(imdb: String?, tmdb: Int?, isSeries: Bool) {
        write(rating: nil, imdb: imdb, tmdb: tmdb, isSeries: isSeries)
    }

    /// Shared local-write + mirror path for both set and clear.
    private func write(rating: Int?, imdb: String?, tmdb: Int?, isSeries: Bool) {
        let cleanIMDb = (imdb?.isEmpty == false) ? imdb : nil
        guard cleanIMDb != nil || tmdb != nil else { return }   // no usable identity: nothing to key on
        lock.lock()
        // Re-file an existing entry under its ORIGINAL key (a title first rated under a `tmdb:` id keeps
        // that key even once its tt id is known); only a title we have never seen mints a new one.
        guard let key = primaryKeyLocked(imdb: cleanIMDb, tmdb: tmdb)
                ?? Self.makeKey(imdb: cleanIMDb, tmdb: tmdb) else { lock.unlock(); return }
        // UNION this page's ids with the ones the entry already carries; never store this call's ids
        // wholesale. A detail page only knows the ids ITS catalog carries, and a tmdb-keyed page has no tt
        // id at all until its meta loads, so a re-rate from there would otherwise DROP an imdb id the entry
        // already had. That id is what the alias index finds the entry by, so the rating would stop
        // resolving on any imdb-keyed page: the user's own score silently reads as unrated, and rating it
        // again there would mint a SECOND entry for one title. Ids only ever accumulate, exactly as
        // `merge`'s enrichment does; a value is replaced, an identity never is.
        let known = entries[key]
        let entry = RatingEntry(imdb: cleanIMDb ?? known?.imdb, tmdb: tmdb ?? known?.tmdb,
                                isSeries: isSeries, rating: rating, ratedAt: Date(), pushed: false)
        entries[key] = entry
        rebuildAliasesLocked()
        pruneLocked()
        let snapshot = entries
        let gen = generation
        lock.unlock()
        Self.save(snapshot)
        notifyChanged()
        mirror(entry, gen: gen)
    }

    /// Push one entry to Trakt. Gated on the ratings toggle + a configured, connected account; when the
    /// gate is closed the local value simply stands (and is NOT queued: a push the user never asked to
    /// mirror must not fire the moment they connect an account later).
    private func mirror(_ entry: RatingEntry, gen: Int) {
        guard TraktAuth.isConfigured,
              ExternalSyncToggle.isOn(ExternalSyncToggle.traktRatings) else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self, await TraktAuth.shared.isSignedIn else { return }
            let ids = TraktIDs(imdb: entry.imdb, tmdb: entry.tmdb)
            do {
                if let rating = entry.rating {
                    let stamp = TraktRatedAt.string(from: entry.ratedAt)
                    let items = entry.isSeries
                        ? TraktRatingItems(shows: [TraktRatedShow(ids: ids, rating: rating, ratedAt: stamp)])
                        : TraktRatingItems(movies: [TraktRatedMovie(ids: ids, rating: rating, ratedAt: stamp)])
                    _ = try await TraktService.shared.addRatings(items)
                } else {
                    let items = entry.isSeries
                        ? TraktRatingItems(shows: [TraktRatedShow(ids: ids)])
                        : TraktRatingItems(movies: [TraktRatedMovie(ids: ids)])
                    _ = try await TraktService.shared.removeRatings(items)
                }
                self.markPushed(entry, gen: gen)
            } catch {
                // Queue only TRANSIENT failures, mirroring TraktProvider.enqueueIfTransient: a 401 needs a
                // reconnect (a blind replay would 401 forever, and could drain into the next account), and
                // .ignored cannot arise on a ratings write. The local value stands either way.
                if let e = error as? TraktServiceError, e == .unauthorized || e == .ignored { return }
                TraktSyncEngine.shared.enqueue(TraktSyncEngine.PendingPush(
                    kind: entry.rating == nil ? .ratingRemove : .ratingSet,
                    isSeries: entry.isSeries, imdb: entry.imdb, tmdb: entry.tmdb,
                    season: nil, episode: nil,
                    rating: entry.rating, ratedAtEpoch: entry.ratedAt.timeIntervalSince1970))
            }
        }
    }

    // MARK: - Push bookkeeping (called by the offline drain too)

    /// Flip an entry to `pushed` once Trakt has it. Matches on the EXACT value+timestamp that was pushed:
    /// a rating the user changed while the push was in flight (or queued) is a different, still-unpushed
    /// edit, and clearing its pending flag would strip its rule-3 immunity and let a stale read-back row
    /// overwrite the newer value.
    func markPushed(_ pushed: RatingEntry, gen: Int? = nil) {
        lock.lock()
        if let gen, gen != generation { lock.unlock(); return }
        guard let key = primaryKeyLocked(imdb: pushed.imdb, tmdb: pushed.tmdb),
              var current = entries[key],
              current.rating == pushed.rating,
              // Dates round-trip through epoch seconds in the push queue, so compare at that resolution
              // rather than requiring bit-equal Date values.
              Int(current.ratedAt.timeIntervalSince1970) == Int(pushed.ratedAt.timeIntervalSince1970)
        else { lock.unlock(); return }
        guard !current.pushed else { lock.unlock(); return }
        current.pushed = true
        entries[key] = current
        let snapshot = entries
        lock.unlock()
        Self.save(snapshot)
    }

    /// Drain-side twin of `markPushed`, taking the queue's flat fields.
    func markPushed(imdb: String?, tmdb: Int?, isSeries: Bool, rating: Int?, ratedAtEpoch: Double?) {
        guard let epoch = ratedAtEpoch else { return }
        markPushed(RatingEntry(imdb: imdb, tmdb: tmdb, isSeries: isSeries, rating: rating,
                               ratedAt: Date(timeIntervalSince1970: epoch), pushed: true))
    }

    // MARK: - Read-back (convergence, NOT authority)

    /// Fold Trakt's rows into the shadow under the four rules in the type comment. Returns true when
    /// anything actually changed (so the caller can notify the UI). Callers MUST NOT call this with a
    /// partial or failed fetch: only a fully decoded 200 is evidence (rule 2).
    @discardableResult
    func merge(entries rows: [TraktRatingEntry], isSeries: Bool, gen: Int) -> Bool {
        guard !rows.isEmpty else { return false }
        lock.lock()
        guard generation == gen else { lock.unlock(); return false }
        // Two flags, deliberately: `valueChanged` is what the USER would see (a rating appeared or moved)
        // and drives the repaint; `dirty` is anything that must reach the alias index and disk, INCLUDING a
        // pure id enrichment that changes no value. Collapsing them would let an enrichment mutate `entries`
        // while `aliases` and the file kept the old shape, so the newly-learned id would not resolve until
        // some later write happened to rebuild them, and would be lost entirely on relaunch.
        var valueChanged = false
        var dirty = false
        for row in rows {
            let container = isSeries ? row.show?.ids : row.movie?.ids
            guard let ids = container else { continue }
            let imdb = (ids.imdb?.isEmpty == false) ? ids.imdb : nil
            let tmdb = ids.tmdb
            guard imdb != nil || tmdb != nil else { continue }
            // A row whose rated_at will not parse gets no timestamp, so it can never win rule 4 against a
            // known local entry. It may still FILL a title we have never seen (that is not a conflict).
            let remoteAt = row.ratedAt.flatMap(TraktRatedAt.date(from:))
            guard Self.validRange.contains(row.rating) else { continue }

            guard let key = primaryKeyLocked(imdb: imdb, tmdb: tmdb) else {
                // Rule 4 (fill): a title the shadow has never heard of. Insert it as already-pushed;
                // it came FROM Trakt, so it owes Trakt nothing.
                guard let newKey = Self.makeKey(imdb: imdb, tmdb: tmdb) else { continue }
                entries[newKey] = RatingEntry(imdb: imdb, tmdb: tmdb, isSeries: isSeries,
                                              rating: row.rating, ratedAt: remoteAt ?? Date(), pushed: true)
                valueChanged = true
                dirty = true
                continue
            }
            guard var local = entries[key] else { continue }
            // Enrich ids either way: learning a title's tt id from Trakt is not a value change, it just
            // makes the entry findable from a tt-keyed page later. Dirty (it must be indexed + saved), but
            // never a repaint on its own.
            if local.imdb == nil, let imdb { local.imdb = imdb; entries[key] = local; dirty = true }
            if local.tmdb == nil, let tmdb { local.tmdb = tmdb; entries[key] = local; dirty = true }

            // Rule 3: an unpushed local edit is immune. Trakt cannot know about it yet by construction.
            guard local.pushed else { continue }
            // Rule 4: adopt ONLY on a strictly newer remote stamp. Equal or older changes nothing, so a
            // routine re-pull is idempotent and can never flap a value back and forth.
            guard let remoteAt, remoteAt > local.ratedAt else { continue }
            guard local.rating != row.rating else { continue }
            local.rating = row.rating
            local.ratedAt = remoteAt
            local.pushed = true
            entries[key] = local
            valueChanged = true
            dirty = true
        }
        // Rule 1 is enforced by absence of code: nothing above removes an entry for not being in `rows`.
        guard dirty else { lock.unlock(); return false }
        rebuildAliasesLocked()
        pruneLocked()
        let snapshot = entries
        lock.unlock()
        Self.save(snapshot)
        return valueChanged
    }

    /// The generation an in-flight pull must present to `merge`, so a disconnect mid-pull discards it.
    var currentGeneration: Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    // MARK: - Disconnect

    /// Wipe the shadow (memory + disk) on disconnect / sign-out, so ratings do not leak into the next
    /// account that connects on this device, and invalidate any in-flight pull or push.
    func reset() {
        lock.lock()
        entries = [:]
        aliases = [:]
        generation &+= 1
        lock.unlock()
        Self.save([:])
        notifyChanged()
    }

    // MARK: - Keys + aliases

    /// The primary key an id pair resolves to, via the alias index. IMDb is tried first so a title known
    /// by both ids resolves deterministically.
    private func primaryKeyLocked(imdb: String?, tmdb: Int?) -> String? {
        if let imdb, !imdb.isEmpty, let key = aliases[imdb] { return key }
        if let tmdb, let key = aliases["tmdb:\(tmdb)"] { return key }
        return nil
    }

    /// The key a NEW entry is filed under. Opaque and stable for the entry's life.
    private static func makeKey(imdb: String?, tmdb: Int?) -> String? {
        if let imdb, !imdb.isEmpty { return imdb }
        if let tmdb { return "tmdb:\(tmdb)" }
        return nil
    }

    private func rebuildAliases() { lock.lock(); rebuildAliasesLocked(); lock.unlock() }

    private func rebuildAliasesLocked() {
        var next: [String: String] = [:]
        // TWO entries can legitimately claim ONE alias. Rating a title from a tmdb-keyed catalog before its
        // meta resolves an tt id makes a `tmdb:` entry; rating the same title from an imdb-keyed catalog
        // makes a `tt` one; a later read-back then enriches the tt entry with that same tmdb id, and both
        // now claim "tmdb:456". Dictionary iteration order is unspecified and varies between launches, so
        // last-writer-wins here would let the chip show one score today and the other tomorrow. Resolve it
        // the way `merge` resolves every other conflict: the NEWER edit wins.
        func claim(_ alias: String, _ key: String) {
            guard let held = next[alias] else { next[alias] = key; return }
            guard let candidate = entries[key], let incumbent = entries[held] else { return }
            // The key breaks an exact timestamp tie, so the result never depends on iteration order.
            if (candidate.ratedAt, key) > (incumbent.ratedAt, held) { next[alias] = key }
        }
        for (key, entry) in entries {
            if let imdb = entry.imdb, !imdb.isEmpty { claim(imdb, key) }
            if let tmdb = entry.tmdb { claim("tmdb:\(tmdb)", key) }
        }
        aliases = next
    }

    /// Keep the file bounded by dropping the OLDEST PUSHED TOMBSTONES only. A real rating is never
    /// auto-dropped (that would be silent data loss), and an unpushed entry still owes Trakt a write.
    private func pruneLocked() {
        guard entries.count > Self.entryCap else { return }
        let droppable = entries
            .filter { $0.value.rating == nil && $0.value.pushed }
            .sorted { $0.value.ratedAt < $1.value.ratedAt }
        for (key, _) in droppable.prefix(entries.count - Self.entryCap) { entries.removeValue(forKey: key) }
        rebuildAliasesLocked()
    }

    private func notifyChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changedNote, object: nil) }
    }

    // MARK: - Persistence (Application Support JSON)

    private static let file = "trakt-ratings-shadow.json"

    private static func fileURL() -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(file)
    }

    private static func load() -> [String: RatingEntry] {
        guard let url = fileURL(), let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: RatingEntry].self, from: data) else { return [:] }
        return decoded
    }

    private static func save(_ entries: [String: RatingEntry]) {
        guard let url = fileURL(), let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
