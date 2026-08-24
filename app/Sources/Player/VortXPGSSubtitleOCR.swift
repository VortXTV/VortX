import Foundation
import CoreGraphics
import Libavcodec
import Libavutil
import Vision

/// The classification of one `VortXPGSSubtitleOCR.prepare` call, surfaced so the caller can tell a BENIGN
/// non-cue apart from a genuine rejection. About half of PGS packets are HDMV clear-screen/erase compositions
/// (`num_rects == 0`) or Vision-empty OCR outcomes (bitmap fine, no text); counting those as rejections made
/// the reject tally read 50-64% when the real failure rate is ~0.08%. `prepare` already computes the internal
/// empty/dropped/rejected stats; this just lets the caller route them to honest counters.
enum PGSOCRPrepareOutcome {
    /// A cue was decoded and is ready to submit.
    case prepared(PGSOCRWorkItem)
    /// No rectangles / no recognizable text (clear-screen, erase, or empty OCR). Normal PGS traffic, NOT a failure.
    case empty
    /// Dropped under worker backpressure before immutable allocation / submission. Benign, NOT a failure.
    case dropped
    /// A genuine decode / policy / timing rejection.
    case rejected
}

/// Turns HDMV PGS bitmap subtitles into text cues without running Vision on the remux producer.
///
/// FFmpeg subtitle decoding remains producer-confined. `prepare` copies admitted bitmap planes into immutable
/// values before AVSubtitle is freed. Only those values cross to one bounded OCR worker. Submission, deadline
/// handling, cancellation, and teardown never wait for Vision.
final class VortXPGSSubtitleOCR {

    /// How many PGS streams one session may decode + OCR at once. Previously 4, which disabled every other
    /// built-in PGS track with the "OCR track limit" reason on subtitle-heavy remuxes (the "99% of built-in
    /// subs don't work in AVPlayer" report). The cap exists only to bound the serial Vision worker's
    /// throughput; raising it alongside the `.fast` recognition level keeps the same bounded queue while
    /// letting the worker serve far more tracks. Memory stays bounded by PGSOCRPolicy regardless of this value.
    static let maximumStreams = 8
    static let minimumRectEdge = 8

    private let epoch: UInt64
    private let worker: PGSOCRWorker
    private let statsLock = NSLock()
    /// Decoder contexts are created, used, and closed only by the remux producer thread.
    private var decoders: [Int: UnsafeMutablePointer<AVCodecContext>] = [:]
    private var admitted: Set<Int> = []
    private var refused: Set<Int> = []
    private var preparedPackets = 0
    private var emptyPackets = 0
    private var rejectedPackets = 0
    private var droppedPackets = 0

    init(epoch: UInt64,
         completion: @escaping @Sendable (PGSOCRCompletion) -> Void) {
        self.epoch = epoch
        worker = PGSOCRWorker(
            recognizer: { item, context in
                Self.recognise(item: item, context: context)
            },
            completion: completion)
        worker.start()
    }

    deinit {
        _ = worker.invalidateAndStop()
    }

    func admits(stream index: Int) -> Bool {
        statsLock.lock(); defer { statsLock.unlock() }
        if admitted.contains(index) { return true }
        if refused.contains(index) { return false }
        guard admitted.count < Self.maximumStreams else {
            refused.insert(index)
            return false
        }
        admitted.insert(index)
        return true
    }

