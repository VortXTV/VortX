// Production-linked fragmented-MP4 publication harness.
//
//   MPV_ROOT=/path/to/DerivedData/VortX-*/SourcePackages/artifacts/mpvkit
//   FRAMEWORK_KEYS=(Libavformat-GPL Libavcodec-GPL Libavutil-GPL Libavdevice-GPL Libavfilter-GPL
//     Libswresample-GPL Libswscale-GPL Libssl Libcrypto Libass Libfreetype Libfribidi Libharfbuzz
//     Libshaderc_combined lcms2 Libplacebo Libdovi Libunibreak Libsmbclient gmp nettle hogweed gnutls
//     Libdav1d Libuavs3d)
//   LINK_FLAGS=()
//   for key in "${FRAMEWORK_KEYS[@]}"; do
//     slice=$(find "$MPV_ROOT/$key" -type d -name macos-arm64_x86_64 | head -n 1)
//     framework_dir=$(find "$slice" -maxdepth 1 -name '*.framework' -type d | head -n 1)
//     LINK_FLAGS+=( -F "${framework_dir:h}" -framework "${framework_dir:t:r}" )
//   done
//   MOLTEN_ARCHIVE=$(find "$MPV_ROOT/MoltenVK" -path '*macos-arm64_x86_64/libMoltenVK.a' | head -n 1)
//   SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
//   xcrun swiftc -sdk "$SDK_PATH" -strict-concurrency=complete -warnings-as-errors \
//     "${LINK_FLAGS[@]}" "$MOLTEN_ARCHIVE" \
//     -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework CoreVideo \
//     -framework CoreFoundation -framework CoreMedia -framework Metal -framework VideoToolbox \
//     -framework Foundation -framework IOKit -framework IOSurface -framework QuartzCore \
//     -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++ \
//     -o /tmp/hls-fragment-publication-integration-test \
//     app/Sources/Player/DVPlaybackPolicy.swift app/Sources/Player/VortXRemuxBuffer.swift \
//     app/Tests/HLSFragmentPublicationIntegrationTests.swift
//   /tmp/hls-fragment-publication-integration-test
//
// The embedded fixture was encoded once with FFmpeg 8.1.2 as HEVC hvc1 plus AC3. The harness demuxes only
// enough data to obtain real codec parameters and one valid packet of each shape, then drives the exact shipped
// libavformat 62.12.102 movenc through custom AVIO. All fragment decisions and byte proofs call production code.

import Foundation
import Libavformat
import Libavcodec
import Libavutil

struct RemoteConfig {
    struct Snapshot { let dvRemuxWindowMiB: Int }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}

private let avPacketFlagKey: Int32 = 0x0001
private let avFormatFlagCustomIO: Int32 = 0x0080
private let avSeekSize: Int32 = 0x10000
private let avSeekForce: Int32 = 0x20000

private enum HarnessError: Error, CustomStringConvertible {
    case failed(String)
    case timestampRejected(videoWrites: Int, avioWrites: Int, producedBytes: Int)

    var description: String {
        switch self {
        case .failed(let message): return message
        case .timestampRejected(let videoWrites, let avioWrites, let producedBytes):
            return "timestamp rejected before videoWrites=\(videoWrites) avioWrites=\(avioWrites) bytes=\(producedBytes)"
        }
    }
}

private struct PacketTemplate {
    let bytes: Data
    let isIDR: Bool
}

private func packetIsIDR(_ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
        return VortXVideoIDRClassifier.isIDR(
            bytes: base, count: raw.count, codec: .hevc, format: .lengthPrefixed(4))
    }
}

private final class Fixture {
    let videoParameters: UnsafeMutablePointer<AVCodecParameters>
    let audioParameters: UnsafeMutablePointer<AVCodecParameters>
    let idr: PacketTemplate
    let nonIDR: PacketTemplate
    let audio: PacketTemplate

    init(videoParameters: UnsafeMutablePointer<AVCodecParameters>,
         audioParameters: UnsafeMutablePointer<AVCodecParameters>,
         idr: PacketTemplate,
         nonIDR: PacketTemplate,
         audio: PacketTemplate) {
        self.videoParameters = videoParameters
        self.audioParameters = audioParameters
        self.idr = idr
        self.nonIDR = nonIDR
        self.audio = audio
    }

    deinit {
        var video: UnsafeMutablePointer<AVCodecParameters>? = videoParameters
        var audio: UnsafeMutablePointer<AVCodecParameters>? = audioParameters
        avcodec_parameters_free(&video)
        avcodec_parameters_free(&audio)
    }

    static func load(from url: URL) throws -> Fixture {
        var optionalInput: UnsafeMutablePointer<AVFormatContext>?
        let openResult = avformat_open_input(&optionalInput, url.path, nil, nil)
        guard openResult >= 0, let input = optionalInput else {
            throw HarnessError.failed("fixture open failed (\(openResult))")
        }
        defer {
            var optional: UnsafeMutablePointer<AVFormatContext>? = input
            avformat_close_input(&optional)
        }
        let infoResult = avformat_find_stream_info(input, nil)
        guard infoResult >= 0 else {
            throw HarnessError.failed("fixture stream info failed (\(infoResult))")
        }

        var videoStream: UnsafeMutablePointer<AVStream>?
        var audioStream: UnsafeMutablePointer<AVStream>?
        for index in 0..<Int(input.pointee.nb_streams) {
            guard let stream = input.pointee.streams[index], let parameters = stream.pointee.codecpar else { continue }
            if parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO { videoStream = videoStream ?? stream }
            if parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO { audioStream = audioStream ?? stream }
        }
        guard let videoStream, let audioStream,
              let videoCopy = avcodec_parameters_alloc(),
              let audioCopy = avcodec_parameters_alloc() else {
            throw HarnessError.failed("fixture track allocation failed")
        }
        guard avcodec_parameters_copy(videoCopy, videoStream.pointee.codecpar) >= 0,
              avcodec_parameters_copy(audioCopy, audioStream.pointee.codecpar) >= 0 else {
            var video: UnsafeMutablePointer<AVCodecParameters>? = videoCopy
            var audio: UnsafeMutablePointer<AVCodecParameters>? = audioCopy
            avcodec_parameters_free(&video)
            avcodec_parameters_free(&audio)
            throw HarnessError.failed("fixture parameter copy failed")
        }

        guard let packet = av_packet_alloc() else {
            var video: UnsafeMutablePointer<AVCodecParameters>? = videoCopy
            var audio: UnsafeMutablePointer<AVCodecParameters>? = audioCopy
            avcodec_parameters_free(&video)
            avcodec_parameters_free(&audio)
            throw HarnessError.failed("fixture packet allocation failed")
        }
        defer {
            var optional: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&optional)
        }
        var idr: PacketTemplate?
        var nonIDR: PacketTemplate?
        var audio: PacketTemplate?
        while av_read_frame(input, packet) >= 0 {
            let streamIndex = Int(packet.pointee.stream_index)
            if packet.pointee.size > 0, let bytes = packet.pointee.data,
               streamIndex >= 0, streamIndex < Int(input.pointee.nb_streams),
               let stream = input.pointee.streams[streamIndex], let parameters = stream.pointee.codecpar {
                let data = Data(bytes: bytes, count: Int(packet.pointee.size))
                if parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                    let parsedIDR = packetIsIDR(data)
                    if parsedIDR, idr == nil { idr = PacketTemplate(bytes: data, isIDR: true) }
                    if !parsedIDR, nonIDR == nil { nonIDR = PacketTemplate(bytes: data, isIDR: false) }
                } else if parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO, audio == nil {
                    audio = PacketTemplate(bytes: data, isIDR: false)
                }
            }
            av_packet_unref(packet)
            if idr != nil, nonIDR != nil, audio != nil { break }
        }
        guard let idr, let nonIDR, let audio else {
            var video: UnsafeMutablePointer<AVCodecParameters>? = videoCopy
            var audioParameters: UnsafeMutablePointer<AVCodecParameters>? = audioCopy
            avcodec_parameters_free(&video)
            avcodec_parameters_free(&audioParameters)
            throw HarnessError.failed("fixture did not contain IDR, non-IDR, and AC3 packets")
        }
        return Fixture(
            videoParameters: videoCopy,
            audioParameters: audioCopy,
            idr: idr,
            nonIDR: nonIDR,
            audio: audio)
    }
}

private final class RecordingSink {
    private(set) var bytes: [UInt8] = []
    private(set) var writeRanges: [Range<Int>] = []
    private(set) var appendRanges: [Range<Int>] = []
    var cursor = 0

    func write(_ source: UnsafePointer<UInt8>, count: Int) -> Bool {
        guard count > 0, cursor >= 0, cursor <= bytes.count else { return false }
        let end = cursor + count
        guard end >= cursor else { return false }
        writeRanges.append(cursor..<end)
        if cursor == bytes.count {
            bytes.append(contentsOf: UnsafeBufferPointer(start: source, count: count))
            appendRanges.append(cursor..<end)
        } else {
            let overlap = min(count, bytes.count - cursor)
            if overlap > 0 {
                bytes.replaceSubrange(cursor..<(cursor + overlap),
                                      with: UnsafeBufferPointer(start: source, count: overlap))
            }
            if overlap < count {
                bytes.append(contentsOf: UnsafeBufferPointer(start: source + overlap, count: count - overlap))
                appendRanges.append((cursor + overlap)..<end)
            }
        }
        cursor = end
        return true
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence & avSeekSize != 0 { return Int64(bytes.count) }
        let operation = whence & ~avSeekForce
        let target: Int64
        switch operation {
        case 0: target = offset
        case 1: target = Int64(cursor) + offset
        case 2: target = Int64(bytes.count) + offset
        default: return -1
        }
        guard target >= 0, target <= Int64(Int.max) else { return -1 }
        cursor = Int(target)
        return target
    }
}

