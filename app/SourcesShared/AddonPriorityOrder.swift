import Foundation

/// The ONE canonical add-on PRIORITY ordering primitive: the pure, dependency-free rule that turns the
/// user's applied add-on order (`VortXSyncManager.appliedAddonOrder`, written by the in-app Reorder screen
/// and the web dashboard drag, synced via `doc.addonOrder`) into the DISPLAY / GROUP order the resolution
/// surfaces walk.
///
/// WHAT IT CONTROLS (narrowed, per DIS-05): the order applies at the SWIFT display / grouping seams, so a
/// reordered add-on's streams and catalogs APPEAR FIRST in the source list, the Home board, the Add-ons
/// list and the detail-meta pick. It does NOT rewrite the engine's internal request priority
/// (`AggrRequest`'s Search / LoadRange / Discover walks over the raw `profile.addons` Vec): that is an
/// engine-lane concern left open by DIS-05, and whether the AUTO-SELECTED "Watch Now" source follows this
/// order is governed separately by the user's `SourcePreferences.useAddonOrder` choice (see
/// `StreamRanking.best`). So the honest claim is "controls which add-on's streams and catalogs appear
/// first", not "answers first" everywhere.
///
/// WHY THIS EXISTS (the #144-follow-up defect): the reorder used to be cosmetic. It sorted the Add-ons
/// LIST and picked the detail meta (#144), but the engine's `AggrRequest::AllOfResource` walks the raw
/// `profile.addons` Vec, which a reorder never rewrites, and the engine physically pins its PROTECTED
/// add-ons (the official English Cinemeta at index 0, Local Files) so a `profile.addons` rewrite can never
/// put a user's localized meta provider first anyway (stremio-core `UninstallAddon` refuses a protected
/// descriptor; `InstallAddon` only appends or updates-in-place, so it cannot MOVE one; and both push the
/// collection to api.strem.io when a Stremio session is live, the exact destructive two-way write the app
/// guards against everywhere else). So the order the user chose is applied at the SWIFT display /
/// consumption points instead, where each add-on's output is still separable and re-orderable: the source
/// (stream) groups, the Home catalog rows, and the detail meta. This type is the single sort rule those
/// paths share, so "which add-on appears first" is one behavior with one place to test, not three copies.
///
/// Pure `Foundation` only (no engine, no SwiftUI, no UserDefaults): the production callers pass the applied
/// order in, and the standalone verification compiles THIS FILE and asserts the shipped function directly
/// rather than a re-implemented mirror.
enum AddonPriorityOrder {
    /// The ONE shared, QR-safe canonical identity for an add-on transport URL (aligns the priority-order
    /// lane with the add-on install / QR-pairing lane's identity rule). RFC 3986 makes the SCHEME and HOST
    /// case-INSENSITIVE but the PATH and QUERY case-SENSITIVE, so the previous whole-string `lowercased()`
    /// (H3) collapsed two genuinely-distinct add-ons whose manifests differ only by path or query case into
    /// ONE rank. This folds ONLY the scheme + host to lower case, preserves the path and query EXACTLY,
    /// drops the fragment (never part of an add-on's transport identity), and trims. Both sides of every
    /// lookup pass through here (the stored `appliedAddonOrder` is written canonical and the live add-on
    /// base is canonicalized on read), so identity is stable and case-/fragment-safe on both. A string that
    /// is not a parseable http(s) URL falls back to a trimmed whole-string lower case (there is no path or
    /// query to protect), which is still self-consistent because both sides run this one function.
    static func canonical(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme, !scheme.isEmpty,
              let host = comps.host, !host.isEmpty else {
            return trimmed.lowercased()
        }
        comps.scheme = scheme.lowercased()
        comps.host = host.lowercased()
        comps.fragment = nil
        // Preserve path + query EXACTLY (case-sensitive per RFC 3986); only scheme/host are folded.
        return comps.string ?? trimmed.lowercased()
    }

    /// The FIRST-occurrence rank map for an applied order: `canonical(url) -> position`. When a synced
    /// order carries a DUPLICATE entry, the FIRST occurrence wins and the later one is ignored. This is the
    /// ONE duplicate policy shared by the stream, catalog, AND detail-meta seams (M2): previously the meta
    /// pick built a LAST-occurrence map, so a duplicated synced entry could rank the three surfaces
    /// differently. Every consumer derives its ranks from here, so identity and dedup can never disagree.
    static func rankMap(_ applied: [String]) -> [String: Int] {
        var index: [String: Int] = [:]
        for (i, url) in applied.enumerated() where index[canonical(url)] == nil { index[canonical(url)] = i }
        return index
    }

    /// Stable priority sort: items whose add-on base is present in `applied` come first, in that order;
    /// items NOT in `applied` (a freshly-installed add-on the user has not placed yet) keep their original
    /// relative order at the END so they are never hidden or shuffled. An empty `applied` returns the input
    /// unchanged, so this is a no-op until the user actually reorders. This is the exact rule the Add-ons
    /// list and the source (stream) groups walk.
    static func order<T>(_ items: [T], applied: [String], base: (T) -> String) -> [T] {
        guard !applied.isEmpty else { return items }
        // FIRST-occurrence rank + canonical identity on BOTH sides (the applied order is stored canonical, so
        // this is idempotent for production callers; canonicalizing here too keeps the primitive correct if it
        // is ever handed a raw order).
        let index = rankMap(applied)
        return items.enumerated().sorted { a, b in
            let ia = index[canonical(base(a.element))]
            let ib = index[canonical(base(b.element))]
            switch (ia, ib) {
            case let (x?, y?): return x < y                // both placed -> user order
            case (_?, nil):    return true                 // placed before not-yet-placed
            case (nil, _?):    return false
            case (nil, nil):   return a.offset < b.offset  // stable for the un-placed tail
            }
        }.map(\.element)
    }

    /// Board-catalog ordering: the user's EXPLICIT per-catalog order (the catalog-manager drag,
    /// `CatalogPrefsStore.rank`) still wins where it is set; among catalogs the user has NOT explicitly
    /// ordered (the common default, where `catalogRank` is the same sentinel for both), the add-on PRIORITY
    /// order groups each add-on's catalogs together in the reordered order; the engine catalog index is the
    /// final stable tiebreak. So a reorder drives Home catalog grouping without overriding an explicit
    /// catalog-manager arrangement.
    static func orderCatalogRows<T>(_ rows: [T], applied: [String],
                                    base: (T) -> String,
                                    catalogRank: (T) -> Int,
                                    engineIndex: (T) -> Int) -> [T] {
        let addonRank = rankMap(applied)   // shared FIRST-occurrence + canonical identity
        func rank(_ item: T) -> Int { addonRank[canonical(base(item))] ?? Int.max }
        return rows.sorted { a, b in
            let ca = catalogRank(a), cb = catalogRank(b)
            if ca != cb { return ca < cb }        // explicit catalog-manager order first
            let aa = rank(a), ab = rank(b)
            if aa != ab { return aa < ab }         // then user's add-on priority order
            return engineIndex(a) < engineIndex(b) // then stable engine order
        }
    }

    /// Move the item at `from` by a single step to `to` (the remote up/down reorder on tvOS). Out-of-range
    /// `from`/`to` (a Move-up on the first row, a Move-down on the last, or a stale captured index the list
    /// no longer contains) is a clamped no-op that returns the input order unchanged, so the caller never
    /// has to bounds-check and a boundary press or a stale index can never drop or duplicate an item.
    static func moved<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), to >= 0, to < items.count, to != from else { return items }
        var next = items
        let item = next.remove(at: from)
        next.insert(item, at: to)
        return next
    }
}
