import Foundation
import Darwin
import os
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
/// called OFF the main thread (it does blocking libav I/O).
///
/// LOCAL FILES ONLY: the packet loop below (`av_read_frame`) walks the ENTIRE container sequentially - text
/// cues are interleaved through the whole file, so there is no cheap way to collect them. On a local file
/// (a finished download) that is a quick disk read; on a network input it makes libav RE-DOWNLOAD the whole
/// file at full rate alongside the player. That second stream was the 0.3.9/0.3.10 Apple TV regression:
/// a streamed 1080p remux (20+ GB, and remuxes are exactly the files that carry embedded text tracks)
/// accumulated frame drops and distorted audio minutes in, stacking a further never-cancelled full-file
/// read on every restart and episode switch, and only running smooth again once a read finished during a
/// long pause. So `extractTextSubtitles` hard-refuses any non-file input; callers can pre-check with
/// `isLocalFileInput` to avoid spawning work at all. The 127.0.0.1 torrent loopback counts as REMOTE - its
/// bytes still have to be downloaded by the torrent engine before they can be read.
enum SubtitleEmbeddedExtractor {

    /// True only for an input that is already fully on this device: an absolute file path or a file:// URL.
    /// Everything else (http/https debrid or CDN links, and the 127.0.0.1 torrent loopback) is remote.
    static func isLocalFileInput(_ input: String) -> Bool {
        if input.hasPrefix("/") { return true }
        if let url = URL(string: input), url.isFileURL { return true }
        return false
    }

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
        guard isLocalFileInput(input) else { return [] }   // see the type doc: never demux a network input
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
            builders[i] = CueBuilder(lang: lang, timeBaseSeconds: timeBase > 0 ? timeBase : 0.001,
                                     assPreTextCommas: assPreTextCommas(ctx: ctx))
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

    /// Absolute positions on the original media timeline, before any playback remux.
    struct TimingWindow: Sendable, Equatable {
        enum Purpose: Sendable, Equatable {
            case subject
            case reference
        }

        let startSeconds: Double
        let endSeconds: Double
        let purpose: Purpose

        init(startSeconds: Double, endSeconds: Double, purpose: Purpose) throws {
            let maximumSpan = purpose == .subject ? 1_200.0 : 1_260.0
            guard startSeconds.isFinite, endSeconds.isFinite,
                  startSeconds >= 0, endSeconds <= 86_400,
                  endSeconds > startSeconds, endSeconds - startSeconds <= maximumSpan else {
                throw TimingWindowFailure.invalidRequest
            }
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.purpose = purpose
        }
    }

    struct TimingCue: Sendable, Equatable {
        let startSeconds: Double
        let endSeconds: Double
    }

