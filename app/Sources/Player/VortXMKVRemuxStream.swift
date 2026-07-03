import Foundation
import Libavformat
import Libavcodec
import Libavutil
// Libdovi (libdovi's C API, vendored inside MPVKit-GPL alongside FFmpeg) is used to convert a Dolby Vision
// Profile 7 RPU to Profile 8.1 in-flight so AVPlayer/VideoToolbox can decode it as TRUE DV. It is linked into
// every native Apple target (and the legacy web-host target) transitively via MPVKit-GPL, the same package that
// provides Libavcodec/format/util above, so the import resolves wherever this file compiles.
import Libdovi

/// DV-for-MKV STREAMING remux (Phase 1). Opens an MKV from a debrid HTTP(S) URL and stream-copies it into a
/// fragmented MP4, writing the muxed bytes to an in-memory `VortXRemuxBuffer` via a CUSTOM AVIO write callback
/// (no file, no disk). `VortXRemuxResourceLoader` serves that buffer to AVPlayer as `vortxremux://` byte
/// ranges, so AVPlayer plays TRUE Dolby Vision (Profile 5 / 8.1 / 8.4) out of an MKV that AVFoundation cannot
/// demux directly. Stream-copy re-wraps the exact HEVC access units, so the DV RPU (SEI NALs) + the DOVI
/// config box survive; only the container changes.
///
/// What the output CARRIES is constrained by what AVPlayer can actually play:
///   - Video: single-layer DV Profile 5 / 8.x plays as a pure stream-copy. Dual-layer Profile 7 (BL+EL, i.e.
///     ~every UHD-BluRay DV rip) is CONVERTED on the fly to Profile 8.1: AVPlayer/VideoToolbox cannot decode
///     Profile 7's enhancement layer, but it CAN decode the Profile 8.1 base layer as true DV. We drop the EL
///     (whether a separate MKV track or an in-band UNSPEC63 sublayer NAL) and convert the DV RPU NAL to
///     Profile 8.1 via libdovi, then advertise dv_profile=8 / bl_compat=1 on the output so the mov muxer emits
///     a Profile-8 `dvvC` box and AVPlayer engages true DV. A stream whose DV label lied (no DOVI config) still
///     FAILS FAST (before any video mounts) so the chrome demotes to libmpv's HDR10 tone-map; a Profile-7
///     conversion that errors at runtime also fails soft to that same demotion, never a crash or a hang.
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
        // The base-layer (primary) video track. For DUAL-TRACK Profile 7 (separate BL + EL video streams), the
        // FIRST video stream is the base layer we keep; any later video stream is the enhancement layer, which
        // AVPlayer can't decode and which we DROP (never mapped). Single-track sources have exactly one video
        // stream, so this is a no-op for them. `baseVideoIn` also tells the mux loop which packets to convert.
        var baseVideoIn = -1
        for i in 0..<nb {
            guard let inStream = inCtx.pointee.streams[i], let par = inStream.pointee.codecpar else { continue }
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                if baseVideoIn < 0 {
                    baseVideoIn = i
                    info.width = Int(par.pointee.width)
                    info.height = Int(par.pointee.height)
                    info.videoCodec = Self.codecName(par.pointee.codec_id)
                    Self.readDoVi(par, into: &info)
                    mappable.insert(i)   // map ONLY the base-layer video track
                }
                // Additional video streams (a dual-track P7 enhancement layer) are intentionally NOT mapped.
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
        // Profile 5 / 8.x are single-layer and stream-copy straight through (pure re-wrap, RPU untouched).
        // Profile 7 (BL+EL, ~every UHD-BluRay DV rip) has no VideoToolbox dual-layer decode, so we CONVERT its
        // RPU to Profile 8.1 and drop the EL (see the mux loop). A stream with no DOVI config (the filename
        // label lied) still gains nothing from AVPlayer and fails fast to the libmpv tone-map.
        let convertP7 = (info.dvProfile == 7)
        guard info.dvProfile == 5 || info.dvProfile == 8 || convertP7 else {
            buffer.fail(info.dvProfile < 0
                ? "source has no Dolby Vision configuration (label mismatch)"
                : "Dolby Vision profile \(info.dvProfile) is not AVPlayer-decodable")
            return
        }
        // Reject an obviously-malformed base video track up front so the conversion path has a valid stream to
        // work on and a bad source still fails soft to the libmpv demotion rather than mid-loop.
        if convertP7, baseVideoIn < 0 {
            buffer.fail("Dolby Vision profile 7 source has no base-layer video track")
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
        var baseVideoOut = -1        // output index of the base-layer video track (packets to convert)
        for i in 0..<nb where mappable.contains(i) {
            guard let inStream = inCtx.pointee.streams[i] else { continue }
            let par = inStream.pointee.codecpar
            guard let outStream = avformat_new_stream(outCtx, nil) else { buffer.fail("avformat_new_stream returned nil"); return }
            let cp = avcodec_parameters_copy(outStream.pointee.codecpar, par)
            if cp < 0 { buffer.fail("avcodec_parameters_copy failed (\(cp))"); return }
            outStream.pointee.codecpar.pointee.codec_tag = 0
            if i == baseVideoIn {
                baseVideoOut = Int(outIndex)
                // For a Profile 7 conversion, re-label the OUTPUT DOVI configuration record as Profile 8.1 so
                // FFmpeg's mov muxer writes a Profile-8 `dvvC` box (dv_profile>7 selects dvvC) and AVPlayer
                // engages true DV. The RPU itself is converted per-packet in the mux loop; this makes the
                // container box agree with the converted bitstream. Also clears the EL-present flag (the EL is
                // dropped). Best-effort: if the source somehow carried no DOVI side data to rewrite, the
                // per-packet RPU conversion still runs and the muxer will derive a box from the bitstream.
                if convertP7 {
                    Self.relabelOutputDoViProfile81(outStream.pointee.codecpar)
                }
            }
            streamMap[i] = Int(outIndex)
            outIndex += 1
            info.mappedStreams += 1
        }
        if info.mappedStreams == 0 { buffer.fail("no playable streams in source"); return }
        if convertP7, baseVideoOut < 0 { buffer.fail("Dolby Vision profile 7 base-layer video was not mapped"); return }

        // The HEVC NAL length prefix size (1/2/4 bytes) lives in the base track's hvcC extradata; read it once
        // so the per-packet RPU converter can walk the length-prefixed access units. Defaults to 4 (the near
        // universal value) if extradata is missing or malformed.
        let nalLengthSize: Int = convertP7
            ? Self.hevcNalLengthSize(inCtx.pointee.streams[baseVideoIn]?.pointee.codecpar)
            : 4

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

        NSLog("[dv-remux-stream] start: %@ %dx%d dvProfile=%d blCompat=%d streams=%d convertP7=%d nalLen=%d",
              info.videoCodec, info.width, info.height, info.dvProfile, info.dvBLCompatId,
              info.mappedStreams, convertP7 ? 1 : 0, nalLengthSize)

        while !isCancelled, av_read_frame(inCtx, pkt) >= 0 {
            let inIdx = Int(pkt.pointee.stream_index)
            guard inIdx >= 0, inIdx < nb, streamMap[inIdx] >= 0,
                  let inStream = inCtx.pointee.streams[inIdx],
                  let outStream = outCtx.pointee.streams[streamMap[inIdx]] else {
                av_packet_unref(pkt); continue
            }
            let outIdx = streamMap[inIdx]
            // Profile 7 -> 8.1: rewrite the DV RPU NAL (and drop any in-band EL sublayer NAL) in the base-layer
            // video packets before muxing. Only the base video track is touched; audio and every other packet
            // pass through byte-for-byte. Conversion is fail-SOFT: on any error the packet's bytes are left
            // exactly as read, so a quirk in one access unit degrades to a possibly-imperfect frame rather than
            // aborting the whole session (the AVPlayer -> libmpv demotion remains the hard backstop).
            if convertP7, outIdx == baseVideoOut {
                Self.convertPacketRPUToProfile81(pkt, nalLengthSize: nalLengthSize)
            }
            pkt.pointee.stream_index = Int32(outIdx)
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

    // MARK: - Dolby Vision Profile 7 -> 8.1 conversion (libdovi)

    /// HEVC NAL unit types we care about for DV. The RPU (Dolby's mapping metadata) rides in an UNSPEC62 NAL;
    /// the enhancement-layer sublayer (in a SINGLE-TRACK Profile 7 stream) rides in UNSPEC63. Type is bits 6..1
    /// of the first NAL header byte: `(byte0 >> 1) & 0x3F`.
    private static let hevcNalTypeDoViRPU: UInt8 = 62   // UNSPEC62: Dolby Vision RPU
    private static let hevcNalTypeDoViEL: UInt8 = 63    // UNSPEC63: Dolby Vision enhancement-layer sublayer

    /// libdovi conversion mode 2: "Converts the RPU to be profile 8.1 compatible ... handles source profiles
    /// 5, 7 and 8" (both luma and chroma mapping curves set to no-op). This is the mode that makes a Profile 7
    /// RPU decodable by AVPlayer/VideoToolbox as single-layer 8.1.
    private static let dolbyConvertModeProfile81: UInt8 = 2

    /// Read the HEVC NAL length-prefix size (1, 2, or 4 bytes) from the base track's hvcC extradata. In an
    /// hvcC record byte 21 holds `lengthSizeMinusOne` in its low two bits. Falls back to 4 (the near-universal
    /// value FFmpeg's matroska demuxer emits) when extradata is absent, too short, or not an hvcC record.
    private static func hevcNalLengthSize(_ par: UnsafeMutablePointer<AVCodecParameters>?) -> Int {
        guard let par, let ex = par.pointee.extradata else { return 4 }
        let n = Int(par.pointee.extradata_size)
        // hvcC starts with configurationVersion (1) and needs at least 23 bytes to reach the length-size byte.
        guard n >= 23, ex[0] == 1 else { return 4 }
        let size = Int(ex[21] & 0x03) + 1
        return (size == 1 || size == 2 || size == 4) ? size : 4
    }

    /// Rewrite the OUTPUT stream's DOVI configuration side-data record to advertise Profile 8.1 (BL-compatible)
    /// so FFmpeg's mov muxer emits a Profile-8 `dvvC` box and AVPlayer engages true DV for the converted
    /// bitstream. Mutates the existing `AV_PKT_DATA_DOVI_CONF` record that `avcodec_parameters_copy` already
    /// duplicated onto the output codecpar (the buffer is output-owned, so an in-place edit is safe). No-op if
    /// the source carried no DOVI side data (the per-packet RPU conversion still runs and the muxer derives a
    /// box from the converted bitstream).
    private static func relabelOutputDoViProfile81(_ par: UnsafeMutablePointer<AVCodecParameters>?) {
        guard let par else { return }
        let n = Int(par.pointee.nb_coded_side_data)
        guard n > 0, let arr = par.pointee.coded_side_data else { return }
        for i in 0..<n where arr[i].type == AV_PKT_DATA_DOVI_CONF {
            guard let data = arr[i].data,
                  Int(arr[i].size) >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size else { return }
            data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
                rec.pointee.dv_profile = 8
                rec.pointee.dv_bl_signal_compatibility_id = 1   // BL-compatible (HDR10 base)
                rec.pointee.el_present_flag = 0                 // the enhancement layer is dropped
                rec.pointee.rpu_present_flag = 1
                rec.pointee.bl_present_flag = 1
                rec.pointee.dv_md_compression = UInt8(AV_DOVI_COMPRESSION_NONE.rawValue)
            }
            return
        }
    }

    /// Convert the Dolby Vision RPU inside one base-layer HEVC packet from Profile 7 to Profile 8.1, in place,
    /// and drop any in-band enhancement-layer (UNSPEC63) NAL. Walks the length-prefixed access unit, and for
    /// each NAL either passes it through, converts it (the UNSPEC62 RPU), or drops it (the UNSPEC63 EL). The
    /// packet's data buffer is replaced with the rebuilt access unit via `av_packet_from_data`.
    ///
    /// FAIL-SOFT by design: on ANY problem (unparseable prefixing, a libdovi parse/convert/write error, an
    /// allocation failure) the packet is left byte-for-byte unchanged. That keeps a single quirky access unit
    /// from aborting the session; the AVPlayer -> libmpv demotion remains the hard backstop for a source that
    /// genuinely can't convert.
    private static func convertPacketRPUToProfile81(_ pkt: UnsafeMutablePointer<AVPacket>, nalLengthSize: Int) {
        guard let src = pkt.pointee.data else { return }
        let total = Int(pkt.pointee.size)
        guard total > nalLengthSize, nalLengthSize >= 1, nalLengthSize <= 4 else { return }

        var out = [UInt8]()
        out.reserveCapacity(total)
        var changed = false
        var pos = 0
        while pos + nalLengthSize <= total {
            // Read the big-endian NAL length prefix.
            var nalLen = 0
            for k in 0..<nalLengthSize { nalLen = (nalLen << 8) | Int(src[pos + k]) }
            let nalStart = pos + nalLengthSize
            // A corrupt/misaligned length means we no longer understand the bitstream: abandon the edit and
            // leave the ORIGINAL packet untouched rather than emit a truncated access unit.
            guard nalLen > 0, nalStart + nalLen <= total else { return }
            let nalType = (src[nalStart] >> 1) & 0x3F

            if nalType == hevcNalTypeDoViEL {
                // Drop the in-band enhancement-layer sublayer NAL (single-track Profile 7); the base layer plus
                // the converted RPU is what AVPlayer decodes.
                changed = true
            } else if nalType == hevcNalTypeDoViRPU {
                // Convert the RPU NAL (its 2-byte header 0x7C 0x01 is exactly the escaped UNSPEC62 prefix
                // libdovi expects) to Profile 8.1 and re-emit it length-prefixed. On any libdovi error, keep
                // the ORIGINAL RPU NAL (still valid DV metadata) so the frame is not left without an RPU.
                let converted: [UInt8]? = src.withMemoryRebound(to: UInt8.self, capacity: total) { base -> [UInt8]? in
                    guard let rpu = dovi_parse_unspec62_nalu(base + nalStart, nalLen) else { return nil }
                    defer { dovi_rpu_free(rpu) }
                    guard dovi_convert_rpu_with_mode(rpu, dolbyConvertModeProfile81) == 0 else { return nil }
                    guard let written = dovi_write_unspec62_nalu(rpu) else { return nil }
                    defer { dovi_data_free(written) }
                    guard let wdata = written.pointee.data, written.pointee.len > 0 else { return nil }
                    return Array(UnsafeBufferPointer(start: wdata, count: Int(written.pointee.len)))
                }
                if let newNal = converted {
                    appendLengthPrefixed(&out, newNal, nalLengthSize: nalLengthSize)
                    changed = true
                } else {
                    appendLengthPrefixed(&out, src, from: nalStart, count: nalLen, nalLengthSize: nalLengthSize)
                }
            } else {
                // Every other NAL (VPS/SPS/PPS/slices/SEI) passes through unchanged.
                appendLengthPrefixed(&out, src, from: nalStart, count: nalLen, nalLengthSize: nalLengthSize)
            }
            pos = nalStart + nalLen
        }
        // Trailing bytes we could not parse as a complete NAL: bail to the untouched original for safety.
        guard pos == total else { return }
        guard changed else { return }   // nothing to rewrite; keep the original buffer

        // Replace the packet payload. av_packet_from_data takes ownership of an av_malloc'd buffer padded with
        // AV_INPUT_BUFFER_PADDING_SIZE zeroed bytes (libav readers over-read the tail); allocate + copy into one.
        let newSize = out.count
        guard let dst = av_malloc(newSize + AV_INPUT_BUFFER_PADDING_SIZE_CONST)?
            .assumingMemoryBound(to: UInt8.self) else { return }
        out.withUnsafeBufferPointer { buf in
            if let b = buf.baseAddress { memcpy(dst, b, newSize) }
        }
        memset(dst + newSize, 0, AV_INPUT_BUFFER_PADDING_SIZE_CONST)
        // av_packet_from_data overwrites pkt->buf/data/size but does NOT unref the old buffer, so release the
        // demuxer's buffer ref first (this leaves pts/dts/flags/side_data intact, which is what we want). If the
        // wrap fails, free our buffer and leave the now-empty packet: a zero-size video packet the muxer skips,
        // preferable to a use-after-free. The AVPlayer -> libmpv demotion still backstops a truly broken stream.
        if let b = pkt.pointee.buf {
            var bref: UnsafeMutablePointer<AVBufferRef>? = b
            av_buffer_unref(&bref)
            pkt.pointee.buf = nil
        }
        pkt.pointee.data = nil
        pkt.pointee.size = 0
        if av_packet_from_data(pkt, dst, Int32(newSize)) < 0 {
            av_free(dst)
        }
    }

    /// Append a NAL slice from a source pointer to `out`, writing the big-endian length prefix first.
    private static func appendLengthPrefixed(_ out: inout [UInt8],
                                             _ src: UnsafePointer<UInt8>, from: Int, count: Int,
                                             nalLengthSize: Int) {
        writeLengthPrefix(&out, count, nalLengthSize: nalLengthSize)
        out.append(contentsOf: UnsafeBufferPointer(start: src + from, count: count))
    }

    /// Append a NAL held in a Swift array to `out`, writing the big-endian length prefix first.
    private static func appendLengthPrefixed(_ out: inout [UInt8], _ nal: [UInt8], nalLengthSize: Int) {
        writeLengthPrefix(&out, nal.count, nalLengthSize: nalLengthSize)
        out.append(contentsOf: nal)
    }

    private static func writeLengthPrefix(_ out: inout [UInt8], _ len: Int, nalLengthSize: Int) {
        for k in stride(from: nalLengthSize - 1, through: 0, by: -1) {
            out.append(UInt8((len >> (8 * k)) & 0xFF))
        }
    }
}

// MARK: - Small helpers not exposed cleanly through the Swift libav shims

/// AVERROR_EXIT = -('E'|'X'|'I'|'T'<<8...) via AVERROR(...) on FFERRTAG; the Swift import doesn't surface the
/// macro, so hardcode the standard value. This aborts the muxer's write loop when we cancel mid-remux.
private let AVERROR_EXIT_CONST: Int32 = -1414092869   // AVERROR_EXIT

/// AVFMT_FLAG_CUSTOM_IO is a plain #define (0x0080) not always surfaced as a Swift constant.
private let AVFMT_FLAG_CUSTOM_IO_CONST: Int32 = 0x0080

/// AV_INPUT_BUFFER_PADDING_SIZE is a plain #define (64) the Swift importer does not always surface. libav
/// bitstream readers over-read past the end of a packet buffer by up to this many bytes, so an av_malloc'd
/// packet buffer handed to av_packet_from_data must be over-allocated + zero-padded by this amount.
private let AV_INPUT_BUFFER_PADDING_SIZE_CONST: Int = 64

/// A tiny lock-free-ish boolean flag (an `os_unfair_lock`-free atomic via a serial-safe class). We only need
/// set-once + read-many across threads; a plain `NSLock`-guarded Bool is more than fast enough here and avoids
/// pulling in `Atomics`.
final class ManagedAtomicFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
