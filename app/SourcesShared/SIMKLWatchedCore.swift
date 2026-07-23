import Foundation

/// Pure, Foundation-only state core for the SIMKL watched-history import shadow (see `SIMKLWatchedShadow`).
///
/// Extracted for the same reason `WatchedFold` was: `SIMKLWatchedShadow` pulls in `SIMKLService` /
/// `SIMKLAuth` / `WatchedIndex` and cannot link standalone, so every rule that decides WHAT the shadow
/// knows lives here instead, where a self-contained test can exercise the fold, the replace, the disconnect
/// wipe, and the opt-in gate. `SIMKLWatchedShadow` holds ONE of these under its lock and owns only the
/// impure edges (network, persistence, throttle, WatchedIndex notify).
///
/// TITLE-LEVEL, deliberately. SIMKL's `completed` status is a WHOLE-TITLE signal (the user finished the
/// movie, or every episode of the show), and `SIMKLService.list` hands back title-level `SIMKLListEntry`
/// rows, so unlike Trakt's `/sync/watched/shows` (which carries a per-season / per-episode breakdown) there
/// is no episode grain to harvest here. A completed show badges its cover; that is the whole of #143's
/// cover-badge goal for SIMKL.
struct SIMKLWatchedCore: Equatable {
    /// The watched id set (imdb + tmdb identity forms), unioned into `WatchedIndex` when import is on.
    private(set) var watchedIDs: Set<String> = []

    init(watchedIDs: Set<String> = []) { self.watchedIDs = watchedIDs }

    /// Fold one pull's completed-list entries (movies + shows + anime legs, already flattened by
    /// `SIMKLService.list`) into an identity set, through the SAME `WatchedFold` rule Trakt uses: imdb plus
    /// the canonical and typed tmdb forms, so a cover keyed by either identity matches (#143). Anime rows
    /// are series to the detail page (`SIMKLListEntry.type == "series"`), so they fold as shows.
    static func identities(from entries: [SIMKLListEntry]) -> Set<String> {
        var out = Set<String>()
        for entry in entries {
            let forms = WatchedFold.identities(imdb: entry.imdb, tmdb: entry.tmdb,
                                               isSeries: entry.type == "series")
            for id in forms { out.insert(id) }
        }
        return out
    }

    /// REPLACE the whole set with a fresh pull (a pull is a replace, not a merge, matching Trakt). Returns
    /// true only when the set actually changed, so the caller persists + notifies WatchedIndex just once.
    mutating func replace(with next: Set<String>) -> Bool {
        guard next != watchedIDs else { return false }
        watchedIDs = next
        return true
    }

    /// Disconnect / sign-out wipe: drop the imported badges immediately so one account's SIMKL history can
    /// never badge covers for the next account that connects on this device.
    mutating func wipe() { watchedIDs = [] }

    /// The set the read path may see. Empty unless import is on: importing another service's history into
    /// VortX's watched badges is opt-in, so an import-off shadow answers as if it held nothing.
    func visibleIDs(importOn: Bool) -> Set<String> { importOn ? watchedIDs : [] }
}
