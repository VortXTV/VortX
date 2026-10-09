import Foundation

/// Executes actual production manager methods, the movie caller, playback ref and OperationLease.
/// Only external dependencies are inert: sessions never open a socket, the store is memory-only,
/// preferences are ignored, and synthetic byte files stay inside this run's app/build directory.
@main
enum AppleNativeDownloadLeaseTests {
    static func function(_ source: String, _ marker: String) throws -> String {
        guard let range = source.range(of: marker),
              let start = source[range.upperBound...].firstIndex(of: "{") else {
            throw NSError(domain: "missing production method: \(marker)", code: 1)
        }
        var depth = 0
        for cursor in source[start...].indices {
            if source[cursor] == "{" { depth += 1 }
            if source[cursor] == "}" {
                depth -= 1
                if depth == 0 { return String(source[range.lowerBound...cursor]) }
            }
        }
        throw NSError(domain: "unterminated production method: \(marker)", code: 1)
    }

    static func section(_ source: String, _ start: String, _ end: String) throws -> String {
        guard let a = source.range(of: start),
              let b = source.range(of: end, range: a.upperBound..<source.endIndex) else {
            throw NSError(domain: "missing production section: \(start)", code: 1)
        }
        return String(source[a.lowerBound..<b.lowerBound])
    }