    struct TimingLocalFileIdentity: Sendable, Equatable {
        let device: Int64
        let inode: UInt64
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        fileprivate init(_ status: stat) {
            device = Int64(status.st_dev)
            inode = UInt64(status.st_ino)
            byteCount = status.st_size
            modificationSeconds = Int64(status.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changeSeconds = Int64(status.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }

    /// Owns the original descriptor captured BEFORE asynchronous extraction.
    /// Sendable is safe because all fields are immutable, reads use pread (no
    /// shared file offset), and only deinit closes the descriptor. A worker holds
    /// a strong reference for its whole lifetime; cancellation never closes it.
    final class LocalTimingSource: Sendable {
        let identity: TimingLocalFileIdentity
        fileprivate let descriptor: Int32

        private init(descriptor: Int32, identity: TimingLocalFileIdentity) {
            self.descriptor = descriptor
            self.identity = identity
        }

        /// Call outside the playback owner's lock. Capture original load/track/
        /// manual authority first, open/fstat, then compare that SAME admission
        /// again before scheduling the worker. Do not recapture a newer load.
        static func open(input: String) throws -> LocalTimingSource {
            guard !Thread.isMainThread else { throw TimingWindowFailure.mainThread }
            let path = try SubtitleEmbeddedExtractor.localTimingPath(input)
            // O_NONBLOCK avoids a FIFO open waiting before fstat can reject it.
            let descriptor = path.withCString {
                Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else { throw TimingWindowFailure.localIO(errno) }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw TimingWindowFailure.localIO(code)
            }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_size > 0 else {
                Darwin.close(descriptor)
                throw TimingWindowFailure.notRegularFile
            }
            return LocalTimingSource(descriptor: descriptor, identity: TimingLocalFileIdentity(status))
        }

        deinit { Darwin.close(descriptor) }

        /// A fresh fstat comparison. Call outside host-owner locks and off-main.
        /// Throws with the IO/source-change reason rather than hiding it in Bool.
        func validateUnchanged() throws {
            guard !Thread.isMainThread else { throw TimingWindowFailure.mainThread }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw TimingWindowFailure.localIO(errno) }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  TimingLocalFileIdentity(status) == identity else {
                throw TimingWindowFailure.sourceChanged
            }
        }
    }

    /// Contains no source URL, subtitle text, account key, or opaque playback handle.
    /// The owner must compare its captured media/load/track/manual/account generation
    /// before consuming this result. A matching stream index alone is insufficient.
    struct TimingWindowResult: Sendable {
        let originalStreamIndex: Int
        let originalTimestampOriginSeconds: Double
        let sourceIdentity: TimingLocalFileIdentity
        let window: TimingWindow
        /// Original-media position of the existing index used for this sample.
        /// A value after window.startSeconds explicitly exposes a missing prefix.
        let actualIndexedStartSeconds: Double
        let cues: [TimingCue]
        let inputBytesRead: Int64
        let packetsRead: Int
    }

    enum TimingWindowFailure: Error, Sendable, Equatable {
        case invalidRequest
        case mainThread
        case nonLocalInput
        case notRegularFile
        case sourceChanged
        case localIO(Int32)
        case allocation
        case libav(stage: String, code: Int32)
        case missingSelectedStream
        case unsupportedCodec
        case invalidStreamTiming
        case missingBoundedIndex
        case invalidCueTiming
        case invalidTextPayload
        case nonMonotonicPackets
        case cancelled
        case deadline
        case budget(String)
    }

    /// Only the cancellation bit crosses threads. The checked Sendable lock state
    /// contains no libav pointer, decoder, descriptor, cue array, or callback.
    final class TimingWindowCancellation: Sendable {
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        func cancel() { cancelled.withLock { $0 = true } }

        var isCancelled: Bool { cancelled.withLock { $0 } }
    }

    /// Blocking local-only timing extraction. The owner supplies the ORIGINAL mpv
    /// ff-index and a REQUIRED captured demuxer-start-time from that same original
    /// load. Unknown origin must refuse the request; it must never become zero by
    /// failed numeric lookup. Never call this on the main thread.
    ///
    /// Exactly one subtitle decoder is opened. Only indexed local MKV/WebM/MP4 are
    /// eligible. There is one bounded seek and no retry from the beginning. Network,
    /// addon, loopback, bitmap/OCR and Android extraction are separate required work.
    static func extractSelectedTextTimingWindow(
        source: LocalTimingSource,
        originalStreamIndex: Int,
        originalTimestampOriginSeconds: Double,
        window: TimingWindow,
        cancellation: TimingWindowCancellation
    ) -> Result<TimingWindowResult, TimingWindowFailure> {
        guard !Thread.isMainThread else { return .failure(.mainThread) }
        guard originalStreamIndex >= 0, originalStreamIndex < 128,
              originalTimestampOriginSeconds.isFinite,
              abs(originalTimestampOriginSeconds) <= 86_400 else {
            return .failure(.invalidRequest)
        }
        do {
            let reader = try LocalTimingReader(source: source, cancellation: cancellation)
            // The raw opaque pointers below are unretained. Keep the reader alive
            // until AFTER the input context and custom AVIO have both been destroyed.
            defer { withExtendedLifetime(reader) {} }
            let cuesAndPackets = try readSelectedTimingWindow(
                reader: reader,
                originalStreamIndex: originalStreamIndex,
                originalTimestampOriginSeconds: originalTimestampOriginSeconds,
                window: window)
            try reader.checkStop()
            try source.validateUnchanged()
            try reader.checkStop()
            return .success(TimingWindowResult(
                originalStreamIndex: originalStreamIndex,
                originalTimestampOriginSeconds: originalTimestampOriginSeconds,
                sourceIdentity: source.identity,
                window: window,
                actualIndexedStartSeconds: cuesAndPackets.actualIndexedStartSeconds,
                cues: cuesAndPackets.cues,
                inputBytesRead: reader.bytesRead,
                packetsRead: cuesAndPackets.packets))
        } catch let failure as TimingWindowFailure {
            return .failure(failure)
        } catch {
            // All throwing operations above use TimingWindowFailure. Keep the
            // boundary fail-closed if that implementation contract changes.
            return .failure(.invalidRequest)
        }
    }

    private static func localTimingPath(_ input: String) throws -> String {
        guard !input.utf8.contains(0), input.utf8.count <= 4_096 else {
            throw TimingWindowFailure.nonLocalInput
        }
        if input.hasPrefix("/") { return input }
        guard let url = URL(string: input), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
            throw TimingWindowFailure.nonLocalInput
        }
        return url.path
    }

