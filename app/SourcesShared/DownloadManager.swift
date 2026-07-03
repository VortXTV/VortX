import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// The file-writing core for offline downloads. ONE download = GET an http(s) URL to a local file. There
/// are TWO transport MODES, picked by `stream.isTorrent`, sharing this one core:
///
///  * **debrid / direct / HTTP** (`isTorrent == false`): a true `.background` `URLSession`, so the
///    transfer continues while the app is suspended / backgrounded.
///  * **torrent-to-disk** (`isTorrent == true`): the playable URL IS the loopback streaming-server URL
///    (`127.0.0.1:11470/{infoHash}/{fileIdx}`). The in-app node server fetches pieces as we read, so the
///    server MUST stay alive — a background `URLSession` can't keep it running. So torrents download over
///    a `.default` session while the app is ACTIVE, wrapped in a `UIApplication` background-task assertion
///    that buys a grace window if the user backgrounds the app. If the server dies the transfer simply
///    fails (fail-soft) and the record goes to `.failed` with resume data kept where the OS provides it.
///
/// All state writes go through `DownloadStore` (the local index) on the main actor. Nothing here writes
/// a `libraryItem` document or syncs the list.
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    private let store = DownloadStore.shared

    /// Most downloads we run at once. Beyond this, new downloads are created `.queued` and start
    /// automatically as running ones finish / fail / are cancelled / are paused (start-next-on-finish).
    /// Kept small: each transfer is a multi-GB media file, and torrent transfers also pin the loopback
    /// node server, so a low cap avoids thrashing bandwidth + disk + (for torrents) the server.
    private static let maxConcurrentDownloads = 2

    /// Maps a live URLSession task to the record it's filling, both ways, so a delegate callback (which
    /// arrives with only a task) resolves to a record id, and a pause/cancel(id:) resolves to its task.
    private var taskForRecord: [UUID: URLSessionDownloadTask] = [:]
    private var recordForTask: [Int: UUID] = [:]
    /// Resume data captured on pause / recoverable failure, so resume() can continue instead of restart.
    private var resumeData: [UUID: Data] = [:]

    /// Last progress tick forwarded to the store per record (#24). The OS delivers `didWriteData` many
    /// times per second per active download; unthrottled, each tick was a main-thread `records` publish
    /// PLUS a synchronous JSON re-encode + atomic index write. Ticks are forwarded at most every ~0.5s /
    /// ~8 MB per record.
    private var lastProgressPush: [UUID: (bytes: Int64, at: TimeInterval)] = [:]

    /// The UIKit completion handler handed to us when iOS relaunches the app to deliver finished
    /// background downloads (`application(_:handleEventsForBackgroundURLSession:completionHandler:)`).
    /// We MUST call it once the session has finished delivering all its events
    /// (`urlSessionDidFinishEvents`) or iOS will throttle / kill future background transfers. Stored here
    /// because the app delegate that receives it has no other handle on this session.
    var backgroundCompletionHandler: (() -> Void)?

    /// `taskIdentifier -> final destination file URL`, captured at task-creation time and read from the
    /// `didFinishDownloadingTo` delegate callback. That callback runs on the session's BACKGROUND
    /// delegate queue, where the temp file must be moved synchronously before it's deleted — so the
    /// destination must be resolvable WITHOUT hopping to the main actor. The box is its own thread-safe
    /// (`NSLock`-guarded) `Sendable` type, so it's safe to read from either thread.
    nonisolated let destinations = DownloadDestinationMap()

    #if os(iOS)
    /// The finished HLS `.movpkg` location, captured SYNCHRONOUSLY in `didFinishDownloadingTo` (on the serial
    /// background delegate queue, which AVFoundation runs BEFORE `didCompleteWithError`). `handleAssetTaskCompletion`
    /// reads it synchronously to decide completed-vs-failed, so the decision never depends on a separately-hopped
    /// @MainActor Task that could run out of order and flip a fully-downloaded asset to `.failed`.
    nonisolated let hlsFinishedLocations = DownloadDestinationMap()
    #endif

    #if canImport(UIKit)
    /// Background-task assertion for the torrent (foreground) session, so a brief backgrounding doesn't
    /// instantly suspend the app and kill the node server mid-transfer.
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    // MARK: Sessions

    /// Survives app suspension — debrid / direct / HTTP.
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "tv.vortx.downloads.background")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Active-app only — the loopback torrent URL (server must stay alive).
    private lazy var foregroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    #if os(iOS)
    /// Offline HLS (.m3u8) downloads: AVFoundation fetches the media into a system-managed `.movpkg` bundle we
    /// play back through AVPlayer (libmpv can't open a `.movpkg`). Background config so it survives suspension.
    /// iOS only — `AVAssetDownloadURLSession` is unavailable on tvOS and native macOS (there the source fails soft).
    private lazy var hlsAssetSession: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "tv.vortx.downloads.hls")
        config.allowsCellularAccess = true
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: nil)
    }()

    /// Live HLS asset-download tasks, both ways (an `AVAssetDownloadTask` is a `URLSessionTask` but NOT a
    /// `URLSessionDownloadTask`, so it cannot live in `taskForRecord`). Keyed like the byte-download maps.
    private var assetTaskForRecord: [UUID: AVAssetDownloadTask] = [:]
    private var recordForAssetTask: [Int: UUID] = [:]
    /// Fixed denominator for HLS progress (AVFoundation reports loaded/expected TIME, not bytes): the record's
    /// `bytesDone`/`bytesTotal` are set to `fraction * this` so the existing progress bar works unchanged.
    private static let hlsProgressScale: Int64 = 10_000
    #endif

    // MARK: Public API

    /// Begin downloading `stream` for `meta`, fetching the already-resolved `resolvedURL` (the SAME URL
    /// the player would have used — debrid/direct https, or the loopback torrent URL). Returns the new
    /// record. No-ops to the existing record if this exact video is already downloaded / downloading.
    @discardableResult
    func download(stream: CoreStream, meta: PlaybackMeta, resolvedURL: URL,
                  sourceName: String?, qualityText: String?) -> DownloadRecord {
        if let existing = store.records.first(where: { $0.videoId == meta.videoId && $0.state != .failed }) {
            // A paused download is resumable: tapping Download again on a paused title should resume it, not
            // return the paused record unchanged (which read as a silent no-op).
            if existing.state == .paused { resume(id: existing.id) }
            return existing
        }

        // Honor the concurrency cap: only start now if a slot is free; otherwise create the record
        // `.queued` and let it start when a running download finishes / fails / is cancelled / paused.
        let id = UUID()
        let ext = fileExtension(for: resolvedURL)
        // HLS sources (adaptive .m3u8) cannot be saved by a single-file download task - it fetches only the
        // playlist, not the media segments. On iOS we download them PROPERLY with AVAssetDownloadTask into a
        // system-managed .movpkg (played back through AVPlayer); on tvOS and native macOS AVAssetDownloadURLSession
        // is unavailable, so we fail honestly there (a .movpkg is device-local and never reaches those anyway).
        // (Embed pages that don't end in .m3u8 are caught post-download by the content sniff in
        // didFinishDownloadingTo.) Reported by a community user with the ok.ru add-on. Torrents are exempt (they
        // go through the loopback server, not a media URL).
        if !stream.isTorrent, Self.isHLSPlaylistURL(resolvedURL) {
            #if os(iOS)
            return startHLSDownload(id: id, ext: ext, meta: meta, stream: stream, resolvedURL: resolvedURL,
                                    sourceName: sourceName, qualityText: qualityText)
            #else
            let failedRecord = DownloadRecord(
                id: id, contentId: meta.libraryId, videoId: meta.videoId, type: meta.type,
                name: meta.name, poster: meta.poster, season: meta.season, episode: meta.episode,
                sourceName: sourceName, qualityText: qualityText, isTorrent: false,
                headers: stream.requestHeaders, remoteURL: resolvedURL.absoluteString,
                localFilename: "\(id.uuidString).\(ext)", state: .failed)
            store.upsert(failedRecord)
            store.update(id: id) { $0.errorText = String(localized: "This source streams in segments (HLS), which can't be saved for offline on this device yet. Download it on iPhone or iPad.") }
            return failedRecord
            #endif
        }

        // Honor the concurrency cap: start now only if a slot is free, else create the record `.queued` and
        // let it start when a running download finishes / fails / is cancelled / paused (start-next-on-finish).
        let canStartNow = activeCount < Self.maxConcurrentDownloads
        let record = DownloadRecord(
            id: id, contentId: meta.libraryId, videoId: meta.videoId, type: meta.type,
            name: meta.name, poster: meta.poster, season: meta.season, episode: meta.episode,
            sourceName: sourceName, qualityText: qualityText, isTorrent: stream.isTorrent,
            headers: stream.requestHeaders, remoteURL: resolvedURL.absoluteString,
            localFilename: "\(id.uuidString).\(ext)", state: canStartNow ? .downloading : .queued)
        store.upsert(record)

        // Defensive: iOS does NOT auto-create Application Support, so make sure the Downloads dir exists
        // before the background session or the completion move ever needs it. Rules out a missing container
        // as the "cannot create file (-3000)" cause; the completion move also creates it, this is belt+braces.
        try? FileManager.default.createDirectory(at: DownloadStore.downloadsDirectory, withIntermediateDirectories: true)

        if canStartNow { startTask(for: record, url: resolvedURL) }
        return record
    }

    func pause(id: UUID) {
        #if os(iOS)
        // HLS asset downloads pause by suspending the live task (no resume-data mechanism). Clear the
        // persisted identifier: a paused record must never be reconnected as in-flight (resume re-creates the
        // asset task, and AVFoundation auto-resumes the partial .movpkg).
        if let assetTask = assetTaskForRecord[id] {
            assetTask.suspend()
            store.update(id: id) { $0.state = .paused; $0.taskIdentifier = nil }
            return
        }
        #endif
        // A queued item has no live task yet: just mark it paused so it stops being eligible to start.
        guard let task = taskForRecord[id] else {
            if store.record(id: id)?.state == .queued {
                store.update(id: id) { $0.state = .paused; $0.taskIdentifier = nil }
            }
            return
        }
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.resumeData[id] = data }
                self.store.update(id: id) { $0.state = .paused }
            }
        })
        clearTask(id: id)
    }

    func resume(id: UUID) {
        guard let record = store.record(id: id) else { return }
        #if os(iOS)
        // HLS downloads bypass the byte-download concurrency cap (a separate session). Resume a suspended live
        // task, else re-create the asset task (AVFoundation auto-resumes the partial download, incl. post-relaunch).
        if isHLSRecord(record) {
            store.update(id: id) { $0.state = .downloading; $0.errorText = nil }
            if let assetTask = assetTaskForRecord[id] { assetTask.resume() } else { beginHLSAssetTask(for: record) }
            return
        }
        #endif
        // Respect the concurrency cap on resume too: if every slot is busy, re-queue instead of
        // starting now, so resuming several paused items can't blow past the cap. It starts when a
        // slot frees (start-next-on-finish), exactly like a freshly-queued download.
        guard activeCount < Self.maxConcurrentDownloads else {
            store.update(id: id) { $0.state = .queued }
            return
        }
        store.update(id: id) { $0.state = .downloading }
        // Background-session resume data must be resumed on the SAME session kind it was produced on.
        let session = record.isTorrent ? foregroundSession : backgroundSession
        let task: URLSessionDownloadTask
        if let data = resumeData[id] {
            task = session.downloadTask(withResumeData: data)
            resumeData[id] = nil
        } else if let url = URL(string: record.remoteURL) {
            task = makeTask(on: session, url: url, headers: record.headers)
        } else {
            store.update(id: id) { $0.state = .failed; $0.errorText = "Invalid source URL" }
            return
        }
        bind(task: task, to: id)
        // Persist the destination filename ON the task: a background URLSession serializes `taskDescription`,
        // so it survives the app-suspend/relaunch that wipes the in-memory `destinations` + `recordForTask`
        // maps. The relaunched delegate reads it back to recover where to move the finished temp file (the
        // "cannot create file" root cause: the in-memory map was empty in the relaunched process).
        task.taskDescription = record.localFilename
        destinations.set(store.fileURL(for: record), for: task.taskIdentifier)
        beginForegroundAssertionIfNeeded(for: record)
        task.resume()
    }

    /// Cancel and remove the download entirely (task + record + on-disk file).
    func cancel(id: UUID) {
        taskForRecord[id]?.cancel()
        clearTask(id: id)
        resumeData[id] = nil
        #if os(iOS)
        cancelAssetTask(id: id)
        #endif
        store.remove(id: id)
    }

    // MARK: Task lifecycle

    /// Fail EARLY with a clear message when the Downloads volume can't hold the expected file, instead of
    /// letting iOS run a full multi-GB transfer that ends in an opaque -3000 "cannot create file". Returns
    /// true only on a HARD shortfall; an unknown size (bytesTotal == 0) is allowed through.
    private func storageShortfall(for record: DownloadRecord) -> Bool {
        guard record.bytesTotal > 0 else { return false }
        // volumeAvailableCapacityKey is available on every Apple platform (the ...ForImportantUsage variant is
        // unavailable on tvOS, and this file is shared). Raw available bytes are fine for a shortfall guard.
        let vals = try? DownloadStore.downloadsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let free = vals?.volumeAvailableCapacity else { return false }
        // Need the file plus a ~200 MB margin (the background daemon stages a temp copy before the move).
        return Int64(free) < Int64(record.bytesTotal) + 200 * 1024 * 1024
    }

    private func startTask(for record: DownloadRecord, url: URL) {
        if storageShortfall(for: record) {
            store.update(id: record.id) {
                $0.state = .failed
                $0.errorText = "Not enough storage to save this download. Free up space and try again."
            }
            return
        }
        let session = record.isTorrent ? foregroundSession : backgroundSession
        let task = makeTask(on: session, url: url, headers: record.headers)
        bind(task: task, to: record.id)
        // Persist the destination filename on the task (survives relaunch via the background session). See
        // the matching note in resume(): this is how the off-main delegate recovers the destination after a
        // relaunch empties the in-memory maps.
        task.taskDescription = record.localFilename
        destinations.set(store.fileURL(for: record), for: task.taskIdentifier)
        beginForegroundAssertionIfNeeded(for: record)
        task.resume()
    }

    #if os(iOS)
    // MARK: HLS offline (AVAssetDownloadTask -> .movpkg)

    /// Start an offline HLS download (iOS only). AVFoundation writes a system-managed `.movpkg` (we never move
    /// it); on completion we persist its home-relative path in `hlsRelativePath`, which routes offline playback
    /// through AVPlayer. HLS downloads bypass the byte-download concurrency queue (a separate mechanism).
    private func startHLSDownload(id: UUID, ext: String, meta: PlaybackMeta, stream: CoreStream, resolvedURL: URL,
                                  sourceName: String?, qualityText: String?) -> DownloadRecord {
        let record = DownloadRecord(
            id: id, contentId: meta.libraryId, videoId: meta.videoId, type: meta.type,
            name: meta.name, poster: meta.poster, season: meta.season, episode: meta.episode,
            sourceName: sourceName, qualityText: qualityText, isTorrent: false,
            headers: stream.requestHeaders, remoteURL: resolvedURL.absoluteString,
            localFilename: "\(id.uuidString).\(ext)",
            bytesTotal: Self.hlsProgressScale, bytesDone: 0, state: .downloading)
        store.upsert(record)
        beginHLSAssetTask(for: record)
        return record
    }

    /// Create (or re-create, for resume) the AVAssetDownloadTask for an HLS record. AVFoundation resumes a
    /// partially-downloaded asset automatically when a new task is made for the same asset, so this also serves
    /// as the resume path after a relaunch wiped the in-memory task.
    private func beginHLSAssetTask(for record: DownloadRecord) {
        guard let url = URL(string: record.remoteURL) else {
            store.update(id: record.id) { $0.state = .failed; $0.errorText = String(localized: "Invalid source URL") }
            return
        }
        let options: [String: Any]? = (record.headers?.isEmpty ?? true) ? nil : ["AVURLAssetHTTPHeaderFieldsKey": record.headers!]
        let asset = AVURLAsset(url: url, options: options)
        guard let task = hlsAssetSession.makeAssetDownloadTask(asset: asset, assetTitle: record.displayTitle,
                                                               assetArtworkData: nil, options: nil) else {
            store.update(id: record.id) { $0.state = .failed; $0.errorText = String(localized: "This HLS source can't be downloaded (it may be protected or unavailable).") }
            return
        }
        task.taskDescription = record.id.uuidString
        assetTaskForRecord[record.id] = task
        recordForAssetTask[task.taskIdentifier] = record.id
        // Persist the asset task's identifier so a relaunch can re-wire pause/cancel to the live task (the
        // uuid in taskDescription still serves as the fallback match). Cosmetic field.
        store.update(id: record.id) { $0.taskIdentifier = task.taskIdentifier }
        task.resume()
    }

    /// Record id for an asset task, recovering across a relaunch (in-memory map empty) via the uuid stored in
    /// `taskDescription`, and re-binding so later callbacks resolve fast.
    private func assetRecordID(for task: AVAssetDownloadTask) -> UUID? {
        if let id = recordForAssetTask[task.taskIdentifier] { return id }
        guard let desc = task.taskDescription, let id = UUID(uuidString: desc), store.record(id: id) != nil else { return nil }
        recordForAssetTask[task.taskIdentifier] = id
        return id
    }

    /// Cancel + forget a live HLS asset task (its partial `.movpkg` is discarded by AVFoundation on cancel).
    private func cancelAssetTask(id: UUID) {
        if let task = assetTaskForRecord[id] {
            recordForAssetTask[task.taskIdentifier] = nil
            task.cancel()
        }
        assetTaskForRecord[id] = nil
    }

    /// True when a record's source is an HLS `.m3u8` (so pause/resume/cancel route to the asset session).
    private func isHLSRecord(_ record: DownloadRecord) -> Bool {
        record.remoteURL.range(of: ".m3u8", options: .caseInsensitive) != nil
    }
    #endif

    private func makeTask(on session: URLSession, url: URL, headers: [String: String]?) -> URLSessionDownloadTask {
        var request = URLRequest(url: url)
        // Apply the add-on's declared request headers (behaviorHints.proxyHeaders): a CDN behind a
        // header-gated add-on rejects a request without the right Referer / User-Agent.
        for (name, value) in headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        return session.downloadTask(with: request)
    }

    private func bind(task: URLSessionDownloadTask, to id: UUID) {
        taskForRecord[id] = task
        recordForTask[task.taskIdentifier] = id
        // Persist the task identifier so a relaunch can map this still-running background task back to its
        // record and re-wire pause/cancel. A cosmetic-only field, so a bare progress write is fine (do not
        // force an index rewrite here beyond the store's default).
        store.update(id: id) { $0.taskIdentifier = task.taskIdentifier }
    }

    private func clearTask(id: UUID) {
        if let task = taskForRecord[id] {
            recordForTask[task.taskIdentifier] = nil
            destinations.remove(task.taskIdentifier)
        }
        taskForRecord[id] = nil
        lastProgressPush[id] = nil   // do not leak the throttle entry across a terminal transition
        // The record no longer has a live task; drop the persisted identifier so a later relaunch never
        // tries to reconnect a task that is gone. No-op if the record was already removed (cancel).
        if store.record(id: id) != nil { store.update(id: id) { $0.taskIdentifier = nil } }
        endForegroundAssertionIfIdle()
        // A slot just freed (finish / fail / pause / cancel): pull the next queued download in.
        startNextQueued()
    }

    // MARK: Concurrency queue

    /// Live download tasks in flight. A `.queued` / `.paused` record has no task, so this is exactly the
    /// count of running downloads, which is what the cap gates on.
    private var activeCount: Int { taskForRecord.count }

    /// Start the oldest `.queued` download if a slot is free. Picks the earliest-added queued record so
    /// the queue drains in the order downloads were requested. Fail-soft: a queued record whose source
    /// URL no longer parses is marked `.failed` and skipped, so one bad URL can't wedge the queue.
    private func startNextQueued() {
        guard activeCount < Self.maxConcurrentDownloads else { return }
        guard let next = store.records
            .filter({ $0.state == .queued })
            .min(by: { $0.addedAt < $1.addedAt }) else { return }
        guard let url = URL(string: next.remoteURL) else {
            store.update(id: next.id) { $0.state = .failed; $0.errorText = "Invalid source URL" }
            // Skipping a broken record freed nothing, but another queued record may now be startable.
            startNextQueued()
            return
        }
        store.update(id: next.id) { $0.state = .downloading }
        startTask(for: next, url: url)
    }

    private func recordID(for task: URLSessionTask) -> UUID? { recordForTask[task.taskIdentifier] }

    /// Adopt the iOS background-relaunch completion handler. Touching `backgroundSession` here forces the
    /// lazy session to materialize so its delegate is attached and the queued finished-download events
    /// actually deliver in this relaunched process; the handler is then fired from `urlSessionDidFinishEvents`.
    func adoptBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        // Also re-wire pause/cancel to any transfer still running: a background relaunch may hand us live
        // tasks the in-memory maps know nothing about. reconnect materializes both sessions and rebuilds
        // the maps (and is idempotent, so calling it here + at launch is safe).
        reconnectInFlightDownloads()
    }

    /// Reconnect after an app relaunch so pause/cancel operate on the real, still-running transfers again.
    ///
    /// A `.background` URLSession (and an `AVAssetDownloadURLSession`) keeps its tasks RUNNING while the app
    /// is killed, but the new process starts with EMPTY in-memory maps: `taskForRecord` / `recordForTask`
    /// (byte downloads) and `assetTaskForRecord` / `recordForAssetTask` (HLS). Until we re-adopt those tasks,
    /// a download shows as `.downloading` yet pause/cancel find no live task and silently no-op. So here we:
    ///
    ///  1. Re-CREATE each background session with its SAME identifier + delegate (a background session must be
    ///     recreated in the new process to receive its running tasks) — done by touching the lazy sessions.
    ///  2. `getAllTasks` and RECONCILE: map each live task back to its record (persisted `taskIdentifier`
    ///     first, then the filename/uuid we serialized on `taskDescription`), so its pause/cancel controls
    ///     drive the real task again. An ORPHAN task with no matching store record is cancelled. Any store
    ///     record still marked `.downloading` with NO live task is reconciled to `.paused` (resumable) —
    ///     never deleted, since its bytes-on-disk / partial asset are intact.
    ///
    /// Idempotent + fail-soft: safe to call at launch AND from the background-relaunch handler; a
    /// reconnection miss reconciles to `.paused` rather than crashing or dropping a good download. No-op when
    /// there are no in-flight records, so a normal launch pays nothing.
    func reconnectInFlightDownloads() {
        // Only in-flight (or seemingly-in-flight) records need reconnecting. Nothing to do otherwise, so an
        // ordinary launch with no active downloads materializes no session and touches no state.
        let inFlight = store.records.filter { $0.state == .downloading }
        guard !inFlight.isEmpty else { return }

        // (1) Force the lazy background byte-download session to materialize (recreates it in this process
        // with the same identifier + delegate, so getAllTasks returns its running tasks).
        let byteSession = backgroundSession
        byteSession.getAllTasks { [weak self] tasks in
            let downloadTasks = tasks.compactMap { $0 as? URLSessionDownloadTask }
            Task { @MainActor [weak self] in
                self?.reconcileByteTasks(downloadTasks)
            }
        }

        #if os(iOS)
        // (1) Same for the HLS asset session. Its live tasks are AVAssetDownloadTasks (a URLSessionTask but
        // NOT a URLSessionDownloadTask), so they arrive via getAllTasks and are filtered on that type.
        let assetSession = hlsAssetSession
        assetSession.getAllTasks { [weak self] tasks in
            let assetTasks = tasks.compactMap { $0 as? AVAssetDownloadTask }
            Task { @MainActor [weak self] in
                self?.reconcileAssetTasks(assetTasks)
            }
        }
        #endif
    }

    /// (2) for byte downloads. Re-adopt each live task into the in-memory maps, then reconcile any record
    /// that CLAIMS to be downloading but has no live task down to `.paused`.
    private func reconcileByteTasks(_ tasks: [URLSessionDownloadTask]) {
        var adopted = Set<UUID>()
        for task in tasks {
            guard let id = reconnectRecordID(for: task, filename: task.taskDescription) else {
                // Orphan: a live task with no matching store record (record was deleted while suspended, or
                // is a stale duplicate). Cancel it so it stops consuming bandwidth; nothing to reconcile.
                task.cancel()
                continue
            }
            // Re-wire both maps + the destination the off-main finish callback needs, exactly as bind()/
            // startTask() would have. Do NOT call bind() (it re-persists taskIdentifier via a store write we
            // already have); wire the maps directly.
            taskForRecord[id] = task
            recordForTask[task.taskIdentifier] = id
            if let record = store.record(id: id) {
                destinations.set(store.fileURL(for: record), for: task.taskIdentifier)
                store.update(id: id) { $0.taskIdentifier = task.taskIdentifier }
                beginForegroundAssertionIfNeeded(for: record)
            }
            adopted.insert(id)
        }
        reconcileStuckDownloading(excluding: adopted, hlsOnly: false)
    }

    #if os(iOS)
    /// (2) for HLS asset downloads. Mirror of `reconcileByteTasks` for the asset session's live tasks.
    private func reconcileAssetTasks(_ tasks: [AVAssetDownloadTask]) {
        var adopted = Set<UUID>()
        for task in tasks {
            guard let id = reconnectAssetRecordID(for: task) else {
                task.cancel()   // orphan asset task: no record to fill, discard its partial .movpkg
                continue
            }
            assetTaskForRecord[id] = task
            recordForAssetTask[task.taskIdentifier] = id
            store.update(id: id) { $0.taskIdentifier = task.taskIdentifier }
            adopted.insert(id)
        }
        reconcileStuckDownloading(excluding: adopted, hlsOnly: true)
    }
    #endif

    /// Any record still marked `.downloading` after reconnection but with NO reconnected live task is
    /// stranded (its session/task did not survive, e.g. a torrent foreground transfer whose server died
    /// while suspended, or a task the OS dropped). Reconcile it to `.paused` so its controls make sense and
    /// the user can resume — never delete it, the partial bytes / asset are still on disk. `hlsOnly` scopes
    /// the sweep to the matching transport so the byte pass doesn't touch HLS records still awaiting the
    /// asset-session callback and vice-versa.
    private func reconcileStuckDownloading(excluding adopted: Set<UUID>, hlsOnly: Bool) {
        for record in store.records where record.state == .downloading {
            guard !adopted.contains(record.id) else { continue }
            #if os(iOS)
            let recordIsHLS = isHLSRecord(record)
            #else
            let recordIsHLS = false
            #endif
            if hlsOnly != recordIsHLS { continue }
            // Still has a live task from THIS process (never lost) — leave it alone.
            if taskForRecord[record.id] != nil { continue }
            #if os(iOS)
            if assetTaskForRecord[record.id] != nil { continue }
            #endif
            store.update(id: record.id) {
                $0.state = .paused
                $0.taskIdentifier = nil
            }
        }
    }

    /// Byte-download record id for a live task during reconnection: persisted `taskIdentifier` first (exact),
    /// then the filename we serialized on `taskDescription` matched against `localFilename`. Both survive a
    /// relaunch; the pair makes a stale identifier fall back to the filename rather than orphaning a task.
    private func reconnectRecordID(for task: URLSessionTask, filename: String?) -> UUID? {
        if let id = store.records.first(where: { $0.taskIdentifier == task.taskIdentifier && $0.state == .downloading })?.id {
            return id
        }
        guard let filename else { return nil }
        return store.records.first { $0.localFilename == filename && $0.state == .downloading }?.id
    }

    #if os(iOS)
    /// HLS asset-download record id for a live task during reconnection: persisted `taskIdentifier` first,
    /// then the record uuid we serialized on `taskDescription`.
    private func reconnectAssetRecordID(for task: AVAssetDownloadTask) -> UUID? {
        if let id = store.records.first(where: { $0.taskIdentifier == task.taskIdentifier && $0.state == .downloading })?.id {
            return id
        }
        guard let desc = task.taskDescription, let id = UUID(uuidString: desc), store.record(id: id) != nil else { return nil }
        return id
    }
    #endif

    /// Record id for a finished task, recovering across an app relaunch. The in-memory `recordForTask`
    /// is empty in the relaunched process, so fall back to matching the filename we persisted on the task
    /// (`taskDescription`) against the stored records' `localFilename`. Without this, a download that
    /// completed while the app was suspended saved its file but its row stayed stuck on "Downloading".
    private func recoverRecordID(for task: URLSessionTask, filename: String?) -> UUID? {
        if let id = recordForTask[task.taskIdentifier] { return id }
        guard let filename else { return nil }
        return store.records.first { $0.localFilename == filename }?.id
    }

    // MARK: Foreground assertion (torrent mode only)

    private func beginForegroundAssertionIfNeeded(for record: DownloadRecord) {
        guard record.isTorrent else { return }
        #if canImport(UIKit)
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "vortx.download.torrent") { [weak self] in
            // Expiration: the OS is about to suspend us; we can't keep the node server alive, so end the
            // assertion. The transfer will fail-soft if the server stops; the record stays resumable.
            self?.endForegroundAssertion()
        }
        #endif
    }

    /// End the assertion once no torrent download is still active.
    private func endForegroundAssertionIfIdle() {
        let torrentActive = taskForRecord.keys.contains { id in
            store.record(id: id)?.isTorrent == true
        }
        if !torrentActive { endForegroundAssertion() }
    }

    private func endForegroundAssertion() {
        #if canImport(UIKit)
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
        #endif
    }

    // MARK: Helpers

    /// A reasonable media extension from the URL path, defaulting to mp4 (the loopback torrent URL and
    /// many debrid links carry no extension). Only used to name the local file.
    private func fileExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let known: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "webm", "ts", "flv", "wmv"]
        return known.contains(ext) ? ext : "mp4"
    }

    /// True when a resolved playback URL is an adaptive HLS playlist (.m3u8): a single-file download task
    /// only fetches the tiny playlist, not the media segments. Cheap string check, no network. `nonisolated`
    /// (pure) so the off-main download delegate can call it too.
    nonisolated private static func isHLSPlaylistURL(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "m3u8" { return true }
        return url.absoluteString.lowercased().contains(".m3u8")
    }

    /// Sniff a finished download's first bytes: an HLS playlist (#EXTM3U) or an HTML embed page (from an
    /// add-on that hands back a web page rather than a media file, e.g. ok.ru) is NOT a real media download.
    /// Real media starts with binary magic (mp4 ftyp box, mkv EBML, MPEG-TS 0x47), which never decodes to
    /// these text markers, so there are no false positives on genuine media. An empty file counts as non-media.
    /// `nonisolated` (pure file read) so the off-main `didFinishDownloadingTo` delegate can call it.
    nonisolated private static func looksLikeNonMedia(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64)) ?? Data()
        if head.isEmpty { return true }
        guard let text = String(data: head, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return text.hasPrefix("#extm3u") || text.hasPrefix("#ext-x-")
            || text.hasPrefix("<!doctype") || text.hasPrefix("<html") || text.hasPrefix("<?xml") || text.hasPrefix("<head")
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    /// Progress. Delegate callbacks arrive off the main thread; hop to the main actor for store writes.
    /// THROTTLED (#24): forward a tick at most every ~0.5s AND ~8 MB per record, and never persist the
    /// index for a bare progress tick (state transitions still persist; a crash mid-download only loses
    /// a cosmetic byte count, the transfer itself resumes from the session's own resume data).
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task { @MainActor [weak self] in
            guard let self, let id = self.recordID(for: downloadTask) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let last = self.lastProgressPush[id],
               totalBytesWritten - last.bytes < 8_000_000, now - last.at < 0.5 {
                return
            }
            self.lastProgressPush[id] = (bytes: totalBytesWritten, at: now)
            self.store.update(id: id, persistIndex: false) {
                $0.bytesDone = totalBytesWritten
                if totalBytesExpectedToWrite > 0 { $0.bytesTotal = totalBytesExpectedToWrite }
            }
        }
    }

    /// Finished — the temp file is only valid for the duration of THIS synchronous callback (the OS
    /// deletes it on return), so move it now, on this (background) delegate-queue thread, into the
    /// Downloads dir. Media files are gigabytes, so a `FileManager.moveItem` (an inode relink within the
    /// same container) is the only safe option — never read the bytes into memory. The destination was
    /// captured at task-creation time into a lock-guarded map, so it's resolvable here without hopping to
    /// the main actor (which `assumeIsolated` would crash on, since this runs off-main).
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // Prefer the in-memory map (same-process completion). After an app suspend/relaunch that map is
        // EMPTY in the new process, so recover the destination from the filename we persisted on the task
        // (`taskDescription`, which the background session serializes). This is the iOS "cannot create file"
        // fix: a ~2 GB file guarantees a suspend mid-download, and the old code then had `dest == nil`.
        let dest = destinations.url(for: downloadTask.taskIdentifier)
            ?? downloadTask.taskDescription.map { DownloadStore.fileURL(forFilename: $0) }
        // The source size BEFORE any move (the temp is gone after a successful move). 0 bytes here means the
        // SOURCE returned nothing - usually a torrent with no running server / no debrid, or a dead link - not
        // a save bug. Captured so a "cannot create file" is actually diagnosable.
        let srcBytes = ((try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? Int) ?? -1
        var moveError: Error?
        if let dest {
            try? FileManager.default.removeItem(at: dest)
            // Ensure the CANONICAL current-container Downloads dir exists before the move/copy - creating the
            // real root (+ backup-exclude) rather than a possibly-stale dest-derived parent - and surface a
            // create failure instead of swallowing it into an opaque -3000. Helper contributed by a VortX
            // subreddit user (H20-FIX).
            do { try DownloadStore.ensureDownloadsDirectoryExists() }
            catch { moveError = error }
            if moveError == nil {
                do { try FileManager.default.moveItem(at: location, to: dest) }
                catch {
                    // A cross-volume move can fail with EXDEV; fall back to a copy.
                    do { try FileManager.default.copyItem(at: location, to: dest) } catch { moveError = error }
                }
            }
        }
        var failed = (dest == nil) || (moveError != nil)
        var failureText: String? = failed
            ? (moveError.map { "\(String(localized: "Save failed:")) \(Self.downloadFailureDetail($0)) [src \(srcBytes)B]" }
               ?? String(localized: "Could not save the download: no destination for the file"))
            : nil
        // Content sniff: an add-on that hands back an HLS playlist or a web embed page (e.g. ok.ru) yields a
        // few-KB non-media "download". Reject it with an honest message instead of "completing" with garbage,
        // and delete the bogus file so it never shows up as a playable offline title.
        if !failed, let dest, Self.looksLikeNonMedia(dest) {
            try? FileManager.default.removeItem(at: dest)
            failed = true
            failureText = String(localized: "This source isn't a downloadable file (it streams or resolves through a web page). Downloads work with direct and debrid file sources.")
        }
        // Capture the persisted filename so the main-actor block can recover the record after a relaunch
        // (where `recordForTask` is empty), by matching it against the stored `localFilename`.
        let taskFilename = downloadTask.taskDescription
        Task { @MainActor [weak self] in
            guard let self, let id = self.recoverRecordID(for: downloadTask, filename: taskFilename) else { return }
            self.store.update(id: id) {
                if failed {
                    $0.state = .failed
                    $0.errorText = failureText ?? String(localized: "Could not save downloaded file")
                } else {
                    $0.state = .completed
                    $0.bytesDone = max($0.bytesDone, $0.bytesTotal)
                    $0.errorText = nil
                }
            }
            self.clearTask(id: id)
        }
    }

    /// Error path: a recoverable failure carries resume data; keep it so resume() continues. A user
    /// pause produces a `.cancelled` error which we deliberately ignore (pause already set the state).
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        #if os(iOS)
        // HLS asset downloads finalize here for BOTH success and failure (their success has no move step);
        // route them out of the byte-download path, which returns early on a nil error.
        if let assetTask = task as? AVAssetDownloadTask {
            handleAssetTaskCompletion(assetTask, error: error)
            return
        }
        #endif
        guard let error else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let taskFilename = task.taskDescription
        Task { @MainActor [weak self] in
            guard let self, let id = self.recoverRecordID(for: task, filename: taskFilename) else { return }
            // A deliberate pause cancels the task; pause() already recorded `.paused` + resume data.
            if (error as NSError).code == NSURLErrorCancelled { return }
            if let resume { self.resumeData[id] = resume }
            let ns = error as NSError
            // DIAGNOSTIC: the owner hit NSURLErrorCannotCreateFile (-3000) with ~200 GB free and a ~1 GB file,
            // so this is NOT out of space. Log the FULL error (domain/code/userInfo) so the true cause is
            // visible on-device, and surface the real domain/code instead of a wrong "storage" message.
            NSLog("[downloads] task FAILED id=%@ code=%ld domain=%@ desc=%@ userInfo=%@",
                  id.uuidString, ns.code, ns.domain, ns.localizedDescription, ns.userInfo as NSDictionary)
            self.store.update(id: id) {
                $0.state = .failed
                // Localize only the human prefix; the posix/path detail after it stays as-is (diagnostic).
                $0.errorText = "\(String(localized: "Couldn't save this download:")) \(Self.downloadFailureDetail(error))"
            }
            self.clearTask(id: id)
        }
    }

    #if os(iOS)
    /// Finalize an HLS asset download. On success (`error == nil`) the `.movpkg` location has already been
    /// stored by `assetDownloadTask:didFinishDownloadingTo:` (it fires first), so flip the record to
    /// `.completed`; on a real error mark it `.failed`. A deliberate pause/cancel arrives as `.cancelled` and
    /// is ignored (pause already set `.paused`; cancel already removed the record).
    nonisolated func handleAssetTaskCompletion(_ task: AVAssetDownloadTask, error: Error?) {
        let taskId = task.taskIdentifier
        let taskDesc = task.taskDescription
        if let ns = error as NSError?, ns.code == NSURLErrorCancelled {
            // Clear BOTH maps even for a system-initiated cancel (one that did not go through cancelAssetTask):
            // clearing only recordForAssetTask would leak the AVAssetDownloadTask held in assetTaskForRecord.
            self.hlsFinishedLocations.remove(taskId)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let id = self.recordForAssetTask[taskId] ?? taskDesc.flatMap { UUID(uuidString: $0) }
                self.recordForAssetTask[taskId] = nil
                if let id { self.assetTaskForRecord[id] = nil; self.lastProgressPush[id] = nil }
            }
            return
        }
        // Capture the finished location SYNCHRONOUSLY here (this callback is serialized after
        // didFinishDownloadingTo on the same background delegate queue), so success is decided on a value that
        // is guaranteed present rather than on record.hlsRelativePath written by a separate, possibly-later Task.
        let finishedRelPath = self.hlsFinishedLocations.url(for: taskId)?.relativePath
        let failureText = error.map { "\(String(localized: "Couldn't save this download:")) \(Self.downloadFailureDetail($0))" }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let id = self.recordForAssetTask[taskId] ?? taskDesc.flatMap { UUID(uuidString: $0) }
            guard let id, self.store.record(id: id) != nil else { return }
            self.store.update(id: id) {
                if error == nil, let rel = finishedRelPath {
                    $0.state = .completed
                    $0.hlsRelativePath = rel   // persist here too so completion no longer races the finish Task
                    $0.bytesTotal = Self.hlsProgressScale
                    $0.bytesDone = Self.hlsProgressScale
                    $0.errorText = nil
                } else {
                    $0.state = .failed
                    $0.errorText = failureText ?? String(localized: "The HLS download didn't complete.")
                }
            }
            self.recordForAssetTask[taskId] = nil
            self.assetTaskForRecord[id] = nil
            self.lastProgressPush[id] = nil
            self.hlsFinishedLocations.remove(taskId)
        }
    }
    #endif

    /// A compact, self-diagnosing cause for a failed download. Digs PAST the top NSError into the underlying
    /// POSIX error + the offending file path, so a "cannot create file (-3000)" is legible from a screenshot
    /// alone (no Console log needed): it names the real reason (a permission/path problem, a read-only or
    /// missing container, an out-of-space volume, a background-daemon staging failure) instead of an opaque
    /// code. `-3000` is NSURLErrorCannotCreateFile: the file could not be created at its destination, which is
    /// NOT the same as out-of-space.
    nonisolated static func downloadFailureDetail(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["\(ns.domain) \(ns.code)"]
        if let path = ns.userInfo[NSFilePathErrorKey] as? String { parts.append("path=\(path)") }
        if let url = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            parts.append("host=\(url.host ?? "?")")
        }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("under=\(under.domain) \(under.code)")
            if under.domain == NSPOSIXErrorDomain {
                parts.append("posix=\(String(cString: strerror(Int32(under.code))))")
            }
            if let upath = under.userInfo[NSFilePathErrorKey] as? String { parts.append("upath=\(upath)") }
        }
        return parts.joined(separator: " | ")
    }

    /// iOS has finished delivering every queued event for this background session (after relaunching the
    /// app to do so). Call the stored UIKit completion handler now so the system stops waiting on us and
    /// keeps future background transfers eligible. Required for background downloads that finish while the
    /// app is suspended; without it iOS progressively throttles the session.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}

