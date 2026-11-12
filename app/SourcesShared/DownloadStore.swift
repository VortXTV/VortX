import Foundation
import SwiftUI

/// Device-local persistence for offline downloads. The index is a JSON file at
/// `Application Support/Downloads/index.json`; the media files sit alongside it at
/// `Application Support/Downloads/<id>.<ext>`. The directory is marked excluded-from-iCloud-backup
/// (downloaded media is large + re-downloadable, and the OS would otherwise back it up / purge it under
/// pressure in surprising ways).
///
/// This store is intentionally NOT synced (no VortX-account / E2E write): a download is a physical file
/// on one device, and syncing the LIST to a device that lacks the file is misleading. It also NEVER
/// touches `libraryItem` documents; a download is a local file plus this local index, nothing more.
@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    /// Newest-first, for direct binding into the SwiftUI list.
    @Published private(set) var records: [DownloadRecord] = []

    private let fileManager = FileManager.default
    /// Bare progress callbacks are coalesced across every active download. Publishing one array snapshot at
    /// most twice per second prevents unrelated rows from re-rendering for each delegate callback.
    private var pendingProgressRecords: [UUID: DownloadRecord] = [:]
    private var progressPublishTask: Task<Void, Never>?
    private var seasonBoundaryRequests: Set<UUID> = []

    init() {
        ensureDirectory()
        load()
    }

    // MARK: Locations

    /// `Application Support/Downloads`, created on demand and excluded from backup. `nonisolated static`
    /// so the background URLSession's off-main `didFinishDownloadingTo` delegate can resolve the same
    /// directory WITHOUT hopping to the main actor (pure FileManager path math, no shared mutable state).
    /// The instance `directory` below delegates to it so there is a single source of truth.
    nonisolated static var downloadsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    private var directory: URL { Self.downloadsDirectory }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// Absolute file URL for a record's media, rebuilt from the CURRENT container path so a relocated
    /// app container never strands a stored absolute path.
    func fileURL(for record: DownloadRecord) -> URL {
        // A completed HLS offline download lives in a system-managed .movpkg whose path we persist RELATIVE
        // to the home dir (the container UUID can change between launches); rebuild it against the CURRENT
        // home dir. Progressive/torrent downloads live flat in the Downloads dir by filename.
        if let rel = record.hlsRelativePath {
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(rel)
        }
        return directory.appendingPathComponent(record.localFilename)
    }

    /// Off-main destination resolver for a known media filename (`<id>.<ext>`). Lets the background
    /// URLSession delegate recover a download's destination after an app relaunch wiped the in-memory
    /// task->destination map. Pure path math, so it is `nonisolated`.
    nonisolated static func fileURL(forFilename filename: String) -> URL {
        downloadsDirectory.appendingPathComponent(filename)
    }

    /// Ensure the CURRENT-container Downloads directory exists, then mark it excluded from backup. THROWS on a
    /// real create failure (unlike the private instance `ensureDirectory()`, which logs + swallows) so the
    /// background URLSession delegate can surface a directory-creation fault at the move step instead of a
    /// later opaque -3000 "cannot create file". `nonisolated static` so the off-main delegate can call it with
    /// no main-actor hop. Downloads save FLAT into this root (see `fileURL(forFilename:)`), so creating the
    /// root is the correct target. H20-FIX contributed by a VortX subreddit user (credited in the changelog).
    nonisolated static func ensureDownloadsDirectoryExists() throws {
        let dir = downloadsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var mutable = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
        #if os(iOS)
        // A background download can COMPLETE while the device is LOCKED (a backgrounded or overnight transfer).
        // Under the default file-protection class, creating/writing the file while locked fails with
        // NSURLErrorCannotCreateFile (-3000) even with ample free space, which is one cause of the reported
        // iPhone/iPad download failure. Downgrade the Downloads dir to CompleteUntilFirstUserAuthentication:
        // still protected before the first unlock, but writable while locked afterwards, which suits
        // non-sensitive media and lets a locked-device download land. New files inherit the dir's class.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
        #endif
    }

    /// True when the media file for a completed record actually exists on disk (guards play-from-local
    /// against a row whose file was purged out from under us).
    func fileExists(for record: DownloadRecord) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: record).path)
    }

    private func ensureDirectory() {
        let dir = directory
        // Do NOT swallow this: on iOS the Application Support dir is NOT auto-created, and a silent failure
        // here was the opaque "cannot create file" the owner hit (the directory simply never existed when
        // the background delegate moved the temp file in). Route through the shared helper so the
        // CompleteUntilFirstUserAuthentication protection class is applied from init onward (a locked-device
        // completion otherwise trips -3000); log a real create fault so it is diagnosable instead of vanishing.
        do { try Self.ensureDownloadsDirectoryExists() }
        catch { NSLog("%@", "[downloads] could not create Downloads dir at \(dir.path): \(error.localizedDescription)") }
    }

    /// Mark the directory excluded from iCloud/iTunes backup. Best-effort; a failure here is non-fatal
    /// (the feature still works, the files just aren't flagged).
    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder.downloads.decode([DownloadRecord].self, from: data) else { return }
        records = decoded.sorted { $0.addedAt > $1.addedAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder.downloads.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: CRUD

    func record(id: UUID) -> DownloadRecord? { records.first { $0.id == id } }

    func playableDownload(id: UUID, expected: PlaybackMeta) -> AppleDownloadedPlayback? {
        guard let current = record(id: id), current.state == .completed,
              current.playbackMeta == expected, let url = validatedPlaybackURL(for: current) else { return nil }
        return AppleDownloadedPlayback(record: current, url: url)
    }

    // The index cannot reconstruct the source facts required by the Kids stream filters.
    func playableDownload(for target: PlaybackMeta) -> AppleDownloadedPlayback? {
        guard ProfileStore.shared.active?.isKids != true else { return nil }
        return DownloadRecord.playableCopy(of: target, in: records, fileExists: hasValidPlaybackFile)
            .flatMap { playableDownload(id: $0.id, expected: $0.playbackMeta) }
    }

    func rememberedPlayableDownload(
        for target: PlaybackMeta, cardVideoID: String?, file: URL
    ) -> AppleDownloadedPlayback? {
        guard ProfileStore.shared.active?.isKids != true else { return nil }
        let episode = EpisodePlaybackIdentity.isEpisodicContext(
            type: target.type, season: target.season, episode: target.episode, videoID: target.videoId
        )
        if episode || cardVideoID != nil {
            guard cardVideoID == target.videoId else { return nil }
        }
        return DownloadRecord.rememberedPlayableCopy(
            of: target, rememberedFile: file, in: records,
            fileExists: hasValidPlaybackFile
        ).flatMap { playableDownload(id: $0.id, expected: $0.playbackMeta) }
    }

    func playableDownloads(libraryID: String, type: String) -> [AppleDownloadedPlayback] {
        guard ProfileStore.shared.active?.isKids != true else { return [] }
        var seen = Set<String>()
        return records.filter {
            $0.contentId == libraryID && $0.type == type && $0.state == .completed
                && ($0.usesSeriesLifecycle || $0.videoId == libraryID) && hasValidPlaybackFile($0)
                && seen.insert($0.videoId).inserted
        }.sorted(by: DownloadRecord.episodeOrder)
            .compactMap { playableDownload(id: $0.id, expected: $0.playbackMeta) }
    }

    func nextPlayableDownload(after current: DownloadRecord) -> AppleDownloadedPlayback? {
        guard ProfileStore.shared.active?.isKids != true else { return nil }
        let saved = record(id: current.id)
        let boundary = saved.flatMap {
            $0.state == .completed && $0.playbackMeta == current.playbackMeta ? $0.seasonBoundary : nil
        }
        guard let next = DownloadRecord.playableSuccessor(after: current.playbackMeta, seasonBoundary: boundary,
                                                           in: records, fileExists: hasValidPlaybackFile),
              var admitted = playableDownload(id: next.id, expected: next.playbackMeta) else { return nil }
        if next.season != current.season {
            guard let boundary else { return nil }
            admitted.seasonRollover = DownloadSeasonRolloverWitness(originID: current.id, originMeta: current.playbackMeta,
                                                                     proof: boundary, successorID: next.id)
        }
        return admitted
    }

    fileprivate func stillAdmitsSeasonRollover(_ witness: DownloadSeasonRolloverWitness,
                                               candidate: DownloadRecord) -> Bool {
        witness.accepts(candidate, in: records, fileExists: hasValidPlaybackFile)
    }

    func refreshSeasonBoundaries(libraryID: String, type: String, owner: PlaybackMutationTarget,
                                 afterEnqueuing added: DownloadRecord? = nil) {
        guard EpisodePlaybackIdentity.usesSeriesLifecycle(type: type) else { return }
        var possibleFinales: [Int: DownloadRecord] = [:]
        var firstEpisodeSeasons: Set<Int> = []
        for candidate in records where candidate.contentId == libraryID && candidate.type == type {
            guard let season = candidate.season, season > 0, season < Int.max,
                  let episode = candidate.episode, episode > 0 else { continue }
            if episode == 1, candidate.state != .failed { firstEpisodeSeasons.insert(season) }
            if episode > (possibleFinales[season]?.episode ?? 0) { possibleFinales[season] = candidate }
        }
        for season in possibleFinales.keys.sorted(by: >) {
            guard seasonBoundaryRequests.count < 2 else { return }
            guard firstEpisodeSeasons.contains(season + 1), let candidate = possibleFinales[season] else { continue }
            if let added, added.id != candidate.id,
               !(added.season == season + 1 && added.episode == 1) { continue }
            refreshSeasonBoundary(for: candidate, owner: owner)
        }
        if added == nil {
            for candidate in records where candidate.contentId == libraryID && candidate.type == type
                && candidate.seasonBoundary != nil {
                guard seasonBoundaryRequests.count < 2 else { return }
                refreshSeasonBoundary(for: candidate, owner: owner)
            }
        }
    }

    func refreshSeasonBoundary(for candidate: DownloadRecord, owner: PlaybackMutationTarget) {
        guard seasonBoundaryRequests.count < 2, !seasonBoundaryRequests.contains(candidate.id),
              let original = record(id: candidate.id), original.playbackMeta == candidate.playbackMeta,
              let season = original.season, season > 0, season < Int.max,
              let episode = original.episode, episode > 0 else { return }
        let id = candidate.id
        let meta = original.playbackMeta
        let saved = original.seasonBoundary
        let stillCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self, !Task.isCancelled, ConnectivityMonitor.shared.launchOffline != nil,
                  !ConnectivityMonitor.shared.isOffline, ProfileStore.shared.active?.isKids != true,
                  owner.stillOwnsCurrentContext(core: CoreBridge.shared),
                  let current = self.record(id: id) else { return false }
            return current.state != .failed && current.playbackMeta == meta && current.seasonBoundary == saved
        }
        let savedMatches = saved?.matches(meta, successorVideoID: "\(meta.libraryId):\(season + 1):1") == true
        guard stillCurrent(), savedMatches || DownloadRecord.seasonRolloverSuccessorID(after: meta, in: records) != nil
        else { return }
        seasonBoundaryRequests.insert(id)
        Task { @MainActor [weak self] in
            defer { self?.seasonBoundaryRequests.remove(id) }
            let result = await TMDBClient.downloadSeasonBoundary(
                libraryID: meta.libraryId, season: season, episode: episode, replacing: saved, stillCurrent: stillCurrent
            )
            guard stillCurrent(), let self else { return }
            let verified = result.replacement(for: saved)
            guard verified != saved else { return }
            // Changed canonical evidence retires the old proof even if the new pair cannot be installed.
            let replacement = verified.flatMap { boundary in
                DownloadRecord.seasonRolloverSuccessorID(after: meta, in: self.records).flatMap { successorID in
                    boundary.matches(meta, successorVideoID: successorID) ? boundary : nil
                }
            }
            guard replacement != saved else { return }
            self.update(id: id) { $0.seasonBoundary = replacement }
        }
    }

    private func hasValidPlaybackFile(_ record: DownloadRecord) -> Bool {
        validatedPlaybackURL(for: record) != nil
    }

    private func validatedPlaybackURL(for record: DownloadRecord) -> URL? {
        if let relative = record.hlsRelativePath {
            #if os(iOS)
            guard DownloadRecord.isSafeHLSPackageRelativePath(relative) else { return nil }
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath()
            let candidate = fileURL(for: record)
            let resolved = candidate.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(home.path + "/"), resolved.pathExtension.lowercased() == "movpkg",
                  let attributes = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  attributes.isDirectory == true, attributes.isSymbolicLink == false,
                  fileManager.isReadableFile(atPath: resolved.path) else { return nil }
            return resolved
            #else
            return nil
            #endif
        }
        guard DownloadRecord.isManagedProgressiveFilename(record.localFilename, id: record.id) else { return nil }
        let candidate = fileURL(for: record)
        let resolved = candidate.resolvingSymlinksInPath()
        let managedDirectory = directory.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent().path == managedDirectory.path,
              resolved.lastPathComponent == record.localFilename,
              let attributes = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink == false,
              let size = attributes.fileSize, size > 0,
              fileManager.isReadableFile(atPath: resolved.path) else { return nil }
        return resolved
    }

    /// True when a completed (or in-flight) download already exists for this exact video; drives the
    /// "Downloaded" / "Downloading" state on a source row so a user can't queue a title twice.
    func hasDownload(videoId: String) -> Bool {
        records.contains { $0.videoId == videoId && $0.state != .failed }
    }

    func upsert(_ record: DownloadRecord) {
        pendingProgressRecords.removeValue(forKey: record.id)
        var next = records
        if let idx = next.firstIndex(where: { $0.id == record.id }) {
            next[idx] = record
        } else {
            next.insert(record, at: 0)
        }
        for index in next.indices where record.contradictsSeasonBoundary(of: next[index]) {
            pendingProgressRecords[next[index].id]?.seasonBoundary = nil
            next[index].seasonBoundary = nil
        }
        records = next
        persist()
    }

    /// Mutate a record in place (progress / state transitions) and persist. No-op if the id is gone
    /// (e.g. the user deleted the row while a late delegate callback arrived).
    /// `persistIndex: false` is for high-frequency PROGRESS ticks (#24): they are coalesced across all active
    /// downloads and published as one array snapshot at most every 0.5s. State transitions remain immediate.
    func update(id: UUID, persistIndex: Bool = true, _ mutate: (inout DownloadRecord) -> Void) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        if !persistIndex {
            var copy = pendingProgressRecords[id] ?? records[idx]
            mutate(&copy)
            pendingProgressRecords[id] = copy
            scheduleProgressPublish()
            return
        }
        var copy = pendingProgressRecords.removeValue(forKey: id) ?? records[idx]
        mutate(&copy)
        records[idx] = copy
        persist()
    }

    private func scheduleProgressPublish() {
        guard progressPublishTask == nil else { return }
        progressPublishTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            self?.publishPendingProgress()
        }
    }

    private func publishPendingProgress() {
        defer { progressPublishTask = nil }
        guard !pendingProgressRecords.isEmpty else { return }
        var next = records
        for (id, pending) in pendingProgressRecords {
            if let idx = next.firstIndex(where: { $0.id == id }) { next[idx] = pending }
        }
        pendingProgressRecords.removeAll(keepingCapacity: true)
        records = next
    }

    /// Remove a record AND its on-disk file. The caller (DownloadManager) is responsible for cancelling
    /// any live URLSession task first.
    func remove(id: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        pendingProgressRecords.removeValue(forKey: id)
        let record = records[idx]
        try? fileManager.removeItem(at: fileURL(for: record))
        records.remove(at: idx)
        persist()
    }

    // MARK: Storage usage

    /// Total bytes of completed downloads currently on disk (sums actual file sizes, not the recorded
    /// totals, so a partially-deleted file reports honestly).
    func totalBytesOnDisk() -> Int64 {
        records.reduce(0) { sum, record in
            let url = fileURL(for: record)
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { return sum }
            return sum + size
        }
    }

    /// Human-readable total storage used, e.g. "3.4 GB".
    func formattedTotalSize() -> String {
        ByteCountFormatter.string(fromByteCount: totalBytesOnDisk(), countStyle: .file)
    }

    /// Recorded byte total for a subset of records (the larger of done/total per record). Reads the INDEX,
    /// not the filesystem, so it is cheap enough to call while rendering a grouped list (a per-group total in
    /// a focus-driven view must not stat the disk on every re-render). Completed items dominate; an in-flight
    /// item contributes its known-so-far bytes. Feeds the per-show folder header size.
    func recordedSize(of records: [DownloadRecord]) -> String {
        let bytes = records.reduce(Int64(0)) { $0 + max($1.bytesDone, $1.bytesTotal) }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Grouping (per-show download folders)

    /// The device's downloads as per-show FOLDERS (one group per series) plus standalone movies, derived on
    /// demand from the flat `records` index. This is a pure DERIVATION: it adds no persisted state and does
    /// NOT change the on-disk layout (files stay flat under the Downloads dir / their system-managed
    /// `.movpkg`), so the relocated-container path rebuild + the off-main destination resolver keep working
    /// unchanged, and nothing here touches a `libraryItem` document.
    ///
    /// GROUP ORDER is newest-activity-first, matching the flat list (`records` is already `addedAt`-desc, so
    /// the first record of each key marks the group's newest activity). WITHIN a show folder the episodes are
    /// sorted by SEASON then EPISODE ascending, regardless of the order they were downloaded in, with any
    /// episode missing a season/episode number sinking to the end (tie-broken oldest-first) so the folder
    /// always reads S1E1, S1E2, S2E1 ... A movie (or a series record carrying no season/episode) forms its own
    /// single-item group and renders as a plain row. Exposed on the store so BOTH the Apple TV downloads
    /// screen and the iOS downloads screen can render the same folders from one source of truth.
    func groupedDownloads() -> [DownloadGroup] {
        var order: [String] = []                       // group keys in newest-first encounter order
        var byKey: [String: [DownloadRecord]] = [:]
        for record in records {
            let key = record.groupingKey
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(record)
        }
        return order.compactMap { key -> DownloadGroup? in
            guard let items = byKey[key], let head = items.first else { return nil }
            let sorted = head.usesSeriesLifecycle ? items.sorted(by: DownloadRecord.episodeOrder) : items
            return DownloadGroup(id: key, title: head.name, poster: head.poster,
                                 type: head.type, records: sorted)
        }
    }

}