    private static func readSelectedTimingWindow(
        reader: LocalTimingReader,
        originalStreamIndex: Int,
        originalTimestampOriginSeconds: Double,
        window: TimingWindow
    ) throws -> (cues: [TimingCue], packets: Int, actualIndexedStartSeconds: Double) {
        try reader.checkStop()
        guard let context = avformat_alloc_context() else { throw TimingWindowFailure.allocation }
        var format: UnsafeMutablePointer<AVFormatContext>? = context
        var customIO: UnsafeMutablePointer<AVIOContext>?
        var didOpen = false
        defer {
            if didOpen {
                avformat_close_input(&format)
            } else if let format {
                format.pointee.pb = nil
                avformat_free_context(format)
            }
            // CUSTOM_IO keeps libav from closing our AVIO. Close/free the demuxer
            // first, while its read_close implementation can still access pb.
            if let customIO {
                let backing = customIO.pointee.buffer
                var ownedIO: UnsafeMutablePointer<AVIOContext>? = customIO
                avio_context_free(&ownedIO)
                if let backing { av_free(backing) }
            }
        }
        // Both callbacks exist BEFORE avformat_open_input, stream analysis and seek.
        let opaque = Unmanaged.passUnretained(reader).toOpaque()
        context.pointee.interrupt_callback.callback = { opaque in
            guard let opaque else { return 1 }
            let owner = Unmanaged<LocalTimingReader>.fromOpaque(opaque).takeUnretainedValue()
            return owner.shouldInterrupt ? 1 : 0
        }
        context.pointee.interrupt_callback.opaque = opaque
        // Disallow every secondary IO open, including external MP4 data references.
        // No URL, including a path or file:// URL, is handed to the protocol layer.
        context.pointee.io_open = { _, _, _, _, _ in -1 }
        context.pointee.max_streams = 128
        context.pointee.max_probe_packets = 32
        context.pointee.probesize = 1 << 20
        context.pointee.max_analyze_duration = 100_000

        let scratchSize = 32 << 10
        guard let scratch = av_malloc(scratchSize)?.assumingMemoryBound(to: UInt8.self) else {
            throw TimingWindowFailure.allocation
        }
        guard let io = avio_alloc_context(
            scratch, Int32(scratchSize), 0, opaque,
            { opaque, bytes, count in
                guard let opaque, let bytes, count > 0 else { return -1 }
                let owner = Unmanaged<LocalTimingReader>.fromOpaque(opaque).takeUnretainedValue()
                return owner.read(bytes, count: count)
            },
            nil,
            { opaque, offset, whence in
                guard let opaque else { return -1 }
                let owner = Unmanaged<LocalTimingReader>.fromOpaque(opaque).takeUnretainedValue()
                return owner.seek(offset: offset, whence: whence)
            }) else {
            av_free(scratch)
            throw TimingWindowFailure.allocation
        }
        customIO = io
        io.pointee.seekable = 1 // AVIO_SEEKABLE_NORMAL
        context.pointee.pb = io
        context.pointee.flags |= 0x0080 // AVFMT_FLAG_CUSTOM_IO, same importer constant as remux.
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        for (key, value) in [
            ("format_whitelist", "matroska,webm,mov"),
            ("protocol_whitelist", "file"),
            ("enable_drefs", "0"),
            ("use_absolute_path", "0")
        ] {
            let code = av_dict_set(&options, key, value, 0)
            guard code >= 0 else { throw TimingWindowFailure.libav(stage: "options", code: code) }
        }
        let openCode = avformat_open_input(&format, nil, nil, &options)
        didOpen = openCode == 0
        try reader.checkStop()
        guard openCode == 0, let input = format else {
            // On failed open FFmpeg frees/nulls the supplied context. The custom
            // AVIO remains caller-owned and is still released by its own defer.
            throw TimingWindowFailure.libav(stage: "open", code: openCode)
        }
        let streamCount = Int(input.pointee.nb_streams)
        guard streamCount > 0, streamCount <= 128 else { throw TimingWindowFailure.budget("streams") }
        guard originalStreamIndex < streamCount,
              let streams = input.pointee.streams,
              let selected = streams[originalStreamIndex],
              selected.pointee.index == Int32(originalStreamIndex),
              let parameters = selected.pointee.codecpar,
              parameters.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else {
            throw TimingWindowFailure.missingSelectedStream
        }
        guard isTextSubtitle(parameters.pointee.codec_id) else {
            throw TimingWindowFailure.unsupportedCodec
        }
        // Header parsing may enumerate streams, but we never open all-track
        // decoders or run avformat_find_stream_info's multi-track analysis loop.
        // These container headers must already expose the selected text stream.
        for index in 0..<streamCount {
            streams[index]?.pointee.discard = index == originalStreamIndex ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
        let timeBase = av_q2d(selected.pointee.time_base)
        guard selected.pointee.time_base.num > 0, selected.pointee.time_base.den > 0,
              timeBase.isFinite, timeBase > 0,
              parameters.pointee.extradata_size >= 0,
              parameters.pointee.extradata_size <= 65_536 else {
            throw TimingWindowFailure.invalidStreamTiming
        }
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id),
              codec.pointee.capabilities & (1 << 5) == 0 else { // AV_CODEC_CAP_DELAY
            // This timing path must not silently omit delayed final subtitles.
            throw TimingWindowFailure.unsupportedCodec
        }
        guard let decoder = avcodec_alloc_context3(codec) else {
            throw TimingWindowFailure.allocation
        }
        defer { var owned: UnsafeMutablePointer<AVCodecContext>? = decoder; avcodec_free_context(&owned) }
        let copyCode = avcodec_parameters_to_context(decoder, parameters)
        guard copyCode >= 0 else { throw TimingWindowFailure.libav(stage: "decoder-parameters", code: copyCode) }
        decoder.pointee.pkt_timebase = selected.pointee.time_base
        let decoderCode = avcodec_open2(decoder, codec, nil)
        try reader.checkStop()
        guard decoderCode >= 0 else { throw TimingWindowFailure.libav(stage: "decoder-open", code: decoderCode) }
        guard decoder.pointee.subtitle_header_size >= 0, decoder.pointee.subtitle_header_size <= 65_536 else {
            throw TimingWindowFailure.invalidTextPayload
        }
        let assCommas = assPreTextCommas(ctx: decoder)
        let containerTarget = window.startSeconds + originalTimestampOriginSeconds
        let targetTicks = containerTarget / timeBase
        // This check precedes the Double -> Int64 conversion. The narrow range
        // intentionally stays far from Int64's rounded representational boundary.
        guard targetTicks.isFinite, abs(targetTicks) < 9_000_000_000_000_000 else {
            throw TimingWindowFailure.invalidStreamTiming
        }
        let target = Int64(targetTicks.rounded(.down))
        // Matroska's read_seek can otherwise parse deferred cues and eventually
        // invoke FFmpeg's generic packet-scan fallback. Only already indexed text
        // tracks with a nearby anchor AND an existing later index are eligible.
        // This intentionally refuses deferred/absent subtitle indexes.
        guard avformat_index_get_entries_count(selected) >= 2 else {
            throw TimingWindowFailure.missingBoundedIndex
        }
        // The header guarantees an index pointer only until the NEXT call taking
        // this stream/context. Copy its value before asking for the next entry.
        let anchor: AVIndexEntry
        let seekTarget: Int64
        if let pointer = avformat_index_get_entry_from_timestamp(selected, target, 1) {
            anchor = pointer.pointee
            seekTarget = target
        } else if let pointer = avformat_index_get_entry(selected, 0) {
            let first = pointer.pointee
            let firstMediaSeconds = Double(first.timestamp) * timeBase - originalTimestampOriginSeconds
            guard first.timestamp >= target,
                  firstMediaSeconds.isFinite,
                  firstMediaSeconds >= window.startSeconds,
                  firstMediaSeconds <= window.startSeconds + 30,
                  firstMediaSeconds < window.endSeconds else {
                throw TimingWindowFailure.missingBoundedIndex
            }
            // Startup has no earlier usable subtitle index. Seek the exact existing
            // first index, expose that prefix gap in the result, and retain the
            // ORIGINAL requested window for the matcher's confidence denominator.
            anchor = first
            seekTarget = first.timestamp
        } else {
            throw TimingWindowFailure.missingBoundedIndex
        }
        let actualIndexedStart = Double(anchor.timestamp) * timeBase - originalTimestampOriginSeconds
        guard abs(Double(seekTarget)) < 9_000_000_000_000_000,
              actualIndexedStart.isFinite, actualIndexedStart >= 0,
              actualIndexedStart < window.endSeconds,
              abs(actualIndexedStart - window.startSeconds) <= 30,
              let followingPointer = avformat_index_get_entry_from_timestamp(selected, seekTarget + 1, 0) else {
            throw TimingWindowFailure.missingBoundedIndex
        }
        let following = followingPointer.pointee
        guard anchor.timestamp <= seekTarget, following.timestamp > seekTarget,
              reader.containsIndexPosition(anchor.pos),
              reader.containsIndexPosition(following.pos) else {
            throw TimingWindowFailure.missingBoundedIndex
        }
        // One selected-stream seek. A failure is terminal; never restart at zero
        // and collect the whole container to manufacture a window afterwards.
        // No physical read is allowed during seek: even an unexpected internal
        // generic fallback cannot start scanning the local file.
        reader.beginIndexOnlySeek()
        let seekCode = avformat_seek_file(
            input, Int32(originalStreamIndex), Int64.min,
            seekTarget, seekTarget, 1)
        reader.endIndexOnlySeek()
        try reader.checkStop()
        guard seekCode >= 0 else { throw TimingWindowFailure.libav(stage: "seek", code: seekCode) }
        avcodec_flush_buffers(decoder)
        let sample = try collectTimingCues(
            input: input, decoder: decoder, reader: reader,
            originalStreamIndex: originalStreamIndex,
            originSeconds: originalTimestampOriginSeconds,
            timeBase: timeBase, assCommas: assCommas, window: window)
        return (sample.cues, sample.packets, actualIndexedStart)
    }

