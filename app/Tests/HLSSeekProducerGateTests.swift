import Foundation

struct RemoteConfig {
    struct Snapshot { let dvRemuxWindowMiB: Int }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}
enum DiagnosticsLog { static func log(_ tag: String, _ message: String) {} }

/// Only the stream's immutable retained-window snapshot is substituted. The script inserts the actual
/// server's seek admission, completion, cancellation and producer-gate methods at the marker below.
private final class FixtureStream: @unchecked Sendable {
    let producerLeadGate = VortXRemuxProducerLeadGate()
    let window: VortXHLSWindow
    private(set) var snapshotCount = 0
    init(window: VortXHLSWindow) { self.window = window }
    func hlsWindowSnapshot() -> (window: VortXHLSWindow, ended: Bool) {
        snapshotCount += 1
        return (window, false)
    }
}

private final class SeekGateFixture: @unchecked Sendable {
    private let seekReceiptQueue = DispatchQueue(label: "vortx.test.seek-receipt")
    private let publicationLock = NSLock()
    private let playbackClockLock = NSLock()
    private let producerLeadLock = NSLock()
    private let engineReadyLock = NSLock()
    private let retainsFullTimeline = false
    private let consumptionAnchored = true
    private let engineReady = true
    private var publishedVideoWindow: VortXHLSWindow?
    private var seekAnchorState = VortXHLSSeekAnchorState()
    private var producerLeadLedger = VortXRemuxProducerLeadLedger()
    private var producerLeadPhase = VortXRemuxProducerLeadPolicy.Phase.steady
    private var producerLeadNeedsReanchor = false
    private var lastProducerLeadPaused: Bool?
    private var couplingProducedMediaSeconds: Double = 0
    private var couplingProducedBytes = 0
    private let stream: FixtureStream
    private func observedSourceBitsPerSecond() -> Double? { nil }

    init() {
        // A parked high-bitrate source has published ten six-second segments while playback is at 6s.
        // The seek to 58s is inside the last published segment but requires further media to refill.
        let segmentBytes = VortXRemuxProducerLeadPolicy.maximumAheadBytes / 8
        let segments = (0..<10).map {
            VortXHLSSegment(id: $0, byteOffset: $0 * segmentBytes,
                byteLength: segmentBytes, start: Double($0) * 6, duration: 6)
        }
        let window = VortXHLSWindow(segments: segments)
        stream = FixtureStream(window: window)
        publishedVideoWindow = window
        for segment in segments { refreshProducerLeadGate(producedReceipt: segment) }
        reportPlaybackPosition(playerSeconds: 6, receiptEpoch: seekAnchorState.playbackReceiptEpoch)
    }

    var paused: Bool { stream.producerLeadGate.isPaused }
    var producerClock: Double? { producerLeadLedger.playbackSeconds }
    var outstandingBytes: Int { producerLeadLedger.outstandingBytes }
    var epoch: UInt64 { seekAnchorState.playbackReceiptEpoch }
    var displayedClock: Double? { seekAnchorState.currentPlaybackSeconds }
    var snapshotCount: Int { stream.snapshotCount }

    // INSERT PRODUCTION SERVER METHODS
}

@main
enum HLSSeekProducerGateTests {
    static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }

        let fixture = SeekGateFixture()
        check(fixture.paused && fixture.producerClock == 6, "fixture parks at the outgoing playhead")
        let oldEpoch = fixture.epoch
        let initialSnapshots = fixture.snapshotCount
        fixture.registerLatestSeekRequest(requestID: 1)
        check(fixture.snapshotCount == initialSnapshots,
              "ordinary registration avoids retained-window snapshot work on the caller")
        check(await fixture.prepareForSeek(playerSeconds: 58, requestID: 1), "tail seek is backed by published bytes")
        check(!fixture.paused && fixture.producerClock == 58,
              "admitted forward seek releases producer before native completion needs more media")
        fixture.reportPlaybackPosition(playerSeconds: 6.25, receiptEpoch: oldEpoch)
        check(fixture.producerClock == 58, "outgoing clock cannot revoke the accepted seek's refill reservation")
        fixture.completePreparedSeek(requestID: 1, playerSeconds: 53.5)
        check(fixture.producerClock == 53.5 && fixture.displayedClock == 53.5,
              "actual earlier keyframe landing replaces provisional destination")
        check(fixture.outstandingBytes == VortXRemuxProducerLeadPolicy.maximumAheadBytes / 4,
              "actual landing rebuilds both outstanding segments after provisional compaction")

        let cancelled = SeekGateFixture()
        cancelled.registerLatestSeekRequest(requestID: 1)
        _ = await cancelled.prepareForSeek(playerSeconds: 58, requestID: 1)
        cancelled.cancelPreparedSeek(requestID: 1)
        check(cancelled.paused && cancelled.producerClock == 6,
              "cancel restores confirmed producer budget without waiting for a paused player's tick")

        let superseded = SeekGateFixture()
        superseded.registerLatestSeekRequest(requestID: 1)
        _ = await superseded.prepareForSeek(playerSeconds: 58, requestID: 1)
        superseded.registerLatestSeekRequest(requestID: 2)
        check(superseded.paused && superseded.producerClock == 6,
              "new admission retires the old provisional reservation immediately")
        _ = await superseded.prepareForSeek(playerSeconds: 52, requestID: 2)
        superseded.cancelPreparedSeek(requestID: 1)
        superseded.completePreparedSeek(requestID: 1, playerSeconds: 0)
        check(superseded.producerClock == 52 && !superseded.paused,
              "stale cancellation and completion cannot change the newer producer anchor")
        superseded.completePreparedSeek(requestID: 2, playerSeconds: .nan)
        check(superseded.producerClock == 6 && superseded.paused,
              "invalid current landing retires the provisional reservation")

        let unadmitted = SeekGateFixture()
        let unadmittedSnapshots = unadmitted.snapshotCount
        unadmitted.registerLatestSeekRequest(requestID: 1)
        unadmitted.cancelPreparedSeek(requestID: 1)
        check(unadmitted.snapshotCount == unadmittedSnapshots && unadmitted.producerClock == 6,
              "pre-admission cancellation does not rebuild an unchanged producer budget")
        unadmitted.registerLatestSeekRequest(requestID: 2)
        unadmitted.completePreparedSeek(requestID: 2, playerSeconds: .nan)
        check(unadmitted.snapshotCount == unadmittedSnapshots && unadmitted.paused,
              "invalid pre-admission completion does not snapshot or release the producer")

        let rejected = SeekGateFixture()
        let rejectedSnapshots = rejected.snapshotCount
        rejected.registerLatestSeekRequest(requestID: 1)
        check(!(await rejected.prepareForSeek(playerSeconds: 100, requestID: 1)), "unpublished target is rejected")
        check(rejected.paused && rejected.producerClock == 6,
              "rejected seek cannot release the producer beyond its byte budget")
        check(rejected.snapshotCount == rejectedSnapshots, "rejected admission never snapshots the retained window")
        print("HLS seek producer gate failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