/// One admitted physical download. Paths are derived from the current store at each launch.
struct AppleDownloadedPlayback {
    let record: DownloadRecord
    let url: URL
    var consecutiveAutoAdvances = 0
    fileprivate var seasonRollover: DownloadSeasonRolloverWitness?
    var isSeasonRollover: Bool { seasonRollover != nil }
    var macWasFullScreenAtOpen: Bool?
    private let profileID: UUID?
    private let isKids: Bool
    private let owner: PlaybackMutationTarget

    @MainActor init(record: DownloadRecord, url: URL) {
        self.record = record
        self.url = url
        profileID = ProfileStore.shared.activeID
        isKids = ProfileStore.shared.active?.isKids == true
        owner = PlaybackMutationTarget.capture(core: CoreBridge.shared)
    }

    @MainActor func ownsCurrentContext(core: CoreBridge) -> Bool {
        profileID == ProfileStore.shared.activeID
            && isKids == (ProfileStore.shared.active?.isKids == true)
            && owner.stillOwnsCurrentContext(core: core)
    }

    @MainActor func revalidated() -> Self? {
        guard ownsCurrentContext(core: CoreBridge.shared),
              var current = DownloadStore.shared.playableDownload(id: record.id, expected: record.playbackMeta)
        else { return nil }
        if let seasonRollover {
            guard DownloadStore.shared.stillAdmitsSeasonRollover(seasonRollover, candidate: current.record) else { return nil }
            current.seasonRollover = seasonRollover
        }
        current.consecutiveAutoAdvances = consecutiveAutoAdvances
        current.macWasFullScreenAtOpen = macWasFullScreenAtOpen
        return current
    }