private struct ScenarioConfig {
    let name: String
    let audioTrackFirst: Bool
    let audioPacketFirst: Bool
    let queueAudioPastBoundaryBeforeKey: Bool
    let boundarySeconds: Double
    let disagreement: Bool
    let paddingBytesPerNonIDR: Int
}

private struct ScenarioResult {
    let name: String
    let initData: Data
    let mediaData: Data
    let writeRanges: [Range<Int>]
    let appendRanges: [Range<Int>]
    let videoTrackID: UInt32
    let audioTrackID: UInt32
    let trackOrder: [UInt32]
    let videoProof: VortXFMP4FragmentParser.MediaRangeProof
    let audioProof: VortXFMP4FragmentParser.MediaRangeProof
    let nextMediaData: Data
    let nextVideoProof: VortXFMP4FragmentParser.MediaRangeProof
    let expectedVideoSamples: Int
    let expectedAudioSamples: Int
    let bytesBeforeBoundaryKey: Int
    let bytesAfterBoundaryKey: Int
    let bytesAfterBoundaryDrain: Int
    let closingRangeCompleteAfterKeyWrite: Bool
    let closingSamplesAfterKeyWrite: Int?
}

private struct PendingInitBoundaryResult {
    let initWasDelayedAtThree: Bool
    let retainedThreeAfterItsWrite: Bool
    let queuedThreeAndSixBeforeConsumption: Bool
    let publicationOrderWasInitFirst: Bool
    let nonIDRFourAvoidedHardFailure: Bool
    let nextLogicalSegmentStartedAtThree: Bool
    let invalidPendingInputStayedFailClosed: Bool
    let consumedSegmentIDs: [Int]
    let publishedByteEndpoints: [Int]
    let firstConsumedAudioToken: String?
    let parserIncompleteCandidateStayedUnpublished: Bool
    let preInitInterleaveDrainCount: Int
    let postInitInterleaveDrainCount: Int
    let consumedCountBeforeFirstPostInitDrain: Int?
    let pendingCountBeforeFirstPostInitDrain: Int?
    let producedBytesBeforeFirstPostInitDrain: Int?
    let producedBytesAfterFirstPostInitDrain: Int?
    let finalPublishedStartSeconds: Double
    let nextSegmentID: Int
}

private struct AlternateAudioResult {
    let prematureSampleCount: Int?
    let firstSegmentProof: VortXFMP4FragmentParser.MediaRangeProof
    let finalSegmentProof: VortXFMP4FragmentParser.MediaRangeProof
    let firstSegmentByteCount: Int
    let finalSegmentCandidateByteCount: Int
    let finalTrailerMetadataIsComplete: Bool
}

/// Deliberately broken local mutant: treats the first `traf` as video instead of resolving `tfhd.track_ID`.
private func firstTrafShortcutProof(_ result: ScenarioResult)
    -> VortXFMP4FragmentParser.MediaRangeProof? {
    guard let firstTrackID = result.trackOrder.first else { return nil }
    return VortXFMP4FragmentParser.proveMediaRange(
        result.mediaData, trackID: firstTrackID, requireFirstSampleSync: false)
}

private struct MuxEvent {
    enum Kind { case video, audio }
    let kind: Kind
    let seconds: Double
    let packet: PacketTemplate
    let keyFlag: Bool
}

private func hvc1Tag() -> UInt32 {
    UInt32(Character("h").asciiValue!) | UInt32(Character("v").asciiValue!) << 8
        | UInt32(Character("c").asciiValue!) << 16 | UInt32(Character("1").asciiValue!) << 24
}

private func paddedHEVC(_ template: PacketTemplate, byteCount: Int) -> PacketTemplate {
    guard byteCount > 6 else { return template }
    let payloadCount = byteCount - 4
    var bytes = template.bytes
    let length = UInt32(payloadCount)
    bytes.append(UInt8((length >> 24) & 0xff))
    bytes.append(UInt8((length >> 16) & 0xff))
    bytes.append(UInt8((length >> 8) & 0xff))
    bytes.append(UInt8(length & 0xff))
    bytes.append(38 << 1)
    bytes.append(1)
    bytes.append(Data(repeating: 0, count: payloadCount - 2))
    return PacketTemplate(bytes: bytes, isIDR: template.isIDR)
}

private func makeEvents(config: ScenarioConfig, fixture: Fixture) -> [MuxEvent] {
    var events: [MuxEvent] = []
    if config.disagreement {
        let video: [(Double, PacketTemplate, Bool)] = [
            (0, fixture.idr, true),
            (0.5, fixture.nonIDR, false),
            (1, fixture.idr, false),
            (1.5, fixture.nonIDR, false),
            (2, fixture.nonIDR, true),
            (2.5, fixture.nonIDR, false),
            (config.boundarySeconds, fixture.idr, true),
        ]
        events.append(contentsOf: video.map {
            MuxEvent(kind: .video, seconds: $0.0, packet: $0.1, keyFlag: $0.2)
        })
    } else {
        // Reuse one immutable padded packet across timestamps. This keeps the real >80 MiB open-GOP fixture's
        // source resident set bounded while movenc still receives and emits every full packet independently.
        let paddedNonIDR = config.paddingBytesPerNonIDR > 0
            ? paddedHEVC(fixture.nonIDR, byteCount: config.paddingBytesPerNonIDR)
            : fixture.nonIDR
        var seconds = 0.0
        while seconds <= config.boundarySeconds + 0.000_001 {
            let boundary = abs(seconds - config.boundarySeconds) < 0.000_001
            let base = seconds == 0 || boundary ? fixture.idr : fixture.nonIDR
            let packet = !base.isIDR ? paddedNonIDR : base
            events.append(MuxEvent(
                kind: .video, seconds: seconds, packet: packet, keyFlag: base.isIDR))
            seconds += 0.25
        }
    }
    var audioSeconds = 0.0
    while audioSeconds < config.boundarySeconds - 0.000_001 {
        events.append(MuxEvent(
            kind: .audio, seconds: audioSeconds, packet: fixture.audio, keyFlag: true))
        audioSeconds += 0.032
    }
    var ordered = events.sorted {
        if abs($0.seconds - $1.seconds) > 0.000_001 { return $0.seconds < $1.seconds }
        if $0.kind == $1.kind { return false }
        return config.audioPacketFirst ? $0.kind == .audio : $0.kind == .video
    }
    if config.queueAudioPastBoundaryBeforeKey,
       let boundaryIndex = ordered.firstIndex(where: {
           $0.kind == .video && abs($0.seconds - config.boundarySeconds) < 0.000_001
       }) {
        // A legal per-stream audio packet from just beyond T is deliberately queued before the video key at T.
        // That gives the interleaver both streams when the key is submitted and forces the schedule where the
        // initial packet write, rather than the later nil drain, delivers the key into movenc.
        ordered.insert(MuxEvent(
            kind: .audio,
            seconds: config.boundarySeconds + 0.032,
            packet: fixture.audio,
            keyFlag: true), at: boundaryIndex)
    }
    return ordered
}

private func initEnd(in bytes: Data) -> Int? {
    func read32(_ offset: Int) -> Int {
        Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }
    var cursor = 0
    while cursor + 8 <= bytes.count {
        let size = read32(cursor)
        guard size >= 8, size <= bytes.count - cursor else { return nil }
        let type = String(bytes: bytes[(cursor + 4)..<(cursor + 8)], encoding: .ascii)
        cursor += size
        if type == "moov" { return cursor }
    }
    return nil
}

private func makePacket(template: PacketTemplate,
                        streamIndex: Int32,
                        timeBase: AVRational,
                        seconds: Double,
                        durationSeconds: Double,
                        keyFlag: Bool) throws -> UnsafeMutablePointer<AVPacket> {
    guard let packet = av_packet_alloc() else { throw HarnessError.failed("packet allocation failed") }
    guard template.bytes.count <= Int(Int32.max),
          av_new_packet(packet, Int32(template.bytes.count)) >= 0,
          let destination = packet.pointee.data else {
        var optional: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&optional)
        throw HarnessError.failed("packet payload allocation failed")
    }
    template.bytes.copyBytes(to: destination, count: template.bytes.count)
    let scale = Double(timeBase.den) / Double(timeBase.num)
    packet.pointee.pts = Int64((seconds * scale).rounded())
    packet.pointee.dts = packet.pointee.pts
    packet.pointee.duration = Int64((durationSeconds * scale).rounded())
    packet.pointee.stream_index = streamIndex
    packet.pointee.flags = keyFlag ? avPacketFlagKey : 0
    packet.pointee.pos = -1
    return packet
}

