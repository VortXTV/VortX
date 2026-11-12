import Foundation

/// Offline downloads: the device-local data model. These types are OS-agnostic and compile on every
/// Apple target, and the UI now lives on every target too (iOS/Mac in SourcesiOS, Apple TV in
/// SourcesTV's DetailView Download button + TVDownloadsView). A download is a
/// physical file on ONE device plus a row in the local JSON index: it is NEVER E2E-synced and NEVER
/// written into a `libraryItem` document. Playback of a downloaded file still flows through the normal
/// engine progress path (via `PlaybackMeta`), so per-profile watch history / Continue Watching keep
/// working exactly as for a streamed source.

/// Lifecycle of one download. `queued` exists for a future concurrency-limited queue (P2); the v1
/// manager starts a task immediately, so a record normally moves queued -> downloading on creation.
enum DownloadState: String, Codable, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

/// Exact unfinished local history eligible to open an indexed copy when connectivity is down.
struct DownloadedContinueWatchingTarget: Equatable {
    let libraryID: String
    let type: String
    let videoID: String
    let resumeSeconds: Double

    init?(
        libraryID: String, type: String, cardVideoID: String?,
        resumeSeconds: Double?, progress: Double, isUpNext: Bool
    ) {
        guard !libraryID.isEmpty, !isUpNext,
              let resumeSeconds, resumeSeconds.isFinite, resumeSeconds > 0 else { return nil }
        if EpisodePlaybackIdentity.usesSeriesLifecycle(type: type) {
            guard let cardVideoID, !cardVideoID.isEmpty, cardVideoID != libraryID else { return nil }
            videoID = cardVideoID
        } else {
            let exactMovieID = cardVideoID ?? libraryID
            guard type == "movie", progress.isFinite, progress >= 0, progress < 0.9,
                  !exactMovieID.isEmpty,
                  !EpisodePlaybackIdentity.isEpisodicContext(
                    type: type, season: nil, episode: nil, videoID: exactMovieID
                  ) else { return nil }
            videoID = exactMovieID
        }
        self.libraryID = libraryID
        self.type = type
        self.resumeSeconds = resumeSeconds
    }

    init?(item: CoreCWItem) {
        guard !item.isFinished else { return nil }
        self.init(libraryID: item.id, type: item.type, cardVideoID: item.state.videoId,
                  resumeSeconds: item.resumeSeconds, progress: item.progress, isUpNext: item.isUpNext)
    }
}

/// A single admission result shared by value copies of the original player request.
@MainActor
final class DownloadedContinueWatchingInitialMount {
    private var admission: Bool?

    func admit(confirmedOffline: Bool, exactCopy: Bool) -> Bool {
        if let admission { return admission }
        let accepted = confirmedOffline && exactCopy
        admission = accepted
        return accepted
    }
}

/// A device-local, provider-verified transition between two canonical series episodes.
struct DownloadSeasonBoundary: Codable, Hashable, Sendable {
    let libraryID: String
    let finaleVideoID: String
    let successorVideoID: String
    let season: Int
    let finaleEpisode: Int
    let tmdbSeriesID: Int
    let tmdbFinaleID: Int
    let tmdbSuccessorID: Int

    enum Refresh: Sendable {
        case verified(DownloadSeasonBoundary)
        case contradicted
        case unavailable

        func replacement(for saved: DownloadSeasonBoundary?) -> DownloadSeasonBoundary? {
            switch self {
            case let .verified(boundary): return boundary
            case .contradicted: return nil
            case .unavailable: return saved
            }
        }
    }

    /// Keep independent authenticated facts even when a different endpoint is unavailable.
    struct RefreshObservations {
        let saved: DownloadSeasonBoundary?
        private var contradicted = false

        init(saved: DownloadSeasonBoundary?) { self.saved = saved }

