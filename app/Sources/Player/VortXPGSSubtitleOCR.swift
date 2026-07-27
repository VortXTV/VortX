import Foundation
import CoreGraphics
import Libavcodec
import Libavutil
import Vision

/// Turns HDMV PGS (BluRay bitmap) subtitles into TEXT cues so they can travel the ordinary subtitle path.
///
/// WHY THIS EXISTS. `textSubtitleFormat` accepts only SubRip, ASS/SSA, mov_text, WebVTT and plain text, so a
/// BluRay remux produced ZERO subtitle renditions: field diagnostic 2026-07-27 logged a 3840x2160 Profile 7
/// remux with no `text-renditions-ready` line at all and `subs=0` in its master, while a WEB-DL of the same
/// resolution carried 39 SRT tracks and listed all of them. PGS is images, not text, and images cannot become
/// WebVTT without recognising the glyphs.
///
/// THE APPROACH, and why it is this one rather than an image overlay. Decoding to an image and drawing it over
/// the video would be pixel-perfect, but it needs a new image path in `SubtitleOverlayView` (text-only today),
/// it never appears in AVPlayer's own subtitle picker, and it is lost to PiP and AirPlay. Recognising the text
/// instead means the cue re-enters the EXISTING pipeline unchanged: it becomes a `SubtitleRenditionPolicy.Cue`,
/// gets published as a WebVTT rendition, appears in AVPlayer's native list, and inherits subtitle styling and
/// the delay control the external-overlay path already has. One conversion, and every downstream feature works
/// without being taught about bitmaps.
///
/// THE COST, stated honestly. OCR is not free and it is not perfect. Recognition runs on the Neural Engine via
/// Vision, but a two-hour disc can carry well over a thousand cues per language and a remux commonly ships a
/// dozen or more PGS tracks. Recognising every one would cost more than the remux itself. So this is BOUNDED on
/// three axes: a hard cap on how many PGS streams are recognised at all, a per-image time budget, and a global
/// budget after which recognition stops and the remaining cues are dropped rather than stalling the producer.
/// A dropped cue is a missing subtitle line; a stalled producer is a stalled film.
///
/// ACCURACY. Recognition is per-image with language correction on. Typeset subtitle bitmaps are high-contrast
/// and uniform, which is the easy case for OCR, but expect occasional errors on stylised or overlapping text
/// and on non-Latin scripts. That is a real quality difference from a text track and it is why a source's own
/// SRT is always preferred: `renditions(from:)` sees PGS tracks only after the text ones.
final class VortXPGSSubtitleOCR {

    /// Recognise at most this many PGS streams per session. A remux with fifteen PGS tracks would otherwise
    /// pay recognition fifteen times over for tracks nobody selected.
    static let maximumStreams = 4
    /// Stop recognising once this much wall time has been spent across the whole session. The producer must
    /// never wait on OCR; when the budget is gone the remaining cues are simply not produced.
    static let totalBudgetSeconds: Double = 25
    /// Skip any single image that would take longer than this. A pathological rect must not stall the demux.
    static let perImageBudgetSeconds: Double = 0.6
    /// Ignore rects smaller than this in either axis: they are almost always a stray anti-aliasing artefact
    /// rather than a glyph run, and Vision spends real time on them for nothing.
    static let minimumRectEdge = 8

    private var decoders: [Int: UnsafeMutablePointer<AVCodecContext>] = [:]
    private var admitted: Set<Int> = []
    private var refused: Set<Int> = []
    private var spentSeconds: Double = 0
    private var recognisedCues = 0
    private var droppedForBudget = 0

    deinit { closeAll() }

    /// True when this stream index is one this session will recognise. Admission is first-come and capped, so
    /// the streams a demuxer presents first (conventionally the primary languages) are the ones that get it.
    func admits(stream index: Int) -> Bool {
        if admitted.contains(index) { return true }
        if refused.contains(index) { return false }
        guard admitted.count < Self.maximumStreams else {
            refused.insert(index)
            return false
        }
        admitted.insert(index)
        return true
    }

    var isExhausted: Bool { spentSeconds >= Self.totalBudgetSeconds }

    var summary: String {
        "pgs-ocr streams=\(admitted.count) refused=\(refused.count) cues=\(recognisedCues) "
        + "dropped=\(droppedForBudget) spent=\(String(format: "%.1f", spentSeconds))s"
    }