private func runScenario(_ config: ScenarioConfig,
                         fixture: Fixture,
                         timestampLessFirstVideo: Bool = false) throws -> ScenarioResult {
    let sink = RecordingSink()
    var optionalOutput: UnsafeMutablePointer<AVFormatContext>?
    guard avformat_alloc_output_context2(&optionalOutput, nil, "mp4", nil) >= 0,
          let output = optionalOutput else { throw HarnessError.failed("\(config.name): output allocation failed") }
    var ioContext: UnsafeMutablePointer<AVIOContext>?
    defer {
        output.pointee.pb = nil
        avformat_free_context(output)
        if let ioContext {
            let backing = ioContext.pointee.buffer
            var optional: UnsafeMutablePointer<AVIOContext>? = ioContext
            avio_context_free(&optional)
            if let backing { av_free(backing) }
        }
    }

    guard let ioBytes = av_malloc(256 * 1024)?.assumingMemoryBound(to: UInt8.self) else {
        throw HarnessError.failed("\(config.name): AVIO allocation failed")
    }
    let opaque = Unmanaged.passUnretained(sink).toOpaque()
    ioContext = avio_alloc_context(
        ioBytes, 256 * 1024, 1, opaque, nil,
        { opaque, bytes, size -> Int32 in
            guard let opaque, let bytes, size > 0 else { return -1 }
            let sink = Unmanaged<RecordingSink>.fromOpaque(opaque).takeUnretainedValue()
            return sink.write(bytes, count: Int(size)) ? size : -1
        },
        { opaque, offset, whence -> Int64 in
            guard let opaque else { return -1 }
            return Unmanaged<RecordingSink>.fromOpaque(opaque).takeUnretainedValue()
                .seek(offset: offset, whence: whence)
        })
    guard let ioContext else {
        av_free(ioBytes)
        throw HarnessError.failed("\(config.name): AVIO context creation failed")
    }
    output.pointee.pb = ioContext
    output.pointee.flags |= avFormatFlagCustomIO

    func addVideo() throws -> UnsafeMutablePointer<AVStream> {
        guard let stream = avformat_new_stream(output, nil),
              avcodec_parameters_copy(stream.pointee.codecpar, fixture.videoParameters) >= 0 else {
            throw HarnessError.failed("\(config.name): video stream copy failed")
        }
        stream.pointee.codecpar.pointee.codec_tag = hvc1Tag()
        stream.pointee.time_base = AVRational(num: 1, den: 1_000)
        return stream
    }
    func addAudio() throws -> UnsafeMutablePointer<AVStream> {
        guard let stream = avformat_new_stream(output, nil),
              avcodec_parameters_copy(stream.pointee.codecpar, fixture.audioParameters) >= 0 else {
            throw HarnessError.failed("\(config.name): audio stream copy failed")
        }
        stream.pointee.codecpar.pointee.codec_tag = 0
        if stream.pointee.codecpar.pointee.frame_size == 0 {
            stream.pointee.codecpar.pointee.frame_size = 1536
        }
        stream.pointee.time_base = AVRational(num: 1, den: 48_000)
        return stream
    }

    let videoStream: UnsafeMutablePointer<AVStream>
    let audioStream: UnsafeMutablePointer<AVStream>
    if config.audioTrackFirst {
        audioStream = try addAudio()
        videoStream = try addVideo()
    } else {
        videoStream = try addVideo()
        audioStream = try addAudio()
    }

    var options: OpaquePointer?
    defer { av_dict_free(&options) }
    guard av_dict_set(&options, "movflags", VortXHLSMovencPolicy.movflags, 0) >= 0,
          av_dict_set(
              &options, "min_frag_duration", VortXHLSMovencPolicy.minimumFragmentDurationMicroseconds, 0) >= 0,
          av_dict_set(&options, "strict", "experimental", 0) >= 0 else {
        throw HarnessError.failed("\(config.name): movenc option allocation failed")
    }
    let headerResult = avformat_write_header(output, &options)
    guard headerResult >= 0 else {
        throw HarnessError.failed("\(config.name): delayed AC3 header failed (\(headerResult))")
    }

    var hasOpenSegment = false
    var segmentStartSeconds = 0.0
    var cutCount = 0
    var expectedVideoSamples = 0
    var expectedAudioSamples = 0
    var writtenVideoPackets = 0
    var bytesBeforeBoundaryKey: Int?
    var bytesAfterBoundaryKey: Int?
    let events = makeEvents(config: config, fixture: fixture)
    for event in events {
        let stream = event.kind == .video ? videoStream : audioStream
        var isBoundaryKey = false
        if event.kind == .video {
            let omitTimestamp = timestampLessFirstVideo && writtenVideoPackets == 0
            guard let seconds = VortXHLSBoundaryPolicy.timestampSeconds(
                dts: omitTimestamp ? nil : Int64((event.seconds * 1_000).rounded()),
                pts: nil,
                timeBaseNumerator: 1,
                timeBaseDenominator: 1_000) else {
                if omitTimestamp {
                    throw HarnessError.timestampRejected(
                        videoWrites: writtenVideoPackets,
                        avioWrites: sink.writeRanges.count,
                        producedBytes: sink.bytes.count)
                }
                throw HarnessError.failed("\(config.name): production timestamp gate rejected a valid packet")
            }
            let parsedIDR = packetIsIDR(event.packet.bytes)
            guard parsedIDR == event.packet.isIDR else {
                throw HarnessError.failed("\(config.name): embedded NAL classification changed")
            }
            let decision = VortXHLSBoundaryPolicy.decision(
                hasOpenSegment: hasOpenSegment,
                incomingIsIDR: parsedIDR,
                incomingHasKeyFlag: event.keyFlag,
                elapsed: hasOpenSegment ? seconds - segmentStartSeconds : 0)
            switch decision {
            case .open:
                hasOpenSegment = true
                segmentStartSeconds = seconds
            case .continueOpen:
                break
            case .cut:
                cutCount += 1
                isBoundaryKey = true
            case .failSoft:
                throw HarnessError.failed("\(config.name): production boundary policy failed before the expected cut")
            }
            if event.seconds < config.boundarySeconds - 0.000_001 { expectedVideoSamples += 1 }
        } else if event.seconds < config.boundarySeconds - 0.000_001 {
            expectedAudioSamples += 1
        }

        if isBoundaryKey {
            avio_flush(output.pointee.pb)
            bytesBeforeBoundaryKey = sink.bytes.count
        }

        let packet = try makePacket(
            template: event.packet,
            streamIndex: stream.pointee.index,
            timeBase: stream.pointee.time_base,
            seconds: event.seconds,
            durationSeconds: event.kind == .video ? 0.25 : 0.032,
            keyFlag: event.keyFlag)
        let writeResult = av_interleaved_write_frame(output, packet)
        var optional: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&optional)
        guard writeResult >= 0 else {
            throw HarnessError.failed("\(config.name): interleaved packet write failed (\(writeResult))")
        }
        if isBoundaryKey {
            avio_flush(output.pointee.pb)
            bytesAfterBoundaryKey = sink.bytes.count
        }
        if event.kind == .video { writtenVideoPackets += 1 }
    }
    guard cutCount == 1 else {
        throw HarnessError.failed("\(config.name): expected one both-confirmed boundary, got \(cutCount)")
    }
    let drainResult = av_interleaved_write_frame(output, nil)
    guard drainResult >= 0 else {
        throw HarnessError.failed("\(config.name): interleave drain failed (\(drainResult))")
    }
    avio_flush(output.pointee.pb)
    let bytesAfterBoundaryDrain = sink.bytes.count

    let closedCapture = Data(sink.bytes)
    guard let initEnd = initEnd(in: closedCapture), initEnd < closedCapture.count,
          let bytesBeforeBoundaryKey, let bytesAfterBoundaryKey,
          bytesBeforeBoundaryKey <= bytesAfterBoundaryKey,
          bytesAfterBoundaryKey <= bytesAfterBoundaryDrain else {
        throw HarnessError.failed("\(config.name): delayed init or first media fragment was incomplete")
    }
    let initData = closedCapture.prefix(initEnd)
    let mediaData = closedCapture[initEnd..<bytesAfterBoundaryDrain]
    guard let videoTrackID = VortXFMP4FragmentParser.videoTrackID(inInit: Data(initData)),
          let audioTrackID = VortXFMP4FragmentParser.audioTrackID(inInit: Data(initData)),
          let trackOrder = VortXFMP4FragmentParser.trackIDsInFirstFragment(Data(mediaData)),
          videoTrackID != audioTrackID,
          Set(trackOrder).isSuperset(of: [videoTrackID, audioTrackID]) else {
        throw HarnessError.failed("\(config.name): hvc1 and AC3 track IDs were not preserved")
    }
    guard let videoProof = VortXFMP4FragmentParser.proveMediaRange(
              Data(mediaData), trackID: videoTrackID, requireFirstSampleSync: true),
          let audioProof = VortXFMP4FragmentParser.proveMediaRange(
              Data(mediaData), trackID: audioTrackID, requireFirstSampleSync: false) else {
        throw HarnessError.failed("\(config.name): production fragment proof rejected shipped movenc output")
    }
    let afterKeyProof: VortXFMP4FragmentParser.MediaRangeProof? = {
        guard bytesAfterBoundaryKey > initEnd else { return nil }
        return VortXFMP4FragmentParser.proveMediaRange(
            Data(closedCapture[initEnd..<bytesAfterBoundaryKey]),
            trackID: videoTrackID,
            requireFirstSampleSync: true)
    }()
    let trailerResult = av_write_trailer(output)
    guard trailerResult >= 0 else {
        throw HarnessError.failed("\(config.name): trailer failed (\(trailerResult))")
    }
    avio_flush(output.pointee.pb)
    let finalCapture = Data(sink.bytes)
    guard bytesAfterBoundaryDrain < finalCapture.count else {
        throw HarnessError.failed("\(config.name): trailer did not complete the next media range")
    }
    let nextMediaData = Data(finalCapture[bytesAfterBoundaryDrain..<finalCapture.count])
    guard let nextVideoProof = VortXFMP4FragmentParser.proveMediaRange(
        nextMediaData, trackID: videoTrackID, requireFirstSampleSync: true) else {
        throw HarnessError.failed("\(config.name): next range did not begin with the boundary key")
    }

    return ScenarioResult(
        name: config.name,
        initData: Data(initData),
        mediaData: Data(mediaData),
        writeRanges: sink.writeRanges,
        appendRanges: sink.appendRanges,
        videoTrackID: videoTrackID,
        audioTrackID: audioTrackID,
        trackOrder: trackOrder,
        videoProof: videoProof,
        audioProof: audioProof,
        nextMediaData: nextMediaData,
        nextVideoProof: nextVideoProof,
        expectedVideoSamples: expectedVideoSamples,
        expectedAudioSamples: expectedAudioSamples,
        bytesBeforeBoundaryKey: bytesBeforeBoundaryKey,
        bytesAfterBoundaryKey: bytesAfterBoundaryKey,
        bytesAfterBoundaryDrain: bytesAfterBoundaryDrain,
        closingRangeCompleteAfterKeyWrite: afterKeyProof?.sampleCount == expectedVideoSamples,
        closingSamplesAfterKeyWrite: afterKeyProof?.sampleCount)
}

