import Foundation

/// Device-local persistence for offline downloads. The index is a JSON file at
/// `Application Support/Downloads/index.json`; the media files sit alongside it at
/// `Application Support/Downloads/<id>.<ext>`. The directory is marked excluded-from-iCloud-backup
/// (downloaded media is large + re-downloadable, and the OS would otherwise back it up / purge it under
/// pressure in surprising ways).
///
/// This store is intentionally NOT synced (no VortX-account / E2E write): a download is a physical file
/// on one device, and syncing the LIST to a device that lacks the file is misleading. It also NEVER
/// touches `libraryItem` documents — a download is a local file plus this local index, nothing more.
@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    /// Newest-first, for direct binding into the SwiftUI list.
    @Published private(set) var records: [DownloadRecord] = []

    private let fileManager = FileManager.default

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
        // the background delegate moved the temp file in). Log it so a real permission/path fault is
        // diagnosable instead of vanishing.
        do { try fileManager.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { NSLog("[downloads] could not create Downloads dir at \(dir.path): \(error.localizedDescription)") }
        excludeFromBackup(dir)
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

    /// True when a completed (or in-flight) download already exists for this exact video — drives the
    /// "Downloaded" / "Downloading" state on a source row so a user can't queue a title twice.
    func hasDownload(videoId: String) -> Bool {
        records.contains { $0.videoId == videoId && $0.state != .failed }
    }

    func upsert(_ record: DownloadRecord) {
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.insert(record, at: 0)
        }
        persist()
    }

    /// Mutate a record in place (progress / state transitions) and persist. No-op if the id is gone
    /// (e.g. the user deleted the row while a late delegate callback arrived).
    /// `persistIndex: false` is for high-frequency PROGRESS ticks (#24): they only need the published
    /// records for the UI, and re-encoding + atomically rewriting the JSON index on every tick was a
    /// main-thread disk write several times per second. State transitions keep the default and persist.
    func update(id: UUID, persistIndex: Bool = true, _ mutate: (inout DownloadRecord) -> Void) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        var copy = records[idx]
        mutate(&copy)
        records[idx] = copy
        if persistIndex { persist() }
    }

    /// Remove a record AND its on-disk file. The caller (DownloadManager) is responsible for cancelling
    /// any live URLSession task first.
    func remove(id: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
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
