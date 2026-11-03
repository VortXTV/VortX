import AppKit
import Foundation
import os

// Compiles the complete maintained controller and real runtime protocol. Only the external
// engine, fetch transport and chrome collaborators are fake; no controller method is copied.
@MainActor protocol PlayerEngine: AnyObject {}
struct PlayerLoadToken: Equatable, Sendable { let id = UUID() }
@MainActor protocol MPVPlayerDelegate: AnyObject {
    func propertyChange(propertyName: String, data: Any?, loadToken: PlayerLoadToken)
}
struct PlayerTimePositionEvent {
    let seconds: Double
    let loadToken: PlayerLoadToken
    let positionSettled: Bool
}
struct MPVTrack {
    let id: Int; let type: String; let title: String; let lang: String; let selected: Bool; let forced: Bool
    var unavailableReason: String? = nil
}
struct MPVChapter { let title: String; let start: Double }
enum AudioOutputMode { case automatic }
enum MPVProperty {
    static let endFileEof = "eof", endFileError = "error", timePos = "time", duration = "duration"
    static let seekable = "seekable", pausedForCache = "cache-paused", demuxerCacheTime = "cache-time"
    static let trackList = "tracks", pause = "pause", speed = "speed"
}
// Isolated preference collaborator: the complete source setter can be tested without
// touching UserDefaults.standard or any installed application's preferences.
@MainActor enum UserDefaults {
    static let standard = DisposablePreferences()
}
@MainActor final class DisposablePreferences {
    var values: [String: String] = [:]
    func set(_ value: String, forKey key: String) { values[key] = value }
}
@MainActor final class SubtitleOverlayView: NSView {
    var text: String?
    func setText(_ text: String?) { self.text = text }
    func applyStyle() {}
}
enum SubtitleFileFetcher {
    struct Pending: Sendable { let done: @Sendable (Data?) -> Void }
    private static let requests = OSAllocatedUnfairLock(initialState: [Pending]())
    static func fetch(_ url: URL, timeout: TimeInterval, done: @escaping @Sendable (Data?) -> Void) {
        requests.withLock { $0.append(Pending(done: done)) }
    }
    static func completeFirst() {
        let pending = requests.withLock { $0.removeFirst() }
        pending.done(Data("1\n00:00:00,000 --> 00:00:01,000\nHello\n".utf8))
    }
}
@MainActor enum AetherEngineLoader {
    static var next: (any VortXAetherBridging)!
    static func makePlayer() throws -> any VortXAetherBridging { next }
}
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
    var stops = 0
    func stop() {
        stops += 1
        // Deliberately hostile: native teardown can publish synchronously.
        emitEveryCallback(seconds: 999)
        currentTime = 0; duration = 0
        videoWidth = 0; videoHeight = 0; mediaChapters = []
        audioTracks = []; subtitleTracks = []
        activeAudioTrackID = nil; activeSubtitleTrackID = nil
    }
    func emitEveryCallback(seconds: Double) {
        onState?(.failed("retired source"))
        onTime?(seconds); onDuration?(999); onBuffering?(true)
        onBufferedPosition?(999); onTracksChanged?(); onFirstFrame?()
        onSubtitleText?("retired cue")
    }
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
@MainActor final class Delegate: MPVPlayerDelegate {
    var properties: [String] = []
    var positions: [PlayerTimePositionEvent] = []
    var seekable: [Bool] = []
    func propertyChange(propertyName: String, data: Any?, loadToken: PlayerLoadToken) {
        properties.append(propertyName)
        if let event = data as? PlayerTimePositionEvent { positions.append(event) }
        if propertyName == MPVProperty.seekable, let value = data as? Bool { seekable.append(value) }
    }
}
@main @MainActor enum AetherLoadCallbackIsolationTests {
    static var checks = 0
    static let sourceA = URL(string: "https://example.invalid/A")!
    static let sourceB = URL(string: "https://example.invalid/B")!
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { print("FAIL \(message)"); exit(1) }; checks += 1; print("PASS \(message)")
    }
    static func fresh() throws -> (AetherEngineController, any VortXAetherBridging, VortXAetherPlayer, Delegate) {
        let bridge = try VortXAetherBridgePlayer.makePlayer()
        let fake = VortXAetherPlayer.latest!
        AetherEngineLoader.next = bridge
        let controller = AetherEngineController()
        let delegate = Delegate(); controller.playDelegate = delegate
        return (controller, bridge, fake, delegate)
    }
    static func issue(_ controller: AetherEngineController, _ fake: VortXAetherPlayer, _ source: URL) -> Receipt<Bool> {
        let started = Receipt<Bool>(); fake.onLoadStarted = { started.record(true) }
        controller.loadFile(source, headers: nil, live: false, audioSidecar: nil, reusing: nil)
        return started
    }
    static func main() async throws {
        do {
            let (controller, _, fake, delegate) = try fresh()
            let first = issue(controller, fake, sourceA); _ = await first.value()
            fake.videoWidth = 1920; fake.videoHeight = 1080; fake.duration = 100
            fake.onFirstFrame?(); fake.onTime?(120)
            check(delegate.positions.last?.positionSettled == true, "first session remains usable before replacement")
            let previousCount = delegate.properties.count
            let next = issue(controller, fake, sourceB)
            check(fake.stops == 1 && fake.loads == [sourceA], "completed session stops synchronously before queued replacement enters")
            check(delegate.properties.count == previousCount, "synchronous stop publications cannot be stamped with successor token")
            // A previous @Published willSet could finish storing its value after a
            // re-entrant replacement. The boundary must not expose that readback.
            fake.currentTime = 998; fake.videoWidth = 999; fake.duration = 998
            fake.emitEveryCallback(seconds: 998)
            check(delegate.properties.count == previousCount && controller.subtitleOverlay.text == nil,
                  "every callback is blocked throughout replacement queue gap")
            check(controller.mediaSummary().width == 0 && controller.mediaDurationSeconds() == 0
                    && controller.playbackPositionSeconds == 0,
                  "retired engine readback is cleared before replacement starts")
            _ = await next.value()
            fake.onTime?(1)
            check(delegate.positions.last?.positionSettled == false,
                  "retired first-frame callback cannot settle successor's first clock")
            fake.onFirstFrame?(); fake.onTime?(2)
            check(delegate.positions.last?.positionSettled == true,
                  "successor's own first frame and clock remain usable")
            controller.stop()
            check(fake.stops == 2, "stop retires entered successor once")
        }
        do {
            let (controller, _, fake, delegate) = try fresh()
            let first = issue(controller, fake, sourceA); _ = await first.value()
            let oldCount = delegate.properties.count
            controller.invalidateLoadToken()
            fake.emitEveryCallback(seconds: 997)
            check(fake.stops == 1 && delegate.properties.count == oldCount,
                  "invalidation retires physical playback and all callback authority")
            let queued = issue(controller, fake, sourceB)
            controller.stop()
            // Enter a later generation and confirm the superseded issue cannot run.
            // The older task also checks generation whenever it is eventually scheduled.
            let replacement = issue(controller, fake, sourceA); _ = await replacement.value()
            check(queued.results.isEmpty && fake.loads == [sourceA, sourceA],
                  "cancelled queued load cannot enter or stop a later session")
            controller.stop()
        }
        do {
            let (controller, _, fake, _) = try fresh()
            _ = await issue(controller, fake, sourceA).value()
            fake.onSubtitleText?("Embedded English")
            check(controller.subtitleOverlay.text == "Embedded English",
                  "active embedded text crosses complete runtime bridge into shared styled overlay")
            controller.setSubtitleTrack(-1)
            fake.onSubtitleText?(nil)
            check(controller.subtitleOverlay.text == nil, "Off clears shared embedded text overlay")
            controller.stop(); fake.onSubtitleText?("retired subtitle")
            check(controller.subtitleOverlay.text == nil, "retired native text callback cannot redraw a later surface")
        }
        print("\(checks) callback-isolation checks passed against complete maintained controller and bridge")
    }
}
