import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// DV-for-MKV STREAMING remux (Phase 1). Opens an MKV from a debrid HTTP(S) URL and stream-copies it into a
/// fragmented MP4, writing the muxed bytes to an in-memory `VortXRemuxBuffer` via a CUSTOM AVIO write callback
/// (no file, no disk). `VortXRemuxResourceLoader` serves that buffer to AVPlayer as `vortxremux://` byte
/// ranges, so AVPlayer plays TRUE Dolby Vision (Profile 5 / 8.1 / 8.4) out of an MKV that AVFoundation cannot
/// demux directly. Stream-copy re-wraps the exact HEVC access units, so the DV RPU (SEI NALs) + the DOVI
/// config box survive; only the container changes.
///
/// What the output CARRIES is constrained by what AVPlayer can actually play:
///   - Video: only single-layer DV Profile 5 / 8.x. Profile 7 (BL+EL) has no VideoToolbox decode, and a
///     stream whose DV label lied (no DOVI config) gains nothing here: both FAIL FAST (before any video
///     mounts) so the chrome demotes to libmpv's HDR10 tone-map instead of dead-ending on an AVPlayer error.
///   - Audio: only AVPlayer-decodable codecs (AAC/AC3/EAC3/ALAC/MP3/FLAC) are mapped. TrueHD and DTS are
///     DROPPED, AVPlayer cannot decode them, and muxed in they either kill the muxer or play silent. A
///     source whose ONLY audio is TrueHD/DTS fails fast for the same libmpv demotion (mpv decodes them all).
///   - Subtitles: never mapped. The mp4 muxer cannot stream-copy Matroska text/PGS subtitle codecs
///     (avformat_write_header fails and kills the whole session); the player's add-on/community subtitle
///     panel covers subtitles on the AVPlayer path.
///
/// This mirrors `MKVRemuxSession`'s proven file-based remux (open input, map video/audio/subtitle streams,
/// `avcodec_parameters_copy`, fragmented-mp4 movflags, `av_read_frame` -> `av_interleaved_write_frame`) but
/// swaps the file sink for `avio_alloc_context` with a write callback appending to the buffer.
///
/// Phase-1 scope: FORWARD-ONLY. The custom AVIO exposes no working seek to the muxer, and the source is read
/// straight through, so AVPlayer scrubbing past buffered content is a documented TODO. The remux loop runs on
/// one dedicated background thread; `cancel()` requests a clean stop and the loop tears down in the correct
/// AVIO/AVFormatContext free order.
final class VortXMKVRemuxStream: @unchecked Sendable {

    let buffer = VortXRemuxBuffer()

    private let input: String
    private let headers: [String: String]?
    private var thread: Thread?
    private let cancelledFlag = ManagedAtomicFlag()

    /// AVIO write scratch: libav wants an aligned malloc'd buffer it owns for the AVIO context. We keep the
    /// opaque (a retained reference to `self`) alive for the whole session so the C callback never touches a
    /// freed object.
    private static let avioBufferSize = 1 << 16   // 64 KiB muxer write chunk

    init(input: String, headers: [String: String]?) {
        self.input = input
        self.headers = headers
    }