        mutating func observe(seriesID: Int? = nil, finaleEpisode: Int? = nil,
                              finaleID: Int? = nil, successorID: Int? = nil) {
            guard let saved else { return }
            contradicted = contradicted || (seriesID.map { $0 != saved.tmdbSeriesID } ?? false)
                || (finaleEpisode.map { $0 != saved.finaleEpisode } ?? false)
                || (finaleID.map { $0 != saved.tmdbFinaleID } ?? false)
                || (successorID.map { $0 != saved.tmdbSuccessorID } ?? false)
        }

        var incompleteResult: Refresh { contradicted ? .contradicted : .unavailable }
    }

    enum SeriesID: Sendable {
        case imdb(String)
        case tmdb(Int)

        init?(_ libraryID: String) {
            let imdbDigits = libraryID.utf8.dropFirst(2)
            if libraryID.hasPrefix("tt"), (6...10).contains(imdbDigits.count),
               imdbDigits.allSatisfy({ (48...57).contains($0) }) {
                self = .imdb(libraryID)
            } else if libraryID.hasPrefix("tmdb:"), let id = Int(libraryID.dropFirst(5)),
                      id > 0, id <= Int(Int32.max), libraryID == "tmdb:\(id)" {
                self = .tmdb(id)
            } else {
                return nil
            }
        }
    }

    func matches(_ current: PlaybackMeta, successorVideoID: String) -> Bool {
        guard let title = SeriesID(libraryID) else { return false }
        if case let .tmdb(id) = title, id != tmdbSeriesID { return false }
        return libraryID == current.libraryId && finaleVideoID == current.videoId
            && season == current.season && finaleEpisode == current.episode
            && self.successorVideoID == successorVideoID
            && tmdbSeriesID > 0 && tmdbFinaleID > 0 && tmdbSuccessorID > 0
            && tmdbFinaleID != tmdbSuccessorID
    }
}

/// A malformed optional proof must never make an existing download index unreadable.
@propertyWrapper
struct DecodedDownloadSeasonBoundary: Codable, Hashable, Sendable {
    var wrappedValue: DownloadSeasonBoundary?
}

extension KeyedDecodingContainer {
    func decode(_ type: DecodedDownloadSeasonBoundary.Type, forKey key: Key) throws -> DecodedDownloadSeasonBoundary {
        .init(wrappedValue: try? decodeIfPresent(DownloadSeasonBoundary.self, forKey: key))
    }
}

extension KeyedEncodingContainer {
    mutating func encode(_ value: DecodedDownloadSeasonBoundary, forKey key: Key) throws {
        try encodeIfPresent(value.wrappedValue, forKey: key)
    }
}

struct DownloadSeasonSeries: Decodable {
    struct Season: Decodable {
        let id: Int
        let seasonNumber: Int
        let episodeCount: Int
    }

    struct ExternalIDs: Decodable { let imdbId: String? }

    let id: Int
    let seasons: [Season]
    let externalIds: ExternalIDs?

    func matches(_ title: DownloadSeasonBoundary.SeriesID, requestedID: Int) -> Bool {
        guard id == requestedID else { return false }
        switch title {
        case let .tmdb(id): return self.id == id
        case let .imdb(id): return externalIds?.imdbId == id
        }
    }

    func season(_ number: Int) -> Season? {
        let matches = seasons.filter { $0.seasonNumber == number }
        guard matches.count == 1, let match = matches.first, match.id > 0, match.episodeCount > 0,
              seasons.filter({ $0.id == match.id }).count == 1 else { return nil }
        return match
    }
}

struct DownloadSeasonDetails: Decodable {
    struct Episode: Decodable {
        let id: Int
        let showId: Int
        let seasonNumber: Int
        let episodeNumber: Int
    }

    let id: Int
    let seasonNumber: Int
    let episodes: [Episode]

