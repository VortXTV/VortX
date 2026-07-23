import Foundation

/// Pure, Foundation-only state core for the SIMKL title-ratings shadow (see `SIMKLRatingsStore`).
///
/// The SIMKL peer of `TraktRatingsStore`, and extracted for the same reason `SIMKLWatchedCore` was: the impure
/// `SIMKLRatingsStore` pulls in `SIMKLService` / `SIMKLAuth` and cannot link standalone, so every rule about
/// WHAT a rating row may change lives here where a self-contained test exercises it. `SIMKLRatingsStore` holds
/// ONE of these under its lock and owns only the impure edges (network mirror, persistence, generation, the
/// change notification).
///
/// # The merge rules (the four that keep a two-authority sync from corrupting the user's data)
///
/// These are `TraktRatingsStore`'s rules, ported verbatim, because SIMKL's read-back has the same hazards (a
/// partial / rate-limited / half-migrated response, an offline edit, a re-pull that must be idempotent):
///
///  1. **Absence never deletes.** A title missing from SIMKL's response changes NOTHING. There is no code path
///     that removes an entry because SIMKL did not mention it.
///  2. **A failed or empty pull is not evidence.** The caller only calls `merge` on a decoded 200; an error /
///     timeout / empty array leaves the store untouched (enforced at the call site, like Trakt's `pullRatings`).
///  3. **An unpushed local edit is immune.** While `pushed == false` the user's VortX-side rating has not
///     reached SIMKL yet, so anything SIMKL says about that title is older than what the user just did. Local
///     wins; the queued push then converges SIMKL to it.
///  4. **Otherwise, strictly-newer wins.** For an already-mirrored entry (`pushed == true`), a SIMKL row whose
///     `user_rated_at` is strictly newer is adopted (the same user's later action on the mirror). Equal
///     timestamps change nothing, so a re-pull can never flap.
///
/// A cleared rating is a TOMBSTONE (`rating == nil`), not a deletion, so rule 4 can compare against it.
struct SIMKLRatingsCore: Equatable {
    /// Valid SIMKL rating range. A value outside this is refused rather than clamped.
    static let validRange = 1...10
    /// Bound the file. Only PUSHED TOMBSTONES are ever pruned (oldest first): a real rating is the user's own
    /// data and is never auto-dropped, and an unpushed entry still owes SIMKL a write.
    static let entryCap = 5_000

    /// One rated title. `rating == nil` is a tombstone (the user explicitly cleared their rating).
    struct RatingEntry: Codable, Sendable, Equatable {
        var imdb: String?
        var tmdb: Int?
        var isSeries: Bool
        /// 1...10, or nil for "explicitly unrated" (tombstone).
        var rating: Int?
        /// When the user set (or cleared) this, in whichever client. The merge's newer-wins comparison key.
        var ratedAt: Date
        /// False while this edit still owes SIMKL a write. An unpushed entry is immune to read-back.
        var pushed: Bool
    }

    /// Entries by an opaque, stable primary key (never re-keyed once assigned; a later read-back may enrich an
    /// entry's ids). All lookup goes through `aliases`.
    private(set) var entries: [String: RatingEntry]
    /// Every id form an entry can be found by ("tt123…", "tmdb:456") -> its primary key. Rebuilt on any mutation.
    private var aliases: [String: String] = [:]

    init(entries: [String: RatingEntry] = [:]) {
        self.entries = entries
        rebuildAliases()
    }

    // MARK: - Read side (the app's ONLY SIMKL-rating source)

    /// The user's rating for a title, or nil when unrated / tombstoned / not known.
    func rating(imdb: String?, tmdb: Int?) -> Int? {
        guard let key = primaryKey(imdb: imdb, tmdb: tmdb) else { return nil }
        return entries[key]?.rating
    }

    // MARK: - Write side (user action)