    private static func collectTimingCues(
        input: UnsafeMutablePointer<AVFormatContext>,
        decoder: UnsafeMutablePointer<AVCodecContext>,
        reader: LocalTimingReader,
        originalStreamIndex: Int,
        originSeconds: Double,
        timeBase: Double,
        assCommas: Int,
        window: TimingWindow
    ) throws -> (cues: [TimingCue], packets: Int) {
        guard let packet = av_packet_alloc() else { throw TimingWindowFailure.allocation }
        defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }
        var cues: [TimingCue] = []
        cues.reserveCapacity(1_024)
        var packets = 0
        var previousPacketPTS: Int64?
        while true {
            try reader.checkStop()
            guard packets < 100_000 else { throw TimingWindowFailure.budget("packets") }
            let code = av_read_frame(input, packet)
            try reader.checkStop()
            if code == -541478725 { break } // AVERROR_EOF from pinned FFmpeg headers/remux code.
            guard code >= 0 else { throw TimingWindowFailure.libav(stage: "packet-read", code: code) }
            packets += 1
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == Int32(originalStreamIndex) else { continue }
            guard packet.pointee.size >= 0, packet.pointee.size <= 65_536 else {
                throw TimingWindowFailure.budget("selected-packet-bytes")
            }
            let pts = packet.pointee.pts
            guard pts != Int64.min else { throw TimingWindowFailure.invalidCueTiming }
            if let previousPacketPTS, pts < previousPacketPTS {
                throw TimingWindowFailure.nonMonotonicPackets
            }
            previousPacketPTS = pts
            let packetStart = Double(pts) * timeBase - originSeconds
            guard packetStart.isFinite else { throw TimingWindowFailure.invalidCueTiming }
            if packetStart >= window.endSeconds { break }
            if let cue = try timingCue(
                packet: packet, decoder: decoder, originSeconds: originSeconds,
                assCommas: assCommas, window: window) {
                // Check BEFORE append. Overflow is a failed extraction, never an
                // apparently complete prefix that the matcher might trust.
                if cues.last != cue {
                    guard cues.count < 1_024 else { throw TimingWindowFailure.budget("cues") }
                    cues.append(cue)
                }
            }
        }
        try reader.checkStop()
        let ordered = cues.sorted {
            $0.startSeconds == $1.startSeconds
                ? $0.endSeconds < $1.endSeconds : $0.startSeconds < $1.startSeconds
        }
        return (ordered, packets)
    }

