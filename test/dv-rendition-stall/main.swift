// =============================================================================
// ReproHarness - drives the REAL VortXMKVRemuxStream + VortXRemuxHLSServer end to
// end on macOS against synthesized multi-audio / multi-subtitle MKVs, playing the
// AVPlayer role over loopback HTTP. Repro for the Beta 7 (build 189) field
// regression: master held past the 10s start watchdog, audio renditions absent /
// unlabeled, silent remux death on resume, mid-play spool exhaustion.
//
// Each CHECK prints REPRO-RED (bug present) or REPRO-GREEN (fixed behavior).
// Exit code = number of REPRO-RED checks, so the same binary proves red-before /
// green-after.
// =============================================================================

import Foundation
import AVFoundation
#if ENGINE_TRANSACTION_HARNESS
import Darwin
#endif

#if ENGINE_TRANSACTION_HARNESS
// Standalone shells for app services outside the player lane. The transaction gate below still compiles and
// calls the production AVPlayerEngineController, VortXRemuxHLSServer, VortXMKVRemuxStream, and PlayerLoadToken.
// These shells only make the otherwise app-wide dependency graph finite for one executable.
protocol PlayerEngine: AnyObject {}

enum PlayerEngineRouter {
    static func shouldDVRemux(url: URL) -> Bool { false }
    static func shouldPlainRemux(url: URL) -> Bool { url.pathExtension.lowercased() == "mkv" }
    static func plainRemuxEnabled() -> Bool { true }
    static func isPlainRemuxRetryCandidate(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "mkv"
    }
    static func dvRemuxEnabled(dvDisplayCapable: Bool) -> Bool { false }
}

enum DVDisplaySupport {
    @MainActor static var isCapable: Bool { false }
}

final class VortXExternalEngine: @unchecked Sendable {
    static let shared = VortXExternalEngine()
    var mountPlan: VortXEngineHostPolicy.MountPlan { .onDevice }
}

final class VortXRemoteRemuxMount: @unchecked Sendable {
    static let signallingTimeoutSeconds: Double = 0

    struct ReadinessReceipt: Sendable {
        let identity: VortXEngineHostPolicy.RemoteMountIdentity
        let status: VortXEngineProtocol.SessionStatus
    }

    enum ReadinessFailure: String, Error {
        case explicitFailure = "explicit-failure"
        case unhealthy = "unhealthy"
        case timeout = "readiness-timeout"
        case retired = "retired-mount"
        case cancelled
    }

    let playlistURL: URL
    let identity: VortXEngineHostPolicy.RemoteMountIdentity
    let retainsFullTimeline = false

    private init(playlistURL: URL) {
        self.playlistURL = playlistURL
        identity = .init(sessionID: "test", playlistURL: playlistURL.absoluteString)
    }

    static func open(
        input: URL,
        headers: [String: String]?,
        mode: VortXEngineProtocol.RemuxMode,
        startAtSeconds: Double,
        selectedAudioStreamIndex: Int? = nil,
        engine: VortXExternalEngine = .shared,
        onLost: @escaping @Sendable (VortXRemoteRemuxMount) -> Void
    ) async -> VortXRemoteRemuxMount? {
        nil
    }

    func awaitSignalling(
        timeoutSeconds: Double = VortXRemoteRemuxMount.signallingTimeoutSeconds
    ) async -> Result<ReadinessReceipt, ReadinessFailure> {
        .failure(.timeout)
    }

    func start() {}
    func invalidate() {}
    func markEngineReady() -> Bool { true }
    func awaitHDRFallbackCapability(timeoutSeconds: Double = 0) async -> Bool { false }

    var sourceDurationSeconds: Double { 0 }
    var timelineOriginSeconds: Double { 0 }
    var authoritativeFrameRate: Double { 0 }
    var declaredBandwidth: Int { 0 }
    var videoRange: String? { nil }
    var supportsHDRFallback: Bool { false }
    var sourceAudioTracks: [VortXEngineProtocol.AudioTrack] { [] }
    var selectedSourceAudioIndex: Int? { nil }
    var sourceSubtitleTracks: [VortXEngineProtocol.SubtitleTrack] { [] }
    var chapters: [(start: Double, title: String)] { [] }
    var isMountHealthy: Bool { false }
    var producedEdgeSeconds: Double { 0 }
    var mountProgress: VortXMKVRemuxStream.MountProgress {
        .init(
            producedBytes: 0,
            segmentCount: 0,
            initPublished: false,
            signalingPublished: false,
            ended: false,
            failed: false)
    }
}

struct LastStreamStore {
    struct Entry {
        var videoId: String
        var url: String
        var title: String
        var season: Int?
        var episode: Int?
        var name: String
        var poster: String?
        var type: String
        var qualityText: String?
        var bingeGroup: String?
        var torrent: Bool?
        var savedAt: Date
        var headers: [String: String]?
        var debridService: String?
        var infoHash: String?
        var debridFileId: Int?
        var debridTorrentId: Int?
        var fileIdx: Int?
        var linkSavedAt: Date?
    }
}

enum DebridService: String {
    case realDebrid, allDebrid, premiumize, torBox
}

struct DebridEpisode {
    let season: Int
    let episode: Int
    let sourceFilename: String?

    init(season: Int, episode: Int, sourceFilename: String? = nil) {
        self.season = season
        self.episode = episode
        self.sourceFilename = sourceFilename
    }
}

final class DebridCoordinator {
    static let shared = DebridCoordinator()

    func reresolve(
        service: DebridService,
        infoHash: String,
        torrentId: Int?,
        fileId: Int?,
        fileIdx: Int?,
        episode: DebridEpisode? = nil,
        requiresSemanticSelection: Bool
    ) async throws -> URL {
        throw URLError(.unsupportedURL)
    }
}

enum CatalogRowResolution {
    static func metaHandlesTMDB(providesMeta: Bool, idPrefixes: [String]) -> Bool {
        providesMeta && idPrefixes.contains { "tmdb:0".hasPrefix($0) }
    }
}

enum AddonTombstones {
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum VortXSyncManager {
    static var appliedAddonOrder: [String] { [] }
}

enum DetailMetaRecoveryPolicy {
    enum Resolution { case ready, pending, unresolved }
    enum EntryState { case ready, loading, failed, notStarted }

    static func resolution(entries: [EntryState]) -> Resolution {
        if entries.contains(where: {
            if case .ready = $0 { return true }
            return false
        }) {
            return .ready
        }
        return entries.isEmpty ? .unresolved : .pending
    }

