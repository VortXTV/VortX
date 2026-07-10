import Foundation

/// Durable cross-device REMOVE tombstones for LIBRARY / Continue-Watching titles, the library analogue of
/// `AddonTombstones` (and of `ProfileStore`'s `deletedProfiles` set). The app OWNS this set (it lives in
/// `doc.vortx.deletedLibrary`, the app's namespace) so a title the user removed on one device can never be
/// resurrected by a peer device's UNION hydrate, a stale pre-removal cloud blob, or the cold-device library
/// recovery path.
///
/// Today owner-library hydration is add-only (UNION): `recoverOwnerLibraryIfEmpty` re-adds every owned title
/// on a cold/empty engine and `vortxSummary` re-unions the engine library into `doc.vortx.library`, so a
/// removal on device A is silently undone on device B (and re-unioned back into the doc). This is the exact
/// bug `AddonTombstones` already closes for add-ons; this set closes it for the library the same way:
///
///  - WRITE on an in-app Remove (`CoreBridge.removeFromLibrary`, the engine-history branch) so the removal syncs.
///  - PUSH the EFFECTIVE removed set into `doc.vortx.deletedLibrary` from `vortxSummary`, and SUBTRACT it from
///    the `doc.vortx.library` UNION so a removed title is never re-unioned back in.
///  - FOLD an incoming `doc.vortx.deletedLibrary` (plus its `doc.vortx.deletedLibraryTs` companion) into the
///    local state on a SUCCESSFUL `.doc` pull, so a removal on device A propagates to peers instead of
///    union-resurrecting.
///  - EXCLUDE effectively-removed ids from `recoverOwnerLibraryIfEmpty` so the cold-device recovery never
///    re-adds them.
///
/// LAST-WRITER-WINS model. Each id carries two per-entry timestamps: `removedAt` (stamped by `tombstone`) and
/// `addedAt` (stamped by `forget`). An id is EFFECTIVELY removed iff `removedAt > addedAt`. Entries are never
/// deleted and each stamp only ever moves forward (local writes and the merge fold both take the per-id MAX),
/// so the set stays a monotone, union-style structure; the only extra bit over a plain id set is the recency
/// of the last add versus the last remove, which is what lets a genuine re-add out-race a stale removal
/// instead of being suppressed forever.
///
/// WIRE COMPATIBILITY. `doc.vortx.deletedLibrary` keeps its old shape (an array of ids), now computed as the
/// EFFECTIVE removed set, so the dashboard and older app builds keep reading it exactly as before. The new
/// companion `doc.vortx.deletedLibraryTs` (id -> {removedAt, addedAt}) carries the stamps; clients that do not
/// know the field ignore it. An incoming id that appears only in the legacy array with NO stamp entry is
/// folded at the migration epoch, so any real later add out-races it. Mixed-fleet caveat: an older client's
/// genuine re-removal is indistinguishable from its stale re-emit until that client updates.
///
/// SAFETY: the overlay-profile Remove path is UNTOUCHED (it goes through `ProfileStore`, which is already
/// tombstone-safe); only the OWNER/account engine-history removal writes here. The state only ever changes
/// from EXPLICIT add/remove intent, never from an inferred diff, and a legitimate re-ADD of the same id
/// stamps a newer `addedAt` (`forget`) so `all()` stops listing it and a fresh add of a previously-removed
/// title is honored on every device.
enum LibraryTombstones {
    /// Per-entry removal / add timestamps (milliseconds since epoch), the b172 last-writer-wins stores.
    private static let removedAtKey = "stremiox.library.removedAt"
    private static let addedAtKey = "stremiox.library.addedAt"
    /// Pre-b172 plain removal array. Folded into `removedAt` at the migration epoch on every load, and rewritten
    /// with the current effective removed set on every save so a b171 downgrade still reads live removals.
    private static let legacyDeletedKey = "stremiox.library.deleted"

    /// A migrated legacy removal, or any wire id that carries no stamp, folds in at this fixed low epoch, so
    /// any genuine later add (a real wall-clock millisecond, orders of magnitude larger) always out-races it.
    static let migrationEpochMs: Double = 1

    /// Bound the stores so an oversized peer doc can never grow them without limit. `maxEntries` counts
    /// distinct ids; oversized ids are dropped by `maxIDLength`.
    private static let maxEntries = 10_000
    private static let maxIDLength = 512

