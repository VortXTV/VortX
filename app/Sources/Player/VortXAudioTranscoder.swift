import Foundation
import Libavformat
import Libavcodec
import Libavutil
import Libswresample

/// Transcodes ONE lossless/undecodable source audio track (TrueHD, DTS, DTS-HD MA, MLP, Opus, Vorbis, ...)
/// to an AVPlayer-decodable codec inside the Dolby Vision fMP4 remux, so the AVPlayer DV lane no longer bails
/// to libmpv (HDR10) just because AVPlayer cannot decode the source audio codec.
///
/// CODEC-AGNOSTIC BY DESIGN: the encoder is picked EAC3-first, else AAC. Today's bundled FFmpeg (MPVKit
/// `--enable-encoder=aac`, no ac3/eac3 encoder) resolves that to AAC 5.1/7.1, which AVPlayer decodes natively
/// and the system routes to the receiver as multichannel PCM. The day a rebuilt MPVKit with
/// `--enable-encoder=eac3` lands, the same line resolves to EAC3 and AVPlayer BITSTREAMS Dolby Digital Plus to
/// the receiver, with zero app-code change.
///
/// WHY TRANSCODE AT ALL: pre-tvOS-26 the platform cannot bitstream lossless TrueHD / DTS-HD MA to a receiver
/// (the reference players all decode these to PCM too), so decoded multichannel is the real ceiling. A DV file
/// whose only audio was TrueHD now plays **true Dolby Vision video + multichannel audio** instead of HDR10 + a
/// libmpv tone-map.
///
/// FAIL-SOFT BY CONSTRUCTION: `init?` returns nil and every `feed`/`flush` returns false on any libav error, so
/// the remux calls `buffer.fail(...)` and the chrome demotes to libmpv, i.e. today's exact behavior. Nothing
/// here can regress a file that plays today; it only rescues files that currently tone-map to HDR10.
final class VortXAudioTranscoder {
    private var dec: UnsafeMutablePointer<AVCodecContext>?
    private var enc: UnsafeMutablePointer<AVCodecContext>?
    private var swr: OpaquePointer?                       // SwrContext*
    private var fifo: OpaquePointer?                      // AVAudioFifo*
    private var frame: UnsafeMutablePointer<AVFrame>?     // reused decode-output frame
    private let outStream: UnsafeMutablePointer<AVStream>
    private let sourceTimeBase: AVRational
    private var frameSize: Int32 = 1024
    private var encChannels: Int32 = 2
    /// Running PTS for encoder-input frames, in the ENCODER's 1/sample_rate time base. Seeded once from the
    /// first decoded frame's pts (rescaled from the source stream time base) so the transcoded audio stays in
    /// sync with the stream-copied video; advanced by exactly the samples encoded. Without this every output
    /// packet is NOPTS and the fMP4 muxer misbehaves or the track desyncs.
    private var nextPts: Int64 = 0
    private var ptsSeeded = false

    /// The codec the encoder actually resolved to ("eac3" or "aac"), for the classify log line.
    let encoderName: String