    /// The decoder's bytes-consumed receipt is independent of whether it emits
    /// a subtitle. Validate complete packet consumption BEFORE considering an
    /// empty output, so a zero-output partial decode cannot discard a remainder.
    static func timingPacketHasOutput(
        bytesConsumed: Int32,
        packetSize: Int32,
        gotSubtitle: Int32,
        rectangleCount: UInt32
    ) throws -> Bool {
        guard packetSize >= 0, bytesConsumed >= 0, bytesConsumed == packetSize else {
            throw TimingWindowFailure.invalidTextPayload
        }
        return gotSubtitle != 0 && rectangleCount > 0
    }

    /// MOV text defines exactly two zero bytes as an empty end-of-cue marker.
    /// Its decoder deliberately returns zero, not a bytes-consumed text receipt.
    /// Validate the entire control packet here; every other payload must still
    /// pass the decoder's unchanged full-consumption check below.
    static func timingPacketIsMovTextClear(
        codecID: AVCodecID, packetSize: Int32, data: UnsafePointer<UInt8>?
    ) -> Bool {
        guard codecID == AV_CODEC_ID_MOV_TEXT, packetSize == 2, let data else { return false }
        return data[0] == 0 && data[1] == 0
    }

    private static func timingCue(
        packet: UnsafeMutablePointer<AVPacket>,
        decoder: UnsafeMutablePointer<AVCodecContext>,
        originSeconds: Double,
        assCommas: Int,
        window: TimingWindow
    ) throws -> TimingCue? {
        if timingPacketIsMovTextClear(
            codecID: decoder.pointee.codec_id,
            packetSize: packet.pointee.size, data: packet.pointee.data) { return nil }
        var subtitle = AVSubtitle()
        var got: Int32 = 0
        let code = avcodec_decode_subtitle2(decoder, &subtitle, &got, packet)
        // avsubtitle_free accepts a zero-initialized/already-cleared AVSubtitle.
        // Keep cleanup on decode-error/empty-output paths as well as success.
        defer { avsubtitle_free(&subtitle) }
        guard code >= 0 else { throw TimingWindowFailure.libav(stage: "subtitle-decode", code: code) }
        guard try timingPacketHasOutput(
            bytesConsumed: code, packetSize: packet.pointee.size,
            gotSubtitle: got, rectangleCount: subtitle.num_rects) else { return nil }
        guard subtitle.format == 1, subtitle.num_rects <= 16, let rects = subtitle.rects else {
            throw TimingWindowFailure.invalidTextPayload
        }
        guard subtitle.pts != Int64.min,
              subtitle.end_display_time > subtitle.start_display_time else {
            // Never use the whole-track extractor's synthetic +3 seconds for
            // alignment; a missing real end cannot support trustworthy evidence.
            throw TimingWindowFailure.invalidCueTiming
        }
        let base = Double(subtitle.pts) / 1_000_000 - originSeconds
        let start = base + Double(subtitle.start_display_time) / 1_000
        let end = base + Double(subtitle.end_display_time) / 1_000
        guard start.isFinite, end.isFinite, end > start else { throw TimingWindowFailure.invalidCueTiming }
        // Keep complete, unmodified cues fully inside the requested media window.
        // Never clip their boundaries or rebase them to the seek/first-cue origin.
        guard start >= window.startSeconds, end <= window.endSeconds else { return nil }
        guard start >= 0, end <= 86_400 else { throw TimingWindowFailure.invalidCueTiming }
        var hasVisibleText = false
        for index in 0..<Int(subtitle.num_rects) {
            guard let rect = rects[index] else { throw TimingWindowFailure.invalidTextPayload }
            if let raw = rect.pointee.text {
                let text = try boundedTimingText(raw)
                hasVisibleText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } else if let raw = rect.pointee.ass {
                let text = try boundedTimingText(raw)
                hasVisibleText = !plainTextFromASS(text, preTextCommas: assCommas).isEmpty
            } else {
                throw TimingWindowFailure.invalidTextPayload
            }
            if hasVisibleText { break }
        }
        // Only timing is retained; decoded payloads are freed when this call exits.
        return hasVisibleText ? TimingCue(startSeconds: start, endSeconds: end) : nil
    }