/// Drives keys at 0/3/6 and a non-IDR at 4 through shipped movenc plus the production pending-boundary queue.
/// The natural schedule observes init after every ordinary video write. A second, explicitly injected schedule
/// defers only the harness's observation of already-produced init bytes until key six, forcing both boundaries
/// into the exact production FIFO. Its first parser observation is also explicitly delayed until the one real
/// movenc drain, proving that concrete progress retains an incomplete successor rather than hard-failing it.
private func runPendingInitBoundaryScenario(
    fixture: Fixture,
    deferInitObservationUntilSix: Bool
) throws -> PendingInitBoundaryResult {
    let name = deferInitObservationUntilSix
        ? "injected delayed-observation two-boundary FIFO"
        : "natural delayed-init pending-boundary production state"
    let sink = RecordingSink()
    var optionalOutput: UnsafeMutablePointer<AVFormatContext>?
    guard avformat_alloc_output_context2(&optionalOutput, nil, "mp4", nil) >= 0,
          let output = optionalOutput else { throw HarnessError.failed("\(name): output allocation failed") }
    var ioContext: UnsafeMutablePointer<AVIOContext>?
    defer {
        output.pointee.pb = nil
        avformat_free_context(output)
        if let ioContext {
            let backing = ioContext.pointee.buffer
            var optional: UnsafeMutablePointer<AVIOContext>? = ioContext
            avio_context_free(&optional)
            if let backing { av_free(backing) }
        }
    }

    guard let ioBytes = av_malloc(256 * 1024)?.assumingMemoryBound(to: UInt8.self) else {
        throw HarnessError.failed("\(name): AVIO allocation failed")
    }
    let opaque = Unmanaged.passUnretained(sink).toOpaque()
    ioContext = avio_alloc_context(
        ioBytes, 256 * 1024, 1, opaque, nil,
        { opaque, bytes, size -> Int32 in
            guard let opaque, let bytes, size > 0 else { return -1 }
            let sink = Unmanaged<RecordingSink>.fromOpaque(opaque).takeUnretainedValue()
            return sink.write(bytes, count: Int(size)) ? size : -1
        },
        { opaque, offset, whence -> Int64 in
            guard let opaque else { return -1 }
            return Unmanaged<RecordingSink>.fromOpaque(opaque).takeUnretainedValue()
                .seek(offset: offset, whence: whence)
        })
    guard let ioContext else {
        av_free(ioBytes)
        throw HarnessError.failed("\(name): AVIO context creation failed")
    }
    output.pointee.pb = ioContext
    output.pointee.flags |= avFormatFlagCustomIO

    guard let videoStream = avformat_new_stream(output, nil),
          avcodec_parameters_copy(videoStream.pointee.codecpar, fixture.videoParameters) >= 0,
          let audioStream = avformat_new_stream(output, nil),
          avcodec_parameters_copy(audioStream.pointee.codecpar, fixture.audioParameters) >= 0 else {
        throw HarnessError.failed("\(name): stream copy failed")
    }
    videoStream.pointee.codecpar.pointee.codec_tag = hvc1Tag()
    videoStream.pointee.time_base = AVRational(num: 1, den: 1_000)
    audioStream.pointee.codecpar.pointee.codec_tag = 0
    if audioStream.pointee.codecpar.pointee.frame_size == 0 {
        audioStream.pointee.codecpar.pointee.frame_size = 1536
    }
    audioStream.pointee.time_base = AVRational(num: 1, den: 48_000)

    var options: OpaquePointer?
    defer { av_dict_free(&options) }
    guard av_dict_set(&options, "movflags", VortXHLSMovencPolicy.movflags, 0) >= 0,
          av_dict_set(
              &options, "min_frag_duration", VortXHLSMovencPolicy.minimumFragmentDurationMicroseconds, 0) >= 0,
          av_dict_set(&options, "strict", "experimental", 0) >= 0,
          avformat_write_header(output, &options) >= 0 else {
        throw HarnessError.failed("\(name): delayed header setup failed")
    }

    let videoEvents: [MuxEvent] = [
        MuxEvent(kind: .video, seconds: 0, packet: fixture.idr, keyFlag: true),
        MuxEvent(kind: .video, seconds: 1, packet: fixture.nonIDR, keyFlag: false),
        MuxEvent(kind: .video, seconds: 2, packet: fixture.nonIDR, keyFlag: false),
        MuxEvent(kind: .video, seconds: 3, packet: fixture.idr, keyFlag: true),
        MuxEvent(kind: .video, seconds: 4, packet: fixture.nonIDR, keyFlag: false),
        MuxEvent(kind: .video, seconds: 5, packet: fixture.nonIDR, keyFlag: false),
        MuxEvent(kind: .video, seconds: 6, packet: fixture.idr, keyFlag: true),
    ]
    var events = videoEvents
    var audioSeconds = 0.0
    while audioSeconds < 6.25 {
        events.append(MuxEvent(
            kind: .audio,
            seconds: audioSeconds,
            packet: fixture.audio,
            keyFlag: true))
        audioSeconds += 0.032
    }
    events.sort {
        if abs($0.seconds - $1.seconds) > 0.000_001 { return $0.seconds < $1.seconds }
        if $0.kind == $1.kind { return false }
        return $0.kind == .audio
    }

    var hasOpenSegment = false
    var publishedStartSeconds = 0.0
    var publishedStartByte: Int?
    var videoTrackID: UInt32?
    let pending = VortXHLSPendingPublicationMachine<String?>()
    var consumedSegmentIDs: [Int] = []
    var publishedByteEndpoints: [Int] = []
    var firstConsumedAudioToken: String?
    var initWasDelayedAtThree = false
    var retainedThreeAfterItsWrite = false
    var queuedThreeAndSixBeforeConsumption = false
    var nonIDRFourAvoidedHardFailure = false
    var nextLogicalSegmentStartedAtThree = false
    var invalidPendingInputStayedFailClosed = false
    var parserIncompleteCandidateStayedUnpublished = false
    var preInitInterleaveDrainCount = 0
    var postInitInterleaveDrainCount = 0
    var consumedCountBeforeFirstPostInitDrain: Int?
    var pendingCountBeforeFirstPostInitDrain: Int?
    var producedBytesBeforeFirstPostInitDrain: Int?
    var producedBytesAfterFirstPostInitDrain: Int?
    var eventOrdinal = 0
    var initPublicationOrdinal: Int?
    var segmentPublicationOrdinals: [Int] = []
    var initObservationPermitted = !deferInitObservationUntilSix
    var injectedIncompleteProbeUsed = false

    func refreshInitFromOrdinaryOutput() {
        guard initObservationPermitted, publishedStartByte == nil else { return }
        let capture = Data(sink.bytes)
        guard let discoveredInitEnd = initEnd(in: capture),
              let discoveredTrackID = VortXFMP4FragmentParser.videoTrackID(
                  inInit: Data(capture.prefix(discoveredInitEnd))) else { return }
        publishedStartByte = discoveredInitEnd
        videoTrackID = discoveredTrackID
        eventOrdinal += 1
        initPublicationOrdinal = eventOrdinal
    }

    func advancePending(
        allowPostInitDrain: Bool = true,
        incompleteIsTerminal: Bool = false
    ) -> VortXHLSPendingPublicationMachine<String?>.AdvanceResult {
        pending.advance(
            initMayPublishMedia: { publishedStartByte != nil },
            allowPostInitDrain: allowPostInitDrain,
            incompleteIsTerminal: incompleteIsTerminal,
            proveNextFragment: {
                guard let startByte = publishedStartByte,
                      let trackID = videoTrackID else { return nil as Int? }
                if deferInitObservationUntilSix,
                   !injectedIncompleteProbeUsed,
                   pending.count == 2 {
                    injectedIncompleteProbeUsed = true
                    return nil
                }
                let capture = Data(sink.bytes)
                guard startByte < capture.count else { return nil }
                let candidate = Data(capture[startByte..<capture.count])
                guard let proof = VortXFMP4FragmentParser.proveFirstMediaFragment(
                    candidate, trackID: trackID, requireFirstSampleSync: true),
                      packetIsIDR(proof.firstSampleBytes) else { return nil }
                if !parserIncompleteCandidateStayedUnpublished, proof.mediaEnd > 1 {
                    let incomplete = Data(candidate.prefix(proof.mediaEnd).dropLast())
                    let incompleteMachine = VortXHLSPendingPublicationMachine<String?>()
                    _ = incompleteMachine.append(
                        segmentID: 0, startSeconds: 0, endSeconds: 3, payload: nil)
                    var incompletePublishCalls = 0
                    var incompleteDrainCalls = 0
                    let incompleteResult = incompleteMachine.advance(
                        initMayPublishMedia: { true },
                        allowPostInitDrain: false,
                        proveNextFragment: {
                            VortXFMP4FragmentParser.proveFirstMediaFragment(
                                incomplete,
                                trackID: trackID,
                                requireFirstSampleSync: true)?.mediaEnd
                        },
                        performPostInitDrain: {
                            incompleteDrainCalls += 1
                            return true
                        },
                        publish: { _, _ in
                            incompletePublishCalls += 1
                            return true
                        })
                    parserIncompleteCandidateStayedUnpublished =
                        incompleteResult == .waitingForFragment
                        && incompleteMachine.first?.segmentID == 0
                        && incompletePublishCalls == 0
                        && incompleteDrainCalls == 0
                }
                return startByte + proof.mediaEnd
            },
            performPostInitDrain: {
                if publishedStartByte == nil {
                    preInitInterleaveDrainCount += 1
                } else {
                    if consumedCountBeforeFirstPostInitDrain == nil {
                        consumedCountBeforeFirstPostInitDrain = consumedSegmentIDs.count
                        pendingCountBeforeFirstPostInitDrain = pending.count
                        producedBytesBeforeFirstPostInitDrain = sink.bytes.count
                    }
                    postInitInterleaveDrainCount += 1
                }
                let rc = av_interleaved_write_frame(output, nil)
                avio_flush(output.pointee.pb)
                if producedBytesAfterFirstPostInitDrain == nil {
                    producedBytesAfterFirstPostInitDrain = sink.bytes.count
                }
                refreshInitFromOrdinaryOutput()
                return rc >= 0
            },
            publish: { consumed, provenEndByte in
                guard initPublicationOrdinal != nil,
                      provenEndByte > (publishedStartByte ?? Int.max) else { return false }
                eventOrdinal += 1
                segmentPublicationOrdinals.append(eventOrdinal)
                if firstConsumedAudioToken == nil { firstConsumedAudioToken = consumed.payload }
                consumedSegmentIDs.append(consumed.segmentID)
                publishedByteEndpoints.append(provenEndByte)
                publishedStartSeconds = consumed.endSeconds
                publishedStartByte = provenEndByte
                return true
            })
    }

    for event in events {
        let stream = event.kind == .video ? videoStream : audioStream
        var boundaryToAttach: Int?
        if event.kind == .video {
            let logicalStart = pending.logicalSegmentStartSeconds ?? publishedStartSeconds
            let parsedIDR = packetIsIDR(event.packet.bytes)
            let rawDecision = VortXHLSBoundaryPolicy.decision(
                hasOpenSegment: hasOpenSegment,
                incomingIsIDR: parsedIDR,
                incomingHasKeyFlag: event.keyFlag,
                elapsed: hasOpenSegment ? event.seconds - logicalStart : 0)
            switch rawDecision {
            case .open:
                hasOpenSegment = true
                publishedStartSeconds = event.seconds
            case .continueOpen:
                if event.seconds == 4 {
                    nonIDRFourAvoidedHardFailure = true
                    nextLogicalSegmentStartedAtThree = logicalStart == 3
                }
            case .cut:
                let segmentID = consumedSegmentIDs.count + pending.count
                guard pending.append(
                    segmentID: segmentID,
                    startSeconds: logicalStart,
                    endSeconds: event.seconds,
                    payload: nil) else {
                    throw HarnessError.failed("\(name): pending FIFO rejected boundary \(segmentID)")
                }
                boundaryToAttach = segmentID
                if event.seconds == 6 {
                    queuedThreeAndSixBeforeConsumption =
                        consumedSegmentIDs.isEmpty
                        && pending.count == 2
                        && pending.first?.endSeconds == 3
                        && pending.logicalSegmentStartSeconds == 6
                }
            case .failSoft:
                throw HarnessError.failed("\(name): non-IDR hard-failed after a retained boundary")
            }
        }

        let packet = try makePacket(
            template: event.packet,
            streamIndex: stream.pointee.index,
            timeBase: stream.pointee.time_base,
            seconds: event.seconds,
            durationSeconds: event.kind == .video ? 1 : 0.032,
            keyFlag: event.keyFlag)
        let writeResult = av_interleaved_write_frame(output, packet)
        var optional: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&optional)
        guard writeResult >= 0 else {
            throw HarnessError.failed("\(name): ordinary interleaved write failed (\(writeResult))")
        }
        guard event.kind == .video else { continue }

        // The token is an exact payload-ID retention surrogate for the generic production machine. The separate
        // alternate-audio movenc scenario below proves real AC3 sample completion and trailer behavior.
        if let boundaryToAttach,
           !pending.attachPayload("audio-\(boundaryToAttach)", toSegmentID: boundaryToAttach) {
            throw HarnessError.failed("\(name): late audio did not attach to boundary \(boundaryToAttach)")
        }

        if deferInitObservationUntilSix, event.seconds >= 6 {
            initObservationPermitted = true
        }
        avio_flush(output.pointee.pb)
        refreshInitFromOrdinaryOutput()
        let advanceResult = advancePending()
        if case .failed(let failure) = advanceResult {
            throw HarnessError.failed("\(name): production pending machine failed \(failure)")
        }
        if event.seconds == 3 {
            initWasDelayedAtThree = publishedStartByte == nil
            retainedThreeAfterItsWrite = pending.first?.segmentID == 0
                && pending.first?.endSeconds == 3
            let invalidDecision = VortXHLSBoundaryPolicy.decision(
                hasOpenSegment: true,
                incomingIsIDR: false,
                incomingHasKeyFlag: false,
                elapsed: -1)
            invalidPendingInputStayedFailClosed = invalidDecision == .failSoft
        }
    }

    guard av_write_trailer(output) >= 0 else {
        throw HarnessError.failed("\(name): trailer failed")
    }
    avio_flush(output.pointee.pb)
    refreshInitFromOrdinaryOutput()
    let terminalAdvance = advancePending(
        allowPostInitDrain: false,
        incompleteIsTerminal: true)
    guard terminalAdvance == .settled else {
        throw HarnessError.failed("\(name): terminal pending machine did not settle (\(terminalAdvance))")
    }
    let publicationOrderWasInitFirst: Bool = {
        guard let initPublicationOrdinal,
              !segmentPublicationOrdinals.isEmpty else { return false }
        return segmentPublicationOrdinals.allSatisfy { $0 > initPublicationOrdinal }
    }()

    let result = PendingInitBoundaryResult(
        initWasDelayedAtThree: initWasDelayedAtThree,
        retainedThreeAfterItsWrite: retainedThreeAfterItsWrite,
        queuedThreeAndSixBeforeConsumption: queuedThreeAndSixBeforeConsumption,
        publicationOrderWasInitFirst: publicationOrderWasInitFirst,
        nonIDRFourAvoidedHardFailure: nonIDRFourAvoidedHardFailure,
        nextLogicalSegmentStartedAtThree: nextLogicalSegmentStartedAtThree,
        invalidPendingInputStayedFailClosed: invalidPendingInputStayedFailClosed,
        consumedSegmentIDs: consumedSegmentIDs,
        publishedByteEndpoints: publishedByteEndpoints,
        firstConsumedAudioToken: firstConsumedAudioToken,
        parserIncompleteCandidateStayedUnpublished: parserIncompleteCandidateStayedUnpublished,
        preInitInterleaveDrainCount: preInitInterleaveDrainCount,
        postInitInterleaveDrainCount: postInitInterleaveDrainCount,
        consumedCountBeforeFirstPostInitDrain: consumedCountBeforeFirstPostInitDrain,
        pendingCountBeforeFirstPostInitDrain: pendingCountBeforeFirstPostInitDrain,
        producedBytesBeforeFirstPostInitDrain: producedBytesBeforeFirstPostInitDrain,
        producedBytesAfterFirstPostInitDrain: producedBytesAfterFirstPostInitDrain,
        finalPublishedStartSeconds: publishedStartSeconds,
        nextSegmentID: consumedSegmentIDs.count)
    return result
}