    func completeEpisodes(seriesID: Int, season: DownloadSeasonSeries.Season) -> [Episode]? {
        guard id == season.id, seasonNumber == season.seasonNumber,
              episodes.count == season.episodeCount,
              Set(episodes.map(\.id)).count == episodes.count else { return nil }
        let ordered = episodes.sorted { $0.episodeNumber < $1.episodeNumber }
        guard ordered.enumerated().allSatisfy({ index, episode in
            episode.id > 0 && episode.showId == seriesID && episode.seasonNumber == seasonNumber
                && episode.episodeNumber == index + 1
        }) else { return nil }
        return ordered
    }
}

/// Retain the exact origin, proof, and selected file through deferred playback admission.
struct DownloadSeasonRolloverWitness {
    let originID: UUID
    let originMeta: PlaybackMeta
    let proof: DownloadSeasonBoundary
    let successorID: UUID

    func accepts(_ candidate: DownloadRecord, in records: [DownloadRecord],
                 fileExists: (DownloadRecord) -> Bool) -> Bool {
        guard candidate.id == successorID, candidate.season != originMeta.season,
              let origin = records.first(where: { $0.id == originID }), origin.state == .completed,
              origin.playbackMeta == originMeta, origin.seasonBoundary == proof else { return false }
        let current = DownloadRecord.playableSuccessor(after: originMeta, seasonBoundary: proof,
                                                        in: records, fileExists: fileExists)
        return current?.id == successorID && current?.playbackMeta == candidate.playbackMeta
    }
}

/// One offline download. Identifiable + Codable so it both persists in `index.json` and drives the
/// SwiftUI list directly. All playback-relevant ids (`contentId`/`videoId`/`season`/`episode`) are the
/// SAME values the streaming play path uses, so `playbackMeta` rebuilds a byte-equivalent `PlaybackMeta`
/// and the engine records progress against the right library item.
struct DownloadRecord: Codable, Identifiable, Hashable {
    /// Stable id; also the on-disk filename stem (`<id>.<ext>`), so the file is found without a path
    /// being persisted (paths move between app-container relocations; a relative stem does not).
    let id: UUID

    /// `PlaybackMeta.libraryId`, the movie/series id (the libraryItem `_id`). For a movie this equals
    /// `videoId`; for an episode it is the series id.
    let contentId: String
    /// `PlaybackMeta.videoId`, the movie id, or `imdbId:season:episode` for an episode.
    let videoId: String
    /// The original `PlaybackMeta.type`. The beta lifecycle fence derives behavior without rewriting this
    /// persisted value or migrating the download index.
    let type: String

    let name: String
    let poster: String?
    let season: Int?
    let episode: Int?

    /// The add-on / source label this download came from (`stream.name`), for display.
    let sourceName: String?
    /// Quality signature (StreamRanking.signature) shown on the row + re-recorded on play, so a CW
    /// resume of a downloaded title keeps quality continuity like a streamed one.
    let qualityText: String?

    /// True when this was a torrent-to-disk download (loopback `127.0.0.1:11470/{hash}/{fileIdx}` via
    /// the `.default` foreground session). Debrid/direct/HTTP are false (true `.background` session).
    /// NOTE: a *finished* download always plays from the LOCAL file with `isTorrent: false`; this flag
    /// only records HOW it was fetched.
    let isTorrent: Bool

    /// `behaviorHints.proxyHeaders.request` the source declared, applied to the download request, since
    /// some CDNs 403 without a specific Referer / User-Agent (the player applies the same headers).
    let headers: [String: String]?

    /// The resolved remote URL the download fetched (debrid/direct https, or the loopback torrent URL).
    /// Kept for diagnostics / a future re-download; playback never uses it once `state == .completed`.
    let remoteURL: String

    /// On-disk filename (`<id>.<ext>`), relative to the Downloads directory. The full `URL` is rebuilt
    /// from the current container path so a relocated container can't strand the file. Unused for an HLS
    /// offline download (those live in a system-managed `.movpkg`, tracked by `hlsRelativePath` instead).
    let localFilename: String

