import Foundation
import Combine

/// Personal watch statistics ("year in review"), computed READ ONLY from the active profile's existing
/// watch signal. This never dispatches an engine action, never writes an engine / profile / library
/// document, and never mutates watched state: it only READS what is already persisted.
///
/// The deterministic aggregation (records -> stats) and record normalization live in the pure,
/// dependency-free `WatchStatsAggregation.swift` (`WatchStats.compute`, `WatchStats.record(fromBucketItem:)`,
/// and the small helpers). This type owns only the ENGINE-COUPLED orchestration: which sources to read and
/// how to keep the screen from going empty for a user who has real history.
///
/// Sources, honoring the per-profile history invariant (the same split `WatchedIndex` uses):
///  - OWNER profile (`ProfileStore.activeUsesEngineHistory`): the engine's OWN current-account history. The
///    precise time comes from the engine's persisted library buckets (`library_recent.json` / `library.json`
///    in `CoreBridge.storageDirURL`), which carry the whole library plus each title's
///    `state.overallTimeWatched` (the engine's authoritative total watch time in ms), `timesWatched`, and
///    `lastWatched`. A bucket is consumed when its `uid` matches the live ctx uid (`CoreBridge.currentUID()`)
///    -- mirroring the engine's own `LibraryBucket::merge_bucket` uid refusal so a PREVIOUS account's bucket
///    never leaks into a DIFFERENT signed-in account's numbers -- OR when signed OUT (no live uid), where the
///    on-disk history is the user's own with no other account to leak from. On TOP of the buckets, the engine's
///    LIVE `library` model (loaded on demand, always the current account) and the Continue-Watching preview are
///    unioned in. That live union is what keeps the screen from going empty when the persisted bucket file is
///    skipped by the uid gate or simply has not been written to disk yet on this device (the engine persists
///    the bucket as an async effect AFTER the library lands in memory) -- it is the SAME engine-owned history
///    that already powers Continue Watching and the watched badges. Watch time for a live-only title is
///    estimated from its live state, since the published `CoreCWItem` carries no `overallTimeWatched`.
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

        // Owner profile. Make sure the engine's OWN current-account library is loaded BEFORE we snapshot the
        // live state: it is the authoritative, account-scoped history that also powers Continue Watching and
        // the watched badges, and it is the fallback that keeps this screen from going empty when the persisted
        // bucket file is skipped by the uid gate (signed out / just-switched account) or has not been written
        // to disk yet on this device. `loadLibraryAndAwait` is idempotent and READ ONLY -- it no-ops when the
        // library is already loaded and never mutates the account. `isLoading` stays true across the await, so
        // the view shows the loader rather than a false "no history" frame.
        Task { @MainActor [weak self] in
            await CoreBridge.shared.loadLibraryAndAwait()
            guard let self else { return }
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
    }

    /// Common tail of both load paths: derive the scope years and compute the selected scope.
    private func finishLoad() {
        let years = Set(records.compactMap { $0.lastWatched.map { WatchStats.calendar.component(.year, from: $0) } })
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
                return WatchStats.calendar.component(.year, from: d) == year
            }
        } else {
            scoped = records
        }
        let label = selectedYear.map(String.init) ?? String(localized: "All time")
        stats = WatchStats.compute(records: scoped, genresByID: genresByID, scopeLabel: label,
                                   topTitles: WatchStats.topTitlesLimit, topGenres: WatchStats.topGenresLimit)
    }

    // MARK: Owner path (engine buckets, read only)

    /// Full watch records from BOTH persisted engine buckets, gated on `expectedUID` like
    /// `WatchedIndex.bucketWatchedIDs`. `library.json` (the whole library) is read first, then
    /// `library_recent.json` (the fresher subset) overwrites shared ids. Fail-soft: an absent / unreadable
    /// file contributes nothing. READ ONLY.
    ///
    /// UID GATE: a bucket persists `{ uid, items }`, where `uid` is the auth user id (null when signed out).
    /// A file whose uid does not match `expectedUID` is skipped so a PREVIOUS account's bucket can never leak
    /// into a DIFFERENT signed-in account's numbers (the engine's own `LibraryBucket::merge_bucket` refusal,
    /// #111). The one relaxation: when signed OUT (`expectedUID == nil`) the on-disk bucket is the user's OWN
    /// last-synced history with no other account to leak from -- and it is the same history the app already
    /// shows in Continue Watching and the watched badges -- so it is accepted rather than dropped.
    private static func bucketRecords(expectedUID: String?) -> [String: WatchRecord] {
        var out: [String: WatchRecord] = [:]
        let dir = CoreBridge.storageDirURL
        for name in ["library.json", "library_recent.json"] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let items = root["items"] as? [String: Any] else { continue }
            let bucketUID = root["uid"] as? String
            guard bucketUID == expectedUID || expectedUID == nil else { continue }
            for (id, value) in items {
                guard let item = value as? [String: Any],
                      let record = WatchStats.record(fromBucketItem: id, item) else { continue }
                out[id] = record
            }
        }
        return out
    }

    /// Union in any live library / Continue-Watching title MISSING from the persisted buckets. This is both
    /// the fresh-mark catch-up (a title whose async bucket persist has not landed) AND the whole-history
    /// fallback when the buckets were skipped by the uid gate or never written on this device: the live
    /// `library` model is the engine's current account, so unioning it keeps the screen showing the same
    /// history that powers Continue Watching and the watched badges. Watch time is estimated from the live
    /// state, since the published `CoreCWItem` carries no `overallTimeWatched`. Titles already in the buckets
    /// are left on the authoritative bucket value.
    private static func mergeLive(into bucket: [String: WatchRecord],
                                  library: [CoreCWItem], continueWatching: [CoreCWItem]) -> [WatchRecord] {
        var out = bucket
        for item in (library + continueWatching) {
            guard out[item.id] == nil, WatchStats.isVODType(item.type), !WatchStats.isInternalID(item.id) else { continue }
            guard item.isWatched || item.state.timeOffset > 0 else { continue }
            let isSeries = item.type == "series"
            let durationS = item.state.duration / 1000
            let seconds = isSeries
                ? durationS * Double(max(item.state.timesWatched, 1))       // episodes * per-episode duration
                : (item.isWatched ? durationS : item.resumeSeconds)         // finished movie vs in-progress
            out[item.id] = WatchRecord(id: item.id, type: item.type, name: item.name, poster: item.poster,
                                       watchSeconds: WatchStats.clampSeconds(seconds), plays: item.state.timesWatched,
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
            guard WatchStats.isVODType(entry.type), !WatchStats.isInternalID(metaId) else { continue }
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
                                   watchSeconds: WatchStats.clampSeconds(seconds), plays: plays,
                                   lastWatched: WatchStats.parseISODate(entry.lastWatched)))
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
}