    static func resolution(
        selectedID: String?,
        requestedID: String,
        entries: [EntryState]
    ) -> Resolution? {
        selectedID == requestedID ? resolution(entries: entries) : nil
    }
}

final class DebridKeys {
    static let shared = DebridKeys()
    func isConfigured(_ service: DebridService) -> Bool { false }
}

enum PlaybackSettings {
    static var torrentsDisabled: Bool { false }
}

enum StremioServer {
    static let base = "http://127.0.0.1"
    static let trailerResolverBase = "https://example.invalid"
}

final class SubtitleCueRenderer {
    struct Cue {}
    var hasCues: Bool { false }
    var offset: Double = 0
    static func parse(data: Data) -> [Cue] { [] }
    func load(cues: [Cue]) {}
    func clear() {}
    func activeText(atClock clock: Double) -> String? { nil }
}

enum SubtitleFileFetcher {
    static func fetch(_ url: URL, timeout: TimeInterval, completion: @escaping (Data?) -> Void) {
        completion(nil)
    }
}

enum SubtitleStyle {
    static let colorHex = "#FFFFFF"
    static let backgroundId = "outline"
    static let fontSize = 55
}

final class SubtitleOverlayView {
    func applyStyle() {}
    func setVideoBottomInset(_ inset: CGFloat) {}
    func setText(_ text: String?) {}
}

final class VXProbeState {
    static let shared = VXProbeState()
    func setPlayer(state: String, source: String, engine: String) {}
    func setPlayer(state: String, engine: String, buffering: Bool) {}
    func setPlayer(pos: Int, dur: Int?, engine: String) {}
}

extension VXProbe {
    static func event(_ category: String, _ message: String) {}
}
#endif

let fixtureDir = "/tmp/dd-dvstall/fixtures"

@discardableResult
func fetch(_ base: String, _ path: String, timeout: TimeInterval = 45)
    -> (status: Int, body: Data, latency: Double) {
    let url = URL(string: base + path)!
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var status = -1
    nonisolated(unsafe) var body = Data()
    let began = Date()
    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
        status = (response as? HTTPURLResponse)?.statusCode ?? -1
        body = data ?? Data()
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + timeout + 5)
    return (status, body, Date().timeIntervalSince(began))
}

func extinfSum(_ playlist: String) -> Double {
    playlist.split(separator: "\n")
        .filter { $0.hasPrefix("#EXTINF:") }
        .compactMap { Double($0.dropFirst("#EXTINF:".count).split(separator: ",")[0]) }
        .reduce(0, +)
}

func segmentURIs(_ playlist: String) -> [String] {
    playlist.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
}

var redCount = 0
func check(_ name: String, red: Bool, detail: String) {
    print("\(red ? "REPRO-RED " : "REPRO-GREEN") \(name) :: \(detail)")
    if red { redCount += 1 }
}

struct ScenarioResult {
    var masterStatus = -1
    var masterLatency = 0.0
    var masterBody = ""
    var mediaBody = ""
    var startupRenderedSeconds = 0.0
    var audioMediaTags = 0
    var audioMediaLines: [String] = []
    var subtitleMediaTags = 0
    var nonEmptyVTTs = 0
    var totalVTTs = 0
    var remuxFailedDuringRun = false
    var producedAtEnd = 0
    var segmentsAtEnd = 0
    var producerFrozeWhileHealthy = false
}

func runScenario(name: String, fixture: String, startAt: Double,
                 consumeSeconds: Double) -> ScenarioResult {
    print("=== SCENARIO \(name) fixture=\(fixture) startAt=\(Int(startAt))s ===")
    var result = ScenarioResult()
    let input = URL(fileURLWithPath: "\(fixtureDir)/\(fixture)")
    guard FileManager.default.fileExists(atPath: input.path) else {
        print("FATAL fixture missing: \(input.path)")
        exit(2)
    }
    guard let (server, playlistURL) = VortXRemuxHLSServer.make(
        input: input, headers: nil, mode: .plain, startAtSeconds: startAt) else {
        print("FATAL server did not bind")
        exit(2)
    }
    let base = "http://127.0.0.1:\(server.port)"
    server.start()

    // AVPlayer role: one long-poll master fetch.
    let master = fetch(base, "/master.m3u8")
    result.masterStatus = master.status
    result.masterLatency = master.latency
    result.masterBody = String(decoding: master.body, as: UTF8.self)
    print("master status=\(master.status) latency=\(String(format: "%.1f", master.latency))s bytes=\(master.body.count)")
    print(result.masterBody)
    result.audioMediaLines = result.masterBody.split(separator: "\n")
        .map(String.init)
        .filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }
    result.audioMediaTags = result.audioMediaLines.count
    result.subtitleMediaTags = result.masterBody.split(separator: "\n")
        .filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES") }.count

    if master.status == 200 {
        let media = fetch(base, "/media.m3u8")
        result.mediaBody = String(decoding: media.body, as: UTF8.self)
        result.startupRenderedSeconds = extinfSum(result.mediaBody)
        let segs = segmentURIs(result.mediaBody)
        print("media status=\(media.status) segs=\(segs.count) rendered=\(String(format: "%.1f", result.startupRenderedSeconds))s")

        _ = fetch(base, "/init.mp4")
        for uri in segs.prefix(3) { _ = fetch(base, "/" + uri) }
        server.markEngineReady()

        // Audio rendition routes.
        for line in result.masterBody.split(separator: "\n")
            where line.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") && line.contains("URI=") {
            if let uri = line.split(separator: "\"").last(where: { $0.hasSuffix(".m3u8") }) {
                let ap = fetch(base, "/" + uri, timeout: 10)
                let apBody = String(decoding: ap.body, as: UTF8.self)
                let auris = segmentURIs(apBody)
                print("audio playlist \(uri) status=\(ap.status) segs=\(auris.count)")
                if let initURI = apBody.split(separator: "\n")
                    .first(where: { $0.hasPrefix("#EXT-X-MAP:") })?
                    .split(separator: "\"").dropFirst().first {
                    let ai = fetch(base, "/" + initURI, timeout: 10)
                    print("audio init \(initURI) status=\(ai.status) bytes=\(ai.body.count)")
                }
                for auri in auris.prefix(2) {
                    let aseg = fetch(base, "/" + auri, timeout: 10)
                    print("audio seg \(auri) status=\(aseg.status) bytes=\(aseg.body.count)")
                }
            }
        }

        // Subtitle rendition routes: fetch EVERY startup VTT of rendition 0 and count cue-bearing docs.
        for line in result.masterBody.split(separator: "\n")
            where line.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES") {
            guard let uri = line.split(separator: "\"").last(where: { $0.hasSuffix(".m3u8") }) else { continue }
            let sp = fetch(base, "/" + uri, timeout: 10)
            let spBody = String(decoding: sp.body, as: UTF8.self)
            let suris = segmentURIs(spBody)
            print("subs playlist \(uri) status=\(sp.status) segs=\(suris.count)")
            for suri in suris {
                let vtt = fetch(base, "/" + suri, timeout: 10)
                let text = String(decoding: vtt.body, as: UTF8.self)
                result.totalVTTs += 1
                if text.contains("-->") { result.nonEmptyVTTs += 1 }
            }
            break   // rendition 0 is enough for the cue-presence check
        }

        // Steady-state consumption: poll + consume like a playing AVPlayer for `consumeSeconds`.
        var lastProduced = -1
        var lastProducedChange = Date()
        var served = Set<String>()
        let consumeEnd = Date().addingTimeInterval(consumeSeconds)
        while Date() < consumeEnd {
            let progress = server.mountProgress
            if progress.failed {
                result.remuxFailedDuringRun = true
                print("REMUX FAILED during steady state (produced=\(progress.producedBytes) segs=\(progress.segmentCount))")
                break
            }
            if progress.ended { break }
            if progress.producedBytes != lastProduced {
                lastProduced = progress.producedBytes
                lastProducedChange = Date()
            } else if Date().timeIntervalSince(lastProducedChange) > 8 {
                result.producerFrozeWhileHealthy = true
                print("PRODUCER FROZE >8s at produced=\(progress.producedBytes) segs=\(progress.segmentCount)")
                break
            }
            let refresh = fetch(base, "/media.m3u8", timeout: 10)
            if refresh.status != 200 {
                result.remuxFailedDuringRun = true
                print("media.m3u8 -> \(refresh.status) during steady state")
                break
            }
            for uri in segmentURIs(String(decoding: refresh.body, as: UTF8.self)).prefix(6)
                where !served.contains(uri) {
                served.insert(uri)
                _ = fetch(base, "/" + uri, timeout: 10)
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        let final = server.mountProgress
        result.producedAtEnd = final.producedBytes
        result.segmentsAtEnd = final.segmentCount
        if final.failed { result.remuxFailedDuringRun = true }
        print("steady-state end produced=\(final.producedBytes) segs=\(final.segmentCount) failed=\(final.failed) ended=\(final.ended)")
    } else {
        let progress = server.mountProgress
        print("master DID NOT SERVE (status=\(master.status)); progress produced=\(progress.producedBytes) segs=\(progress.segmentCount) init=\(progress.initPublished) failed=\(progress.failed)")
        if progress.failed { result.remuxFailedDuringRun = true }
    }

    server.invalidate()
    Thread.sleep(forTimeInterval: 0.5)
    return result
}

