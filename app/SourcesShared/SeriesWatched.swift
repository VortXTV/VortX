import Foundation

/// Show- and season-level "fully watched" rollup for a SERIES (issue #143).
///
/// Individual episode marking works via the engine's WatchedBitField (owner profile) or the overlay's
/// `watchedVideoIds`, so per-episode ticks are correct. But the SHOW-level poster badge gates on the
/// engine's `LibraryItem.times_watched`, which a per-episode / per-season mark never bumps (only a
/// whole-item mark or a play-to-threshold does, see stremio-core `mark_video_as_watched` vs `player`), so
/// a series whose episodes were all MARKED (not played) never flipped to watched. And any rollup derived
/// from the video list must NOT require episodes that have not aired yet or Season 0 specials, or a show
/// you have actually finished can never reach 100%.
///
/// This computes the REQUIRED episode-id set for a series: aired, regular-season (non-special) episodes
/// only, and answers "is every required episode in the watched set?". Pure, read-only, chrome-agnostic;
/// the tvOS and iOS/Mac detail views feed the result into `WatchedIndex` so the poster badge is consistent
/// everywhere. Never writes engine / profile / disk state.
enum SeriesWatched {
    /// Episode ids a series must have watched to count as fully watched: REGULAR-SEASON (season != 0)
    /// episodes that have ALREADY AIRED (a parseable `released` date at or before `now`). An episode with
    /// no parseable air date is treated as UNAIRED and excluded from the requirement (issue #143), so a
    /// not-yet-dated future episode can never hold a finished show back. Season 0 specials are never
    /// required. A `nil` season is treated as a regular season (1), never a special.
    static func requiredEpisodeIDs(in videos: [CoreVideo], asOf now: Date = Date()) -> Set<String> {
        var required = Set<String>()
        for video in videos {
            guard (video.season ?? 1) != 0 else { continue }            // Season 0 specials are not required
            guard let aired = airDate(video.released), aired <= now else { continue }   // skip unaired / undated
            required.insert(video.id)
        }
        return required
    }

    /// True when EVERY required (aired, regular-season) episode is in `watched`. Guarded on a non-empty
    /// requirement, so a series with no aired regular episodes (or no parseable air dates at all) never
    /// reads watched — the badge only ever falls back to its existing engine/overlay signal, never a false
    /// positive.
    static func isFullyWatched(videos: [CoreVideo], watched: Set<String>, asOf now: Date = Date()) -> Bool {
        let required = requiredEpisodeIDs(in: videos, asOf: now)
        guard !required.isEmpty else { return false }
        return required.isSubset(of: watched)
    }

    /// Season-scoped twin: every AIRED episode of `season` watched. Asks about that season itself, so a
    /// special season (0) uses its own aired episodes. Not currently surfaced as its own badge; kept here
    /// so the season and series rollups live in one place and stay consistent.
    static func isSeasonFullyWatched(_ season: Int, videos: [CoreVideo],
                                     watched: Set<String>, asOf now: Date = Date()) -> Bool {
        let required = Set(videos
            .filter { ($0.season ?? 1) == season }
            .filter { airDate($0.released).map { $0 <= now } ?? false }
            .map(\.id))
        guard !required.isEmpty else { return false }
        return required.isSubset(of: watched)
    }

    /// Tolerant `released` parser: full ISO-8601 (with or without fractional seconds), else a bare
    /// `yyyy-MM-dd` calendar day (midnight UTC). Returns nil when absent or unparseable, which the callers
    /// treat as unaired. A fresh day-formatter per call (DateFormatter is not thread-safe); the ISO
    /// formatters are the shared reused instances from CoreModels.
    private static func airDate(_ released: String?) -> Date? {
        guard let released, !released.isEmpty else { return nil }
        if let d = ISO8601DateFormatter.epg.date(from: released) { return d }
        if let d = ISO8601DateFormatter.epgFractional.date(from: released) { return d }
        guard released.count >= 10 else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(released.prefix(10)))
    }
}
