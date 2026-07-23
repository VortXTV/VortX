// Executable contract for the separate aligned HLS audio-rendition topology.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/multi-audio-policy-test \
//     app/Sources/Player/VortXRemuxBuffer.swift \
//     app/Sources/Player/MultiAudioPolicy.swift \
//     app/Tests/MultiAudioPolicyTests.swift && /tmp/multi-audio-policy-test
//
// The suite executes the exact production plan, master tags, request parser, media playlist and boundary
// decisions used by the stream/server. Product-target builds separately prove the AVIO and Network callers link.

import Foundation

struct RemoteConfig {
    struct Snapshot { let dvRemuxWindowMiB: Int }
    static let snapshot = Snapshot(dvRemuxWindowMiB: 64)
}

/// Standalone-compilation stub for the buffer's failure-reason funnel (same pattern as the RemoteConfig stub).
enum DiagnosticsLog {
    static func log(_ tag: String, _ message: String) { print("[\(tag)] \(message)") }
}

@MainActor private var failures = 0

@MainActor private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private typealias Track = MultiAudioPolicy.AudioTrack

@MainActor @main
enum MultiAudioPolicyTests {
    static func main() {
        testQualificationAndDistinctSinks()
        testMasterTopology()
        testAbsolutePlaylistAndRequests()
        testAlignedPublicationLifecycle()
        testBoundedAlignmentHold()
        testProductionPacketCoverage()
        testHonestFinalMediaBoundary()
        testNonblockingOptionalBuffer()
        testUnselectedRetention()
        testActiveAudioResponseRetention()
        testFailOpenStartupState()

        print("")
        if failures == 0 {
            print("ALL PASS")
            exit(0)
        }
        print("\(failures) FAILED")
        exit(1)
    }

    private static let eac3: UInt32 = 101
    private static let ac3: UInt32 = 102
    private static let primary = Track(
        index: 1, codecID: eac3, channels: 6, language: "eng", title: "English")
    private static let japanese = Track(
        index: 2, codecID: eac3, channels: 6, language: "jpn", title: "Japanese")