    /// HLS offline downloads (iOS only, via `AVAssetDownloadTask`) land in a system-managed `.movpkg`
    /// bundle whose path we do not choose; we persist its path RELATIVE to the home directory (the
    /// container UUID can change between launches) and rebuild the absolute URL on demand. Non-nil only
    /// for a COMPLETED HLS download; nil for a progressive/torrent file download and for an in-flight HLS
    /// download (which is identified by its `.m3u8` `remoteURL` until it finishes). Its presence is what
    /// routes offline playback through AVPlayer instead of libmpv (libmpv can't open a `.movpkg`).
    var hlsRelativePath: String?

    var bytesTotal: Int64
    var bytesDone: Int64
    var state: DownloadState
    let addedAt: Date
    /// Human-readable failure reason when `state == .failed`; nil otherwise.
    var errorText: String?

    /// Honest note that this record is a batch auto-retry (#119): set when a batch-queued episode's first
    /// source failed and the coordinator swapped in the next-best source for it. Surfaces in the row
    /// subtitle so the user sees the episode was retried, not silently swapped. nil for every normal record.
    /// Optional + defaulted, so an index written before this field decodes it as nil (Codable-compatible).
    var retryNote: String?

    /// The live `URLSessionTask.taskIdentifier` of the transfer filling this record, persisted so a
    /// relaunch can map a still-running background task (byte-download OR HLS asset) back to its record
    /// and re-wire pause/cancel to the real task. `taskIdentifier` is stable for the life of a task on a
    /// background session and survives app suspend/relaunch (the OS keeps the task running). Nil for a
    /// record with no live task (queued / paused / completed / failed). This is a RECONNECT HINT only:
    /// reconciliation also falls back to matching `localFilename` (byte) / `id` (HLS) via `taskDescription`,
    /// so a stale or missing identifier never strands a good download.
    var taskIdentifier: Int?

    /// Missing on older indexes. This carries no path, account identifier, provider URL or token.
    @DecodedDownloadSeasonBoundary var seasonBoundary: DownloadSeasonBoundary? = nil

    /// A completed HLS offline download (its media is a `.movpkg`, playable only by AVPlayer).
    var isHLSOffline: Bool { hlsRelativePath != nil }

    init(id: UUID = UUID(), contentId: String, videoId: String, type: String, name: String,
         poster: String?, season: Int?, episode: Int?, sourceName: String?, qualityText: String?,
         isTorrent: Bool, headers: [String: String]?, remoteURL: String, localFilename: String,
         hlsRelativePath: String? = nil,
         bytesTotal: Int64 = 0, bytesDone: Int64 = 0, state: DownloadState = .queued,
         addedAt: Date = Date(), errorText: String? = nil, retryNote: String? = nil, taskIdentifier: Int? = nil) {
        self.id = id
        self.contentId = contentId
        self.videoId = videoId
        self.type = type
        self.name = name
        self.poster = poster
        self.season = season
        self.episode = episode
        self.sourceName = sourceName
        self.qualityText = qualityText
        self.isTorrent = isTorrent
        self.headers = headers
        self.remoteURL = remoteURL
        self.localFilename = localFilename
        self.hlsRelativePath = hlsRelativePath
        self.bytesTotal = bytesTotal
        self.bytesDone = bytesDone
        self.state = state
        self.addedAt = addedAt
        self.errorText = errorText
        self.retryNote = retryNote
        self.taskIdentifier = taskIdentifier
    }

    /// Rebuild the `PlaybackMeta` for play-from-local. Identical to the meta the streaming play path
    /// builds, so the engine + account record progress against the same library item, Continue
    /// Watching / resume keep working offline.
    var playbackMeta: PlaybackMeta {
        PlaybackMeta(libraryId: contentId, videoId: videoId, type: type,
                     name: name, poster: poster, season: season, episode: episode)
    }