    private static func boundedTimingText(_ pointer: UnsafePointer<CChar>) throws -> String {
        let count = strnlen(pointer, 65_537)
        guard count <= 65_536 else { throw TimingWindowFailure.invalidTextPayload }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        guard let text = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else {
            throw TimingWindowFailure.invalidTextPayload
        }
        return text
    }

    /// Worker-thread confined. Custom AVIO can read only this already-open regular
    /// descriptor. Cumulative physical read bytes include probing and seek rereads;
    /// seeking does not reset the byte allowance or monotonic deadline.
    private final class LocalTimingReader {
        private static let exitCode: Int32 = -1_414_092_869
        private static let eofCode: Int32 = -541_478_725
        private static let maximumBytes: Int64 = 128 << 20
        private let source: LocalTimingSource
        private let fileSize: Int64
        private let deadline: UInt64
        private let cancellation: TimingWindowCancellation
        private var offset: Int64 = 0
        private var reads = 0
        private var seeks = 0
        private var indexOnlySeek = false
        private(set) var bytesRead: Int64 = 0
        private var stop: TimingWindowFailure?

        init(source: LocalTimingSource, cancellation: TimingWindowCancellation) throws {
            self.source = source
            self.cancellation = cancellation
            deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000_000
            fileSize = source.identity.byteCount
            guard !cancellation.isCancelled else { throw TimingWindowFailure.cancelled }
            try source.validateUnchanged()
        }