// MARK: - REAL-CONSUMER gate: an actual AVPlayer plays the served stream continuously.
//
// The production-side scenarios below drive the server the way a well-behaved client would, but they cannot
// observe CONSUMPTION dynamics - the build 190 field regression (media window sliding at production speed,
// AVPlayer skip/stall/demote) passed all of them. This scenario is the gate that catches that class: a real
// AVFoundation HLS client plays for a minute and its clock must advance continuously with no seek-jumps.

struct ConsumerResult {
    var reachedSeconds = 0.0
    var wallSeconds = 0.0
    var maxForwardJump = 0.0
    var maxBackwardJump = 0.0
    var longestStall = 0.0
    var itemError: String?
    var remuxFailed = false
}

/// Serve the fixture over the conformance range server at a PACED byte rate, so the producer and the player
/// race the way they do against a real debrid link. Unpaced local input makes production instant, the live
/// playlist covers the whole file before AVPlayer's first fetch, and the client starts at the live edge -
/// a shape the field never produces and one that would let a windowing bug through this gate.
func startPacedSource(fixture: String, bytesPerSecond: Int) -> (process: Process, url: URL) {
    let portFile = "/tmp/dd-dvpin/paced-port-\(UUID().uuidString.prefix(8))"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "test/player-conformance/range-server.py",
                         "\(fixtureDir)/\(fixture)", portFile, "127.0.0.1",
                         String(bytesPerSecond)]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let deadline = Date().addingTimeInterval(10)
    var port = 0
    while Date() < deadline, port == 0 {
        if let text = try? String(contentsOfFile: portFile, encoding: .utf8),
           let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            port = value
        } else {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    guard port != 0 else { print("FATAL paced source did not start"); exit(2) }
    return (process, URL(string: "http://127.0.0.1:\(port)/\(fixture)")!)
}

func consumerScenario(name: String, fixture: String, startAt: Double,
                      playSeconds: Double, pacedBytesPerSecond: Int) -> ConsumerResult {
    print("=== CONSUMER \(name) fixture=\(fixture) startAt=\(Int(startAt))s play=\(Int(playSeconds))s paced=\(pacedBytesPerSecond)B/s ===")
    var result = ConsumerResult()
    let source = startPacedSource(fixture: fixture, bytesPerSecond: pacedBytesPerSecond)
    defer { source.process.terminate() }
    guard let (server, playlistURL) = VortXRemuxHLSServer.make(
        input: source.url, headers: nil, mode: .plain, startAtSeconds: startAt) else {
        print("FATAL consumer server did not bind"); exit(2)
    }
    server.start()
    let item = AVPlayerItem(url: playlistURL)
    let player = AVPlayer(playerItem: item)
    player.play()

    let wallStart = Date()
    var engineReadySent = false
    var lastTime = -1.0
    var hasAdvanced = false   // startup buffering before first motion is latency, not a mid-play stall
    var stallStart: Date?
    let deadline = wallStart.addingTimeInterval(playSeconds + 30)   // startup allowance beyond play window
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if item.status == .failed {
            result.itemError = item.error.map(String.init(describing:)) ?? "failed"
            break
        }
        if item.status == .readyToPlay, !engineReadySent {
            engineReadySent = true
            server.markEngineReady()   // mirror AVPlayerEngine's readyToPlay hook
            player.play()
        }
        let progress = server.mountProgress
        if progress.failed { result.remuxFailed = true; break }
        let now = item.currentTime().seconds
        guard now.isFinite else { continue }
        if lastTime >= 0 {
            let delta = now - lastTime
            if delta > 0.05 {
                if let began = stallStart {
                    result.longestStall = max(result.longestStall, Date().timeIntervalSince(began))
                    stallStart = nil
                }
                let expected = 0.6   // one 0.5s sample at rate 1.0 plus jitter
                if hasAdvanced, delta > expected {
                    result.maxForwardJump = max(result.maxForwardJump, delta)
                }
                hasAdvanced = true
            } else if delta < -0.5 {
                result.maxBackwardJump = min(result.maxBackwardJump, delta)
            } else if hasAdvanced {
                if stallStart == nil { stallStart = Date() }
            }
        }
        lastTime = max(lastTime, now)
        result.reachedSeconds = max(result.reachedSeconds, now)
        if result.reachedSeconds >= playSeconds { break }
    }
    if let began = stallStart {
        result.longestStall = max(result.longestStall, Date().timeIntervalSince(began))
    }
    result.wallSeconds = Date().timeIntervalSince(wallStart)
    print(String(format: "consumer end reached=%.1fs wall=%.1fs maxFwdJump=%.2fs maxBackJump=%.2fs longestStall=%.1fs itemError=%@ remuxFailed=%@",
                 result.reachedSeconds, result.wallSeconds, result.maxForwardJump,
                 result.maxBackwardJump, result.longestStall,
                 result.itemError ?? "none", String(result.remuxFailed)))
    player.pause()
    server.invalidate()
    Thread.sleep(forTimeInterval: 0.5)
    return result
}

// MARK: - REAL-CONSUMER SELECTION gate.
//
// The consumer gate above proves the stream PLAYS. It cannot prove a viewer can CHANGE anything: the field
// report on build 191 was that audio showed one name with no options, subtitles showed Off while built-in
// subs rendered, and picking a row buffered without switching. Audio now keeps its complete source inventory
// outside AVFoundation and remounts one selected in-band primary. The direct remount receipts below are
// supplemental producer evidence only, not a consumer audio switch. This gate drives a REAL AVPlayer, waits
// for steady playback, then SELECTS an alternate subtitle rendition mid-play and requires three things:
//   1. AVPlayerItem.currentMediaSelection reports the option we asked for (the selection BOUND),
//   2. the server actually SERVED that rendition's own resources afterwards (the switch reached the wire),
//   3. playback continued for 20s+ with no stall, no error and a monotonically advancing clock.

