// Inert platform doubles around mechanically extracted production methods.
// CoreMedia/CoreVideo build CPU-backed sample buffers; no AVKit/Metal/UIKit runtime.
import Foundation
import Combine
import CoreMedia
import CoreVideo
import CoreGraphics

enum MPVProperty {
    static let pause = "pause", pausedForCache = "paused-for-cache"
    static let duration = "duration", timePos = "time-pos"
}
struct PlayerLoadToken: Equatable { let value = UUID() }
struct MPVResumeSeekTicket<Owner: Equatable> { let owner: Owner; let generation: UInt64; let target: Double }
enum PlaybackSettings { static var keepPlayingInBackground = false }
enum UIApplicationState { case active, inactive, background }
final class UIApplication {
    static let shared = UIApplication()
    var applicationState = UIApplicationState.active
}
enum DiagnosticsLog { static func log(_ channel: String, _ message: String) {} }
protocol AVPictureInPictureControllerDelegate: AnyObject {}
protocol AVPictureInPictureSampleBufferPlaybackDelegate: AnyObject {}
class FakeLayer: NSObject {
    weak var superlayer: FakeLayer?
    var frame = CGRect.zero
    func addSublayer(_ layer: FakeLayer) { layer.superlayer = self }
}
final class FakeView {
    var layer = FakeLayer()
    var bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
    var window: NSObject? = NSObject()
}
final class FakeMetalLayer {
    var completion: ((Bool) -> Void)?
    func requestPiPPresentation(_ value: @escaping (Bool) -> Void) { completion = value }
    func cancelPiPPresentation() { let old = completion; completion = nil; old?(false) }
    func cancelPendingCapture() {}
}
final class AVSampleBufferDisplayLayer: FakeLayer {
    enum Gravity { case resizeAspect }
    enum Status { case unknown, failed }
    var videoGravity = Gravity.resizeAspect
    var status = Status.unknown
    var isHidden = false
    var isReadyForMoreMediaData = true
    var controlTimebase: CMTimebase?
    var enqueued = 0, flushed = 0
    var lastPTS = Double.nan
    func flushAndRemoveImage() { flushed += 1 }
    func enqueue(_ sample: CMSampleBuffer) { enqueued += 1; lastPTS = CMSampleBufferGetPresentationTimeStamp(sample).seconds }
}
final class AVPictureInPictureController: NSObject {
    final class ContentSource {
        init(sampleBufferDisplayLayer: AVSampleBufferDisplayLayer, playbackDelegate: AVPictureInPictureSampleBufferPlaybackDelegate) {}
    }
    static var supported = true
    static func isPictureInPictureSupported() -> Bool { supported }
    init(contentSource: ContentSource) {}
    weak var delegate: AVPictureInPictureControllerDelegate?
    @objc dynamic var isPictureInPicturePossible = false
    var isPictureInPictureActive = false
    var canStartPictureInPictureAutomaticallyFromInline = false
    var starts = 0, stops = 0
    func startPictureInPicture() { starts += 1 }
    func stopPictureInPicture() { stops += 1; isPictureInPictureActive = false }
    func invalidatePlaybackState() {}
}