    static func command(_ arguments: [String], cwd: URL) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = cwd
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    static func main() throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[1])
        func resolve(_ path: String) -> URL {
            (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        }
        let producer = resolve(args[2])
        let output = resolve(args[3])
        let baseline = args.count > 4 ? args[4] : ""
        func read(_ path: String, productionRoot: URL? = nil) throws -> String {
            if !baseline.isEmpty, productionRoot == nil {
                let result = try command(["/usr/bin/git", "-C", root.path, "show", "\(baseline):\(path)"], cwd: root)
                guard result.0 == 0 else { throw NSError(domain: result.1, code: 1) }
                return result.1
            }
            return try String(contentsOf: (productionRoot ?? root).appendingPathComponent(path), encoding: .utf8)
        }
        let manager = try read("app/SourcesShared/DownloadManager.swift")
        let movie = try read("app/SourcesiOS/iOSDetailView.swift")
        let resolver = try read("app/SourcesShared/DebridResolver.swift", productionRoot: producer)
        let client = try read("app/SourcesShared/UsenetNodeClient.swift", productionRoot: producer)
        let models = try read("app/SourcesShared/DownloadModels.swift")
        let classifier = try read("app/SourcesShared/DownloadFailureClassifier.swift")
        var source = "import Foundation\n"
        source += "let fixtureRoot = URL(fileURLWithPath: \(String(reflecting: output.path)))\n"
        source += dependencies
        source += "\nenum UsenetNodeClient { final class NoRedirects {}\n"
        source += try function(client, "final class OperationLease:") + "\n}\n"
        source += try function(resolver, "struct DebridPlaybackRef:") + "\n"
        source += models + "\n" + classifier + "\n"
        source += try section(manager, "enum DownloadStartDisposition:", "/// The file-writing core")
        source += "\n@MainActor final class DebridCoordinator { static let shared = DebridCoordinator()\n"
        source += "weak var lastLease: UsenetNodeClient.OperationLease?; var lastOperationID: String?\n"
        source += "func resolvedPlaybackRef(for stream: CoreStream, episode: DebridEpisode? = nil, confirmedCachedHashes: Set<String>? = nil, confirmedUsenetURLs: Set<String>? = nil) async -> DebridPlaybackRef? { let lease = makeLease(); lastLease = lease; lastOperationID = lease.id; return DebridPlaybackRef(url: mediaURL, service: .torBox, infoHash: \"\", torrentId: nil, fileId: nil, fileIdx: nil, nativeUsenetLease: lease) }\n"
        source += try function(resolver, "func resolvedPlaybackURL(") + "\n}\n"
        source += "\n@MainActor final class DownloadManager {\n" + managerFields + "\n"
        if baseline.isEmpty {
            source += try section(manager, "private struct NativeSource {", "/// A session-namespaced task key")
        }
        let markers = [
            "private nonisolated static func taskKey(", "func download(", "func pause(id:",
            "func resume(id:", "func cancel(id:", "func orderedQueuedRecords()",
            "private func appendToQueueOrder(", "private func prependToQueueOrder(", "private func pruneQueueOrder()",
            "private func fillAvailableSlots()", "private func startTask(", "private func makeTask(",
            "private func bind(", "private func clearTask(", "private var activeWeight:",
            "private func transport(", "private func startQueued(", "private func recordID(",
            "private func recoverRecordID(", "private func beginForegroundAssertionIfNeeded(",
            "private func endForegroundAssertionIfIdle()", "private func endForegroundAssertion()",
            "private func fileExtension(", "nonisolated private static func looksLikeNonMedia(",
            "nonisolated static func downloadFailureDetail(",
            "nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,\n                                didFinishDownloadingTo location: URL)",
            "nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)"
        ]
        for marker in markers {
            if marker == "func download(" { source += "@discardableResult\n" }
            source += try function(manager, marker) + "\n"
        }
        if baseline.isEmpty {
            for marker in ["private func releaseNativeSource(", "private func nativeSourceDidClose(", "private func failNativeSource(", "nonisolated static func nativeDownloadFailureDetail("] {
                source += try function(manager, marker) + "\n"
            }
        }
        source += "}\n"
        source += try function(manager, "final class DownloadDestinationMap:") + "\n"
        source += "\n@MainActor final class MovieCaller { var meta: MovieMeta? = nil; let id = \"movie\"; let title = \"Synthetic\"; let seedBackdrop: String? = nil; var torrentPrime: Task<Void, Never>?\n"
        source += try function(movie, "private func downloadStream(_ stream: CoreStream, url: URL")
            .replacingOccurrences(of: "private func downloadStream", with: "func downloadStream")
        source += "\n}\n" + cases
        // Access adaptation only: production method bodies and external calls are preserved.
        source = source.replacingOccurrences(of: "fileprivate ", with: "")
            .replacingOccurrences(of: "private ", with: "")
            .replacingOccurrences(of: "#if canImport(UIKit)", with: "#if DOWNLOAD_FIXTURE_UIKIT")
        let generated = output.appendingPathComponent("production-download-methods.swift")
        try source.write(to: generated, atomically: true, encoding: .utf8)
        let executable = output.appendingPathComponent("fixture")
        var compile = ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-strict-concurrency=complete", "-warnings-as-errors", "-D", "DOWNLOAD_FIXTURE_UIKIT"]
        if !baseline.isEmpty { compile += ["-D", "BASELINE"] }
        compile += [generated.path, "-o", executable.path]
        let built = try command(compile, cwd: root)
        print(built.1, terminator: "")
        guard built.0 == 0 else { exit(built.0) }
        let ran = try command([executable.path], cwd: root)
        print(ran.1, terminator: "")
        guard ran.0 == 0 else { exit(ran.0) }
        if baseline.isEmpty {
            let paths = ["app/SourcesiOS/iOSDetailView.swift", "app/SourcesTV/DetailView.swift", "app/SourcesiOS/DownloadQualityPickerView.swift", "app/SourcesiOS/iOSBatchDownloadCoordinator.swift"]
            var transfers = 0
            for path in paths {
                let body = try read(path)
                let calls = body.components(separatedBy: "DownloadManager.shared.download(").dropFirst()
                for call in calls {
                    let tail = call.components(separatedBy: "nativeUsenetLease:").first ?? ""
                    guard tail.count < 600 else { fatalError("missing native transfer: \(path)") }
                    transfers += 1
                }
                guard !body.contains("await DebridCoordinator.shared.resolvedPlaybackURL(") else { fatalError("URL-only download resolve remains: \(path)") }
            }
            guard transfers == 6 else { fatalError("expected six download transfers, got \(transfers)") }
            print("PASS  all six production callers transfer the full native lease")
            guard !models.contains("OperationLease"), !models.contains("nativeUsenetLease") else { fatalError("lease serialized in download model") }
            print("PASS  persisted download model carries no operation lease")
        }
    }

    static let dependencies = #"""
