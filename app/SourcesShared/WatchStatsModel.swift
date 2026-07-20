import Foundation
import Combine

/// Personal watch statistics ("year in review"), computed READ ONLY from the active profile's existing
/// watch signal. This never dispatches an engine action, never writes an engine / profile / library
/// document, and never mutates watched state: it only READS what is already persisted.
///
/// Sources, honoring the per-profile history invariant (the same split `WatchedIndex` uses):
///  - OWNER profile (`ProfileStore.activeUsesEngineHistory`): the engine's own persisted library buckets
///    (`library_recent.json` / `library.json` in `CoreBridge.storageDirURL`), which carry the whole library
///    plus each title's `state.overallTimeWatched` (the engine's authoritative total watch time in ms),
///    `timesWatched`, and `lastWatched`. A bucket is consumed only when its `uid` matches the live ctx uid
///    (`CoreBridge.currentUID()`), mirroring the engine's own `LibraryBucket::merge_bucket` uid refusal, so a
///    stale bucket from a previous account can never leak into the new account's numbers. The live published
///    `library` / `continueWatching` models fill in any freshly touched title whose bucket persist has not
///    landed yet.
///  - OVERLAY profile: only that profile's private overlay (`ProfileStore.watch`), NEVER the account/engine
///    set. The overlay carries a per-title `durationMs` + watched-episode list, from which watch time is
///    estimated.
///
/// Genres are not stored in the library (a Stremio `LibraryItem` has no genres), so the genre breakdown is a
/// best-effort join against whatever `CoreMeta` the app already holds in memory (Home rows, Discover, search,
/// the open detail). Titles with no locally known genre simply do not contribute to the genre card; the
/// screen labels the card accordingly. Everything is fail-soft: a missing / unreadable bucket contributes
/// nothing rather than crashing.
///
/// Threading mirrors `WatchedIndex`: the public entry points run on the main queue (the view calls `load()`
/// from a main-actor `.task`, and the scope `didSet` fires on the main thread), the bucket JSON is parsed on
/// a utility queue, and every `@Published` mutation is hopped back to the main queue. Not a `@MainActor`
/// type on purpose, so the GCD hop stays isolation-clean.
final class WatchStatsModel: ObservableObject {
    /// The computed stats for the selected scope (nil until the first load completes).
    @Published private(set) var stats: WatchStats?
    /// Years present in the watch history, newest first, for the "year in review" scope picker.
    @Published private(set) var availableYears: [Int] = []
    /// True while the first load reads + parses the buckets off the main queue. Starts true so the very
    /// first frame (before `load()` runs from `.task`) shows the loader, not a false "no history" state.
    @Published private(set) var isLoading = true

    /// nil = all time; otherwise a specific calendar year. Re-filters the cached records in memory (cheap),
    /// so switching scope never re-reads the buckets.
    @Published var selectedYear: Int? {
        didSet { if selectedYear != oldValue { recompute() } }
    }

    /// The normalized records for the active profile, cached so a scope change is an in-memory recompute.
    private var records: [WatchRecord] = []
    /// metaId (and, where known, the title's imdb video id) -> genres, joined from in-memory `CoreMeta`.
    private var genresByID: [String: [String]] = [:]

    /// How many titles to surface in the "most watched" list and the internal work caps.
    private static let topTitlesLimit = 8
    private static let topGenresLimit = 6

    // MARK: Load