    /// Backward-compatible beta lifecycle classification. Computed fields do not alter `index.json`, and
    /// the raw catalog type remains available to API and storage call sites.
    var usesSeriesLifecycle: Bool {
        EpisodePlaybackIdentity.usesSeriesLifecycle(type: type)
    }

    /// Display title, episode-aware (matches the streaming episode title format).
    var displayTitle: String {
        if usesSeriesLifecycle, let s = season, let e = episode {
            return "\(name)  ·  S\(s)E\(e)"
        }
        return name
    }

    /// A show-like record groups under its durable title id, while a movie remains a standalone video.
    var groupingKey: String {
        usesSeriesLifecycle ? "series:\(contentId)" : "movie:\(videoId)"
    }

    /// Season-then-episode ascending. Unknown numbers sort last, then insertion time stabilizes ties.
    static func episodeOrder(_ a: DownloadRecord, _ b: DownloadRecord) -> Bool {
        let seasonA = a.season ?? Int.max, seasonB = b.season ?? Int.max
        if seasonA != seasonB { return seasonA < seasonB }
        let episodeA = a.episode ?? Int.max, episodeB = b.episode ?? Int.max
        if episodeA != episodeB { return episodeA < episodeB }
        return a.addedAt < b.addedAt
    }

    static func isManagedProgressiveFilename(_ filename: String, id: UUID) -> Bool {
        let name = filename as NSString
        return !filename.contains("/") && !filename.contains("\\")
            && UUID(uuidString: name.deletingPathExtension) == id
            && !name.pathExtension.isEmpty
            && name.pathExtension.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value)
            }
    }

    static func isSafeHLSPackageRelativePath(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "movpkg"
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Play only the exact durable title and video. Coordinates protect against stale ID reuse.
    func matchesPlayback(_ target: PlaybackMeta) -> Bool {
        contentId == target.libraryId && videoId == target.videoId
            && type == target.type
            && season == target.season && episode == target.episode
    }

    /// A missing local file cannot block another completed copy of the same exact video.
    static func playableCopy(
        of target: PlaybackMeta, in records: [Self], fileExists: (Self) -> Bool
    ) -> Self? {
        records.first { $0.state == .completed && $0.matchesPlayback(target) && fileExists($0) }
    }

    static func offlineContinueWatchingCopy(
        for target: DownloadedContinueWatchingTarget, in records: [Self],
        fileExists: (Self) -> Bool
    ) -> Self? {
        let matches = records.filter {
            $0.state == .completed && $0.contentId == target.libraryID
                && $0.type == target.type && $0.videoId == target.videoID
        }
        if target.type == "movie" {
            return matches.first { $0.season == nil && $0.episode == nil && fileExists($0) }
        }
        guard let first = matches.first,
              let numbers = EpisodePlaybackIdentity.provenEpisodeNumbers(season: first.season, episode: first.episode),
              matches.allSatisfy({ $0.season == first.season && $0.episode == first.episode }) else { return nil }
        // The indexed coordinates must agree when the exact video ID also carries this title's numbers.
        // An opaque video ID still needs its own exact indexed row with valid stored coordinates.
        let prefix = "\(target.libraryID):"
        if target.videoID.hasPrefix(prefix) {
            let suffix = target.videoID.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false)
            if suffix.count == 2, let season = Int(suffix[0]), let episode = Int(suffix[1]) {
                guard season == numbers.season && episode == numbers.episode else { return nil }
            }
        }
        return matches.first(where: fileExists)
    }

    /// A stored file URL is a hint for one indexed copy. Never open or resolve that path itself.
    static func rememberedPlayableCopy(
        of target: PlaybackMeta, rememberedFile: URL,
        in records: [Self], fileExists: (Self) -> Bool
    ) -> Self? {
        guard rememberedFile.isFileURL, [nil, "", "localhost"].contains(rememberedFile.host),
              !target.libraryId.isEmpty, !target.videoId.isEmpty else { return nil }
        let path = rememberedFile.pathComponents
        let matches = records.filter { copy in
            guard copy.state == .completed, copy.matchesPlayback(target) else { return false }
            if let relative = copy.hlsRelativePath {
                guard isSafeHLSPackageRelativePath(relative) else { return false }
                let components = relative.split(separator: "/").map(String.init)
                return path.suffix(components.count).elementsEqual(components)
            }
            return isManagedProgressiveFilename(copy.localFilename, id: copy.id)
                && path.suffix(3).elementsEqual(["Application Support", "Downloads", copy.localFilename])
        }
        guard matches.count == 1, let match = matches.first, fileExists(match) else { return nil }
        return match
    }

    /// Gate the local handoff after its player has admitted a genuine EOF event.
    static func permitsDownloadedAdvance(position: Double?, duration: Double) -> Bool {
        guard let position, position.isFinite, position > 0,
              duration.isFinite, duration > 0 else { return false }
        return position >= duration * 0.9
    }

    /// The index can identify a candidate for verification, but cannot prove the current season ended.
    static func seasonRolloverSuccessorID(after current: PlaybackMeta, in records: [Self]) -> String? {
        guard current.usesSeriesLifecycle, DownloadSeasonBoundary.SeriesID(current.libraryId) != nil,
              let season = current.season, season > 0, season < Int.max,
              let episode = current.episode, episode > 0,
              current.videoId == "\(current.libraryId):\(season):\(episode)" else { return nil }
        let successorID = "\(current.libraryId):\(season + 1):1"
        let series = records.filter { $0.contentId == current.libraryId && $0.usesSeriesLifecycle }
        guard !series.contains(where: { $0.season == season && ($0.episode ?? 0) > episode }),
              !series.contains(where: { $0.season == season && $0.episode == episode && $0.videoId != current.videoId }),
              !series.contains(where: { $0.season == season + 1 && $0.episode == 1 && $0.videoId != successorID }),
              series.contains(where: {
                  $0.videoId == successorID && $0.type == current.type && $0.season == season + 1
                      && $0.episode == 1 && $0.state != .failed
              }) else { return nil }
        return successorID
    }

    /// A newly indexed canonical later episode retires earlier stored finale evidence even offline.
    func contradictsSeasonBoundary(of origin: Self) -> Bool {
        guard origin.seasonBoundary != nil, usesSeriesLifecycle,
              contentId == origin.contentId, type == origin.type,
              let season, season == origin.season, let episode, let earlier = origin.episode,
              episode > earlier else { return false }
        return videoId == "\(contentId):\(season):\(episode)"
    }

    static func playableSuccessor(
        after current: PlaybackMeta, seasonBoundary: DownloadSeasonBoundary? = nil,
        in records: [Self], fileExists: (Self) -> Bool
    ) -> Self? {
        guard current.usesSeriesLifecycle, let season = current.season, season >= 0,
              let episode = current.episode, episode >= 0, episode < Int.max else { return nil }
        let candidates = records.filter {
            $0.state == .completed && $0.usesSeriesLifecycle && $0.contentId == current.libraryId
                && $0.videoId != current.videoId && $0.season == season && $0.episode == episode + 1
                && fileExists($0)
        }
        if !candidates.isEmpty {
            // If two distinct video identities claim the coordinate, don't guess a provider alias.
            guard Set(candidates.map(\.videoId)).count == 1 else { return nil }
            return candidates.first
        }
        guard let seasonBoundary,
              let successorID = seasonRolloverSuccessorID(after: current, in: records),
              seasonBoundary.matches(current, successorVideoID: successorID) else { return nil }
        return records.first {
            $0.contentId == current.libraryId && $0.type == current.type && $0.videoId == successorID
                && $0.season == season + 1 && $0.episode == 1 && $0.state == .completed && fileExists($0)
        }
    }

    /// 0...1 download progress; 0 until a total is known (a torrent's total is unknown up front).
    var fractionComplete: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1, max(0, Double(bytesDone) / Double(bytesTotal)))
    }
}
