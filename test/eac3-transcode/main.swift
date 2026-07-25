// =============================================================================
// eac3-transcode harness
//
// Proves the Dolby Vision remux lane now delivers Dolby Digital Plus rather than
// silently settling for AAC.
//
// VortXAudioTranscoder.swift asks for AV_CODEC_ID_EAC3 and falls back to AAC. Upstream
// MPVKit's FFmpeg is configured with `--disable-encoders` plus an explicit allowlist that
// contained neither eac3 nor ac3, so that fallback fired on EVERY lossless source: a TrueHD
// or DTS-HD MA track reached the receiver as AAC. Our build adds `--enable-encoder=eac3`.
//
// This drives the REAL VortXAudioTranscoder over a REAL TrueHD track and writes a REAL
// fragmented MP4, so a pass means the whole chain works, not just that a symbol exists.
// The runner then reads the output back with ffprobe.
//
// Exit code = RED count.
// =============================================================================

import Foundation
import Libavformat
import Libavcodec
import Libavutil
import Libswresample

var reds = 0
func check(_ ok: Bool, _ what: String, _ detail: String) {
    print("\(ok ? "GREEN " : "RED   ") \(what): \(detail)")
    if !ok { reds += 1 }
}

let args = CommandLine.arguments
guard args.count > 4 else {
    print("usage: eac3-transcode <input.mkv> <output.mp4> <movflags> <min_frag_duration_us>")
    exit(2)
}
let input = args[1], output = args[2]
// Passed in by the runner, read out of DVPlaybackPolicy.swift, so the harness always muxes with
// the product's own contract instead of a hand-copied guess.
let movflags = args[3], minFragDuration = args[4]

// ---------------------------------------------------------------- 1. the encoder exists

let eac3 = avcodec_find_encoder(AV_CODEC_ID_EAC3)
let ac3 = avcodec_find_encoder(AV_CODEC_ID_AC3)
let aac = avcodec_find_encoder(AV_CODEC_ID_AAC)
check(eac3 != nil, "E-AC-3 encoder present in the linked libavcodec",
      eac3 != nil ? "avcodec_find_encoder(AV_CODEC_ID_EAC3) -> \(String(cString: eac3!.pointee.name))"
                  : "avcodec_find_encoder(AV_CODEC_ID_EAC3) -> nil, so the transcoder can only reach AAC")
// ac3_encoder is pulled in by FFmpeg's own dependency rule eac3_encoder_select="ac3_encoder".
print("NOTE   ac3 encoder: \(ac3 != nil ? "present (selected as an eac3 dependency)" : "absent")")
print("NOTE   aac encoder: \(aac != nil ? "present (the fallback that used to always win)" : "absent")")

// ---------------------------------------------------------------- 2. open the source

var inCtx: UnsafeMutablePointer<AVFormatContext>? = nil
guard avformat_open_input(&inCtx, input, nil, nil) >= 0, avformat_find_stream_info(inCtx, nil) >= 0,
      let ic = inCtx else {
    check(false, "source opened", "avformat_open_input failed for \(input)")
    exit(Int32(max(reds, 1)))
}

var audioIn = -1
for i in 0..<Int(ic.pointee.nb_streams) {
    guard let s = ic.pointee.streams[i] else { continue }
    if s.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO { audioIn = i; break }
}
guard audioIn >= 0, let inStream = ic.pointee.streams[audioIn], let sourcePar = inStream.pointee.codecpar else {
    check(false, "source has an audio track", "none found in \(input)")
    exit(Int32(max(reds, 1)))
}
let sourceCodec = avcodec_get_name(sourcePar.pointee.codec_id).map { String(cString: $0) } ?? "?"
print("NOTE   source audio: \(sourceCodec) \(sourcePar.pointee.ch_layout.nb_channels)ch @ \(sourcePar.pointee.sample_rate) Hz")
check(sourcePar.pointee.codec_id == AV_CODEC_ID_TRUEHD, "source is the lossless shape the fallback used to hit",
      "codec=\(sourceCodec) (want truehd)")