struct SwitchOutcome {
    var requested = ""
    var observed = ""
    var servedRenditionResources = false
    var secondsPlayedAfter = 0.0
    var longestStallAfter = 0.0
    var errorAfter: String?
    var attempted = false
    /// Wall seconds between `item.select(_:in:)` returning and `currentMediaSelection` reporting the pick.
    /// The chrome re-reads the engine's track list 0.25s after a tap, so a settle slower than that is what
    /// makes a viewer's checkmark jump back with the stream buffering behind it.
    var settleSeconds = -1.0
}

struct SelectionResult {
    var audioOptions: [String] = []
    var selectedNativeAudioName: String?
    var subtitleOptions: [String] = []
    var subtitles = SwitchOutcome()
    var itemError: String?
    var remuxFailed = false
    var reachedSecondsBeforeSwitch = 0.0
    var sourceAudioRows: [(index: Int, title: String)] = []
    var selectedSourceAudioIndex: Int?
}

/// Pump the main run loop until `ready()` returns true or `seconds` elapse. Returns whether it went true.
@discardableResult
func pump(seconds: Double, until ready: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if ready() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }
    return ready()
}

func loadGroup(_ asset: AVAsset, _ characteristic: AVMediaCharacteristic) -> AVMediaSelectionGroup? {
    nonisolated(unsafe) var group: AVMediaSelectionGroup?
    nonisolated(unsafe) var done = false
    Task {
        group = try? await asset.loadMediaSelectionGroup(for: characteristic)
        done = true
    }
    pump(seconds: 20) { done }
    return group
}

/// Play for `seconds`, reporting how far the clock advanced and the longest mid-play stall. Any item error
/// is captured. Mirrors the continuity rules of `consumerScenario` so a switch cannot hide a stall.
func observePlayback(item: AVPlayerItem, seconds: Double) -> (played: Double, longestStall: Double, error: String?) {
    let start = item.currentTime().seconds
    var last = start
    var stallStart: Date?
    var longestStall = 0.0
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if item.status == .failed {
            return (max(0, last - start), longestStall,
                    item.error.map(String.init(describing:)) ?? "failed")
        }
        let now = item.currentTime().seconds
        guard now.isFinite else { continue }
        if now - last > 0.05 {
            if let began = stallStart {
                longestStall = max(longestStall, Date().timeIntervalSince(began))
                stallStart = nil
            }
            last = now
        } else if stallStart == nil {
            stallStart = Date()
        }
    }
    if let began = stallStart { longestStall = max(longestStall, Date().timeIntervalSince(began)) }
    return (max(0, last - start), longestStall, nil)
}

/// Did the server serve any resource whose logged path matches `marker` after log index `since`?
func servedSince(_ since: Int, marker: String) -> Bool {
    DiagnosticsLog.capturedLines().dropFirst(since)
        .contains { $0.contains("hls resp") && $0.contains(marker) }
}

func selectionScenario(name: String, fixture: String, playSeconds: Double,
                       holdSeconds: Double, pacedBytesPerSecond: Int) -> SelectionResult {
    print("=== SELECTION \(name) fixture=\(fixture) ===")
    var result = SelectionResult()
    let source = startPacedSource(fixture: fixture, bytesPerSecond: pacedBytesPerSecond)
    defer { source.process.terminate() }
    guard let (server, playlistURL) = VortXRemuxHLSServer.make(
        input: source.url, headers: nil, mode: .plain, startAtSeconds: 0) else {
        print("FATAL selection server did not bind"); exit(2)
    }
    server.start()
    let item = AVPlayerItem(url: playlistURL)
    let player = AVPlayer(playerItem: item)
    player.play()

    guard pump(seconds: 60, until: { item.status == .readyToPlay || item.status == .failed }) ,
          item.status == .readyToPlay else {
        result.itemError = item.error.map(String.init(describing:)) ?? "never became readyToPlay"
        print("selection: item never readyToPlay (\(result.itemError!))")
        server.invalidate()
        return result
    }
    server.markEngineReady()
    player.play()

    // Steady playback first: a selection made before the stream is genuinely rolling proves nothing.
    let warm = observePlayback(item: item, seconds: playSeconds)
    result.reachedSecondsBeforeSwitch = item.currentTime().seconds
    result.itemError = warm.error
    if server.mountProgress.failed { result.remuxFailed = true }
    result.sourceAudioRows = server.sourceAudioTracks.map { ($0.sourceIndex, $0.title) }
    result.selectedSourceAudioIndex = server.selectedSourceAudioIndex
    print(String(format: "selection warm-up: clock=%.1fs advanced=%.1fs stall=%.1fs",
                 result.reachedSecondsBeforeSwitch, warm.played, warm.longestStall))

    let audioGroup = loadGroup(item.asset, .audible)
    let subGroup = loadGroup(item.asset, .legible)
    // Mirror AVPlayerEngine.loadSelectionGroups: the app owns selection from here on, so the framework must
    // stop re-applying its own automatic criteria over an explicit pick. Set at the same point in the
    // sequence, so this gate exercises the configuration that actually ships.
    player.appliesMediaSelectionCriteriaAutomatically = false
    result.audioOptions = audioGroup?.options.map(\.displayName) ?? []
    result.subtitleOptions = subGroup?.options.map(\.displayName) ?? []
    print("selection groups: audio=\(result.audioOptions) subtitles=\(result.subtitleOptions)")
    // What AVFoundation picked on its own, BEFORE anything asked it to. A legible rendition auto-selected
    // here renders subtitles the viewer never asked for, and any chrome that reports "Off" while this is
    // non-nil is lying about the state (the build 191 "built-in subs show but settings say off" report).
    result.selectedNativeAudioName = audioGroup
        .flatMap { item.currentMediaSelection.selectedMediaOption(in: $0)?.displayName }
    let initialAudio = result.selectedNativeAudioName ?? "none"
    let initialSubtitle = subGroup
        .flatMap { item.currentMediaSelection.selectedMediaOption(in: $0)?.displayName } ?? "none"
    print("selection at mount (AVFoundation's own automatic pick): audio=\(initialAudio) subtitle=\(initialSubtitle)")

    // --- subtitle switch ---
    if let group = subGroup, !group.options.isEmpty {
        let current = item.currentMediaSelection.selectedMediaOption(in: group)
        if let target = group.options.first(where: { $0 != current }) {
            result.subtitles.attempted = true
            result.subtitles.requested = target.displayName
            let mark = DiagnosticsLog.capturedLines().count
            let selectAt = Date()
            item.select(target, in: group)
            if pump(seconds: 10, until: {
                item.currentMediaSelection.selectedMediaOption(in: group) == target
            }) { result.subtitles.settleSeconds = Date().timeIntervalSince(selectAt) }
            result.subtitles.observed = item.currentMediaSelection
                .selectedMediaOption(in: group)?.displayName ?? "nil"
            let after = observePlayback(item: item, seconds: holdSeconds)
            result.subtitles.secondsPlayedAfter = after.played
            result.subtitles.longestStallAfter = after.longestStall
            result.subtitles.errorAfter = after.error
            result.subtitles.servedRenditionResources = servedSince(mark, marker: "subs")
            print(String(format: "subtitle switch: requested=%@ observed=%@ settle=%.2fs served=%@ played=%.1fs stall=%.1fs",
                         result.subtitles.requested, result.subtitles.observed, result.subtitles.settleSeconds,
                         String(result.subtitles.servedRenditionResources),
                         result.subtitles.secondsPlayedAfter, result.subtitles.longestStallAfter))
        } else {
            print("subtitle switch: NO alternate option exists (options=\(result.subtitleOptions.count))")
        }
    }

    if server.mountProgress.failed { result.remuxFailed = true }
    player.pause()
    server.invalidate()
    Thread.sleep(forTimeInterval: 0.5)
    return result
}

