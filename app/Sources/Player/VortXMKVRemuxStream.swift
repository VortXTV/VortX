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
        // Cold-debrid warm-up retry. The FIRST open of a debrid link frequently times out (rc=-60 ETIMEDOUT):
        // the provider is still pulling the file into its CDN cache, so the first request primes it and an
        // immediate retry connects in a couple seconds. This is exactly why libmpv (which opens the link AFTER
        // our probe demotes) plays where the probe timed out. Retry ONCE, on timeout only, with a fresh options
        // dict; a warm retry lands inside the start-watchdog window, a genuinely dead link times out twice and
        // demotes to libmpv HDR10 as before.
        if openRc == AVERROR_ETIMEDOUT_CONST {
            VXProbe.log("dv", "probe open timed out rc=\(openRc); retrying once (cold-debrid warm-up)")
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
        // Gap A: collect EVERY audio track (not just the first), then pick the best AFTER the scan. A UHD
        // remux commonly orders a stereo or commentary track BEFORE the multichannel bed; picking the first
        // decodable track silently dropped the real (often EAC3-JOC Atmos) audio. Each tuple carries the track's
        // channel count, its stream-copy codec rank, and its language tag (the pick keeps to the source's
        // target language so raising the channel/EAC3 preference can never swap in a same-channel foreign dub).
        // `decodableAudio` = AVPlayer stream-copyable tracks; `transcodableAudio` = FFmpeg-decodable-only tracks
        // that must be transcoded (TrueHD/DTS/... - the b160 lane).
        var decodableAudio: [(index: Int, channels: Int32, rank: Int, lang: String)] = []
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
                    decodableAudio.append((i, audioChannels, Self.audioCopyRank(par.pointee.codec_id), audioLang))
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
        // Gap A pick: among all AVPlayer-decodable audio tracks, first keep to the target language, then prefer
        // the MOST channels (a commentary or stereo downmix is 1-2ch; the main bed is 6-8ch), breaking ties
        // toward EAC3 (Dolby Atmos JOC rides in EAC3, so it beats AC3, which beats lossy/stereo-lossless), then
        // original order for determinism. This stops a stereo track ordered first from masking the real
        // multichannel Atmos bed, without stealing audio away from the original language.
        var mappedAudioIn = -1
        if let best = decodableAudio.min(by: { a, b in
            let am = a.lang == decodableTargetLang, bm = b.lang == decodableTargetLang
            if am != bm { return am }
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
        // The exact stream-copied audio track + its channel count, so an on-device probe log reveals whether the
        // multichannel EAC3-JOC bed (not a stereo dub) is what actually reached AVPlayer.
        var mappedAudioName = "none"
        if hasDecodableAudio, mappedAudioIn >= 0, let s = inCtx.pointee.streams[mappedAudioIn], let p = s.pointee.codecpar {
            mappedAudioName = "\(Self.codecName(p.pointee.codec_id))/\(p.pointee.ch_layout.nb_channels)ch"
        }
        // [dv] classify probe: one greppable line of what the source actually carries (DV profile, dims, and
        // the audio codecs seen / whether any is AVPlayer-decodable). This is the line that explains WHY a DV
        // source did or did not stay on the true-DV AVPlayer lane. Gated, so free in shipping builds.
        VXProbe.log("dv", "remux classify \(info.width)x\(info.height) dvProfile=\(info.dvProfile) blCompat=\(info.dvBLCompatId) audio=[\(audioSeen.joined(separator: ","))] decodableAudio=\(hasDecodableAudio) mappedAudio=\(mappedAudioName) transcodeAudio=\(transcodeAudioName)")

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
        if info.dvProfile < 0, baseVideoIn >= 0 {
            let scanNalLen = Self.hevcNalLengthSize(inCtx.pointee.streams[baseVideoIn]?.pointee.codecpar)
            let maxScan = 240   // well within probesize; caps memory + reads if the base-video packet is late/absent
            var scanned = 0
            while scanned < maxScan, !isCancelled {
                guard let p = av_packet_alloc() else { break }
                if av_read_frame(inCtx, p) < 0 { var pp: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&pp); break }
                scanned += 1
                prebuffered.append(p)
                if Int(p.pointee.stream_index) == baseVideoIn {
                    let prof = Self.inBandDoViProfile(p, nalLengthSize: scanNalLen)
                    if prof >= 0 {
                        info.dvProfile = prof
                        VXProbe.log("dv", "in-band RPU detected dvProfile=\(prof) (no container DOVI config)")
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
                // For a Profile 7 conversion, re-label the OUTPUT DOVI configuration record as Profile 8.1 so
                // FFmpeg's mov muxer writes a Profile-8 `dvvC` box (dv_profile>7 selects dvvC) and AVPlayer
                // engages true DV. The RPU itself is converted per-packet in the mux loop; this makes the
                // container box agree with the converted bitstream. The EL-present flag is cleared in the relabel.
                if convertP7 {
                    Self.relabelOutputDoViProfile81(outStream.pointee.codecpar)
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

        // [dv] one-line dump of exactly what the muxer is about to validate: the base-video sample-entry fourcc
        // (must be hvc1 for a DV config box, NOT hev1) + the DOVI record fields. Disambiguates a codec_tag
        // problem from a record-field problem in a single live run, whether write_header then succeeds or fails.
        if convertP7, baseVideoOut >= 0, let vpar = outCtx.pointee.streams[baseVideoOut]?.pointee.codecpar {
            let tag = vpar.pointee.codec_tag
            let fourcc = String(bytes: [UInt8(tag & 0xFF), UInt8((tag >> 8) & 0xFF),
                                        UInt8((tag >> 16) & 0xFF), UInt8((tag >> 24) & 0xFF)],
                                encoding: .ascii) ?? "?"
            var maj = -1, lvl = -1, comp = -1, blc = -1, elp = -1
            let n = Int(vpar.pointee.nb_coded_side_data)
            if n > 0, let arr = vpar.pointee.coded_side_data {
                for i in 0..<n where arr[i].type == AV_PKT_DATA_DOVI_CONF {
                    if let d = arr[i].data {
                        d.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { r in
                            maj = Int(r.pointee.dv_version_major); lvl = Int(r.pointee.dv_level)
                            comp = Int(r.pointee.dv_md_compression)
                            blc = Int(r.pointee.dv_bl_signal_compatibility_id); elp = Int(r.pointee.el_present_flag)
                        }
                    }
                }
            }
            VXProbe.log("dv", "pre-write_header video tag=\(fourcc) dvMaj=\(maj) dvLevel=\(lvl) blCompat=\(blc) el=\(elp) mdComp=\(comp)")
        }

        let wh = avformat_write_header(outCtx, &opts)
        if wh < 0 { VXProbe.log("dv", "HDR10 FALLBACK: avformat_write_header rc=\(wh) (convertP7=\(convertP7); the relabel-8.1 dvvC box or the fMP4 muxer rejected the mapped streams)"); buffer.fail("avformat_write_header failed (\(wh))"); return }

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
                    buffer.fail("audio transcode failed mid-stream [prebuffered drain]")
                    return
                }
                continue
            }
            if convertP7, outIdx == baseVideoOut {
                Self.convertPacketRPUToProfile81(p, nalLengthSize: nalLengthSize, stats: &rpuStats)
            }
            p.pointee.stream_index = Int32(outIdx)
            av_packet_rescale_ts(p, inStream.pointee.time_base, outStream.pointee.time_base)
            p.pointee.pos = -1
            let wf = av_interleaved_write_frame(outCtx, p)
            if wf < 0 {
                if isCancelled { break }
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

        // EOF: drain the transcoder's decoder/FIFO/encoder tail into the muxer BEFORE the trailer so the last
        // second of audio is not lost. Best-effort (the file already reached EOF; the trailer is still written).
        if let transcoder {
            _ = transcoder.flush(write: { av_interleaved_write_frame(outCtx, $0) })
        }
        // Flush the muxer trailer (writes the final fragment metadata), then mark the buffer complete.
        av_write_trailer(outCtx)
        buffer.finish()
        NSLog("[dv-remux-stream] done: %d bytes muxed", buffer.producedCount)
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
                // Fully populate the record (not a partial relabel): movenc's DoVi validation wants a complete,
                // internally-consistent Profile 8.1 config. dv_version_major must be 1 and dv_level must be
                // non-zero or mov_init can EINVAL; a P7 source's md_compression may be non-zero, invalid for the
                // fragmented-output DoVi box, so force NONE.
                rec.pointee.dv_version_major = 1
                rec.pointee.dv_version_minor = 0
                rec.pointee.dv_profile = 8
                rec.pointee.dv_level = max(rec.pointee.dv_level, 1)   // keep the source level, never 0
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
