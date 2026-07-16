import Foundation

/// Auto-add-to-Library at ~60s of playback (D8): once the user has genuinely committed to a title (crossed the
/// ~60s watch tick that also marks progress), add it to the Library automatically so it is one tap away later.
///
/// Invariants (see CLAUDE.md "Per-profile watch history" + "Never write app data into libraryItem"):
///   - MAIN profile (`activeUsesEngineHistory`): add through the ENGINE's AddToLibrary dispatch ONLY
///     (`CoreBridge.addToLibrary` / `addCatalogItemToAccount`), which syncs to the account exactly like the
///     manual Library button. Never an app-side libraryItem write.
///   - OVERLAY profiles: must NOT touch the account library. Save to the profile's private local overlay
///     (`ProfileStore.addLibraryEntry`) instead.
///
/// Idempotency + honoring a manual removal: this records a per-profile set of ids it has ALREADY auto-added
/// (UserDefaults). It auto-adds a given (profile, id) AT MOST ONCE, so if the user later manually removes the
/// title it is NOT force-re-added on the next play (the whole point of D8's "remember a manual removal"). The
/// engine's AddToLibrary is itself idempotent, but the local marker is what makes a manual removal stick.
///
/// Fully fail-soft: a missing meta / unresolved id simply skips (the title just is not auto-added that session).
@MainActor
enum LibraryAutoAdd {

    /// UserDefaults key prefix; the active profile id is appended so each profile has its own auto-added set
    /// (an overlay profile's local adds must never leak into another profile's or the account's ledger).
    private static let keyPrefix = "stremiox.autoAddedLibrary"
    private static let cap = 2000   // bound the remembered-ids set so it can't grow without limit

    /// The per-profile storage key. Falls back to a shared key when there is no active profile id.
    private static func storageKey() -> String {
        if let id = ProfileStore.shared.activeID { return "\(keyPrefix).\(id.uuidString)" }
        return keyPrefix
    }