    /// Build a decoder for `sourcePar`, an EAC3-else-AAC encoder matching its rate/channels, a resampler and a
    /// FIFO, and stamp `outStream.codecpar` + `time_base` for the encoded track. nil if the source codec has no
    /// decoder, no encoder is available, or any context fails to open (the caller then fails soft to libmpv).
    /// `sourceTimeBase` is the INPUT stream's time base (packet pts units) used to seed A/V-sync-correct output
    /// timestamps. `globalHeader` must be true for an fMP4 sink so the encoder emits its config as extradata.
    init?(sourcePar: UnsafePointer<AVCodecParameters>, outStream: UnsafeMutablePointer<AVStream>,
          sourceTimeBase: AVRational, globalHeader: Bool) {
        self.outStream = outStream
        self.sourceTimeBase = sourceTimeBase

        guard let decoder = avcodec_find_decoder(sourcePar.pointee.codec_id),
              let dctx = avcodec_alloc_context3(decoder) else { self.encoderName = "?"; return nil }
        self.dec = dctx
        // Decoded frames inherit packet timestamps in this time base; needed for the PTS seed below.
        dctx.pointee.pkt_timebase = sourceTimeBase
        guard avcodec_parameters_to_context(dctx, sourcePar) >= 0 else { encoderName = "?"; cleanup(); return nil }
        dctx.pointee.pkt_timebase = sourceTimeBase   // parameters_to_context may reset it; re-assert
        guard avcodec_open2(dctx, decoder, nil) >= 0 else { encoderName = "?"; cleanup(); return nil }

        // EAC3-first, else AAC. With today's bundled binaries this resolves to AAC; a rebuilt MPVKit with
        // `--enable-encoder=eac3` flips the receiver badge to Dolby Digital Plus with no app-code change.
        guard let encoder = avcodec_find_encoder(AV_CODEC_ID_EAC3) ?? avcodec_find_encoder(AV_CODEC_ID_AAC),
              let ectx = avcodec_alloc_context3(encoder) else { encoderName = "?"; cleanup(); return nil }
        self.enc = ectx
        let isEAC3 = encoder.pointee.id == AV_CODEC_ID_EAC3
        self.encoderName = isEAC3 ? "eac3" : "aac"
        let srcRate = dctx.pointee.sample_rate > 0 ? dctx.pointee.sample_rate : 48_000
        let srcChannels = dctx.pointee.ch_layout.nb_channels > 0 ? dctx.pointee.ch_layout.nb_channels : 2
        // AAC tops out at 7.1; FFmpeg's eac3 encoder tops out at 5.1 (a 7.1 TrueHD source folds to 5.1 there).
        encChannels = min(max(srcChannels, 1), isEAC3 ? 6 : 8)
        // #148: snap the encoder rate to what the encoder actually opens with. The old "AAC keeps the
        // source rate" passed 192/176.4 kHz hi-res TrueHD/DTS-HD straight to avcodec_open2, which rejects
        // anything above 96 kHz (rc=-22), so init? failed and the whole DV session demoted to the libmpv
        // HDR10 tone-map: the "TrueHD reverts to HDR" field report. The resampler below already converts
        // whatever rate delta this produces (it always did for the EAC3 48 kHz cap).
        let encRate = VortXAudioTranscodePolicy.encoderSampleRate(source: srcRate, isEAC3: isEAC3)
        ectx.pointee.sample_rate = encRate
        ectx.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP          // both encoders' native planar-float input
        av_channel_layout_default(&ectx.pointee.ch_layout, encChannels)
        // EAC3 at 768 kb/s is transparent for a 5.1 film bed; AAC ~96 kb/s per channel likewise.
        ectx.pointee.bit_rate = isEAC3 ? 768_000 : Int64(encChannels) * 96_000
        ectx.pointee.time_base = AVRational(num: 1, den: encRate)
        if globalHeader { ectx.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER }
        guard avcodec_open2(ectx, encoder, nil) >= 0 else { cleanup(); return nil }
        frameSize = ectx.pointee.frame_size > 0 ? ectx.pointee.frame_size : 1024

        guard avcodec_parameters_from_context(outStream.pointee.codecpar, ectx) >= 0 else { cleanup(); return nil }
        outStream.pointee.codecpar.pointee.codec_tag = 0
        outStream.pointee.time_base = ectx.pointee.time_base

        var swrCtx: OpaquePointer?
        guard swr_alloc_set_opts2(&swrCtx,
                                  &ectx.pointee.ch_layout, AV_SAMPLE_FMT_FLTP, encRate,
                                  &dctx.pointee.ch_layout, dctx.pointee.sample_fmt,
                                  dctx.pointee.sample_rate > 0 ? dctx.pointee.sample_rate : encRate,
                                  0, nil) >= 0,
              let sc = swrCtx, swr_init(sc) >= 0 else { cleanup(); return nil }
        self.swr = sc

        guard let f = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, encChannels, 1) else { cleanup(); return nil }
        self.fifo = f
        guard let fr = av_frame_alloc() else { cleanup(); return nil }
        self.frame = fr
    }

    /// Feed one source audio packet; encode as many full frames as the FIFO now holds, writing each via
    /// `write` (which does `av_interleaved_write_frame` and returns its rc). Returns false on any libav error.
    func feed(_ pkt: UnsafeMutablePointer<AVPacket>, write: (UnsafeMutablePointer<AVPacket>) -> Int32) -> Bool {
        guard let dec else { return false }
        if avcodec_send_packet(dec, pkt) < 0 { return false }
        return drainDecoder(write: write, flushing: false)
    }

    /// EOF: flush the decoder, drain the FIFO (encoding a final short frame if samples remain), then flush the
    /// encoder. Call once before `av_write_trailer` so the tail audio is not lost.
    func flush(write: (UnsafeMutablePointer<AVPacket>) -> Int32) -> Bool {
        guard let dec, let enc else { return false }
        _ = avcodec_send_packet(dec, nil)
        if !drainDecoder(write: write, flushing: true) { return false }
        _ = avcodec_send_frame(enc, nil)
        return drainEncoder(write: write)
    }

    // MARK: - internals

    private func drainDecoder(write: (UnsafeMutablePointer<AVPacket>) -> Int32, flushing: Bool) -> Bool {
        guard let dec, let enc, let frame, let swr, let fifo else { return false }
        while true {
            let r = avcodec_receive_frame(dec, frame)
            if r == Self.EAGAIN || r == Self.AVEOF { break }
            if r < 0 { return false }
            if !ptsSeeded {
                // Seed the output clock from the FIRST decoded frame so transcoded audio lines up with the
                // stream-copied video (a mid-file audio start would otherwise play from t=0). NOPTS seeds 0.
                let fpts = frame.pointee.pts
                if fpts != Self.AV_NOPTS {
                    nextPts = av_rescale_q(fpts, sourceTimeBase, enc.pointee.time_base)
                }
                ptsSeeded = true
            }
            let ok = resampleIntoFifo(frame, swr: swr, fifo: fifo)
            av_frame_unref(frame)
            if !ok { return false }
        }
        if flushing, !resampleIntoFifo(nil, swr: swr, fifo: fifo) { return false }   // flush swr's own buffer
        return encodeFromFifo(write: write, drainAll: flushing)
    }

    /// Convert one decoded frame (or, when `src` is nil, the resampler's residual buffer) to FLTP and append to
    /// the FIFO. Allocates a scratch planar buffer sized to the converted sample count.
    private func resampleIntoFifo(_ src: UnsafeMutablePointer<AVFrame>?, swr: OpaquePointer, fifo: OpaquePointer) -> Bool {
        let inCount = src?.pointee.nb_samples ?? 0
        let outCount = swr_get_out_samples(swr, inCount)
        if outCount <= 0 { return true }
        var buffers = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: Int(encChannels))
        if av_samples_alloc(&buffers, nil, encChannels, outCount, AV_SAMPLE_FMT_FLTP, 0) < 0 { return false }
        defer { av_freep(&buffers[0]) }
        // swr_convert's input is `const uint8_t * const *` (inner pointee const); rebind the frame's
        // extended_data (uint8_t**) to that shape rather than constructing an UnsafePointer of the array.
        let inPtr: UnsafePointer<UnsafePointer<UInt8>?>? = src.flatMap { f in
            UnsafeRawPointer(f.pointee.extended_data)?.assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        }
        let converted: Int32 = buffers.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafeMutablePointer<UInt8>?.self, capacity: buf.count) { outPtr in
                swr_convert(swr, outPtr, outCount, inPtr, inCount)
            }
        }
        if converted < 0 { return false }
        if converted > 0 {
            let wrote: Int32 = buffers.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: buf.count) { raw in
                    av_audio_fifo_write(fifo, raw, converted)
                }
            }
            if wrote < converted { return false }
        }
        return true
    }

    private func encodeFromFifo(write: (UnsafeMutablePointer<AVPacket>) -> Int32, drainAll: Bool) -> Bool {
        guard let enc, let fifo else { return false }
        while av_audio_fifo_size(fifo) >= frameSize || (drainAll && av_audio_fifo_size(fifo) > 0) {
            let take = min(frameSize, av_audio_fifo_size(fifo))
            guard let ofr = av_frame_alloc() else { return false }
            defer { var o: UnsafeMutablePointer<AVFrame>? = ofr; av_frame_free(&o) }
            ofr.pointee.nb_samples = take
            ofr.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            ofr.pointee.sample_rate = enc.pointee.sample_rate
            if av_channel_layout_copy(&ofr.pointee.ch_layout, &enc.pointee.ch_layout) < 0 { return false }
            if av_frame_get_buffer(ofr, 0) < 0 { return false }
            let read: Int32 = ofr.pointee.extended_data.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: Int(encChannels)) { data in
                av_audio_fifo_read(fifo, data, take)
            }
            if read < take { return false }
            // Stamp the running sample clock (1/sample_rate time base) so every encoded packet carries a
            // monotonic, source-aligned PTS. This is what keeps the fMP4 muxer happy and A/V in sync.
            ofr.pointee.pts = nextPts
            nextPts += Int64(take)
            if avcodec_send_frame(enc, ofr) < 0 { return false }
            if !drainEncoder(write: write) { return false }
        }
        return true
    }

    private func drainEncoder(write: (UnsafeMutablePointer<AVPacket>) -> Int32) -> Bool {
        guard let enc, let pkt = av_packet_alloc() else { return false }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
        while true {
            let r = avcodec_receive_packet(enc, pkt)
            if r == Self.EAGAIN || r == Self.AVEOF { return true }
            if r < 0 { return false }
            pkt.pointee.stream_index = outStream.pointee.index
            // Rescale to the stream's LIVE time base (write_header may retime the stream), not a cached copy.
            av_packet_rescale_ts(pkt, enc.pointee.time_base, outStream.pointee.time_base)
            pkt.pointee.pos = -1
            let w = write(pkt)
            av_packet_unref(pkt)
            if w < 0 { return false }
        }
    }

    private static let EAGAIN: Int32 = -35            // POSIX EAGAIN on Darwin (AVERROR(EAGAIN))
    private static let AVEOF: Int32 = -541478725      // AVERROR_EOF = FFERRTAG('E','O','F',' ')
    private static let AV_NOPTS: Int64 = Int64.min    // AV_NOPTS_VALUE (0x8000000000000000)

    private func cleanup() {
        if dec != nil { var d: UnsafeMutablePointer<AVCodecContext>? = dec; avcodec_free_context(&d); dec = nil }
        if enc != nil { var e: UnsafeMutablePointer<AVCodecContext>? = enc; avcodec_free_context(&e); enc = nil }
        if swr != nil { swr_free(&swr) }
        if fifo != nil { av_audio_fifo_free(fifo); fifo = nil }
        if frame != nil { var f: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&f); frame = nil }
    }

    deinit { cleanup() }
}