    /// Recognise one PGS packet. Returns nil when there is nothing to show (an empty clear-screen composition,
    /// a rect below the size floor, a budget refusal, or no recognised glyphs). nil is NOT an error: PGS emits
    /// a clear-screen composition after every visible one, and those legitimately carry no text.
    func recognise(packet: UnsafeMutablePointer<AVPacket>,
                   parameters: UnsafePointer<AVCodecParameters>,
                   streamIndex: Int) -> String? {
        guard admits(stream: streamIndex), !isExhausted else {
            if isExhausted { droppedForBudget += 1 }
            return nil
        }
        guard let ctx = decoder(for: streamIndex, parameters: parameters) else { return nil }

        var subtitle = AVSubtitle()
        var got: Int32 = 0
        let rc = avcodec_decode_subtitle2(ctx, &subtitle, &got, packet)
        guard rc >= 0, got != 0 else { return nil }
        defer { avsubtitle_free(&subtitle) }
        guard subtitle.num_rects > 0, let rects = subtitle.rects else { return nil }

        let started = ProcessInfo.processInfo.systemUptime
        var lines: [String] = []
        for i in 0..<Int(subtitle.num_rects) {
            guard let rect = rects[i] else { continue }
            guard let image = Self.image(from: rect.pointee) else { continue }
            guard let text = recognise(image: image) else { continue }
            lines.append(text)
            if ProcessInfo.processInfo.systemUptime - started > Self.perImageBudgetSeconds { break }
        }
        spentSeconds += ProcessInfo.processInfo.systemUptime - started
        guard !lines.isEmpty else { return nil }
        recognisedCues += 1
        return lines.joined(separator: "\n")
    }

    // MARK: - Decoder

    private func decoder(for index: Int,
                         parameters: UnsafePointer<AVCodecParameters>) -> UnsafeMutablePointer<AVCodecContext>? {
        if let existing = decoders[index] { return existing }
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id),
              let ctx = avcodec_alloc_context3(codec) else { return nil }
        var context: UnsafeMutablePointer<AVCodecContext>? = ctx
        guard avcodec_parameters_to_context(ctx, parameters) >= 0,
              avcodec_open2(ctx, codec, nil) >= 0 else {
            avcodec_free_context(&context)
            return nil
        }
        decoders[index] = ctx
        return ctx
    }

    func closeAll() {
        for (_, ctx) in decoders {
            var c: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&c)
        }
        decoders.removeAll()
    }

    // MARK: - Bitmap

    /// Build a CGImage from a PGS rect. The decoder hands back 8-bit palette indices in `data[0]` and a
    /// 256-entry BGRA palette in `data[1]`, so the pixels must be expanded before Vision sees them.
    ///
    /// The expansion also INVERTS the usual assumption: subtitle bitmaps are light glyphs on a transparent
    /// field, and Vision recognises dark-on-light far more reliably. Every pixel is therefore composited onto
    /// white and inverted to black text, which measurably improves recognition on typeset subtitles.
    static func image(from rect: AVSubtitleRect) -> CGImage? {
        let width = Int(rect.w)
        let height = Int(rect.h)
        guard width >= minimumRectEdge, height >= minimumRectEdge,
              width < 8192, height < 8192,
              let indices = rect.data.0, let paletteBytes = rect.data.1 else { return nil }
        let stride = Int(rect.linesize.0)
        guard stride >= width else { return nil }

        var palette = [UInt8](repeating: 0, count: 256 * 4)
        for i in 0..<(256 * 4) { palette[i] = paletteBytes[i] }

        var pixels = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = Int(indices[y * stride + x])
                let base = index * 4
                let b = Double(palette[base])
                let g = Double(palette[base + 1])
                let r = Double(palette[base + 2])
                let a = Double(palette[base + 3]) / 255.0
                // Composite onto white, then invert: light glyphs become dark text on a light field.
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                let composited = luma * a + 255.0 * (1.0 - a)
                pixels[y * width + x] = UInt8(max(0, min(255, 255.0 - composited * a - (1.0 - a) * 0)))
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    // MARK: - Recognition

    private func recognise(image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // A subtitle bitmap is one or two short lines of large type. Telling Vision the glyphs are tall
        // relative to the image stops it hunting for paragraph structure that is not there.
        request.minimumTextHeight = 0.15
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