    /// Read the active profile's watch history (read only) and compute stats. Safe to call repeatedly;
    /// it fully rebuilds. The owner path parses the bucket JSON on a utility queue and republishes on main.
    func load() {
        isLoading = true
        genresByID = Self.buildGenreIndex()

        guard ProfileStore.shared.activeUsesEngineHistory else {
            // Overlay profile: its private overlay only, never the engine buckets.
            records = Self.overlayRecords(ProfileStore.shared.watch)
            finishLoad()
            return
        }

        // Owner profile. Capture the live state on main, then parse the persisted buckets off-main.
        let expectedUID = CoreBridge.shared.currentUID()
        let liveLibrary = CoreBridge.shared.library?.catalog ?? []
        let liveCW = CoreBridge.shared.continueWatching
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let bucket = Self.bucketRecords(expectedUID: expectedUID)
            let merged = Self.mergeLive(into: bucket, library: liveLibrary, continueWatching: liveCW)
            DispatchQueue.main.async {
                guard let self else { return }
                self.records = merged
                self.finishLoad()
            }
        }
    }

    /// Common tail of both load paths: derive the scope years and compute the selected scope.
    private func finishLoad() {
        let years = Set(records.compactMap { $0.lastWatched.map { Self.calendar.component(.year, from: $0) } })
        availableYears = years.sorted(by: >)
        // Drop a stale selection that no longer exists in this profile's data.
        if let year = selectedYear, !availableYears.contains(year) { selectedYear = nil }
        isLoading = false
        recompute()
    }

    /// Filter the cached records to the selected scope and compute. Pure + in-memory; runs on main.
    private func recompute() {
        let scoped: [WatchRecord]
        if let year = selectedYear {
            scoped = records.filter { r in
                guard let d = r.lastWatched else { return false }
                return Self.calendar.component(.year, from: d) == year
            }
        } else {
            scoped = records
        }
        let label = selectedYear.map(String.init) ?? String(localized: "All time")
        stats = WatchStats.compute(records: scoped, genresByID: genresByID, scopeLabel: label,
                                   topTitles: Self.topTitlesLimit, topGenres: Self.topGenresLimit)
    }

    // MARK: Owner path (engine buckets, read only)

    /// Full watch records from BOTH persisted engine buckets, gated on `expectedUID` exactly like
    /// `WatchedIndex.bucketWatchedIDs`. `library.json` (the whole library) is read first, then
    /// `library_recent.json` (the fresher subset) overwrites shared ids. Fail-soft: an absent / unreadable /
    /// uid-mismatched file contributes nothing. READ ONLY.
    private static func bucketRecords(expectedUID: String?) -> [String: WatchRecord] {
        var out: [String: WatchRecord] = [:]
        let dir = CoreBridge.storageDirURL
        for name in ["library.json", "library_recent.json"] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let items = root["items"] as? [String: Any] else { continue }
            // Absent / null uid decodes to nil and matches only the signed-out state, the engine's own
            // equality semantics.
            guard (root["uid"] as? String) == expectedUID else { continue }
            for (id, value) in items {
                guard let item = value as? [String: Any],
                      let record = makeRecord(fromBucketItem: id, item) else { continue }
                out[id] = record
            }
        }
        return out
    }

    /// Normalize one persisted `LibraryItem` JSON into a `WatchRecord`, or nil to skip it (internal docs,
    /// non VOD types, nothing watched). Never throws.
    private static func makeRecord(fromBucketItem id: String, _ item: [String: Any]) -> WatchRecord? {
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

    /// Union in any live library / Continue-Watching title MISSING from the persisted buckets (a fresh mark
    /// whose async bucket persist has not landed). Watch time is estimated from the live state, since the
    /// published `CoreCWItem` carries no `overallTimeWatched`. Titles already in the buckets are left on the
    /// authoritative bucket value.
    private static func mergeLive(into bucket: [String: WatchRecord],
                                  library: [CoreCWItem], continueWatching: [CoreCWItem]) -> [WatchRecord] {
        var out = bucket
        for item in (library + continueWatching) {
            guard out[item.id] == nil, isVODType(item.type), !isInternalID(item.id) else { continue }
            guard item.isWatched || item.state.timeOffset > 0 else { continue }
            let isSeries = item.type == "series"
            let durationS = item.state.duration / 1000
            let seconds = isSeries
                ? durationS * Double(max(item.state.timesWatched, 1))       // episodes * per-episode duration
                : (item.isWatched ? durationS : item.resumeSeconds)         // finished movie vs in-progress
            out[item.id] = WatchRecord(id: item.id, type: item.type, name: item.name, poster: item.poster,
                                       watchSeconds: clampSeconds(seconds), plays: item.state.timesWatched,
                                       lastWatched: nil)
        }
        return Array(out.values)
    }

    // MARK: Overlay path (private overlay, read only)

    /// Records from an overlay profile's private watch overlay. Watch time is estimated: the overlay stores a
    /// per-title `durationMs` (the last-played video's duration) and the set of watched episode ids, so a
    /// series is `watchedEpisodes * durationMs` and a movie is its full duration when finished or its resume
    /// offset while in progress. READ ONLY (never writes the overlay).
    private static func overlayRecords(_ watch: [String: WatchEntry]) -> [WatchRecord] {
        var out: [WatchRecord] = []
        for (metaId, entry) in watch {
            guard isVODType(entry.type), !isInternalID(metaId) else { continue }
            let isSeries = entry.type == "series"
            let durationS = Double(entry.durationMs) / 1000
            let episodes = entry.watchedVideoIds.count
            let seconds: Double
            let plays: Int
            if isSeries {
                seconds = durationS * Double(episodes)
                plays = episodes
            } else {
                let finished = entry.progress >= 0.9 || entry.watchedVideoIds.contains(entry.videoId ?? metaId)
                seconds = finished ? durationS : Double(entry.timeOffsetMs) / 1000
                plays = (finished || seconds > 0) ? 1 : 0
            }
            guard seconds > 0 || plays > 0 else { continue }
            out.append(WatchRecord(id: metaId, type: entry.type, name: entry.name, poster: entry.poster,
                                   watchSeconds: clampSeconds(seconds), plays: plays,
                                   lastWatched: parseISODate(entry.lastWatched)))
        }
        return out
    }

    // MARK: Genre index (best-effort, in-memory CoreMeta only)

    /// Join whatever `CoreMeta` the app already holds in memory into a metaId -> genres lookup. This is the
    /// only local source of genres (the library stores none), so coverage is partial by design: it reflects
    /// titles whose catalog card or detail the user has loaded. Never fetches. MUST be called on the main
    /// queue (it reads CoreBridge's published state); `load()` is, so this is too.
    private static func buildGenreIndex() -> [String: [String]] {
        var index: [String: [String]] = [:]
        func add(_ id: String?, _ genres: [String]) {
            guard let id, !id.isEmpty, !genres.isEmpty, index[id] == nil else { return }
            index[id] = genres
        }
        let bridge = CoreBridge.shared
        for row in bridge.boardRows {
            for meta in row.items { add(meta.id, meta.genres ?? []) }
        }
        for meta in bridge.discover?.items ?? [] { add(meta.id, meta.genres ?? []) }
        for meta in bridge.searchResults { add(meta.id, meta.genres ?? []) }
        if let meta = bridge.metaDetails?.meta {
            add(meta.id, meta.genres)
            add(meta.behaviorHints?.defaultVideoId, meta.genres)
        }
        return index
    }

    // MARK: Small helpers

    /// A shared calendar for year bucketing (UTC so a title's year matches its stored `lastWatched` day
    /// regardless of the device time zone).
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

    /// The VOD content types this screen counts. Live TV / channels and the internal "other" docs are
    /// excluded (they are not "titles watched").
    private static func isVODType(_ type: String) -> Bool { type == "movie" || type == "series" }

    /// The app's own internal library docs (e.g. the `stremiox:profiles` sync doc) must never count.
    private static func isInternalID(_ id: String) -> Bool { id.hasPrefix("stremiox:") || id.hasPrefix("vortx:") }

    /// Corruption guard: keep a finite, non-negative value and cap it at an absurdly high ceiling so a single
    /// bad accumulator can never dominate the total. Real values sit far below this.
    private static func clampSeconds(_ seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(seconds, 500_000 * 3600)
    }

    private static func doubleValue(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return 0
    }

    private static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    /// Tolerant ISO-8601 parse for a stored `lastWatched`. The engine writes up to nanosecond fractional
    /// seconds (e.g. "2026-05-13T05:50:02.786798226Z"), which the standard fractional formatter rejects, so
    /// try both ISO forms first and finally fall back to the leading calendar day. Only the year is load-
    /// bearing here (year-in-review scoping), so pinning a UTC day when the full timestamp is over-precise is
    /// enough; nil when absent / unparseable. Mirrors `SeriesWatched.airDate`.
    private static func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let d = ISO8601DateFormatter.epgFractional.date(from: raw) { return d }
        if let d = ISO8601DateFormatter.epg.date(from: raw) { return d }
        guard raw.count >= 10 else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(raw.prefix(10)))
    }
}

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