    /// Record the user's rating (or a clear, `rating == nil`) locally and return the entry to mirror, or nil
    /// when there is no usable identity to key on. Mirrors `TraktRatingsStore.write`'s id-union discipline: the
    /// entry keeps its ORIGINAL key and only ACCUMULATES ids, so a re-rate from a tmdb-keyed page never drops
    /// an imdb id the entry already had.
    mutating func write(rating: Int?, imdb: String?, tmdb: Int?, isSeries: Bool) -> RatingEntry? {
        let cleanIMDb = (imdb?.isEmpty == false) ? imdb : nil
        guard cleanIMDb != nil || tmdb != nil else { return nil }
        guard let key = primaryKey(imdb: cleanIMDb, tmdb: tmdb)
                ?? Self.makeKey(imdb: cleanIMDb, tmdb: tmdb) else { return nil }
        let known = entries[key]
        let entry = RatingEntry(imdb: cleanIMDb ?? known?.imdb, tmdb: tmdb ?? known?.tmdb,
                                isSeries: isSeries, rating: rating, ratedAt: Date(), pushed: false)
        entries[key] = entry
        rebuildAliases()
        prune()
        return entry
    }

    /// Flip an entry to `pushed` once SIMKL has it. Matches on the EXACT value + timestamp that was pushed so a
    /// rating changed while the push was in flight (a different, still-unpushed edit) keeps its rule-3 immunity.
    /// Returns true when something changed (so the caller persists).
    @discardableResult
    mutating func markPushed(_ pushed: RatingEntry) -> Bool {
        guard let key = primaryKey(imdb: pushed.imdb, tmdb: pushed.tmdb),
              var current = entries[key],
              current.rating == pushed.rating,
              // Dates round-trip through epoch seconds, so compare at that resolution.
              Int(current.ratedAt.timeIntervalSince1970) == Int(pushed.ratedAt.timeIntervalSince1970),
              !current.pushed
        else { return false }
        current.pushed = true
        entries[key] = current
        return true
    }

    // MARK: - Read-back (convergence, NOT authority)

    /// A neutral read-back row, flattened out of `SIMKLRatingsResponse` so `merge` stays independent of the wire
    /// envelope. `ratedAt` is nil when SIMKL's `user_rated_at` failed to parse, so such a row can fill an unseen
    /// title but can never win rule 4 against a known local entry.
    struct RemoteRating: Equatable {
        var imdb: String?
        var tmdb: Int?
        var isSeries: Bool
        var rating: Int
        var ratedAt: Date?
    }

    /// Flatten a decoded ratings response into neutral rows. Movies fold as movies; shows AND anime fold as
    /// series (anime is series to the detail page, exactly as `SIMKLWatchedCore` treats it). Rows with no
    /// usable id, or a rating outside 1...10, are dropped.
    static func remoteRatings(from response: SIMKLRatingsResponse) -> [RemoteRating] {
        var out: [RemoteRating] = []
        func fold(_ rows: [SIMKLRatingEntry]?, isSeries: Bool) {
            for row in rows ?? [] {
                let ids = isSeries ? row.show?.ids : row.movie?.ids
                guard let ids else { continue }
                let imdb = (ids.imdb?.isEmpty == false) ? ids.imdb : nil
                let tmdb = ids.tmdb
                guard imdb != nil || tmdb != nil else { continue }
                guard validRange.contains(row.userRating) else { continue }
                out.append(RemoteRating(imdb: imdb, tmdb: tmdb, isSeries: isSeries,
                                        rating: row.userRating,
                                        ratedAt: row.userRatedAt.flatMap(SIMKLRatedAt.date(from:))))
            }
        }
        fold(response.movies, isSeries: false)
        fold(response.shows, isSeries: true)
        fold(response.anime, isSeries: true)
        return out
    }

