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
/// (no file, no disk). `VortXRemuxHLSServer` serves that buffer to AVPlayer as local HLS (the b166 default
/// delivery; the legacy `VortXRemuxResourceLoader` progressive path stays compiled for rollback), so AVPlayer
/// plays TRUE Dolby Vision (Profile 5 / 8.1 / 8.4) out of an MKV that AVFoundation cannot demux directly.
/// Stream-copy re-wraps the exact HEVC access units, so the DV RPU (SEI NALs) + the DOVI config box survive;
/// only the container changes.
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
///   - Audio: AVPlayer-decodable codecs (AAC/AC3/EAC3/ALAC/MP3/FLAC) stream-copy through, always preferred.
///     When a source's ONLY audio is a codec AVPlayer cannot decode (TrueHD, DTS/DTS-HD MA, MLP, Opus,
///     Vorbis, PCM variants), that ONE track is TRANSCODED in-flight by `VortXAudioTranscoder` (EAC3-first,
///     else AAC with today's bundled FFmpeg) so the DV lane no longer bails to libmpv's HDR10 tone-map over
///     audio alone. A source with no decodable AND no transcodable audio still fails fast to libmpv.
///   - Subtitles: never mapped. The mp4 muxer cannot stream-copy Matroska text/PGS subtitle codecs
///     (avformat_write_header fails and kills the whole session); the player's add-on/community subtitle
///     panel covers subtitles on the AVPlayer path.
///
/// This mirrors `MKVRemuxSession`'s proven file-based remux (open input, map video/audio/subtitle streams,
/// `avcodec_parameters_copy`, fragmented-mp4 movflags, `av_read_frame` -> `av_interleaved_write_frame`) but
/// swaps the file sink for `avio_alloc_context` with a write callback appending to the buffer.
///
/// Phase-1 scope: FORWARD-ONLY DELIVERY. The source is read straight through and the produced stream is served
/// forward-only, so AVPlayer scrubbing past buffered content is a documented TODO. The custom AVIO IS seekable on
/// the WRITE side, but ONLY so the muxer can backpatch box-size placeholders once a box length is known (see
/// `avioSeek` / `avioWrite`); it never re-reads and never repositions the source. The remux loop runs on one
/// dedicated background thread; `cancel()` requests a clean stop and the loop tears down in the correct
/// AVIO/AVFormatContext free order.
final class VortXMKVRemuxStream: @unchecked Sendable {

    let buffer = VortXRemuxBuffer()

    private let input: String
    private let headers: [String: String]?
    private var thread: Thread?
    private let cancelledFlag = ManagedAtomicFlag()

    /// AVIO write scratch: libav wants an aligned malloc'd buffer it owns for the AVIO context. The callback's
    /// opaque is an UNRETAINED pointer to `self`, kept alive for the whole session by the remux thread's strong
    /// capture (see `start()`), so the C callback never touches a freed object.
    /// This size NO LONGER bounds correctness. movenc writes every box as a 32-bit size PLACEHOLDER + fourcc and
    /// backpatches it via update_size() -> avio_seek() once the length is known. The AVIO is now WRITE-SEEKABLE
    /// (a real `avioSeek`/`avioWrite` pair), so a backpatch that lands OUTSIDE this buffer rewrites the already-
    /// produced bytes in place (VortXRemuxBuffer.overwrite) instead of failing EPIPE and leaving a size-0 moov.
    /// The old requirement "the whole moov must fit this buffer or its size field ships unpatched" is gone: the
    /// moov (and its children) backpatch correctly at ANY size, and the init segment is read back from the
    /// produced bytes, not from this scratch, so it is deliberately DECOUPLED from hlsHeadCap now. The size is
    /// therefore just the write-flush granularity (bigger = fewer, larger appends). Kept at 4 MiB so every file
    /// whose moov already fit produces bit-identical bytes: those seeks stay in-buffer and never reach avioSeek.
    private static let avioBufferSize = 4 << 20   // 4 MiB; write-flush batch granularity only (not a moov ceiling)

    /// HLS delivery mode (b166). AVFoundation does NOT support a plain progressive fragmented MP4: it treats
    /// the vortxremux:// asset as a regular file, cannot index an open-ended fMP4, and either fails the item
    /// "Cannot Open" or scans forever without producing a frame (the ozdek b165 log: ~0% first-frame rate on
    /// this lane). The one supported way to feed AVPlayer a GROWING fMP4 stream, and the one Apple documents
    /// for Dolby Vision 8.1, is HLS. When this flag is set the stream additionally indexes its own muxed
    /// output into an init segment (ftyp+moov) plus closed media segments (byte ranges + exact durations,
    /// cut by this class at keyframe boundaries), which `VortXRemuxHLSServer` serves to AVPlayer as local
    /// HLS from 127.0.0.1. When false (the legacy vortxremux:// loader path, kept for rollback) none of the
    /// indexing runs and the produced byte stream is byte-identical to before.
    private let hlsIndexingEnabled: Bool

    /// The muxer's logical write position (absolute output offset of the next byte the AVIO layer will hand us).
    /// Mirrors the AVIO context's own `pos`: `avioWrite` advances it by each write, `avioSeek` sets it. When it
    /// is behind the produced high-water mark a write is a box-size BACKPATCH (overwrite already-stored bytes);
    /// at the mark it is a normal forward append. Touched ONLY from the remux thread (movenc calls the AVIO
    /// write/seek callbacks synchronously on it), so it needs no lock.
    private var avioWriteCursor: Int = 0

    init(input: String, headers: [String: String]?, indexForHLS: Bool = false) {
        self.input = input
        self.headers = headers
        self.hlsIndexingEnabled = indexForHLS
    }

    // MARK: - HLS output index (b166; populated only when `hlsIndexingEnabled`)

    /// One closed fMP4 media segment: `byteOffset..<byteOffset+byteLength` of the produced stream, holding
    /// one or more complete moof+mdat pairs, `duration` seconds long (exact, from the muxed video DTS).
    struct HLSSegment {
        let index: Int
        let byteOffset: Int
        let byteLength: Int
        let duration: Double
    }

    /// What the master playlist needs to advertise so tvOS engages TRUE Dolby Vision: the RFC-6381 codec
    /// strings, the DV SUPPLEMENTAL-CODECS compatibility brand, and VIDEO-RANGE. Apple's HLS authoring spec
    /// calls the brand + VIDEO-RANGE mandatory cross-checks for DV 8.1.
    struct HLSSignaling {
        let videoCodec: String         // "hvc1.2.4.L153.B0" (P8) or "dvh1.05.06" (P5)
        let supplementalCodec: String? // "dvh1.08.06/db1p" for P8.1; nil when not applicable
        let videoRange: String?        // "PQ" / "HLG"
        let audioCodec: String?        // "ec-3" / "ac-3" / "mp4a.40.2" / ...
        let width: Int
        let height: Int
        let bandwidth: Int
        let fps: Double                // base video frame rate; 0 when unknown (FRAME-RATE then omitted)
    }

    /// Guards the four published index fields below (written on the remux thread, read from the HLS server's
    /// serve queue). The head-scan / cut state further down is remux-thread-only and needs no lock.
    private let hlsLock = NSLock()
    private var _hlsInitData: Data?
    private var _hlsSegments: [HLSSegment] = []
    private var _hlsEnded = false
    private var _hlsSignaling: HLSSignaling?

    /// Consistent snapshot of the published HLS index for the local server.
    func hlsSnapshot() -> (initData: Data?, segments: [HLSSegment], ended: Bool, signaling: HLSSignaling?) {
        hlsLock.lock(); defer { hlsLock.unlock() }
        return (_hlsInitData, _hlsSegments, _hlsEnded, _hlsSignaling)
    }

    // Init-segment head scan state (remux thread only). Accumulates ONLY the leading top-level box headers until
    // the `moov` box is LOCATED; the init CONTENT (ftyp+moov, any size) is then read straight from the produced
    // buffer (`hlsFinalizeInit`), so the scan is size-agnostic and never has to hold the whole moov. The moov's
    // 32-bit size is usually an UNPATCHED placeholder when first seen (movenc backpatches it after writing the
    // box); `hlsMoovStart` remembers where it is, and the size backpatch (`hlsNoteBackpatch`) publishes the init.
    private var hlsHeadBuf: [UInt8] = []
    private var hlsHeadDone = false
    private var hlsMoovStart: Int?            // absolute offset of the top-level moov box, once its header is seen
    private static let hlsHeadCap = 4 << 20   // cap on the box-header WALK to locate moov (ftyp is tiny, so the
                                              // moov header lands almost immediately); moov CONTENT is unbounded

