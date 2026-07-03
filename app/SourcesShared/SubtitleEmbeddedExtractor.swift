import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Extract EMBEDDED TEXT subtitle tracks from a container using libav, for the community-subtitle system.
///
/// WHY this exists even though libmpv already shows embedded subs during playback: this extractor is NOT for
/// local display. libmpv renders the file's own tracks fine on its own. This produces standalone SRT/VTT TEXT
/// so we can (a) UPLOAD an embedded subtitle to the pool so users on a DIFFERENT rip (that lacks it) benefit,
/// and (b) feed the AVPlayer path (which cannot mux Matroska text tracks itself). It reuses the exact libav
/// pattern from `MKVRemuxSession` (`avformat_open_input`, stream enumeration); FFmpeg is already linked via
/// MPVKit-GPL and the `Libav*` modules import directly from Swift (verified there).
///
/// SCOPE: TEXT subtitle codecs ONLY -- SubRip/SRT, ASS/SSA, mov_text (tx3g), WebVTT, raw TEXT. IMAGE subtitles
/// (PGS/HDMV, DVD/VobSub, DVB) are SKIPPED: they are bitmaps, not text, and OCR is out of scope.
///
/// FAIL-SOFT: returns `[]` on ANY error (open failure, no text tracks, decode failure). Never throws. Must be
/// called OFF the main thread (it does blocking libav I/O). Accepts a local file path OR a direct/debrid
/// HTTP(S) URL that libav can open (same inputs `MKVRemuxSession.remux` accepts).
enum SubtitleEmbeddedExtractor {

    /// One extracted text subtitle track.
    struct ExtractedTrack: Sendable {
        let lang: String     // ISO code from the stream's "language" metadata tag, or "und"
        let format: String   // "srt" | "vtt"
        let srt: String      // the assembled subtitle text (SRT unless `format == "vtt"`)
        let cueCount: Int    // number of cues emitted (0-cue tracks are still returned so the caller can decide)
    }

