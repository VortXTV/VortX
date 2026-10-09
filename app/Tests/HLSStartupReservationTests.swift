import Foundation

struct RemoteConfig {
    struct Snapshot { let dvRemuxWindowMiB: Int }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}
enum DiagnosticsLog { static func log(_ tag: String, _ message: String) {} }
enum VortXRemuxProducerArbitration { enum Purpose { case playback, preparation } }

/// No media, network, AVFoundation or FFmpeg. Segment lengths below are metadata, not allocations.
private final class VortXMKVRemuxStream: @unchecked Sendable {
    struct Signaling { var dolbyVision = true }
    struct HLSWindowSnapshot {
        var initData: Data? = Data([0])
        var window = VortXHLSWindow(segments: [])
        var ended = false
        var signaling: Signaling? = Signaling()
        var audioPlan: MultiAudioPolicy.RenditionPlan?
        var audioInitData: Data? = Data([0])
        var audioWindow: VortXHLSWindow?
        var audioState = MultiAudioPolicy.StartupState.pending
        var primaryAudioTag: String?
        var subtitleRenditions: [SubtitleRenditionPolicy.Rendition] = []
        var subtitleCues: [[SubtitleRenditionPolicy.Cue]] = [[]]
        var subtitleWindow: VortXHLSWindow?
        var subtitleFailureReason: SubtitleRenditionPolicy.InvalidationReason?
        var frozenTarget = VortXHLSTargetPolicy.conservativeTarget
    }
    enum SubtitleBackingOutcome { case ready, pendingAdmission, fatal(String) }
    final class Buffer {
        struct Status { let failure: String? }
        var failure: String?
        func status() -> Status { Status(failure: failure) }
    }
    let buffer = Buffer()
    let producerLeadGate = VortXRemuxProducerLeadGate()
    let preparationGate = VortXRemuxPreparationGate()
    var snapshot = HLSWindowSnapshot()
    var resources = Set<VortXHLSSessionSpool.ResourceKey>()
    var backingOutcome = SubtitleBackingOutcome.ready
    var rejectPublication = false
    var receipts: [[VortXHLSSessionSpool.ResourceKey]] = []
    func hlsWindowSnapshot() -> HLSWindowSnapshot { snapshot }
    func hlsSnapshot() -> HLSWindowSnapshot { snapshot }
    func hasHLSResource(_ key: VortXHLSSessionSpool.ResourceKey) -> Bool { resources.contains(key) }
    func failHLS(_ reason: String) { buffer.failure = reason }
    func recordHLSPlaylist(_ id: String, resourceKeys: [VortXHLSSessionSpool.ResourceKey], now: TimeInterval) -> Bool {
        guard !rejectPublication, resourceKeys.allSatisfy(resources.contains) else { return false }
        receipts.append(resourceKeys)
        return true
    }
    func ensureSubtitleBackings(window: VortXHLSWindow, renditions: [(id: Int, cues: [SubtitleRenditionPolicy.Cue])]) -> SubtitleBackingOutcome {
        if case .ready = backingOutcome {
            for rendition in renditions {
                for segment in window.segments { resources.insert(.subtitle(renditionID: rendition.id, segmentID: segment.id)) }
            }
        }
        return backingOutcome
    }
    func requestPreparationProducerPark() -> Bool { preparationGate.requestParkAfterBoundary() }
    var isPreparationProducerParked: Bool { preparationGate.isParked }
    func resumePreparationProducer() { preparationGate.resume() }
    func mountProgress() -> (segmentCount: Int, producedBytes: Int) {
        (snapshot.window.segments.count, snapshot.window.segments.reduce(0) { $0 + $1.byteLength })
    }
    func cancel() { producerLeadGate.cancel(); preparationGate.cancel() }
}