    /// Decode one packet on the remux thread and copy its bitmap data into a worker-safe value.
    ///
    /// The outcome is fail-open. Empty clear-screen compositions, malformed rectangles, queue pressure, and
    /// refused streams affect only that one subtitle packet; the classification lets the caller tally a benign
    /// `.empty` / `.dropped` apart from a genuine `.rejected` instead of treating every non-cue as a rejection.
    func prepare(packet: UnsafeMutablePointer<AVPacket>,
                 parameters: UnsafePointer<AVCodecParameters>,
                 streamIndex: Int,
                 renditionID: Int,
                 token: UInt64,
                 startSeconds: Double,
                 durationSeconds: Double) -> PGSOCRPrepareOutcome {
        guard admits(stream: streamIndex),
              let context = decoder(for: streamIndex, parameters: parameters) else {
            recordRejected()
            return .rejected
        }

        var subtitle = AVSubtitle()
        var got: Int32 = 0
        let rc = avcodec_decode_subtitle2(context, &subtitle, &got, packet)
        defer { avsubtitle_free(&subtitle) }
        guard rc >= 0, got != 0 else {
            recordRejected()
            return .rejected
        }
        let rectangleCount = Int(subtitle.num_rects)
        guard rectangleCount > 0 else {
            recordEmpty()
            return .empty
        }
        guard PGSOCRPolicy.acceptsPacketRectangleCount(rectangleCount),
              let rects = subtitle.rects else {
            recordRejected()
            return .rejected
        }
        // Feed every admitted packet through the stateful FFmpeg decoder even under worker pressure. PGS
        // object and palette definitions can span packets, so dropping input before decode can corrupt every
        // later cue. Backpressure starts here, before immutable bitmap allocation and Vision submission.
        guard worker.canPrepare else {
            recordDropped()
            return .dropped
        }

        var bitmaps: [PGSOCRBitmap] = []
        bitmaps.reserveCapacity(rectangleCount)
        var copiedBytes = 0
        for index in 0..<rectangleCount {
            guard let rect = rects[index],
                  let nextBytes = Self.bitmapStorageByteCount(from: rect.pointee) else { continue }
            guard PGSOCRPolicy.canAppendBitmap(
                existingCount: bitmaps.count,
                existingBytes: copiedBytes,
                nextBytes: nextBytes) else {
                recordRejected()
                return .rejected
            }
            guard let bitmap = Self.copyBitmap(from: rect.pointee) else { continue }
            bitmaps.append(bitmap)
            copiedBytes += nextBytes
        }
        guard !bitmaps.isEmpty else {
            recordEmpty()
            return .empty
        }
        guard let timing = PGSOCRPolicy.cueTiming(
            packetStartSeconds: startSeconds,
            packetDurationSeconds: durationSeconds,
            displayStartMilliseconds: subtitle.start_display_time,
            displayEndMilliseconds: subtitle.end_display_time) else {
            recordRejected()
            return .rejected
        }

        statsLock.lock()
        preparedPackets += 1
        statsLock.unlock()
        return .prepared(PGSOCRWorkItem(
            token: token,
            epoch: epoch,
            sourceIndex: streamIndex,
            renditionID: renditionID,
            startSeconds: timing.start,
            durationSeconds: timing.duration,
            deadlineUptime: ProcessInfo.processInfo.systemUptime
                + PGSOCRPolicy.recognitionDeadlineSeconds,
            bitmaps: bitmaps))
    }

    func submit(_ item: PGSOCRWorkItem) -> PGSOCRSubmission {
        let result = worker.submit(item)
        statsLock.lock()
        droppedPackets += result.droppedTokens.count + (result.accepted ? 0 : 1)
        statsLock.unlock()
        return result
    }

    func finishAdmissionAndDrain() {
        worker.finishAdmissionAndDrain()
    }

    func invalidateAndStop() -> [UInt64] {
        let dropped = worker.invalidateAndStop()
        statsLock.lock()
        droppedPackets += dropped.count
        statsLock.unlock()
        return dropped
    }

    var summary: String {
        let queue = worker.snapshot
        statsLock.lock()
        let streams = admitted.count
        let refusedCount = refused.count
        let prepared = preparedPackets
        let empty = emptyPackets
        let rejected = rejectedPackets
        let dropped = droppedPackets
        statsLock.unlock()
        return "pgs-ocr streams=\(streams) refused=\(refusedCount) "
            + "prepared=\(prepared) empty=\(empty) rejected=\(rejected) "
            + "dropped=\(dropped) queued=\(queue.queuedItems)/\(queue.queuedBytes)B "
            + "inflight=\(queue.inFlightItems)/\(queue.inFlightBytes)B"
    }

    private func recordRejected() {
        statsLock.lock()
        rejectedPackets += 1
        statsLock.unlock()
    }

    private func recordEmpty() {
        statsLock.lock()
        emptyPackets += 1
        statsLock.unlock()
    }

    private func recordDropped() {
        statsLock.lock()
        droppedPackets += 1
        statsLock.unlock()
    }

    // MARK: - Producer-confined FFmpeg decode