    /// Extract every TEXT subtitle track from `input`. `preferVTT` picks the WebVTT container for the output
    /// text (default false = SRT). Blocking; call off the main thread. Returns `[]` on any error.
    static func extractTextSubtitles(input: String, preferVTT: Bool = false) -> [ExtractedTrack] {
        var ifmt: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&ifmt, input, nil, nil) == 0, let inCtx = ifmt else { return [] }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = inCtx; avformat_close_input(&p) }

        guard avformat_find_stream_info(inCtx, nil) >= 0 else { return [] }

        let nb = Int(inCtx.pointee.nb_streams)
        guard nb > 0 else { return [] }

        // Identify TEXT subtitle streams and set up a decoder per stream (index -> builder).
        var builders: [Int: CueBuilder] = [:]
        var decoders: [Int: UnsafeMutablePointer<AVCodecContext>] = [:]
        defer {
            for (_, ctx) in decoders { var c: UnsafeMutablePointer<AVCodecContext>? = ctx; avcodec_free_context(&c) }
        }

        for i in 0..<nb {
            guard let stream = inCtx.pointee.streams[i],
                  let par = stream.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE,
                  isTextSubtitle(par.pointee.codec_id) else { continue }

            guard let codec = avcodec_find_decoder(par.pointee.codec_id),
                  let ctx = avcodec_alloc_context3(codec) else { continue }
            var opened = false
            defer { if !opened { var c: UnsafeMutablePointer<AVCodecContext>? = ctx; avcodec_free_context(&c) } }

            guard avcodec_parameters_to_context(ctx, par) >= 0,
                  avcodec_open2(ctx, codec, nil) >= 0 else { continue }
            opened = true

            decoders[i] = ctx
            let lang = languageTag(of: stream) ?? "und"
            let timeBase = av_q2d(stream.pointee.time_base)
            builders[i] = CueBuilder(lang: lang, timeBaseSeconds: timeBase > 0 ? timeBase : 0.001)
        }

        guard !decoders.isEmpty else { return [] }   // no text subtitle tracks

        // Read packets; decode each subtitle-stream packet into cues.
        guard let pkt = av_packet_alloc() else { return [] }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }

        while av_read_frame(inCtx, pkt) >= 0 {
            let idx = Int(pkt.pointee.stream_index)
            if let ctx = decoders[idx], let builder = builders[idx] {
                decodePacket(pkt, ctx: ctx, into: builder)
            }
            av_packet_unref(pkt)
        }

        // Assemble each builder into an output track.
        return builders
            .sorted { $0.key < $1.key }
            .map { $0.value.finish(preferVTT: preferVTT) }
    }

    // MARK: - Packet decode

    /// Decode one subtitle packet into `builder`, appending each text/ASS rect as a cue.
    private static func decodePacket(_ pkt: UnsafeMutablePointer<AVPacket>,
                                     ctx: UnsafeMutablePointer<AVCodecContext>,
                                     into builder: CueBuilder) {
        var sub = AVSubtitle()
        var got: Int32 = 0
        let ret = avcodec_decode_subtitle2(ctx, &sub, &got, pkt)
        guard ret >= 0, got != 0 else { return }
        defer { avsubtitle_free(&sub) }

        // Timing: packet PTS in the stream time base -> seconds, plus the subtitle's own display offsets (ms).
        let ptsSeconds = pkt.pointee.pts != Int64.min
            ? Double(pkt.pointee.pts) * builder.timeBaseSeconds
            : 0
        let startSeconds = ptsSeconds + Double(sub.start_display_time) / 1000.0
        // end_display_time == 0 means "until next": give it a short default so the cue is well-formed.
        let endMs = sub.end_display_time > sub.start_display_time ? sub.end_display_time : sub.start_display_time + 3000
        let endSeconds = ptsSeconds + Double(endMs) / 1000.0

        let n = Int(sub.num_rects)
        guard n > 0, let rects = sub.rects else { return }
        var lines: [String] = []
        for r in 0..<n {
            guard let rect = rects[r] else { continue }
            if let text = rect.pointee.text {                     // raw UTF-8 text rect (SRT/TEXT)
                let s = String(cString: text)
                if !s.isEmpty { lines.append(s) }
            } else if let ass = rect.pointee.ass {                // ASS/SSA event line; take the visible text field
                let s = plainTextFromASS(String(cString: ass))
                if !s.isEmpty { lines.append(s) }
            }
        }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return }
        builder.add(startSeconds: max(0, startSeconds), endSeconds: max(startSeconds, endSeconds), text: joined)
    }

    // MARK: - Codec classification

    /// True for TEXT subtitle codecs we can turn into SRT/VTT. Image subtitles (PGS/DVD/DVB) return false.
    private static func isTextSubtitle(_ id: AVCodecID) -> Bool {
        switch id {
        case AV_CODEC_ID_SUBRIP, AV_CODEC_ID_TEXT, AV_CODEC_ID_ASS, AV_CODEC_ID_SSA,
             AV_CODEC_ID_MOV_TEXT, AV_CODEC_ID_WEBVTT:
            return true
        default:
            return false   // AV_CODEC_ID_HDMV_PGS_SUBTITLE / DVD_SUBTITLE / DVB_SUBTITLE etc: image, skip
        }
    }

    // MARK: - Metadata

    /// The ISO language code from a stream's "language" metadata tag, lowercased, or nil.
    private static func languageTag(of stream: UnsafeMutablePointer<AVStream>) -> String? {
        guard let entry = av_dict_get(stream.pointee.metadata, "language", nil, 0),
              let value = entry.pointee.value else { return nil }
        let lang = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lang.isEmpty || lang == "und" ? nil : lang
    }

    /// Extract the visible text from an ASS/SSA "Dialogue" event line. The format is 9 comma-separated fields
    /// (Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect) then the Text (which may itself contain
    /// commas), so we split on the first 9 commas and take the remainder, then strip `{...}` override tags and
    /// convert `\N` / `\n` to newlines.
    private static func plainTextFromASS(_ ass: String) -> String {
        // libavcodec's `ass` rect is the event line WITHOUT the "Dialogue: " prefix but WITH the leading
        // ReadOrder/Layer fields. Split into at most 10 parts on comma; the 10th is the text.
        let parts = ass.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
        let textField = parts.count >= 10 ? String(parts[9]) : ass
        let noTags = textField.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
        return noTags
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cue assembly

    /// Accumulates cues for one subtitle stream and serializes to SRT or WebVTT. A `class` so builders can live
    /// in a dictionary and be mutated as packets stream in.
    private final class CueBuilder {
        let lang: String
        let timeBaseSeconds: Double
        private var cues: [(start: Double, end: Double, text: String)] = []

        init(lang: String, timeBaseSeconds: Double) {
            self.lang = lang
            self.timeBaseSeconds = timeBaseSeconds
        }

        func add(startSeconds: Double, endSeconds: Double, text: String) {
            cues.append((startSeconds, endSeconds, text))
        }

        /// Serialize accumulated cues to an SRT (or VTT) string, sorted by start time.
        func finish(preferVTT: Bool) -> ExtractedTrack {
            let ordered = cues.sorted { $0.start < $1.start }
            let format = preferVTT ? "vtt" : "srt"
            let body = preferVTT ? serializeVTT(ordered) : serializeSRT(ordered)
            return ExtractedTrack(lang: lang, format: format, srt: body, cueCount: ordered.count)
        }

        private func serializeSRT(_ ordered: [(start: Double, end: Double, text: String)]) -> String {
            var out = ""
            for (i, cue) in ordered.enumerated() {
                out += "\(i + 1)\n"
                out += "\(srtTime(cue.start)) --> \(srtTime(cue.end))\n"
                out += "\(cue.text)\n\n"
            }
            return out
        }

        private func serializeVTT(_ ordered: [(start: Double, end: Double, text: String)]) -> String {
            var out = "WEBVTT\n\n"
            for cue in ordered {
                out += "\(vttTime(cue.start)) --> \(vttTime(cue.end))\n"
                out += "\(cue.text)\n\n"
            }
            return out
        }

        /// SRT timestamp `HH:MM:SS,mmm`.
        private func srtTime(_ seconds: Double) -> String {
            let (h, m, s, ms) = hms(seconds)
            return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
        }

        /// WebVTT timestamp `HH:MM:SS.mmm`.
        private func vttTime(_ seconds: Double) -> String {
            let (h, m, s, ms) = hms(seconds)
            return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
        }

        private func hms(_ seconds: Double) -> (Int, Int, Int, Int) {
            let clamped = max(0, seconds)
            let totalMs = Int((clamped * 1000).rounded())
            let ms = totalMs % 1000
            let totalSecs = totalMs / 1000
            return (totalSecs / 3600, (totalSecs % 3600) / 60, totalSecs % 60, ms)
        }
    }
}