// ---------------------------------------------------------------- 3. the real transcoder

var outCtx: UnsafeMutablePointer<AVFormatContext>? = nil
// Same sink shape the remux uses: fragmented MP4 with out-of-band extradata.
avformat_alloc_output_context2(&outCtx, nil, "mp4", output)
guard let oc = outCtx, let outStream = avformat_new_stream(oc, nil) else {
    check(false, "output context", "avformat_alloc_output_context2 / avformat_new_stream failed")
    exit(Int32(max(reds, 1)))
}

guard let transcoder = VortXAudioTranscoder(sourcePar: sourcePar, outStream: outStream,
                                            sourceTimeBase: inStream.pointee.time_base,
                                            globalHeader: true) else {
    check(false, "VortXAudioTranscoder built", "init? returned nil, the DV session would demote to libmpv")
    exit(Int32(max(reds, 1)))
}
check(transcoder.encoderName == "eac3", "the shipping Swift path SELECTS E-AC-3",
      "VortXAudioTranscoder.encoderName = \"\(transcoder.encoderName)\" (was always \"aac\" before)")

let outCodec = avcodec_get_name(outStream.pointee.codecpar.pointee.codec_id).map { String(cString: $0) } ?? "?"
check(outStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_EAC3, "output track is stamped E-AC-3",
      "outStream.codecpar.codec_id = \(outCodec)")
print("NOTE   encoder opened at \(outStream.pointee.codecpar.pointee.sample_rate) Hz, " +
      "\(outStream.pointee.codecpar.pointee.ch_layout.nb_channels)ch " +
      "(E-AC-3 caps at 5.1, so a 7.1 source folds, as the Swift already documents)")

// ---------------------------------------------------------------- 4. actually mux it

var wrote = 0
if avio_open(&oc.pointee.pb, output, AVIO_FLAG_WRITE) < 0 {
    check(false, "output opened for writing", output)
    exit(Int32(max(reds, 1)))
}
// The REAL muxer options, not a restatement. `delay_moov` in particular is load-bearing for
// E-AC-3: movenc can only build the dec3 atom once it has parsed real frames, and with a plain
// `empty_moov` it refuses write_header outright ("Cannot write moov atom before EAC3 packets
// parsed"). The product already carries delay_moov for the stream-copied AC3/E-AC-3 case, and the
// newly reachable transcoded case needs exactly the same thing.
print("NOTE   muxing with movflags=\(movflags) min_frag_duration=\(minFragDuration)")
var opts: OpaquePointer? = nil
av_dict_set(&opts, "movflags", movflags, 0)
av_dict_set(&opts, "min_frag_duration", minFragDuration, 0)
av_dict_set(&opts, "strict", "experimental", 0)
let hdr = avformat_write_header(oc, &opts)
check(hdr >= 0, "fMP4 header written", "avformat_write_header rc=\(hdr)")
guard hdr >= 0 else {
    print("---")
    print("eac3-transcode: \(reds) RED (aborted, nothing can be muxed without a header)")
    exit(Int32(max(reds, 1)))
}

let pkt = av_packet_alloc()!
while av_read_frame(ic, pkt) >= 0 {
    if Int(pkt.pointee.stream_index) == audioIn {
        let ok = transcoder.feed(pkt) { p in wrote += 1; return av_interleaved_write_frame(oc, p) }
        if !ok { check(false, "transcode fed cleanly", "feed() returned false after \(wrote) packets"); break }
    }
    av_packet_unref(pkt)
}
_ = transcoder.flush { p in wrote += 1; return av_interleaved_write_frame(oc, p) }
let trailer = av_write_trailer(oc)
check(trailer >= 0, "fMP4 trailer written", "av_write_trailer rc=\(trailer)")
check(wrote > 0, "encoded packets actually produced", "\(wrote) E-AC-3 packets written to \(output)")

print("---")
print("eac3-transcode: \(reds) RED")
exit(Int32(reds))