    // Segment-cut state (remux thread only).
    private var hlsSegmentStartSec: Double?   // first video DTS of the OPEN segment (input timebase seconds)
    private var hlsSegmentStartByte: Int?     // byte offset the open segment starts at (nil until init known)
    private var hlsLastVideoSec: Double = 0   // last written video DTS, for the final segment's duration
    private static let hlsTargetSegmentSecs = 1.0   // cut at the first keyframe past this
    private static let hlsMaxSegmentSecs = 4.0      // hard cut so one long GOP cannot outgrow TARGETDURATION
    /// Byte-size hard cut: the producer parks once (windowFloor + producerLead) bytes are resident, and only
    /// PUBLISHED (closed) segments are readable, so an open segment must never be able to swallow the whole
    /// producer lead (64 MiB) or the pipeline would stall un-publishable at extreme bitrates. 32 MiB keeps
    /// the open tail comfortably under the lead; at sane bitrates the time cuts always fire first.
    private static let hlsMaxSegmentBytes = 32 << 20
    /// The playlist's EXT-X-TARGETDURATION: must be >= every EXTINF and stay constant across reloads.
    static let hlsTargetDuration = 5

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
        // Reasonable network timeouts so a dead debrid link fails instead of hanging the thread forever. Kept
        // at 10s (not longer) so a cold-open timeout PLUS the single warm retry below still lands inside the
        // start-watchdog window rather than tripping a source hop.
        av_dict_set(&openOpts, "rw_timeout", "10000000", 0)   // 10s in microseconds
        // Cap how much the probe reads before classifying. rw_timeout bounds each syscall, but without these
        // avformat_find_stream_info can read many seconds of a high-bitrate 4K DV bitstream off a slow debrid
        // CDN before the DV / audio fail-fast guard below runs, leaving AVPlayer on frameless chrome (no bytes,
        // no error) so the start-watchdog and the AVPlayer -> libmpv demotion cannot fire yet. A few MB / a
        // couple seconds is plenty to read the DOVI config and audio codecs and keeps the pre-start window bounded.
        av_dict_set(&openOpts, "probesize", "5000000", 0)         // ~5 MB
        av_dict_set(&openOpts, "analyzeduration", "2000000", 0)   // 2s in microseconds
        // Debrid CDNs answer with chunked / redirected slow-start responses that FFmpeg's plain HTTP open gives
        // up on (rc=-60), where libmpv, which sets exactly these flags, succeeds on the same URL. Reconnect on
        // transient/network errors and keep the connection persistent across the redirect + range requests so
        // the remux open matches mpv's resilience. Unknown keys are ignored by older protocol builds, not fatal.
        Self.applyDebridHTTPResilience(&openOpts)
        var openRc = avformat_open_input(&ifmt, input, nil, &openOpts)
        av_dict_free(&openOpts)
        // Cold-debrid warm-up retry. The FIRST open of a debrid link frequently fails transiently: it times out
        // (rc=-60 ETIMEDOUT) OR the still-warming CDN answers the first request with HTTP 400 (rc=-808465656,
        // AVERROR_HTTP_BAD_REQUEST) while the provider pulls the file into cache. The first request primes it and
        // an immediate retry connects in a couple seconds; this is exactly why libmpv (which opens the link AFTER
        // our probe demotes) plays where the probe failed. Retry ONCE, on either transient class, with a fresh
        // options dict; a warm retry lands inside the start-watchdog window, a genuinely dead link fails twice
        // and demotes to libmpv HDR10 as before. (400 is the proven cold-CDN class here; ETIMEDOUT already was.)
        if openRc == AVERROR_ETIMEDOUT_CONST || openRc == AVERROR_HTTP_BAD_REQUEST_CONST {
            VXProbe.log("dv", "probe open failed rc=\(openRc) (transient); retrying once (cold-debrid warm-up)")
            var retryOpts: OpaquePointer? = nil
            if let headers, !headers.isEmpty {
                let joined = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
                av_dict_set(&retryOpts, "headers", joined, 0)
            }
            av_dict_set(&retryOpts, "rw_timeout", "10000000", 0)      // 10s on the warm retry
            av_dict_set(&retryOpts, "probesize", "5000000", 0)
            av_dict_set(&retryOpts, "analyzeduration", "2000000", 0)
            Self.applyDebridHTTPResilience(&retryOpts)
            openRc = avformat_open_input(&ifmt, input, nil, &retryOpts)
            av_dict_free(&retryOpts)
            if openRc == 0 { VXProbe.log("dv", "probe open retry SUCCEEDED (warm debrid)") }
        }
        guard openRc == 0, let inCtx = ifmt else {
            // [dv] could not open the source at all (dead debrid link / network / timed out twice) -> libmpv HDR10.
            VXProbe.log("dv", "HDR10 FALLBACK: probe open failed rc=\(openRc)")
            buffer.fail("avformat_open_input failed (\(openRc))")
            return
        }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = inCtx; avformat_close_input(&p) }

        let si = avformat_find_stream_info(inCtx, nil)
        if si < 0 {
            // [dv] opened but could not read stream info -> demote to libmpv HDR10.
            VXProbe.log("dv", "HDR10 FALLBACK: find_stream_info failed rc=\(si)")
            buffer.fail("avformat_find_stream_info failed (\(si))")
            return
        }

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
                // Write callback: route the muxed bytes to the growing buffer (append at the head, or overwrite
                // an already-produced box-size placeholder on a backpatch). Runs on the remux thread.
                guard let opaque, let buf, size > 0 else { return 0 }
                let me = Unmanaged<VortXMKVRemuxStream>.fromOpaque(opaque).takeUnretainedValue()
                if me.isCancelled { return AVERROR_EXIT_CONST }   // abort muxing on cancel
                me.avioWrite(buf, Int(size))
                return size
            },
            { (opaque, offset, whence) -> Int64 in
                // Seek callback: makes the AVIO WRITE-seekable so movenc's update_size() can backpatch box-size
                // placeholders (chiefly the init moov) even after they flush out of the AVIO buffer. Never used
                // to re-read or reposition the source. Runs on the remux thread.
                guard let opaque else { return -1 }
                let me = Unmanaged<VortXMKVRemuxStream>.fromOpaque(opaque).takeUnretainedValue()
                return me.avioSeek(offset, whence)
            }
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
        // Gap A: collect EVERY audio track (not just the first), then pick the best AFTER the scan. A UHD
        // remux commonly orders a stereo or commentary track BEFORE the multichannel bed; picking the first
        // decodable track silently dropped the real (often EAC3-JOC Atmos) audio. Each tuple carries the track's
        // channel count, its stream-copy codec rank, and its language tag (the pick keeps to the source's
        // target language so raising the channel/EAC3 preference can never swap in a same-channel foreign dub).
        // `decodableAudio` = AVPlayer stream-copyable tracks; `transcodableAudio` = FFmpeg-decodable-only tracks
        // that must be transcoded (TrueHD/DTS/... - the b160 lane).
        var decodableAudio: [(index: Int, channels: Int32, rank: Int, lang: String, atmos: Bool)] = []
        var transcodableAudio: [(index: Int, channels: Int32, lang: String)] = []
        // The audio track AVPlayer canNOT decode but the bundled FFmpeg CAN (TrueHD/MLP/DTS/Opus/Vorbis/PCM...,
        // a generic decoder check, no allowlist). Used ONLY when the scan finds no stream-copyable track:
        // stream-copy always beats a transcode. Chosen (below) as the highest-channel transcodable track.
        var transcodeAudioIn = -1
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
                // Collect the track; the single best one is mapped after the scan. Only ONE audio track is ever
                // mapped: a UHD remux can carry 10+ dubs, and mapping several makes the fragmented muxer's
                // delay_moov wait for a first packet from EVERY audio stream before it can write the moov, but
                // frag_keyframe cuts the first fragment at the opening video keyframe before the sparse later
                // tracks deliver one, so the moov write fails ("Cannot write moov before AC3 packets") and the
                // mux aborts. AVPlayer plays one track anyway.
                let audioChannels = par.pointee.ch_layout.nb_channels
                let audioLang = Self.streamLanguage(inStream)
                if Self.avPlayerDecodableAudio.contains(par.pointee.codec_id.rawValue) {
                    // FFmpeg's EAC3 probe sets codecpar.profile to DDP_ATMOS when the bitstream carries the
                    // Dolby Atmos JOC extension; tvOS lights Atmos ONLY from a 5.1-core+JOC E-AC3 track, so
                    // the pick below must prefer this over raw channel count (a 7.1/8ch non-JOC E-AC3 or PCM
                    // track must never shadow the 6ch EAC3-JOC bed).
                    let isAtmosJOC = par.pointee.codec_id == AV_CODEC_ID_EAC3
                        && par.pointee.profile == Self.eac3AtmosProfile
                    decodableAudio.append((i, audioChannels, Self.audioCopyRank(par.pointee.codec_id), audioLang, isAtmosJOC))
                } else if avcodec_find_decoder(par.pointee.codec_id) != nil {
                    transcodableAudio.append((i, audioChannels, audioLang))
                }
            default:
                break   // subtitles/data/attachments are never mapped (see the header note)
            }
        }
        // The target language each pick keeps to: the language of the FIRST track of its OWN kind in scan order,
        // which is exactly the track the old first-decodable / first-transcodable code played. Keeping to it
        // means the new channel/EAC3 ordering reorders only WITHIN that language and can never swap in a
        // same-channel foreign dub. When the source tags no language the demuxer substitutes ONE default value
        // for every track (matroska -> "eng"), so untagged tracks all match and the pick collapses to pure
        // channel/codec order, exactly as intended.
        let decodableTargetLang = decodableAudio.first?.lang ?? ""
        let transcodeTargetLang = transcodableAudio.first?.lang ?? ""
        // Audio pick: keep to the TARGET LANGUAGE first (the original / main-program language), so a
        // higher-channel FOREIGN dub never displaces the original-language track - a Japanese 2.0 original must
        // beat an English 5.1 dub for a sub-watcher, and the remux maps only ONE track so there is no in-player
        // recovery. WITHIN the target language then prefer an EAC3-JOC (Dolby Atmos) track BEFORE raw channel
        // count: tvOS renders Atmos only from a 5.1-core+JOC E-AC3 bed, so a 7.1/8ch non-JOC track (E-AC3 or
        // otherwise) must never shadow the 6ch EAC3-JOC bed. Then the MOST channels, so the real 6-8ch surround
        // bed is never masked by a 1-2ch stereo downmix or commentary ordered ahead of it (the "Atmos plays as
        // stereo" report), then EAC3 (beating AC3, then lossy), then file order.
        var mappedAudioIn = -1
        if let best = decodableAudio.min(by: { a, b in
            let am = a.lang == decodableTargetLang, bm = b.lang == decodableTargetLang
            if am != bm { return am }
            if a.atmos != b.atmos { return a.atmos }
            if a.channels != b.channels { return a.channels > b.channels }
            if a.rank != b.rank { return a.rank < b.rank }
            return a.index < b.index
        }) {
            hasDecodableAudio = true
            mappedAudioIn = best.index
            mappable.insert(best.index)
        }
        // The transcode candidate follows the same target-language-then-highest-channel order (a 5.1 DTS bed in
        // the original language over a 2.0 DTS commentary or a foreign dub), used ONLY when nothing is
        // stream-copyable.
        transcodeAudioIn = transcodableAudio.min(by: { a, b in
            let am = a.lang == transcodeTargetLang, bm = b.lang == transcodeTargetLang
            if am != bm { return am }
            if a.channels != b.channels { return a.channels > b.channels }
            return a.index < b.index
        })?.index ?? -1
        // Insert the transcode candidate into the map ONLY when nothing stream-copyable exists (stream-copy is
        // always preferred over a transcode). `transcodeActive` is the single switch the setup + mux loops key on.
        let transcodeActive = !hasDecodableAudio && transcodeAudioIn >= 0
        if transcodeActive { mappable.insert(transcodeAudioIn) }
        var transcodeAudioName = "none"
        if transcodeActive, let s = inCtx.pointee.streams[transcodeAudioIn], let p = s.pointee.codecpar {
            transcodeAudioName = Self.codecName(p.pointee.codec_id)
        }
        // The exact stream-copied audio track + its channel count + its codec profile (the JOC/Atmos proof),
        // so an on-device probe log reveals whether the multichannel EAC3-JOC bed (not a stereo dub, not a
        // non-JOC track) is what actually reached AVPlayer.
        var mappedAudioName = "none"
        if hasDecodableAudio, mappedAudioIn >= 0, let s = inCtx.pointee.streams[mappedAudioIn], let p = s.pointee.codecpar {
            let profile = p.pointee.profile
            let joc = p.pointee.codec_id == AV_CODEC_ID_EAC3 && profile == Self.eac3AtmosProfile
            mappedAudioName = "\(Self.codecName(p.pointee.codec_id))/\(p.pointee.ch_layout.nb_channels)ch profile=\(profile) joc=\(joc)"
            // Arm the one-time dec3 verification scan for a stream-copied E-AC3 track: the produced init
            // segment's dec3 box must carry the JOC extension for tvOS to light Atmos, and the log proves in
            // one diagnostics export whether the muxer wrote it (see scanForDec3). Message-only, fail-soft.
            if p.pointee.codec_id == AV_CODEC_ID_EAC3 { dec3ScanDone = false }
        }
        // [dv] classify probe: one greppable line of what the source actually carries (DV profile, dims, and
        // the audio codecs seen / whether any is AVPlayer-decodable). This is the line that explains WHY a DV
        // source did or did not stay on the true-DV AVPlayer lane. Gated, so free in shipping builds.
        VXProbe.log("dv", "remux classify \(info.width)x\(info.height) dvProfile=\(info.dvProfile) blCompat=\(info.dvBLCompatId) audio=[\(audioSeen.joined(separator: ","))] decodableAudio=\(hasDecodableAudio) mappedAudio=\(mappedAudioName) transcodeAudio=\(transcodeAudioName)")

        // The forced 'hvc1' sample entry (below) requires the HEVC parameter sets (VPS/SPS/PPS) OUT-OF-BAND
        // in the sample entry's hvcC box. Validate the base track's extradata NOW, before the packet pre-scan,
        // so a deficient record (WEB-DL-derived MKVs whose CodecPrivate carries EMPTY parameter-set arrays, or
        // no usable record at all, with the parameter sets riding in-band instead) can be repaired from the
        // first access unit's in-band parameter sets. Without this, movenc's mov_write_hvcc_tag IGNORES
        // ff_isom_write_hvcc's AVERROR_INVALIDDATA and writes an EMPTY hvcC into an otherwise-valid moov
        // (verified against the shipped libavformat 62); AVPlayer then cannot build a video format description
        // ('hvc1' forbids the in-band parameter-set fallback 'hev1' allows) and fails the mounted item with
        // "Cannot Open", the SLOW demotion. This is why one DV P8 MKV failed post-mount while others played.
        var hvc1Check = Hvc1ExtradataCheck()
        hvc1Check.eligible = true   // non-HEVC / no-video default: the guards below act only on a real HEVC failure
        if baseVideoIn >= 0, let bpar = inCtx.pointee.streams[baseVideoIn]?.pointee.codecpar,
           bpar.pointee.codec_id == AV_CODEC_ID_HEVC {
            hvc1Check = Self.checkHvc1Extradata(bpar)
        }
        // In-band VPS/SPS/PPS harvested from the first base-video access unit (raw NALs), used to REBUILD the
        // output hvcC when the source's CodecPrivate carries empty parameter-set arrays. nil = not needed,
        // or nothing usable was found (the stream setup then fails fast, BEFORE write_header).
        var hvc1Harvest: (nals: [(type: UInt8, bytes: [UInt8])], vps: Int, sps: Int, pps: Int)? = nil

        // Profile 5 / 8.x are single-layer and stream-copy straight through (pure re-wrap, RPU untouched).
        // Profile 7 (BL+EL, ~every UHD-BluRay DV rip) has no VideoToolbox dual-layer decode, so we CONVERT its
        // RPU to Profile 8.1 and drop the EL (see the mux loop). A stream with no DOVI config (the filename
        // label lied) still gains nothing from AVPlayer and fails fast to the libmpv tone-map.
        // The matroska demuxer only surfaces a DOVI config from a container dvcC/dvvC BlockAdditionMapping. A
        // source that labels DV solely via IN-BAND HEVC RPU NALs (UNSPEC62) leaves dvProfile at -1 above, and
        // real Stremio (mpv, which reads the in-band RPU) still shows DV. When the container gave no profile,
        // probe the bitstream: read a bounded run of packets into a small buffer (NO av_seek - the debrid HTTP
        // AVIO is not reliably byte-seekable) and read the profile from the FIRST base-video packet's RPU. Those
        // packets are DRAINED into the mux loop below (in order) so nothing is re-read and no rewind is needed;
        // a function-scope defer frees any packet the mux loop never got to (early return / non-DV fall-through).
        var prebuffered: [UnsafeMutablePointer<AVPacket>] = []
        defer { for p in prebuffered { var pp: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&pp) } }
        // The pre-scan also runs when the base track's extradata cannot yield a valid hvcC (not only when the
        // DV profile is unknown): the SAME first access unit that would carry an in-band RPU also carries the
        // in-band VPS/SPS/PPS a parameter-sets-in-band stream repeats ahead of its IDR slice, so one bounded,
        // seek-free read serves both needs. Files whose extradata is already hvc1-ready skip this exactly as
        // before, so nothing that opens today reads a single extra packet.
        if baseVideoIn >= 0, info.dvProfile < 0 || !hvc1Check.eligible {
            let scanNalLen = Self.hevcNalLengthSize(inCtx.pointee.streams[baseVideoIn]?.pointee.codecpar)
            let maxScan = 240   // well within probesize; caps memory + reads if the base-video packet is late/absent
            var scanned = 0
            while scanned < maxScan, !isCancelled {
                guard let p = av_packet_alloc() else { break }
                if av_read_frame(inCtx, p) < 0 { var pp: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&pp); break }
                scanned += 1
                prebuffered.append(p)
                if Int(p.pointee.stream_index) == baseVideoIn {
                    if info.dvProfile < 0 {
                        let prof = Self.inBandDoViProfile(p, nalLengthSize: scanNalLen)
                        if prof >= 0 {
                            info.dvProfile = prof
                            VXProbe.log("dv", "in-band RPU detected dvProfile=\(prof) (no container DOVI config)")
                        }
                    }
                    // Extradata repair harvest: collect the access unit's raw VPS/SPS/PPS NALs so the stream
                    // setup below can rebuild the output hvcC's parameter-set arrays in place. NOT Annex-B
                    // extradata (the b164 shape): movenc treats Annex-B extradata as proof the BITSTREAM is
                    // Annex-B too and runs ff_hevc_annexb2mp4 over every already-length-prefixed packet
                    // (movenc.c:6851-6861), which would corrupt every sample. A failed walk just leaves the
                    // harvest nil; the setup loop then fails fast BEFORE write_header rather than mux a moov
                    // AVPlayer cannot open.
                    if !hvc1Check.eligible {
                        hvc1Harvest = Self.harvestParameterSets(p, nalLengthSize: scanNalLen)
                    }
                    break   // decided on the first base-video packet either way
                }
            }
        }

        let convertP7 = (info.dvProfile == 7)
        guard info.dvProfile == 5 || info.dvProfile == 8 || convertP7 else {
            // [dv] the DV source is not an AVPlayer-decodable profile -> fail fast so the chrome demotes to
            // libmpv HDR10. Logs the exact reason (no DOVI config vs an undecodable profile like 4/9).
            VXProbe.log("dv", "HDR10 FALLBACK: dvProfile=\(info.dvProfile) not AVPlayer-decodable")
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
        // AVPlayer cannot decode TrueHD/DTS, but a TrueHD/DTS-only source no longer fails here: its one audio
        // track is transcoded in-flight (see `transcodeActive`), which was the DOMINANT real-world reason a
        // premium 4K DV remux tone-mapped to HDR10. Only a source with NO decodable and NO transcodable audio
        // (or none at all) still fails fast so the chrome demotes to libmpv, which decodes everything.
        guard hasDecodableAudio || transcodeActive else {
            VXProbe.log("dv", "HDR10 FALLBACK: no AVPlayer-decodable or transcodable audio, source=[\(audioSeen.joined(separator: ","))]")
            buffer.fail("no AVPlayer-decodable audio track (source audio: \(audioSeen.joined(separator: ",")))")
            return
        }
        var streamMap = [Int](repeating: -1, count: nb)
        var outIndex: Int32 = 0
        var baseVideoOut = -1        // output index of the base-layer video track (packets to convert)
        // The one-track audio transcoder (TrueHD/DTS/... -> EAC3-or-AAC), created in the setup loop below when
        // `transcodeActive`. Owns its decoder/encoder/resampler; its deinit cleans up on every exit path.
        var transcoder: VortXAudioTranscoder? = nil
        for i in 0..<nb where mappable.contains(i) {
            guard let inStream = inCtx.pointee.streams[i] else { continue }
            let par = inStream.pointee.codecpar
            guard let outStream = avformat_new_stream(outCtx, nil) else { VXProbe.log("dv", "HDR10 FALLBACK: avformat_new_stream returned nil (inStream=\(i))"); buffer.fail("avformat_new_stream returned nil"); return }
            if transcodeActive, i == transcodeAudioIn {
                // Transcode track: the transcoder stamps outStream.codecpar (incl. a real frame_size, so the
                // frame_size fixup below is bypassed) INSTEAD of avcodec_parameters_copy. Fail-soft: a source
                // whose decoder/encoder cannot open demotes to libmpv exactly like the old no-audio bail.
                guard let par,
                      let t = VortXAudioTranscoder(sourcePar: par, outStream: outStream,
                                                   sourceTimeBase: inStream.pointee.time_base,
                                                   globalHeader: true) else {
                    VXProbe.log("dv", "HDR10 FALLBACK: audio transcode init failed (inStream=\(i), codec=\(transcodeAudioName))")
                    buffer.fail("audio transcode init failed (source audio: \(audioSeen.joined(separator: ",")))")
                    return
                }
                transcoder = t
                VXProbe.log("dv", "audio transcode armed: \(transcodeAudioName) -> \(t.encoderName) (inStream=\(i))")
                streamMap[i] = Int(outIndex)
                outIndex += 1
                info.mappedStreams += 1
                continue
            }
            let cp = avcodec_parameters_copy(outStream.pointee.codecpar, par)
            if cp < 0 { VXProbe.log("dv", "HDR10 FALLBACK: avcodec_parameters_copy rc=\(cp) (inStream=\(i))"); buffer.fail("avcodec_parameters_copy failed (\(cp))"); return }
            outStream.pointee.codecpar.pointee.codec_tag = 0
            if i == baseVideoIn {
                baseVideoOut = Int(outIndex)
                // DV HEVC in mp4 MUST use the 'hvc1' sample entry (parameter sets out-of-band in hvcC). A Dolby
                // Vision config box (dvcC/dvvC) on an 'hev1' entry (in-band parameter sets) is rejected by
                // movenc's mov_init with EINVAL, and the codec_tag=0 above lets the muxer derive 'hev1' for some
                // Profile 7 rips - which is exactly the write_header rc=-22 we hit only on convertP7. Force
                // 'hvc1' (MKTAG little-endian) on the base video so the DV config box sits on a valid entry.
                outStream.pointee.codecpar.pointee.codec_tag =
                    UInt32(UInt8(ascii: "h")) | UInt32(UInt8(ascii: "v")) << 8
                    | UInt32(UInt8(ascii: "c")) << 16 | UInt32(UInt8(ascii: "1")) << 24
                // 'hvc1' is only valid when the hvcC box carries the parameter sets OUT-OF-BAND, and movenc
                // does NOT enforce that: it ignores ff_isom_write_hvcc's error and writes an EMPTY hvcC, a
                // structurally-fine moov AVPlayer then fails with "Cannot Open" AFTER mounting. So when the
                // source extradata cannot produce a valid hvcC (validated in the classify step), REBUILD the
                // hvcC: keep the source record's header bytes (profile/tier/level/lengthSize, which the
                // WEB-DL-derived MKVs this repairs carry correctly even with empty arrays) and graft in the
                // parameter sets harvested from the first access unit. NEVER install Annex-B extradata here:
                // movenc takes Annex-B extradata as proof the bitstream is Annex-B too and would run
                // ff_hevc_annexb2mp4 over the already-length-prefixed packets, corrupting every sample (the
                // b164 latent bug). If no rebuild is possible, fail fast BEFORE write_header, the same
                // fail-soft shape as the no-audio bail above: the chrome demotes to libmpv within the probe
                // window, quickly and cleanly, instead of after a mounted-then-rejected AVPlayer item.
                if !hvc1Check.eligible {
                    if let h = hvc1Harvest,
                       let rebuilt = Self.buildRepairedHvcC(source: outStream.pointee.codecpar, nals: h.nals),
                       Self.installExtradata(outStream.pointee.codecpar, rebuilt) {
                        DiagnosticsLog.log("dv", "hvc1 extradata repaired: hvcC arrays rebuilt from in-band parameter sets vps=\(h.vps) sps=\(h.sps) pps=\(h.pps) hvcC=\(rebuilt.count)B (source extradata \(hvc1Check.form)/\(hvc1Check.size)B vps=\(hvc1Check.vps) sps=\(hvc1Check.sps) pps=\(hvc1Check.pps))")
                    } else {
                        DiagnosticsLog.log("dv", "remux output rejected pre-mux: hvc1 needs out-of-band VPS/SPS/PPS and the source has none usable (extradata \(hvc1Check.form)/\(hvc1Check.size)B vps=\(hvc1Check.vps) sps=\(hvc1Check.sps) pps=\(hvc1Check.pps); in-band harvest empty or not hvcC-rebuildable) -> demoting to libmpv HDR10")
                        VXProbe.log("dv", "HDR10 FALLBACK: hvc1 parameter sets unavailable (extradata \(hvc1Check.form)/\(hvc1Check.size)B vps=\(hvc1Check.vps) sps=\(hvc1Check.sps) pps=\(hvc1Check.pps))")
                        buffer.fail("HEVC parameter sets unavailable for the hvc1 sample entry")
                        return
                    }
                }
                // For a Profile 7 conversion, re-label the OUTPUT DOVI configuration record as Profile 8.1 so
                // FFmpeg's mov muxer writes a Profile-8 `dvvC` box (dv_profile>7 selects dvvC) and AVPlayer
                // engages true DV. The RPU itself is converted per-packet in the mux loop; this makes the
                // container box agree with the converted bitstream. The EL-present flag is cleared in the relabel.
                if convertP7 {
                    Self.sanitizeOutputDoVi(outStream.pointee.codecpar, relabelProfile81: true)
                } else {
                    // P5 / P8 stream-copy lane: sanitize only the structural fields (version, level, el/rpu/bl
                    // present), WITHOUT relabeling the profile/compatibility id and WITHOUT touching
                    // md_compression. The source record used to ride through verbatim here, so a hybrid
                    // dovi_tool-injected rip carrying el_present=1 or dv_level=0 produced a dvvC AVPlayer's
                    // strict open-time parser can refuse; those structural forces are proven no-ops on a
                    // conformant source and corrective on a malformed one. md_compression is left at the source
                    // value because this lane copies the RPU byte-for-byte (rewriting the box to NONE would
                    // desync it from a metadata-compressed bitstream); the common rip is already NONE, so the
                    // box stays byte-identical to today for it.
                    Self.sanitizeOutputDoVi(outStream.pointee.codecpar, relabelProfile81: false)
                }
                // The mov muxer writes the dvcC/dvvC box and the dby1 ftyp brand ONLY from an
                // AV_PKT_DATA_DOVI_CONF record on the output codecpar; it never parses the bitstream RPUs to
                // derive one. A source that signalled Dolby Vision solely through in-band HEVC RPUs (no
                // container dvcC/dvvC) reaches here with no such record, so both sanitize calls above were
                // no-ops: without synthesis the moov ships as plain HEVC and AVPlayer decodes it as HDR10
                // silently. Build the record the muxer needs from the fields already known (converted-to-8.1
                // for a P7 source, else the detected profile). It is built already-conformant, so
                // sanitizeOutputDoVi is NOT re-run over it.
                if !Self.hasDoViSideData(outStream.pointee.codecpar) {
                    Self.attachSyntheticDoVi(outStream.pointee.codecpar,
                                             profile: convertP7 ? 8 : info.dvProfile,
                                             width: info.width, height: info.height,
                                             fps: Self.frameRate(inStream))
                }
            }
            // fMP4 requires each AUDIO track to carry a frame_size; a matroska stream-copy usually leaves it 0,
            // and movenc then rejects write_header with EINVAL ("track N: codec frame size is not set"). This,
            // NOT the DV config box, is the real Profile-7 write_header failure (the source's AC3 tracks all
            // report frame_size 0). Set the codec's known constant when absent so the mov muxer accepts them.
            if outStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO,
               outStream.pointee.codecpar.pointee.frame_size == 0 {
                switch outStream.pointee.codecpar.pointee.codec_id {
                case AV_CODEC_ID_AAC: outStream.pointee.codecpar.pointee.frame_size = 1024
                case AV_CODEC_ID_MP3: outStream.pointee.codecpar.pointee.frame_size = 1152
                default: outStream.pointee.codecpar.pointee.frame_size = 1536   // AC3/EAC3, and a safe non-zero fallback
                }
            }
            streamMap[i] = Int(outIndex)
            outIndex += 1
            info.mappedStreams += 1
        }
        if info.mappedStreams == 0 { VXProbe.log("dv", "HDR10 FALLBACK: no playable streams mapped"); buffer.fail("no playable streams in source"); return }
        if convertP7, baseVideoOut < 0 { VXProbe.log("dv", "HDR10 FALLBACK: P7 base-layer video not mapped (baseVideoIn=\(baseVideoIn))"); buffer.fail("Dolby Vision profile 7 base-layer video was not mapped"); return }

        // The HEVC NAL length prefix size (1/2/4 bytes) lives in the base track's hvcC extradata; read it once
        // so the per-packet RPU converter can walk the length-prefixed access units. Defaults to 4 (the near
        // universal value) if extradata is missing or malformed.
        let nalLengthSize: Int = convertP7
            ? Self.hevcNalLengthSize(inCtx.pointee.streams[baseVideoIn]?.pointee.codecpar)
            : 4

        // Fragmented MP4 so playback starts before the whole file is muxed, and so it can stream. `faststart`
        // is a no-op for custom-IO (it needs a seekable sink) but harmless; the frag flags are what matter.
        var opts: OpaquePointer? = nil   // AVDictionary*
        // delay_moov is REQUIRED here: with empty_moov the muxer would try to write the moov at write_header,
        // but an AC3 audio track's parameters are only known once the first AC3 packet arrives, so movenc
        // rejects write_header with EINVAL ("Cannot write moov atom before AC3 packets. Set the delay_moov flag
        // to fix this."). delay_moov defers the moov to the first fragment, which is exactly what fMP4 wants.
        // TIME-BASED FRAGMENTATION (NO frag_keyframe) is what finally lets a P7-with-AC3 DV remux PLAY, not just
        // write_header. frag_keyframe cuts the first fragment at the opening video keyframe, and delay_moov then
        // serializes the moov there BEFORE the AC3 track has delivered a packet, so movenc's dac3 writer (which
        // needs a parsed AC3 packet: track->eac3_priv->ec3_done, it never reads extradata) aborts with "Cannot
        // write moov before AC3 packets". A time-based cut lets av_interleaved_write_frame deliver the AC3
        // track's first packet (DTS-ordered) into the muxer before the ~1s fragment flush, so the moov gets a
        // valid dac3 box. frag_duration (the max-fragment-duration TRIGGER) is REQUIRED, not min_frag_duration
        // (a floor only): movenc re-adds frag_keyframe in mov_write_header when there is no cut trigger, silently
        // restoring the keyframe cut. Verified against libavformat 62.12.101 (the exact lib this app ships).
        av_dict_set(&opts, "movflags", "empty_moov+default_base_moof+delay_moov", 0)
        av_dict_set(&opts, "frag_duration", "1000000", 0)   // 1s fragments in microseconds (the cut TRIGGER)
        // FLAC-in-mp4 is spec'd (and AVPlayer decodes it) but FFmpeg's mov muxer gates it behind strict
        // experimental; without this a FLAC-audio DV MKV would die at avformat_write_header.
        av_dict_set(&opts, "strict", "experimental", 0)
        defer { av_dict_free(&opts) }

        // [dv] one-line dump of exactly what the muxer is about to validate, for EVERY DV lane (it was
        // convertP7-gated once, which left a failing P8 stream-copy with zero visibility into precisely the
        // fields that matter): the base-video sample-entry fourcc (must be hvc1 for a DV config box, NOT
        // hev1), the output dimensions, the DOVI record fields, and the hvcC parameter-set counts from the
        // OUTPUT extradata (post-repair). Disambiguates a codec_tag problem from a record-field problem from
        // an empty-hvcC problem in a single device log export, whether write_header then succeeds or fails.
        // DiagnosticsLog (not the gated probe) so an owner export always carries it.
        if baseVideoOut >= 0, let vpar = outCtx.pointee.streams[baseVideoOut]?.pointee.codecpar {
            let tag = vpar.pointee.codec_tag
            let fourcc = String(bytes: [UInt8(tag & 0xFF), UInt8((tag >> 8) & 0xFF),
                                        UInt8((tag >> 16) & 0xFF), UInt8((tag >> 24) & 0xFF)],
                                encoding: .ascii) ?? "?"
            var prof = -1, maj = -1, lvl = -1, comp = -1, blc = -1, elp = -1
            let n = Int(vpar.pointee.nb_coded_side_data)
            if n > 0, let arr = vpar.pointee.coded_side_data {
                for i in 0..<n where arr[i].type == AV_PKT_DATA_DOVI_CONF {
                    if let d = arr[i].data {
                        d.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { r in
                            prof = Int(r.pointee.dv_profile)
                            maj = Int(r.pointee.dv_version_major); lvl = Int(r.pointee.dv_level)
                            comp = Int(r.pointee.dv_md_compression)
                            blc = Int(r.pointee.dv_bl_signal_compatibility_id); elp = Int(r.pointee.el_present_flag)
                        }
                    }
                }
            }
            let ex = Self.checkHvc1Extradata(vpar)
            DiagnosticsLog.log("dv", "pre-write_header video tag=\(fourcc) \(vpar.pointee.width)x\(vpar.pointee.height) dvProfile=\(prof) dvMaj=\(maj) dvLevel=\(lvl) blCompat=\(blc) el=\(elp) mdComp=\(comp) extradata=\(ex.form)/\(ex.size)B vps=\(ex.vps) sps=\(ex.sps) pps=\(ex.pps) hvc1Ready=\(ex.eligible)")
        }

        let wh = avformat_write_header(outCtx, &opts)
        if wh < 0 { VXProbe.log("dv", "HDR10 FALLBACK: avformat_write_header rc=\(wh) (convertP7=\(convertP7); the relabel-8.1 dvvC box or the fMP4 muxer rejected the mapped streams)"); buffer.fail("avformat_write_header failed (\(wh))"); return }

        // HLS lane: publish the master-playlist signaling now that the OUTPUT streams are final (post
        // extradata repair + DOVI sanitize/relabel). The local server blocks its master.m3u8 answer on this.
        if hlsIndexingEnabled { hlsBuildSignaling(outCtx: outCtx, inCtx: inCtx, info: info, baseVideoOut: baseVideoOut, baseVideoIn: baseVideoIn) }

        guard let pkt = av_packet_alloc() else { buffer.fail("av_packet_alloc returned nil"); return }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }

        NSLog("[dv-remux-stream] start: %@ %dx%d dvProfile=%d blCompat=%d streams=%d convertP7=%d nalLen=%d",
              info.videoCodec, info.width, info.height, info.dvProfile, info.dvBLCompatId,
              info.mappedStreams, convertP7 ? 1 : 0, nalLengthSize)

        // [dv] tally the P7->8.1 RPU conversion outcome across the whole session and emit ONE greppable summary
        // on every exit (trailer, cancel, or an AVPlayer-rejected write that breaks the loop). This is the line
        // that distinguishes "libdovi converted fine, AVPlayer still refused it" from "libdovi rejected the RPU".
        var rpuStats = RPUConvStats()
        defer {
            if convertP7 {
                VXProbe.log("dv", "P7 RPU convert exit: converted=\(rpuStats.rpuConverted) fellBack=\(rpuStats.rpuFellBack) elDropped=\(rpuStats.elDropped) pktBailed=\(rpuStats.pktBailed) bytes=\(buffer.producedCount)")
            }
        }

        // AVERROR_EOF = FFERRTAG('E','O','F',' ') = -541478725. Distinguish a genuine end-of-stream from a
        // MID-STREAM read failure (a debrid CDN dropping mid-film once the reconnect attempts are exhausted).
        // The old `av_read_frame >= 0` loop condition treated BOTH as EOF and fell through to write_trailer +
        // buffer.finish(), so a truncated stream ended playback cleanly with no error and no AVPlayer -> libmpv
        // demotion. A mid-stream error now fails the buffer so the loader errors the request and the chrome
        // can re-open the link on libmpv.
        // Drain the DV-detection read-ahead packets FIRST, in order, before any live read. Each was
        // av_packet_alloc'd in the pre-scan; the per-iteration defer frees it however this iteration exits, and
        // removeFirst drops it from `prebuffered` so the function-scope defer never double-frees it. This is the
        // seek-free half: the buffered packets are the exact bytes the loop would have read, so muxing them in
        // order reproduces a full stream. Same streamMap / convertP7 / rescale path as the live loop below.
        while !prebuffered.isEmpty, !isCancelled {
            let p = prebuffered.removeFirst()
            defer { var pp: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&pp) }
            let inIdx = Int(p.pointee.stream_index)
            guard inIdx >= 0, inIdx < nb, streamMap[inIdx] >= 0,
                  let inStream = inCtx.pointee.streams[inIdx],
                  let outStream = outCtx.pointee.streams[streamMap[inIdx]] else { continue }
            let outIdx = streamMap[inIdx]
            // Transcode-track packets go through the transcoder (which decodes, re-encodes, and stamps
            // stream_index + timestamps itself), NEVER the stream-copy rescale below.
            if let transcoder, inIdx == transcodeAudioIn {
                guard transcoder.feed(p, write: { av_interleaved_write_frame(outCtx, $0) }) else {
                    if isCancelled { break }
                    DiagnosticsLog.log("dv", "audio transcode feed FAILED preMoov=\(buffer.producedCount == 0) [prebuffered drain]")
                    buffer.fail("audio transcode failed mid-stream [prebuffered drain]")
                    return
                }
                continue
            }
            if convertP7, outIdx == baseVideoOut {
                Self.convertPacketRPUToProfile81(p, nalLengthSize: nalLengthSize, stats: &rpuStats)
            }
            // HLS lane: cut a segment boundary BEFORE this video packet when the open segment is long enough.
            if hlsIndexingEnabled, outIdx == baseVideoOut {
                hlsMaybeCut(outCtx: outCtx, pkt: p, timeBase: inStream.pointee.time_base)
            }
            p.pointee.stream_index = Int32(outIdx)
            av_packet_rescale_ts(p, inStream.pointee.time_base, outStream.pointee.time_base)
            p.pointee.pos = -1
            let wf = av_interleaved_write_frame(outCtx, p)
            if wf < 0 {
                if isCancelled { break }
                // Case-A visibility (#76 b166): this abort used to be the ONLY silent death path between
                // write_header and the delayed moov, so ozdek's "Cannot Open ~130ms after write_header" plays
                // carried no clue which stream/rc killed the mux. preMoov=true means AVPlayer got ZERO bytes.
                DiagnosticsLog.log("dv", "av_interleaved_write_frame FAILED rc=\(wf) stream=\(outIdx == baseVideoOut ? "video" : "audio") outIdx=\(outIdx) preMoov=\(buffer.producedCount == 0) [prebuffered drain]")
                buffer.fail("av_interleaved_write_frame failed (\(wf)) [prebuffered drain]")
                return
            }
        }

        let AVERROR_EOF_CONST: Int32 = -541478725
        var readRetries = 0
        let maxReadRetries = 4
        while !isCancelled {
            let rf = av_read_frame(inCtx, pkt)
            if rf < 0 {
                if rf == AVERROR_EOF_CONST { break }   // genuine EOF: write the trailer + finish() below
                if isCancelled { break }
                // A debrid CDN stall/drop mid-stream (rw_timeout rc=-60, or EIO) returns a non-EOF error. The
                // reconnect flags re-establish the connection, so RETRY the read a few times before giving up,
                // rather than failing on the first stall - libmpv tolerates the same chunked/slow debrid delivery
                // and plays these links fine, which is why DV that classified + wrote its header still stopped
                // early (8 MB, or 0 bytes). A genuinely dead link errors every retry and then demotes to libmpv.
                readRetries += 1
                if readRetries <= maxReadRetries {
                    VXProbe.log("dv", "mid-stream read rc=\(rf), retry \(readRetries)/\(maxReadRetries)")
                    continue
                }
                buffer.fail("source read failed mid-stream (rc=\(rf)) after \(maxReadRetries) retries")
                return
            }
            readRetries = 0   // a successful read resets the streak
            let inIdx = Int(pkt.pointee.stream_index)
            guard inIdx >= 0, inIdx < nb, streamMap[inIdx] >= 0,
                  let inStream = inCtx.pointee.streams[inIdx],
                  let outStream = outCtx.pointee.streams[streamMap[inIdx]] else {
                av_packet_unref(pkt); continue
            }
            let outIdx = streamMap[inIdx]
            // Transcode-track packets go through the transcoder (which stamps stream_index + timestamps
            // itself), never the stream-copy rescale. Fail-soft: a mid-stream decode/encode/write error fails
            // the buffer for the same AVPlayer -> libmpv demotion as a stream-copy write failure.
            if let transcoder, inIdx == transcodeAudioIn {
                let fed = transcoder.feed(pkt, write: { av_interleaved_write_frame(outCtx, $0) })
                av_packet_unref(pkt)
                if !fed {
                    if isCancelled { break }
                    DiagnosticsLog.log("dv", "audio transcode feed FAILED preMoov=\(buffer.producedCount == 0)")
                    buffer.fail("audio transcode failed mid-stream")
                    return
                }
                continue
            }
            // Profile 7 -> 8.1: rewrite the DV RPU NAL (and drop any in-band EL sublayer NAL) in the base-layer
            // video packets before muxing. Only the base video track is touched; audio and every other packet
            // pass through byte-for-byte. Conversion is fail-SOFT: on any error the packet's bytes are left
            // exactly as read, so a quirk in one access unit degrades to a possibly-imperfect frame rather than
            // aborting the whole session (the AVPlayer -> libmpv demotion remains the hard backstop).
            if convertP7, outIdx == baseVideoOut {
                Self.convertPacketRPUToProfile81(pkt, nalLengthSize: nalLengthSize, stats: &rpuStats)
            }
            // HLS lane: cut a segment boundary BEFORE this video packet when the open segment is long enough.
            if hlsIndexingEnabled, outIdx == baseVideoOut {
                hlsMaybeCut(outCtx: outCtx, pkt: pkt, timeBase: inStream.pointee.time_base)
            }
            pkt.pointee.stream_index = Int32(outIdx)
            av_packet_rescale_ts(pkt, inStream.pointee.time_base, outStream.pointee.time_base)
            pkt.pointee.pos = -1
            let wf = av_interleaved_write_frame(outCtx, pkt)
            av_packet_unref(pkt)
            if wf < 0 {
                if isCancelled { break }     // our write callback returned EXIT; expected on cancel
                // Case-A visibility (#76 b166): the one silent death path between write_header and the delayed
                // moov. preMoov=true means AVPlayer got ZERO bytes when the item then fails "Cannot Open"; the
                // rc + stream name the exact movenc rejection (expected: handle_eac3 on unparseable DDP).
                DiagnosticsLog.log("dv", "av_interleaved_write_frame FAILED rc=\(wf) stream=\(outIdx == baseVideoOut ? "video" : "audio") outIdx=\(outIdx) preMoov=\(buffer.producedCount == 0)")
                buffer.fail("av_interleaved_write_frame failed (\(wf))")
                return
            }
        }

        if isCancelled {
            NSLog("[dv-remux-stream] cancelled after %d bytes", buffer.producedCount)
            // buffer already marked failed("cancelled") by cancel(); defers handle libav teardown.
            return
        }

        // EOF: drain the transcoder's decoder/FIFO/encoder tail into the muxer BEFORE the trailer so the last
        // second of audio is not lost. Best-effort (the file already reached EOF; the trailer is still written).
        if let transcoder {
            _ = transcoder.flush(write: { av_interleaved_write_frame(outCtx, $0) })
        }
        // Flush the muxer trailer (writes the final fragment metadata), then mark the buffer complete.
        av_write_trailer(outCtx)
        if hlsIndexingEnabled {
            // Close the final segment (write_trailer flushed the last fragment + the AVIO tail) and mark the
            // playlist ended so the server can append EXT-X-ENDLIST. Duration is a safe estimate for the tail.
            avio_flush(outCtx.pointee.pb)
            hlsCloseSegment(endSec: hlsLastVideoSec + Self.hlsTargetSegmentSecs)
            hlsLock.lock(); _hlsEnded = true; hlsLock.unlock()
        }
        buffer.finish()
        NSLog("[dv-remux-stream] done: %d bytes muxed", buffer.producedCount)
    }

    // MARK: - Custom AVIO write/seek (the muxer's file emulation; remux-thread only)

    /// AVIO write callback body. Routes `count` muxed bytes to the buffer at the current `avioWriteCursor`:
    /// a forward write at (or beyond) the produced high-water mark APPENDS; a write behind it is movenc
    /// backpatching a box-size placeholder, so it OVERWRITES the already-stored bytes in place. The muxer only
    /// ever seeks back to rewrite a size field it already emitted, so the overwrite target is always within the
    /// produced region (and, before the init is published, always still resident). Cursor advances by `count`,
    /// mirroring the AVIO context's own `pos`. The one-time Atmos (dec3) scan and the HLS init-head walk run on
    /// the forward-append path only, where bytes arrive in order; a backpatch feeds neither (it only corrects a
    /// size field), except that patching the moov's own size finalizes the init segment (hlsNoteBackpatch).
    private func avioWrite(_ buf: UnsafePointer<UInt8>, _ count: Int) {
        let cursor = avioWriteCursor
        let head = buffer.producedCount   // produced high-water mark (overwrite never advances it)
        if cursor >= head {
            // Forward write at the head (cursor == head is the only shape movenc produces; a cursor strictly
            // beyond head would require a seek past EOF then a write, which it never does with these movflags).
            buffer.append(buf, count: count)
            scanForDec3(buf, count: count)   // one-time Atmos-signaling verification; no-op once done
            hlsIndexHead(buf, count: count)  // HLS lane: locate the ftyp+moov init segment; no-op once done
        } else {
            // Backpatch: rewrite an already-produced box-size placeholder now that the box length is known.
            let overlap = min(count, head - cursor)
            if buffer.overwrite(at: cursor, bytes: buf, count: overlap) {
                hlsNoteBackpatch(at: cursor, bytes: buf, count: overlap)
            } else if hlsIndexingEnabled, !hlsHeadDone {
                // A backpatch below the sliding window BEFORE the init is even published should be impossible
                // (nothing is served or evicted pre-init). If it ever happens the init is likely doomed; surface
                // it once. After the init is published (hlsHeadDone) a dropped backpatch is the expected, harmless
                // trailer-time case (an evicted moov/mehd patch movenc ignores anyway), so it stays silent.
                DiagnosticsLog.log("dv", "hls init: box-size backpatch at \(cursor) fell below the window (pre-init eviction?)")
            }
            // A pure size patch never spills past the head; stay total in case a future movflag ever does.
            if count > overlap {
                let tail = buf + overlap
                buffer.append(tail, count: count - overlap)
                scanForDec3(tail, count: count - overlap)
                hlsIndexHead(tail, count: count - overlap)
            }
        }
        avioWriteCursor += count
    }

    /// AVIO seek callback body. movenc drives this ONLY to backpatch box-size placeholders (update_size seeks
    /// back to a box start, rewrites its 32-bit size, then seeks forward to resume). We emulate a file cursor:
    /// SEEK_SET/CUR/END move `avioWriteCursor` and the next writes land there (patching produced bytes via
    /// avioWrite's overwrite path, or appending at the head). Returning a valid offset is what sets the context
    /// AVIO_SEEKABLE_NORMAL so update_size actually runs; a nil seek returned EPIPE and shipped a size-0 moov the
    /// instant the moov outgrew the AVIO buffer. AVSEEK_SIZE reports the current produced length. Never touches
    /// the source. Remux-thread only, so `avioWriteCursor` needs no lock.
    private func avioSeek(_ offset: Int64, _ whence: Int32) -> Int64 {
        if (whence & AVSEEK_SIZE_CONST) != 0 {
            return Int64(buffer.producedCount)   // current logical file size (the high-water mark)
        }
        let w = whence & ~AVSEEK_FORCE_CONST
        let target: Int64
        switch w {
        case SEEK_SET_CONST: target = offset
        case SEEK_CUR_CONST: target = Int64(avioWriteCursor) + offset
        case SEEK_END_CONST: target = Int64(buffer.producedCount) + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        avioWriteCursor = Int(target)
        return target
    }

    // MARK: - dec3 (E-AC3 / Atmos JOC signaling) verification, message-only and fail-soft

    /// Accumulates the FIRST bytes of muxed output until the `dec3` sample-entry box is found (it rides in
    /// the moov, which movenc writes with the first fragment under delay_moov) or the cap is hit. Touched
    /// only on the remux thread (the AVIO write callback). Armed (dec3ScanDone = false) only when an E-AC3
    /// track was stream-copied; otherwise the scan never runs.
    private var dec3ScanBuf: [UInt8] = []
    private var dec3ScanDone = true
    private static let dec3ScanCap = 1 << 20   // the moov lands with the first fragment, well inside 1 MiB

    /// One-time scan for the `dec3` box, logging whether the muxer wrote the Dolby Atmos JOC extension.
    /// Per ETSI TS 103 420 / FFmpeg movenc, a dec3 payload that carries the extension ENDS with the byte
    /// `0000000 1` (7 reserved bits + flag_ec3_extension_type_a) followed by `complexity_index_type_a`
    /// (non-zero for a real Atmos track). The bundled libavformat 62.x writes those bytes when the mapped
    /// track's profile is DDP_ATMOS, so this log turns one diagnostics export into proof of whether the
    /// produced fMP4 SIGNALS Atmos, separating "muxed correctly" from any downstream AVPlayer/HDMI cause.
    private func scanForDec3(_ bytes: UnsafePointer<UInt8>, count: Int) {
        guard !dec3ScanDone else { return }
        dec3ScanBuf.append(contentsOf: UnsafeBufferPointer(start: bytes, count: count))
        let needle: [UInt8] = [0x64, 0x65, 0x63, 0x33]   // 'd' 'e' 'c' '3'
        if let pos = Self.firstIndex(of: needle, in: dec3ScanBuf) {
            dec3ScanDone = true
            var detail = "found, payload unreadable"
            if pos >= 4 {
                // The 4 bytes before the fourcc are the big-endian box size (header 8 bytes + payload).
                let size = (Int(dec3ScanBuf[pos - 4]) << 24) | (Int(dec3ScanBuf[pos - 3]) << 16)
                         | (Int(dec3ScanBuf[pos - 2]) << 8) | Int(dec3ScanBuf[pos - 1])
                let payloadStart = pos + 4
                let payloadLen = size - 8
                if payloadLen > 0, payloadLen <= 64, payloadStart + payloadLen <= dec3ScanBuf.count {
                    let payload = Array(dec3ScanBuf[payloadStart..<(payloadStart + payloadLen)])
                    let hex = payload.map { String(format: "%02x", $0) }.joined()
                    let hasExt = payloadLen >= 2 && (payload[payloadLen - 2] & 0x01) == 1
                    let complexity = hasExt ? Int(payload[payloadLen - 1]) : 0
                    detail = "payload=\(hex) atmosExt=\(hasExt ? "YES complexity_index_type_a=\(complexity)" : "ABSENT")"
                }
            }
            DiagnosticsLog.log("dv", "dec3 box in muxed init segment: \(detail)")
            dec3ScanBuf = []
        } else if dec3ScanBuf.count >= Self.dec3ScanCap {
            dec3ScanDone = true
            DiagnosticsLog.log("dv", "no dec3 box in the first \(Self.dec3ScanCap) muxed bytes (moov landed later than expected)")
            dec3ScanBuf = []
        }
    }

    /// Naive first-occurrence search (the haystack is capped at 1 MiB and scanned at most ~16 times, so
    /// O(n*m) is fine and avoids any stdlib-availability dependency).
    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        let end = haystack.count - needle.count
        for i in 0...end {
            var match = true
            for j in 0..<needle.count where haystack[i + j] != needle[j] { match = false; break }
            if match { return i }
        }
        return nil
    }

    // MARK: - HLS output indexing (b166; every method no-ops unless `hlsIndexingEnabled`)

    /// Locate the init segment's `moov` box by walking the leading top-level boxes. Runs on the forward-append
    /// path of the AVIO write callback. Once `moov` is located we STOP accumulating and wait for the muxer to
    /// backpatch its 32-bit size (a >AVIO-buffer moov is patched via the seekable AVIO's overwrite path, not in
    /// the AVIO buffer); that patch (`hlsNoteBackpatch`) publishes the init. If the moov already fit the AVIO
    /// buffer it was patched in-buffer before this flush, so a valid size here finalizes immediately. The init
    /// CONTENT is read from the produced buffer, so this walk never has to hold the moov and is size-agnostic.
    /// Fail-soft: a malformed walk gives up (the server never gets an init, the playlist starves, and the start
    /// watchdog demotes to libmpv exactly like any other dead mount).
    private func hlsIndexHead(_ bytes: UnsafePointer<UInt8>, count: Int) {
        guard hlsIndexingEnabled, !hlsHeadDone, hlsMoovStart == nil, count > 0 else { return }
        hlsHeadBuf.append(contentsOf: UnsafeBufferPointer(start: bytes, count: count))
        var pos = 0
        while pos + 8 <= hlsHeadBuf.count {
            var size = (Int(hlsHeadBuf[pos]) << 24) | (Int(hlsHeadBuf[pos + 1]) << 16)
                     | (Int(hlsHeadBuf[pos + 2]) << 8) | Int(hlsHeadBuf[pos + 3])
            let fourcc = String(bytes: hlsHeadBuf[(pos + 4)...(pos + 7)], encoding: .ascii) ?? "?"
            var headerLen = 8
            if size == 1 {   // ISO-BMFF largesize: real 64-bit size in bytes pos+8..pos+15
                guard pos + 16 <= hlsHeadBuf.count else { return }   // wait for the largesize field
                var big: UInt64 = 0
                for i in 0..<8 { big = (big << 8) | UInt64(hlsHeadBuf[pos + 8 + i]) }
                guard big >= 16, big <= UInt64(Int.max - pos) else {
                    hlsAbortInitScan("malformed largesize \(big) type=\(fourcc)"); return
                }
                size = Int(big)
                headerLen = 16
            }
            if fourcc == "moov" {
                // Located. Remember it and STOP accumulating (guard above short-circuits future calls). The size
                // field is very likely an unpatched 0 placeholder right now; the muxer backpatches it once the
                // whole moov is written, and hlsNoteBackpatch finalizes on that patch. If it is ALREADY valid
                // (the moov fit the AVIO buffer and was patched in-buffer before this flush) finalize now.
                hlsMoovStart = pos
                hlsHeadBuf = []
                if size >= headerLen {
                    hlsFinalizeInit(moovStart: pos, moovSize: size)
                } else {
                    DiagnosticsLog.log("dv", "hls init: moov located at byte \(pos), awaiting size backpatch (placeholder size field=\(size))")
                }
                return
            }
            if fourcc == "moof" || fourcc == "styp" || fourcc == "mdat" {   // fragment data before any moov
                hlsAbortInitScan("\(fourcc) arrived before moov"); return
            }
            guard size >= headerLen else {   // zero/malformed size on a box we must walk PAST: give up
                hlsAbortInitScan("unparseable top-level box size=\(size) type=\(fourcc)"); return
            }
            pos += size   // skip ftyp/free/... ; loop waits for more bytes if the next header is not in yet
        }
        if hlsHeadBuf.count > Self.hlsHeadCap {
            hlsAbortInitScan("no moov header in the first \(Self.hlsHeadCap) bytes")
        }
    }

    /// The muxer backpatched a box-size placeholder (the seekable-AVIO overwrite path, `avioWrite`). If it
    /// patched the TOP-LEVEL moov's size field, the init length is now known, so publish the init segment. A
    /// no-op for every other backpatch (a nested box inside the moov, or a trailer-time patch): only the moov's
    /// own size (the 4 bytes at [hlsMoovStart, +4)) triggers finalization, and it is written in a single wb32.
    private func hlsNoteBackpatch(at offset: Int, bytes: UnsafePointer<UInt8>, count: Int) {
        guard hlsIndexingEnabled, !hlsHeadDone, let m = hlsMoovStart else { return }
        guard offset <= m, offset + count >= m + 4 else { return }   // must fully cover the moov size field
        let o = m - offset
        let size = (Int(bytes[o]) << 24) | (Int(bytes[o + 1]) << 16) | (Int(bytes[o + 2]) << 8) | Int(bytes[o + 3])
        guard size >= 8 else { return }   // still a placeholder: keep waiting for the real wb32
        hlsFinalizeInit(moovStart: m, moovSize: size)
    }

    /// Publish the init segment (ftyp .. end-of-moov) read back from the produced buffer. One-shot. Nothing is
    /// served until this sets `_hlsInitData`, so the whole init is still resident from offset 0 (no eviction
    /// yet) and `snapshotPrefix` returns it regardless of moov size.
    private func hlsFinalizeInit(moovStart: Int, moovSize: Int) {
        guard !hlsHeadDone else { return }
        let initLen = moovStart + moovSize
        guard let initData = buffer.snapshotPrefix(length: initLen) else {
            hlsAbortInitScan("init \(initLen)B (moov \(moovSize)B @\(moovStart)) not fully resident")
            return
        }
        hlsLock.lock(); _hlsInitData = initData; hlsLock.unlock()
        hlsSegmentStartByte = initLen   // segment 0 starts right after the init
        hlsHeadDone = true; hlsHeadBuf = []
        DiagnosticsLog.log("dv", "hls init segment indexed: \(initLen)B (ftyp+moov, moov=\(moovSize)B, \(Self.describeInitDoVi(initData)))")
    }

    /// Decode the DV carriage straight out of the SERVED init bytes (not the codecpar we handed the muxer) so
    /// the marker proves what actually shipped: the dvcC/dvvC box's profile, level, and BL-compatibility id, or
    /// `dovi=MISSING` when neither box is present (an in-band-only source that reached the muxer with no record).
    /// dvcC/dvvC are plain boxes, so the 24-byte DOVIDecoderConfigurationRecord starts right after the fourcc.
    private static func describeInitDoVi(_ data: Data) -> String {
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String in
            guard let base = raw.baseAddress else { return "dovi=MISSING" }
            let b = base.assumingMemoryBound(to: UInt8.self)
            let n = raw.count
            let d = UInt8(ascii: "d"), v = UInt8(ascii: "v"), c = UInt8(ascii: "c"), C = UInt8(ascii: "C")
            var f = 0
            while f + 4 + 5 <= n {   // fourcc (4) + at least 5 record bytes to read profile/level/compat
                if b[f] == d, b[f + 1] == v, (b[f + 2] == v || b[f + 2] == c), b[f + 3] == C {
                    let name = b[f + 2] == v ? "dvvC" : "dvcC"
                    let p = f + 4
                    let profile = (Int(b[p + 2]) >> 1) & 0x7F
                    let level = ((Int(b[p + 2]) & 1) << 5) | ((Int(b[p + 3]) >> 3) & 0x1F)
                    let compat = (Int(b[p + 4]) >> 4) & 0x0F
                    return "dovi=\(name) p\(profile) l\(level) c\(compat)"
                }
                f += 1
            }
            return "dovi=MISSING"
        }
    }

    /// Give up on the init scan (fail-soft): the playlist starves and the start watchdog demotes to libmpv.
    private func hlsAbortInitScan(_ reason: String) {
        hlsHeadDone = true; hlsHeadBuf = []
        DiagnosticsLog.log("dv", "hls init scan aborted: \(reason)")
    }

    /// Cut a segment boundary BEFORE writing this base-video packet when the open segment has reached the
    /// target duration at a keyframe (clean, seekable cut) or the hard bound at any frame (so one long GOP
    /// can never outgrow the playlist's fixed TARGETDURATION). The cut = drain the interleave queue + flush
    /// the muxer's open fragment (`av_interleaved_write_frame(ctx, nil)`, the documented movenc fragment
    /// cut) + flush the AVIO tail, after which `buffer.producedCount` is EXACTLY the segment's end byte.
    /// movenc's own frag_duration auto-cuts continue as shipped; they simply become intra-segment fragments.
    private func hlsMaybeCut(outCtx: UnsafeMutablePointer<AVFormatContext>,
                             pkt: UnsafeMutablePointer<AVPacket>,
                             timeBase: AVRational) {
        guard hlsIndexingEnabled else { return }
        let den = Double(timeBase.den)
        guard den > 0 else { return }
        let ts = pkt.pointee.dts != AV_NOPTS_VALUE_CONST ? pkt.pointee.dts : pkt.pointee.pts
        guard ts != AV_NOPTS_VALUE_CONST else { return }
        let sec = Double(ts) * Double(timeBase.num) / den
        hlsLastVideoSec = sec
        guard let start = hlsSegmentStartSec else {
            hlsSegmentStartSec = sec   // the first base-video packet opens segment 0
            return
        }
        let elapsed = sec - start
        let isKey = (pkt.pointee.flags & AV_PKT_FLAG_KEY_CONST) != 0
        let openBytes = buffer.producedCount - (hlsSegmentStartByte ?? 0)
        guard (isKey && elapsed >= Self.hlsTargetSegmentSecs)
                || elapsed >= Self.hlsMaxSegmentSecs
                || openBytes >= Self.hlsMaxSegmentBytes else { return }
        _ = av_interleaved_write_frame(outCtx, nil)   // drain the interleave queue + flush the open fragment
        avio_flush(outCtx.pointee.pb)                 // push the AVIO tail so producedCount == the boundary
        hlsCloseSegment(endSec: sec)
        hlsSegmentStartSec = sec
    }

    /// Publish the open segment as CLOSED (byte range + exact duration). Only closed segments appear in the
    /// media playlist, so a segment's bytes are always fully produced before AVPlayer can request them.
    private func hlsCloseSegment(endSec: Double) {
        guard hlsIndexingEnabled, let segStartByte = hlsSegmentStartByte, let startSec = hlsSegmentStartSec else { return }
        let endByte = buffer.producedCount
        guard endByte > segStartByte else { return }   // the flush produced no bytes: nothing to publish
        let duration = min(Double(Self.hlsTargetDuration), max(0.04, endSec - startSec))
        hlsLock.lock()
        let idx = _hlsSegments.count
        _hlsSegments.append(HLSSegment(index: idx, byteOffset: segStartByte,
                                       byteLength: endByte - segStartByte, duration: duration))
        hlsLock.unlock()
        hlsSegmentStartByte = endByte
    }

    /// Build the master-playlist signaling from the FINAL output streams (post extradata repair + DOVI
    /// sanitize/relabel), per Apple's HLS authoring spec for Dolby Vision: P5 advertises CODECS="dvh1.05.LL";
    /// P8.1 advertises the plain HEVC CODECS plus SUPPLEMENTAL-CODECS="dvh1.08.LL/db1p" and VIDEO-RANGE=PQ
    /// (the brand and VIDEO-RANGE are mandatory cross-checks; leaving either out is incorrect).
    private func hlsBuildSignaling(outCtx: UnsafeMutablePointer<AVFormatContext>,
                                   inCtx: UnsafeMutablePointer<AVFormatContext>,
                                   info: SourceInfo, baseVideoOut: Int, baseVideoIn: Int) {
        var videoCodec = "hvc1.2.4.L153.B0"   // safe Main10 default when the hvcC parse fails
        var dvLevel = 0
        var blCompat = info.dvBLCompatId
        var profile = info.dvProfile
        if baseVideoOut >= 0, let vpar = outCtx.pointee.streams[baseVideoOut]?.pointee.codecpar {
            let n = Int(vpar.pointee.nb_coded_side_data)
            if n > 0, let arr = vpar.pointee.coded_side_data {
                for i in 0..<n where arr[i].type == AV_PKT_DATA_DOVI_CONF {
                    if let d = arr[i].data {
                        d.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { r in
                            dvLevel = Int(r.pointee.dv_level)
                            blCompat = Int(r.pointee.dv_bl_signal_compatibility_id)
                            profile = Int(r.pointee.dv_profile)
                        }
                    }
                }
            }
            if let parsed = Self.hevcCodecString(vpar) { videoCodec = parsed }
        }
        var supplemental: String?
        var range: String? = "PQ"
        let lvl = String(format: "%02d", min(max(dvLevel, 1), 13))
        if profile == 5 {
            videoCodec = "dvh1.05.\(lvl)"   // Profile 5 is DV-only (no cross-compatible base layer)
        } else if profile == 8 {
            switch blCompat {
            case 1, 6: supplemental = "dvh1.08.\(lvl)/db1p"                  // HDR10/PQ-compatible base
            case 4:    supplemental = "dvh1.08.\(lvl)/db4h"; range = "HLG"   // HLG-compatible base (8.4)
            default:   supplemental = nil                                    // unknown compat: plain HEVC HDR
            }
        }
        var audio: String?
        for i in 0..<Int(outCtx.pointee.nb_streams) {
            guard let par = outCtx.pointee.streams[i]?.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            audio = Self.audioCodecString(par.pointee.codec_id)
        }
        let br = Int(inCtx.pointee.bit_rate)
        let bandwidth = br > 0 ? br + br / 4 : 25_000_000   // headroom over the container rate; generous 4K default
        // FRAME-RATE comes from the INPUT base-video stream: parameters_copy never sets the OUTPUT stream's
        // avg_frame_rate, and inCtx must be read at baseVideoIn specifically because a Profile 7 source carries
        // an enhancement-layer video track too, so "the first video stream" is the wrong one.
        let fps = baseVideoIn >= 0 ? Self.frameRate(inCtx.pointee.streams[baseVideoIn]) : 0
        let sig = HLSSignaling(videoCodec: videoCodec, supplementalCodec: supplemental, videoRange: range,
                               audioCodec: audio, width: info.width, height: info.height, bandwidth: bandwidth, fps: fps)
        hlsLock.lock(); _hlsSignaling = sig; hlsLock.unlock()
        DiagnosticsLog.log("dv", "hls signaling codecs=\(videoCodec)\(audio.map { ",\($0)" } ?? "") supplemental=\(supplemental ?? "none") range=\(range ?? "none") fps=\(String(format: "%.3f", fps)) bw=\(bandwidth)")
    }

    /// RFC 6381 HEVC codec string ("hvc1.2.4.L153.B0") from an hvcC record's profile/tier/level bytes.
    /// Returns nil (caller keeps a safe default) when the extradata is not a parseable hvcC record.
    private static func hevcCodecString(_ par: UnsafeMutablePointer<AVCodecParameters>?) -> String? {
        guard let par, let ex = par.pointee.extradata else { return nil }
        let n = Int(par.pointee.extradata_size)
        guard n >= 23, ex[0] == 1 else { return nil }
        let profileSpace = Int((ex[1] >> 6) & 0x3)
        // general_tier_flag (ex[1] bit 5) is deliberately NOT read: the HLS CODECS tier is FORCED to Main ("L")
        // below (kept as a harmless canonical-form choice; it was NOT the -1002 fix - see the note on the `s` line).
        let profileIdc = ex[1] & 0x1F
        // general_profile_compatibility_flags, bit-reversed then hex, per RFC 6381 (e.g. Main10 -> "4").
        var compat: UInt32 = (UInt32(ex[2]) << 24) | (UInt32(ex[3]) << 16) | (UInt32(ex[4]) << 8) | UInt32(ex[5])
        var reversed: UInt32 = 0
        for _ in 0..<32 { reversed = (reversed << 1) | (compat & 1); compat >>= 1 }
        let level = ex[12]
        // Constraint bytes 6..11 as hex, trailing zero bytes omitted (Apple's examples end ".B0").
        var lastNonZero = -1
        for k in 0..<6 where ex[6 + k] != 0 { lastNonZero = k }
        var constraints: [String] = []
        if lastNonZero >= 0 {
            for k in 0...lastNonZero { constraints.append(String(format: "%X", ex[6 + k])) }
        }
        let spacePrefix = ["", "A", "B", "C"][profileSpace]
        // TIER FORCED TO MAIN ("L"), never High ("H"). This is KEPT, but it is NOT what fixed the DV-remux
        // -1002 - an earlier note here claimed AVFoundation rejects a High-tier base for DV Profile 8.1; a
        // byte-exact off-device bisect (13 cases on the same CoreMedia HLS stack) disproved that. The -1002
        // was AVFoundation's VIDEO-RANGE single-variant filter: an explicit non-SDR VIDEO-RANGE (PQ/HLG)
        // variant is dropped when the output pipeline is not provably HDR at master-parse time, and the master
        // carried exactly ONE variant, so that single drop left ZERO playable variants -> NSURLErrorDomain
        // -1002 / CoreMediaErrorDomain -1002. The bisect proved: an HONEST High-tier "hvc1.2.4.H153.B0" with
        // NO VIDEO-RANGE plays fine (so forced-L was never load-bearing), and a genuine codec-level reject
        // surfaces as AVFoundationErrorDomain -11848 / CoreMediaErrorDomain -15517 ("Cannot Open"), a DIFFERENT
        // signature from -1002. The actual -1002 fix is the range-unlabeled "lifeboat" second variant in
        // VortXRemuxHLSServer.serveMaster (b170), which always survives the filter. Forced-L is retained only
        // because it is proven harmless: CODECS governs only variant SELECTION, the init segment's real hvcC
        // (still truthfully High tier) is what VideoToolbox decodes, and the hardware decodes regardless of the
        // advertised tier. Profile/compat/level/constraints are left exact.
        var s = "hvc1.\(spacePrefix)\(profileIdc).\(String(reversed, radix: 16, uppercase: true)).L\(level)"
        if !constraints.isEmpty { s += "." + constraints.joined(separator: ".") }
        return s
    }

    /// RFC 6381 codec string for the one mapped audio track (nil = leave it out of CODECS).
    private static func audioCodecString(_ id: AVCodecID) -> String? {
        switch id {
        case AV_CODEC_ID_EAC3: return "ec-3"
        case AV_CODEC_ID_AC3:  return "ac-3"
        case AV_CODEC_ID_AAC:  return "mp4a.40.2"
        case AV_CODEC_ID_MP3:  return "mp4a.40.34"
        case AV_CODEC_ID_FLAC: return "fLaC"
        case AV_CODEC_ID_ALAC: return "alac"
        default: return nil
        }
    }

    // MARK: - Source diagnostics (mirrors MKVRemuxSession)

    /// Audio codecs AVPlayer can decode out of an fMP4 (compared by rawValue), always stream-copied when
    /// present. Everything else (chiefly TrueHD, DTS, Opus, Vorbis, raw PCM variants) is dropped from the map,
    /// UNLESS the source has none of these at all, in which case ONE such track is transcoded in-flight by
    /// `VortXAudioTranscoder`; only a source with no decodable and no transcodable audio fails to libmpv.
    private static let avPlayerDecodableAudio: [AVCodecID.RawValue] = [
        AV_CODEC_ID_AAC.rawValue, AV_CODEC_ID_AC3.rawValue, AV_CODEC_ID_EAC3.rawValue,
        AV_CODEC_ID_ALAC.rawValue, AV_CODEC_ID_MP3.rawValue, AV_CODEC_ID_FLAC.rawValue
    ]

    /// FFmpeg's `AV_PROFILE_EAC3_DDP_ATMOS` (libavcodec/defs.h): the E-AC3 probe sets `codecpar.profile` to
    /// this when the bitstream carries the Dolby Atmos JOC extension. Mirrored as a named literal because
    /// simple `#define` macros do not reliably import through the Libavcodec Swift module map.
    private static let eac3AtmosProfile: Int32 = 30

    /// Preference rank for a stream-copyable audio codec when several tie on channel count: lower is better.
    /// EAC3 carries Dolby Atmos (JOC in its syncframes) so it wins any tie; AC3 (Dolby Digital 5.1) is next;
    /// the lossy / stereo-lossless fallbacks share the bottom. Only consulted AFTER channel count in the
    /// classify scan, so a 6ch AC3 main bed still beats a 2ch EAC3 commentary.
    private static func audioCopyRank(_ id: AVCodecID) -> Int {
        switch id {
        case AV_CODEC_ID_EAC3: return 0
        case AV_CODEC_ID_AC3:  return 1
        default:               return 2
        }
    }

    /// The ISO-639 language tag on a stream ("eng", "ger", ...), lowercased. Read from the demuxer's per-stream
    /// metadata (matroska's Language element, MP4's language atom). NOTE: the matroska demuxer substitutes its
    /// spec default "eng" for a track with no Language element, and MP4 often yields "und", so this rarely
    /// returns "" in practice; what matters for the pick is that all untagged tracks in ONE file share the same
    /// substituted value, so the language key stays a no-op among them (it never spuriously splits them).
    private static func streamLanguage(_ stream: UnsafeMutablePointer<AVStream>) -> String {
        guard let entry = av_dict_get(stream.pointee.metadata, "language", nil, 0),
              let value = entry.pointee.value else { return "" }
        return String(cString: value).lowercased()
    }

    /// Per-session tally of Profile-7 -> 8.1 RPU conversion outcomes, logged once at mux exit so a DV source
    /// that mounts but still demotes to mpv reveals WHERE it broke: converted>0 with fellBack==0 means libdovi
    /// did its job (the failure is downstream in AVPlayer); fellBack>0 means libdovi rejected the RPU (the real
    /// DV blocker, needs a libdovi/RPU fix); both zero means no RPU NAL was ever walked (an nalLengthSize or
    /// bitstream-shape problem, cross-check the classify line).
    struct RPUConvStats {
        var rpuConverted = 0
        var rpuFellBack = 0
        var elDropped = 0
        var pktBailed = 0
    }

    struct SourceInfo {
        var videoCodec: String = "?"
        var dvProfile: Int = -1
        var dvBLCompatId: Int = -1
        var width: Int = 0
        var height: Int = 0
        var mappedStreams: Int = 0
    }

    /// Apply the HTTP protocol options libmpv uses so the remux open survives debrid CDN quirks (chunked
    /// slow-start, mid-stream redirects, transient resets) that make a plain FFmpeg open time out (rc=-60) on a
    /// URL libmpv plays fine. Set on the same AVDictionary handed to avformat_open_input. Unknown keys on an
    /// older protocol build are simply left in the dict, never fatal.
    private static func applyDebridHTTPResilience(_ opts: inout OpaquePointer?) {
        av_dict_set(&opts, "reconnect", "1", 0)
        av_dict_set(&opts, "reconnect_streamed", "1", 0)
        av_dict_set(&opts, "reconnect_on_network_error", "1", 0)
        av_dict_set(&opts, "reconnect_delay_max", "5", 0)          // seconds
        av_dict_set(&opts, "multiple_requests", "1", 0)            // persistent connection across redirect+range
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

    // MARK: - hvc1 extradata validation + repair (the "Cannot Open" empty-hvcC guard)

    /// What `checkHvc1Extradata` learned about a base-video extradata buffer. `eligible` means the shipped
    /// libavformat 62's ff_isom_write_hvcc (with ps_array_completeness=1, which movenc passes for the 'hvc1'
    /// tag) can build a VALID hvcC box from it; the counts and form feed the diagnostics lines either way.
    struct Hvc1ExtradataCheck {
        var eligible = false
        var form = "absent"      // "absent" | "hvcC" | "annexB" | "unknown"
        var size = 0
        var vps = 0
        var sps = 0
        var pps = 0
    }

    /// Mirror EXACTLY what libavformat 62's hevc.c enforces before it will write a non-empty hvcC for an
    /// 'hvc1' sample entry: extradata present and >= 6 bytes; either Annex-B form (a raw 00 00 01 /
    /// 00 00 00 01 start code, from which hevc.c builds a complete hvcC itself) or hvcC form
    /// (configurationVersion 1, >= 23 bytes) whose parameter-set arrays carry AT LEAST one VPS (NAL type 32),
    /// one SPS (33), and one PPS (34); with array-completeness required, hevc.c rejects a record missing any
    /// of the three, and movenc then swallows that error and writes an 8-byte EMPTY hvcC AVPlayer cannot
    /// open. Every read is bounds-checked; a malformed walk simply reports ineligible (fail-soft, never a
    /// crash).
    private static func checkHvc1Extradata(_ par: UnsafeMutablePointer<AVCodecParameters>?) -> Hvc1ExtradataCheck {
        var c = Hvc1ExtradataCheck()
        guard let par, let ex = par.pointee.extradata else { return c }
        let n = Int(par.pointee.extradata_size)
        c.size = n
        guard n >= 6 else { return c }   // hevc.c: size < 6 is AVERROR_INVALIDDATA outright
        if (ex[0] == 0 && ex[1] == 0 && ex[2] == 1)
            || (ex[0] == 0 && ex[1] == 0 && ex[2] == 0 && ex[3] == 1) {
            c.form = "annexB"
            c.eligible = true   // hevc.c parses the raw NALs and builds the complete hvcC itself
            return c
        }
        guard ex[0] == 1 else { c.form = "unknown"; return c }
        c.form = "hvcC"
        guard n >= 23 else { return c }
        // Walk the parameter-set arrays: byte 22 = numOfArrays; each array = 1 byte (completeness bit + NAL
        // type in the low 6 bits), a 2-byte NALU count, then per-NALU a 2-byte length + payload.
        let numArrays = Int(ex[22])
        var pos = 23
        for _ in 0..<numArrays {
            guard pos + 3 <= n else { return c }
            let nalType = ex[pos] & 0x3F
            let numNalus = (Int(ex[pos + 1]) << 8) | Int(ex[pos + 2])
            pos += 3
            for _ in 0..<numNalus {
                guard pos + 2 <= n else { return c }
                let len = (Int(ex[pos]) << 8) | Int(ex[pos + 1])
                pos += 2
                guard len > 0, pos + len <= n else { return c }
                switch nalType {
                case 32: c.vps += 1
                case 33: c.sps += 1
                case 34: c.pps += 1
                default: break
                }
                pos += len
            }
        }
        c.eligible = c.vps > 0 && c.sps > 0 && c.pps > 0
        return c
    }

    /// Harvest the raw VPS/SPS/PPS NALs out of ONE length-prefixed base-video access unit. A
    /// parameter-sets-in-band stream repeats all three ahead of its IDR slice in the very first access unit,
    /// which the DV pre-scan already prebuffers seek-free. Returns nil unless the walk parses cleanly
    /// end-to-end AND finds at least one of each parameter set, so a misaligned or Annex-B-framed packet can
    /// never smuggle garbage into the output extradata (fail-soft: the caller then demotes to libmpv).
    /// The NALs feed `buildRepairedHvcC`, never Annex-B extradata (see the repair-site comment for why).
    private static func harvestParameterSets(_ pkt: UnsafeMutablePointer<AVPacket>, nalLengthSize: Int)
        -> (nals: [(type: UInt8, bytes: [UInt8])], vps: Int, sps: Int, pps: Int)? {
        guard let src = pkt.pointee.data else { return nil }
        let total = Int(pkt.pointee.size)
        guard total > nalLengthSize, nalLengthSize >= 1, nalLengthSize <= 4 else { return nil }
        var out: [(type: UInt8, bytes: [UInt8])] = []
        var vps = 0, sps = 0, pps = 0
        var pos = 0
        while pos + nalLengthSize <= total {
            var nalLen = 0
            for k in 0..<nalLengthSize { nalLen = (nalLen << 8) | Int(src[pos + k]) }
            let nalStart = pos + nalLengthSize
            guard nalLen > 0, nalStart + nalLen <= total else { return nil }   // malformed walk: no harvest
            let nalType = (src[nalStart] >> 1) & 0x3F
            if nalType == 32 || nalType == 33 || nalType == 34 {
                out.append((type: nalType, bytes: Array(UnsafeBufferPointer(start: src + nalStart, count: nalLen))))
                switch nalType {
                case 32: vps += 1
                case 33: sps += 1
                default: pps += 1
                }
            }
            pos = nalStart + nalLen
        }
        guard pos == total, vps > 0, sps > 0, pps > 0 else { return nil }
        return (out, vps, sps, pps)
    }

    /// Build a complete hvcC record by grafting the harvested in-band parameter sets onto the SOURCE hvcC's
    /// header fields (bytes 0..21: configurationVersion through lengthSizeMinusOne, which the WEB-DL-derived
    /// MKVs this repairs carry correctly even when their parameter-set arrays are empty). Each array is
    /// written with array_completeness=1, matching what movenc requires for the 'hvc1' sample entry. Returns
    /// nil (the caller then fails fast to libmpv) when the source extradata is not an hvcC record to begin
    /// with; building the header fields from scratch would need a full SPS bit parse, and no such source has
    /// been observed on this lane.
    private static func buildRepairedHvcC(source: UnsafeMutablePointer<AVCodecParameters>?,
                                          nals: [(type: UInt8, bytes: [UInt8])]) -> [UInt8]? {
        guard let source, let ex = source.pointee.extradata else { return nil }
        let n = Int(source.pointee.extradata_size)
        guard n >= 23, ex[0] == 1, !nals.isEmpty else { return nil }
        var out = [UInt8](UnsafeBufferPointer(start: ex, count: 22))   // header bytes 0..21 verbatim
        let grouped = Dictionary(grouping: nals, by: { $0.type })
        let arrayTypes: [UInt8] = [32, 33, 34].filter { grouped[$0] != nil }   // VPS, SPS, PPS in spec order
        out.append(UInt8(arrayTypes.count))                            // numOfArrays
        for t in arrayTypes {
            let list = grouped[t] ?? []
            guard list.count <= 0xFFFF else { return nil }
            out.append(0x80 | t)                                       // array_completeness=1 + NAL unit type
            out.append(UInt8((list.count >> 8) & 0xFF)); out.append(UInt8(list.count & 0xFF))
            for nal in list {
                guard nal.bytes.count <= 0xFFFF else { return nil }
                out.append(UInt8((nal.bytes.count >> 8) & 0xFF)); out.append(UInt8(nal.bytes.count & 0xFF))
                out.append(contentsOf: nal.bytes)
            }
        }
        return out
    }

    /// Replace the output codecpar's extradata with `bytes` (an av_malloc'd copy, zero-padded by
    /// AV_INPUT_BUFFER_PADDING_SIZE as libav readers over-read the tail). The old buffer, which
    /// avcodec_parameters_copy av_malloc'd, is freed; the new one is owned by the codecpar and freed with the
    /// output context. Returns false (leaving the codecpar untouched) only on allocation failure.
    private static func installExtradata(_ par: UnsafeMutablePointer<AVCodecParameters>?, _ bytes: [UInt8]) -> Bool {
        guard let par, !bytes.isEmpty else { return false }
        let size = bytes.count
        guard let dst = av_malloc(size + AV_INPUT_BUFFER_PADDING_SIZE_CONST)?
            .assumingMemoryBound(to: UInt8.self) else { return false }
        bytes.withUnsafeBufferPointer { buf in
            if let b = buf.baseAddress { memcpy(dst, b, size) }
        }
        memset(dst + size, 0, AV_INPUT_BUFFER_PADDING_SIZE_CONST)
        if let old = par.pointee.extradata { av_free(old) }
        par.pointee.extradata = dst
        par.pointee.extradata_size = Int32(size)
        return true
    }

    /// Sanitize the OUTPUT stream's DOVI configuration side-data record so FFmpeg's mov muxer writes a `dvvC`
    /// box AVPlayer's strict open-time parser accepts. Forces only the structural fields that every file which
    /// opens today already carries and that can only repair a malformed box, never break a conformant one:
    /// movenc's DoVi validation wants a complete, internally-consistent record (dv_version_major must be 1 and
    /// dv_level non-zero or mov_init can EINVAL), and a single-layer P5/P8 (or converted P7) source has no
    /// enhancement layer (so el_present must be 0; hybrid dovi_tool injects sometimes leave it set on a Profile
    /// 8 source, which this clears). These are proven no-ops on a conformant source and corrective on a
    /// malformed one.
    ///
    /// `dv_md_compression` is deliberately NOT forced on the stream-copy lane. It is only zeroed under
    /// `relabelProfile81` (the Profile 7 -> 8.1 conversion), where the per-packet RPU is actually rewritten to
    /// an uncompressed Profile 8.1 bitstream, so a NONE box is the correct, consistent label. On the P5/P8
    /// stream-copy lane the RPU rides through byte-for-byte, so we keep the source md_compression: the common
    /// rip already reads NONE (byte-identical to before), and a rare metadata-compressed source keeps a box
    /// that agrees with its untouched bitstream instead of a NONE box that would lie about it. `relabelProfile81`
    /// additionally relabels the record Profile 8 / BL-compatible so the box agrees with the converted
    /// bitstream; the P5/P8 stream-copy lanes keep their source profile + compatibility id.
    ///
    /// Mutates the existing `AV_PKT_DATA_DOVI_CONF` record that `avcodec_parameters_copy` already duplicated
    /// onto the output codecpar (the buffer is output-owned, so an in-place edit is safe). No-op if the source
    /// carried no DOVI side data; that in-band-only case is handled by `attachSyntheticDoVi`, which builds and
    /// attaches a conformant record so the muxer has one to write the dvvC box + dby1 brand from.
    private static func sanitizeOutputDoVi(_ par: UnsafeMutablePointer<AVCodecParameters>?, relabelProfile81: Bool) {
        guard let par else { return }
        let n = Int(par.pointee.nb_coded_side_data)
        guard n > 0, let arr = par.pointee.coded_side_data else { return }
        for i in 0..<n where arr[i].type == AV_PKT_DATA_DOVI_CONF {
            guard let data = arr[i].data,
                  Int(arr[i].size) >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size else { return }
            data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { rec in
                rec.pointee.dv_version_major = 1
                rec.pointee.dv_version_minor = 0
                rec.pointee.dv_level = max(rec.pointee.dv_level, 1)   // keep the source level, never 0
                rec.pointee.el_present_flag = 0                 // no lane maps or keeps an enhancement layer
                rec.pointee.rpu_present_flag = 1
                rec.pointee.bl_present_flag = 1
                if relabelProfile81 {
                    // convertP7 ONLY: the RPU is rewritten to uncompressed Profile 8.1, so the box must read
                    // NONE to match. The stream-copy lane deliberately preserves the source md_compression
                    // (see the doc comment) so a metadata-compressed RPU is never mislabeled NONE.
                    rec.pointee.dv_md_compression = UInt8(AV_DOVI_COMPRESSION_NONE.rawValue)
                    rec.pointee.dv_profile = 8
                    rec.pointee.dv_bl_signal_compatibility_id = 1   // BL-compatible (HDR10 base)
                }
            }
            return
        }
    }

    /// True when the output codecpar already carries an AV_PKT_DATA_DOVI_CONF record (a container dvcC/dvvC that
    /// `avcodec_parameters_copy` duplicated onto it). When this is false the source signalled DV only through
    /// in-band RPUs and `attachSyntheticDoVi` must build the record the mov muxer needs.
    private static func hasDoViSideData(_ par: UnsafeMutablePointer<AVCodecParameters>?) -> Bool {
        guard let par, let arr = par.pointee.coded_side_data else { return false }
        let n = Int(par.pointee.nb_coded_side_data)
        for i in 0..<n where arr[i].type == AV_PKT_DATA_DOVI_CONF { return true }
        return false
    }

    /// Synthesize and attach an AV_PKT_DATA_DOVI_CONF record for a source whose Dolby Vision was carried only as
    /// in-band HEVC RPUs (no container dvcC/dvvC). movenc writes the dvvC box and the dby1 brand from this
    /// record, so attaching it is what makes AVPlayer engage true DV instead of decoding the base layer as
    /// HDR10. Built already-conformant (single-layer, RPU present, uncompressed) so no later sanitize pass is
    /// needed. `av_dovi_alloc` allocates the struct (its size is not part of the public ABI) and
    /// `av_packet_side_data_add` takes ownership of that av_malloc'd block on success, so the record is freed
    /// here only when the add fails.
    private static func attachSyntheticDoVi(_ par: UnsafeMutablePointer<AVCodecParameters>?,
                                            profile: Int, width: Int, height: Int, fps: Double) {
        guard let par else { return }
        var recSize = 0
        guard let rec = av_dovi_alloc(&recSize), recSize > 0 else {
            DiagnosticsLog.log("dv", "synthetic dvvC record: av_dovi_alloc failed")
            return
        }
        rec.pointee.dv_version_major = 1
        rec.pointee.dv_version_minor = 0
        rec.pointee.dv_profile = UInt8(max(0, min(profile, 255)))
        rec.pointee.dv_level = doViLevel(width: width, height: height, fps: fps)
        rec.pointee.rpu_present_flag = 1
        rec.pointee.el_present_flag = 0     // no lane maps or keeps an enhancement layer
        rec.pointee.bl_present_flag = 1
        // Base-layer compatibility: Profile 5 is DV-only (0); a converted-P7 or native P8 base is HDR10/PQ
        // compatible (1). blCompat cannot be recovered from libdovi (DoviRpuDataHeader exposes only
        // guessed_profile), so the one case the default 1 would mislabel, a hypothetical in-band-only 8.4/HLG
        // source, is disambiguated by the demuxer's transfer characteristic: ARIB STD-B67 (VUI transfer 18)
        // means HLG, which is blCompat 4 and makes hlsBuildSignaling emit db4h + VIDEO-RANGE HLG. When the
        // source leaves the transfer unspecified the PQ default stands, correct for every mainstream rip.
        var blCompat: UInt8 = profile == 5 ? 0 : 1
        if profile != 5, par.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67 { blCompat = 4 }
        rec.pointee.dv_bl_signal_compatibility_id = blCompat
        rec.pointee.dv_md_compression = UInt8(AV_DOVI_COMPRESSION_NONE.rawValue)
        if av_packet_side_data_add(&par.pointee.coded_side_data, &par.pointee.nb_coded_side_data,
                                   AV_PKT_DATA_DOVI_CONF, rec, recSize, 0) == nil {
            av_free(rec)
            DiagnosticsLog.log("dv", "synthetic dvvC record: side-data add failed (record freed)")
        } else {
            DiagnosticsLog.log("dv", "synthesized dvvC record for in-band-only DV source: profile=\(rec.pointee.dv_profile) level=\(rec.pointee.dv_level) blCompat=\(blCompat)")
        }
    }

    /// Dolby Vision `dv_level` from the output resolution and frame rate (ISOBMFF spec ladder). The level rises
    /// with pixel rate; the boundaries are the documented (resolution, fps) tiers: 1080p24=3 ... 2160p24=6,
    /// 2160p30=7, 2160p60=9. Used only when synthesizing a record for an in-band-only source (a container
    /// record already carries its own level).
    private static func doViLevel(width: Int, height: Int, fps: Double) -> UInt8 {
        let dim = max(width, height)
        let f = fps > 0 ? fps : 24
        switch dim {
        case ...1280: return f <= 24 ? 1 : 2
        case ...2048: return f <= 24 ? 3 : (f <= 30 ? 4 : 5)
        case ...4096: return f <= 24 ? 6 : (f <= 30 ? 7 : (f <= 48 ? 8 : (f <= 60 ? 9 : 10)))
        default:      return f <= 24 ? 11 : (f <= 30 ? 12 : 13)
        }
    }

    /// The base video track's frame rate in fps, read from the INPUT stream. `avcodec_parameters_copy` copies
    /// codecpar only, never avg_frame_rate, so the OUTPUT stream's rate stays 0/0 and the input stream is the
    /// one authority. Prefers avg_frame_rate, falls back to r_frame_rate, and returns 0 when neither is known.
    private static func frameRate(_ stream: UnsafeMutablePointer<AVStream>?) -> Double {
        guard let stream else { return 0 }
        let avg = stream.pointee.avg_frame_rate
        if avg.num > 0, avg.den > 0 { return Double(avg.num) / Double(avg.den) }
        let r = stream.pointee.r_frame_rate
        if r.num > 0, r.den > 0 { return Double(r.num) / Double(r.den) }
        return 0
    }

    /// Detect the Dolby Vision profile from an IN-BAND HEVC RPU when the container carried no DOVI config. Walks
    /// one base-video access unit's length-prefixed NALs; on the FIRST UNSPEC62 (type 62) RPU it parses the RPU
    /// with libdovi and returns its `guessed_profile` (5/7/8...). Returns -1 when the packet has no parseable RPU.
    /// SEEK-FREE and side-effect-free: reads the packet bytes only, never advances the demuxer or mutates the
    /// packet. Mirrors the NAL walk + memory pattern of `convertPacketRPUToProfile81`; uses only libdovi symbols
    /// already linked (dovi_parse_unspec62_nalu / dovi_rpu_get_header / guessed_profile / free).
    private static func inBandDoViProfile(_ pkt: UnsafeMutablePointer<AVPacket>, nalLengthSize: Int) -> Int {
        guard let src = pkt.pointee.data else { return -1 }
        let total = Int(pkt.pointee.size)
        guard total > nalLengthSize, nalLengthSize >= 1, nalLengthSize <= 4 else { return -1 }
        var pos = 0
        while pos + nalLengthSize <= total {
            var nalLen = 0
            for k in 0..<nalLengthSize { nalLen = (nalLen << 8) | Int(src[pos + k]) }
            let nalStart = pos + nalLengthSize
            guard nalLen > 0, nalStart + nalLen <= total else { return -1 }
            let nalType = (src[nalStart] >> 1) & 0x3F
            if nalType == hevcNalTypeDoViRPU {
                return src.withMemoryRebound(to: UInt8.self, capacity: total) { base -> Int in
                    guard let rpu = dovi_parse_unspec62_nalu(base + nalStart, nalLen) else { return -1 }
                    defer { dovi_rpu_free(rpu) }
                    guard let hdr = dovi_rpu_get_header(rpu) else { return -1 }
                    defer { dovi_rpu_free_header(hdr) }
                    return Int(hdr.pointee.guessed_profile)
                }
            }
            pos = nalStart + nalLen
        }
        return -1
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
    private static func convertPacketRPUToProfile81(_ pkt: UnsafeMutablePointer<AVPacket>, nalLengthSize: Int, stats: inout RPUConvStats) {
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
            guard nalLen > 0, nalStart + nalLen <= total else { stats.pktBailed += 1; return }
            let nalType = (src[nalStart] >> 1) & 0x3F

            if nalType == hevcNalTypeDoViEL {
                // Drop the in-band enhancement-layer sublayer NAL (single-track Profile 7); the base layer plus
                // the converted RPU is what AVPlayer decodes.
                changed = true
                stats.elDropped += 1
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
                    stats.rpuConverted += 1
                } else {
                    appendLengthPrefixed(&out, src, from: nalStart, count: nalLen, nalLengthSize: nalLengthSize)
                    stats.rpuFellBack += 1
                }
            } else {
                // Every other NAL (VPS/SPS/PPS/slices/SEI) passes through unchanged.
                appendLengthPrefixed(&out, src, from: nalStart, count: nalLen, nalLengthSize: nalLengthSize)
            }
            pos = nalStart + nalLen
        }
        // Trailing bytes we could not parse as a complete NAL: bail to the untouched original for safety.
        guard pos == total else { stats.pktBailed += 1; return }
        guard changed else { return }   // nothing to rewrite; keep the original buffer

        // Replace the packet payload. av_packet_from_data takes ownership of an av_malloc'd buffer padded with
        // AV_INPUT_BUFFER_PADDING_SIZE zeroed bytes (libav readers over-read the tail); allocate + copy into one.
        let newSize = out.count
        guard let dst = av_malloc(newSize + AV_INPUT_BUFFER_PADDING_SIZE_CONST)?
            .assumingMemoryBound(to: UInt8.self) else { return }   // original packet untouched
        out.withUnsafeBufferPointer { buf in
            if let b = buf.baseAddress { memcpy(dst, b, newSize) }
        }
        memset(dst + newSize, 0, AV_INPUT_BUFFER_PADDING_SIZE_CONST)

        // Wrap the converted bytes in a SCRATCH packet first, so the original packet stays byte-for-byte intact
        // on every error path. Only once the new ref-counted buffer is fully built do we hand it to `pkt`.
        // av_packet_from_data owns `dst` on success (freeing it on unref) and does NOT take it on failure.
        guard let tmp = av_packet_alloc() else { av_free(dst); return }   // original packet untouched
        if av_packet_from_data(tmp, dst, Int32(newSize)) < 0 {
            av_free(dst)                                 // wrap failed: we still own dst, free it
            var t: UnsafeMutablePointer<AVPacket>? = tmp
            av_packet_free(&t)
            return                                       // original packet untouched: fail-soft stream-copies it
        }

        // The scratch packet now solely owns a valid buffer ref for the converted access unit. Move that single
        // ref into `pkt`: release the demuxer's old buffer ref, then transfer buf/data/size and blank the scratch
        // so freeing it drops only the empty AVPacket struct, never the buffer. pts/dts/flags/stream_index/
        // side_data on `pkt` are never touched, exactly as required.
        var oldBuf: UnsafeMutablePointer<AVBufferRef>? = pkt.pointee.buf
        av_buffer_unref(&oldBuf)                         // no-op if pkt.buf was already nil
        pkt.pointee.buf = tmp.pointee.buf
        pkt.pointee.data = tmp.pointee.data
        pkt.pointee.size = tmp.pointee.size
        tmp.pointee.buf = nil
        tmp.pointee.data = nil
        tmp.pointee.size = 0
        var t: UnsafeMutablePointer<AVPacket>? = tmp
        av_packet_free(&t)                               // frees the scratch struct only; buffer now owned by pkt
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

/// AVERROR(ETIMEDOUT) = -(ETIMEDOUT) = -60 on Darwin (what rw_timeout expiry returns). The Swift importer does
/// not surface the AVERROR macro, so hardcode the observed value to gate the cold-debrid open retry.
private let AVERROR_ETIMEDOUT_CONST: Int32 = -60

/// AVERROR_HTTP_BAD_REQUEST = -FFERRTAG(0xF8,'4','0','0') = -808465656: a transient HTTP 400 a still-warming
/// debrid CDN can answer the first open with. The Swift importer does not surface the FFERRTAG macro, so
/// hardcode it to widen the single cold-debrid open retry to this class (same fresh-options retry as ETIMEDOUT).
private let AVERROR_HTTP_BAD_REQUEST_CONST: Int32 = -808465656

/// AVFMT_FLAG_CUSTOM_IO is a plain #define (0x0080) not always surfaced as a Swift constant.
private let AVFMT_FLAG_CUSTOM_IO_CONST: Int32 = 0x0080

/// AVIO seek `whence` values. SEEK_SET/CUR/END are the standard libc constants; AVSEEK_SIZE / AVSEEK_FORCE are
/// libavformat #defines the Swift importer does not surface. `avioSeek` uses them to service movenc's box-size
/// backpatch seeks and any avio_size() query.
private let SEEK_SET_CONST: Int32 = 0
private let SEEK_CUR_CONST: Int32 = 1
private let SEEK_END_CONST: Int32 = 2
private let AVSEEK_SIZE_CONST: Int32 = 0x10000
private let AVSEEK_FORCE_CONST: Int32 = 0x20000

/// AV_NOPTS_VALUE = INT64_MIN via a cast macro the Swift importer does not surface.
private let AV_NOPTS_VALUE_CONST: Int64 = Int64.min

/// AV_PKT_FLAG_KEY is a plain #define (0x0001) not always surfaced as a Swift constant.
private let AV_PKT_FLAG_KEY_CONST: Int32 = 0x0001

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