    /// Start the remux on a dedicated background thread. Idempotent-ish: call once per session.
    ///
    /// CRASH-SAFETY: the closure captures `self` STRONGLY on purpose. The C AVIO write callback holds an
    /// unretained opaque pointer to `self` and runs on this thread; if the only owning reference (the resource
    /// loader) is niled on the main thread mid-mux (a title switch / player dismiss), a weak capture would let
    /// `self` deallocate while `av_interleaved_write_frame` / `av_write_trailer` is still re-entering that
    /// callback -> use-after-free. The strong capture forms a deliberate, TEMPORARY retain cycle
    /// (self -> thread -> closure -> self) that keeps `self` alive for exactly the lifetime of `run()`;
    /// Foundation releases the block when the thread exits, breaking the cycle. `cancel()` sets the flag so the
    /// write callback returns AVERROR_EXIT and the loop unwinds promptly, so this never leaks past teardown.
    func start() {
        let t = Thread { self.run() }
        t.name = "vortx.dvremux"
        t.stackSize = 1 << 20      // 1 MiB; libav muxing is not deeply recursive but give it headroom
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// Request a clean stop. The read loop checks this between packets and bails, then frees in order. Safe to
    /// call more than once and from any thread. Does NOT block; teardown completes on the remux thread.
    func cancel() {
        cancelledFlag.set()
        // Wake any buffer reader blocked in AVPlayer's loader so it stops waiting on bytes that won't come.
        buffer.fail("cancelled")
    }

    var isCancelled: Bool { cancelledFlag.get() }

    // MARK: - Remux loop (background thread)

    private func run() {
        var info = SourceInfo()

        // Open the source. libav's protocol layer handles http/https directly; pass request headers (debrid
        // links sometimes need auth / a UA) through the demuxer options as a CRLF-joined "headers" string.
        var ifmt: UnsafeMutablePointer<AVFormatContext>? = nil
        var openOpts: OpaquePointer? = nil    // AVDictionary*
        if let headers, !headers.isEmpty {
            let joined = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
            av_dict_set(&openOpts, "headers", joined, 0)
        }
        // Reasonable network timeouts so a dead debrid link fails instead of hanging the thread forever.
        av_dict_set(&openOpts, "rw_timeout", "15000000", 0)   // 15s in microseconds
        // Cap how much the probe reads before classifying. rw_timeout bounds each syscall, but without these
        // avformat_find_stream_info can read many seconds of a high-bitrate 4K DV bitstream off a slow debrid
        // CDN before the DV / audio fail-fast guard below runs, leaving AVPlayer on frameless chrome (no bytes,
        // no error) so the start-watchdog and the AVPlayer -> libmpv demotion cannot fire yet. A few MB / a
        // couple seconds is plenty to read the DOVI config and audio codecs and keeps the pre-start window bounded.
        av_dict_set(&openOpts, "probesize", "5000000", 0)         // ~5 MB
        av_dict_set(&openOpts, "analyzeduration", "2000000", 0)   // 2s in microseconds
        let openRc = avformat_open_input(&ifmt, input, nil, &openOpts)
        av_dict_free(&openOpts)
        guard openRc == 0, let inCtx = ifmt else {
            buffer.fail("avformat_open_input failed (\(openRc))")
            return
        }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = inCtx; avformat_close_input(&p) }

        let si = avformat_find_stream_info(inCtx, nil)
        if si < 0 { buffer.fail("avformat_find_stream_info failed (\(si))"); return }

        // Output context: fragmented MP4, NO file (custom IO).
        var ofmt: UnsafeMutablePointer<AVFormatContext>? = nil
        let ao = avformat_alloc_output_context2(&ofmt, nil, "mp4", nil)
        guard ao >= 0, let outCtx = ofmt else { buffer.fail("avformat_alloc_output_context2 failed (\(ao))"); return }

        // Custom AVIO. libav wants an aligned buffer it owns; av_malloc it and hand ownership to the context.
        // `opaque` is an unretained pointer to self (self outlives the thread: the thread holds a strong ref
        // via the closure until run() returns, and callers keep the stream alive for the session).
        let avioBuf = av_malloc(Self.avioBufferSize)?.assumingMemoryBound(to: UInt8.self)
        guard let avioBuf else { buffer.fail("av_malloc(avio) failed"); avformat_free_context(outCtx); return }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        let avio = avio_alloc_context(
            avioBuf, Int32(Self.avioBufferSize),
            1,          // write_flag
            opaque,
            nil,        // read_packet: not needed for a write-only muxer
            { (opaque, buf, size) -> Int32 in
                // Write callback: copy the muxed bytes into the growing buffer. Runs on the remux thread.
                guard let opaque, let buf, size > 0 else { return 0 }
                let me = Unmanaged<VortXMKVRemuxStream>.fromOpaque(opaque).takeUnretainedValue()
                if me.isCancelled { return AVERROR_EXIT_CONST }   // abort muxing on cancel
                me.buffer.append(buf, count: Int(size))
                return size
            },
            nil         // seek: forward-only (Phase 1); the muxer only appends with these movflags
        )
        guard let avio else {
            av_free(avioBuf)
            avformat_free_context(outCtx)
            buffer.fail("avio_alloc_context failed")
            return
        }
        outCtx.pointee.pb = avio
        // We manage the AVIO ourselves, so make sure the muxer never tries to open/close a file for it.
        outCtx.pointee.flags |= AVFMT_FLAG_CUSTOM_IO_CONST

        // Ordered teardown: free the muxer context's streams first (avformat_free_context), then the AVIO
        // context, then its backing buffer. avio_context_free may reallocate ctx->buffer internally, so we
        // read the CURRENT buffer pointer back from the context right before freeing it (never free avioBuf
        // directly, or we risk a double-free / stale-pointer free).
        defer {
            // Detach pb so avformat_free_context does not touch the AVIO (we own it under CUSTOM_IO).
            let pb = outCtx.pointee.pb
            outCtx.pointee.pb = nil
            avformat_free_context(outCtx)
            if let pb {
                // The muxer may have swapped ctx->buffer for a new av_malloc'd block; free the CURRENT one
                // (read it before avio_context_free frees the struct), then the struct. Exactly one free each,
                // in this order, so no double-free of avioBuf.
                let backing = pb.pointee.buffer
                var pbOpt: UnsafeMutablePointer<AVIOContext>? = pb
                avio_context_free(&pbOpt)
                if let backing { av_free(backing) }
            }
        }

        // Inspect BEFORE mapping: read the DV profile and classify audio so an impossible session fails FAST
        // (seconds in, before AVPlayer mounts any video). A fast buffer.fail here is what drives the chrome's
        // seamless AVPlayer -> libmpv demotion; the alternative was a hard AVPlayer error screen mid-remux.
        let nb = Int(inCtx.pointee.nb_streams)
        var mappable = Set<Int>()
        var audioSeen: [String] = []
        var hasDecodableAudio = false
        for i in 0..<nb {
            guard let inStream = inCtx.pointee.streams[i], let par = inStream.pointee.codecpar else { continue }
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                if info.dvProfile < 0 {
                    info.width = Int(par.pointee.width)
                    info.height = Int(par.pointee.height)
                    info.videoCodec = Self.codecName(par.pointee.codec_id)
                    Self.readDoVi(par, into: &info)
                }
                mappable.insert(i)
            case AVMEDIA_TYPE_AUDIO:
                audioSeen.append(Self.codecName(par.pointee.codec_id))
                if Self.avPlayerDecodableAudio.contains(par.pointee.codec_id.rawValue) {
                    hasDecodableAudio = true
                    mappable.insert(i)
                }
            default:
                break   // subtitles/data/attachments are never mapped (see the header note)
            }
        }
        // TRUE DV via AVPlayer needs single-layer Profile 5 / 8.x. Profile 7 (BL+EL) has no VideoToolbox
        // decode, and a stream with no DOVI config (the filename label lied) gains nothing from AVPlayer.
        guard info.dvProfile == 5 || info.dvProfile == 8 else {
            buffer.fail(info.dvProfile < 0
                ? "source has no Dolby Vision configuration (label mismatch)"
                : "Dolby Vision profile \(info.dvProfile) is not AVPlayer-decodable")
            return
        }
        // AVPlayer cannot decode TrueHD/DTS. With no decodable track the session would mount then fail (or
        // play silent); libmpv decodes every codec here, so fail fast and let the chrome demote.
        guard hasDecodableAudio else {
            buffer.fail("no AVPlayer-decodable audio track (source audio: \(audioSeen.joined(separator: ",")))")
            return
        }
        var streamMap = [Int](repeating: -1, count: nb)
        var outIndex: Int32 = 0
        for i in 0..<nb where mappable.contains(i) {
            guard let inStream = inCtx.pointee.streams[i] else { continue }
            let par = inStream.pointee.codecpar
            guard let outStream = avformat_new_stream(outCtx, nil) else { buffer.fail("avformat_new_stream returned nil"); return }
            let cp = avcodec_parameters_copy(outStream.pointee.codecpar, par)
            if cp < 0 { buffer.fail("avcodec_parameters_copy failed (\(cp))"); return }
            outStream.pointee.codecpar.pointee.codec_tag = 0
            streamMap[i] = Int(outIndex)
            outIndex += 1
            info.mappedStreams += 1
        }
        if info.mappedStreams == 0 { buffer.fail("no playable streams in source"); return }

