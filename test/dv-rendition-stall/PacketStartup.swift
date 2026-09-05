import Foundation
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil

// Synthetic container variants, using the same linked FFmpeg as the production remux.
// No network source, account, or copyrighted sample is used by this gate.
private enum PacketFixtureError: Error {
    case failed(String, Int32)
}

private func checked(_ result: Int32, _ operation: String) throws {
    if result < 0 { throw PacketFixtureError.failed(operation, result) }
}

private func makePacketFixture(source: String, destination: String, emptyHvcC: Bool) throws {
    var input: UnsafeMutablePointer<AVFormatContext>?
    try checked(avformat_open_input(&input, source, nil, nil), "open fixture")
    defer { avformat_close_input(&input) }
    guard let input else { throw PacketFixtureError.failed("input", -1) }
    try checked(avformat_find_stream_info(input, nil), "probe fixture")
    var output: UnsafeMutablePointer<AVFormatContext>?
    try checked(avformat_alloc_output_context2(&output, nil, "matroska", destination), "output")
    guard let output else { throw PacketFixtureError.failed("output allocation", -1) }
    defer {
        avio_closep(&output.pointee.pb)
        avformat_free_context(output)
    }
    var map: [Int32: Int32] = [:]
    var videoIndex: Int32 = -1
    var audioFound = false
    var parameterSets = [UInt8]()
    for index in 0..<Int(input.pointee.nb_streams) {
        guard let stream = input.pointee.streams[index], let par = stream.pointee.codecpar else { continue }
        let type = par.pointee.codec_type
        guard (type == AVMEDIA_TYPE_VIDEO && videoIndex < 0)
                || (type == AVMEDIA_TYPE_AUDIO && !audioFound) else { continue }
        guard let out = avformat_new_stream(output, nil) else {
            throw PacketFixtureError.failed("new stream", -1)
        }
        try checked(avcodec_parameters_copy(out.pointee.codecpar, par), "copy parameters")
        out.pointee.time_base = stream.pointee.time_base
        out.pointee.codecpar.pointee.codec_tag = 0
        map[Int32(index)] = out.pointee.index
        if type == AVMEDIA_TYPE_VIDEO {
            videoIndex = Int32(index)
            if emptyHvcC, let ex = par.pointee.extradata, par.pointee.extradata_size >= 23 {
                let size = Int(par.pointee.extradata_size)
                var cursor = 23
                for _ in 0..<Int(ex[22]) {
                    guard cursor + 3 <= size else { throw PacketFixtureError.failed("hvcC arrays", -1) }
                    let nalType = ex[cursor] & 63
                    let count = Int(ex[cursor + 1]) * 256 + Int(ex[cursor + 2])
                    cursor += 3
                    for _ in 0..<count {
                        guard cursor + 2 <= size else { throw PacketFixtureError.failed("hvcC length", -1) }
                        let length = Int(ex[cursor]) * 256 + Int(ex[cursor + 1])
                        cursor += 2
                        guard cursor + length <= size else { throw PacketFixtureError.failed("hvcC NAL", -1) }
                        if [32, 33, 34].contains(Int(nalType)) {
                            parameterSets += [0, 0, UInt8(length >> 8), UInt8(length & 255)]
                            parameterSets += Array(UnsafeBufferPointer(start: ex + cursor, count: length))
                        }
                        cursor += length
                    }
                }
                out.pointee.codecpar.pointee.extradata_size = 23
                out.pointee.codecpar.pointee.extradata[22] = 0
            }
        } else { audioFound = true }
    }
    try checked(avio_open(&output.pointee.pb, destination, 2), "open output")
    try checked(avformat_write_header(output, nil), "write MKV header")
    guard let packet = av_packet_alloc() else { throw PacketFixtureError.failed("packet", -1) }
    defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
    while av_read_frame(input, packet) >= 0 {
        let index = packet.pointee.stream_index
        guard let outIndex = map[index], let inStream = input.pointee.streams[Int(index)],
              let outStream = output.pointee.streams[Int(outIndex)] else {
            av_packet_unref(packet)
            continue
        }
        if index == videoIndex, !parameterSets.isEmpty, packet.pointee.flags & 1 != 0 {
            let oldSize = Int(packet.pointee.size)
            try checked(av_grow_packet(packet, Int32(parameterSets.count)), "grow packet")
            let bytes = packet.pointee.data!
            memmove(bytes + parameterSets.count, bytes, oldSize)
            _ = parameterSets.withUnsafeBytes { raw in memcpy(bytes, raw.baseAddress!, raw.count) }
        }
        av_packet_rescale_ts(packet, inStream.pointee.time_base, outStream.pointee.time_base)
        packet.pointee.stream_index = outIndex
        packet.pointee.pos = -1
        try checked(av_interleaved_write_frame(output, packet), "write MKV packet")
        av_packet_unref(packet)
    }
    try checked(av_write_trailer(output), "MKV trailer")
}