private final class StartupFixture: @unchecked Sendable {
    let stream = VortXMKVRemuxStream()
    private let publicationLock = NSLock(), playbackClockLock = NSLock(), producerLeadLock = NSLock()
    private let engineReadyLock = NSLock(), producerLifecycleLock = NSLock(), deadlineLock = NSLock()
    private let seekReceiptQueue = DispatchQueue(label: "startup-fixture.seek")
    private var producerLeadLedger = VortXRemuxProducerLeadLedger()
    #if STARTUP_RESERVATION
    private var producerLeadPhase = VortXRemuxProducerLeadPolicy.Phase.startup
    #endif
    private var producerLeadNeedsReanchor = false
    private var seekAnchorState = VortXHLSSeekAnchorState()
    private var lastProducerLeadPaused: Bool?
    private var couplingProducedBytes = 0, couplingProducedMediaSeconds: Double = 0
    private let retainsFullTimeline = false, consumptionAnchored = true, engineReady = false
    private var startupMediaList: (window: VortXHLSWindow, ended: Bool)?
    private var publishedVideoWindow: VortXHLSWindow?
    private var advertisedAudioPlan: MultiAudioPolicy.RenditionPlan?
    private var advertisedPrimaryAudioTag: String?, advertisedAudioInitData: Data?
    private var lastPublishedAudioWindow: VortXHLSWindow?, lastPublishedSubtitleWindow: VortXHLSWindow?
    private var advertisedSubtitles: [SubtitleRenditionPolicy.Rendition] = []
    private var subtitleRouteTerminated = false, advertisedDolbyVision = false
    private let startupReadiness = VortXHLSStartupReadiness(frozenTarget: VortXHLSTargetPolicy.conservativeTarget)!
    private var producerPurpose: VortXRemuxProducerArbitration.Purpose? = .playback
    private var producerTerminated = false, preparedReady = false, preparedAdopted = false
    private var onStartupTimeout: @Sendable (VortXRemuxHLSServer) -> Void = { _ in }
    private var mountDeadline = VortXHLSMountDeadlineState()
    private let port = 0
    var isInvalidated = false
    var scheduledPolls = 0
    private struct MasterPublication {
        let audioPlan: MultiAudioPolicy.RenditionPlan?
        let primaryAudioTag: String?
        let subtitles: [SubtitleRenditionPolicy.Rendition]
    }
    init(preparation: Bool = false, siblings: Bool = false) {
        producerPurpose = preparation ? .preparation : .playback
        stream.snapshot.audioState = .failed // no alternate requested
        if siblings {
            stream.snapshot.audioState = .ready
            stream.snapshot.audioPlan = .init(
                primary: .init(id: 0, sourceIndex: 1, name: "A", language: "en", channelSignaling: .physical(2), isInBand: true),
                alternate: .init(id: 1, sourceIndex: 2, name: "B", language: "fr", channelSignaling: .physical(2), isInBand: false))
            stream.snapshot.subtitleRenditions = [.init(id: 0, sourceIndex: 3, format: .plainText,
                name: "Test", language: "en", isDefault: false, isAutoSelect: false, isForced: false)]
        }
    }
    private func observedSourceBitsPerSecond() -> Double? { nil }
    private func schedulePreparedReadinessPoll() { scheduledPolls += 1 }
    private func armMountDeadline() -> Bool { mountDeadline.start(now: 0) != nil }
    var paused: Bool { stream.producerLeadGate.isPaused }
    var ready: Bool { preparedReady }
    var cohortCount: Int { startupMediaList?.window.segments.count ?? 0 }
    var budget: Int {
        #if STARTUP_RESERVATION
        return producerLeadPhase.maximumAheadBytes
        #else
        return VortXRemuxProducerLeadPolicy.maximumAheadBytes
        #endif
    }
    var bytes: Int { producerLeadLedger.outstandingBytes }
    @discardableResult func publish(bytes: Int, duration: Double = 4) -> Bool {
        guard !paused else { return false }
        let old = stream.snapshot.window.segments
        let segment = VortXHLSSegment(id: old.count, byteOffset: old.reduce(0) { $0 + $1.byteLength },
            byteLength: bytes, start: old.last?.end ?? 0, duration: duration)
        stream.snapshot.window = VortXHLSWindow(segments: old + [segment])
        stream.resources.insert(.video(segmentID: segment.id))
        refreshProducerLeadGate(producedReceipt: segment)
        return true
    }
    func alignSiblings(audioDuration: Double = 4) {
        let video = stream.snapshot.window
        stream.snapshot.audioWindow = VortXHLSWindow(segments: video.segments.map {
            VortXHLSSegment(id: $0.id, byteOffset: 0, byteLength: 1, start: Double($0.id) * audioDuration, duration: audioDuration)
        })
        stream.snapshot.subtitleWindow = video
        for segment in video.segments { stream.resources.insert(.audio(renditionID: 1, segmentID: segment.id)) }
    }
    func master() -> Bool { prepareMasterPublication() != nil }
    func poll() { pollPreparedReadiness() }
    func clock(_ seconds: Double, epoch: UInt64? = nil) {
        reportPlaybackPosition(playerSeconds: seconds, receiptEpoch: epoch ?? seekAnchorState.playbackReceiptEpoch)
    }
    func end() { stream.snapshot.ended = true; producerTerminated = true }
    func cancel() { isInvalidated = true; stream.cancel() }
    func adopt() -> Bool { adoptPrepared(onStartupTimeout: { _ in }) }
    func waitForPreparation() {
        let deadline = Date(timeIntervalSinceNow: 1)
        repeat { poll(); Thread.sleep(forTimeInterval: 0.001) } while !ready && Date() < deadline
    }
    // INSERT PRODUCTION SERVER METHODS
}
private typealias VortXRemuxHLSServer = StartupFixture