    private static func testQualificationAndDistinctSinks() {
        let candidate = MultiAudioPolicy.alternateCandidate(
            from: [primary, japanese], primaryIndex: primary.index)
        check("plan: metadata may select a candidate without claiming packet proof",
              candidate?.index == japanese.index)

        let plan = MultiAudioPolicy.renditionPlan(
            from: [primary, japanese],
            primaryIndex: primary.index,
            provenPacketStreamIndices: [japanese.index])

        check("plan: a proven same-codec different-language alternate qualifies", plan != nil)
        check("plan: primary remains the one in-band audio stream",
              plan?.primary.isInBand == true && plan?.primary.sourceIndex == primary.index)
        check("plan: alternate is a separate URI-bearing rendition",
              plan?.alternate.isInBand == false && plan?.alternate.sourceIndex == japanese.index)
        check("plan: the alternate can never enter the primary media sink",
              plan?.primaryMuxSourceIndices == [primary.index]
                  && plan?.alternateMuxSourceIndex == japanese.index)

        check("plan: an unproven alternate is not advertised",
              MultiAudioPolicy.renditionPlan(
                from: [primary, japanese],
                primaryIndex: primary.index,
                provenPacketStreamIndices: []) == nil)
        check("plan: a different codec does not qualify",
              MultiAudioPolicy.renditionPlan(
                from: [primary, Track(index: 2, codecID: ac3, channels: 6,
                                      language: "jpn", title: "Japanese")],
                primaryIndex: primary.index,
                provenPacketStreamIndices: [2]) == nil)
        check("plan: the same language does not qualify",
              MultiAudioPolicy.renditionPlan(
                from: [primary, Track(index: 2, codecID: eac3, channels: 8,
                                      language: "ENG", title: "Commentary")],
                primaryIndex: primary.index,
                provenPacketStreamIndices: [2]) == nil)
        check("plan: an unknown primary language cannot prove a different-language pair",
              MultiAudioPolicy.renditionPlan(
                from: [Track(index: 1, codecID: eac3, channels: 6,
                             language: "und", title: "Main"), japanese],
                primaryIndex: 1,
                provenPacketStreamIndices: [2]) == nil)
        check("plan: an unknown alternate language does not qualify",
              MultiAudioPolicy.renditionPlan(
                from: [primary, Track(index: 2, codecID: eac3, channels: 6,
                                      language: "", title: "Alternate")],
                primaryIndex: primary.index,
                provenPacketStreamIndices: [2]) == nil)
        let jocPrimary = Track(
            index: 1, codecID: eac3, channels: 6, language: "eng",
            title: "English Atmos", isJOC: true, usesDec3: true)
        let plainAlternate = Track(
            index: 2, codecID: eac3, channels: 6, language: "jpn",
            title: "Japanese", usesDec3: true)
        let jocPrimaryCandidate = MultiAudioPolicy.renditionPlan(
            from: [jocPrimary, plainAlternate],
            primaryIndex: 1,
            provenPacketStreamIndices: [2])
        check("plan: a JOC primary keeps the in-band primary while awaiting its own mux receipt",
              jocPrimaryCandidate?.primary.isInBand == true)
        check("plan: an unobserved JOC candidate cannot emit an AUDIO group",
              MultiAudioPolicy.mediaTags(jocPrimaryCandidate).isEmpty)

        let primary7 = MultiAudioPolicy.dec3Observation(in: dec3Init(jocComplexity: 7))
        let primary16 = MultiAudioPolicy.dec3Observation(in: dec3Init(jocComplexity: 16))
        let invalid17 = MultiAudioPolicy.dec3Observation(in: dec3Init(jocComplexity: 17))
        let plainDec3 = MultiAudioPolicy.dec3Observation(in: dec3Init(jocComplexity: nil))
        let capturedOfficialJOC = MultiAudioPolicy.dec3Observation(
            in: dec3Init(payload: [0x0e, 0x00, 0x20, 0x0f, 0x00, 0x01, 0x10]))
        let capturedPlainControl = MultiAudioPolicy.dec3Observation(
            in: dec3Init(payload: [0x14, 0x00, 0x20, 0x0f, 0x00]))
        check("plan: captured official Dolby JOC dec3 reports its exact complexity 16",
              capturedOfficialJOC?.jocComplexityIndex == 16)
        check("plan: captured FFmpeg plain E-AC3 dec3 is not a false Atmos positive",
              capturedPlainControl == .init(jocComplexityIndex: nil))
        check("plan: a complete movenc-shaped non-JOC dec3 is a positive non-JOC observation",
              plainDec3 == .init(jocComplexityIndex: nil))
        check("plan: LFE in the base substream is not misread as a JOC extension flag",
              movencDec3Payload(jocComplexity: nil)[3] & 0x01 == 1
                  && plainDec3?.jocComplexityIndex == nil)
        check("plan: the dependent-substream branch is parsed at its real four-byte width",
              MultiAudioPolicy.dec3Observation(
                  in: dec3Init(payload: movencDec3Payload(
                      jocComplexity: nil, dependentSubstreams: 1)))
                  == .init(jocComplexityIndex: nil))
        check("plan: a truncated independent-substream record is rejected",
              MultiAudioPolicy.dec3Observation(
                  in: dec3Init(payload: Array(
                      movencDec3Payload(jocComplexity: nil).dropLast()))) == nil)
        check("plan: a nonzero reserved JOC extension field is rejected",
              MultiAudioPolicy.dec3Observation(
                  in: dec3Init(payload: movencDec3Payload(jocComplexity: nil) + [0x81, 0x07])) == nil)
        check("plan: a cleared JOC extension flag is rejected as malformed trailing data",
              MultiAudioPolicy.dec3Observation(
                  in: dec3Init(payload: movencDec3Payload(jocComplexity: nil) + [0x00, 0x07])) == nil)
        check("plan: a zero JOC complexity index is rejected",
              MultiAudioPolicy.dec3Observation(
                  in: dec3Init(payload: movencDec3Payload(jocComplexity: 0))) == nil)
        check("plan: a JOC complexity above the normative maximum 16 is rejected",
              invalid17 == nil)
        check("plan: bytes after the exact JOC extension are rejected",
              MultiAudioPolicy.dec3Observation(
                  in: dec3Init(payload: movencDec3Payload(jocComplexity: 7) + [0x00])) == nil)
        check("plan: a valid-size dec3 decoy outside an E-AC3 sample entry cannot authorize JOC",
              MultiAudioPolicy.dec3Observation(
                  in: mp4Box("dec3", payload: [0x00, 0x00, 0x01, 0x07])) == nil)
        let finalized7 = MultiAudioPolicy.finalizeForPublication(
            jocPrimaryCandidate,
            primaryDec3: primary7,
            alternateDec3: plainDec3)
        let finalized16 = MultiAudioPolicy.finalizeForPublication(
            jocPrimaryCandidate,
            primaryDec3: primary16,
            alternateDec3: plainDec3)
        check("plan: the primary CHANNELS value comes from its muxed dec3 complexity",
              MultiAudioPolicy.mediaTags(finalized7).first?.contains(#"CHANNELS="7/JOC""#) == true)
        check("plan: dec3 complexity is carried exactly rather than replaced by a constant",
              MultiAudioPolicy.mediaTags(finalized16).first?.contains(#"CHANNELS="16/JOC""#) == true
                  && MultiAudioPolicy.mediaTags(finalized16).first?.contains("7/JOC") == false)
        check("plan: an out-of-range dec3 observation can never publish invalid CHANNELS metadata",
              MultiAudioPolicy.finalizeForPublication(
                  jocPrimaryCandidate,
                  primaryDec3: invalid17,
                  alternateDec3: plainDec3) == nil)
        check("plan: missing primary dec3 observation withholds the group but not in-band playback",
              MultiAudioPolicy.finalizeForPublication(
                  jocPrimaryCandidate,
                  primaryDec3: nil,
                  alternateDec3: plainDec3) == nil
                  && jocPrimaryCandidate?.primary.isInBand == true)

        let plainPrimary = Track(
            index: 1, codecID: eac3, channels: 6, language: "eng",
            title: "English", usesDec3: true)
        let jocAlternate = Track(
            index: 2, codecID: eac3, channels: 6, language: "jpn",
            title: "Japanese Atmos", isJOC: true, usesDec3: true)
        let jocAlternateCandidate = MultiAudioPolicy.renditionPlan(
            from: [plainPrimary, jocAlternate],
            primaryIndex: 1,
            provenPacketStreamIndices: [2])
        let alternate12 = MultiAudioPolicy.dec3Observation(in: dec3Init(jocComplexity: 12))
        let finalizedAlternate = MultiAudioPolicy.finalizeForPublication(
            jocAlternateCandidate,
            primaryDec3: plainDec3,
            alternateDec3: alternate12)
        let alternateTags = MultiAudioPolicy.mediaTags(finalizedAlternate)
        check("plan: a JOC alternate uses its separate muxer's dec3 rather than primary metadata",
              alternateTags.count == 2
                  && alternateTags[0].contains(#"CHANNELS="6""#)
                  && alternateTags[1].contains(#"CHANNELS="12/JOC""#))
        check("plan: missing alternate dec3 observation withholds the alternate AUDIO group",
              MultiAudioPolicy.finalizeForPublication(
                  jocAlternateCandidate,
                  primaryDec3: plainDec3,
                  alternateDec3: nil) == nil)

        let channelsWin = MultiAudioPolicy.renditionPlan(
            from: [
                primary,
                Track(index: 2, codecID: eac3, channels: 2, language: "fra", title: "French"),
                Track(index: 3, codecID: eac3, channels: 8, language: "deu", title: "German"),
            ],
            primaryIndex: primary.index,
            provenPacketStreamIndices: [2, 3])
        check("plan: the highest-channel proven alternate wins", channelsWin?.alternate.sourceIndex == 3)

        let inputOrderWins = MultiAudioPolicy.renditionPlan(
            from: [
                primary,
                Track(index: 3, codecID: eac3, channels: 6, language: "deu", title: "German"),
                Track(index: 2, codecID: eac3, channels: 6, language: "fra", title: "French"),
            ],
            primaryIndex: primary.index,
            provenPacketStreamIndices: [2, 3])
        check("plan: equal channels fall back to source index", inputOrderWins?.alternate.sourceIndex == 2)
    }

    private static func testMasterTopology() {
        let plan = MultiAudioPolicy.renditionPlan(
            from: [
                Track(index: 1, codecID: eac3, channels: 6, language: "eng", title: "Main"),
                Track(index: 2, codecID: eac3, channels: 6, language: "jpn", title: "Main"),
            ],
            primaryIndex: 1,
            provenPacketStreamIndices: [2])
        guard let plan else {
            check("master: topology exists", false)
            return
        }

        let tags = MultiAudioPolicy.mediaTags(plan)
        check("master: one in-band primary and one separate alternate are advertised", tags.count == 2)
        check("master: every row is AUDIO in one group",
              tags.allSatisfy {
                  $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO")
                      && $0.contains(#"GROUP-ID="audio""#)
              })
        check("master: primary is in-band and therefore has no URI",
              !tags[0].contains("URI=") && tags[0].contains("DEFAULT=YES"))
        check("master: alternate has its own playlist URI",
              tags[1].contains(#"URI="audio0.m3u8""#) && tags[1].contains("DEFAULT=NO"))
        check("master: names are unique even when source titles collide",
              plan.primary.name != plan.alternate.name)
        check("master: both audio rows carry non-empty language",
              tags.allSatisfy { $0.contains("LANGUAGE=") } && !tags.joined().contains(#"LANGUAGE="""#))
        check("master: both rows carry channel metadata",
              tags[0].contains(#"CHANNELS="6""#) && tags[1].contains(#"CHANNELS="6""#))
        check("master: every video variant receives the AUDIO attribute",
              MultiAudioPolicy.streamInfAttribute(plan: plan) == #",AUDIO="audio""#)
        check("master: no alternate means no AUDIO topology bytes",
              MultiAudioPolicy.streamInfAttribute(plan: nil).isEmpty
                  && MultiAudioPolicy.mediaTags(nil).isEmpty)
        check("master: source quotes and line breaks cannot escape an attribute",
              !MultiAudioPolicy.quoteSafe("A\"\r\nB").contains("\"")
                  && !MultiAudioPolicy.quoteSafe("A\"\r\nB").contains("\n"))
    }

    private struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var bitCount = 0

        mutating func append(_ value: Int, width: Int) {
            precondition(width > 0 && width <= 16)
            precondition(value >= 0 && value < (1 << width))
            for shift in stride(from: width - 1, through: 0, by: -1) {
                if bitCount % 8 == 0 { bytes.append(0) }
                if (value >> shift) & 1 == 1 {
                    bytes[bytes.count - 1] |= UInt8(1 << (7 - bitCount % 8))
                }
                bitCount += 1
            }
        }
    }

    /// Mirrors FFmpeg movenc's EC3SpecificBox writer: 13-bit data rate, 3-bit num_ind_sub, one independent
    /// substream record, then the optional exact 16-bit type-A JOC extension.
    private static func movencDec3Payload(jocComplexity: Int?,
                                          dependentSubstreams: Int = 0) -> [UInt8] {
        precondition((0...15).contains(dependentSubstreams))
        var writer = BitWriter()
        writer.append(768, width: 13)             // data_rate
        writer.append(0, width: 3)                // one independent substream (minus one)
        writer.append(0, width: 2)                // fscod
        writer.append(16, width: 5)               // bsid
        writer.append(0, width: 1)                // reserved
        writer.append(0, width: 1)                // asvc
        writer.append(0, width: 3)                // bsmod
        writer.append(7, width: 3)                // acmod
        writer.append(1, width: 1)                // lfeon; ends the second-last base byte with one
        writer.append(0, width: 3)                // reserved
        writer.append(dependentSubstreams, width: 4)
        if dependentSubstreams == 0 {
            writer.append(0, width: 1)            // reserved
        } else {
            writer.append(0x101, width: 9)        // chan_loc
        }
        if let jocComplexity {
            precondition((0...255).contains(jocComplexity))
            writer.append(0, width: 7)            // reserved type-A extension bits
            writer.append(1, width: 1)            // flag_ec3_extension_type_a
            writer.append(jocComplexity, width: 8)
        }
        return writer.bytes
    }

    private static func dec3Init(jocComplexity: Int?) -> Data {
        dec3Init(payload: movencDec3Payload(jocComplexity: jocComplexity))
    }

    private static func dec3Init(payload: [UInt8]) -> Data {
        let dec3 = mp4Box("dec3", payload: payload)
        let audioSampleEntry = mp4Box(
            "ec-3", payload: [UInt8](repeating: 0, count: 28) + [UInt8](dec3))
        let stsd = mp4Box(
            "stsd", payload: [UInt8](repeating: 0, count: 8) + [UInt8](audioSampleEntry))
        let stbl = mp4Box("stbl", payload: [UInt8](stsd))
        let minf = mp4Box("minf", payload: [UInt8](stbl))
        let mdia = mp4Box("mdia", payload: [UInt8](minf))
        let trak = mp4Box("trak", payload: [UInt8](mdia))
        return mp4Box("moov", payload: [UInt8](trak))
    }

    private static func mp4Box(_ type: String, payload: [UInt8]) -> Data {
        precondition(type.utf8.count == 4)
        let size = payload.count + 8
        return Data([
            UInt8((size >> 24) & 0xff), UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff), UInt8(size & 0xff),
        ] + Array(type.utf8) + payload)
    }

    private static func testAbsolutePlaylistAndRequests() {
        let videoFrameDuration = 1.0 / 24.0
        let videoSegments = (8..<11).map {
            VortXHLSSegment(id: $0, byteOffset: ($0 - 8) * 100,
                            byteLength: 100, start: Double($0 * 4), duration: 4)
        }
        let videoWindow = VortXHLSWindow(segments: videoSegments)
        let resources = (8..<11).map {
            MultiAudioPolicy.AudioResource(
                segmentID: $0, byteOffset: ($0 - 8) * 64, byteLength: 64,
                decodeStart: Double($0 * 4), decodeEnd: Double(($0 + 1) * 4))
        }
        guard let window = MultiAudioPolicy.alignedWindow(
            videoWindow: videoWindow,
            audioResources: resources,
            videoFrameDuration: videoFrameDuration) else {
            check("coverage: a complete continuous alternate window is accepted", false)
            return
        }
        check("coverage: audio resources inherit every video id and duration",
              window.segments.map(\.id) == [8, 9, 10]
                  && window.segments.map(\.duration) == [4, 4, 4])
        check("coverage: a missing segment rejects the alternate instead of declaring a silent hole",
              MultiAudioPolicy.alignedWindow(
                  videoWindow: videoWindow,
                  audioResources: Array(resources.dropLast()),
                  videoFrameDuration: videoFrameDuration) == nil)
        var discontinuous = resources
        discontinuous[1] = .init(
            segmentID: 9, byteOffset: 64, byteLength: 64, decodeStart: 99, decodeEnd: 103)
        check("coverage: a decode-time discontinuity rejects the alternate",
              MultiAudioPolicy.alignedWindow(
                  videoWindow: videoWindow,
                  audioResources: discontinuous,
                  videoFrameDuration: videoFrameDuration) == nil)
        var missingTail = resources
        missingTail[2] = .init(
            segmentID: 10, byteOffset: 128, byteLength: 64, decodeStart: 40, decodeEnd: 43.9)
        check("coverage: a real resource that ends before the video tail is rejected",
              MultiAudioPolicy.alignedWindow(
                  videoWindow: videoWindow,
                  audioResources: missingTail,
                  videoFrameDuration: videoFrameDuration) == nil)
        var firstOffset = resources
        firstOffset[0] = .init(
            segmentID: 8, byteOffset: 0, byteLength: 64, decodeStart: 32.1, decodeEnd: 36)
        check("coverage: a first DTS offset is rejected instead of relabeled as the video start",
              MultiAudioPolicy.alignedWindow(
                  videoWindow: videoWindow,
                  audioResources: firstOffset,
                  videoFrameDuration: videoFrameDuration) == nil)
        let lines = MultiAudioPolicy.mediaPlaylist(
            renditionID: 0, window: window, ended: false, targetDuration: 5)

        check("playlist: media sequence is the first absolute aligned id",
              lines.contains("#EXT-X-MEDIA-SEQUENCE:8"))
        check("playlist: an evicted id is never advertised", !lines.contains("audio0-seg0.m4s"))
        check("playlist: absolute aligned ids name every segment",
              lines.contains("audio0-seg8.m4s")
                  && lines.contains("audio0-seg9.m4s")
                  && lines.contains("audio0-seg10.m4s"))
        check("playlist: full declared duration has a real non-GAP audio resource",
              !lines.contains("#EXT-X-GAP")
                  && lines.filter { $0.hasPrefix("#EXTINF:") }.count == 3
                  && lines.filter { $0.hasSuffix(".m4s") }.count == 3)
        check("playlist: the audio init map is rendition-specific",
              lines.contains(#"#EXT-X-MAP:URI="audio0-init.mp4""#))
        check("playlist: a nonzero window never carries the session-zero start preference",
              !lines.contains(where: { $0.hasPrefix("#EXT-X-START:") }))
        check("playlist: an active sliding rendition is not falsely EVENT",
              !lines.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        check("playlist: ENDLIST is emitted only after completion",
              !lines.contains("#EXT-X-ENDLIST")
                  && MultiAudioPolicy.mediaPlaylist(
                      renditionID: 0, window: window, ended: true, targetDuration: 5)
                      .contains("#EXT-X-ENDLIST"))

        check("request: generated playlist URI round-trips",
              MultiAudioPolicy.parseRequest(path: "/audio0.m3u8") == .playlist(renditionID: 0))
        check("request: generated init URI round-trips",
              MultiAudioPolicy.parseRequest(path: "/audio0-init.mp4") == .initialization(renditionID: 0))
        check("request: an absolute segment id round-trips",
              MultiAudioPolicy.parseRequest(path: "/audio0-seg42.m4s")
                  == .segment(renditionID: 0, segmentID: 42))
        check("request: malformed or negative ids are rejected",
              MultiAudioPolicy.parseRequest(path: "/audio-1-seg2.m4s") == nil
                  && MultiAudioPolicy.parseRequest(path: "/audio0-seg-2.m4s") == nil
                  && MultiAudioPolicy.parseRequest(path: "/audio0.mp4") == nil)
    }

    private static func testAlignedPublicationLifecycle() {
        let frameDuration = 1.0 / 24.0
        let videos = (0..<4).map {
            VortXHLSSegment(
                id: $0, byteOffset: $0 * 100, byteLength: 100,
                start: Double($0 * 4), duration: 4)
        }
        let resources = (0..<4).map {
            MultiAudioPolicy.AudioResource(
                segmentID: $0, byteOffset: $0 * 8, byteLength: 8,
                decodeStart: Double($0 * 4), decodeEnd: Double(($0 + 1) * 4))
        }

        let startupVideo = VortXHLSWindow(segments: Array(videos[0...1]))
        check("publication: resource zero alone is not enough to open a two-segment startup window",
              MultiAudioPolicy.alignedWindow(
                  videoWindow: startupVideo,
                  audioResources: [resources[0]],
                  videoFrameDuration: frameDuration) == nil)
        check("publication: a finalized plan remains pending until the full startup video window aligns",
              MultiAudioPolicy.snapshotState(
                  current: .pending,
                  planFinalized: true,
                  fullWindowResident: false) == .pending)
        check("publication: the full aligned startup window opens the rendition exactly once",
              MultiAudioPolicy.snapshotState(
                  current: .pending,
                  planFinalized: true,
                  fullWindowResident: true) == .ready)

        let interleavedVideo = VortXHLSWindow(segments: Array(videos[0...2]))
        let stablePrefix = MultiAudioPolicy.alignedPrefix(
            videoWindow: interleavedVideo,
            audioResources: Array(resources[0...1]),
            videoFrameDuration: frameDuration)
        check("publication: an advertised rendition survives a late newest audio segment with its aligned prefix",
              stablePrefix?.segments.map(\.id) == [0, 1])
        check("publication: readiness stays latched while the newest video tail awaits audio",
              MultiAudioPolicy.snapshotState(
                  current: .ready,
                  planFinalized: true,
                  fullWindowResident: false) == .ready)
        let advanced = MultiAudioPolicy.alignedPrefix(
            videoWindow: interleavedVideo,
            audioResources: Array(resources[0...2]),
            videoFrameDuration: frameDuration)
        check("publication: the stable prefix advances when the late audio resource arrives",
              advanced?.segments.map(\.id) == [0, 1, 2])

        let buffer = VortXRemuxBuffer(windowFloorBytes: 1)
        let bytes = [UInt8](repeating: 0x3a, count: 32)
        bytes.withUnsafeBufferPointer { raw in
            buffer.append(raw.baseAddress!, count: raw.count)
        }
        _ = buffer.discardPrefix(before: resources[1].byteOffset)
        let evictedVideo = VortXHLSWindow(segments: Array(videos[1...3]))
        let evictedPrefix = MultiAudioPolicy.alignedPrefix(
            videoWindow: evictedVideo,
            audioResources: Array(resources[0...2]),
            videoFrameDuration: frameDuration)
        let residentPrefix = evictedPrefix.map { buffer.residentWindow(segments: $0.segments) }
        check("publication: primary eviction drops old absolute ids instead of advertising stale audio URIs",
              residentPrefix?.segments.map(\.id) == [1, 2]
                  && residentPrefix?.segments.allSatisfy {
                      $0.byteOffset >= buffer.residentByteRange.lowerBound
                  } == true)
    }

    private static func testBoundedAlignmentHold() {
        var state = MultiAudioPolicy.AlignmentState()
        check("alignment: a small ahead packet enters the bounded hold",
              state.enqueue(.init(token: 1, timestamp: 35.5, byteCount: 100,
                                  ownership: .ownedReference)))
        check("alignment: a packet exactly on the future cut is held too",
              state.enqueue(.init(token: 2, timestamp: 36, byteCount: 100,
                                  ownership: .ownedReference)))
        check("alignment: a packet beyond the future cut is held too",
              state.enqueue(.init(token: 3, timestamp: 36.5, byteCount: 100,
                                  ownership: .ownedReference)))

        let cut = MultiAudioPolicy.Boundary(id: 8, start: 32, duration: 4)
        let actions = state.advanceVideo(to: 36, closing: cut)
        check("alignment: only samples strictly before T enter T's old segment",
              actions.writeCurrentSegment == [1])
        check("alignment: the shared absolute boundary closes before T is written",
              actions.closedBoundary == cut)
        check("alignment: a sample exactly at T enters the new segment",
              actions.writeNextSegment == [2])
        check("alignment: a sample ahead of the video watermark remains held",
              state.heldTokens == [3])

        var closedFrontier = MultiAudioPolicy.AlignmentState()
        _ = closedFrontier.enqueue(.init(
            token: 29, timestamp: 36, byteCount: 100, ownership: .ownedReference))
        _ = closedFrontier.advanceVideo(to: 36, closing: cut)
        check("alignment: audio arriving after the cut with DTS below T is rejected",
              !closedFrontier.enqueue(.init(token: 30, timestamp: 35.999, byteCount: 100,
                                            ownership: .ownedReference)))
        check("alignment: audio arriving after the cut exactly at T belongs to the new segment",
              closedFrontier.enqueue(.init(token: 31, timestamp: 36, byteCount: 100,
                                           ownership: .ownedReference)))

        let asymmetricCut = MultiAudioPolicy.Boundary(id: 0, start: 0, duration: 4)
        var startIsNearer = MultiAudioPolicy.AlignmentState()
        _ = startIsNearer.enqueue(.init(
            token: 40, timestamp: 3.99, duration: 0.03, byteCount: 100,
            ownership: .ownedReference))
        let startDecision = startIsNearer.advanceVideo(to: 4, closing: asymmetricCut)
        check("alignment: a straddler nearer its start is assigned wholly to the new segment",
              startDecision.writeCurrentSegment.isEmpty
                  && startDecision.writeNextSegment == [40]
                  && startDecision.audioCut.map { abs($0 - 3.99) < 0.000_001 } == true
                  && startIsNearer.heldTokens.isEmpty)

        var endIsNearer = MultiAudioPolicy.AlignmentState()
        _ = endIsNearer.enqueue(.init(
            token: 41, timestamp: 3.98, duration: 0.03, byteCount: 100,
            ownership: .ownedReference))
        let endDecision = endIsNearer.advanceVideo(to: 4, closing: asymmetricCut)
        check("alignment: a straddler nearer its end is assigned wholly to the closing segment",
              endDecision.writeCurrentSegment == [41]
                  && endDecision.writeNextSegment.isEmpty
                  && endDecision.audioCut.map { abs($0 - 4.01) < 0.000_001 } == true
                  && endIsNearer.heldTokens.isEmpty)

        var demuxOrderedLate = MultiAudioPolicy.AlignmentState()
        _ = demuxOrderedLate.enqueue(.init(
            token: 50, timestamp: 3.96, duration: 0.03, byteCount: 100,
            ownership: .ownedReference))
        let videoArrivedFirst = demuxOrderedLate.advanceVideo(to: 4, closing: asymmetricCut)
        check("alignment: a video boundary waits when the demuxed straddling audio packet has not arrived",
              videoArrivedFirst.writeCurrentSegment == [50]
                  && videoArrivedFirst.closedBoundary == nil
                  && demuxOrderedLate.hasPendingBoundary)
        check("alignment: the normal late demux-order straddler is accepted while closure is pending",
              demuxOrderedLate.enqueue(.init(
                  token: 51, timestamp: 3.99, duration: 0.03, byteCount: 100,
                  ownership: .ownedReference)))
        let lateDecision = demuxOrderedLate.drainAvailableAudio()
        check("alignment: late demux-order settlement assigns the straddler exactly once",
              lateDecision.closedBoundary == asymmetricCut
                  && lateDecision.writeCurrentSegment.isEmpty
                  && lateDecision.writeNextSegment == [51]
                  && lateDecision.audioCut.map { abs($0 - 3.99) < 0.000_001 } == true
                  && !demuxOrderedLate.hasPendingBoundary
                  && demuxOrderedLate.heldTokens.isEmpty)

        var preBoundaryLookahead = MultiAudioPolicy.AlignmentState()
        _ = preBoundaryLookahead.advanceVideo(to: 4, closing: nil)
        _ = preBoundaryLookahead.enqueue(.init(
            token: 52, timestamp: 3.99, duration: 0.03, byteCount: 100,
            ownership: .ownedReference))
        let beforeBoundary = preBoundaryLookahead.drainAvailableAudio()
        check("alignment: the trailing audio frame remains held until the next video boundary is known",
              beforeBoundary.writeCurrentSegment.isEmpty
                  && preBoundaryLookahead.heldTokens == [52])
        let lookaheadDecision = preBoundaryLookahead.advanceVideo(
            to: 4, closing: asymmetricCut)
        check("alignment: production-order lookahead preserves a start-nearer straddler for the new segment",
              lookaheadDecision.writeCurrentSegment.isEmpty
                  && lookaheadDecision.writeNextSegment == [52]
                  && lookaheadDecision.audioCut.map { abs($0 - 3.99) < 0.000_001 } == true)

        let noCut = state.advanceVideo(to: 36.5, closing: nil)
        check("alignment: without a cut, one trailing sample remains as boundary lookahead",
              noCut.writeCurrentSegment.isEmpty
                  && noCut.closedBoundary == nil
                  && noCut.writeNextSegment.isEmpty
                  && state.heldTokens == [3])
        _ = state.enqueue(.init(
            token: 4, timestamp: 37, duration: 0.02, byteCount: 100,
            ownership: .ownedReference))
        let successorReleasesLookahead = state.advanceVideo(to: 37, closing: nil)
        check("alignment: a successor releases the prior safe lookahead exactly once",
              successorReleasesLookahead.writeCurrentSegment == [3]
                  && state.heldTokens == [4])

        var eof = MultiAudioPolicy.AlignmentState()
        _ = eof.enqueue(.init(token: 20, timestamp: 40, byteCount: 100, ownership: .ownedReference))
        _ = eof.enqueue(.init(token: 21, timestamp: 41, byteCount: 100, ownership: .ownedReference))
        check("alignment: EOF drains every remaining owned packet into the final segment",
              eof.drainAtEOF() == [20, 21] && eof.heldTokens.isEmpty && eof.heldBytes == 0)

        var bounded = MultiAudioPolicy.AlignmentState()
        check("alignment: a packet at the byte cap is accepted",
              bounded.enqueue(.init(token: 9, timestamp: 1,
                                    byteCount: MultiAudioPolicy.maxHeldAudioBytes,
                                    ownership: .ownedReference)))
        check("alignment: the packet that would exceed the cap fails before append",
              !bounded.enqueue(.init(token: 10, timestamp: 2, byteCount: 1,
                                     ownership: .ownedReference))
                  && bounded.heldTokens == [9]
                  && bounded.heldBytes == MultiAudioPolicy.maxHeldAudioBytes)
        check("alignment: an oversized first packet never enters memory",
              !MultiAudioPolicy.AlignmentState().canAccept(byteCount: MultiAudioPolicy.maxHeldAudioBytes + 1))
        var ownership = MultiAudioPolicy.AlignmentState()
        check("alignment: a borrowed AVPacket token is rejected before the caller unrefs it",
              !ownership.enqueue(.init(token: 11, timestamp: 1, byteCount: 100,
                                       ownership: .borrowed))
                  && ownership.heldTokens.isEmpty)
    }

    private static func testProductionPacketCoverage() {
        let first = MultiAudioPolicy.Boundary(id: 8, start: 32, duration: 4)
        let second = MultiAudioPolicy.Boundary(id: 9, start: 36, duration: 4)
        var continuous = MultiAudioPolicy.AudioCoverageState()
        check("coverage facts: the first accepted packet contributes its real DTS and duration",
              continuous.accept(.init(decodeStart: 32, duration: 2)))
        check("coverage facts: an exactly adjacent packet extends the real sample tail",
              continuous.accept(.init(decodeStart: 34, duration: 2)))
        let firstProof = continuous.close(boundary: first)
        check("coverage facts: a boundary closes only with proven start and tail",
              firstProof?.decodeStart == 32 && firstProof?.decodeEnd == 36)
        check("coverage facts: the next segment must begin at the prior real sample end",
              continuous.accept(.init(decodeStart: 36, duration: 4)))
        let secondProof = continuous.close(boundary: second)
        check("coverage facts: an exact segment transition remains continuous",
              secondProof?.decodeStart == 36 && secondProof?.decodeEnd == 40)

        let aacFrameDuration = 1024.0 / 48_000.0
        let videoFrameDuration = 1.0 / 24.0
        let firstVideo = MultiAudioPolicy.Boundary(id: 0, start: 0, duration: 4)
        let secondVideo = MultiAudioPolicy.Boundary(id: 1, start: 4, duration: 4)
        var aac = MultiAudioPolicy.AudioCoverageState()
        var nextAACStart = 0.0
        while nextAACStart < firstVideo.end {
            _ = aac.accept(.init(decodeStart: nextAACStart, duration: aacFrameDuration))
            nextAACStart += aacFrameDuration
        }
        let firstAACProof = aac.close(
            boundary: firstVideo,
            audioCut: nextAACStart,
            selectionFrameDuration: aacFrameDuration)
        while nextAACStart < secondVideo.end {
            _ = aac.accept(.init(decodeStart: nextAACStart, duration: aacFrameDuration))
            nextAACStart += aacFrameDuration
        }
        let secondAACProof = aac.close(
            boundary: secondVideo,
            audioCut: nextAACStart,
            selectionFrameDuration: aacFrameDuration)
        check("coverage facts: 48 kHz AAC quantization may cross a 4-second video cut",
              firstAACProof.map { $0.decodeEnd > firstVideo.end } == true)
        check("coverage facts: the next AAC resource starts at the prior tfdt/sample end",
              firstAACProof?.decodeEnd == secondAACProof?.decodeStart)

        var variableFrames = MultiAudioPolicy.AudioCoverageState()
        _ = variableFrames.accept(.init(decodeStart: 0, duration: 3.96))
        _ = variableFrames.accept(.init(decodeStart: 3.96, duration: 0.04))
        let variableCurrent = variableFrames.close(
            boundary: firstVideo,
            audioCut: 4,
            selectionFrameDuration: 0.02)
        _ = variableFrames.accept(.init(decodeStart: 4, duration: 0.02))
        _ = variableFrames.accept(.init(decodeStart: 4.02, duration: 3.98))
        let variableNext = variableFrames.close(
            boundary: secondVideo,
            audioCut: 8,
            selectionFrameDuration: 3.98)
        check("coverage facts: selection quantum does not replace the current resource's real trailing frame",
              variableCurrent?.trailingPacketDuration == 0.04)
        check("coverage facts: the next resource reports its own first frame rather than the prior quantum",
              variableNext?.leadingPacketDuration == 0.02)

        let signedBeforeResources = [
            MultiAudioPolicy.AudioResource(
                segmentID: 0, byteOffset: 0, byteLength: 64,
                decodeStart: -0.01, decodeEnd: 3.99,
                leadingPacketDuration: 0.02, trailingPacketDuration: 0.02),
            MultiAudioPolicy.AudioResource(
                segmentID: 1, byteOffset: 64, byteLength: 64,
                decodeStart: 3.99, decodeEnd: 7.99,
                leadingPacketDuration: 0.02, trailingPacketDuration: 0.02),
        ]
        let signedAfterResources = signedBeforeResources.map {
            MultiAudioPolicy.AudioResource(
                segmentID: $0.segmentID,
                byteOffset: $0.byteOffset,
                byteLength: $0.byteLength,
                decodeStart: $0.decodeStart + 0.02,
                decodeEnd: $0.decodeEnd + 0.02,
                leadingPacketDuration: 0.02,
                trailingPacketDuration: 0.02)
        }
        let signedVideoWindow = VortXHLSWindow(segments: [
            .init(id: 0, byteOffset: 0, byteLength: 100, start: 0, duration: 4),
            .init(id: 1, byteOffset: 100, byteLength: 100, start: 4, duration: 4),
        ])
        check("coverage facts: nearest boundaries may land half an audio frame before first and ongoing video cuts",
              MultiAudioPolicy.alignedWindow(
                  videoWindow: signedVideoWindow,
                  audioResources: signedBeforeResources,
                  videoFrameDuration: videoFrameDuration) != nil)
        check("coverage facts: nearest boundaries may land half an audio frame after first and ongoing video cuts",
              MultiAudioPolicy.alignedWindow(
                  videoWindow: signedVideoWindow,
                  audioResources: signedAfterResources,
                  videoFrameDuration: videoFrameDuration) != nil)
        let wholeFrameShift = signedBeforeResources.map {
            MultiAudioPolicy.AudioResource(
                segmentID: $0.segmentID,
                byteOffset: $0.byteOffset,
                byteLength: $0.byteLength,
                decodeStart: $0.decodeStart - 0.01,
                decodeEnd: $0.decodeEnd - 0.01,
                leadingPacketDuration: 0.02,
                trailingPacketDuration: 0.02)
        }
        check("coverage facts: a whole-frame negative boundary shift remains rejected",
              MultiAudioPolicy.alignedWindow(
                  videoWindow: signedVideoWindow,
                  audioResources: wholeFrameShift,
                  videoFrameDuration: videoFrameDuration) == nil)

        if let firstAACProof, let secondAACProof {
            let aacVideoWindow = VortXHLSWindow(segments: [
                .init(id: 0, byteOffset: 0, byteLength: 100, start: 0, duration: 4),
                .init(id: 1, byteOffset: 100, byteLength: 100, start: 4, duration: 4),
            ])
            let aacResources = [
                MultiAudioPolicy.AudioResource(
                    segmentID: 0, byteOffset: 0, byteLength: 64,
                    decodeStart: firstAACProof.decodeStart, decodeEnd: firstAACProof.decodeEnd,
                    leadingPacketDuration: firstAACProof.leadingPacketDuration,
                    trailingPacketDuration: firstAACProof.trailingPacketDuration),
                MultiAudioPolicy.AudioResource(
                    segmentID: 1, byteOffset: 64, byteLength: 64,
                    decodeStart: secondAACProof.decodeStart, decodeEnd: secondAACProof.decodeEnd,
                    leadingPacketDuration: secondAACProof.leadingPacketDuration,
                    trailingPacketDuration: secondAACProof.trailingPacketDuration),
            ]
            let aacWindow = MultiAudioPolicy.alignedWindow(
                videoWindow: aacVideoWindow,
                audioResources: aacResources,
                videoFrameDuration: videoFrameDuration)
            let honestDurations = aacWindow?.segments.map(\.duration) ?? []
            check("coverage facts: realistic AAC cadence remains eligible within one video frame",
                  aacWindow != nil)
            check("coverage facts: audio EXTINF durations remain honest rather than copied from video",
                  honestDurations.count == 2
                      && honestDurations[0] > 4
                      && honestDurations[1] < 4
                      && abs(honestDurations.reduce(0, +) - 8) < 0.001)

            var excessiveDrift = aacResources
            excessiveDrift[0] = .init(
                segmentID: 0, byteOffset: 0, byteLength: 64,
                decodeStart: 0, decodeEnd: 4.05)
            excessiveDrift[1] = .init(
                segmentID: 1, byteOffset: 64, byteLength: 64,
                decodeStart: 4.05, decodeEnd: 8)
            check("coverage facts: cumulative audio drift beyond one video frame is rejected",
                  MultiAudioPolicy.alignedWindow(
                      videoWindow: aacVideoWindow,
                      audioResources: excessiveDrift,
                      videoFrameDuration: videoFrameDuration) == nil)

            let shiftedOneAudioFrame = aacResources.map {
                MultiAudioPolicy.AudioResource(
                    segmentID: $0.segmentID,
                    byteOffset: $0.byteOffset,
                    byteLength: $0.byteLength,
                    decodeStart: $0.decodeStart + aacFrameDuration,
                    decodeEnd: $0.decodeEnd + aacFrameDuration,
                    leadingPacketDuration: aacFrameDuration,
                    trailingPacketDuration: aacFrameDuration)
            }
            check("coverage facts: a whole-audio-frame timeline shift is rejected",
                  MultiAudioPolicy.alignedWindow(
                      videoWindow: aacVideoWindow,
                      audioResources: shiftedOneAudioFrame,
                      videoFrameDuration: videoFrameDuration) == nil)
        } else {
            check("coverage facts: realistic AAC proofs close", false)
        }

        var missingTail = MultiAudioPolicy.AudioCoverageState()
        _ = missingTail.accept(.init(decodeStart: 32, duration: 3.9))
        check("coverage facts: a missing final sample tail cannot close a video boundary",
              missingTail.close(boundary: first) == nil)

        var firstOffset = MultiAudioPolicy.AudioCoverageState()
        _ = firstOffset.accept(.init(decodeStart: 32.1, duration: 0.02))
        _ = firstOffset.accept(.init(decodeStart: 32.12, duration: 3.88))
        check("coverage facts: caller boundary time cannot hide a real first-DTS offset",
              firstOffset.close(boundary: first) == nil)

        var gap = MultiAudioPolicy.AudioCoverageState()
        _ = gap.accept(.init(decodeStart: 32, duration: 2))
        check("coverage facts: a timestamp gap invalidates the optional lane",
              !gap.accept(.init(decodeStart: 34.1, duration: 1.9)))

        var regression = MultiAudioPolicy.AudioCoverageState()
        _ = regression.accept(.init(decodeStart: 32, duration: 2))
        check("coverage facts: a timestamp regression invalidates the optional lane",
              !regression.accept(.init(decodeStart: 33.9, duration: 2.1)))

        var wrongTransition = MultiAudioPolicy.AudioCoverageState()
        _ = wrongTransition.accept(.init(decodeStart: 32, duration: 4))
        _ = wrongTransition.close(boundary: first)
        _ = wrongTransition.accept(.init(decodeStart: 36, duration: 4.1))
        check("coverage facts: consecutive video boundaries must transition exactly",
              wrongTransition.close(
                  boundary: .init(id: 9, start: 36.1, duration: 3.9)) == nil)

        var skippedID = MultiAudioPolicy.AudioCoverageState()
        _ = skippedID.accept(.init(decodeStart: 32, duration: 4))
        _ = skippedID.close(boundary: first)
        _ = skippedID.accept(.init(decodeStart: 36, duration: 4))
        check("coverage facts: a skipped absolute segment id cannot masquerade as continuity",
              skippedID.close(boundary: .init(id: 10, start: 36, duration: 4)) == nil)
    }

    private static func testHonestFinalMediaBoundary() {
        var observed = MultiAudioPolicy.MediaEndState()
        _ = observed.observe(
            packetStart: 7.96, packetDuration: 0.04, signaledFrameDuration: 1.0 / 25.0)
        let final = observed.observe(
            packetStart: 8.0, packetDuration: 0.04, signaledFrameDuration: 1.0 / 25.0)
        check("EOF: a real short final video packet ends at DTS plus packet duration",
              final.map { abs($0.seconds - 8.04) < 0.000_001 && $0.basis == .packetDuration } == true
                  && observed.latestEnd.map { abs($0 - 8.04) < 0.000_001 } == true)
        check("EOF: the old target-duration tail is not manufactured",
              observed.latestEnd != 9.0)

        var missingDuration = MultiAudioPolicy.MediaEndState()
        _ = missingDuration.observe(
            packetStart: 7.96, packetDuration: 0.04, signaledFrameDuration: 1.0 / 25.0)
        let observedCadenceEnd = missingDuration.observe(
            packetStart: 8.0, packetDuration: nil, signaledFrameDuration: 1.0 / 24.0)
        check("EOF: a missing duration uses only the last known video cadence and marks it derived",
              observedCadenceEnd.map {
                  abs($0.seconds - 8.04) < 0.000_001 && $0.basis == .derivedFrameDuration
              } == true)

        var noKnownFrame = MultiAudioPolicy.MediaEndState()
        let missingEnd = noKnownFrame.observe(
            packetStart: 8.0, packetDuration: nil, signaledFrameDuration: 1.0)
        check("EOF: no default or target-duration tail is invented without a valid frame duration",
              missingEnd == nil && noKnownFrame.latestEnd == nil)

        var signaledFrame = MultiAudioPolicy.MediaEndState()
        let signaledEnd = signaledFrame.observe(
            packetStart: 8.0, packetDuration: nil, signaledFrameDuration: 1.0 / 24.0)
        check("EOF: classifier signaling alone cannot bootstrap an unobserved final frame",
              signaledEnd == nil && signaledFrame.latestEnd == nil)
        check("EOF: an unproved final video end must fail rather than publish a truncated ENDLIST",
              MultiAudioPolicy.finalizationDecision(observedEnd: nil) == .failUnproven)
        check("EOF: a packet-derived final video end is the only close-and-ENDLIST receipt",
              MultiAudioPolicy.finalizationDecision(observedEnd: 8.04) == .close(end: 8.04))
    }

    private static func testNonblockingOptionalBuffer() {
        let buffer = VortXRemuxBuffer(windowFloorBytes: 1)
        let first = [UInt8](repeating: 0x41, count: 4)
        let second = [UInt8](repeating: 0x42, count: 1)
        let accepted = first.withUnsafeBufferPointer { bytes in
            buffer.appendIfWithinResidentLimit(bytes.baseAddress!, count: bytes.count, limit: 4)
        }
        let rejected = second.withUnsafeBufferPointer { bytes in
            buffer.appendIfWithinResidentLimit(bytes.baseAddress!, count: bytes.count, limit: 4)
        }
        check("optional buffer: an append exactly at the resident cap succeeds", accepted)
        check("optional buffer: the first byte beyond the cap fails immediately", !rejected)
        check("optional buffer: rejection neither appends nor fails the independent buffer",
              buffer.status().produced == 4 && buffer.status().failure == nil)
        check("optional buffer: the production audio cap is finite and above the packet hold",
              MultiAudioPolicy.maxResidentAudioBytes > MultiAudioPolicy.maxHeldAudioBytes)

        var held = MultiAudioPolicy.AlignmentState()
        _ = held.enqueue(.init(token: 100, timestamp: 1, byteCount: 2,
                              ownership: .ownedReference))
        _ = held.enqueue(.init(token: 101, timestamp: 2, byteCount: 2,
                              ownership: .ownedReference))
        let released = held.drainAtEOF()
        buffer.fail("alternate audio unavailable")
        check("optional buffer: cap failure omits the alternate publication",
              MultiAudioPolicy.startupDecision(state: .failed, elapsed: 0) == .omit)
        check("optional buffer: cleanup releases every held packet token and finishes the sink",
              released == [100, 101]
                  && held.heldTokens.isEmpty
                  && buffer.status().finished
                  && buffer.status().failure != nil)

        let primary = VortXRemuxBuffer(windowFloorBytes: 1)
        let primaryBytes = [UInt8](repeating: 0x50, count: 8)
        primaryBytes.withUnsafeBufferPointer { bytes in
            primary.append(bytes.baseAddress!, count: bytes.count)
        }
        check("optional buffer: primary production continues after alternate cap failure",
              primary.status().produced == primaryBytes.count
                  && primary.status().failure == nil)
    }

    private static func testUnselectedRetention() {
        let buffer = VortXRemuxBuffer(windowFloorBytes: 1)
        var resources: [MultiAudioPolicy.AudioResource] = []
        var segments: [VortXHLSSegment] = []
        var allAccepted = true
        var peakResident = 0

        for id in 0..<200 {
            let bytes = [UInt8](repeating: UInt8(id & 0xff), count: 8)
            let accepted = bytes.withUnsafeBufferPointer { raw in
                buffer.appendIfWithinResidentLimit(raw.baseAddress!, count: raw.count, limit: 48)
            }
            allAccepted = allAccepted && accepted
            guard accepted else { break }

            resources.append(.init(
                segmentID: id, byteOffset: id * 8, byteLength: 8,
                decodeStart: Double(id * 4), decodeEnd: Double((id + 1) * 4)))
            segments.append(.init(
                id: id, byteOffset: id * 8, byteLength: 8,
                start: Double(id * 4), duration: 4))

            let currentVideo = VortXHLSWindow(segments: Array(segments.suffix(4)))
            if let floor = MultiAudioPolicy.retentionFloor(
                videoWindow: currentVideo, audioResources: resources) {
                _ = buffer.discardPrefix(before: floor)
            }
            peakResident = max(peakResident, buffer.residentByteRange.count)
        }

        check("optional retention: long unselected playback never reaches the fixed cap",
              allAccepted && resources.count == 200 && peakResident < 48)

        let currentVideo = VortXHLSWindow(segments: Array(segments.suffix(4)))
        let currentResources = Array(resources.suffix(4))
        let aligned = MultiAudioPolicy.alignedWindow(
            videoWindow: currentVideo,
            audioResources: currentResources,
            videoFrameDuration: 1.0 / 24.0)
        let resident = aligned.map { buffer.residentWindow(segments: $0.segments) }
        check("optional retention: later selection still has every advertised current-window segment",
              resident?.segments.map(\.id) == currentVideo.segments.map(\.id))
    }

    private static func testActiveAudioResponseRetention() {
        let buffer = VortXRemuxBuffer(windowFloorBytes: 1)
        let bytes = Array(UInt8(0)..<UInt8(24))
        let accepted = bytes.withUnsafeBufferPointer { raw in
            buffer.appendIfWithinResidentLimit(raw.baseAddress!, count: raw.count, limit: raw.count)
        }
        var activeLease = buffer.beginReadLease(offset: 0, length: 8)
        let first = buffer.read(offset: 0, length: 2, cancelled: { false })
        _ = buffer.discardPrefix(before: 16)
        let tail = buffer.read(offset: 2, length: 6, cancelled: { false })
        check("optional retention: advancing the window mid-response preserves every leased tail byte",
              accepted && activeLease != nil
                  && first.failure == nil && first.data == Data(bytes[0..<2])
                  && tail.failure == nil && tail.data == Data(bytes[2..<8]))

        activeLease = nil
        _ = buffer.discardPrefix(before: 16)
        check("optional retention: response completion releases the lease and makes old bytes trimmable",
              buffer.read(offset: 0, length: 1, cancelled: { false }).failure != nil)

        var cancelledLease = buffer.beginReadLease(offset: 16, length: 4)
        _ = buffer.discardPrefix(before: 24)
        check("optional retention: a cancellation lease protects its resource until cancellation",
              cancelledLease != nil
                  && buffer.read(offset: 16, length: 1, cancelled: { false }).failure == nil)
        cancelledLease = nil
        _ = buffer.discardPrefix(before: 24)
        check("optional retention: cancellation releases the lease and permits trimming",
              buffer.read(offset: 16, length: 1, cancelled: { false }).failure != nil)

        let failedBuffer = VortXRemuxBuffer(windowFloorBytes: 1)
        let failedBytes = [UInt8](repeating: 0x45, count: 8)
        failedBytes.withUnsafeBufferPointer { raw in
            failedBuffer.append(raw.baseAddress!, count: raw.count)
        }
        var failedLease = failedBuffer.beginReadLease(offset: 0, length: 4)
        _ = failedBuffer.discardPrefix(before: 8)
        check("optional retention: an error path can hold a final resource lease", failedLease != nil)
        failedLease = nil
        _ = failedBuffer.discardPrefix(before: 8)
        check("optional retention: an error releases its lease and permits the final trim",
              failedBuffer.read(offset: 0, length: 1, cancelled: { false }).failure != nil)
    }

    private static func testFailOpenStartupState() {
        check("startup: the alternate readiness wait has a hard short bound",
              MultiAudioPolicy.alternateStartupWaitSeconds > 0
                  && MultiAudioPolicy.alternateStartupWaitSeconds <= 2)
        check("startup: a ready alternate is advertised",
              MultiAudioPolicy.startupDecision(
                  state: .ready, elapsed: 0) == .advertise)
        check("startup: a failed alternate is omitted without touching primary",
              MultiAudioPolicy.startupDecision(
                  state: .failed, elapsed: 0) == .omit)
        check("startup: pending remains bounded wait inside the deadline",
              MultiAudioPolicy.startupDecision(
                  state: .pending,
                  elapsed: MultiAudioPolicy.alternateStartupWaitSeconds - 0.001) == .wait)
        check("startup: timeout omits alternate and releases primary startup",
              MultiAudioPolicy.startupDecision(
                  state: .pending,
                  elapsed: MultiAudioPolicy.alternateStartupWaitSeconds) == .omit)
    }
}