func runPacketStartupRepro(scratchRoot: String) -> Int32 {
    print("PACKET REPRO libavformat=\(avformat_version()) libavcodec=\(avcodec_version())")
    var failures: Int32 = 0
    var controlFrames: Int?
    for empty in [false, true] {
        let name = empty ? "empty-hvcc" : "control"
        let path = scratchRoot + "/fixtures/packet-\(name).mkv"
        do {
            try makePacketFixture(source: scratchRoot + "/fixtures/fixture-multiaudio.mkv",
                                  destination: path, emptyHvcC: empty)
            let terminal = DispatchSemaphore(value: 0)
            let remux = VortXMKVRemuxStream(input: path, headers: nil, indexForHLS: true,
                                          mode: .plain, onProducerTerminal: { terminal.signal() })
            remux.start()
            let result = terminal.wait(timeout: .now() + 30)
            let snapshot = remux.mountProgress()
            print("PACKET \(name) terminal=\(result == .success) progress=\(snapshot)")
            defer { remux.cancel() }
            if result != .success || snapshot.failed || snapshot.producedBytes == 0 { failures += 1 }
            let hls = remux.hlsSnapshot()
            guard let initData = hls.initData, !hls.segments.isEmpty else {
                throw PacketFixtureError.failed("missing published HLS init or media", -1)
            }
            do {
                var movie = initData
                for segment in hls.segments {
                    guard let lease = remux.openHLSResource(.video(segmentID: segment.id)) else {
                        throw PacketFixtureError.failed("published segment unavailable", -1)
                    }
                    defer { lease.close() }
                    movie.append(try lease.read(maxLength: lease.length))
                }
                try movie.write(to: URL(fileURLWithPath: scratchRoot + "/packet-\(name).mp4"))
                print("PACKET \(name) HLS firstStart=\(hls.segments[0].start)")
                if hls.segments[0].start != 0 { failures += 1 }
                let decoded = try decodePacketFixture(scratchRoot + "/packet-\(name).mp4")
                print("PACKET \(name) decodedFrames=\(decoded.count) firstPresentation=\(decoded.firstPTS)")
                if !empty { controlFrames = decoded.count }
                if decoded.count == 0 || decoded.count != controlFrames || !decoded.firstPTS.isFinite || abs(decoded.firstPTS) > 0.001 {
                    failures += 1
                }
            }
        } catch {
            print("PACKET \(name) failed: \(error)")
            failures += 1
        }
    }
    return failures
}

private func decodePacketFixture(_ path: String) throws -> (count: Int, firstPTS: Double) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first else {
        throw PacketFixtureError.failed("missing output video", -1)
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ])
    reader.add(output)
    guard reader.startReading() else { throw PacketFixtureError.failed("decode startup", -1) }
    var count = 0
    var firstPTS = Double.nan
    while let sample = output.copyNextSampleBuffer() {
        if count == 0 { firstPTS = CMSampleBufferGetPresentationTimeStamp(sample).seconds }
        count += 1
    }
    guard reader.status == .completed else { throw reader.error ?? PacketFixtureError.failed("decode", -1) }
    return (count, firstPTS)
}