private func receiptArrived(_ semaphore: DispatchSemaphore, timeout: Double = 1) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}

@main
enum HLSStartupReservationTests {
    static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        let mib = 1024 * 1024
        let high = StartupFixture()
        high.publish(bytes: 80 * mib); high.publish(bytes: 80 * mib)
        print("RECEIPT pre-master producedSeconds=\(high.stream.snapshot.window.segments.last?.end ?? 0) aheadBytes=\(high.bytes) gatePaused=\(high.paused) requiredMilliseconds=\(VortXHLSStartupReadiness.startupFloorMilliseconds)")
        check(!high.master() && high.bytes == 160 * mib, "8s/160MiB cannot advertise the 12s startup cohort")
        check(!high.paused, "startup must not park at 8s before master readiness")
        check(high.publish(bytes: 80 * mib) && high.master() && high.cohortCount == 3,
              "third legal fragment makes coherent 12s/240MiB master consumable")
        check(high.budget == 160 * mib && high.paused, "durable master immediately retires startup grant to steady160")
        high.clock(4)
        check(high.paused, "steady byte hysteresis retains park at160MiB after first consumed fragment")
        high.clock(8)
        check(!high.paused && high.bytes == 80 * mib, "actual consumption drains below136MiB and resumes producer")
        high.registerLatestSeekRequest(requestID: 1)
        _ = await high.prepareForSeek(playerSeconds: 11, requestID: 1)
        high.cancelPreparedSeek(requestID: 1)
        check(high.budget == 160 * mib, "seek admission and cancellation never regrant startup history share")

        let normal = StartupFixture()
        for _ in 0..<3 { normal.publish(bytes: 8 * mib) }
        check(normal.master() && !normal.paused, "ordinary bitrate retains coherent startup without unnecessary park")
        let clock = StartupFixture()
        clock.clock(0)
        check(clock.budget == 288 * mib, "initial zero clock is not consumption proof")
        clock.clock(1, epoch: 999)
        check(clock.budget == 288 * mib, "stale positive clock cannot retire reservation")
        clock.clock(1)
        check(clock.budget == 160 * mib, "admitted positive clock retires history borrowing")

