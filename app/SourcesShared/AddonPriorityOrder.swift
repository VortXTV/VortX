import Foundation

/// The ONE canonical add-on PRIORITY ordering primitive: the pure, dependency-free rule that turns the
/// user's applied add-on order (`VortXSyncManager.appliedAddonOrder`, written by the in-app Reorder screen
/// and the web dashboard drag, synced via `doc.addonOrder`) into the order every REAL resolution surface
/// walks.
///
/// WHY THIS EXISTS (the #144-follow-up defect): the reorder used to be cosmetic. It sorted the Add-ons
/// LIST and picked the detail meta (#144), but the engine's `AggrRequest::AllOfResource` walks the raw
/// `profile.addons` Vec, which a reorder never rewrites, and the engine physically pins its PROTECTED
/// add-ons (the official English Cinemeta at index 0, Local Files) so a `profile.addons` rewrite can never
/// put a user's localized meta provider first anyway (stremio-core `UninstallAddon` refuses a protected
/// descriptor; `InstallAddon` only appends or updates-in-place, so it cannot MOVE one; and both push the
/// collection to api.strem.io when a Stremio session is live, the exact destructive two-way write the app
/// guards against everywhere else). So the order the user chose is applied at the SWIFT resolution
/// consumption points instead, where each add-on's output is still separable and re-orderable: the source
/// (stream) groups, the Home catalog rows, and the detail meta. This type is the single sort rule those
/// paths share, so "which add-on answers first" is one behavior with one place to test, not three copies.
///
/// Pure `Foundation` only (no engine, no SwiftUI, no UserDefaults): the production callers pass the applied
/// order in, and the standalone verification compiles THIS FILE and asserts the shipped function directly
/// rather than a re-implemented mirror.
enum AddonPriorityOrder {
    /// Normalize a transport URL to its comparison key, IDENTICAL to `AddonTombstones.normalize`
    /// (trim + lowercase). `appliedAddonOrder` is stored already-normalized (see
    /// `VortXSyncManager.applyInAppAddonOrder`), so both sides of every lookup pass through this.
    static func normalize(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Stable priority sort: items whose add-on base is present in `applied` come first, in that order;
    /// items NOT in `applied` (a freshly-installed add-on the user has not placed yet) keep their original
    /// relative order at the END so they are never hidden or shuffled. An empty `applied` returns the input
    /// unchanged, so this is a no-op until the user actually reorders. This is the exact rule the Add-ons
    /// list and the source (stream) groups walk.
    static func order<T>(_ items: [T], applied: [String], base: (T) -> String) -> [T] {
        guard !applied.isEmpty else { return items }
        var index: [String: Int] = [:]
        // Normalize BOTH sides. `appliedAddonOrder` is stored already-normalized, so this is idempotent for
        // production callers; normalizing here too keeps the primitive correct if it is ever handed a raw
        // order (and keeps a first-write-wins index if a URL somehow appears twice).
        for (i, url) in applied.enumerated() where index[normalize(url)] == nil { index[normalize(url)] = i }
        return items.enumerated().sorted { a, b in
            let ia = index[normalize(base(a.element))]
            let ib = index[normalize(base(b.element))]
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
        var addonRank: [String: Int] = [:]
        for (i, url) in applied.enumerated() where addonRank[normalize(url)] == nil { addonRank[normalize(url)] = i }
        func rank(_ item: T) -> Int { addonRank[normalize(base(item))] ?? Int.max }
        return rows.sorted { a, b in
            let ca = catalogRank(a), cb = catalogRank(b)
            if ca != cb { return ca < cb }        // explicit catalog-manager order first
            let aa = rank(a), ab = rank(b)
            if aa != ab { return aa < ab }         // then user's add-on priority order
            return engineIndex(a) < engineIndex(b) // then stable engine order
        }
    }

    /// Move the item at `from` by a single step to `to` (the remote up/down reorder on tvOS). Out-of-range
    /// `to` (a Move-up on the first row, a Move-down on the last) is a clamped no-op that returns the input
    /// order unchanged, so the caller never has to bounds-check and a boundary press can never drop an item.
    static func moved<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), to >= 0, to < items.count, to != from else { return items }
        var next = items
        let item = next.remove(at: from)
        next.insert(item, at: to)
        return next
    }
}
