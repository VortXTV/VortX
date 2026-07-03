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
}
