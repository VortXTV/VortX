import Foundation

/// The PURE, dependency-free core of Watch Stats: the normalized watch record, the computed stats, and the
/// deterministic aggregation that turns records into the numbers the screen renders. Nothing here touches the
/// engine, the profile store, the file system, or any `@Published` state, so it is trivially unit-testable in
/// isolation (see `Tests/WatchStatsAggregation`). `WatchStatsModel` owns the engine-coupled orchestration
/// (which buckets / overlay / live models to read) and funnels everything through these pure helpers.
///
/// Kept Foundation-only ON PURPOSE: it carries its OWN tolerant ISO-8601 parser rather than reusing the
/// engine's `ISO8601DateFormatter.epg*` extensions (CoreModels.swift), so the aggregation compiles and runs
/// with no app types in scope.

// MARK: - Value types

/// One title's normalized, read-only watch record. Pure value type.
struct WatchRecord {
    let id: String
    let type: String          // "movie" | "series"
    let name: String
    let poster: String?
    /// Total time spent watching this title, in seconds (engine `overallTimeWatched` for the owner, an
    /// estimate for overlay / live-only titles).
    let watchSeconds: Double
    /// Finished plays for a movie, or watched-episode count for a series.
    let plays: Int
    /// The last time this title was watched, for year-in-review scoping (nil when unknown).
    let lastWatched: Date?

    var isSeries: Bool { type == "series" }
    var isMovie: Bool { type == "movie" }
}

/// One genre's share of watch time within the current scope.
struct GenreStat: Identifiable {
    let name: String
    let seconds: Double
    var id: String { name }
}

/// The single title the user sank the most into (the "longest binge").
struct BingeStat {
    let name: String
    let type: String
    let seconds: Double
    let episodes: Int
}

/// One row of the "most watched" list.
struct TitleStat: Identifiable {
    let id: String
    let name: String
    let type: String
    let poster: String?
    let seconds: Double
    let plays: Int
}

/// The fully computed stats for one scope (all time, or one year). Pure output; the view only formats it.
struct WatchStats {
    let scopeLabel: String
    let totalWatchSeconds: Double
    let titlesCount: Int
    let moviesCount: Int
    let seriesCount: Int
    let episodesCount: Int
    let topGenres: [GenreStat]
    /// How many scoped titles had a locally known genre (so the view can caption the genre card honestly).
    let genreCoverage: Int
    let longestBinge: BingeStat?
    let topTitles: [TitleStat]

    /// True when there is anything at all to show.
    var hasData: Bool { titlesCount > 0 }

    /// Compute the stats over already-scoped records. Pure and deterministic (no I/O), so it is trivially
    /// testable and cheap enough to run on every scope change.
    static func compute(records: [WatchRecord], genresByID: [String: [String]],
                        scopeLabel: String, topTitles: Int, topGenres: Int) -> WatchStats {
        let movies = records.filter(\.isMovie)
        let series = records.filter(\.isSeries)
        let totalSeconds = records.reduce(0) { $0 + $1.watchSeconds }
        let episodes = series.reduce(0) { $0 + max($1.plays, 0) }

        // Top genres, weighted by watch time so a genre the user spent more hours on ranks higher.
        var genreSeconds: [String: Double] = [:]
        var covered = 0
        for record in records {
            guard let genres = genresByID[record.id], !genres.isEmpty else { continue }
            covered += 1
            // Split the title's time evenly across its genres so a 3-genre title does not triple-count.
            let share = record.watchSeconds / Double(genres.count)
            for genre in genres { genreSeconds[genre, default: 0] += share }
        }
        let genres = genreSeconds
            .map { GenreStat(name: $0.key, seconds: $0.value) }
            .filter { $0.seconds > 0 }
            .sorted { $0.seconds > $1.seconds }
            .prefix(topGenres)

        // Longest binge: the series with the most watched episodes (tiebreak on time). With no series, the
        // movie with the most watch time stands in.
        let binge: BingeStat?
        if let topSeries = series.max(by: { ($0.plays, $0.watchSeconds) < ($1.plays, $1.watchSeconds) }),
           topSeries.plays > 0 {
            binge = BingeStat(name: topSeries.name, type: topSeries.type,
                              seconds: topSeries.watchSeconds, episodes: topSeries.plays)
        } else if let topMovie = movies.max(by: { $0.watchSeconds < $1.watchSeconds }), topMovie.watchSeconds > 0 {
            binge = BingeStat(name: topMovie.name, type: topMovie.type,
                              seconds: topMovie.watchSeconds, episodes: 0)
        } else {
            binge = nil
        }

        // Most watched, ranked by time spent.
        let ranked = records
            .filter { $0.watchSeconds > 0 || $0.plays > 0 }
            .sorted { ($0.watchSeconds, Double($0.plays)) > ($1.watchSeconds, Double($1.plays)) }
            .prefix(topTitles)
            .map { TitleStat(id: $0.id, name: $0.name, type: $0.type, poster: $0.poster,
                             seconds: $0.watchSeconds, plays: $0.plays) }

        return WatchStats(
            scopeLabel: scopeLabel,
            totalWatchSeconds: totalSeconds,
            titlesCount: records.count,
            moviesCount: movies.count,
            seriesCount: series.count,
            episodesCount: episodes,
            topGenres: Array(genres),
            genreCoverage: covered,
            longestBinge: binge,
            topTitles: Array(ranked)
        )
    }
}