        var shouldInterrupt: Bool {
            if stop != nil { return true }
            if cancellation.isCancelled { stop = .cancelled; return true }
            if DispatchTime.now().uptimeNanoseconds >= deadline { stop = .deadline; return true }
            return false
        }

        func checkStop() throws {
            if shouldInterrupt { throw stop ?? TimingWindowFailure.cancelled }
        }

        func containsIndexPosition(_ position: Int64) -> Bool {
            position >= 0 && position < fileSize
        }

        func beginIndexOnlySeek() { indexOnlySeek = true }
        func endIndexOnlySeek() { indexOnlySeek = false }

        func read(_ buffer: UnsafeMutablePointer<UInt8>, count: Int32) -> Int32 {
            guard !shouldInterrupt else { return Self.exitCode }
            guard !indexOnlySeek else { stop = .budget("unindexed-seek-read"); return Self.exitCode }
            guard reads < 8_192 else { stop = .budget("read-calls"); return Self.exitCode }
            guard bytesRead < Self.maximumBytes else { stop = .budget("input-bytes"); return Self.exitCode }
            guard offset < fileSize else { return Self.eofCode }
            let allowed = min(min(Int64(count), 32_768), min(Self.maximumBytes - bytesRead, fileSize - offset))
            guard allowed > 0 else { return Self.eofCode }
            reads += 1
            let result = pread(source.descriptor, buffer, Int(allowed), off_t(offset))
            guard result >= 0 else { stop = .localIO(errno); return Self.exitCode }
            guard result > 0 else { return Self.eofCode }
            offset += Int64(result)
            bytesRead += Int64(result)
            guard !shouldInterrupt else { return Self.exitCode }
            return Int32(result)
        }

        func seek(offset requested: Int64, whence: Int32) -> Int64 {
            guard !shouldInterrupt else { return Int64(Self.exitCode) }
            guard seeks < 4_096 else { stop = .budget("seek-calls"); return Int64(Self.exitCode) }
            seeks += 1
            if whence & 0x10000 != 0 { return fileSize } // AVSEEK_SIZE
            let mode = whence & ~Int32(0x20000) // strip AVSEEK_FORCE
            let base: Int64
            switch mode {
            case SEEK_SET: base = 0
            case SEEK_CUR: base = offset
            case SEEK_END: base = fileSize
            default: return -1
            }
            let (target, overflow) = base.addingReportingOverflow(requested)
            guard !overflow, target >= 0, target <= fileSize else { return -1 }
            offset = target
            return target
        }
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
                let s = plainTextFromASS(String(cString: ass), preTextCommas: builder.assPreTextCommas)
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

    /// The standard v4+ event row (`ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`) has
    /// 8 commas before the Text field. Also what FFmpeg's own default header declares, so SRT / mov_text /
    /// WebVTT events (whose ASS rows the decoders SYNTHESIZE in this exact layout) always use it.
    private static let standardASSPreTextCommas = 8

