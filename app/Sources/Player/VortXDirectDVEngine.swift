import Foundation
import AVFoundation
import CoreMedia
import Libavformat
import Libavcodec
import Libavutil
#if canImport(UIKit)
import UIKit
#endif

// ATTRIBUTION (licence-relevant, do not strip):
// The renderer topology here (AVSampleBufferRenderSynchronizer driving an AVSampleBufferAudioRenderer and
// a display layer, fed via requestMediaDataWhenReady on serial queues) follows the pattern of
// kingslay/KSPlayer (GPL-3.0), Sources/KSPlayer/MEPlayer/AudioRendererPlayer.swift. What KSPlayer does
// NOT do, and what this lane adds, is feeding the VIDEO renderer COMPRESSED access units whose
// CMVideoFormatDescription carries the Dolby Vision configuration atom: KSPlayer decodes to pixel
// buffers first, which is precisely the step Nuvio's own DVRemuxer header calls out as losing the RPU
// ("anything FFmpeg decodes to pixels has already lost the RPU", prehakanson-art/NuvioTVAppleTV,
// GPL-3.0, NuvioTV/Player/DVRemuxer.swift). The demux thread's shape (interrupt cell, drain-in-order
// prescan, fail-soft P7 conversion) reuses THIS project's own VortXMKVRemuxStream internals. VortX is
// GPL-3.0; both referenced projects are GPL-3.0, so incorporation is licence-compatible.

/// The DIRECT Dolby Vision lane: FFmpeg demux to compressed CMSampleBuffers, enqueued on an
/// AVSampleBufferDisplayLayer + AVSampleBufferAudioRenderer under one AVSampleBufferRenderSynchronizer.
///
/// Why a third lane (owner mandate "if there is Dolby Vision, play Dolby Vision"):
///   - The remux lane reaches AVPlayer through a LOCAL HLS master, and a master carries declarations
///     (SUPPLEMENTAL-CODECS media-profile brands) CoreMedia cross-checks against the served init
///     segment; a disagreement is CoreMediaErrorDomain -12927 and DV silently degrades to HDR10.
///   - This lane has NO playlist and NO declaration: the Dolby Vision configuration rides inside the
///     CMVideoFormatDescription (hvcC + dvcC/dvvC sample-description extension atoms) and the RPU NALs
///     ride inside the enqueued access units, exactly as they left the source container. -12927 cannot
///     exist here by construction.
///   - AVPlayer keeps AirPlay / PiP / ABR, so this lane is ADDITIVE and flag-gated, never a replacement.
///     The tvOS chrome demotes direct -> remux(AVPlayer) -> libmpv, so a direct-lane failure loses
///     nothing that ships today.
///
/// What this lane preserves from the remux lane (deliberately, they beat rivals):
///   - Profile 7 -> 8.1 in-flight conversion (the SAME VortXMKVRemuxStream.convertPacketRPUToProfile81
///     libdovi path, fail-soft per access unit), gated on hardware tier (VortXDirectDVDeviceTier).
///   - RPU survival: video is never decoded in-process; access units are re-wrapped byte-for-byte.
///   - Atmos: E-AC-3 (JOC) is enqueued COMPRESSED, so its Atmos signalling reaches the system decoder.
final class VortXDirectDVPipeline {

    /// What the demux classified, delivered once before the first sample is enqueued. Everything the
    /// engine needs for the display-mode switch, the chrome's track list, and the stats overlay.
    struct Classified {
        var width = 0
        var height = 0
        var fps: Double = 0
        var durationSeconds: Double = 0
        var startSeconds: Double = 0
        var dvProfileSource = -1        // profile as read from the source (7 for a converted stream)
        var dvProfileOutput = -1        // profile as signalled to CoreMedia (8 for a converted P7)
        var convertingP7 = false
        var audioCodec = "?"
        var audioChannels = 0
        var audioLang = ""
        var audioTitle = ""
    }