    /// Whether this (active-profile, id) has already been auto-added once. Public so the caller can cheaply
    /// short-circuit the ~60s tick without building any meta.
    static func hasAutoAdded(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: storageKey()) ?? []).contains(id)
    }

    private static func rememberAutoAdded(_ id: String) {
        let key = storageKey()
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !ids.contains(id) else { return }
        ids.append(id)
        if ids.count > cap { ids.removeFirst(ids.count - cap) }   // drop oldest, stay bounded
        UserDefaults.standard.set(ids, forKey: key)
    }

    /// Auto-add the currently-playing title to the Library once, respecting the per-profile rules above.
    ///
    /// - Parameters:
    ///   - meta: the playing title's `PlaybackMeta` (its `libraryId` is the catalog id; `type` = movie/series).
    ///   - core: the engine bridge (main-profile adds dispatch through it).
    ///   - enabled: the "Auto-add watched to Library" setting (default ON); a `false` skips entirely.
    /// Idempotent: after the first successful auto-add for (profile, id) this is a no-op, so a manual removal
    /// afterwards is honored (the title is not re-added on the next play).
    static func addIfNeeded(meta: PlaybackMeta, core: CoreBridge, enabled: Bool) {
        guard enabled else { return }
        let id = meta.libraryId
        // Only real catalog ids belong in the account library. A synthetic magnet / ad-hoc paste-a-link id
        // must never be written (it poisons official-client account sync). tt… and tmdb… are the safe shapes.
        guard id.hasPrefix("tt") || id.hasPrefix("tmdb") else { return }
        guard !hasAutoAdded(id) else { return }   // already auto-added once for this profile -> respect removal

        if ProfileStore.shared.activeUsesEngineHistory {
            // MAIN profile: go through the engine. Prefer the loaded meta_details (exact engine shape); if that
            // is not this title (a hub/CW launch may have replaced it), resolve the full meta from Cinemeta and
            // dispatch AddToLibrary. Both routes are the account-syncing engine path, never an app libraryItem.
            if let loaded = core.metaDetails?.meta, loaded.id == id {
                core.addToLibrary(metaId: id)
                rememberAutoAdded(id)
                NSLog("[autolib] auto-added %@ to account library (engine, loaded meta)", id)
            } else {
                let type = (meta.type == "series") ? "series" : "movie"
                Task { @MainActor in
                    // Only remember the auto-add once the account write actually succeeded; a failed resolve
                    // must retry on the next play, not be silently pinned as "already added".
                    if await core.addCatalogItemToAccount(id: id, type: type) {
                        rememberAutoAdded(id)
                        NSLog("[autolib] auto-added %@ to account library (engine, resolved meta)", id)
                    }
                }
            }
        } else {
            // OVERLAY profile: local overlay ONLY, never the account library.
            ProfileStore.shared.addLibraryEntry(metaId: id, name: meta.name, type: meta.type, poster: meta.poster)
            rememberAutoAdded(id)
            NSLog("[autolib] auto-added %@ to overlay-profile library (local overlay)", id)
        }
    }

    // MARK: - Watchlist (a lightweight per-profile "want to watch" ledger)

    /// A pure app-side "want to watch" flag, kept in the SAME local-overlay style as the auto-added set above:
    /// a per-profile UserDefaults record, engine-safe ids only, and NEVER a write into a `libraryItem` doc or
    /// any account-parsed schema (the CLAUDE.md invariant that once corrupted official-client sync). So marking
    /// a title for later cannot touch the account library or leak between profiles. Records carry the title's
    /// type (and an optional name/poster snapshot) so the Upcoming calendar can route and render each entry
    /// without a second meta lookup. This is intentionally SEPARATE from the Trakt / SIMKL remote watchlists in
    /// `ExternalScrobbleProvider`: those mirror to a remote account; this is the on-device list a later pass may
    /// choose to bridge to them.

    /// One remembered watchlist title. Codable so the whole list round-trips through a single UserDefaults value.
    struct WatchlistEntry: Codable, Equatable, Identifiable {
        let id: String          // engine catalog id (tt… / tmdb…)
        let type: String        // "series" | "movie"
        let name: String?       // snapshot for a list row / calendar fallback
        let poster: String?     // snapshot poster URL, if known at add time
        let addedAt: Double     // epoch seconds, so the list can render newest-add first
    }

    /// Posted (main thread) after any watchlist mutation so a bookmark button or the Upcoming rail can refresh.
    static let watchlistChangedNote = Notification.Name("vortx.watchlistChanged")

    private static let watchlistKeyPrefix = "vortx.watchlist"
    private static let watchlistCap = 1000   // bound the list so it can't grow without limit

    /// Per-profile storage key (an overlay profile's list must never leak into another profile's or the account).
    private static func watchlistKey() -> String {
        if let id = ProfileStore.shared.activeID { return "\(watchlistKeyPrefix).\(id.uuidString)" }
        return watchlistKeyPrefix
    }

    /// The active profile's watchlist, newest-add first. Fail-soft: a missing / garbled value reads as empty.
    static func watchlist() -> [WatchlistEntry] {
        guard let data = UserDefaults.standard.data(forKey: watchlistKey()),
              let entries = try? JSONDecoder().decode([WatchlistEntry].self, from: data) else { return [] }
        return entries.sorted { $0.addedAt > $1.addedAt }
    }

    private static func saveWatchlist(_ entries: [WatchlistEntry]) {
        // Keep the newest `watchlistCap` so a huge list stays bounded (drop the oldest adds first).
        let bounded = Array(entries.sorted { $0.addedAt > $1.addedAt }.prefix(watchlistCap))
        if let data = try? JSONEncoder().encode(bounded) {
            UserDefaults.standard.set(data, forKey: watchlistKey())
        }
        NotificationCenter.default.post(name: watchlistChangedNote, object: nil)
    }

    /// Whether a title is on the active profile's watchlist. Cheap enough for a button to read directly.
    static func isWatchlisted(_ id: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: watchlistKey()),
              let entries = try? JSONDecoder().decode([WatchlistEntry].self, from: data) else { return false }
        return entries.contains { $0.id == id }
    }

    /// Add a title to the watchlist. Engine-safe ids ONLY (a synthetic magnet / paste-a-link id is rejected so
    /// it can never poison sync if a later pass bridges the list upstream). Idempotent: a title already present
    /// is left untouched. Returns true only when it actually added a new entry.
    @discardableResult
    static func addToWatchlist(id: String, type: String, name: String? = nil, poster: String? = nil) -> Bool {
        guard id.hasPrefix("tt") || id.hasPrefix("tmdb") else { return false }
        var entries = watchlist()
        guard !entries.contains(where: { $0.id == id }) else { return false }
        let normalizedType = (type == "series") ? "series" : "movie"
        entries.append(WatchlistEntry(id: id, type: normalizedType, name: name, poster: poster,
                                      addedAt: Date().timeIntervalSince1970))
        saveWatchlist(entries)
        NSLog("[watchlist] added %@ (%@)", id, normalizedType)
        return true
    }

    /// Remove a title from the watchlist (no-op if it was not on it).
    static func removeFromWatchlist(_ id: String) {
        var entries = watchlist()
        let before = entries.count
        entries.removeAll { $0.id == id }
        guard entries.count != before else { return }
        saveWatchlist(entries)
        NSLog("[watchlist] removed %@", id)
    }

    /// Flip a title's watchlist membership. Returns the NEW state (true = now on the watchlist), so a button can
    /// set its own filled / outline state straight from the return value without a second `isWatchlisted` read.
    @discardableResult
    static func toggleWatchlist(id: String, type: String, name: String? = nil, poster: String? = nil) -> Bool {
        if isWatchlisted(id) { removeFromWatchlist(id); return false }
        return addToWatchlist(id: id, type: type, name: name, poster: poster)
    }

    /// The watchlisted ids of one type ("series" / "movie"), for the Upcoming calendar's per-type fan-out.
    static func watchlistedIDs(ofType type: String) -> [String] {
        let normalizedType = (type == "series") ? "series" : "movie"
        return watchlist().filter { $0.type == normalizedType }.map(\.id)
    }
}