    @MainActor func prepareForPlayback(
        core: CoreBridge, displayedResume: Double? = nil, refreshSeasonBoundary: Bool = true
    ) async -> (copy: Self, resume: Double)? {
        guard !Task.isCancelled, let current = revalidated() else { return nil }
        let meta = current.record.playbackMeta
        let resume: Double
        if let displayedResume, displayedResume.isFinite, displayedResume >= 0 {
            resume = displayedResume
        } else if let cached = core.engineResumeSecondsByLibraryId(for: meta), cached.isFinite, cached > 5 {
            resume = cached
        } else if core.usesNativeProfileState {
            resume = await core.nativeResumeSeconds(for: meta, target: current.owner)
        } else {
            resume = ProfileStore.shared.resumeOffset(for: meta)
        }
        guard !Task.isCancelled, let final = current.revalidated() else { return nil }
        if refreshSeasonBoundary {
            DownloadStore.shared.refreshSeasonBoundary(for: final.record, owner: final.owner)
        }
        return (final, resume.isFinite ? max(0, resume) : 0)
    }
}

/// Offline entry choices when a title route exists but its catalog metadata cannot be loaded.
struct DownloadedTitleChoices: View {
    let copies: [AppleDownloadedPlayback]
    let onPlay: (AppleDownloadedPlayback) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: Theme.Space.sm) {
                ForEach(copies, id: \.record.id) { copy in
                    Button { onPlay(copy) } label: {
                        if let season = copy.record.season, let episode = copy.record.episode {
                            Label("Play download · S\(season)E\(episode)", systemImage: "play.fill")
                        } else {
                            Label("Play downloaded", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(ChipButtonStyle())
                }
            }
        }
    }
}

/// A virtual "folder" of downloads for one show (all episodes of a series) or a single movie, derived from
/// the flat download index by `DownloadStore.groupedDownloads()`. Purely a view model: it holds no state of
/// its own and drives a grouped SwiftUI list directly (Identifiable). See `groupedDownloads()` for the
/// grouping + season/episode ordering rules.
struct DownloadGroup: Identifiable {
    /// `series:<seriesId>` for a show folder, or `movie:<videoId>` for a standalone movie.
    let id: String
    /// The show title (or movie title). For a series every episode carries the series name, so any record's
    /// `name` is the show name.
    let title: String
    let poster: String?
    /// Original persisted catalog type from the group's first record. Folder rendering uses `isShow`.
    let type: String
    /// The group's downloads: for a series, episodes sorted season-then-episode; for a movie, the one record.
    let records: [DownloadRecord]

    /// True for a derived episode group. A movie group renders as a plain row instead of a folder.
    var isShow: Bool { records.first?.usesSeriesLifecycle ?? false }
    /// Number of downloads in the folder (episode count for a show).
    var count: Int { records.count }
}

private extension JSONEncoder {
    static let downloads: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let downloads: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