    // Callbacks, all delivered on the MAIN queue. The engine niles itself out via `cancel()`, and every
    // delivery re-checks `cancelled` on main so nothing lands after teardown.
    var onClassified: ((Classified) -> Void)?
    var onFatal: ((String) -> Void)?
    var onEndOfStream: (() -> Void)?
    var onBuffering: ((Bool) -> Void)?

    private let input: String
    private let headers: [String: String]?
    private let convertP7Enabled: Bool
    private let displayLayer: AVSampleBufferDisplayLayer
    private let audioRenderer: AVSampleBufferAudioRenderer

    // Demux-thread state
    private var thread: Thread?
    private let interruptFlag: UnsafeMutablePointer<Int32>
    private let cancelLock = NSLock()
    private var cancelledStorage = false
    private var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelledStorage
    }

    // Bounded sample queues (lock-guarded; produced by the demux thread, consumed by the renderer
    // request queues). The demux thread BLOCKS when `queuedBytes` exceeds the tier budget, so memory is
    // capped by construction: the direct-lane answer to the remux window and to Nuvio's pacing knobs.
    private let queueLock = NSCondition()
    private var videoQueue: [CMSampleBuffer] = []
    private var audioQueue: [CMSampleBuffer] = []
    private var queuedBytes = 0
    private var generation = 0            // bumped by seek; in-flight packets of an older gen are dropped
    private var pendingSeekSeconds: Double?
    private var demuxFinished = false
    private var fatalDelivered = false
    private var bufferingSignalled = false
    private let byteBudget = VortXDirectDVDeviceTier.packetQueueByteBudget

    private let videoFeedQueue = DispatchQueue(label: "vortx.dvdirect.videofeed")
    private let audioFeedQueue = DispatchQueue(label: "vortx.dvdirect.audiofeed")

    init(input: String, headers: [String: String]?, convertP7Enabled: Bool,
         displayLayer: AVSampleBufferDisplayLayer, audioRenderer: AVSampleBufferAudioRenderer) {
        self.input = input
        self.headers = headers
        self.convertP7Enabled = convertP7Enabled
        self.displayLayer = displayLayer
        self.audioRenderer = audioRenderer
        interruptFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        interruptFlag.initialize(to: 0)
    }

    deinit {
        // The demux thread strong-captures self for the whole of run() (same crash-safety shape as
        // VortXMKVRemuxStream.start), so by the time deinit runs the C interrupt callback cannot fire.
        interruptFlag.deinitialize(count: 1)
        interruptFlag.deallocate()
    }

    // MARK: Control (any thread)

    func start() {
        let t = Thread { self.run() }   // strong capture on purpose; see deinit note
        t.name = "vortx.dvdirect"
        t.stackSize = 1 << 20
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func cancel() {
        cancelLock.lock(); cancelledStorage = true; cancelLock.unlock()
        interruptFlag.pointee = 1
        queueLock.lock()
        videoQueue.removeAll(); audioQueue.removeAll(); queuedBytes = 0
        queueLock.signal()
        queueLock.unlock()
        displayLayer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
    }

    /// Ask the demux thread to seek. The caller (engine, main) flushes the renderers and re-times the
    /// synchronizer itself; this only redirects the producer. Samples of the pre-seek generation still
    /// in flight are dropped by the generation check before they reach the queue.
    func requestSeek(to seconds: Double) {
        queueLock.lock()
        pendingSeekSeconds = max(0, seconds)
        generation += 1
        videoQueue.removeAll(); audioQueue.removeAll(); queuedBytes = 0
        demuxFinished = false
        queueLock.signal()
        queueLock.unlock()
    }

    /// True when the producer is done AND both queues have fully drained (used by the engine's EOF check).
    var isDrained: Bool {
        queueLock.lock(); defer { queueLock.unlock() }
        return demuxFinished && videoQueue.isEmpty && audioQueue.isEmpty
    }

    /// Live queue depth for the stats overlay.
    var queueDepth: (video: Int, audio: Int, bytes: Int) {
        queueLock.lock(); defer { queueLock.unlock() }
        return (videoQueue.count, audioQueue.count, queuedBytes)
    }

    /// Install the pull-driven feeders. Called once by the engine after the renderers joined the
    /// synchronizer. Each feeder pops from its queue while the renderer wants data; an underrun while
    /// the producer is still running surfaces as a buffering signal.
    func beginFeeding() {
        displayLayer.requestMediaDataWhenReady(on: videoFeedQueue) { [weak self] in
            guard let self else { return }
            self.feed(layerWants: true)
        }
        audioRenderer.requestMediaDataWhenReady(on: audioFeedQueue) { [weak self] in
            guard let self else { return }
            self.feed(layerWants: false)
        }
    }

    private func feed(layerWants video: Bool) {
        while !isCancelled {
            let target: any AVQueuedSampleBufferRendering = video ? displayLayer : audioRenderer
            guard target.isReadyForMoreMediaData else { return }
            queueLock.lock()
            let sample: CMSampleBuffer?
            if video {
                sample = videoQueue.isEmpty ? nil : videoQueue.removeFirst()
            } else {
                sample = audioQueue.isEmpty ? nil : audioQueue.removeFirst()
            }
            if let sample {
                queuedBytes -= CMSampleBufferGetTotalSampleSize(sample)
                if queuedBytes < 0 { queuedBytes = 0 }
                let recovered = bufferingSignalled && !videoQueue.isEmpty
                if recovered { bufferingSignalled = false }
                queueLock.signal()   // wake a producer blocked on the byte budget
                queueLock.unlock()
                if recovered { deliver { self.onBuffering?(false) } }
                target.enqueue(sample)
            } else {
                let underrun = !demuxFinished && video && !bufferingSignalled
                if underrun { bufferingSignalled = true }
                queueLock.unlock()
                if underrun { deliver { self.onBuffering?(true) } }
                return
            }
        }
    }

    private func deliver(_ block: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            block()
        }
    }

    private func fail(_ reason: String) {
        queueLock.lock()
        let first = !fatalDelivered
        fatalDelivered = true
        demuxFinished = true
        queueLock.unlock()
        guard first else { return }
        DiagnosticsLog.log("dv", "direct lane FAILED: \(reason)")
        deliver { self.onFatal?(reason) }
    }

    // MARK: Demux thread

    private func run() {
        // ---- Open input: same network posture as the remux lane (headers, timeouts, debrid resilience).
        var ifmt: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard ifmt != nil else { fail("avformat_alloc_context failed"); return }
        ifmt!.pointee.interrupt_callback.callback = vortxDirectDVInterruptCallback
        ifmt!.pointee.interrupt_callback.opaque = UnsafeMutableRawPointer(interruptFlag)

        var openOpts: OpaquePointer?
        if let headers, !headers.isEmpty {
            let joined = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
            av_dict_set(&openOpts, "headers", joined, 0)
        }
        av_dict_set(&openOpts, "rw_timeout", "10000000", 0)
        av_dict_set(&openOpts, "probesize", "5000000", 0)
        av_dict_set(&openOpts, "analyzeduration", "2000000", 0)
        VortXMKVRemuxStream.applyDebridHTTPResilience(&openOpts)
        let openRc = avformat_open_input(&ifmt, input, nil, &openOpts)
        av_dict_free(&openOpts)
        guard openRc == 0, let inCtx = ifmt else { fail("source open failed (\(openRc))"); return }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = inCtx; avformat_close_input(&p) }
        let siRc = avformat_find_stream_info(inCtx, nil)
        guard siRc >= 0 else { fail("source probe failed (\(siRc))"); return }

        // ---- Stream selection: first real HEVC video; best passthrough audio (EAC3 > AC3 > AAC).
        let nb = Int(inCtx.pointee.nb_streams)
        var videoIn = -1
        var audioIn = -1
        var audioKind: VortXDirectDVFormat.PassthroughAudio?
        var audioScore = -1
        var audioSeen: [String] = []
        for i in 0..<nb {
            guard let s = inCtx.pointee.streams[i], let par = s.pointee.codecpar else { continue }
            if par.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
               (s.pointee.disposition & vortxAVDispositionAttachedPic) == 0,
               videoIn < 0, par.pointee.codec_id == AV_CODEC_ID_HEVC {
                videoIn = i
            } else if par.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                let name = avcodec_get_name(par.pointee.codec_id).map { String(cString: $0) } ?? "?"
                audioSeen.append(name)
                guard let kind = VortXDirectDVFormat.PassthroughAudio(codecID: par.pointee.codec_id) else { continue }
                if kind.score > audioScore {
                    audioScore = kind.score
                    audioIn = i
                    audioKind = kind
                }
            }
        }
        guard videoIn >= 0, let videoStream = inCtx.pointee.streams[videoIn],
              let videoPar = videoStream.pointee.codecpar else {
            fail("no HEVC video stream"); return
        }
        let nalLengthSize = VortXMKVRemuxStream.hevcNalLengthSize(videoPar)

        // ---- Dolby Vision classification: container DOVI config first, in-band RPU probe second
        // (drain-in-order, seek-free: the probed packets feed the queue afterwards, nothing is re-read).
        var dovi = VortXDirectDVFormat.doviConfig(from: videoPar)
        var prebuffered: [UnsafeMutablePointer<AVPacket>] = []
        defer { for p in prebuffered { var pp: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&pp) } }
        if dovi == nil {
            let maxScan = 240
            var scanned = 0
            while scanned < maxScan, !isCancelled {
                guard let p = av_packet_alloc() else { break }
                if av_read_frame(inCtx, p) < 0 { var pp: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&pp); break }
                scanned += 1
                prebuffered.append(p)
                if Int(p.pointee.stream_index) == videoIn {
                    let prof = VortXMKVRemuxStream.inBandDoViProfile(p, nalLengthSize: nalLengthSize)
                    if prof >= 0 {
                        let fps = Self.frameRate(videoStream)
                        var blCompat = prof == 5 ? 0 : 1
                        if prof != 5, videoPar.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67 { blCompat = 4 }
                        dovi = VortXDirectDVFormat.DoViConfig(
                            profile: prof,
                            level: Int(VortXMKVRemuxStream.doViLevel(width: Int(videoPar.pointee.width),
                                                                     height: Int(videoPar.pointee.height),
                                                                     fps: fps)),
                            rpuPresent: true, elPresent: false, blPresent: true,
                            blSignalCompatibilityId: blCompat)
                        VXProbe.log("dv", "direct: in-band RPU classified dvProfile=\(prof)")
                    }
                    break
                }
            }
        }
        guard var doviConfig = dovi else {
            fail("source has no Dolby Vision configuration (label mismatch)"); return
        }
        let sourceProfile = doviConfig.profile
        let convertP7 = sourceProfile == 7
        if convertP7, !convertP7Enabled {
            fail("Dolby Vision profile 7 conversion is disabled on this hardware tier"); return
        }
        guard sourceProfile == 5 || sourceProfile == 8 || convertP7 else {
            fail("Dolby Vision profile \(sourceProfile) is not decodable on this pipeline"); return
        }
        if convertP7 {
            // The per-packet RPU rewrite emits 8.1; the format description must agree (single layer,
            // HDR10-compatible base), mirroring the remux lane's dvvC relabel.
            doviConfig.profile = 8
            doviConfig.elPresent = false
            doviConfig.rpuPresent = true
            doviConfig.blPresent = true
            doviConfig.blSignalCompatibilityId = 1
        }

        guard audioIn >= 0, let audioKind,
              let audioStream = inCtx.pointee.streams[audioIn],
              let audioPar = audioStream.pointee.codecpar else {
            // The remux lane can TRANSCODE TrueHD/DTS; this lane deliberately does not duplicate that
            // machinery, so it fails fast and the chrome demotes to the remux lane.
            fail("no passthrough-capable audio track (source audio: \(audioSeen.joined(separator: ",")))"); return
        }

        // ---- Format descriptions.
        guard let videoFormat = VortXDirectDVFormat.videoFormatDescription(par: videoPar, dovi: doviConfig) else {
            fail("video format description failed (hvcC unusable; remux lane can repair)"); return
        }
        guard let audioFormat = VortXDirectDVFormat.audioFormatDescription(par: audioPar, kind: audioKind) else {
            fail("audio format description failed"); return
        }

        // ---- Classify callback (display-mode switch + chrome metadata) BEFORE the first sample.
        var classified = Classified()
        classified.width = Int(videoPar.pointee.width)
        classified.height = Int(videoPar.pointee.height)
        classified.fps = Self.frameRate(videoStream)
        if inCtx.pointee.duration > 0 {
            classified.durationSeconds = Double(inCtx.pointee.duration) / Double(vortxAVTimeBase)
        }
        if inCtx.pointee.start_time > 0, inCtx.pointee.start_time != vortxAVNoPtsValue {
            classified.startSeconds = Double(inCtx.pointee.start_time) / Double(vortxAVTimeBase)
        }
        classified.dvProfileSource = sourceProfile
        classified.dvProfileOutput = doviConfig.profile
        classified.convertingP7 = convertP7
        classified.audioCodec = avcodec_get_name(audioPar.pointee.codec_id).map { String(cString: $0) } ?? "?"
        classified.audioChannels = Int(audioPar.pointee.ch_layout.nb_channels)
        if let langEntry = av_dict_get(audioStream.pointee.metadata, "language", nil, 0),
           let v = langEntry.pointee.value { classified.audioLang = String(cString: v) }
        if let titleEntry = av_dict_get(audioStream.pointee.metadata, "title", nil, 0),
           let v = titleEntry.pointee.value { classified.audioTitle = String(cString: v) }
        let eac3Atmos = audioPar.pointee.codec_id == AV_CODEC_ID_EAC3 && audioPar.pointee.profile == 30
        VXProbe.log("dv", "direct classify \(classified.width)x\(classified.height) dvProfile=\(sourceProfile)"
            + (convertP7 ? "->8.1" : "") + " audio=\(classified.audioCodec)/\(classified.audioChannels)ch joc=\(eac3Atmos)"
            + " fps=\(String(format: "%.3f", classified.fps)) dur=\(String(format: "%.1f", classified.durationSeconds))")
        DiagnosticsLog.log("dv", "direct lane mounted: dvProfile=\(sourceProfile)\(convertP7 ? " (converting to 8.1)" : "") "
            + "\(classified.width)x\(classified.height) audio=\(classified.audioCodec) queueBudget=\(byteBudget >> 20)MiB")
        let classifiedCopy = classified
        deliver { self.onClassified?(classifiedCopy) }

        // ---- Packet pump.
        let videoTB = videoStream.pointee.time_base
        let audioTB = audioStream.pointee.time_base
        let frameDuration = classified.fps > 0 ? 1.0 / classified.fps : 1.0 / 24.0
        var rpuStats = VortXMKVRemuxStream.RPUConvStats()
        var awaitingSync = true          // first video sample enqueued must be a keyframe
        var readRetries = 0
        let maxReadRetries = 12

        func currentGeneration() -> Int {
            queueLock.lock(); defer { queueLock.unlock() }
            return generation
        }

        // Process one packet into its queue. Returns false only on cancel.
        func processPacket(_ pkt: UnsafeMutablePointer<AVPacket>, gen: Int) -> Bool {
            let idx = Int(pkt.pointee.stream_index)
            if idx == videoIn {
                if convertP7 {
                    VortXMKVRemuxStream.convertPacketRPUToProfile81(pkt, nalLengthSize: nalLengthSize, stats: &rpuStats)
                }
                let isKey = (pkt.pointee.flags & vortxAVPktFlagKey) != 0
                if awaitingSync, !isKey { return true }   // drop pre-keyframe leftovers after open/seek
                awaitingSync = false
                guard let sample = Self.videoSampleBuffer(from: pkt, format: videoFormat, timeBase: videoTB,
                                                          fallbackDuration: frameDuration, isKey: isKey) else { return true }
                return enqueue(sample, video: true, gen: gen)
            } else if idx == audioIn {
                guard let sample = Self.audioSampleBuffer(from: pkt, format: audioFormat, timeBase: audioTB) else { return true }
                return enqueue(sample, video: false, gen: gen)
            }
            return true
        }

        // Drain the prescan packets first (in order), then the live read loop.
        var gen = currentGeneration()
        for p in prebuffered {
            if isCancelled { return }
            _ = processPacket(p, gen: gen)
            var pp: UnsafeMutablePointer<AVPacket>? = p
            av_packet_free(&pp)
        }
        prebuffered.removeAll()

        guard let pkt = av_packet_alloc() else { fail("packet alloc failed"); return }
        var freePkt: UnsafeMutablePointer<AVPacket>? = pkt
        defer { av_packet_free(&freePkt) }

        while !isCancelled {
            // Seek requested by the engine: run it here, on the thread that owns the contexts.
            queueLock.lock()
            let seekTarget = pendingSeekSeconds
            pendingSeekSeconds = nil
            queueLock.unlock()
            if let seekTarget {
                let ts = Int64(seekTarget * Double(vortxAVTimeBase))
                let rc = av_seek_frame(inCtx, -1, ts, vortxAVSeekFlagBackward)
                if rc < 0 {
                    VXProbe.log("dv", "direct seek av_seek_frame rc=\(rc) target=\(String(format: "%.1f", seekTarget)) (continuing)")
                }
                awaitingSync = true
                gen = currentGeneration()
            }

            let rf = av_read_frame(inCtx, pkt)
            if rf < 0 {
                if isCancelled { return }
                if rf == vortxAVErrorEOF {
                    queueLock.lock(); demuxFinished = true; queueLock.unlock()
                    if convertP7 {
                        VXProbe.log("dv", "direct P7 convert exit: converted=\(rpuStats.rpuConverted) fellBack=\(rpuStats.rpuFellBack) elDropped=\(rpuStats.elDropped) pktBailed=\(rpuStats.pktBailed)")
                    }
                    deliver { self.onEndOfStream?() }
                    // Stay alive for a post-EOF backward seek (replay/scrub): wait until cancel or seek.
                    queueLock.lock()
                    while !isCancelled, pendingSeekSeconds == nil { queueLock.wait() }
                    queueLock.unlock()
                    if isCancelled { return }
                    continue
                }
                readRetries += 1
                if readRetries <= maxReadRetries {
                    VXProbe.log("dv", "direct mid-stream read rc=\(rf), retry \(readRetries)/\(maxReadRetries)")
                    continue
                }
                fail("source read failed mid-stream (rc=\(rf)) after \(maxReadRetries) retries")
                return
            }
            readRetries = 0
            let ok = processPacket(pkt, gen: gen)
            av_packet_unref(pkt)
            if !ok { return }
        }
    }

    /// Append a sample to its queue, blocking while the byte budget is exhausted (the direct lane's
    /// built-in pacing). Drops the sample when a seek advanced the generation. Returns false on cancel.
    private func enqueue(_ sample: CMSampleBuffer, video: Bool, gen: Int) -> Bool {
        queueLock.lock()
        while queuedBytes >= byteBudget, !cancelledUnderLock(), pendingSeekSeconds == nil, generation == gen {
            queueLock.wait()
        }
        guard !cancelledUnderLock() else { queueLock.unlock(); return false }
        guard generation == gen, pendingSeekSeconds == nil else { queueLock.unlock(); return true }
        if video { videoQueue.append(sample) } else { audioQueue.append(sample) }
        queuedBytes += CMSampleBufferGetTotalSampleSize(sample)
        queueLock.unlock()
        return true
    }

    private func cancelledUnderLock() -> Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelledStorage
    }

    // MARK: Sample-buffer construction (demux thread)

    private static func time(of value: Int64, _ tb: AVRational) -> CMTime {
        guard value != vortxAVNoPtsValue else { return .invalid }
        let q = tb.den != 0 ? Double(tb.num) / Double(tb.den) : 0
        return CMTime(seconds: Double(value) * q, preferredTimescale: 90000)
    }

    static func videoSampleBuffer(from pkt: UnsafeMutablePointer<AVPacket>,
                                  format: CMVideoFormatDescription,
                                  timeBase: AVRational,
                                  fallbackDuration: Double,
                                  isKey: Bool) -> CMSampleBuffer? {
        guard let data = pkt.pointee.data, pkt.pointee.size > 0 else { return nil }
        let size = Int(pkt.pointee.size)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: size, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: size,
                                                 flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let blockBuffer = block,
              CMBlockBufferReplaceDataBytes(with: data, blockBuffer: blockBuffer,
                                            offsetIntoDestination: 0, dataLength: size) == kCMBlockBufferNoErr
        else { return nil }

        let duration = pkt.pointee.duration > 0
            ? time(of: pkt.pointee.duration, timeBase)
            : CMTime(seconds: fallbackDuration, preferredTimescale: 90000)
        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: time(of: pkt.pointee.pts, timeBase),
                                        decodeTimeStamp: time(of: pkt.pointee.dts, timeBase))
        var sampleSize = size
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                                        formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sample) == noErr,
              let out = sample else { return nil }
        if !isKey,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(out, createIfNecessary: true) as? [NSMutableDictionary],
           let dict = attachments.first {
            dict[kCMSampleAttachmentKey_NotSync] = true
            dict[kCMSampleAttachmentKey_DependsOnOthers] = true
        }
        return out
    }

    static func audioSampleBuffer(from pkt: UnsafeMutablePointer<AVPacket>,
                                  format: CMAudioFormatDescription,
                                  timeBase: AVRational) -> CMSampleBuffer? {
        guard let data = pkt.pointee.data, pkt.pointee.size > 0 else { return nil }
        let size = Int(pkt.pointee.size)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: size, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: size,
                                                 flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let blockBuffer = block,
              CMBlockBufferReplaceDataBytes(with: data, blockBuffer: blockBuffer,
                                            offsetIntoDestination: 0, dataLength: size) == kCMBlockBufferNoErr
        else { return nil }
        var aspd = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                mDataByteSize: UInt32(size))
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, presentationTimeStamp: time(of: pkt.pointee.pts, timeBase),
            packetDescriptions: &aspd, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    private static func frameRate(_ stream: UnsafeMutablePointer<AVStream>) -> Double {
        let avg = stream.pointee.avg_frame_rate
        if avg.num > 0, avg.den > 0 { return Double(avg.num) / Double(avg.den) }
        let r = stream.pointee.r_frame_rate
        if r.num > 0, r.den > 0 { return Double(r.num) / Double(r.den) }
        return 0
    }
}

// FFmpeg #define macros the Swift importer does not surface (same shim style as VortXMKVRemuxStream).
private let vortxAVErrorEOF: Int32 = -541478725            // AVERROR_EOF = FFERRTAG('E','O','F',' ')
private let vortxAVTimeBase: Int64 = 1_000_000             // AV_TIME_BASE (microseconds)
private let vortxAVSeekFlagBackward: Int32 = 1             // AVSEEK_FLAG_BACKWARD
private let vortxAVPktFlagKey: Int32 = 0x0001              // AV_PKT_FLAG_KEY
private let vortxAVDispositionAttachedPic: Int32 = 0x0400  // AV_DISPOSITION_ATTACHED_PIC
private let vortxAVNoPtsValue: Int64 = Int64.min           // AV_NOPTS_VALUE

/// C-convention interrupt callback for the direct lane (mirrors the remux lane's cell shape).
private func vortxDirectDVInterruptCallback(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    return opaque.assumingMemoryBound(to: Int32.self).pointee
}
