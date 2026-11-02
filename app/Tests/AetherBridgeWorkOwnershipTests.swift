import AppKit
import Foundation

// Complete maintained bridge adapter under test; only its internal engine wrapper is synthetic.
struct VortXAetherTrack {
    let id: Int; let title: String; let language: String; let codec: String
    let channels: Int; let isDefault: Bool; let isForced: Bool
}
enum VortXAetherState { case idle, loading, playing, paused, seeking, ended, failed(String) }
@MainActor final class VortXAetherPlayer {
    static var latest: VortXAetherPlayer!
    init() throws { Self.latest = self }
    let view = NSView()
    var onState: ((VortXAetherState) -> Void)?
    var onTime: ((Double) -> Void)?
    var onDuration: ((Double) -> Void)?
    var onBuffering: ((Bool) -> Void)?
    var onBufferedPosition: ((Double) -> Void)?
    var onTracksChanged: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    var onSubtitleText: ((String?) -> Void)?
    var loads: [URL] = [], seeks: [Double] = []
    var suspendsLoads = false
    var onLoadStarted: (() -> Void)?
    var continuations: [URL: CheckedContinuation<Void, Never>] = [:]
    func load(url: URL, headers: [String: String]?, live: Bool, startPosition: Double?, autoplay: Bool) async throws {
        loads.append(url)
        if suspendsLoads {
            await withCheckedContinuation { continuation in
                continuations[url] = continuation
                onLoadStarted?()
            }
        } else { onLoadStarted?() }
    }
    func finish(_ url: URL) { continuations.removeValue(forKey: url)!.resume() }
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to seconds: Double) async { seeks.append(seconds) }
    func setRate(_ rate: Double) {}
    func setVideoSize(_ mode: String) {}
    func setAudioDelay(_ seconds: Double) {}
    var volume = 1.0, currentTime = 0.0, duration = 100.0, bufferedPosition = 0.0
    var canSeek = true, isSeeking = false
    // Outcome policy is tested against the actual wrapper in AetherPlayerObservationTests.
    var positionIsSettled: Bool { !isSeeking }
    var audioTracks: [VortXAetherTrack] = [], subtitleTracks: [VortXAetherTrack] = []
    var activeAudioTrackID: Int?, activeSubtitleTrackID: Int?
    func selectAudioTrack(id: Int) {}
    func selectSubtitleTrack(id: Int) {}
    func clearSubtitle() {}
    var activeSecondarySubtitleTrackID: Int?
    func selectSecondarySubtitleTrack(id: Int) { activeSecondarySubtitleTrackID = id }
    func clearSecondarySubtitle() { activeSecondarySubtitleTrackID = nil }
    func removeExternalSubtitleTrack(id: Int) {}
    var localCommits: [URL] = []
    func selectLocalSubtitle(url: URL, title: String, lang: String, secondary: Bool,
        permitsPreparation: @MainActor () -> Bool, permitsCommit: @MainActor () -> Bool, committedTrack: @MainActor (Int) -> Void, finishedCommit: @MainActor () -> Void) async throws {
        guard permitsPreparation() else { throw CancellationError() }
        await Task.yield()
        guard !Task.isCancelled, permitsCommit() else { throw CancellationError() }
        defer { finishedCommit() }
        localCommits.append(url)
        committedTrack(100000 + localCommits.count)
    }
    func selectSidecarSubtitle(url: URL, headers: [String: String]?) {}
    func setSubtitleDelay(_ seconds: Double) {}
    var videoWidth = 0, videoHeight = 0
    var videoFrameRate: Double?
    var videoDynamicRange = "unknown"
    var mediaChapters: [[String: Any]] = []
    var videoFormat = "sdr", sourceVideoFormat = "sdr", audioDelivery = "pcm", videoRoute = "fake"
    var sourceDolbyVisionProfile: Int?
    var videoDecoder: String?, audioDecoder: String?
    var isDolbyVisionPresented = false
}
@MainActor final class Receipt<Value: Sendable> {
    var results: [Value] = []
    var waiter: CheckedContinuation<Value, Never>?
    func record(_ value: Value) { results.append(value); waiter?.resume(returning: value); waiter = nil }
    func value() async -> Value {
        if let value = results.last { return value }
        return await withCheckedContinuation { waiter = $0 }
    }
}
@main @MainActor enum AetherBridgeWorkOwnershipTests {
    static var checks = 0
    static let sourceA = URL(string: "https://example.invalid/A")!
    static let sourceB = URL(string: "https://example.invalid/B")!
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message); checks += 1; print("PASS \(message)")
    }
    static func issue(_ bridge: any VortXAetherBridging, _ url: URL) -> Receipt<Int> {
        let result = Receipt<Int>()
        bridge.load(url: url, headers: nil, live: false, startPosition: nil, autoplay: true) {
            result.record($0?.code ?? 0)
        }
        return result
    }
    static func main() async throws {
        do {
            let bridge = try VortXAetherBridgePlayer.makePlayer(); let fake = VortXAetherPlayer.latest!
            let completion = issue(bridge, sourceA); bridge.stop()
            check(await completion.value() == VortXAetherBridgeErrorCode.cancelled.rawValue, "pre-start cancellation completes exactly once as cancelled")
            check(fake.loads.isEmpty && completion.results.count == 1, "cancelled queued load never reaches internal engine")
        }
        do {
            let bridge = try VortXAetherBridgePlayer.makePlayer(); let fake = VortXAetherPlayer.latest!
            let staleSeek = Receipt<Bool>()
            bridge.seek(to: 80) { staleSeek.record(true) }
            let loaded = issue(bridge, sourceB); _ = await loaded.value()
            check(fake.seeks.isEmpty && staleSeek.results.isEmpty, "queued old-generation seek cannot mutate or complete against successor load")
            let valid = Receipt<Bool>(); bridge.seek(to: 20) { valid.record(true) }
            check(await valid.value() && fake.seeks == [20], "current-generation seek still reaches engine and completes")
        }
        do {
            let bridge = try VortXAetherBridgePlayer.makePlayer(); let fake = VortXAetherPlayer.latest!
            bridge.seek(to: 75, completion: nil); bridge.stop()
            let loaded = issue(bridge, sourceB); _ = await loaded.value()
            check(fake.seeks.isEmpty, "stop retires a queued seek before replacement")
        }
        do {
            let bridge = try VortXAetherBridgePlayer.makePlayer(); let fake = VortXAetherPlayer.latest!
            fake.suspendsLoads = true
            let startedA = Receipt<Bool>(); fake.onLoadStarted = { startedA.record(true) }
            let completionA = issue(bridge, sourceA); _ = await startedA.value()
            let startedB = Receipt<Bool>(); fake.onLoadStarted = { startedB.record(true) }
            let completionB = issue(bridge, sourceB); _ = await startedB.value()
            fake.finish(sourceB)
            check(await completionB.value() == 0, "successor completion reports success")
            fake.finish(sourceA)
            check(await completionA.value() == VortXAetherBridgeErrorCode.cancelled.rawValue, "late predecessor success reports cancellation")
            check(completionA.results.count == 1 && completionB.results.count == 1, "both load generations finish exactly once")
        }
        do {
            let bridge = try VortXAetherBridgePlayer.makePlayer(); let fake = VortXAetherPlayer.latest!
            _ = await issue(bridge, sourceA).value()
            let result = Receipt<Bool>()
            bridge.selectLocalSubtitle(url: URL(fileURLWithPath: "/synthetic-local.srt"), title: "English", lang: "eng", secondary: false,
                permitsPreparation: { true }, permitsCommit: { true }, committedTrack: { _ in }, finishedCommit: {}) { result.record($0) }
            bridge.clearSubtitle()
            check(!(await result.value()) && fake.localCommits.isEmpty,
                  "Off retires a queued prepared subtitle before native commit")
            let current = Receipt<Bool>()
            bridge.selectLocalSubtitle(url: URL(fileURLWithPath: "/synthetic-local.srt"), title: "English", lang: "eng", secondary: false,
                permitsPreparation: { true }, permitsCommit: { true }, committedTrack: { _ in }, finishedCommit: {}) { current.record($0) }
            check(await current.value() && fake.localCommits.count == 1,
                  "current local subtitle completes only after underlying preparation commits")
            let denied = Receipt<Bool>()
            bridge.selectLocalSubtitle(url: URL(fileURLWithPath: "/denied-local.srt"), title: "English", lang: "eng", secondary: false,
                permitsPreparation: { true }, permitsCommit: { false }, committedTrack: { _ in }, finishedCommit: {}) { denied.record($0) }
            check(!(await denied.value()) && fake.localCommits.count == 1,
                  "revoked original caller permit cannot commit an already prepared subtitle")
        }
        print("\(checks) bridge ownership checks passed against complete maintained adapter")
    }
}