#if os(iOS)
// MARK: - AVAssetDownloadDelegate (offline HLS)

extension DownloadManager: AVAssetDownloadDelegate {
    /// Progress: AVFoundation reports the loaded vs expected TIME range (there is no byte count), so map the
    /// fraction onto the record's byte-scaled progress so the existing bar works. Throttled like the byte path.
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                                didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                                timeRangeExpectedToLoad: CMTimeRange) {
        var loaded = 0.0
        for value in loadedTimeRanges { loaded += value.timeRangeValue.duration.seconds }
        let total = timeRangeExpectedToLoad.duration.seconds
        let fraction = total > 0 ? min(1.0, max(0.0, loaded / total)) : 0
        let taskId = assetDownloadTask.taskIdentifier
        Task { @MainActor [weak self] in
            guard let self, let id = self.recordForAssetTask[taskId] else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let last = self.lastProgressPush[id], now - last.at < 0.5 { return }
            let done = Int64(fraction * Double(Self.hlsProgressScale))
            self.lastProgressPush[id] = (bytes: done, at: now)
            self.store.update(id: id, persistIndex: false) {
                $0.bytesTotal = Self.hlsProgressScale
                $0.bytesDone = done
            }
        }
    }

    /// The finished `.movpkg` location: system-managed, so we do NOT move it. Persist its path RELATIVE to the
    /// home dir (the container UUID can change between launches); the completion callback flips the record to
    /// `.completed`. Fires BEFORE `didCompleteWithError`.
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let relativePath = location.relativePath
        let taskId = assetDownloadTask.taskIdentifier
        let taskDesc = assetDownloadTask.taskDescription
        // Record the finished location SYNCHRONOUSLY on the delegate queue so handleAssetTaskCompletion (which
        // runs next on the same serial queue) sees it without depending on the @MainActor persistence below.
        self.hlsFinishedLocations.set(location, for: taskId)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let id = self.recordForAssetTask[taskId] ?? taskDesc.flatMap { UUID(uuidString: $0) }
            guard let id else { return }
            self.store.update(id: id) { $0.hlsRelativePath = relativePath }
        }
    }
}
#endif

/// A tiny lock-guarded `taskIdentifier -> destination URL` map. It exists OUTSIDE the `@MainActor`
/// isolation of `DownloadManager` so the `didFinishDownloadingTo` delegate callback (which runs on the
/// URLSession background delegate queue and must move the temp file synchronously, before the OS deletes
/// it) can resolve the destination without hopping to the main actor. `@unchecked Sendable` is sound here
/// because every access goes through the lock.
final class DownloadDestinationMap: @unchecked Sendable {
    private var map: [Int: URL] = [:]
    private let lock = NSLock()

    func set(_ url: URL, for taskIdentifier: Int) {
        lock.lock(); defer { lock.unlock() }
        map[taskIdentifier] = url
    }

    func url(for taskIdentifier: Int) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return map[taskIdentifier]
    }

    func remove(_ taskIdentifier: Int) {
        lock.lock(); defer { lock.unlock() }
        map[taskIdentifier] = nil
    }
}
