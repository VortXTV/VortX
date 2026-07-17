import Foundation

/// Read side of the per-episode Trakt watched shadow: turns `TraktSyncEngine`'s
/// `<showIdentity>|<season>|<episode>` keys back into the app's own opaque video ids, so a series screen
/// can union them into the episode watched set it already renders from.
///
/// WHY A TRANSLATION LAYER. The two sides speak different id languages and neither should learn the
/// other's. Trakt speaks (show, season number, episode number). The app speaks `CoreVideo.id`, an opaque
/// string minted by whichever meta add-on served the series (Cinemeta's `tt…:S:E` is only the common
/// case, not a contract). Parsing a video id's format to reach season/episode would hard-code an add-on's
/// private convention and break the moment a series comes from a differently-shaped catalog. Instead we
/// read the `season` / `episode` fields `CoreVideo` already carries and look the numbers up, so this works
/// for every id scheme without knowing any of them.
///
/// AUTHORITY (read this before widening the callers). The VortX account owns watched state; Trakt is an
/// optional mirror. Everything here is ADDITIVE and read-only:
///   - It only ever ADDS video ids to a set the caller already computed from VortX state. The union is
///     monotonic, so Trakt can put a tick ON an episode VortX never saw, and can NEVER take one off an
///     episode VortX recorded. There is no direction in which a Trakt answer overrides VortX.
///   - It writes nothing: no engine `libraryItem`, no profile overlay, no disk. Same invariant the
///     title-level shadow holds (see `TraktSyncEngine`'s POISON note).
///   - It must NOT feed a RESUME decision. A resume position is VortX's own live state about this device's
///     user; a Trakt "watched" flag on the same episode is a weaker, staler claim from another system.
///     Letting the union answer "is this episode watched?" in the resume branch would let Trakt delete the
///     user's half-finished episode and skip them forward. The detail screens therefore keep their resume
///     guard on the LOCAL set and use the union only to pick the next UNSTARTED episode. If you add a
///     caller, preserve that split.
enum TraktEpisodeShadow {

    /// The subset of `videos` that Trakt records as watched, as the app's own video ids, ready to union
    /// into a series' watched set. Empty when import is off, when nothing has been pulled, or when this
    /// show's identity does not match anything Trakt gave us.
    ///
    /// `showIdentity` is the series' meta id (`tt0944947`, `tmdb:1399`, `tmdb:tv:1399`, …). The pull side
    /// indexes every identity form Trakt returned for a show, so whichever form this catalog uses matches
    /// without any normalization here.
    static func watchedVideoIDs(showIdentity: String, videos: [CoreVideo]) -> Set<String> {
        // Fast path: one lock + one emptiness check for the overwhelmingly common case (import off, or
        // never pulled), instead of a lookup per episode of the series.
        guard TraktSyncEngine.shared.hasEpisodeShadow() else { return [] }
        var found = Set<String>()
        for video in videos {
            // An episode with no season/episode numbers cannot be addressed in Trakt's language, so it is
            // simply absent (no tick) rather than guessed at. `season` nil is treated as season 1, matching
            // how `SeriesWatched` reads a nil season as a regular season rather than a special.
            guard let episode = video.episode else { continue }
            if TraktSyncEngine.shared.shadowWatchedEpisode(showIdentity: showIdentity,
                                                           season: video.season ?? 1,
                                                           episode: episode) {
                found.insert(video.id)
            }
        }
        return found
    }
}