struct SourceRemountReceipt {
    let requestedSourceIndex: Int
    let sourceAudioIndices: [Int]
    let selectedSourceIndex: Int?
    let timelineOriginSeconds: Double
    let audioMediaLines: [String]
    let failed: Bool
}

/// Mount one immutable source index as the sole in-band primary at the carried source playhead.
/// This is supplemental producer evidence for AVPlayerEngine's replacement transaction. It does not invoke
/// setAudioTrack and must not be reported as a physical consumer audio switch; the focused player contract
/// owns the transaction and rollback state gate.
func sourceRemountReceipt(fixture: String,
                          sourceIndex: Int,
                          sourcePlayhead: Double) -> SourceRemountReceipt {
    let input = URL(fileURLWithPath: "\(fixtureDir)/\(fixture)")
    guard let (server, _) = VortXRemuxHLSServer.make(
        input: input,
        headers: nil,
        mode: .plain,
        startAtSeconds: sourcePlayhead,
        selectedAudioStreamIndex: sourceIndex) else {
        print("FATAL source remount server did not bind")
        exit(2)
    }
    let base = "http://127.0.0.1:\(server.port)"
    server.start()
    let master = fetch(base, "/master.m3u8")
    let audioLines = String(decoding: master.body, as: UTF8.self)
        .split(separator: "\n")
        .map(String.init)
        .filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }
    let receipt = SourceRemountReceipt(
        requestedSourceIndex: sourceIndex,
        sourceAudioIndices: server.sourceAudioTracks.map(\.sourceIndex),
        selectedSourceIndex: server.selectedSourceAudioIndex,
        timelineOriginSeconds: server.timelineOriginSeconds,
        audioMediaLines: audioLines,
        failed: master.status != 200 || server.mountProgress.failed)
    server.invalidate()
    Thread.sleep(forTimeInterval: 0.25)
    return receipt
}

func judgeSwitch(_ label: String, _ outcome: SwitchOutcome, holdSeconds: Double, optionCount: Int) {
    check("selection \(label): an alternate rendition is offered at all",
          red: optionCount < 2,
          detail: "options=\(optionCount) (field: the audio menu showed one name and no choices)")
    guard optionCount >= 2 else { return }
    check("selection \(label): selection BINDS (currentMediaSelection reports the pick)",
          red: !outcome.attempted || outcome.observed != outcome.requested,
          detail: String(format: "requested=%@ observed=%@ settled in %.2fs",
                         outcome.requested, outcome.observed, outcome.settleSeconds))
    check("selection \(label): the picked rendition is actually SERVED",
          red: !outcome.servedRenditionResources,
          detail: "served=\(outcome.servedRenditionResources) (field: the stream buffered and nothing changed)")
    check("selection \(label): playback continues \(Int(holdSeconds))s after the switch",
          red: outcome.secondsPlayedAfter < holdSeconds - 6
              || outcome.longestStallAfter > 5.0 || outcome.errorAfter != nil,
          detail: String(format: "played=%.1fs of %.0fs stall=%.1fs error=%@",
                         outcome.secondsPlayedAfter, holdSeconds, outcome.longestStallAfter,
                         outcome.errorAfter ?? "none"))
}

#if ENGINE_TRANSACTION_HARNESS
@MainActor
private final class EngineTransactionDelegate: MPVPlayerDelegate {
    private(set) var errors: [String] = []

    func propertyChange(propertyName: String, data: Any?, loadToken: PlayerLoadToken) {
        if propertyName == MPVProperty.endFileError {
            errors.append(data.map(String.init(describing:)) ?? "unknown")
        }
    }
}

private struct EngineTransactionResult {
    var initialRows: [Int] = []
    var rowsAfterReady: [Int] = []
    var targetSourceIndex: Int?
    var selectedAfterReady: Int?
    var tokenWasReused = false
    var sourceSecondsBeforeSwitch = 0.0
    var sourceSecondsAtReady = 0.0
    var advancedAfterReady = 0.0
    var longestStallAfterReady = 0.0
    var errors: [String] = []
    var sawProductionSelection = false
    var sawProductionReady = false
    var sawProductionRestore = false
}

private struct EngineRollbackResult {
    var sourceWasSuspended = false
    var rollbackCount = 0
    var targetFailureReason: String?
    var priorSourceIndex: Int?
    var targetSourceIndex: Int?
    var selectedAfterRollback: Int?
    var tokenWasReused = false
    var sourceSecondsBeforeSwitch = 0.0
    var rollbackSourceSeconds: Double?
    var advancedAfterRollback = 0.0
    var errors: [String] = []
    var sawTargetFailure = false
    var sawRollbackReady = false
    var sawRollbackRestore = false
}

@MainActor
private func waitForEngineState(
    timeout: TimeInterval,
    _ predicate: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    return predicate()
}