final class MPVMetalViewController {
    let queue = DispatchQueue(label: "inert-mpv-event-queue")
    let pipCaptureGate = MPVPiPCaptureGate()
    var pipGPUTransitionAttempted = false, pipGPURetired = false
    var pipForegroundAllowed = true, pipBackgroundDroppedVideo = false
    var pipResumeAfterOwnedBackgroundPause: PlayerLoadToken?
    var mpv: OpaquePointer! = OpaquePointer(bitPattern: 1)
    var activeLoadToken: PlayerLoadToken? = PlayerLoadToken()
    var view = FakeView()
    var viewIfLoaded: FakeView? { view }
    var isViewLoaded = true, startMuted = false, playUrlLive = false
    var probeChannel: StaticString = "player"
    var playDelegate: AnyObject?
    var metalLayer = FakeMetalLayer()
    var paused = true, seeking = false, buffering = false
    var requestedPauseIntent: Bool { paused }
    var wasPlayingBeforeBackground = false
    var playCalls = 0, stopCalls = 0
    var settled = false
    @MainActor lazy var pictureInPicture = MPVSampleBufferPiPController(owner: self)
    func callbackLoadToken(requiresLoadedFile: Bool = false) -> PlayerLoadToken? { activeLoadToken }
    func getFlag(_ property: String) -> Bool { property == "pause" ? paused : property == "seeking" ? seeking : buffering }
    func getDouble(_ property: String) -> Double { property == "duration" ? 120 : 42 }
    func play() { playCalls += 1; paused = false; pipResumeAfterOwnedBackgroundPause = nil }
    func pause() { paused = true; pipResumeAfterOwnedBackgroundPause = nil }
    func stop() { stopCalls += 1; mpv = nil }
    func applyVideoSize(_ apply: (String, String) -> Void) {}
    func setString(_ property: String, _ value: String) {}
    func seekForPiP(by interval: Double, owner: PlayerLoadToken) -> MPVResumeSeekTicket<PlayerLoadToken>? {
        .init(owner: owner, generation: 1, target: 42 + interval)
    }
    func piPSeekHasSettled(_ ticket: MPVResumeSeekTicket<PlayerLoadToken>) -> Bool { settled }
    // @@ENGINE_METHODS@@
}
var testVideoDropResult: Int32 = 0
var testVideoDrops = 0
@discardableResult
func mpv_set_property_string(_ handle: OpaquePointer, _ property: String, _ value: String) -> Int32 {
    if property == "vid" && value == "no" { testVideoDrops += 1; return testVideoDropResult }
    return 0
}
// Actual UIViewControllerRepresentable carries MainActor isolation.
@MainActor struct MPVMetalPlayerView {
    @MainActor final class Coordinator {
        weak var player: MPVMetalViewController?
        var pictureInPictureOwner: MPVMetalViewController?
    }
    // @@DISMANTLE_METHOD@@
}

// @@PRODUCTION_BRIDGE@@

@MainActor private var passed = 0
@MainActor private var failed = 0
@MainActor private func check(_ value: @autoclosure () -> Bool, _ description: String) {
    if value() { passed += 1; print("PASS \(description)") }
    else { failed += 1; print("FAIL \(description)") }
}