        // Fragmented MP4 so playback starts before the whole file is muxed, and so it can stream. `faststart`
        // is a no-op for custom-IO (it needs a seekable sink) but harmless; the frag flags are what matter.
        var opts: OpaquePointer? = nil   // AVDictionary*
        av_dict_set(&opts, "movflags", "frag_keyframe+empty_moov+default_base_moof", 0)
        // FLAC-in-mp4 is spec'd (and AVPlayer decodes it) but FFmpeg's mov muxer gates it behind strict
        // experimental; without this a FLAC-audio DV MKV would die at avformat_write_header.
        av_dict_set(&opts, "strict", "experimental", 0)
        defer { av_dict_free(&opts) }

        let wh = avformat_write_header(outCtx, &opts)
        if wh < 0 { buffer.fail("avformat_write_header failed (\(wh))"); return }

        guard let pkt = av_packet_alloc() else { buffer.fail("av_packet_alloc returned nil"); return }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }

        NSLog("[dv-remux-stream] start: %@ %dx%d dvProfile=%d blCompat=%d streams=%d",
              info.videoCodec, info.width, info.height, info.dvProfile, info.dvBLCompatId, info.mappedStreams)

        while !isCancelled, av_read_frame(inCtx, pkt) >= 0 {
            let inIdx = Int(pkt.pointee.stream_index)
            guard inIdx >= 0, inIdx < nb, streamMap[inIdx] >= 0,
                  let inStream = inCtx.pointee.streams[inIdx],
                  let outStream = outCtx.pointee.streams[streamMap[inIdx]] else {
                av_packet_unref(pkt); continue
            }
            pkt.pointee.stream_index = Int32(streamMap[inIdx])
            av_packet_rescale_ts(pkt, inStream.pointee.time_base, outStream.pointee.time_base)
            pkt.pointee.pos = -1
            let wf = av_interleaved_write_frame(outCtx, pkt)
            av_packet_unref(pkt)
            if wf < 0 {
                if isCancelled { break }     // our write callback returned EXIT; expected on cancel
                buffer.fail("av_interleaved_write_frame failed (\(wf))")
                return
            }
        }

        if isCancelled {
            NSLog("[dv-remux-stream] cancelled after %d bytes", buffer.producedCount)
            // buffer already marked failed("cancelled") by cancel(); defers handle libav teardown.
            return
        }

        // Flush the muxer trailer (writes the final fragment metadata), then mark the buffer complete.
        av_write_trailer(outCtx)
        buffer.finish()
        NSLog("[dv-remux-stream] done: %d bytes muxed", buffer.producedCount)
    }

    // MARK: - Source diagnostics (mirrors MKVRemuxSession)

    /// Audio codecs AVPlayer can decode out of an fMP4 (compared by rawValue). Everything else (chiefly
    /// TrueHD, DTS, Opus, Vorbis, raw PCM variants) is dropped from the map; a source with none of these
    /// fails fast to the libmpv path.
    private static let avPlayerDecodableAudio: [AVCodecID.RawValue] = [
        AV_CODEC_ID_AAC.rawValue, AV_CODEC_ID_AC3.rawValue, AV_CODEC_ID_EAC3.rawValue,
        AV_CODEC_ID_ALAC.rawValue, AV_CODEC_ID_MP3.rawValue, AV_CODEC_ID_FLAC.rawValue
    ]

    struct SourceInfo {
        var videoCodec: String = "?"
        var dvProfile: Int = -1
        var dvBLCompatId: Int = -1
        var width: Int = 0
        var height: Int = 0
        var mappedStreams: Int = 0
    }

    private static func readDoVi(_ par: UnsafeMutablePointer<AVCodecParameters>?, into info: inout SourceInfo) {
        guard let par else { return }
        let n = Int(par.pointee.nb_coded_side_data)
        guard n > 0, let arr = par.pointee.coded_side_data else { return }
        for i in 0..<n {
            let sd = arr[i]
            if sd.type == AV_PKT_DATA_DOVI_CONF, let data = sd.data {
                data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
                    info.dvProfile = Int(rec.pointee.dv_profile)
                    info.dvBLCompatId = Int(rec.pointee.dv_bl_signal_compatibility_id)
                }
                return
            }
        }
    }

    private static func codecName(_ id: AVCodecID) -> String {
        if let c = avcodec_get_name(id) { return String(cString: c) }
        return "?"
    }
}

// MARK: - Small helpers not exposed cleanly through the Swift libav shims

/// AVERROR_EXIT = -('E'|'X'|'I'|'T'<<8...) via AVERROR(...) on FFERRTAG; the Swift import doesn't surface the
/// macro, so hardcode the standard value. This aborts the muxer's write loop when we cancel mid-remux.
private let AVERROR_EXIT_CONST: Int32 = -1414092869   // AVERROR_EXIT

/// AVFMT_FLAG_CUSTOM_IO is a plain #define (0x0080) not always surfaced as a Swift constant.
private let AVFMT_FLAG_CUSTOM_IO_CONST: Int32 = 0x0080

/// A tiny lock-free-ish boolean flag (an `os_unfair_lock`-free atomic via a serial-safe class). We only need
/// set-once + read-many across threads; a plain `NSLock`-guarded Bool is more than fast enough here and avoids
/// pulling in `Atomics`.
final class ManagedAtomicFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