    /// Fold SIMKL's rows into the shadow under the four rules. Returns `(valueChanged, dirty)`: `valueChanged`
    /// is what the user would see (a rating appeared or moved) and drives a repaint; `dirty` is anything that
    /// must reach the alias index + disk, INCLUDING a pure id enrichment that changes no value.
    @discardableResult
    mutating func merge(_ rows: [RemoteRating]) -> (valueChanged: Bool, dirty: Bool) {
        guard !rows.isEmpty else { return (false, false) }
        var valueChanged = false
        var dirty = false
        for row in rows {
            let imdb = (row.imdb?.isEmpty == false) ? row.imdb : nil
            let tmdb = row.tmdb
            guard imdb != nil || tmdb != nil else { continue }
            guard Self.validRange.contains(row.rating) else { continue }

            guard let key = primaryKey(imdb: imdb, tmdb: tmdb) else {
                // Rule 4 (fill): a title the shadow has never heard of. Insert already-pushed; it came FROM
                // SIMKL, so it owes SIMKL nothing.
                guard let newKey = Self.makeKey(imdb: imdb, tmdb: tmdb) else { continue }
                entries[newKey] = RatingEntry(imdb: imdb, tmdb: tmdb, isSeries: row.isSeries,
                                              rating: row.rating, ratedAt: row.ratedAt ?? Date(), pushed: true)
                valueChanged = true
                dirty = true
                continue
            }
            guard var local = entries[key] else { continue }
            // Enrich ids either way (learning a tt id from SIMKL is not a value change, just makes the entry
            // findable from a tt-keyed page later).
            if local.imdb == nil, let imdb { local.imdb = imdb; entries[key] = local; dirty = true }
            if local.tmdb == nil, let tmdb { local.tmdb = tmdb; entries[key] = local; dirty = true }

            // Rule 3: an unpushed local edit is immune.
            guard local.pushed else { continue }
            // Rule 4: adopt ONLY on a strictly newer remote stamp.
            guard let remoteAt = row.ratedAt, remoteAt > local.ratedAt else { continue }
            guard local.rating != row.rating else { continue }
            local.rating = row.rating
            local.ratedAt = remoteAt
            local.pushed = true
            entries[key] = local
            valueChanged = true
            dirty = true
        }
        // Rule 1 is enforced by absence of code: nothing above removes an entry for not being in `rows`.
        guard dirty else { return (false, false) }
        rebuildAliases()
        prune()
        return (valueChanged, true)
    }

    // MARK: - Disconnect

    /// Wipe the shadow on disconnect / sign-out so ratings do not leak into the next account on this device.
    mutating func wipe() {
        entries = [:]
        aliases = [:]
    }

    // MARK: - Keys + aliases (ported from TraktRatingsStore)

    private func primaryKey(imdb: String?, tmdb: Int?) -> String? {
        if let imdb, !imdb.isEmpty, let key = aliases[imdb] { return key }
        if let tmdb, let key = aliases["tmdb:\(tmdb)"] { return key }
        return nil
    }

    private static func makeKey(imdb: String?, tmdb: Int?) -> String? {
        if let imdb, !imdb.isEmpty { return imdb }
        if let tmdb { return "tmdb:\(tmdb)" }
        return nil
    }

    private mutating func rebuildAliases() {
        var next: [String: String] = [:]
        // Two entries can legitimately claim one alias (a tmdb-keyed entry enriched to share a tt-keyed entry's
        // tmdb id); resolve it the way `merge` resolves every conflict: the NEWER edit wins, with the key
        // breaking an exact timestamp tie so the result never depends on dictionary iteration order.
        func claim(_ alias: String, _ key: String) {
            guard let held = next[alias] else { next[alias] = key; return }
            guard let candidate = entries[key], let incumbent = entries[held] else { return }
            if (candidate.ratedAt, key) > (incumbent.ratedAt, held) { next[alias] = key }
        }
        for (key, entry) in entries {
            if let imdb = entry.imdb, !imdb.isEmpty { claim(imdb, key) }
            if let tmdb = entry.tmdb { claim("tmdb:\(tmdb)", key) }
        }
        aliases = next
    }

    /// Keep the file bounded by dropping the OLDEST PUSHED TOMBSTONES only. A real rating is never auto-dropped;
    /// an unpushed entry still owes SIMKL a write.
    private mutating func prune() {
        guard entries.count > Self.entryCap else { return }
        let droppable = entries
            .filter { $0.value.rating == nil && $0.value.pushed }
            .sorted { $0.value.ratedAt < $1.value.ratedAt }
        for (key, _) in droppable.prefix(entries.count - Self.entryCap) { entries.removeValue(forKey: key) }
        rebuildAliases()
    }
}