/// Execute the physical source-remount transaction through the production controller. No private state is
/// seeded: a real HLS mount publishes the source inventory, then the public picker entry point performs the
/// same-token loadFile remount and production readiness/intent restoration.
@MainActor
private func engineTransactionSuccessScenario(
    fixture: String,
    pacedBytesPerSecond: Int
) -> EngineTransactionResult {
    print("=== ENGINE TRANSACTION SUCCESS fixture=\(fixture) ===")
    var result = EngineTransactionResult()
    let source = startPacedSource(fixture: fixture, bytesPerSecond: pacedBytesPerSecond)
    defer {
        if source.process.isRunning { source.process.terminate() }
    }

    let delegate = EngineTransactionDelegate()
    let engine = AVPlayerEngineController()
    engine.playDelegate = delegate
    engine.configureResumeOrigin(seconds: 18)
    let initialToken = engine.loadFile(
        source.url,
        headers: nil,
        live: false,
        audioSidecar: nil,
        reusing: nil)

    let initialReady = waitForEngineState(timeout: 40) {
        let rows = engine.tracks(ofType: "audio")
        return rows.count == 5
            && rows.contains(where: \.selected)
            && engine.playbackPositionSeconds >= 18
    }
    guard initialReady else {
        result.errors = delegate.errors + ["initial production engine mount did not become ready"]
        engine.stop()
        return result
    }

    let initialTracks = engine.tracks(ofType: "audio")
    result.initialRows = initialTracks.map(\.id)
    guard let initialSelected = initialTracks.first(where: \.selected)?.id,
          let target = initialTracks.first(where: { $0.id != initialSelected })?.id else {
        result.errors = delegate.errors + ["source inventory did not provide a replacement target"]
        engine.stop()
        return result
    }
    result.targetSourceIndex = target

    _ = waitForEngineState(timeout: 8) {
        engine.playbackPositionSeconds >= 20
    }
    result.sourceSecondsBeforeSwitch = engine.playbackPositionSeconds
    let logOffset = DiagnosticsLog.capturedLines().count
    engine.setAudioTrack(target)

    let replacementReady = waitForEngineState(timeout: 40) {
        let transactionLines = DiagnosticsLog.capturedLines().dropFirst(logOffset)
        return transactionLines.contains(where: {
            $0.contains("audio replacement generation") && $0.contains("reached source ready")
        }) && transactionLines.contains(where: {
            $0.contains("playback intent restored once")
        })
    }
    let transactionLines = Array(DiagnosticsLog.capturedLines().dropFirst(logOffset))
    result.sawProductionSelection = transactionLines.contains {
        $0.contains("audio source selected source=\(target)")
    }
    result.sawProductionReady = transactionLines.contains {
        $0.contains("audio replacement generation") && $0.contains("reached source ready")
    }
    result.sawProductionRestore = transactionLines.contains {
        $0.contains("playback intent restored once")
    }
    result.tokenWasReused = engine.activeLoadToken == initialToken
    let replacementTracks = replacementReady ? engine.tracks(ofType: "audio") : []
    result.rowsAfterReady = replacementTracks.map(\.id)
    result.selectedAfterReady = replacementTracks.first(where: \.selected)?.id
    result.sourceSecondsAtReady = engine.playbackPositionSeconds

    if replacementReady {
        var lastPosition = result.sourceSecondsAtReady
        var lastAdvance = Date()
        let targetAdvance = 20.0
        let deadline = Date().addingTimeInterval(targetAdvance + 15)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            let now = engine.playbackPositionSeconds
            if now > lastPosition + 0.05 {
                result.longestStallAfterReady = max(
                    result.longestStallAfterReady,
                    Date().timeIntervalSince(lastAdvance))
                lastAdvance = Date()
                lastPosition = now
            }
            result.advancedAfterReady = max(
                result.advancedAfterReady,
                now - result.sourceSecondsAtReady)
            if result.advancedAfterReady >= targetAdvance { break }
        }
        result.longestStallAfterReady = max(
            result.longestStallAfterReady,
            Date().timeIntervalSince(lastAdvance))
    }
    result.errors = delegate.errors
    engine.stop()
    return result
}

/// Force the requested remount's real AVPlayer item to fail by pausing the paced HTTP origin. The origin
/// resumes after AVFoundation has rejected that target, so the controller's single rollback remount can open
/// the same immutable source and restore the prior audio at the captured playhead.
@MainActor
private func engineTransactionRollbackScenario(
    fixture: String,
    pacedBytesPerSecond: Int
) -> EngineRollbackResult {
    print("=== ENGINE TRANSACTION ROLLBACK fixture=\(fixture) ===")
    var result = EngineRollbackResult()
    let source = startPacedSource(fixture: fixture, bytesPerSecond: pacedBytesPerSecond)
    let sourcePID = source.process.processIdentifier
    defer {
        _ = Darwin.kill(sourcePID, SIGCONT)
        if source.process.isRunning { source.process.terminate() }
    }

    let delegate = EngineTransactionDelegate()
    let engine = AVPlayerEngineController()
    engine.playDelegate = delegate
    engine.configureResumeOrigin(seconds: 36)
    let initialToken = engine.loadFile(
        source.url,
        headers: nil,
        live: false,
        audioSidecar: nil,
        reusing: nil)

    let initialReady = waitForEngineState(timeout: 40) {
        let rows = engine.tracks(ofType: "audio")
        return rows.count == 5
            && rows.contains(where: \.selected)
            && engine.playbackPositionSeconds >= 36
    }
    guard initialReady else {
        result.errors = delegate.errors + ["rollback setup mount did not become ready"]
        engine.stop()
        return result
    }

    let tracks = engine.tracks(ofType: "audio")
    guard let prior = tracks.first(where: \.selected)?.id,
          let target = tracks.first(where: { $0.id != prior })?.id else {
        result.errors = delegate.errors + ["rollback setup had no alternate source target"]
        engine.stop()
        return result
    }
    result.priorSourceIndex = prior
    result.targetSourceIndex = target
    _ = waitForEngineState(timeout: 8) {
        engine.playbackPositionSeconds >= 38
    }
    result.sourceSecondsBeforeSwitch = engine.playbackPositionSeconds
    let logOffset = DiagnosticsLog.capturedLines().count

    result.sourceWasSuspended = Darwin.kill(sourcePID, SIGSTOP) == 0
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 31) {
        _ = Darwin.kill(sourcePID, SIGCONT)
    }
    engine.setAudioTrack(target)

    let rollbackReady = waitForEngineState(timeout: 55) {
        let transactionLines = DiagnosticsLog.capturedLines().dropFirst(logOffset)
        return transactionLines.contains(where: {
            $0.contains("audio replacement failed") && $0.contains("one rollback")
        }) && transactionLines.contains(where: {
            $0.contains("audio replacement generation")
                && $0.contains("reached source ready source=\(prior)")
        }) && transactionLines.contains(where: {
            $0.contains("playback intent restored once")
                && $0.contains("audio=\(prior)")
        })
    }

    let transactionLines = Array(DiagnosticsLog.capturedLines().dropFirst(logOffset))
    let rollbackLines = transactionLines.filter {
        $0.contains("audio replacement failed") && $0.contains("one rollback")
    }
    result.rollbackCount = rollbackLines.count
    result.targetFailureReason = rollbackLines.first.flatMap { line in
        guard let reasonStart = line.range(of: "audio replacement failed (")?.upperBound,
              let reasonEnd = line.range(
                of: ") -> one rollback",
                range: reasonStart..<line.endIndex)?.lowerBound
        else { return nil }
        return String(line[reasonStart..<reasonEnd])
    }
    result.sawTargetFailure = result.targetFailureReason == "resource unavailable"
    result.sawRollbackReady = transactionLines.contains {
        $0.contains("audio replacement generation")
            && $0.contains("reached source ready source=\(prior)")
    }
    result.sawRollbackRestore = transactionLines.contains {
        $0.contains("playback intent restored once") && $0.contains("audio=\(prior)")
    }
    result.rollbackSourceSeconds = rollbackLines.first.flatMap { line in
        guard let atRange = line.range(of: " at "),
              let secondsRange = line.range(
                of: "s",
                range: atRange.upperBound..<line.endIndex)
        else { return nil }
        return Double(line[atRange.upperBound..<secondsRange.lowerBound])
    }
    result.tokenWasReused = engine.activeLoadToken == initialToken
    result.selectedAfterRollback = rollbackReady
        ? engine.tracks(ofType: "audio").first(where: \.selected)?.id
        : nil

    if rollbackReady {
        let restoredAt = engine.playbackPositionSeconds
        _ = waitForEngineState(timeout: 15) {
            engine.playbackPositionSeconds >= restoredAt + 8
        }
        result.advancedAfterRollback = max(0, engine.playbackPositionSeconds - restoredAt)
    }
    result.errors = delegate.errors
    engine.stop()
    return result
}
#endif