    /// Normalize a library id for tombstone identity: trim + lowercase. Stremio/Cinemeta ids (`tt…`, `tmdb:…`)
    /// are effectively lowercase/numeric, so the same trim/lowercase is applied on both the write side (when
    /// recording a removal) and the match side (when subtracting from the library union or the recovery loop),
    /// keeping identity stable across any casing drift.
    static func normalize(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The current durable removal set (normalized library ids that are EFFECTIVELY removed). Read fresh from
    /// UserDefaults so every surface (CoreBridge write, vortxSummary push, syncDown fold, recovery skip) sees
    /// the same authority.
    static func all() -> Set<String> {
        effectiveRemoved(load())
    }

    /// The per-id timestamp map for the wire (`doc.vortx.deletedLibraryTs`). Carries BOTH stamps for every
    /// tracked id, not just the effectively-removed ones, so a peer folding this learns a genuine re-add's
    /// `addedAt` and stops re-emitting a stale removal. Clients that do not know the field ignore it.
    static func timestampsForSync() -> [String: [String: Double]] {
        let state = load()
        let ids = Set(state.removedAt.keys).union(state.addedAt.keys)
        var out: [String: [String: Double]] = [:]
        out.reserveCapacity(ids.count)
        for id in ids {
            var entry: [String: Double] = [:]
            if let r = state.removedAt[id] { entry["removedAt"] = r }
            if let a = state.addedAt[id] { entry["addedAt"] = a }
            if !entry.isEmpty { out[id] = entry }
        }
        return out
    }

    /// Record a library removal so it sticks across devices. Idempotent for the caller. Returns true when the
    /// id becomes NEWLY effectively-removed. Callers MUST guard the OWNER (engine-history) branch before
    /// calling: an overlay-profile removal is private history and must never enter this account-scoped set.
    @discardableResult
    static func tombstone(_ id: String) -> Bool {
        let key = normalize(id)
        guard !key.isEmpty, key.count <= maxIDLength else { return false }
        var state = load()
        let wasRemoved = isRemoved(key, in: state)
        // Move the removal high-water mark forward so this removal out-races an older add on any peer.
        state.removedAt[key] = max(state.removedAt[key] ?? 0, nowMs())
        save(state)
        return !wasRemoved && isRemoved(key, in: state)
    }

    /// Forget a removal tombstone, so an EXPLICIT fresh add of the same title later is honored instead of
    /// being suppressed forever by an old removal. Called from every OWNER-branch add path
    /// (`CoreBridge.addDetailToLibrary` / `addToLibrary` / `addRawMetaToLibrary` / `addCatalogItemToAccount`):
    /// an explicit add is intent to have the title, which supersedes a prior removal. Idempotent for the
    /// caller. Returns true when the id flips from effectively-removed to present.
    ///
    /// Why this is safe against a stale-doc re-resurrection: `vortxSummary` rewrites `doc.vortx.library` from
    /// the live engine library (which now includes the re-added title), `doc.vortx.deletedLibrary` from the
    /// EFFECTIVE removed set (which no longer lists this id) and `doc.vortx.deletedLibraryTs` with the newer
    /// `addedAt`, so the account doc carries an add that out-races the tombstone on every peer.
    @discardableResult
    static func forget(_ id: String) -> Bool {
        let key = normalize(id)
        guard !key.isEmpty, key.count <= maxIDLength else { return false }
        var state = load()
        let wasRemoved = isRemoved(key, in: state)
        // Move the add high-water mark forward so this add out-races an older removal on any peer.
        state.addedAt[key] = max(state.addedAt[key] ?? 0, nowMs())
        save(state)
        return wasRemoved && !isRemoved(key, in: state)
    }

    /// Fold an incoming peer's library tombstones. `legacyIDs` is the back-compat `doc.vortx.deletedLibrary`
    /// array (the effective removed set as written by any client); `stampsRaw` is the raw
    /// `doc.vortx.deletedLibraryTs` map ({removedAt, addedAt} per id) written by builds that know the field.
    /// Both fold by per-id MAX timestamp, so the merge stays a monotone union-style fold: an incoming removed
    /// stamp can only push `removedAt` forward and an incoming add stamp can only push `addedAt` forward. A
    /// legacy id with NO stamp entry folds at the migration epoch, so any real later add out-races it. Returns
    /// true when the EFFECTIVE removed set changed (which now includes a peer re-add flipping an id back to
    /// present, the last-writer-wins point of this set).
    @discardableResult
    static func merge(legacyIDs: [String], stampsRaw: [String: Any]) -> Bool {
        // Timestamps are wall-clock milliseconds, the only frame comparable across devices. The fold takes the
        // per-id MAX, so a stamp dated far in the future wins until real time reaches it: a device with a
        // grossly wrong-future clock pins an id's state until then. Bounded on purpose (docs are per-account
        // and E2E, so the only stamp source is the user's own devices); a bounded future-stamp clamp is queued
        // for a later build.
        var state = load()
        let before = effectiveRemoved(state)
        let futureThresholdMs = nowMs() + 48 * 60 * 60 * 1000   // surface a clock-skewed peer before the b173 clamp
        var maxFutureSeen: Double = 0

        var stamped = Set<String>()
        for (rawID, rawEntry) in stampsRaw {
            let id = normalize(rawID)
            guard !id.isEmpty, id.count <= maxIDLength, let entry = rawEntry as? [String: Any] else { continue }
            stamped.insert(id)
            if let r = (entry["removedAt"] as? NSNumber)?.doubleValue, r.isFinite {
                if r > futureThresholdMs { maxFutureSeen = max(maxFutureSeen, r) }
                state.removedAt[id] = max(state.removedAt[id] ?? 0, r)
            }
            if let a = (entry["addedAt"] as? NSNumber)?.doubleValue, a.isFinite {
                if a > futureThresholdMs { maxFutureSeen = max(maxFutureSeen, a) }
                state.addedAt[id] = max(state.addedAt[id] ?? 0, a)
            }
        }
        for rawID in legacyIDs {
            let id = normalize(rawID)
            guard !id.isEmpty, id.count <= maxIDLength, !stamped.contains(id) else { continue }
            state.removedAt[id] = max(state.removedAt[id] ?? 0, migrationEpochMs)
        }

        save(state)
        if maxFutureSeen > 0 {
            DiagnosticsLog.log("sync", "library tombstone fold saw a stamp \(Int(maxFutureSeen)) beyond now+48h (peer clock skew)")
        }
        return effectiveRemoved(load()) != before
    }

    // MARK: - State

    private struct State {
        var removedAt: [String: Double]
        var addedAt: [String: Double]
    }

    private static func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    private static func isRemoved(_ id: String, in state: State) -> Bool {
        (state.removedAt[id] ?? 0) > (state.addedAt[id] ?? 0)
    }

    private static func effectiveRemoved(_ state: State) -> Set<String> {
        var out = Set<String>()
        out.reserveCapacity(state.removedAt.count)
        for (id, removed) in state.removedAt where removed > (state.addedAt[id] ?? 0) {
            out.insert(id)
        }
        return out
    }

    private static func load() -> State {
        var removedAt = loadMap(removedAtKey)
        let addedAt = loadMap(addedAtKey)
        // Fold the pre-b172 plain removal array at the migration epoch on EVERY load. The max-fold is monotone
        // and idempotent, so no once-flag is needed (a flag has three holes: a kill between setting it and doing
        // the work loses the set, a b171 downgrade reads a frozen pre-upgrade array, and a downgrade-then-upgrade
        // skips re-migration). Folding every load also re-picks-up removals a b171 interlude added to the legacy
        // key. Irreducible caveat: a re-add made during a b171 interlude carries no stamp and stays suppressed
        // until one manual re-add on b172.
        if let legacy = UserDefaults.standard.stringArray(forKey: legacyDeletedKey) {
            for raw in legacy.prefix(maxEntries) {
                let id = normalize(raw)
                guard !id.isEmpty, id.count <= maxIDLength else { continue }
                removedAt[id] = max(removedAt[id] ?? 0, migrationEpochMs)
            }
        }
        return State(removedAt: removedAt, addedAt: addedAt)
    }

    private static func save(_ state: State) {
        let bounded = capped(state)
        UserDefaults.standard.set(bounded.removedAt, forKey: removedAtKey)
        UserDefaults.standard.set(bounded.addedAt, forKey: addedAtKey)
        // Dual-write the effective removed set back to the pre-b172 legacy key so a downgrade to b171 still
        // reads the current removals (b171 reads this array directly; load() re-folds it at the epoch on the
        // next b172 upgrade).
        UserDefaults.standard.set(Array(effectiveRemoved(bounded)), forKey: legacyDeletedKey)
    }

    private static func loadMap(_ key: String) -> [String: Double] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else { return [:] }
        var out: [String: Double] = [:]
        out.reserveCapacity(raw.count)
        for (id, value) in raw {
            if let number = value as? NSNumber { out[id] = number.doubleValue }
        }
        return out
    }

    /// Enforce the size cap by keeping the most-recently-touched ids (by the later of their two stamps) and
    /// dropping the oldest. Ids are evicted WHOLE (both stamps together), so a half-drop can never flip an
    /// added title back to removed.
    private static func capped(_ state: State) -> State {
        let ids = Set(state.removedAt.keys).union(state.addedAt.keys)
        guard ids.count > maxEntries else { return state }
        let keep = Set(ids.sorted { lhs, rhs in
            let l = max(state.removedAt[lhs] ?? 0, state.addedAt[lhs] ?? 0)
            let r = max(state.removedAt[rhs] ?? 0, state.addedAt[rhs] ?? 0)
            return l > r
        }.prefix(maxEntries))
        var removedAt: [String: Double] = [:]
        var addedAt: [String: Double] = [:]
        for id in keep {
            if let v = state.removedAt[id] { removedAt[id] = v }
            if let v = state.addedAt[id] { addedAt[id] = v }
        }
        return State(removedAt: removedAt, addedAt: addedAt)
    }
}