private func timestampLessPublicationAttemptIsRejected(fixture: Fixture) -> Bool {
    let config = ScenarioConfig(
        name: "timestamp-less first video",
        audioTrackFirst: false,
        audioPacketFirst: false,
        queueAudioPastBoundaryBeforeKey: false,
        boundarySeconds: 1,
        disagreement: false,
        paddingBytesPerNonIDR: 0)
    do {
        _ = try runScenario(config, fixture: fixture, timestampLessFirstVideo: true)
        return false
    } catch HarnessError.timestampRejected(let videoWrites, let avioWrites, let producedBytes) {
        return videoWrites == 0 && avioWrites == 0 && producedBytes == 0
    } catch {
        return false
    }
}

/// Drives the shipped movenc through the alternate lane's production flags and parser while mirroring the private
/// pending-segment state machine. The fourth packet is the first packet of logical segment 1 and must complete
/// exactly the three samples in segment 0. The trailer completes exactly the two samples in segment 1. This also
/// proves that a plain AVIO flush would have advertised only two of the three logical samples.
private func runAlternateAudioScenario(fixture: Fixture) throws -> AlternateAudioResult {
    let sink = RecordingSink()
    var optionalOutput: UnsafeMutablePointer<AVFormatContext>?
    guard avformat_alloc_output_context2(&optionalOutput, nil, "mp4", nil) >= 0,
          let output = optionalOutput else {
        throw HarnessError.failed("alternate audio: output allocation failed")
    }
    var ioContext: UnsafeMutablePointer<AVIOContext>?
    defer {
        output.pointee.pb = nil
        avformat_free_context(output)
        if let ioContext {
            let backing = ioContext.pointee.buffer
            var optional: UnsafeMutablePointer<AVIOContext>? = ioContext
            avio_context_free(&optional)
            if let backing { av_free(backing) }
        }
    }
    guard let ioBytes = av_malloc(256 * 1024)?.assumingMemoryBound(to: UInt8.self) else {
        throw HarnessError.failed("alternate audio: AVIO allocation failed")
    }
    let opaque = Unmanaged.passUnretained(sink).toOpaque()
    ioContext = avio_alloc_context(
        ioBytes, 256 * 1024, 1, opaque, nil,
        { opaque, bytes, size -> Int32 in
            guard let opaque, let bytes, size > 0 else { return -1 }
            let sink = Unmanaged<RecordingSink>.fromOpaque(opaque).takeUnretainedValue()
            return sink.write(bytes, count: Int(size)) ? size : -1
        },
        { opaque, offset, whence -> Int64 in
            guard let opaque else { return -1 }
            return Unmanaged<RecordingSink>.fromOpaque(opaque).takeUnretainedValue()
                .seek(offset: offset, whence: whence)
        })
    guard let ioContext else {
        av_free(ioBytes)
        throw HarnessError.failed("alternate audio: AVIO context creation failed")
    }
    output.pointee.pb = ioContext
    output.pointee.flags |= avFormatFlagCustomIO

    guard let stream = avformat_new_stream(output, nil),
          avcodec_parameters_copy(stream.pointee.codecpar, fixture.audioParameters) >= 0 else {
        throw HarnessError.failed("alternate audio: stream copy failed")
    }
    stream.pointee.codecpar.pointee.codec_tag = 0
    if stream.pointee.codecpar.pointee.frame_size == 0 {
        stream.pointee.codecpar.pointee.frame_size = 1536
    }
    stream.pointee.time_base = AVRational(num: 1, den: 48_000)

    var options: OpaquePointer?
    defer { av_dict_free(&options) }
    guard av_dict_set(&options, "movflags", VortXAlternateAudioMovencPolicy.movflags, 0) >= 0,
          av_dict_set(&options, "strict", "experimental", 0) >= 0,
          avformat_write_header(output, &options) >= 0 else {
        throw HarnessError.failed("alternate audio: delayed header failed")
    }

    func writePacket(at seconds: Double) throws {
        let packet = try makePacket(
            template: fixture.audio,
            streamIndex: stream.pointee.index,
            timeBase: stream.pointee.time_base,
            seconds: seconds,
            durationSeconds: 0.032,
            keyFlag: true)
        let result = av_interleaved_write_frame(output, packet)
        var optional: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&optional)
        guard result >= 0 else {
            throw HarnessError.failed("alternate audio: packet write failed (\(result))")
        }
    }

    try writePacket(at: 0)
    try writePacket(at: 0.032)
    try writePacket(at: 0.064)
    avio_flush(output.pointee.pb)
    let prematureCapture = Data(sink.bytes)
    guard let initEnd = initEnd(in: prematureCapture), initEnd < prematureCapture.count,
          let audioTrackID = VortXFMP4FragmentParser.audioTrackID(
              inInit: Data(prematureCapture.prefix(initEnd))) else {
        throw HarnessError.failed("alternate audio: init or track ID was not proven")
    }
    let prematureProof = VortXFMP4FragmentParser.proveMediaRange(
        Data(prematureCapture.dropFirst(initEnd)),
        trackID: audioTrackID,
        requireFirstSampleSync: false)

    try writePacket(at: 0.096)
    avio_flush(output.pointee.pb)
    let firstFrontier = sink.bytes.count
    let firstMedia = Data(Data(sink.bytes).dropFirst(initEnd))
    guard let firstProof = VortXFMP4FragmentParser.proveMediaRange(
              firstMedia, trackID: audioTrackID, requireFirstSampleSync: false),
          firstProof.mediaEnd == firstMedia.count else {
        throw HarnessError.failed("alternate audio: next-packet trigger did not prove segment 0")
    }

    try writePacket(at: 0.128)
    guard av_write_trailer(output) >= 0 else {
        throw HarnessError.failed("alternate audio: trailer failed")
    }
    avio_flush(output.pointee.pb)
    let finalMedia = Data(Data(sink.bytes).dropFirst(firstFrontier))
    guard let finalProof = VortXFMP4FragmentParser.proveMediaRange(
        finalMedia, trackID: audioTrackID, requireFirstSampleSync: false) else {
        throw HarnessError.failed("alternate audio: trailer did not prove final segment")
    }
    let trailerMetadataIsComplete: Bool = {
        guard finalProof.mediaEnd < finalMedia.count else { return true }
        let trailer = finalMedia.dropFirst(finalProof.mediaEnd)
        guard trailer.count >= 8 else { return false }
        let size = Int(trailer[trailer.startIndex]) << 24
            | Int(trailer[trailer.startIndex + 1]) << 16
            | Int(trailer[trailer.startIndex + 2]) << 8
            | Int(trailer[trailer.startIndex + 3])
        let type = String(
            bytes: trailer[(trailer.startIndex + 4)..<(trailer.startIndex + 8)],
            encoding: .ascii)
        return size == trailer.count && type == "mfra"
    }()
    return AlternateAudioResult(
        prematureSampleCount: prematureProof?.sampleCount,
        firstSegmentProof: firstProof,
        finalSegmentProof: finalProof,
        firstSegmentByteCount: firstMedia.count,
        finalSegmentCandidateByteCount: finalMedia.count,
        finalTrailerMetadataIsComplete: trailerMetadataIsComplete)
}