// Iteration affordance ONLY: `ONLY_SELECTION=1` runs just the selection gate while that gate is being
// developed. Every reported run is a full run (the variable is unset), and the summary states which it was.
let onlySelection = ProcessInfo.processInfo.environment["ONLY_SELECTION"] == "1"
// ~2.6x the fixture's real-time byte rate: the producer leads the player modestly, the field shape.
let pacedRate = 400_000

if !onlySelection {

// --- Scenario 1: fresh play, same-codec alternate + 2 text subs ---
let fresh = runScenario(name: "fresh-multiaudio", fixture: "fixture-multiaudio.mkv",
                        startAt: 0, consumeSeconds: 12)
// The first media playlist must start PINNED at sequence zero (the growing EVENT tail is by-design; the
// build 190 regression was the sequence racing ahead of the client at production speed). Master latency
// stays covered by the paced consumer gate below; against this unpaced local file the tail legitimately
// covers however much was already produced.
check("first media playlist starts pinned at sequence zero",
      red: !fresh.mediaBody.contains("#EXT-X-MEDIA-SEQUENCE:0"),
      detail: "first media playlist rendered=\(String(format: "%.1f", fresh.startupRenderedSeconds))s, seq0=\(fresh.mediaBody.contains("#EXT-X-MEDIA-SEQUENCE:0"))")
check("master served at all (fresh)", red: fresh.masterStatus != 200,
      detail: "status=\(fresh.masterStatus)")
check("initial master advertises one named primary audio row",
      red: fresh.audioMediaTags != 1
          || fresh.audioMediaLines.first?.contains(#"NAME="English 5.1""#) != true,
      detail: "audio rows=\(fresh.audioMediaLines)")
check("initial master advertises no alternate audio URI",
      red: fresh.audioMediaLines.contains(where: { $0.contains("URI=") }),
      detail: "audio rows=\(fresh.audioMediaLines)")
check("subtitle renditions advertised", red: fresh.subtitleMediaTags < 2,
      detail: "subtitle EXT-X-MEDIA tags=\(fresh.subtitleMediaTags)")
check("startup VTTs carry cues (fresh)", red: fresh.totalVTTs > 0 && fresh.nonEmptyVTTs == 0,
      detail: "nonEmpty=\(fresh.nonEmptyVTTs)/\(fresh.totalVTTs)")
check("remux alive through steady state (fresh)", red: fresh.remuxFailedDuringRun,
      detail: "failed=\(fresh.remuxFailedDuringRun) froze=\(fresh.producerFrozeWhileHealthy)")

// --- Scenario 2: RESUME play (the diag 8 field shape: every mount died) ---
let resume = runScenario(name: "resume-multiaudio", fixture: "fixture-multiaudio.mkv",
                         startAt: 60, consumeSeconds: 12)
check("master served on resume", red: resume.masterStatus != 200,
      detail: "status=\(resume.masterStatus) latency=\(String(format: "%.1f", resume.masterLatency))s (field: instant 404 -> item .failed -> HDR10 demote)")
check("remux alive on resume", red: resume.remuxFailedDuringRun,
      detail: "failed=\(resume.remuxFailedDuringRun)")
check("resume VTTs carry cues (timeline rebase)",
      red: resume.totalVTTs > 0 && resume.nonEmptyVTTs == 0,
      detail: "nonEmpty=\(resume.nonEmptyVTTs)/\(resume.totalVTTs) (field: unbroken 51B empty docs on the resume play)")

// --- Scenario 3: mixed-codec audio (the CEO's 4-language file shape) ---
let mixed = runScenario(name: "fresh-mixedcodec", fixture: "fixture-mixedcodec.mkv",
                        startAt: 0, consumeSeconds: 6)
check("mixed-codec master keeps one named primary without an alternate",
      red: mixed.audioMediaTags != 1
          || mixed.audioMediaLines.first?.contains(#"NAME="English 5.1""#) != true
          || mixed.audioMediaLines.contains(where: { $0.contains("URI=") }),
      detail: "audio rows=\(mixed.audioMediaLines)")
check("master served (mixed)", red: mixed.masterStatus != 200,
      detail: "status=\(mixed.masterStatus)")

// --- REAL-CONSUMER gate: 60+ seconds of continuous AVPlayer playback, fresh AND resume ---
func judgeConsumer(_ label: String, _ run: ConsumerResult, playSeconds: Double) {
    check("consumer \(label): played \(Int(playSeconds))s continuously",
          red: run.reachedSeconds < playSeconds - 1,
          detail: String(format: "reached=%.1fs of %.0fs (wall=%.1fs)",
                         run.reachedSeconds, playSeconds, run.wallSeconds))
    check("consumer \(label): no seek-jumps",
          red: run.maxForwardJump > 3.0 || run.maxBackwardJump < -1.0,
          detail: String(format: "maxFwdJump=%.2fs maxBackJump=%.2fs (field: skips of ~15s every few seconds)",
                         run.maxForwardJump, run.maxBackwardJump))
    check("consumer \(label): no stall or failure",
          red: run.longestStall > 5.0 || run.itemError != nil || run.remuxFailed,
          detail: String(format: "longestStall=%.1fs itemError=%@ remuxFailed=%@",
                         run.longestStall, run.itemError ?? "none", String(run.remuxFailed)))
}

let consumerFresh = consumerScenario(
    name: "fresh", fixture: "fixture-multiaudio.mkv", startAt: 0, playSeconds: 65,
    pacedBytesPerSecond: pacedRate)
judgeConsumer("fresh", consumerFresh, playSeconds: 65)
let consumerResume = consumerScenario(
    name: "resume", fixture: "fixture-multiaudio.mkv", startAt: 60, playSeconds: 65,
    pacedBytesPerSecond: pacedRate)
judgeConsumer("resume", consumerResume, playSeconds: 65)

}   // end !onlySelection

// --- REAL-CONSUMER SELECTION gate: the CEO's build 191 field shape (5 mixed-codec dubs, 5 text subs) ---
let selectionHold = 22.0
let selection = selectionScenario(
    name: "manyaudio", fixture: "fixture-manyaudio.mkv", playSeconds: 12,
    holdSeconds: selectionHold, pacedBytesPerSecond: pacedRate)
check("selection: every text subtitle track is offered",
      red: selection.subtitleOptions.count < 5,
      detail: "subtitle options=\(selection.subtitleOptions.count) \(selection.subtitleOptions) (fixture carries 5)")
check("selection: AVFoundation sees only the in-band primary audio",
      red: selection.audioOptions.count != 1 || selection.selectedNativeAudioName == nil,
      detail: "native audio options=\(selection.audioOptions) selected=\(selection.selectedNativeAudioName ?? "nil")")
check("selection: every source audio row remains visible outside the HLS group",
      red: selection.sourceAudioRows.count != 5
          || Set(selection.sourceAudioRows.map(\.index)).count != 5,
      detail: "source rows=\(selection.sourceAudioRows)")
check("selection: the initial source receipt names one visible row",
      red: selection.selectedSourceAudioIndex.map {
          selection.sourceAudioRows.map(\.index).contains($0)
      } != true,
      detail: "selected=\(selection.selectedSourceAudioIndex.map(String.init) ?? "nil") rows=\(selection.sourceAudioRows)")
judgeSwitch("subtitle", selection.subtitles, holdSeconds: selectionHold,
            optionCount: selection.subtitleOptions.count)
check("selection: the session survived the subtitle switch",
      red: selection.remuxFailed || selection.itemError != nil,
      detail: "remuxFailed=\(selection.remuxFailed) itemError=\(selection.itemError ?? "none")")

let sourcePlayhead = 18.0
let remountReceipts = selection.sourceAudioRows.map {
    sourceRemountReceipt(
        fixture: "fixture-manyaudio.mkv",
        sourceIndex: $0.index,
        sourcePlayhead: sourcePlayhead)
}
let remountSummary = remountReceipts.map {
    "\($0.requestedSourceIndex)->\($0.selectedSourceIndex.map(String.init) ?? "nil")"
}
let remountOrigins = remountReceipts.map {
    String(format: "%.3f", $0.timelineOriginSeconds)
}
check("producer supplemental: every immutable source index is remounted as the sole primary",
      red: remountReceipts.count != 5
          || remountReceipts.contains {
              $0.failed
                  || $0.selectedSourceIndex != $0.requestedSourceIndex
                  || $0.audioMediaLines.count != 1
                  || !$0.audioMediaLines[0].contains("NAME=")
                  || $0.audioMediaLines[0].contains("URI=")
          },
      detail: "receipts=\(remountSummary)")
check("producer supplemental: every remount preserves the complete source inventory",
      red: remountReceipts.contains {
          $0.sourceAudioIndices != selection.sourceAudioRows.map(\.index)
      },
      detail: "inventories=\(remountReceipts.map(\.sourceAudioIndices))")
check("producer supplemental: every remount carries the source playhead",
      red: remountReceipts.contains {
          abs($0.timelineOriginSeconds - sourcePlayhead) > 1.5
      },
      detail: "origins=\(remountOrigins)")

#if ENGINE_TRANSACTION_HARNESS
private let engineTransaction = MainActor.assumeIsolated {
    engineTransactionSuccessScenario(
        fixture: "fixture-manyaudio.mkv",
        pacedBytesPerSecond: pacedRate)
}
private let engineRollback = MainActor.assumeIsolated {
    engineTransactionRollbackScenario(
        fixture: "fixture-manyaudio.mkv",
        pacedBytesPerSecond: pacedRate)
}
check("engine transaction: production picker path starts and reaches readiness",
      red: !engineTransaction.sawProductionSelection
          || !engineTransaction.sawProductionReady
          || !engineTransaction.sawProductionRestore,
      detail: "selected=\(engineTransaction.sawProductionSelection) ready=\(engineTransaction.sawProductionReady) restore=\(engineTransaction.sawProductionRestore)")
check("engine transaction: complete source inventory survives the physical remount",
      red: engineTransaction.initialRows.count != 5
          || Set(engineTransaction.initialRows).count != 5
          || engineTransaction.rowsAfterReady != engineTransaction.initialRows,
      detail: "initial=\(engineTransaction.initialRows) postRemount=\(engineTransaction.rowsAfterReady)")
check("engine transaction: requested source becomes the selected in-band primary",
      red: engineTransaction.targetSourceIndex == nil
          || engineTransaction.selectedAfterReady != engineTransaction.targetSourceIndex,
      detail: "target=\(engineTransaction.targetSourceIndex.map(String.init) ?? "nil") selected=\(engineTransaction.selectedAfterReady.map(String.init) ?? "nil")")
check("engine transaction: logical PlayerLoadToken is reused",
      red: !engineTransaction.tokenWasReused,
      detail: "same token=\(engineTransaction.tokenWasReused)")
check("engine transaction: source playhead is carried into the replacement",
      red: abs(engineTransaction.sourceSecondsAtReady
          - engineTransaction.sourceSecondsBeforeSwitch) > 1.5,
      detail: String(
        format: "before=%.3fs ready=%.3fs drift=%.3fs tolerance=1.500s",
        engineTransaction.sourceSecondsBeforeSwitch,
        engineTransaction.sourceSecondsAtReady,
        abs(engineTransaction.sourceSecondsAtReady
            - engineTransaction.sourceSecondsBeforeSwitch)))
check("engine transaction: replacement advances 20s without a long stall or terminal error",
      red: engineTransaction.advancedAfterReady < 20
          || engineTransaction.longestStallAfterReady > 5
          || !engineTransaction.errors.isEmpty,
      detail: String(
        format: "advanced=%.1fs longestStall=%.1fs errors=%@",
        engineTransaction.advancedAfterReady,
        engineTransaction.longestStallAfterReady,
        engineTransaction.errors.description))
check("engine rollback: deterministic target failure triggers exactly one rollback",
      red: !engineRollback.sourceWasSuspended
          || !engineRollback.sawTargetFailure
          || engineRollback.rollbackCount != 1,
      detail: "sourceSuspended=\(engineRollback.sourceWasSuspended) failure=\(engineRollback.sawTargetFailure) reason=\(engineRollback.targetFailureReason ?? "nil") rollbackCount=\(engineRollback.rollbackCount)")
check("engine rollback: prior source becomes ready and is restored",
      red: !engineRollback.sawRollbackReady
          || !engineRollback.sawRollbackRestore
          || engineRollback.priorSourceIndex == nil
          || engineRollback.selectedAfterRollback != engineRollback.priorSourceIndex,
      detail: "prior=\(engineRollback.priorSourceIndex.map(String.init) ?? "nil") target=\(engineRollback.targetSourceIndex.map(String.init) ?? "nil") selected=\(engineRollback.selectedAfterRollback.map(String.init) ?? "nil") ready=\(engineRollback.sawRollbackReady) restore=\(engineRollback.sawRollbackRestore)")
check("engine rollback: measured playhead and logical PlayerLoadToken survive",
      red: !engineRollback.tokenWasReused
          || engineRollback.rollbackSourceSeconds == nil
          || abs((engineRollback.rollbackSourceSeconds ?? 0)
              - engineRollback.sourceSecondsBeforeSwitch) > 1.5,
      detail: String(
        format: "sameToken=%@ before=%.3fs rollback=%.3fs",
        String(engineRollback.tokenWasReused),
        engineRollback.sourceSecondsBeforeSwitch,
        engineRollback.rollbackSourceSeconds ?? -1))
check("engine rollback: recovered playback advances without a terminal error",
      red: engineRollback.advancedAfterRollback < 8
          || !engineRollback.errors.isEmpty,
      detail: String(
        format: "advanced=%.1fs errors=%@",
        engineRollback.advancedAfterRollback,
        engineRollback.errors.description))
#endif

print("=== REPRO SUMMARY: \(redCount) RED\(onlySelection ? " (SELECTION GATE ONLY)" : " (full run)") ===")
exit(Int32(min(redCount, 125)))
