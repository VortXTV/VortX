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
/// The main actor owns requests, cached records and a serialized presentation mailbox. Bucket parsing
/// remains on a utility queue. A request retains its original profile/account authority through every
/// asynchronous hop; observation can enqueue newer intent but cannot enter a nested Published setter.
@MainActor
final class WatchStatsModel: ObservableObject {
    private struct Presentation {
        var authority: Authority?
        var stats: WatchStats?
        var availableYears: [Int] = []
        var isLoading = true
        var selectedYear: Int?
    }

    // One Published assignment keeps the four visible values coherent. The existing view reads these
    // properties and assigns selectedYear; it does not use the old synthesized $property publishers.
    @Published private var presentation = Presentation()
    var stats: WatchStats? { visiblePresentation.stats }
    var availableYears: [Int] { visiblePresentation.availableYears }
    var isLoading: Bool { visiblePresentation.isLoading }
    var selectedYear: Int? {
        get { visiblePresentation.selectedYear }
        set {
            guard desired.selectedYear != newValue else { return }
            desired.selectedYear = newValue
            retireStaleState()
            recompute()
            publish()
        }
    }

    private var visiblePresentation: Presentation {
        // A Published willSet observer may retire the owner without calling this model. The setter
        // can still physically store its old value before returning; public reads must refuse that
        // value's ORIGINAL authority even before the bounded drain gets its next repair opportunity.
        guard let authority = presentation.authority, !Self.authorityIsCurrent(authority) else {
            return presentation
        }
        var unavailable = Presentation()
        unavailable.isLoading = false
        return unavailable
    }

    /// All fields are captured before the first publication or asynchronous hop. The legacy UID remains
    /// optional: nil is an exact identity here, while the bucket reader retains its signed-out policy.
    private struct Authority {
        let epoch: UUID
        let credential: CredentialScopeRegistry.Capture
        let profileID: UUID?
        let profile: LegacyWatchOwnership.ProfileBinding?
        let keychainAccount: String
        let usesEngineHistory: Bool
        let target: PlaybackMutationTarget
    }

    private struct LoadRequest {
        let generation = UUID()
        let authority: Authority
    }

    /// The normalized records for the active profile, cached so a scope change is an in-memory recompute.
    private var records: [WatchRecord] = []
    /// metaId (and, where known, the title's imdb video id) -> genres, joined from in-memory `CoreMeta`.
    private var genresByID: [String: [String]] = [:]
    private var cachedAuthority: Authority?
    private var activeRequest: LoadRequest?
    private var libraryTask: Task<Void, Never>?
    private var ownershipSubscription: AnyCancellable?

    private var desired = Presentation()
    private var publicationPending = false
    private var isPublishing = false
    private var publicationScheduled = false

    init() {
        // A settled profile/auth boundary also retires an already visible result, without asking the
        // view to issue another load. Admission checks use the epoch directly and do not wait for this
        // scheduled notification. A delayed notification cannot retire a newer, still-current request.
        ownershipSubscription = NotificationCenter.default.publisher(for: LegacyWatchOwnership.sessionDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                dispatchPrecondition(condition: .onQueue(.main))
                MainActor.assumeIsolated {
                    guard let self, self.retireStaleState() else { return }
                    self.publish()
                }
            }
    }

    private static func profileBinding(_ profiles: ProfileStore) -> LegacyWatchOwnership.ProfileBinding? {
        profiles.active.map { .init(id: $0.id, isOwner: $0.isOwner, usesOwnAccount: $0.usesOwnAccount) }
    }

    private static func captureAuthority() -> Authority? {
        guard let epoch = LegacyWatchOwnership.captureApplicationEpoch() else { return nil }
        let profiles = ProfileStore.shared
        let credential = CredentialScopeRegistry.shared.capture()
        let authority = Authority(epoch: epoch, credential: credential, profileID: profiles.activeID,
                                  profile: profileBinding(profiles), keychainAccount: profiles.activeKeychainAccount,
                                  usesEngineHistory: profiles.activeUsesEngineHistory,
                                  target: PlaybackMutationTarget.capture(core: .shared))
        return authorityIsCurrent(authority) ? authority : nil
    }

    private static func authorityIsCurrent(_ authority: Authority) -> Bool {
        let profiles = ProfileStore.shared
        guard LegacyWatchOwnership.applicationEpochIsCurrent(authority.epoch),
              CredentialScopeRegistry.shared.isCurrent(authority.credential),
              profiles.activeID == authority.profileID, profileBinding(profiles) == authority.profile,
              profiles.activeKeychainAccount == authority.keychainAccount,
              profiles.activeUsesEngineHistory == authority.usesEngineHistory else { return false }
        guard authority.target.stillOwnsCurrentContext(core: .shared) else { return false }
        return LegacyWatchOwnership.applicationEpochIsCurrent(authority.epoch)
            && CredentialScopeRegistry.shared.isCurrent(authority.credential)
    }

    private func isCurrent(_ request: LoadRequest) -> Bool {
        activeRequest?.generation == request.generation && Self.authorityIsCurrent(request.authority)
    }

    /// Only transient presentation/cache state is retired; no history, account or epoch is mutated.
    @discardableResult
    private func retireStaleState() -> Bool {
        var changed = false
        if let request = activeRequest, !Self.authorityIsCurrent(request.authority) {
            activeRequest = nil
            libraryTask?.cancel()
            libraryTask = nil
            desired.isLoading = false
            if cachedAuthority == nil { desired.authority = nil }
            changed = true
        }
        if let authority = cachedAuthority, !Self.authorityIsCurrent(authority) {
            records = []
            genresByID = [:]
            cachedAuthority = nil
            desired.authority = activeRequest?.authority
            desired.stats = nil
            desired.availableYears = []
            changed = true
        }
        return changed
    }