private final class Checks {
    private(set) var failures = 0

    func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)")
        }
    }
}

private struct RealOpenStageResult {
    let completedWithoutProducerPark: Bool
    let openBytesBeforeClose: Int
    let proofEndedAtFirstFragment: Bool
    let firstSampleWasDetachedIDR: Bool
    let closeCommitted: Bool
    let finalLength: Int?
    let successorBytes: Int
    let successorRemainedOpen: Bool
    let accountingWasExact: Bool
    let residentRAMWasReleased: Bool
}

private func appendInBoundedCalls(_ data: Data, to buffer: VortXRemuxBuffer,
                                  chunkSize: Int = 512 * 1024) {
    data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let count = min(chunkSize, raw.count - offset)
            buffer.append(base + offset, count: count)
            if buffer.status().failure != nil { return }
            offset += count
        }
    }
}

/// Feeds real shipped-movenc bytes through the production OpenStage. The first fragment exceeds the exact
/// 80 MiB pre-ready RAM threshold while remaining an 11-second legal GOP. A partial real successor is appended
/// too, so the parser claim, P+S promotion, and successor retention all execute against private production state.
private func runRealOpenStageScenario(_ result: ScenarioResult) throws -> RealOpenStageResult {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vortx-real-open-stage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let buffer = VortXRemuxBuffer()
    guard let spool = VortXHLSSessionSpool(
        parentDirectory: root,
        capacityBytes: VortXHLSSessionSpool.defaultCapacityBytes,
        chunkSize: VortXHLSSessionSpool.defaultChunkBytes,
        scavengeStaleSessions: false),
          let stage = spool.attachOpenStage(to: buffer) else {
        throw HarnessError.failed("real open-stage fixture could not create session backing")
    }
    appendInBoundedCalls(result.initData, to: buffer)
    guard stage.arm(base: result.initData.count, auxiliaryBytes: result.initData.count) else {
        throw HarnessError.failed("real open-stage fixture could not arm after init")
    }
    let successor = Data(result.nextMediaData.dropLast())
    guard !successor.isEmpty else {
        throw HarnessError.failed("real open-stage fixture did not produce a partial successor")
    }
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        appendInBoundedCalls(result.mediaData, to: buffer)
        appendInBoundedCalls(successor, to: buffer)
        done.signal()
    }
    let completed = done.wait(timeout: .now() + 30) == .success
    if !completed { buffer.fail("real open-stage fixture producer parked") }
    let beforeClose = stage.snapshot
    let activationPeak = spool.accounting.peakTransientCopyBytes
    let openBytes = result.mediaData.count + successor.count
    guard completed, let claim = stage.claim() else {
        throw HarnessError.failed("real open-stage fixture did not yield an exact claim")
    }
    var proofEnd: Int?
    var detachedIDR = false
    let parsed = claim.withBytes { bytes in
        guard let proof = VortXFMP4FragmentParser.proveFirstMediaFragment(
            bytes,
            trackID: result.videoTrackID,
            requireFirstSampleSync: true) else { return }
        let detached = Data(proof.firstSampleBytes)
        proofEnd = proof.mediaEnd
        detachedIDR = packetIsIDR(detached)
    }
    guard parsed, let proofEnd else {
        claim.release()
        throw HarnessError.failed("real open-stage mapped parser proof failed")
    }
    let key = VortXHLSSessionSpool.ResourceKey.video(segmentID: 700)
    let absoluteEnd = result.initData.count + proofEnd
    let committed = stage.closePrefix(
        claim,
        endOffset: absoluteEnd,
        key: key,
        durationMilliseconds: 11_000,
        additionalResources: [])
    let lease = spool.openResource(key, now: 0)
    let finalLength = lease?.length
    let firstBytes = try? lease?.read(maxLength: min(64, result.mediaData.count))
    lease?.close(now: 0)
    let afterClose = stage.snapshot
    let accounting = spool.accounting
    return RealOpenStageResult(
        completedWithoutProducerPark: completed,
        openBytesBeforeClose: openBytes,
        proofEndedAtFirstFragment: proofEnd == result.mediaData.count,
        firstSampleWasDetachedIDR: detachedIDR,
        closeCommitted: committed
            && firstBytes == Data(result.mediaData.prefix(min(64, result.mediaData.count))),
        finalLength: finalLength,
        successorBytes: successor.count,
        successorRemainedOpen: afterClose.storage == .active
            && afterClose.baseOffset == absoluteEnd
            && afterClose.logicalEndOffset == result.initData.count + openBytes,
        accountingWasExact: accounting.finalBytes == result.mediaData.count
            && accounting.openBytes == successor.count
            && accounting.reservedBytes == 0
            && accounting.transientCopyBytes == 0
            && activationPeak > successor.count
            && accounting.peakTransientCopyBytes == max(activationPeak, successor.count)
            && accounting.physicalBytes == accounting.admittedBytes,
        residentRAMWasReleased: beforeClose.storage == .active
            && buffer.residentByteRange.isEmpty)
}

