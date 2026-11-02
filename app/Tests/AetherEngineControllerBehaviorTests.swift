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
    static var next: FakeAetherBridge!
    static func makePlayer() throws -> any VortXAetherBridging { next }
}
@MainActor final class FakeAetherBridge: NSObject, VortXAetherBridging {
    struct Load { let start: Double?; let autoplay: Bool; let live: Bool }
    var loads: [Load] = []
    var sidecars: [URL] = []
    var selections: [Int] = []
    var publishDuringStop = false
    static func makePlayer() throws -> any VortXAetherBridging { FakeAetherBridge() }
    let view = NSView()
    var onState: ((VortXAetherBridgeState, String?) -> Void)?
    var onTime: ((Double) -> Void)?
    var onDuration: ((Double) -> Void)?
    var onBuffering: ((Bool) -> Void)?
    var onBufferedPosition: ((Double) -> Void)?
    var onTracksChanged: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    var onSubtitleText: ((String?) -> Void)?
    func load(url: URL, headers: [String: String]?, live: Bool, startPosition: NSNumber?, autoplay: Bool,
              completion: @escaping (NSError?) -> Void) {
        loads.append(Load(start: startPosition?.doubleValue, autoplay: autoplay, live: live)); completion(nil)
    }
    func cancelLoad() {}
    func play() {}
    func pause() {}
    func stop() {
        if publishDuringStop { onTime?(999); onSubtitleText?("retiring cue") }
    }
    func seek(to seconds: Double, completion: (() -> Void)?) { completion?() }
    func setRate(_ rate: Double) {}
    var sizeModes: [String] = []
    func setVideoSize(_ mode: String) { sizeModes.append(mode) }
    func setAudioDelay(_ seconds: Double) {}
    var volume = 1.0
    var currentTime = 0.0
    var duration = 600.0
    var canSeek = true
    var isSeeking = false
    // Outcome policy is tested against the actual wrapper in AetherPlayerObservationTests.
    var positionIsSettled: Bool { !isSeeking }
    var bufferedPosition = 0.0
    var audioTracks: [[String: Any]] = []
    var subtitleTracks: [[String: Any]] = []
    var activeAudioTrackID: NSNumber?
    var activeSubtitleTrackID: NSNumber?
    func selectAudioTrack(id: Int) {}
    func selectSubtitleTrack(id: Int) { selections.append(id); activeSubtitleTrackID = NSNumber(value: id) }
    func clearSubtitle() { selections.append(-1); activeSubtitleTrackID = nil; onSubtitleText?(nil) }
    func selectSidecarSubtitle(url: URL, headers: [String: String]?) { sidecars.append(url) }
    func setSubtitleDelay(_ seconds: Double) {}
    var videoWidth = 0, videoHeight = 0
    var videoFrameRate: NSNumber?
    var videoDynamicRange = "unknown"
    var mediaChapters: [[String: Any]] = []
    var videoFormat = "sdr", sourceVideoFormat = "sdr", audioDelivery = "pcm", videoRoute = "synthetic"
    var sourceDolbyVisionProfile: NSNumber?
    var videoDecoder: String?, audioDecoder: String?
    var isDolbyVisionPresented = false
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
@MainActor final class Completion {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    func record(_ value: Bool) { result = value; waiter?.resume(returning: value); waiter = nil }
    func value() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}
@main @MainActor enum AetherEngineControllerBehaviorTests {
    static let source = URL(string: "https://example.invalid/movie.mkv")!
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message); checks += 1; print("PASS \(message)")
    }
    static func fresh() -> (AetherEngineController, FakeAetherBridge) {
        let fake = FakeAetherBridge(); AetherEngineLoader.next = fake
        let controller = AetherEngineController()
        controller.loadFile(source, headers: nil, live: false, audioSidecar: nil, reusing: nil)
        return (controller, fake)
    }
    static func pending(_ controller: AetherEngineController) -> Completion {
        let completion = Completion()
        controller.addExternalSubtitle(url: "https://example.invalid/sub.srt", title: "English", lang: "eng",
            timeout: 2) { completion.record($0) }
        return completion
    }
    static func main() async {
        do {
            let (controller, fake) = fresh()
            controller.configureResumeOrigin(seconds: 312)
            controller.holdsNextLoadPaused = true
            controller.loadFile(source, headers: nil, live: false, audioSidecar: nil, reusing: nil)
            controller.loadFile(source, headers: nil, live: false, audioSidecar: nil, reusing: nil)
            check(fake.loads[1].start == 312 && !fake.loads[1].autoplay, "configured load receives resume and paused intent")
            check(fake.loads[2].start == nil && fake.loads[2].autoplay, "next unrelated load consumes neither old intent")
        }
        for id in [-1, 4] {
            let (controller, fake) = fresh(); let result = pending(controller)
            controller.setSubtitleTrack(id); SubtitleFileFetcher.completeFirst()
            check(!(await result.value()), "manual subtitle \(id) retires queued external request")
            check(fake.sidecars.isEmpty && fake.selections == [id], "manual subtitle \(id) remains selected")
        }
        do {
            let (controller, fake) = fresh(); let result = pending(controller)
            let token = controller.activeLoadToken!
            controller.loadFile(source, headers: nil, live: false, audioSidecar: nil, reusing: token)
            SubtitleFileFetcher.completeFirst()
            check(!(await result.value()) && fake.sidecars.isEmpty, "same-token retry cannot admit a previous issue's subtitle")
        }
        do {
            let (controller, fake) = fresh(); let old = pending(controller); let latest = pending(controller)
            SubtitleFileFetcher.completeFirst()
            check(!(await old.value()), "newer external request retires the older one")
            SubtitleFileFetcher.completeFirst()
            check(await latest.value(), "latest current external request remains usable")
            check(fake.sidecars.count == 1 && FileManager.default.fileExists(atPath: fake.sidecars[0].path), "admitted external passes the actual local file to the engine")
            controller.stop()
            check(!FileManager.default.fileExists(atPath: fake.sidecars[0].path), "stop removes admitted temporary subtitle")
        }
        do {
            let (controller, fake) = fresh(); let result = pending(controller)
            controller.invalidateLoadToken(); SubtitleFileFetcher.completeFirst()
            check(!(await result.value()) && fake.sidecars.isEmpty, "invalidated load refuses late download")
        }
        do {
            let (controller, fake) = fresh(); let delegate = Delegate(); controller.playDelegate = delegate
            fake.publishDuringStop = true; controller.stop()
            check(delegate.properties.isEmpty, "synchronous stop clock cannot publish under retiring owner")
            fake.onSubtitleText?("late cue")
            check(controller.subtitleOverlay.text == nil, "retired engine cannot resurrect text overlay")
        }
        do {
            let (controller, fake) = fresh(); let delegate = Delegate(); controller.playDelegate = delegate
            fake.onFirstFrame?()
            fake.isSeeking = true
            fake.onState?(.seeking, nil)
            fake.onState?(.playing, nil) // Aether transport is optimistic before physical landing.
            fake.onTime?(120)
            check(delegate.positions.last?.positionSettled == false, "optimistic playing cannot settle a physical seek")
            fake.isSeeking = false; fake.onTime?(120)
            check(delegate.positions.last?.positionSettled == true, "physical landing admits a settled position")
        }
        do {
            let (controller, fake) = fresh(); let delegate = Delegate(); controller.playDelegate = delegate
            fake.canSeek = false
            controller.loadFile(source, headers: nil, live: false, audioSidecar: nil, reusing: nil)
            fake.onDuration?(600)
            check(delegate.seekable == [false], "early source metadata does not promise unready seekability")
            fake.canSeek = true; fake.onTime?(0); fake.onTime?(1)
            check(delegate.seekable == [false, true], "ready clock refreshes capability without duplicate notifications")
        }
        do {
            let (controller, fake) = fresh()
            controller.loadFile(source, headers: nil, live: true, audioSidecar: nil, reusing: nil)
            check(fake.loads.last?.live == true, "live input reaches the real runtime boundary")
            controller.setVideoSize("zoom"); controller.setVideoSize("stretch"); controller.setVideoSize("fit")
            check(fake.sizeModes == ["zoom", "stretch", "fit"], "video sizing commands reach the engine boundary")
            fake.videoDynamicRange = ""
            check(!controller.hdrAvailable, "empty format cannot claim HDR")
            fake.videoDynamicRange = "unknown"
            check(!controller.hdrAvailable, "unmeasured format cannot claim HDR")
            fake.videoWidth = 3840; fake.videoHeight = 2160; fake.videoDynamicRange = "pq"
            check(controller.hdrAvailable, "observed PQ presentation enables HDR")
            fake.audioTracks = [["id": 2, "language": "eng", "codec": "eac3", "channels": 6]]
            fake.activeAudioTrackID = 2
            let facts = controller.playbackMetadataFacts()
            check(facts.width == 3840 && facts.height == 2160 && facts.dynamicRange == .pq,
                  "observed picture dimensions and presented dynamic range populate metadata")
            check(facts.audioSelected && facts.audioCodec == "eac3" && facts.audioChannels == 6,
                  "selected audio facts use the bridge's actual selected ID")
            fake.activeAudioTrackID = nil
            check(!controller.playbackMetadataFacts().audioSelected, "absent selection never fabricates audio facts")
            fake.mediaChapters = [["title": "Intro", "start": 0.0], ["title": "Main", "start": 90.0], ["start": Double.nan]]
            check(controller.chapters().map(\.start) == [0, 90], "container chapters retain the seek axis and reject invalid timestamps")
            controller.invalidateLoadToken()
            check(controller.playbackMetadataFacts().pills.isEmpty, "retired metadata cannot describe a successor surface")
            check(controller.chapters().isEmpty && controller.mediaSummary().width == 0 && !controller.hdrAvailable,
                  "retired chapters, summary and HDR capabilities fail closed")
        }
        print("\(checks) checks passed against the complete actual controller")
    }
}