let mediaURL = URL(string: "http://127.0.0.1:11470/nzb/stream?key=synthetic-operation")!
enum DebridService: Sendable, Equatable { case torBox }
enum DebridUsenetRoute: Sendable, Equatable { case native }
struct DebridEpisode { let season: Int; let episode: Int }
struct PlaybackMeta { let libraryId: String; let videoId: String; let type: String; let name: String; let poster: String?; let season: Int?; let episode: Int? }
struct MovieMeta { let id: String; let name: String; let poster: String? }
struct CoreStream {
    struct Hints { var filename: String? = nil }
    var isTorrent = false
    var isUsenet = true
    var name: String? = "Synthetic"
    var requestHeaders: [String: String]? = nil
    var behaviorHints: Hints? = nil
}
enum StreamRanking { static func signature(_ stream: CoreStream) -> String? { nil } }
enum EpisodePlaybackIdentity {
    static func usesSeriesLifecycle(type: String) -> Bool { type == "series" }
    static func resolvedEpisodeMediaURL(isUsenet: Bool, resolvedURL: URL?, fallbackURL: URL?) -> URL? { resolvedURL ?? (isUsenet ? nil : fallbackURL) }
}
func prepareTorrentStream(_ stream: CoreStream) -> Task<Void, Never>? { nil }
@MainActor final class CoreBridge { static let shared = CoreBridge(); var generation = 1 }
@MainActor enum StremioServer { static var nativeTransportSelected = true }
struct PlaybackMutationTarget {
    let generation: Int
    @MainActor static func capture(core: CoreBridge) -> Self { Self(generation: core.generation) }
    @MainActor func stillOwnsCurrentContext(core: CoreBridge) -> Bool { generation == core.generation }
}
final class Owner: @unchecked Sendable {
    private let lock = NSLock(); private var live = true
    var current: Bool { lock.withLock { live } }
    func retire() { lock.withLock { live = false } }
}
final class ControlLedger: @unchecked Sendable {
    static let shared = ControlLedger(); private let lock = NSLock(); private var paths: [String] = []
    func add(_ path: String) { lock.withLock { paths.append(path) } }
    func count(_ id: String) -> Int { lock.withLock { paths.filter { $0 == "/nzb/operations/\(id)/cancel" }.count } }
}
final class LogLedger: @unchecked Sendable {
    static let shared = LogLedger(); private let lock = NSLock(); private var entries: [String] = []
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var text: String { lock.withLock { entries.joined(separator: "\n") } }
}
final class URLSessionConfiguration: @unchecked Sendable {
    var identifier: String?; var timeoutIntervalForRequest = 0.0; var timeoutIntervalForResource = 0.0
    init(_ identifier: String? = nil) { self.identifier = identifier }
    static var `default`: URLSessionConfiguration { .init() }
    static func background(withIdentifier value: String) -> URLSessionConfiguration { .init(value) }
}
class URLSessionTask: @unchecked Sendable {
    let taskIdentifier: Int; var taskDescription: String?; var cancelled = false; var started = false
    init(id: Int) { taskIdentifier = id }
    func cancel() { cancelled = true }
    func resume() { started = true }
}
final class URLSessionDownloadTask: URLSessionTask, @unchecked Sendable {
    var pauseCallback: (@Sendable (Data?) -> Void)?
    var request: URLRequest?
    func cancel(byProducingResumeData callback: @escaping @Sendable (Data?) -> Void) { cancelled = true; pauseCallback = callback }
    func deliverPause() { pauseCallback?(Data([1, 2, 3])); pauseCallback = nil }
}
final class URLSession: @unchecked Sendable {
    let configuration: URLSessionConfiguration; private let lock = NSLock(); private var next = 0
    init(configuration: URLSessionConfiguration) { self.configuration = configuration }
    func downloadTask(with request: URLRequest) -> URLSessionDownloadTask {
        let id = lock.withLock { next += 1; return next }
        let task = URLSessionDownloadTask(id: id); task.request = request; return task
    }
    func downloadTask(withResumeData data: Data) -> URLSessionDownloadTask { downloadTask(with: URLRequest(url: mediaURL)) }
    func invalidateAndCancel() {}
    func data(for request: URLRequest, delegate: UsenetNodeClient.NoRedirects) async throws -> (Data, URLResponse) {
        ControlLedger.shared.add(request.url!.path)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor final class UserDefaults { static let standard = UserDefaults(); func set(_ value: Any, forKey key: String) {} }
struct UIBackgroundTaskIdentifier: Equatable { let value: Int; static let invalid = Self(value: -1) }
@MainActor final class UIApplication {
    static let shared = UIApplication(); private var next = 0; var assertions: Set<Int> = []
    func beginBackgroundTask(withName name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier { next += 1; assertions.insert(next); return .init(value: next) }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) { assertions.remove(id.value) }
}
final class HLSBackgroundEventBarrier: @unchecked Sendable {}
let NSURLSessionDownloadTaskResumeData = "synthetic-resume-data"
@MainActor final class DownloadStore {
    static var shared = DownloadStore(); var records: [DownloadRecord] = []
    nonisolated static func fileURL(forFilename filename: String) -> URL { fixtureRoot.appendingPathComponent(filename) }
    nonisolated static func ensureDownloadsDirectoryExists() throws { try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true) }
    func fileURL(for record: DownloadRecord) -> URL { Self.fileURL(forFilename: record.localFilename) }
    func record(id: UUID) -> DownloadRecord? { records.first { $0.id == id } }
    func upsert(_ record: DownloadRecord) { records.removeAll { $0.id == record.id }; records.append(record) }
    func update(id: UUID, persistIndex: Bool = true, _ mutation: (inout DownloadRecord) -> Void) { guard let index = records.firstIndex(where: { $0.id == id }) else { return }; mutation(&records[index]) }
    func remove(id: UUID) { if let record = record(id: id) { try? FileManager.default.removeItem(at: fileURL(for: record)) }; records.removeAll { $0.id == id } }
}
func makeLease(owner: Owner = Owner(), monitor: Bool = false) -> UsenetNodeClient.OperationLease {
    let lease = UsenetNodeClient.OperationLease(origin: URL(string: "http://127.0.0.1:11470")!, session: URLSession(configuration: .default), ownerIsCurrent: { owner.current })
    if monitor { lease.startMonitoring() }; return lease
}
"""#

    static let managerFields = #"""
    static var shared = DownloadManager()
    nonisolated static let backgroundSessionIdentifier = "tv.vortx.downloads.background"
    static let queueOrderDefaultsKey = "fixture"
    let store = DownloadStore.shared
    var maxConcurrentDownloads = 2
    var queueOrder: [UUID] = []
    var taskForRecord: [UUID: URLSessionDownloadTask] = [:]
    var recordForTask: [String: UUID] = [:]
    var resumeData: [UUID: Data] = [:]
    var pauseGenerations: [UUID: UUID] = [:]
    var schedulerCoordinator = DownloadSchedulerCoordinator()
    var unlockedSaveFailures: [UUID: Int] = [:]
    var awaitingUnlockRetry: Set<UUID> = []
    var lastProgressPush: [UUID: (bytes: Int64, at: TimeInterval)] = [:]
    nonisolated let destinations = DownloadDestinationMap()
    let foregroundSession = URLSession(configuration: .default)
    let backgroundSession = URLSession(configuration: .background(withIdentifier: DownloadManager.backgroundSessionIdentifier))
    var bgTask = UIBackgroundTaskIdentifier.invalid
    var insufficientStorage = false
    var isProtectedDataAvailable = true
    func storageShortfall(for record: DownloadRecord) -> Bool { insufficientStorage }
    nonisolated func logDownload(_ message: String) { LogLedger.shared.add(message) }
    nonisolated func beginByteBackgroundEventWork(for session: URLSession) -> HLSBackgroundEventBarrier? { nil }
    static func finishBackgroundEventWork(_ barrier: HLSBackgroundEventBarrier?) {}
"""#

    static let cases = #"""
@main @MainActor enum Fixture {
    static var failures = 0
    static func check(_ name: String, _ condition: Bool) { print("\(condition ? "PASS" : "FAIL")  \(name)"); if !condition { failures += 1 } }
    static func flush() async { for _ in 0..<6 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(10)) }
    static func reset() -> DownloadManager {
        DownloadStore.shared = DownloadStore(); DownloadManager.shared = DownloadManager(); return DownloadManager.shared
    }
    static func meta(_ id: String = UUID().uuidString) -> PlaybackMeta { .init(libraryId: id, videoId: id, type: "movie", name: "Synthetic", poster: nil, season: nil, episode: nil) }
    static func bytes(_ name: String) throws -> URL { let url = fixtureRoot.appendingPathComponent(name); try Data([0, 0, 0, 24, 102, 116, 121, 112]).write(to: url); return url }
    static func main() async throws {
        _ = reset()
        #if BASELINE
        await MovieCaller().downloadStream(CoreStream(), url: mediaURL)
        #else
        await MovieCaller().downloadStream(CoreStream(), url: mediaURL, owner: NativeDownloadOwner())
        #endif
        await flush()
        check("actual movie handoff retains native operation beyond resolver", DebridCoordinator.shared.lastLease?.isClosed == false)
        check("native handoff does not send premature operation cancellation", ControlLedger.shared.count(DebridCoordinator.shared.lastOperationID!) == 0)
        #if BASELINE
        exit(failures == 0 ? 0 : 1)
        #else
        let handed = DownloadStore.shared.records[0]
        check("native queue persists a noncredential marker", handed.remoteURL == DownloadManager.nativeSourceMarker && !handed.remoteURL.contains("synthetic-operation"))
        let movieLease = DebridCoordinator.shared.lastLease!
        DownloadManager.shared.cancel(id: handed.id)
        check("movie cancellation explicitly retires transferred operation", movieLease.isClosed)

        let manager = reset()
        var nativeStream = CoreStream()
        nativeStream.requestHeaders = ["Authorization": "Bearer must-not-persist-header", "Cookie": "must-not-persist-cookie"]
        func admit(_ lease: UsenetNodeClient.OperationLease, _ identity: PlaybackMeta = meta()) async -> DownloadRecord {
            await manager.download(stream: nativeStream, meta: identity, resolvedURL: mediaURL, sourceName: nil, qualityText: nil, nativeUsenetLease: lease, nativeOwner: NativeDownloadOwner())
        }
        let first = makeLease(); let identity = meta("duplicate"); let row = await admit(first, identity)
        let other = makeLease(); let duplicate = await admit(other, identity)
        check("duplicate closes newcomer and preserves accepted lease", duplicate.id == row.id && other.isClosed && !first.isClosed)
        _ = await admit(first, identity)
        check("duplicate identical reference cannot close accepted operation", !first.isClosed)
        check("native transfer uses process-owned foreground session", manager.recordForTask[DownloadManager.taskKey(manager.foregroundSession, manager.taskForRecord[row.id]!.taskIdentifier)] == row.id)
        check("native record and request exclude addon credential headers", row.headers == nil && manager.taskForRecord[row.id]!.request?.value(forHTTPHeaderField: "Authorization") == nil && manager.taskForRecord[row.id]!.request?.value(forHTTPHeaderField: "Cookie") == nil)
        check("native transfer takes existing background grace assertion", manager.bgTask != .invalid)
        let pausedTask = manager.taskForRecord[row.id]!
        manager.pause(id: row.id)
        check("pause retains native lease", !first.isClosed && manager.store.record(id: row.id)?.state == .paused)
        manager.resume(id: row.id)
        let resumedTask = manager.taskForRecord[row.id]!
        pausedTask.deliverPause(); await flush()
        check("late pause completion cannot pause resumed transfer", manager.store.record(id: row.id)?.state == .downloading && manager.taskForRecord[row.id] === resumedTask)
        let late = try bytes("late-native.bin")
        manager.urlSession(manager.foregroundSession, downloadTask: pausedTask, didFinishDownloadingTo: late)
        await flush()
        check("late foreground finish cannot install or close replacement", !first.isClosed && manager.taskForRecord[row.id] === resumedTask && !FileManager.default.fileExists(atPath: manager.store.fileURL(for: row).path))
        manager.urlSession(manager.foregroundSession, task: pausedTask, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
        await flush()
        check("late foreground failure cannot fail or close replacement", !first.isClosed && manager.taskForRecord[row.id] === resumedTask && manager.store.record(id: row.id)?.state == .downloading)
        manager.urlSession(manager.foregroundSession, downloadTask: resumedTask, didFinishDownloadingTo: try bytes("racing-native.bin"))
        // The delegate moved to its task-specific staging file, but has not entered MainActor yet.
        manager.pause(id: row.id); manager.resume(id: row.id)
        let finalTask = manager.taskForRecord[row.id]!
        await flush()
        check("already staged old callback cannot install over resumed task", !first.isClosed && manager.taskForRecord[row.id] === finalTask && !FileManager.default.fileExists(atPath: manager.store.fileURL(for: row).path))
        manager.urlSession(manager.foregroundSession, downloadTask: finalTask, didFinishDownloadingTo: try bytes("finished-native.bin"))
        await flush()
        check("actual success finalizer saves canonical bytes and closes lease", first.isClosed && manager.store.record(id: row.id)?.state == .completed && FileManager.default.fileExists(atPath: manager.store.fileURL(for: row).path))
        check("completion releases foreground assertion", manager.bgTask == .invalid)
        manager.cancel(id: row.id)

        manager.maxConcurrentDownloads = 0
        let queuedLease = makeLease(); let queued = await admit(queuedLease)
        check("accepted queue retains native operation without a live task", manager.store.record(id: queued.id)?.state == .queued && manager.taskForRecord[queued.id] == nil && !queuedLease.isClosed)
        manager.pause(id: queued.id)
        check("queued pause retains native operation", !queuedLease.isClosed && manager.store.record(id: queued.id)?.state == .paused)
        manager.cancel(id: queued.id)
        check("cancelled queued operation closes explicitly", queuedLease.isClosed)
        manager.maxConcurrentDownloads = 2

        manager.insufficientStorage = true
        let refusedLease = makeLease(); let refused = await admit(refusedLease)
        check("actual storage admission refusal closes native operation", refused.state == .failed && refusedLease.isClosed)
        manager.insufficientStorage = false
        let networkLease = makeLease(); let network = await admit(networkLease)
        let privateURL = URL(string: "http://127.0.0.1:11470/nzb/stream?key=must-not-export")!
        let privateError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [
            NSURLErrorFailingURLErrorKey: privateURL, "NSErrorFailingURLStringKey": privateURL.absoluteString,
            NSLocalizedDescriptionKey: "failed \(privateURL)", NSFilePathErrorKey: privateURL.absoluteString,
            NSURLSessionDownloadTaskResumeData: Data(privateURL.absoluteString.utf8)])
        manager.urlSession(manager.foregroundSession, task: manager.taskForRecord[network.id]!, didCompleteWithError: privateError)
        await flush()
        check("actual transfer failure closes operation", networkLease.isClosed && manager.store.record(id: network.id)?.state == .failed)
        check("native error URL capabilities stay out of logs and index", !LogLedger.shared.text.contains("must-not-export") && !(manager.store.record(id: network.id)?.errorText?.contains("must-not-export") ?? true))
        let saveLease = makeLease(); let save = await admit(saveLease)
        manager.urlSession(manager.foregroundSession, downloadTask: manager.taskForRecord[save.id]!, didFinishDownloadingTo: fixtureRoot.appendingPathComponent("absent-synthetic.bin"))
        await flush()
        check("actual save failure closes operation", saveLease.isClosed && manager.store.record(id: save.id)?.state == .failed)

        let retiredOwner = Owner(); retiredOwner.retire()
        let staleLease = makeLease(owner: retiredOwner); let stale = await admit(staleLease)
        check("already retired owner cannot enter transfer", stale.state == .failed && staleLease.isClosed && manager.taskForRecord[stale.id] == nil)
        let owner = Owner(); let ownedLease = makeLease(owner: owner, monitor: true); let owned = await admit(ownedLease)
        let ownedTask = manager.taskForRecord[owned.id]!
        owner.retire(); try? await Task.sleep(for: .milliseconds(150)); await flush()
        check("owner retirement fails and cancels exact active native task", ownedLease.isClosed && ownedTask.cancelled && manager.store.record(id: owned.id)?.state == .failed)
        let pausedOwner = Owner(); let pausedLease = makeLease(owner: pausedOwner, monitor: true); let paused = await admit(pausedLease)
        let ownerPausedTask = manager.taskForRecord[paused.id]!
        manager.pause(id: paused.id); pausedOwner.retire(); try? await Task.sleep(for: .milliseconds(150)); await flush()
        ownerPausedTask.deliverPause(); await flush()
        check("owner retirement also fails paused native row", pausedLease.isClosed && manager.store.record(id: paused.id)?.state == .failed)
        manager.maxConcurrentDownloads = 0
        let queuedOwner = Owner(); let retiringQueue = makeLease(owner: queuedOwner, monitor: true); let retiring = await admit(retiringQueue)
        queuedOwner.retire(); try? await Task.sleep(for: .milliseconds(150)); await flush()
        check("owner retirement also fails queued native row", retiringQueue.isClosed && manager.store.record(id: retiring.id)?.state == .failed)
        manager.maxConcurrentDownloads = 2

        let active = makeLease(); let activeRow = await admit(active)
        let prewarm = makeLease(); prewarm.close(); await flush()
        check("independent prewarm disposal preserves download operation", !active.isClosed && manager.store.record(id: activeRow.id)?.state == .downloading)
        manager.cancel(id: activeRow.id)
        await flush()
        check("exact native operation cancellation is sent once", ControlLedger.shared.count(active.id) == 1)
        let ownerCapture = NativeDownloadOwner(); CoreBridge.shared.generation += 1
        check("captured caller cannot use successor native authority", !ownerCapture.allows(CoreStream()))
        let resolvedBefore = DebridCoordinator.shared.lastOperationID
        await MovieCaller().downloadStream(CoreStream(), url: mediaURL, owner: ownerCapture)
        check("actual delayed movie caller rejects owner before resolver entry", DebridCoordinator.shared.lastOperationID == resolvedBefore)
        let retiredCallerLease = makeLease()
        let retiredCaller = await manager.download(stream: CoreStream(), meta: meta(), resolvedURL: mediaURL, sourceName: nil, qualityText: nil, nativeUsenetLease: retiredCallerLease, nativeOwner: ownerCapture)
        check("manager synchronously rejects original caller even if lease monitor has not closed", retiredCaller.state == .failed && retiredCallerLease.isClosed)
        let nativeModeOwner = NativeDownloadOwner()
        StremioServer.nativeTransportSelected = false
        check("native to legacy mode change cannot revive captured authority", !nativeModeOwner.isCurrent)
        let legacyModeOwner = NativeDownloadOwner()
        StremioServer.nativeTransportSelected = true
        check("legacy to native mode change cannot acquire successor authority", !legacyModeOwner.isCurrent)
        var direct = CoreStream(); direct.isUsenet = false
        direct.requestHeaders = ["Authorization": "ordinary-direct-header"]
        check("native owner gate leaves ordinary direct download unchanged", ownerCapture.allows(direct))
        let staleReplacement = await manager.download(stream: direct, meta: meta(), resolvedURL: URL(string: "https://invalid.example/replacement.mp4")!, sourceName: nil, qualityText: nil, nativeOwner: ownerCapture, requiresNativeOwner: true)
        check("retired native-origin retry cannot start a cloud/direct replacement", staleReplacement.state == .failed && manager.taskForRecord[staleReplacement.id] == nil)

        let nativeLease = makeLease(); let native = await admit(nativeLease)
        let http = await manager.download(stream: direct, meta: meta(), resolvedURL: URL(string: "https://invalid.example/file.mp4")!, sourceName: nil, qualityText: nil)
        let httpTask = manager.taskForRecord[http.id]!
        check("ordinary direct download retains required headers", http.headers?["Authorization"] == "ordinary-direct-header" && httpTask.request?.value(forHTTPHeaderField: "Authorization") == "ordinary-direct-header")
        // Explicitly use an equal ID in another session, matching the genuine per-session numbering.
        manager.recordForTask[DownloadManager.taskKey(manager.backgroundSession, manager.taskForRecord[native.id]!.taskIdentifier)] = http.id
        manager.cancel(id: native.id)
        check("native cleanup preserves another session's equal task id", manager.recordForTask.values.contains(http.id) && !httpTask.cancelled)
        manager.recordForTask.removeAll(); manager.taskForRecord.removeAll()
        let recovered = manager.recoverRecordID(for: httpTask, on: manager.backgroundSession, filename: http.localFilename)
        check("ordinary background completion still recovers persisted filename", recovered == http.id)

        manager.resume(id: retiring.id)
        check("cold native resume requires source reselection", manager.store.record(id: retiring.id)?.state == .failed && manager.taskForRecord[retiring.id] == nil)
        let serialized = String(decoding: try JSONEncoder().encode(manager.store.records), as: UTF8.self)
        check("serialized metadata contains neither native operation id, URL token nor addon credentials", !serialized.contains(active.id) && !serialized.contains("synthetic-operation") && !serialized.contains("must-not-persist"))
        print("Native download fixture: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
        #endif
    }
}
"""#
}
