import Foundation
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

    /// `taskIdentifier -> final destination file URL`, captured at task-creation time and read from the
    /// `didFinishDownloadingTo` delegate callback. That callback runs on the session's BACKGROUND
    /// delegate queue, where the temp file must be moved synchronously before it's deleted — so the
    /// destination must be resolvable WITHOUT hopping to the main actor. The box is its own thread-safe
    /// (`NSLock`-guarded) `Sendable` type, so it's safe to read from either thread.
    nonisolated let destinations = DownloadDestinationMap()

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

    // MARK: Public API

    /// Begin downloading `stream` for `meta`, fetching the already-resolved `resolvedURL` (the SAME URL
    /// the player would have used — debrid/direct https, or the loopback torrent URL). Returns the new
    /// record. No-ops to the existing record if this exact video is already downloaded / downloading.
    @discardableResult
    func download(stream: CoreStream, meta: PlaybackMeta, resolvedURL: URL,
                  sourceName: String?, qualityText: String?) -> DownloadRecord {
        if let existing = store.records.first(where: { $0.videoId == meta.videoId && $0.state != .failed }) {
            return existing
        }

        // Honor the concurrency cap: only start now if a slot is free; otherwise create the record
        // `.queued` and let it start when a running download finishes / fails / is cancelled / paused.
        let id = UUID()
        let ext = fileExtension(for: resolvedURL)
        let canStartNow = activeCount < Self.maxConcurrentDownloads
        let record = DownloadRecord(
            id: id, contentId: meta.libraryId, videoId: meta.videoId, type: meta.type,
            name: meta.name, poster: meta.poster, season: meta.season, episode: meta.episode,
            sourceName: sourceName, qualityText: qualityText, isTorrent: stream.isTorrent,
            headers: stream.requestHeaders, remoteURL: resolvedURL.absoluteString,
            localFilename: "\(id.uuidString).\(ext)", state: canStartNow ? .downloading : .queued)
        store.upsert(record)

        if canStartNow { startTask(for: record, url: resolvedURL) }
        return record
    }

    func pause(id: UUID) {
        // A queued item has no live task yet: just mark it paused so it stops being eligible to start.
        guard let task = taskForRecord[id] else {
            if store.record(id: id)?.state == .queued {
                store.update(id: id) { $0.state = .paused }
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
        destinations.set(store.fileURL(for: record), for: task.taskIdentifier)
        beginForegroundAssertionIfNeeded(for: record)
        task.resume()
    }

    /// Cancel and remove the download entirely (task + record + on-disk file).
    func cancel(id: UUID) {
        taskForRecord[id]?.cancel()
        clearTask(id: id)
        resumeData[id] = nil
        store.remove(id: id)
    }

    // MARK: Task lifecycle

    private func startTask(for record: DownloadRecord, url: URL) {
        let session = record.isTorrent ? foregroundSession : backgroundSession
        let task = makeTask(on: session, url: url, headers: record.headers)
        bind(task: task, to: record.id)
        destinations.set(store.fileURL(for: record), for: task.taskIdentifier)
        beginForegroundAssertionIfNeeded(for: record)
        task.resume()
    }

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
    }

    private func clearTask(id: UUID) {
        if let task = taskForRecord[id] {
            recordForTask[task.taskIdentifier] = nil
            destinations.remove(task.taskIdentifier)
        }
        taskForRecord[id] = nil
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
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    /// Progress. Delegate callbacks arrive off the main thread; hop to the main actor for store writes.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task { @MainActor [weak self] in
            guard let self, let id = self.recordID(for: downloadTask) else { return }
            self.store.update(id: id) {
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
        let dest = destinations.url(for: downloadTask.taskIdentifier)
        var moveError: Error?
        if let dest {
            try? FileManager.default.removeItem(at: dest)
            // Ensure the destination directory exists before the move/copy. If the Downloads dir was
            // never created (or was reclaimed by the OS), moveItem/copyItem fails and the user sees
            // "cannot create file" on completion. createDirectory is a no-op when it already exists.
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            do { try FileManager.default.moveItem(at: location, to: dest) }
            catch {
                // A cross-volume move can fail with EXDEV; fall back to a copy.
                do { try FileManager.default.copyItem(at: location, to: dest) } catch { moveError = error }
            }
        }
        let failed = (dest == nil) || (moveError != nil)
        let failureText = moveError?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, let id = self.recordID(for: downloadTask) else { return }
            self.store.update(id: id) {
                if failed {
                    $0.state = .failed
                    $0.errorText = failureText ?? "Could not save downloaded file"
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
        guard let error else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor [weak self] in
            guard let self, let id = self.recordID(for: task) else { return }
            // A deliberate pause cancels the task; pause() already recorded `.paused` + resume data.
            if (error as NSError).code == NSURLErrorCancelled { return }
            if let resume { self.resumeData[id] = resume }
            self.store.update(id: id) {
                $0.state = .failed
                $0.errorText = error.localizedDescription
            }
            self.clearTask(id: id)
        }
    }
}

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