extension MPVSampleBufferPiPController {
    @MainActor static func runCases(dismantleOnly: Bool) async {
        func fixture() -> (MPVMetalViewController, MPVSampleBufferPiPController) {
            TestNativeReset()
            UIApplication.shared.applicationState = .active
            let owner = MPVMetalViewController()
            let pip = owner.pictureInPicture
            pip.start()
            return (owner, pip)
        }
        func close(_ owner: MPVMetalViewController, _ pip: MPVSampleBufferPiPController) {
            owner.pipGPURetired = false; owner.pipGPUTransitionAttempted = false
            pip.invalidate()
            TestNativeReset()
        }
        // The immutable original baseline contains this real unconditional stop.
        do {
            let (owner, pip) = fixture()
            let coordinator = MPVMetalPlayerView.Coordinator()
            coordinator.player = owner; owner.playDelegate = coordinator
            pip.phase = .active
            MPVMetalPlayerView.dismantleUIViewController(owner, coordinator: coordinator)
            check(owner.stopCalls == 0, "actual dismantle retains exact active PiP decoder")
            check(coordinator.pictureInPictureOwner === owner, "actual dismantle transfers exact controller lease")
            pip.invalidate()
            check(coordinator.pictureInPictureOwner == nil, "terminal disposal breaks coordinator-controller cycle")
            close(owner, pip)
        }
        do {
            let (owner, pip) = fixture()
            let coordinator = MPVMetalPlayerView.Coordinator()
            let differentOwner = MPVMetalViewController()
            coordinator.player = differentOwner
            pip.phase = .active
            MPVMetalPlayerView.dismantleUIViewController(owner, coordinator: coordinator)
            check(owner.stopCalls == 1, "differing coordinator cannot retain an old decoder")
            withExtendedLifetime(differentOwner) {}
            close(owner, pip)
        }
        if dismantleOnly { return }
        do {
            let gate = MPVPiPCaptureGate()
            check(gate.enter(), "capture gate admits one complete operation")
            let receipt = gate.seal()
            DispatchQueue.global().async { gate.leave() }
            check(gate.waitUntilDrained(receipt, before: Date().addingTimeInterval(0.5)), "actual condition wait receives worker completion without main dependency")
            gate.reopen()
            _ = gate.seal()
            check(!gate.waitUntilDrained(receipt, before: Date()), "reopened and reclosed gate revokes stale drain receipt")
        }
        do {
            let owner = MPVMetalViewController()
            let pip = owner.pictureInPicture
            check(owner.pipCaptureGate.enter(), "inert CI operation enters foreground gate")
            pip.start()
            check(pip.phase == .idle && pip.subscription == nil, "slow CI preflight refuses BEFORE arming PiP")
            owner.pipCaptureGate.leave()
            pip.start()
            check(pip.phase == .preparing, "complete CI receipt admits preparation")
            check(!owner.pipCaptureGate.enter(), "capture admission stays closed during preparation")
            close(owner, pip)
        }
        do {
            let (owner, pip) = fixture()
            var pixels: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixels)
            check(status == kCVReturnSuccess && pixels != nil, "CPU-only native pixel fixture created")
            let pointer = Unmanaged.passUnretained(pixels!).toOpaque()
            TestNativePublish(pointer, 42, 1.5, true, 1)
            TestNativePublish(pointer, 43, 1.5, true, 1)
            check(TestNativeOutstandingFrames() <= 2, "native mailbox never exceeds two leases")
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
            check(TestNativeOutstandingFrames() == 0, "sample creation releases all native leases")
            check(pip.displayLayer.enqueued == 1 && pip.displayLayer.lastPTS == 43, "actual consume uses latest decoded PTS not requested seek")
            check(pip.timebase.map { CMTimebaseGetRate($0) == 0 } == true, "paused native frame produces stopped timebase")
            owner.paused = false
            TestNativePublish(pointer, 43.5, 1.5, false, 1)
            try? await Task.sleep(nanoseconds: 10_000_000)
            check(pip.timebase.map { CMTimebaseGetRate($0) == 1.5 } == true, "actual scheduled playback rate reaches sample timebase")
            owner.paused = true
            check(pip.controller?.starts == 0, "device support and frame alone do not bypass possibility")
            pip.seekAccepted(previousEpoch: (1, 1))
            TestNativePublish(pointer, 44, 1, true, 1)
            try? await Task.sleep(nanoseconds: 10_000_000)
            check(pip.displayLayer.enqueued == 2, "accepted seek rejects old native timeline frames")
            TestNativePublish(pointer, 90, 1, true, 2)
            try? await Task.sleep(nanoseconds: 10_000_000)
            check(pip.displayLayer.lastPTS == 90, "new achieved native epoch resumes frame admission")
            TestNativePublish(pointer, 91, 1, true, 2)
            pip.invalidate()
            try? await Task.sleep(nanoseconds: 10_000_000)
            check(TestNativeOutstandingFrames() == 0 && TestNativeDestroyCalls() == 1, "retirement drops pending frame and destroys receiver once")
            close(owner, pip)
        }
        do {
            let (owner, pip) = fixture()
            owner.pipGPURetired = true
            pip.phase = .restoring; pip.restoreInFlight = true
            pip.restoreAcknowledged = true; pip.restorePresented = true
            var restores: [Bool] = []
            pip.restoration = { restores.append($0) }
            owner.activeLoadToken = PlayerLoadToken()
            pip.completeInlineRestoreIfReady(request: pip.generation)
            check(restores.isEmpty, "changed playback owner cannot consume late physical restore receipt")
            pip.invalidate()
            check(restores == [false], "retired restoration completion declines exactly once")
            close(owner, pip)
        }
        do {
            let (owner, pip) = fixture()
            owner.pipGPURetired = true; owner.pipGPUTransitionAttempted = true
            pip.phase = .active
            TestNativeSetModeResult(9)
            check(!pip.retireForSourceReplacement(), "negative restore refuses replacement")
            check(pip.subscription != nil && owner.paused, "negative restore retains authority and old pause")
            pip.restoreInFlight = true
            pip.endInlineRestore(succeeded: false)
            check(pip.phase == .restoring && pip.subscription != nil, "failed inline restore never launders retired GPU into idle")
            TestNativeSetModeResult(0)
            check(pip.retireForSourceReplacement(), "same-owner retry restores before allowing replacement")
            check(pip.phase == .idle && owner.paused && owner.playCalls == 0, "replacement disposal never unpauses old media")
            close(owner, pip)
        }
        do {
            let (owner, pip) = fixture()
            pip.phase = .active
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixels)
            let pointer = Unmanaged.passUnretained(pixels!).toOpaque()
            TestNativePublish(pointer, 40, 1, true, 1)
            try? await Task.sleep(nanoseconds: 10_000_000)
            var skips = 0
            pip.pictureInPictureController(pip.controller!, skipByInterval: CMTime(seconds: 10, preferredTimescale: 600)) { skips += 1 }
            owner.settled = true
            pip.refreshStatus()
            check(skips == 0, "native settle before achieved frame does not complete skip")
            owner.settled = false
            TestNativePublish(pointer, 50, 1, true, 2)
            try? await Task.sleep(nanoseconds: 10_000_000)
            pip.refreshStatus()
            check(skips == 0, "achieved frame before native settle does not complete skip")
            owner.settled = true
            pip.refreshStatus(); pip.refreshStatus()
            check(skips == 1, "achieved frame plus exact command settlement completes skip once")
            close(owner, pip)
        }
        do {
            let (owner, pip) = fixture()
            pip.phase = .active
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixels)
            let pointer = Unmanaged.passUnretained(pixels!).toOpaque()
            TestNativePublish(pointer, 10, 1, true, 1)
            try? await Task.sleep(nanoseconds: 10_000_000)
            var firstSkip = 0, latestSkip = 0
            pip.pictureInPictureController(pip.controller!, skipByInterval: CMTime(seconds: 10, preferredTimescale: 600)) { firstSkip += 1 }
            TestNativeAdvanceEpoch(2)
            // The second command is queued before seek1's frame reaches main.
            pip.pictureInPictureController(pip.controller!, skipByInterval: CMTime(seconds: 20, preferredTimescale: 600)) { latestSkip += 1 }
            TestNativePublish(pointer, 20, 1, true, 2)
            try? await Task.sleep(nanoseconds: 10_000_000)
            // Then the second RESET/settlement outruns its delivered frame.
            TestNativeAdvanceEpoch(3)
            owner.settled = true
            pip.refreshStatus()
            check(firstSkip == 1 && latestSkip == 0, "rapid seek settlement rejects preceding seek's consumed native epoch")
            TestNativePublish(pointer, 30, 1, true, 3)
            check(TestNativeOutstandingFrames() <= 2, "pending skip epoch witness preserves native two-lease cap")
            try? await Task.sleep(nanoseconds: 10_000_000)
            pip.refreshStatus(); pip.refreshStatus()
            check(latestSkip == 1 && pip.displayLayer.lastPTS == 30, "latest current native frame completes rapid skip exactly once")
            check(TestNativeOutstandingFrames() == 0, "completed rapid skip releases its native epoch witness")
            close(owner, pip)
        }
        do {
            let (owner, pip) = fixture()
            let originalOwner = owner.activeLoadToken
            owner.pipGPURetired = true
            pip.phase = .active
            var cleanupCalls = 0
            _ = pip.retainDisappearance(.screen) {
                cleanupCalls += 1
                owner.activeLoadToken = nil // actual screen cleanup invalidates old provenance
            }
            let modeCalls = TestNativeModeCalls()
            check(!pip.retireForSourceReplacement(), "pending screen cleanup refuses pre-admission replacement")
            check(owner.activeLoadToken == originalOwner && cleanupCalls == 0 && owner.paused,
                  "rejected detached replacement preserves exact old token pause and cleanup lease")
            check(TestNativeModeCalls() == modeCalls, "detached replacement refuses before touching native renderer")
            close(owner, pip)
        }
        do {
            let owner = MPVMetalViewController()
            check(owner.pictureInPicture.retireForSourceReplacement(), "ordinary no-PiP source replacement remains admitted")
        }
        do {
            let (owner, pip) = fixture()
            owner.pipGPURetired = true; pip.phase = .active
            UIApplication.shared.applicationState = .background
            let calls = TestNativeModeCalls()
            check(!pip.retireForSourceReplacement() && TestNativeModeCalls() == calls, "background replacement cannot recreate GPU")
            UIApplication.shared.applicationState = .active
            close(owner, pip)
        }
        do {
            let (owner, pip) = fixture()
            owner.wasPlayingBeforeBackground = true
            owner.paused = true
            pip.willResignActive()
            pip.becameActive() // NO didEnterBackground: stale prior flag must be irrelevant
            check(owner.paused && owner.playCalls == 0, "transient resign does not borrow prior-cycle playing flag")
            close(owner, pip)
        }
        do {
            let (owner, pip) = fixture()
            pip.phase = .active
            var ends = 0
            check(pip.retainDisappearance(.screen) { ends += 1 }, "screen cleanup explicitly transfers to active PiP")
            check(pip.resumeDisappearance(.screen), "same owner consumes transfer without another begin")
            pip.invalidate()
            check(ends == 0, "remounted screen lease is not ended by PiP disposal")
            close(owner, pip)
        }
        do {
            let (owner, pip) = fixture()
            pip.phase = .active
            var ends = 0
            _ = pip.retainDisappearance(.screen) { ends += 1; pip.invalidate() }
            _ = pip.retainDisappearance(.presentation) { ends += 1 }
            pip.invalidate(); pip.invalidate()
            check(ends == 2, "both appearance leases close once despite recursive terminal invalidation")
            close(owner, pip)
        }
        do {
            let (owner, pip) = fixture()
            owner.pipGPURetired = true; pip.phase = .restoring
            pip.restoreInFlight = true; pip.restoreAcknowledged = true
            var restoration: [Bool] = []
            pip.restoration = { restoration.append($0) }
            pip.completeInlineRestoreIfReady(request: pip.generation)
            check(restoration.isEmpty, "native acknowledgement alone cannot prove inline presentation")
            owner.pipGPURetired = false
            pip.restorePresented = true
            pip.completeInlineRestoreIfReady(request: pip.generation)
            check(restoration == [true], "actual presentation plus native acknowledgement restores once")
            pip.completeInlineRestoreIfReady(request: pip.generation)
            check(restoration == [true], "late duplicate restore completion is inert")
            close(owner, pip)
        }
    }
}

@main struct HostTests {
    @MainActor static func main() async {
        await MPVSampleBufferPiPController.runCases(dismantleOnly: CommandLine.arguments.contains("--dismantle-only"))
        print("RESULT \(passed) PASS / \(failed) FAIL")
        exit(failed == 0 ? 0 : 1)
    }
}