    // MARK: Load

    /// Read the active profile's watch history (read only) and compute stats. Safe to call repeatedly;
    /// it fully rebuilds. The owner path parses the bucket JSON on a utility queue and republishes on main.
    func load() {
        // Retire the previous generation before any observer can run. Capture the ORIGINAL authority
        // now, including UID and same-owner epoch, rather than borrowing it after the library wait.
        activeRequest = nil
        libraryTask?.cancel()
        libraryTask = nil
        retireStaleState()
        guard let authority = Self.captureAuthority() else {
            records = []
            genresByID = [:]
            cachedAuthority = nil
            desired.authority = nil
            desired.stats = nil
            desired.availableYears = []
            desired.isLoading = false
            publish()
            return
        }
        let request = LoadRequest(authority: authority)
        activeRequest = request
        genresByID = Self.buildGenreIndex()
        // Keep the original cache lease while a same-context reload leaves its prior stats visible.
        if cachedAuthority == nil { desired.authority = authority }
        desired.isLoading = true
        publish()
        guard isCurrent(request) else { abandon(request); return }
        guard let playback = CoreBridge.shared.nativePlaybackSnapshot() else {
            guard isCurrent(request) else { abandon(request); return }
            records = []
            cachedAuthority = authority
            desired.authority = authority
            desired.stats = nil
            desired.isLoading = false
            publish()
            return
        }
        let loaded = (playback["history"]?.array ?? []).compactMap { row -> WatchRecord? in
            guard case .string(let id) = row["metaId"], case .string(let type) = row["type"],
                  WatchStats.isVODType(type), !WatchStats.isInternalID(id) else { return nil }
            let duration = (try? row["durationMs"]?.decode(Double.self)) ?? 0
            let offset = (try? row["offsetMs"]?.decode(Double.self)) ?? 0
            let played = (try? row["timesWatched"]?.decode(Int.self)) ?? 0
            let episodes = playback["watchedVideoIdsByTitle"]?[id]?.array?.count ?? 0
            let plays = type == "series" ? episodes : played
            let timestamp = (try? row["updatedAt"]?.decode(Double.self)) ?? 0
            // Same estimate as the existing live-state reader; the native query does not claim
            // an accumulated watch-time counter. Saved membership never enters this history.
            let seconds = max(offset, duration * Double(plays)) / 1000
            return WatchRecord(id: id, type: type, name: (try? row["name"]?.decode(String.self)) ?? id,
                               poster: try? row["poster"]?.decode(String.self), watchSeconds: WatchStats.clampSeconds(seconds),
                               plays: plays, lastWatched: timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil)
        }
        finishLoad(loaded, request: request)
    }

    private func abandon(_ request: LoadRequest) {
        guard activeRequest?.generation == request.generation else { return }
        activeRequest = nil
        libraryTask = nil
        desired.isLoading = false
        if cachedAuthority == nil { desired.authority = nil }
        retireStaleState()
        publish()
    }

    /// Common tail: accept only original-owner results, derive years, then use the newest scope intent.
    private func finishLoad(_ loaded: [WatchRecord], request: LoadRequest) {
        guard isCurrent(request) else { abandon(request); return }
        records = loaded
        cachedAuthority = request.authority
        libraryTask = nil
        let years = Set(records.compactMap { $0.lastWatched.map { WatchStats.calendar.component(.year, from: $0) } })
        desired.availableYears = years.sorted(by: >)
        // Drop a stale selection only when this profile's accepted data proves it unavailable.
        if let year = desired.selectedYear, !desired.availableYears.contains(year) { desired.selectedYear = nil }
        desired.isLoading = false
        recompute()
        publish()
    }

    /// Filter the cached records to the selected scope and compute. Pure + in-memory; runs on main.
    private func recompute() {
        desired.authority = cachedAuthority ?? activeRequest?.authority
        let scoped: [WatchRecord]
        if let year = desired.selectedYear {
            scoped = records.filter { r in
                guard let d = r.lastWatched else { return false }
                return WatchStats.calendar.component(.year, from: d) == year
            }
        } else {
            scoped = records
        }
        let label = desired.selectedYear.map(String.init) ?? String(localized: "All time")
        desired.stats = WatchStats.compute(records: scoped, genresByID: genresByID, scopeLabel: label,
                                          topTitles: WatchStats.topTitlesLimit, topGenres: WatchStats.topGenresLimit)
    }

    // MARK: Serialized observer publication

    private func publish() {
        publicationPending = true
        guard !isPublishing, !publicationScheduled else { return }
        schedulePublication()
    }

    private func drainPublications() {
        guard !isPublishing else { return }
        isPublishing = true
        var remaining = 2
        while publicationPending && remaining > 0 {
            publicationPending = false
            retireStaleState()
            // No request/scope entry point writes presentation directly. Nested observers only
            // replace desired and mark pending, so this setter cannot overwrite newer final storage.
            presentation = desired
            // Also repair a profile/auth change made by an observer that did not call this model.
            if retireStaleState() { publicationPending = true }
            remaining -= 1
        }
        isPublishing = false
        guard publicationPending, !publicationScheduled else { return }
        schedulePublication()
    }

    private func schedulePublication() {
        publicationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publicationScheduled = false
            self.drainPublications()
        }
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
    nonisolated private static func bucketRecords(expectedUID: String?) -> [String: WatchRecord] {
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
    nonisolated private static func mergeLive(into bucket: [String: WatchRecord],
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