// MARK: - Pure record normalization + helpers

extension WatchStats {
    /// How many titles to surface in the "most watched" list and the internal work caps.
    static let topTitlesLimit = 8
    static let topGenresLimit = 6

    /// A shared calendar for year bucketing (UTC so a title's year matches its stored `lastWatched` day
    /// regardless of the device time zone).
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

    /// The VOD content types this screen counts. Live TV / channels and the internal "other" docs are
    /// excluded (they are not "titles watched").
    static func isVODType(_ type: String) -> Bool { type == "movie" || type == "series" }

    /// The app's own internal library docs (e.g. the `stremiox:profiles` sync doc) must never count.
    static func isInternalID(_ id: String) -> Bool { id.hasPrefix("stremiox:") || id.hasPrefix("vortx:") }

    /// Corruption guard: keep a finite, non-negative value and cap it at an absurdly high ceiling so a single
    /// bad accumulator can never dominate the total. Real values sit far below this.
    static func clampSeconds(_ seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(seconds, 500_000 * 3600)
    }

    static func doubleValue(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return 0
    }

    static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    /// Normalize one persisted `LibraryItem` JSON into a `WatchRecord`, or nil to skip it (internal docs,
    /// non VOD types, nothing watched). Never throws. Pure: takes the already-decoded JSON dictionary.
    static func record(fromBucketItem id: String, _ item: [String: Any]) -> WatchRecord? {
        let type = (item["type"] as? String) ?? ""
        guard isVODType(type), !isInternalID(id) else { return nil }
        let state = (item["state"] as? [String: Any]) ?? [:]
        let overallMs = doubleValue(state["overallTimeWatched"])
        let timesWatched = intValue(state["timesWatched"])
        let flaggedWatched = intValue(state["flaggedWatched"])
        // Keep only titles the user has actually engaged with: real watch time, a finished play / watched
        // episode, or a watched-from-catalog mark. A bare library add (never played) contributes nothing.
        guard overallMs > 0 || timesWatched > 0 || flaggedWatched > 0 else { return nil }
        let name = (item["name"] as? String) ?? id
        let poster = item["poster"] as? String
        let last = parseISODate(state["lastWatched"] as? String)
        return WatchRecord(id: id, type: type, name: name, poster: poster,
                           watchSeconds: clampSeconds(overallMs / 1000),
                           plays: timesWatched, lastWatched: last)
    }

    // Self-contained ISO-8601 formatters (mirrors CoreModels' `epg`/`epgFractional` but kept local so this
    // file has no app dependency). `static let` so the parse reuses one instance per form.
    private static let isoPlain = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Tolerant ISO-8601 parse for a stored `lastWatched`. The engine writes up to nanosecond fractional
    /// seconds (e.g. "2026-05-13T05:50:02.786798226Z"), which the standard fractional formatter rejects, so
    /// try both ISO forms first and finally fall back to the leading calendar day. Only the year is load-
    /// bearing here (year-in-review scoping), so pinning a UTC day when the full timestamp is over-precise is
    /// enough; nil when absent / unparseable.
    static func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let d = isoFractional.date(from: raw) { return d }
        if let d = isoPlain.date(from: raw) { return d }
        guard raw.count >= 10 else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(raw.prefix(10)))
    }
}
