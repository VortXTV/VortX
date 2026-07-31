import Foundation

/// Pure, dependency-free identity folding shared by the external watched-history imports (Trakt via
/// `TraktSyncEngine`, SIMKL via `SIMKLWatchedShadow`).
///
/// This is the ONE place the shadow's id language is spelled. It was extracted verbatim out of
/// `TraktSyncEngine.pullWatched` so the issue #143 contract - "a title watched on an external service must
/// match its catalog cover by the cover's imdb AND its tmdb identity" - lives in a single Foundation-only
/// unit a standalone test can exercise. `TraktSyncEngine` / `SIMKLWatchedShadow` cannot compile alone (they
/// pull in their auth / service / WatchedIndex layers), so without this seam the identity rule had no
/// executable regression guard. Behaviour is byte-for-byte what `pullWatched` did inline before; only the
/// seam moved, and then generalized so SIMKL folds its completed list through the exact same rule rather
/// than a second copy that could drift.
///
/// `TraktWatchedFold` remains a name for this type (typealias below) so every Trakt call site and its
/// standalone test stay byte-compatible after the rename.
enum WatchedFold {

    /// Every shadow identity form for a title carrying `imdb` (a `tt…` id) and/or `tmdb` (a positive
    /// database id): the imdb id when present, plus the canonical `tmdb:<id>` form the hub covers use AND
    /// the typed `tmdb:movie:<id>` / `tmdb:tv:<id>` shape some metas carry, so a cover keyed by EITHER
    /// identity matches the plain `ids.contains(item.id)` read.
    ///
    /// Capturing ONLY imdb dropped every tmdb-keyed cover and any record without an imdb id, so a title
    /// watched externally showed as unwatched (issue #143). Order is imdb first (preferred), then the tmdb
    /// forms. Empty only when NEITHER id was given, in which case the title cannot be matched to any cover
    /// and is simply absent from the shadow - never a guessed identity. A non-positive `tmdb` (0 / negative,
    /// never a real id) contributes nothing. `isSeries` picks the typed tmdb form so a movie and a show
    /// sharing a tmdb number never collide.
    static func identities(imdb: String?, tmdb: Int?, isSeries: Bool) -> [String] {
        var out: [String] = []
        if let imdb, !imdb.isEmpty { out.append(imdb) }
        if let tmdb, tmdb > 0 {
            out.append("tmdb:\(tmdb)")
            out.append(isSeries ? "tmdb:tv:\(tmdb)" : "tmdb:movie:\(tmdb)")
        }
        return out
    }

    /// The Trakt call-site adapter: extracts imdb + tmdb out of a Trakt `ids` JSON bag (an NSNumber tmdb
    /// from JSONSerialization, or defensively a numeric String) and folds them through `identities` above.
    /// Kept exactly as `pullWatched` called it so the Trakt path and its 25-check test are unchanged.
    static func titleIdentities(_ ids: [String: Any], isSeries: Bool) -> [String] {
        identities(imdb: ids["imdb"] as? String, tmdb: intID(ids["tmdb"]), isSeries: isSeries)
    }

    /// The one place the per-episode key shape is spelled, so the pull and the read can never drift apart.
    /// `|` cannot appear in an imdb / `tmdb:<id>` identity, so the key is unambiguous.
    static func episodeKey(_ identity: String, _ season: Int, _ episode: Int) -> String {
        "\(identity)|\(season)|\(episode)"
    }

    /// Coerce a JSON id value (an NSNumber from JSONSerialization, or defensively a numeric String) to a
    /// POSITIVE Int, or nil. Used to normalize the tmdb id into a `tmdb:<id>` shadow key. A database id is
    /// always positive, so 0 / negative is rejected.
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

/// The pre-generalization name for the shared fold. Kept so every existing Trakt call site
/// (`TraktSyncEngine`) and the `TraktWatchedFoldTests` runner stay byte-for-byte compatible after the type
/// was renamed and shared with SIMKL.
typealias TraktWatchedFold = WatchedFold
