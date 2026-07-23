import Foundation

/// Pure, dependency-free identity folding for the Trakt watched-history import (see `TraktSyncEngine`).
///
/// This is the ONE place the shadow's id language is spelled. It was extracted verbatim out of
/// `TraktSyncEngine.pullWatched` so the issue #143 contract - "a title watched on Trakt must match its
/// catalog cover by the cover's imdb AND its tmdb identity" - lives in a single Foundation-only unit a
/// standalone test can exercise. `TraktSyncEngine` itself cannot compile alone (it pulls in TraktAuth /
/// TraktService / WatchedIndex / TraktRatingsStore), so without this seam the identity rule had no
/// executable regression guard. Behaviour is byte-for-byte what `pullWatched` did inline before; only the
/// seam moved.
enum TraktWatchedFold {

    /// Every shadow identity form for one title's Trakt `ids` bag: the imdb `tt…` id when present, plus the
    /// canonical `tmdb:<id>` form the hub covers use AND the typed `tmdb:movie:<id>` / `tmdb:tv:<id>` shape
    /// some metas carry, so a cover keyed by EITHER identity matches the plain `ids.contains(item.id)` read.
    ///
    /// Capturing ONLY imdb dropped every tmdb-keyed cover and any Trakt record without an imdb id, so a
    /// title watched on Trakt showed as unwatched (issue #143). Order is imdb first (preferred), then the
    /// tmdb forms. Empty only when Trakt gave NEITHER id, in which case the title cannot be matched to any
    /// cover and is simply absent from the shadow - never a guessed identity. `isSeries` (known from the
    /// endpoint the row came from) picks the typed tmdb form so a movie and a show sharing a tmdb number
    /// never collide.
    static func titleIdentities(_ ids: [String: Any], isSeries: Bool) -> [String] {
        var out: [String] = []
        if let imdb = ids["imdb"] as? String, !imdb.isEmpty { out.append(imdb) }
        if let tmdb = intID(ids["tmdb"]) {
            out.append("tmdb:\(tmdb)")
            out.append(isSeries ? "tmdb:tv:\(tmdb)" : "tmdb:movie:\(tmdb)")
        }
        return out
    }

    /// The one place the per-episode key shape is spelled, so the pull and the read can never drift apart.
    /// `|` cannot appear in an imdb / `tmdb:<id>` identity, so the key is unambiguous.
    static func episodeKey(_ identity: String, _ season: Int, _ episode: Int) -> String {
        "\(identity)|\(season)|\(episode)"
    }

    /// Coerce a Trakt JSON id value (an NSNumber from JSONSerialization, or defensively a numeric String)
    /// to a POSITIVE Int, or nil. Used to normalize the tmdb id into a `tmdb:<id>` shadow key. A database
    /// id is always positive, so 0 / negative is rejected.
    static func intID(_ value: Any?) -> Int? {
        if let n = value as? Int, n > 0 { return n }
        if let s = value as? String, let n = Int(s), n > 0 { return n }
        return nil
    }

    /// Coerce a season / episode NUMBER to a NON-NEGATIVE Int. Deliberately NOT `intID`, which demands a
    /// POSITIVE value because it validates database ids: season 0 is the real, common specials season, and
    /// `intID` would reject it, silently dropping every special's tick. Numbers and ids are different
    /// domains with different valid ranges, so they get different coercions.
    static func nonNegativeInt(_ value: Any?) -> Int? {
        if let n = value as? Int, n >= 0 { return n }
        if let s = value as? String, let n = Int(s), n >= 0 { return n }
        return nil
    }
}