    private func decoder(for index: Int,
                         parameters: UnsafePointer<AVCodecParameters>) -> UnsafeMutablePointer<AVCodecContext>? {
        if let existing = decoders[index] { return existing }
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id),
              let context = avcodec_alloc_context3(codec) else { return nil }
        var optionalContext: UnsafeMutablePointer<AVCodecContext>? = context
        guard avcodec_parameters_to_context(context, parameters) >= 0,
              avcodec_open2(context, codec, nil) >= 0 else {
            avcodec_free_context(&optionalContext)
            return nil
        }
        decoders[index] = context
        return context
    }

    /// Must be called by the remux producer at its terminal edge. FFmpeg decoder contexts never cross to the
    /// worker, deadline, or server threads.
    func closeProducerResources() {
        for (_, context) in decoders {
            var optionalContext: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&optionalContext)
        }
        decoders.removeAll()
    }

    private static func bitmapStorageByteCount(from rect: AVSubtitleRect) -> Int? {
        let width = Int(rect.w)
        let height = Int(rect.h)
        guard width >= minimumRectEdge,
              height >= minimumRectEdge,
              width <= PGSOCRPolicy.maximumBitmapEdge,
              height <= PGSOCRPolicy.maximumBitmapEdge else { return nil }
        let stride = Int(rect.linesize.0)
        guard stride >= width else { return nil }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow,
              pixelCount > 0,
              pixelCount <= PGSOCRPolicy.maximumBitmapPixels else { return nil }
        let (storageBytes, storageOverflow) = pixelCount.addingReportingOverflow(256 * 4)
        guard !storageOverflow else { return nil }
        return storageBytes
    }

    private static func copyBitmap(from rect: AVSubtitleRect) -> PGSOCRBitmap? {
        guard let storageBytes = bitmapStorageByteCount(from: rect),
              let indices = rect.data.0,
              let palette = rect.data.1 else { return nil }
        let width = Int(rect.w)
        let height = Int(rect.h)
        let stride = Int(rect.linesize.0)
        let pixelCount = storageBytes - (256 * 4)

        var packed = Data(count: pixelCount)
        let copied = packed.withUnsafeMutableBytes { raw -> Bool in
            guard let destination = raw.baseAddress else { return false }
            for row in 0..<height {
                destination.advanced(by: row * width)
                    .copyMemory(from: indices.advanced(by: row * stride), byteCount: width)
            }
            return true
        }
        guard copied else { return nil }
        return PGSOCRBitmap(
            width: width,
            height: height,
            indices: packed,
            paletteBGRA: Data(bytes: palette, count: 256 * 4))
    }

    // MARK: - Worker-only image conversion and Vision

    private final class RequestCancellationBox: @unchecked Sendable {
        let request: VNRequest
        init(_ request: VNRequest) { self.request = request }
    }

    private static func recognise(item: PGSOCRWorkItem,
                                  context: PGSOCRRecognitionContext) -> PGSOCRRecognizerResult {
        var lines: [String] = []
        for bitmap in item.bitmaps {
            if context.shouldStop { return .failed }
            guard let image = image(from: bitmap) else { continue }
            let request = VNRecognizeTextRequest()
            // .fast, not .accurate: subtitle bitmaps are clean, high-contrast text, and .fast recognises it
            // ~3-5x quicker on Apple TV, which is what lets one serial worker serve maximumStreams tracks at
            // once without dropping cues. A rare misread of a stylized glyph is far cheaper than a missing line.
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.15
            let cancellationBox = RequestCancellationBox(request)
            context.registerCancellation { cancellationBox.request.cancel() }

            var requestFailed = false
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                requestFailed = true
            }
            context.clearCancellation()
            if requestFailed {
                if context.shouldStop { return .failed }
                continue
            }
            if context.shouldStop { return .failed }
            guard let observations = request.results else { continue }
            let recognised = observations.compactMap { $0.topCandidates(1).first?.string }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            lines.append(contentsOf: recognised)
        }
        guard !lines.isEmpty else { return .empty }
        return .text(lines.joined(separator: "\n"))
    }

    private static func image(from bitmap: PGSOCRBitmap) -> CGImage? {
        let (pixelCount, overflow) = bitmap.width.multipliedReportingOverflow(by: bitmap.height)
        guard !overflow,
              bitmap.width >= minimumRectEdge,
              bitmap.height >= minimumRectEdge,
              pixelCount == bitmap.indices.count,
              bitmap.paletteBGRA.count == 256 * 4 else { return nil }

        let indices = [UInt8](bitmap.indices)
        let palette = [UInt8](bitmap.paletteBGRA)
        var pixels = [UInt8](repeating: 255, count: pixelCount)
        for offset in 0..<pixelCount {
            let paletteOffset = Int(indices[offset]) * 4
            let blue = Double(palette[paletteOffset])
            let green = Double(palette[paletteOffset + 1])
            let red = Double(palette[paletteOffset + 2])
            let alpha = Double(palette[paletteOffset + 3]) / 255.0
            let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
            let composited = luminance * alpha + 255.0 * (1.0 - alpha)
            pixels[offset] = UInt8(max(0, min(255, 255.0 - composited * alpha)))
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: bitmap.width,
            height: bitmap.height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: bitmap.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)
    }
}