    /// How many commas precede the Text field in this stream's decoded event rows, read from the `[Events]`
    /// `Format:` line of the decoder's subtitle header. A Matroska ASS/SSA block is NOT normalized to the
    /// standard layout: it is the file's own Dialogue fields with Start/End removed and a ReadOrder prepended
    /// (FFmpeg's `ass` decoder hands that row through verbatim), so a track whose Format declares a
    /// nonstandard field count (v4++ MarginB, trimmed machine-generated Formats, ...) must be split by ITS
    /// declared layout -- the hardcoded standard split left metadata glued to the cue text. NOTE on issue
    /// #76: BOTH leak families exist. The pool poison actually ground-truthed live (imdb:tt32278481,
    /// origin "embedded", `N,0,Default,,0,0,0,,text` on every first cue line) is the pre-0.3.11
    /// split-on-9 raw-row fallback over STANDARD rows; nonstandard-Format files leak the same way under
    /// any fixed-count split, which is what this Format-driven count fixes for NEW extractions. The
    /// renderer's `stripLeakedASSMetadata` covers both families at display time for what is already
    /// pooled. Row shape: `ReadOrder,` + declared fields minus Start/End, Text last,
    /// so pre-Text commas = declaredFields - 2 (+1 ReadOrder, -2 Start/End, -1 Text; each pre-Text field is
    /// comma-terminated). Falls back to the standard 8 when the header is missing or its Format line is
    /// absent or nonconforming.
    private static func assPreTextCommas(ctx: UnsafeMutablePointer<AVCodecContext>) -> Int {
        guard let hdr = ctx.pointee.subtitle_header, ctx.pointee.subtitle_header_size > 0 else {
            return standardASSPreTextCommas
        }
        let data = Data(bytes: hdr, count: Int(ctx.pointee.subtitle_header_size))
        guard let header = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return standardASSPreTextCommas
        }
        // The header buffer may carry a trailing NUL (FFmpeg null-terminates it); drop NULs so the last
        // line's fields still compare clean.
        return preTextCommaCount(inASSHeader: header.replacingOccurrences(of: "\0", with: ""))
    }

    /// Parse `header` (a full ASS/SSA script head) for the `[Events]` section's `Format:` line and derive the
    /// pre-Text comma count of a demuxed event row. Pure + fail-soft: any shape surprise returns the standard 8.
    static func preTextCommaCount(inASSHeader header: String) -> Int {
        var inEvents = false
        for rawLine in header.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)   // tolerate \r\n headers
            if line.hasPrefix("[") {
                inEvents = line.lowercased().hasPrefix("[events]")
                continue
            }
            guard inEvents, line.lowercased().hasPrefix("format:") else { continue }
            let fields = line.dropFirst("format:".count)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            // Only trust a well-formed Events format: Start/End present (they are what ReadOrder replaces in
            // demuxed rows) and Text declared LAST (the only field that may itself contain commas).
            guard fields.count >= 3, fields.last == "text",
                  fields.contains("start"), fields.contains("end") else { return standardASSPreTextCommas }
            return fields.count - 2
        }
        return standardASSPreTextCommas
    }

    /// Extract the visible text from a libavcodec ASS/SSA event packet: split on the stream's declared
    /// pre-Text comma count (see `assPreTextCommas`; commas INSIDE the Text are preserved), then strip
    /// `{...}` override tags and convert `\N` / `\n` to newlines.
    ///
    /// Fail-soft, honestly stated:
    ///  - A row with FEWER total commas than its header declares cannot carry the declared layout. When it
    ///    still satisfies the STANDARD layout (8+ commas) it is split as standard; anything shorter renders
    ///    its raw text (never crashes), and the renderer's display-time scrub covers the residue.
    ///  - The one unrecoverable case: a header over-declaring the count (say 9) over standard rows whose
    ///    TEXT contains commas. Such a row has >= 9 commas, is indistinguishable from a true 9-field row,
    ///    and loses its first text segment up to the first comma. No split choice can tell those apart.
    private static func plainTextFromASS(_ ass: String, preTextCommas: Int) -> String {
        let declared = max(1, preTextCommas)
        let rowCommas = ass.lazy.filter { $0 == "," }.count
        let splits = rowCommas >= declared
            ? declared
            : (rowCommas >= standardASSPreTextCommas ? standardASSPreTextCommas : declared)
        let parts = ass.split(separator: ",", maxSplits: splits, omittingEmptySubsequences: false)
        let textField = parts.count > splits ? String(parts[splits]) : ass
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
        /// Commas before the Text field in this stream's decoded ASS/SSA event rows, derived from the
        /// stream's OWN `[Events]` Format line (standard layout = 8). See `assPreTextCommas(ctx:)`.
        let assPreTextCommas: Int
        private var cues: [(start: Double, end: Double, text: String)] = []

        init(lang: String, timeBaseSeconds: Double, assPreTextCommas: Int) {
            self.lang = lang
            self.timeBaseSeconds = timeBaseSeconds
            self.assPreTextCommas = assPreTextCommas
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