        let aligned = StartupFixture(siblings: true)
        for _ in 0..<3 { aligned.publish(bytes: 80 * mib) }
        check(!aligned.master() && aligned.budget == 288 * mib, "video alone never retires grant before aligned siblings exist")
        aligned.alignSiblings(audioDuration: 3.9)
        check(!aligned.master(), "all advertised renditions independently satisfy rendered12s")
        aligned.publish(bytes: 80 * mib)
        aligned.alignSiblings(audioDuration: 3.9)
        aligned.stream.backingOutcome = .pendingAdmission
        check(!aligned.master() && aligned.paused && aligned.bytes <= 352 * mib,
              "pending subtitle backing remains bounded at startup reservation plus closed boundary")
        aligned.stream.backingOutcome = .ready
        check(aligned.master() && aligned.cohortCount == 4 && aligned.stream.receipts.count == 4,
              "durable aligned video/DV/audio/subtitle routes commit before grant retirement")

        let missing = StartupFixture(siblings: true)
        while missing.publish(bytes: 72 * mib) {}
        check(missing.bytes == 288 * mib && missing.paused && !missing.master(),
              "unready topology cannot extend startup production beyond bounded288MiB")
        let rejected = StartupFixture()
        for _ in 0..<3 { rejected.publish(bytes: 80 * mib) }
        rejected.stream.rejectPublication = true
        check(!rejected.master() && rejected.stream.buffer.status().failure != nil && rejected.budget == 288 * mib,
              "failed playlist receipt cannot claim a consumable master or retire the phase")

