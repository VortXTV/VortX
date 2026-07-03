import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// DV-for-MKV engine, Phase 0 (the go/no-go spike): an IN-PROCESS libav stream-copy remux of a Matroska (MKV)
/// container into a fragmented MP4, WITHOUT re-encoding. Stream-copy re-wraps the exact HEVC access units, so
/// the Dolby Vision RPU (carried as SEI NAL units in the bitstream) and the DOVI configuration box are
/// preserved; only the container changes. The resulting fMP4 can then feed AVPlayer, which negotiates TRUE
/// Dolby Vision with the display for Profile 5 / 8.1 / 8.4 - the path AVPlayer cannot take directly because it
/// has no Matroska demuxer. Profile 7 (dual-layer) has no VideoToolbox support and stays a libmpv HDR10
/// fallback (handled by the router, not here).
///
/// This Phase-0 form writes to a FILE so the spike is trivially testable (remux a short DV MKV -> play the
/// output through a bare AVPlayer on a real Apple TV, confirm the info overlay says Dolby Vision). Phase 1
/// replaces the file sink with an in-memory ring buffer served to AVPlayer via an AVAssetResourceLoaderDelegate
/// so nothing large touches disk. FFmpeg is already linked via MPVKit-GPL (Libavformat/codec/util import
/// directly from Swift - verified).
enum MKVRemuxSession {

    enum RemuxError: Error, CustomStringConvertible {
        case openInput(Int32)
        case findStreamInfo(Int32)
        case allocOutput(Int32)
        case newStream
        case copyParams(Int32)
        case openOutputIO(Int32)
        case writeHeader(Int32)
        case writeFrame(Int32)
        case allocPacket

        var description: String {
            switch self {
            case .openInput(let c):     return "avformat_open_input failed (\(c))"
            case .findStreamInfo(let c): return "avformat_find_stream_info failed (\(c))"
            case .allocOutput(let c):    return "avformat_alloc_output_context2 failed (\(c))"
            case .newStream:             return "avformat_new_stream returned nil"
            case .copyParams(let c):     return "avcodec_parameters_copy failed (\(c))"
            case .openOutputIO(let c):   return "avio_open failed (\(c))"
            case .writeHeader(let c):    return "avformat_write_header failed (\(c))"
            case .writeFrame(let c):     return "av_interleaved_write_frame failed (\(c))"
            case .allocPacket:           return "av_packet_alloc returned nil"
            }
        }
    }

    /// What the remux found in the source - surfaced for the Phase-0 diagnostic (which DV profile, so we know
    /// whether TRUE DV is even possible on this stream: 5/8.1/8.4 = yes via AVPlayer, 7 = HDR10 fallback).
    struct SourceInfo {
        var videoCodec: String = "?"
        var dvProfile: Int = -1     // -1 = no DOVI config found (not DV, or the label lied)
        var dvBLCompatId: Int = -1  // 1 => HDR10-compatible base (8.1), 4 => HLG base (8.4)
        var width: Int = 0
        var height: Int = 0
        var mappedStreams: Int = 0
    }

    /// Remux `input` (a local file path OR a direct/debrid HTTP(S) URL libav can open) to a fragmented MP4 at
    /// `output`. Synchronous + stream-copy only. Returns what it found (DV profile etc). Throws on failure.
    /// Runs off the main thread by the caller.
    @discardableResult
    static func remux(input: String, output: String) throws -> SourceInfo {
        var info = SourceInfo()

        var ifmt: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&ifmt, input, nil, nil) == 0, let inCtx = ifmt else {
            throw RemuxError.openInput(-1)
        }
        defer { var p: UnsafeMutablePointer<AVFormatContext>? = inCtx; avformat_close_input(&p) }

        let si = avformat_find_stream_info(inCtx, nil)
        if si < 0 { throw RemuxError.findStreamInfo(si) }

        var ofmt: UnsafeMutablePointer<AVFormatContext>? = nil
        let ao = avformat_alloc_output_context2(&ofmt, nil, "mp4", output)
        guard ao >= 0, let outCtx = ofmt else { throw RemuxError.allocOutput(ao) }
        defer {
            if let pb = outCtx.pointee.pb, (outCtx.pointee.oformat?.pointee.flags ?? 0) & AVFMT_NOFILE == 0 {
                var io: UnsafeMutablePointer<AVIOContext>? = pb; avio_closep(&io)
            }
            avformat_free_context(outCtx)
        }

        // Map video / audio / subtitle streams 1:1 (skip data/attachment). streamMap[inIndex] = outIndex or -1.
        let nb = Int(inCtx.pointee.nb_streams)
        var streamMap = [Int](repeating: -1, count: nb)
        var outIndex: Int32 = 0
        for i in 0..<nb {
            guard let inStream = inCtx.pointee.streams[i] else { continue }
            let par = inStream.pointee.codecpar
            let type = par?.pointee.codec_type
            guard type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO || type == AVMEDIA_TYPE_SUBTITLE else { continue }
            guard let outStream = avformat_new_stream(outCtx, nil) else { throw RemuxError.newStream }
            let cp = avcodec_parameters_copy(outStream.pointee.codecpar, par)
            if cp < 0 { throw RemuxError.copyParams(cp) }
            outStream.pointee.codecpar.pointee.codec_tag = 0   // let the muxer pick the right sample-entry tag
            streamMap[i] = Int(outIndex)
            outIndex += 1
            info.mappedStreams += 1

            if type == AVMEDIA_TYPE_VIDEO, info.dvProfile < 0 {
                info.width = Int(par?.pointee.width ?? 0)
                info.height = Int(par?.pointee.height ?? 0)
                info.videoCodec = codecName(par?.pointee.codec_id ?? AV_CODEC_ID_NONE)
                readDoVi(par, into: &info)
            }
        }

        // Fragmented MP4 so playback can start before the whole moov is written (and so Phase 1 can stream it).
        var opts: OpaquePointer? = nil   // AVDictionary*
        av_dict_set(&opts, "movflags", "frag_keyframe+empty_moov+default_base_moof+faststart", 0)
        defer { av_dict_free(&opts) }

        if (outCtx.pointee.oformat?.pointee.flags ?? 0) & AVFMT_NOFILE == 0 {
            let io = avio_open(&outCtx.pointee.pb, output, AVIO_FLAG_WRITE)
            if io < 0 { throw RemuxError.openOutputIO(io) }
        }

        let wh = avformat_write_header(outCtx, &opts)
        if wh < 0 { throw RemuxError.writeHeader(wh) }

        guard let pkt = av_packet_alloc() else { throw RemuxError.allocPacket }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }

        while av_read_frame(inCtx, pkt) >= 0 {
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
            if wf < 0 { throw RemuxError.writeFrame(wf) }
        }

        av_write_trailer(outCtx)
        NSLog("[dv-remux] done: %@ %dx%d dvProfile=%d blCompat=%d streams=%d -> %@",
              info.videoCodec, info.width, info.height, info.dvProfile, info.dvBLCompatId, info.mappedStreams, output)
        return info
    }

    // MARK: - helpers

    /// Read the Dolby Vision configuration (profile + BL signal compatibility) from the video stream's coded
    /// side data, if present. Profile 5/8.1/8.4 -> AVPlayer can emit true DV; 7 -> HDR10 fallback; absent -> not DV.
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