@main
private enum HLSFragmentPublicationIntegrationTests {
    static func main() {
        let checks = Checks()
        let version = avformat_version()
        checks.check("pinned movenc: libavformat is exactly 62.12.102",
                     version == (62 << 16 | 12 << 8 | 102))

        guard let fixtureData = Data(base64Encoded: fixtureBase64, options: .ignoreUnknownCharacters) else {
            print("FAIL  fixture base64 could not be decoded")
            exit(1)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortx-hls-fragment-\(UUID().uuidString)", isDirectory: true)
        let fixtureURL = directory.appendingPathComponent("hevc-ac3.mp4")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try fixtureData.write(to: fixtureURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try Fixture.load(from: fixtureURL)
            checks.check("fixture: opening HEVC packet is a parsed IDR NAL", fixture.idr.isIDR)
            checks.check("fixture: disagreement packet is parsed non-IDR", !fixture.nonIDR.isIDR)

            let scenarios = [
                ScenarioConfig(
                    name: "audio-track-first/video-packet-first short GOP",
                    audioTrackFirst: true,
                    audioPacketFirst: false,
                    queueAudioPastBoundaryBeforeKey: true,
                    boundarySeconds: 1,
                    disagreement: false,
                    paddingBytesPerNonIDR: 0),
                ScenarioConfig(
                    name: "video-track-first/audio-packet-first long GOP",
                    audioTrackFirst: false,
                    audioPacketFirst: true,
                    queueAudioPastBoundaryBeforeKey: false,
                    boundarySeconds: 3,
                    disagreement: false,
                    paddingBytesPerNonIDR: 0),
                ScenarioConfig(
                    name: "high-bitrate byte pressure",
                    audioTrackFirst: true,
                    audioPacketFirst: true,
                    queueAudioPastBoundaryBeforeKey: false,
                    boundarySeconds: 3,
                    disagreement: false,
                    paddingBytesPerNonIDR: 256 * 1024),
                ScenarioConfig(
                    name: "IDR/key disagreement extends",
                    audioTrackFirst: true,
                    audioPacketFirst: false,
                    queueAudioPastBoundaryBeforeKey: false,
                    boundarySeconds: 3,
                    disagreement: true,
                    paddingBytesPerNonIDR: 0),
                ScenarioConfig(
                    name: "real >80MiB open GOP",
                    audioTrackFirst: true,
                    audioPacketFirst: true,
                    queueAudioPastBoundaryBeforeKey: false,
                    boundarySeconds: 11,
                    disagreement: false,
                    paddingBytesPerNonIDR: 2 * 1024 * 1024),
            ]
            var results: [ScenarioResult] = []
            for scenario in scenarios {
                let result = try runScenario(scenario, fixture: fixture)
                results.append(result)
                checks.check("\(result.name): AVIO recorded writes", !result.writeRanges.isEmpty)
                checks.check("\(result.name): complete moof+mdat ends at advertised byte",
                             result.videoProof.mediaEnd == result.mediaData.count)
                checks.check("\(result.name): first published video sample is sync",
                             result.videoProof.firstSampleIsSync == true)
                checks.check("\(result.name): first output video sample carries a parsed IDR NAL",
                             packetIsIDR(result.videoProof.firstSampleBytes))
                checks.check("\(result.name): tfhd video sample count is exact",
                             result.videoProof.sampleCount == result.expectedVideoSamples)
                checks.check("\(result.name): delayed AC3 track and samples survive",
                             result.audioProof.sampleCount == result.expectedAudioSamples)
                checks.check("\(result.name): boundary receipts are monotonic",
                             result.bytesBeforeBoundaryKey <= result.bytesAfterBoundaryKey
                                 && result.bytesAfterBoundaryKey <= result.bytesAfterBoundaryDrain)
                checks.check("\(result.name): next published range begins with boundary IDR",
                             result.nextVideoProof.firstSampleIsSync == true
                                 && result.nextVideoProof.sampleCount == 1
                                 && packetIsIDR(result.nextVideoProof.firstSampleBytes))
                let afterKeySamples = result.closingSamplesAfterKeyWrite.map(String.init) ?? "none"
                print("RECEIPT  \(result.name): bytes before-key=\(result.bytesBeforeBoundaryKey) after-key=\(result.bytesAfterBoundaryKey) after-drain=\(result.bytesAfterBoundaryDrain); closing-video-samples after-key=\(afterKeySamples) after-drain=\(result.videoProof.sampleCount); next-range-video-samples=\(result.nextVideoProof.sampleCount)")
            }

            checks.check("forced schedule: initial key write completes the closing range",
                         results.first.map {
                             $0.closingRangeCompleteAfterKeyWrite
                                 && $0.bytesAfterBoundaryKey > $0.bytesBeforeBoundaryKey
                         } == true)
            checks.check("alternate schedule: nil drain completes a key-buffered closing range",
                         results.dropFirst().contains { !$0.closingRangeCompleteAfterKeyWrite })

            let pendingInit = try runPendingInitBoundaryScenario(
                fixture: fixture,
                deferInitObservationUntilSix: false)
            checks.check("pending-init production state: init remains delayed after key three",
                         pendingInit.initWasDelayedAtThree)
            checks.check("mutant drop pending T turns red",
                         pendingInit.retainedThreeAfterItsWrite
                             && pendingInit.consumedSegmentIDs.first == 0)
            checks.check("mutant force pre-init publication turns red",
                         pendingInit.publicationOrderWasInitFirst)
            checks.check("mutant allow non-IDR four hard-fail turns red",
                         pendingInit.nonIDRFourAvoidedHardFailure
                             && pendingInit.nextLogicalSegmentStartedAtThree)
            checks.check("mutant blanket pending fail-soft suppression turns red",
                         pendingInit.invalidPendingInputStayedFailClosed)
            checks.check("mutant unconditional test-only drain turns red",
                         pendingInit.preInitInterleaveDrainCount == 0)
            checks.check("mutant accept parser-incomplete fragment turns red",
                         pendingInit.parserIncompleteCandidateStayedUnpublished)
            checks.check("pending-init production state: payload-ID surrogate stays paired with video zero",
                         pendingInit.firstConsumedAudioToken == "audio-0")
            checks.check("pending-init production state: final start and next ID remain contiguous",
                         pendingInit.finalPublishedStartSeconds == 6
                             && pendingInit.nextSegmentID == 2)
            print("RECEIPT  pending-init natural state: pre-init drains=\(pendingInit.preInitInterleaveDrainCount) post-init drains=\(pendingInit.postInitInterleaveDrainCount) consumed=\(pendingInit.consumedSegmentIDs) final-start=\(pendingInit.finalPublishedStartSeconds) next-id=\(pendingInit.nextSegmentID)")

            let injectedFIFO = try runPendingInitBoundaryScenario(
                fixture: fixture,
                deferInitObservationUntilSix: true)
            checks.check("injected delayed observation: key three and key six coexist before consumption",
                         injectedFIFO.queuedThreeAndSixBeforeConsumption)
            checks.check("injected delayed observation: FIFO consumes both boundaries in exact order",
                         injectedFIFO.consumedSegmentIDs == [0, 1])
            checks.check("injected delayed observation/parser latency: one real drain publishes two complete queued fragments separately",
                         injectedFIFO.postInitInterleaveDrainCount == 1
                             && injectedFIFO.consumedCountBeforeFirstPostInitDrain == 0
                             && injectedFIFO.pendingCountBeforeFirstPostInitDrain == 2
                             && (injectedFIFO.producedBytesAfterFirstPostInitDrain ?? 0)
                                 > (injectedFIFO.producedBytesBeforeFirstPostInitDrain ?? Int.max)
                             && injectedFIFO.consumedSegmentIDs == [0, 1]
                             && injectedFIFO.publishedByteEndpoints.count == 2
                             && injectedFIFO.publishedByteEndpoints[0]
                                 < injectedFIFO.publishedByteEndpoints[1]
                             && injectedFIFO.publishedByteEndpoints[1]
                                 <= (injectedFIFO.producedBytesAfterFirstPostInitDrain ?? 0))
            checks.check("injected delayed observation: init precedes both media publications",
                         injectedFIFO.publicationOrderWasInitFirst)
            checks.check("injected delayed observation: no pre-init nil drain occurs",
                         injectedFIFO.preInitInterleaveDrainCount == 0)
            checks.check("injected delayed observation: final start and next ID remain contiguous",
                         injectedFIFO.finalPublishedStartSeconds == 6
                             && injectedFIFO.nextSegmentID == 2)
            print("RECEIPT  injected delayed-observation/parser-latency FIFO: pre-init drains=\(injectedFIFO.preInitInterleaveDrainCount) post-init drains=\(injectedFIFO.postInitInterleaveDrainCount) before-first-drain consumed=\(String(describing: injectedFIFO.consumedCountBeforeFirstPostInitDrain)) pending=\(String(describing: injectedFIFO.pendingCountBeforeFirstPostInitDrain)) bytes=\(String(describing: injectedFIFO.producedBytesBeforeFirstPostInitDrain))->\(String(describing: injectedFIFO.producedBytesAfterFirstPostInitDrain)) consumed=\(injectedFIFO.consumedSegmentIDs) final-start=\(injectedFIFO.finalPublishedStartSeconds) next-id=\(injectedFIFO.nextSegmentID)")

            if let audioFirst = results.first {
                checks.check("audio-track-first output: actual first traf is audio",
                             audioFirst.trackOrder.first == audioFirst.audioTrackID)
                checks.check("mutant mid-fragment advertised offset turns red",
                             VortXFMP4FragmentParser.proveMediaRange(
                                 Data(audioFirst.mediaData.dropLast()),
                                 trackID: audioFirst.videoTrackID,
                                 requireFirstSampleSync: true) == nil)
                let mutantProof = firstTrafShortcutProof(audioFirst)
                checks.check("mutant first-traf shortcut executes and turns red",
                             mutantProof?.sampleCount == audioFirst.audioProof.sampleCount
                                 && mutantProof?.sampleCount != audioFirst.expectedVideoSamples)
                let firstRange = audioFirst.mediaData
                let secondRange = Data(audioFirst.nextMediaData.prefix(
                    audioFirst.nextVideoProof.mediaEnd))
                let twoCompleteRanges = firstRange + secondRange
                let firstOnlyProof = VortXFMP4FragmentParser.proveFirstMediaFragment(
                    twoCompleteRanges,
                    trackID: audioFirst.videoTrackID,
                    requireFirstSampleSync: true)
                checks.check("first-fragment proof: two complete real movenc fragments return only the first endpoint",
                             firstOnlyProof?.mediaEnd == firstRange.count
                                 && firstOnlyProof?.fragmentCount == 1
                                 && firstOnlyProof?.mediaEnd ?? 0 < twoCompleteRanges.count)
                let completePlusPartial = firstRange + Data(secondRange.dropLast())
                checks.check("first-fragment proof: a complete head ignores a partial real movenc successor",
                             VortXFMP4FragmentParser.proveFirstMediaFragment(
                                completePlusPartial,
                                trackID: audioFirst.videoTrackID,
                                requireFirstSampleSync: true)?.mediaEnd == firstRange.count)
                let twoQueued = VortXHLSPendingPublicationMachine<Void>()
                _ = twoQueued.append(segmentID: 0, startSeconds: 0, endSeconds: 3, payload: ())
                _ = twoQueued.append(segmentID: 1, startSeconds: 3, endSeconds: 6, payload: ())
                var byteFrontier = 0
                var publishedEndpoints: [Int] = []
                let twoQueuedResult = twoQueued.advance(
                    initMayPublishMedia: { true },
                    allowPostInitDrain: false,
                    proveNextFragment: {
                        let suffix = Data(twoCompleteRanges.dropFirst(byteFrontier))
                        guard let proof = VortXFMP4FragmentParser.proveFirstMediaFragment(
                            suffix,
                            trackID: audioFirst.videoTrackID,
                            requireFirstSampleSync: true) else { return nil as Int? }
                        return byteFrontier + proof.mediaEnd
                    },
                    performPostInitDrain: { false },
                    publish: { _, endpoint in
                        guard endpoint > byteFrontier else { return false }
                        byteFrontier = endpoint
                        publishedEndpoints.append(endpoint)
                        return true
                    })
                checks.check("first-fragment proof: one advance publishes two queued real fragments as distinct FIFO ranges",
                             twoQueuedResult == .settled
                                 && publishedEndpoints == [firstRange.count, twoCompleteRanges.count])
                let completeThenPartial = VortXHLSPendingPublicationMachine<Void>()
                _ = completeThenPartial.append(
                    segmentID: 0, startSeconds: 0, endSeconds: 3, payload: ())
                _ = completeThenPartial.append(
                    segmentID: 1, startSeconds: 3, endSeconds: 6, payload: ())
                var partialFrontier = 0
                var partialPublishedEndpoints: [Int] = []
                var partialDrainCount = 0
                let completeThenPartialResult = completeThenPartial.advance(
                    initMayPublishMedia: { true },
                    proveNextFragment: {
                        let suffix = Data(completePlusPartial.dropFirst(partialFrontier))
                        guard let proof = VortXFMP4FragmentParser.proveFirstMediaFragment(
                            suffix,
                            trackID: audioFirst.videoTrackID,
                            requireFirstSampleSync: true) else { return nil as Int? }
                        return partialFrontier + proof.mediaEnd
                    },
                    performPostInitDrain: {
                        partialDrainCount += 1
                        return true
                    },
                    publish: { _, endpoint in
                        guard endpoint > partialFrontier else { return false }
                        partialFrontier = endpoint
                        partialPublishedEndpoints.append(endpoint)
                        return true
                    })
                checks.check("first-fragment proof: a complete real head before one drain leaves its partial successor waiting",
                             completeThenPartialResult == .waitingForFragment
                                 && partialPublishedEndpoints == [firstRange.count]
                                 && partialDrainCount == 1
                                 && completeThenPartial.count == 1
                                 && completeThenPartial.first?.segmentID == 1)
            }
            if let pressured = results.first(where: { $0.name == "high-bitrate byte pressure" }) {
                checks.check("multi-MiB packet pressure: complete media range exceeds two MiB",
                             pressured.mediaData.count > 2 * 1024 * 1024)
            }
            if let openGOP = results.first(where: { $0.name == "real >80MiB open GOP" }) {
                checks.check("real open stage fixture: shipped movenc emits a legal <=12s fragment above 80 MiB",
                             openGOP.mediaData.count > 80 * 1024 * 1024)
                let staged = try runRealOpenStageScenario(openGOP)
                checks.check("real open stage: >80 MiB producer completes instead of parking at the RAM ceiling",
                             staged.completedWithoutProducerPark
                                 && staged.openBytesBeforeClose > 80 * 1024 * 1024
                                 && staged.residentRAMWasReleased)
                checks.check("real open stage: exact mapped claim proves only P before the partial successor",
                             staged.proofEndedAtFirstFragment
                                 && staged.firstSampleWasDetachedIDR)
                checks.check("real open stage: P commits to the private registry and retains S as the next open stage",
                             staged.closeCommitted
                                 && staged.finalLength == openGOP.mediaData.count
                                 && staged.successorBytes > 0
                                 && staged.successorRemainedOpen)
                checks.check("real open stage: activation and active close both balance their transient copies",
                             staged.accountingWasExact)
                print("RECEIPT  real open stage: P=\(openGOP.mediaData.count)B S=\(staged.successorBytes)B open-before=\(staged.openBytesBeforeClose)B target=11s")
            } else {
                checks.check("real open stage fixture: scenario result exists", false)
            }
            checks.check("mutant IDR-only acceptance turns red",
                         VortXHLSBoundaryPolicy.decision(
                             hasOpenSegment: true,
                             incomingIsIDR: true,
                             incomingHasKeyFlag: false,
                             elapsed: 1) == .continueOpen)
            checks.check("mutant key-flag-only acceptance turns red",
                         VortXHLSBoundaryPolicy.decision(
                             hasOpenSegment: true,
                             incomingIsIDR: false,
                             incomingHasKeyFlag: true,
                             elapsed: 1) == .continueOpen)
            checks.check("non-IDR remains legal at the exact frozen target",
                         VortXHLSBoundaryPolicy.decision(
                             hasOpenSegment: true,
                             incomingIsIDR: true,
                             incomingHasKeyFlag: false,
                             elapsed: 12) == .continueOpen)
            checks.check("non-IDR fails on the first positive delta beyond the frozen target",
                         VortXHLSBoundaryPolicy.decision(
                             hasOpenSegment: true,
                             incomingIsIDR: true,
                             incomingHasKeyFlag: false,
                             elapsed: 12.000_001) == .failSoft)
            checks.check("mutant timestamp-less mux/publication turns red before any AVIO write",
                         timestampLessPublicationAttemptIsRejected(fixture: fixture))
            let alternate = try runAlternateAudioScenario(fixture: fixture)
            checks.check("alternate audio mutant: AVIO flush alone omits the last logical sample",
                         alternate.prematureSampleCount == 2)
            checks.check("alternate audio: first next-segment packet completes exactly three samples",
                         alternate.firstSegmentProof.sampleCount == 3
                             && alternate.firstSegmentProof.mediaEnd == alternate.firstSegmentByteCount)
            checks.check("alternate audio: trailer completes exactly two final samples",
                         alternate.finalSegmentProof.sampleCount == 2
                             && alternate.finalSegmentProof.mediaEnd
                                 <= alternate.finalSegmentCandidateByteCount
                             && alternate.finalTrailerMetadataIsComplete)
        } catch {
            checks.check("integration harness completed: \(error)", false)
        }

        if checks.failures == 0 {
            print("\nALL PASS")
        } else {
            print("\n\(checks.failures) TEST(S) FAILED")
            exit(1)
        }
    }
}

private let fixtureBase64 = """
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
"""