        let prepared = StartupFixture(preparation: true)
        while prepared.publish(bytes: 72 * mib) {}
        prepared.poll()
        check(!prepared.ready, "requested lead pause alone is not preparation acknowledgement")
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = prepared.stream.producerLeadGate.waitAtClosedSegmentBoundaryIfPaused()
            finished.signal()
        }
        // Actual method keeps polling; allow the real producer condition wait to acknowledge the closed edge.
        prepared.waitForPreparation()
        check(prepared.ready, "already physically lead-parked producer completes preparation after master commit")
        check(prepared.adopt() && !prepared.adopt(), "prepared mount is adopted once without restarting producer")
        check(prepared.paused && prepared.budget == 160 * mib, "adoption preserves steady byte park until consumption")
        prepared.clock(12)
        check(receiptArrived(finished), "adopted real clock releases physically parked producer")
        prepared.cancel()
        _ = receiptArrived(finished, timeout: 0.01)

        let warm = StartupFixture(preparation: true)
        for _ in 0..<3 { warm.publish(bytes: 8 * mib) }
        warm.poll()
        let warmFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = warm.stream.preparationGate.waitAtClosedSegmentBoundary()
            _ = warm.stream.producerLeadGate.waitAtClosedSegmentBoundaryIfPaused()
            warmFinished.signal()
        }
        warm.waitForPreparation()
        check(warm.ready && warm.adopt() && receiptArrived(warmFinished),
              "normal bitrate preparation gate still parks and adopts at a real closed boundary")
        warm.cancel()

        let cancelled = StartupFixture(preparation: true)
        while cancelled.publish(bytes: 72 * mib) {}
        cancelled.stream.cancel() // race cancellation after the outer invalidation check
        cancelled.poll()
        check(!cancelled.ready, "cancelled gates never count as prepared park acknowledgement")
        check(cancelled.stream.producerLeadGate.waitAtClosedSegmentBoundaryIfPaused() == .cancelled,
              "cancellation permanently releases and retires the producer gate")
        let terminalCancelled = StartupFixture(preparation: true)
        terminalCancelled.publish(bytes: 8 * mib); terminalCancelled.end()
        terminalCancelled.stream.cancel(); terminalCancelled.poll()
        check(!terminalCancelled.ready, "cancelled terminal producer cannot mint a new prepared-ready receipt")
        #if STARTUP_RESERVATION
        let gate = VortXRemuxProducerLeadGate()
        gate.setPaused(true)
        check(!gate.isParked, "new mount requested pause cannot borrow another mount's parked acknowledgement")
        let cancelledWait = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = gate.waitAtClosedSegmentBoundaryIfPaused()
            cancelledWait.signal()
        }
        waitForPark(gate)
        check(gate.isParked, "gate acknowledgement belongs to its actual producer condition wait")
        gate.cancel()
        check(!gate.isParked && receiptArrived(cancelledWait),
              "cancel clears actual parked receipt and wakes blocked producer")
        #endif
        let eof = StartupFixture(preparation: true)
        eof.publish(bytes: 80 * mib)
        eof.end(); eof.poll()
        check(eof.ready && eof.cohortCount == 1 && eof.budget == 160 * mib,
              "short true EOF publishes legal terminal cohort without waiting for nonexistent12s")

        check(VortXRemuxProducerLeadPolicy.maximumAheadBytes == 160 * mib
              && VortXRemuxProducerLeadPolicy.byteResumeThreshold == 136 * mib,
              "unchanged steady160MiB and85percent hysteresis")
        check(288 * mib + VortXHLSConsumptionWindowPolicy.closedBoundaryAllowanceBytes
              == VortXHLSConsumptionWindowPolicy.retainedWindowMaximumBytes,
              "startup borrowing and closed boundary fit one352MiB publication share")
        check(2 * VortXHLSConsumptionWindowPolicy.retainedWindowMaximumBytes
              + VortXHLSConsumptionWindowPolicy.operationalReserveBytes
              + VortXHLSConsumptionWindowPolicy.safetyHeadroomBytes == 1024 * mib,
              "predecessor operational and safety shares retain exact1GiB planning envelope")
        var deadline = VortXHLSMountDeadlineState()
        _ = deadline.start(now: 0)
        check(deadline.remaining(now: 30).didExpire, "unready startup keeps original30s mount deadline")

        // Actual spool admission and predecessor retention; only eight inert bytes are written.
        let spool = VortXHLSSessionSpool(parentDirectory: URL(fileURLWithPath: CommandLine.arguments[1]),
            scavengeStaleSessions: false)!
        check(spool.setAuxiliaryBytes(1024 * mib), "physical accounting accepts exact1GiB cap without allocating it")
        let tiny = VortXHLSSessionSpool.SpillResource(key: .video(segmentID: 0), data: Data([0, 1, 2, 3]), durationMilliseconds: 4_000)
        check(!spool.setAuxiliaryBytes(1024 * mib + 1) && spool.spillOutcome([tiny]) == .pendingAdmission,
              "physical accounting rejects one byte over cap and defers new resource without eviction")
        _ = spool.setAuxiliaryBytes(0)
        check(spool.spill([tiny]), "bounded inert resource admitted after accounting release")
        _ = spool.recordPlaylistGeneration(playlistID: "media", resourceKeys: [.video(segmentID: 0)], now: 0)
        _ = spool.spill([.init(key: .video(segmentID: 1), data: Data([4, 5, 6, 7]), durationMilliseconds: 4_000)])
        _ = spool.recordPlaylistGeneration(playlistID: "media", resourceKeys: [.video(segmentID: 1)], now: 1)
        spool.collectExpired(now: 8.9)
        check(spool.contains(.video(segmentID: 0)), "published predecessor remains open through legal retention deadline")
        spool.collectExpired(now: 9.1)
        check(!spool.contains(.video(segmentID: 0)) && spool.contains(.video(segmentID: 1)),
              "only expired predecessor is reclaimed; current advertised resource stays durable")
        spool.invalidateSession(); spool.producerDidTerminate(); spool.listenerDidRetire()
        print("HLS startup reservation failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    #if STARTUP_RESERVATION
    private static func waitForPark(_ gate: VortXRemuxProducerLeadGate) {
        let deadline = Date(timeIntervalSinceNow: 1)
        while !gate.isParked && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    }
    #endif
}
