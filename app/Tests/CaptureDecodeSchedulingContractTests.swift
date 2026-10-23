import Foundation

// Host runner inserts each production captureFrameJPEGData completion at its matching marker.
// A deterministic decoder gate proves queue scheduling and stale-generation rejection; no GPU/player runs.
private struct FixtureImage: Sendable {}
private final class DecodeControl: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var count = 0
    private var main = false
    var starts: Int { lock.lock(); defer { lock.unlock() }; return count }
    var decodedOnMain: Bool { lock.lock(); defer { lock.unlock() }; return main }
    func begin() {
        lock.lock(); count += 1; main = main || Thread.isMainThread; lock.unlock()
        _ = release.wait(timeout: .now() + 2)
    }
    func proceed() { release.signal() }
}
@MainActor private final class ScrubThumbnailsStore {
    nonisolated static let control = DecodeControl()
    var records = 0
    nonisolated static func decodeCapturedFrame(_ data: Data, at time: Double) -> FixtureImage? {
        control.begin()
        return FixtureImage()
    }
    func recordDecodedFrame(_ frame: FixtureImage, data: Data, at time: Double) { records += 1 }
}
private enum VXProbe { static func log(_ channel: String, _ message: String) {} }
private struct FixtureBreaker { mutating func recordCapture(hadData: Bool) -> Bool { false } }
@MainActor private final class FixtureCaptureEngine {
    let payload: Data?
    init(_ payload: Data?) { self.payload = payload }
    func captureFrameJPEGData(maxWidth: CGFloat, completion: @escaping (Data?) -> Void) {
        let payload = payload
        DispatchQueue.main.async { completion(payload) }
    }
}
@MainActor private final class FixtureCaptureView {
    var localTrickplayCaptureGeneration: UInt64 = 0
    var localTrickplayCaptureInFlight = false
    var localTrickplayCaptureBreaker = FixtureBreaker()
    var trickplayCaptureCompletionsSinceReceipt = 0
    var trickplayCaptureNilSinceReceipt = 0
    var scrubThumbnails = ScrubThumbnailsStore()
    var lastWatchdog: Task<Void, Never>?
    func ownsLocalTrickplayCapture(_ generation: UInt64) -> Bool {
        localTrickplayCaptureInFlight && localTrickplayCaptureGeneration == generation
    }
    func captureTV(_ payload: Data?) {
        localTrickplayCaptureGeneration += 1
        localTrickplayCaptureInFlight = true
        let captureGeneration = localTrickplayCaptureGeneration
        let time = 10.0, engine = "avplayer"
        let watchdog = Task<Void, Never> {}
        lastWatchdog = watchdog
        let player = FixtureCaptureEngine(payload)
        // __PRODUCTION_TV_CAPTURE_COMPLETION__
    }
    func captureIOS(_ payload: Data?) {
        localTrickplayCaptureGeneration += 1
        localTrickplayCaptureInFlight = true
        let captureGeneration = localTrickplayCaptureGeneration
        let time = 10.0, engine = "avplayer"
        let watchdog = Task<Void, Never> {}
        lastWatchdog = watchdog
        let player = FixtureCaptureEngine(payload)
        // __PRODUCTION_IOS_CAPTURE_COMPLETION__
    }
}
@main @MainActor private enum CaptureDecodeSchedulingContractTests {
    static func awaitCondition(_ label: String, _ predicate: @MainActor () -> Bool) async {
        for _ in 0..<2_000 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("Timed out: \(label)")
    }
    static func check(_ label: String, _ condition: Bool) {
        precondition(condition, label)
        print("PASS \(label)")
    }
    static func run(_ label: String, capture: @MainActor (FixtureCaptureView, Data?) -> Void) async {
        let view = FixtureCaptureView()
        let fixture = Data("fixture jpeg bytes".utf8)
        let starts = ScrubThumbnailsStore.control.starts
        capture(view, fixture)
        await awaitCondition("\(label) decoder starts") { ScrubThumbnailsStore.control.starts == starts + 1 }
        check("\(label) main actor remains responsive during JPEG work", !ScrubThumbnailsStore.control.decodedOnMain)
        view.localTrickplayCaptureGeneration += 1
        ScrubThumbnailsStore.control.proceed()
        await awaitCondition("\(label) stale decode completes") { view.lastWatchdog?.isCancelled == true }
        check("\(label) stale decode cannot publish a frame", view.scrubThumbnails.records == 0)

        capture(view, fixture)
        await awaitCondition("\(label) current decoder starts") { ScrubThumbnailsStore.control.starts == starts + 2 }
        ScrubThumbnailsStore.control.proceed()
        await awaitCondition("\(label) current frame publishes") { view.scrubThumbnails.records == 1 }
        check("\(label) owned decode publishes once and releases capture", !view.localTrickplayCaptureInFlight)

        capture(view, nil)
        await awaitCondition("\(label) nil completion") { view.lastWatchdog?.isCancelled == true }
        check("\(label) nil result releases capture without JPEG work", !view.localTrickplayCaptureInFlight
              && view.scrubThumbnails.records == 1 && ScrubThumbnailsStore.control.starts == starts + 2)
    }
    static func main() async {
        await run("tvOS", capture: { $0.captureTV($1) })
        await run("iOS/macOS", capture: { $0.captureIOS($1) })
        print("CAPTURE_DECODE_SCHEDULING_GREEN")
    }
}
