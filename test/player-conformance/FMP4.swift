import Foundation

// =============================================================================
// fMP4 media-segment inspection for contract (2): does the FIRST VIDEO sample
// carry BOTH sync metadata in ISO-BMFF and an AVC/HEVC IDR NAL unit?
//
// Neither signal is sufficient alone. movenc derives MP4 sync metadata from the
// packet key flag, while the NAL bytes say whether the access unit is actually an
// IDR. The gate fails closed when the video track, codec, sample range, flags, or
// NAL framing cannot be resolved.
// =============================================================================

enum FMP4 {

    enum VideoCodec: Equatable {
        case avc(nalLengthBytes: Int)
        case hevc(nalLengthBytes: Int)

        var name: String {
            switch self {
            case .avc: return "AVC"
            case .hevc: return "HEVC"
            }
        }

        var nalLengthBytes: Int {
            switch self {
            case .avc(let n), .hevc(let n): return n
            }
        }
    }

    struct VideoTrack: Equatable {
        let id: UInt32
        let codec: VideoCodec
    }

    struct FirstVideoSampleEvidence: Equatable {
        let mp4Sync: Bool
        let nalIDR: Bool
        var accepted: Bool { mp4Sync && nalIDR }
    }

    /// Focused oracle mutants. Production calls always use `.none`; `selftest
    /// --mutant NAME` enables one at a time and must turn RED.
    enum Mutation: String, CaseIterable {
        case wrongTrack = "wrong-track"
        case fallbackOnNilOrUnmatchedTrack = "nil-unmatched-track"
        case unknownTkhdAsVersion0 = "unknown-tkhd-version"
        case syncMetadataOnly = "sync-flag-only"
        case nalOnly = "nal-only"
        case firstTrafOnly = "audio-first-order"
        case lastTrafOnly = "video-first-order"
        case hevcIDRIgnoresLayerID = "hevc-idr-layer-zero"
        case shortTkhdPayloadAccepted = "short-tkhd-payload"
    }

    struct Box {
        let type: String
        let range: Range<Data.Index>
        let payload: Range<Data.Index>
    }

    private struct TFHD {
        let trackID: UInt32
        let baseDataOffset: UInt64?
        let sampleDescriptionIndex: UInt32?
        let defaultSampleSize: UInt32?
        let defaultSampleFlags: UInt32?
        let defaultBaseIsMoof: Bool
    }

    private struct TRUN {
        let dataOffset: Int32?
        let firstSampleSize: UInt32?
        let firstSampleFlags: UInt32?
    }

    // MARK: - Public inspection

    /// Resolve the `vide` track from a real init segment and retain the NAL length
    /// format from its avcC/hvcC sample entry. Unknown tkhd versions fail closed.
    static func videoTrack(inInit data: Data, mutation: Mutation? = nil) -> VideoTrack? {
        guard let moov = topLevelBox(named: "moov", in: data) else { return nil }
        var videos: [VideoTrack] = []
        var otherTrackIDs: [UInt32] = []
        var allTrackIDs = Set<UInt32>()

        for trak in childBoxes(in: moov.payload, of: data) where trak.type == "trak" {
            guard let mdia = childBox(named: "mdia", inContainer: trak.payload, of: data),
                  let hdlr = childBox(named: "hdlr", inContainer: mdia.payload, of: data),
                  let handler = handlerType(hdlr.payload, of: data),
                  let tkhd = childBox(named: "tkhd", inContainer: trak.payload, of: data),
                  let trackID = tkhdTrackID(tkhd.payload, of: data, mutation: mutation) else {
                return nil
            }
            guard allTrackIDs.insert(trackID).inserted else { return nil }

            if handler == "vide" {
                guard let codec = videoCodec(inMdia: mdia.payload, of: data) else { return nil }
                videos.append(VideoTrack(id: trackID, codec: codec))
            } else {
                otherTrackIDs.append(trackID)
            }
        }

        guard videos.count == 1, let resolved = videos.first else { return nil }
        if mutation == .wrongTrack, let wrong = otherTrackIDs.first {
            return VideoTrack(id: wrong, codec: resolved.codec)
        }
        return resolved
    }

    static func videoTrackID(inInit data: Data, mutation: Mutation? = nil) -> UInt32? {
        videoTrack(inInit: data, mutation: mutation)?.id
    }

    /// nil means the first video sample could not be resolved safely. false means
    /// at least one of the two required signals disagreed with an IDR boundary.
    static func firstVideoSampleIsIDR(
        _ data: Data,
        videoTrackID: UInt32?,
        codec: VideoCodec?,
        mutation: Mutation? = nil
    ) -> Bool? {
        firstVideoSampleEvidence(data, videoTrackID: videoTrackID, codec: codec, mutation: mutation)?.accepted
    }

    static func firstVideoSampleEvidence(
        _ data: Data,
        videoTrackID: UInt32?,
        codec: VideoCodec?,
        mutation: Mutation? = nil
    ) -> FirstVideoSampleEvidence? {
        guard let codec,
              let location = firstSampleLocation(data, trackID: videoTrackID, mutation: mutation),
              let flags = location.trun.firstSampleFlags ?? location.tfhd.defaultSampleFlags,
              let nalIDR = sampleContainsIDR(
                  data[location.sampleRange],
                  codec: codec,
                  mutation: mutation
              ) else {
            return nil
        }

        let mp4Sync = isSync(flags)
        switch mutation {
        case .syncMetadataOnly:
            return FirstVideoSampleEvidence(mp4Sync: mp4Sync, nalIDR: true)
        case .nalOnly:
            return FirstVideoSampleEvidence(mp4Sync: true, nalIDR: nalIDR)
        default:
            return FirstVideoSampleEvidence(mp4Sync: mp4Sync, nalIDR: nalIDR)
        }
    }

    /// sample_is_non_sync_sample is bit 16 of the sample_flags word (ISO 14496-12).
    static func isSync(_ flags: UInt32) -> Bool { (flags & 0x0001_0000) == 0 }

    // MARK: - Real-fixture support used by selftest

    /// Split an ffmpeg-produced fragmented MP4 into its real init segment and its
    /// first complete moof+mdat fragment.
    static func splitInitAndFirstFragment(_ whole: Data) -> (initSegment: Data, fragment: Data)? {
        let boxes = topLevelBoxes(in: whole)
        guard let moofIndex = boxes.firstIndex(where: { $0.type == "moof" }),
              let mdat = boxes.dropFirst(moofIndex + 1).first(where: { $0.type == "mdat" }) else {
            return nil
        }
        let moof = boxes[moofIndex]
        guard moof.range.lowerBound < mdat.range.upperBound else { return nil }
        return (
            Data(whole[whole.startIndex ..< moof.range.lowerBound]),
            Data(whole[moof.range.lowerBound ..< mdat.range.upperBound])
        )
    }

    static func trafTrackIDs(in fragment: Data) -> [UInt32] {
        guard let moof = topLevelBox(named: "moof", in: fragment) else { return [] }
        return childBoxes(in: moof.payload, of: fragment).compactMap { box in
            guard box.type == "traf",
                  let tfhd = childBox(named: "tfhd", inContainer: box.payload, of: fragment) else { return nil }
            return parseTFHD(tfhd.payload, of: fragment)?.trackID
        }
    }

    static func settingVideoTkhdVersion(in initSegment: Data, to version: UInt8) -> Data? {
        guard let moov = topLevelBox(named: "moov", in: initSegment) else { return nil }
        var out = initSegment
        for trak in childBoxes(in: moov.payload, of: initSegment) where trak.type == "trak" {
            guard let mdia = childBox(named: "mdia", inContainer: trak.payload, of: initSegment),
                  let hdlr = childBox(named: "hdlr", inContainer: mdia.payload, of: initSegment),
                  handlerType(hdlr.payload, of: initSegment) == "vide",
                  let tkhd = childBox(named: "tkhd", inContainer: trak.payload, of: initSegment),
                  !tkhd.payload.isEmpty else { continue }
            out[tkhd.payload.lowerBound] = version
            return out
        }
        return nil
    }

    static func truncatingVideoTkhdPayload(in initSegment: Data, to byteCount: Int) -> Data? {
        guard (1 ... 3).contains(byteCount),
              let moov = topLevelBox(named: "moov", in: initSegment) else { return nil }
        for trak in childBoxes(in: moov.payload, of: initSegment) where trak.type == "trak" {
            guard let mdia = childBox(named: "mdia", inContainer: trak.payload, of: initSegment),
                  let hdlr = childBox(named: "hdlr", inContainer: mdia.payload, of: initSegment),
                  handlerType(hdlr.payload, of: initSegment) == "vide",
                  let tkhd = childBox(named: "tkhd", inContainer: trak.payload, of: initSegment),
                  tkhd.payload.count > byteCount else { continue }
            let removed = tkhd.payload.count - byteCount
            var out = initSegment
            for box in [tkhd, trak, moov] {
                let oldSize = be32(initSegment, box.range.lowerBound)
                guard oldSize > UInt32(removed), oldSize - UInt32(removed) >= 8 else { return nil }
                writeBE32(oldSize - UInt32(removed), to: &out, at: box.range.lowerBound)
            }
            out.removeSubrange((tkhd.payload.lowerBound + byteCount) ..< tkhd.payload.upperBound)
            return out
        }
        return nil
    }

    static func settingFirstVideoTFHDVersion(
        in fragment: Data,
        videoTrackID: UInt32,
        to version: UInt8
    ) -> Data? {
        guard let moof = topLevelBox(named: "moof", in: fragment),
              let traf = selectTraf(in: moof, of: fragment, trackID: videoTrackID, mutation: nil),
              let tfhd = childBox(named: "tfhd", inContainer: traf.payload, of: fragment),
              !tfhd.payload.isEmpty else { return nil }
        var out = fragment
        out[tfhd.payload.lowerBound] = version
        return out
    }

    static func settingFirstVideoTFHDFlags(
        in fragment: Data,
        videoTrackID: UInt32,
        to flags: UInt32
    ) -> Data? {
        guard flags <= 0x00FF_FFFF,
              let moof = topLevelBox(named: "moof", in: fragment),
              let traf = selectTraf(in: moof, of: fragment, trackID: videoTrackID, mutation: nil),
              let tfhd = childBox(named: "tfhd", inContainer: traf.payload, of: fragment),
              tfhd.payload.lowerBound + 4 <= tfhd.payload.upperBound else { return nil }
        var out = fragment
        let version = UInt32(out[tfhd.payload.lowerBound]) << 24
        writeBE32(version | flags, to: &out, at: tfhd.payload.lowerBound)
        return out
    }

    static func settingFirstVideoTRUNVersion(
        in fragment: Data,
        videoTrackID: UInt32,
        to version: UInt8
    ) -> Data? {
        guard let moof = topLevelBox(named: "moof", in: fragment),
              let traf = selectTraf(in: moof, of: fragment, trackID: videoTrackID, mutation: nil),
              let trun = childBox(named: "trun", inContainer: traf.payload, of: fragment),
              !trun.payload.isEmpty else { return nil }
        var out = fragment
        out[trun.payload.lowerBound] = version
        return out
    }

    static func settingFirstVideoTRUNFlags(
        in fragment: Data,
        videoTrackID: UInt32,
        to flags: UInt32
    ) -> Data? {
        guard flags <= 0x00FF_FFFF,
              let moof = topLevelBox(named: "moof", in: fragment),
              let traf = selectTraf(in: moof, of: fragment, trackID: videoTrackID, mutation: nil),
              let trun = childBox(named: "trun", inContainer: traf.payload, of: fragment),
              trun.payload.lowerBound + 4 <= trun.payload.upperBound else { return nil }
        var out = fragment
        let version = UInt32(out[trun.payload.lowerBound]) << 24
        writeBE32(version | flags, to: &out, at: trun.payload.lowerBound)
        return out
    }

    static func inflatingFirstVideoTRUNSampleCountWithOneRecord(
        in fragment: Data,
        videoTrackID: UInt32
    ) -> Data? {
        guard let moof = topLevelBox(named: "moof", in: fragment),
              let traf = selectTraf(in: moof, of: fragment, trackID: videoTrackID, mutation: nil),
              let trun = childBox(named: "trun", inContainer: traf.payload, of: fragment),
              trun.payload.lowerBound + 16 == trun.payload.upperBound else { return nil }
        var out = fragment
        // The ffmpeg video fixture carries data-offset + first-sample-flags. Recast
        // that same final word as one per-sample size record, then claim UINT32_MAX
        // records. A parser that reads only record zero accepts this malformed box.
        writeBE32(0x00000201, to: &out, at: trun.payload.lowerBound)
        writeBE32(UInt32.max, to: &out, at: trun.payload.lowerBound + 4)
        return out
    }

    static func duplicatingVideoTrack(in initSegment: Data) -> Data? {
        guard let moov = topLevelBox(named: "moov", in: initSegment),
              let trak = childBoxes(in: moov.payload, of: initSegment).first(where: { box in
                  guard box.type == "trak",
                        let mdia = childBox(named: "mdia", inContainer: box.payload, of: initSegment),
                        let hdlr = childBox(named: "hdlr", inContainer: mdia.payload, of: initSegment) else {
                      return false
                  }
                  return handlerType(hdlr.payload, of: initSegment) == "vide"
              }) else { return nil }
        return insertingCopy(of: trak.range, at: moov.range.upperBound, growing: [moov], in: initSegment)
    }

    static func duplicatingMatchingTraf(in fragment: Data, videoTrackID: UInt32) -> Data? {
        guard let moof = topLevelBox(named: "moof", in: fragment),
              let traf = selectTraf(in: moof, of: fragment, trackID: videoTrackID, mutation: nil) else {
            return nil
        }
        return insertingCopy(of: traf.range, at: moof.range.upperBound, growing: [moof], in: fragment)
    }

    static func duplicatingVideoSampleDescription(in initSegment: Data) -> Data? {
        guard let moov = topLevelBox(named: "moov", in: initSegment) else { return nil }
        for trak in childBoxes(in: moov.payload, of: initSegment) where trak.type == "trak" {
            guard let mdia = childBox(named: "mdia", inContainer: trak.payload, of: initSegment),
                  let hdlr = childBox(named: "hdlr", inContainer: mdia.payload, of: initSegment),
                  handlerType(hdlr.payload, of: initSegment) == "vide",
                  let minf = childBox(named: "minf", inContainer: mdia.payload, of: initSegment),
                  let stbl = childBox(named: "stbl", inContainer: minf.payload, of: initSegment),
                  let stsd = childBox(named: "stsd", inContainer: stbl.payload, of: initSegment),
                  stsd.payload.lowerBound + 8 <= stsd.payload.upperBound,
                  be32(initSegment, stsd.payload.lowerBound + 4) == 1,
                  let entry = childBoxes(
                      in: (stsd.payload.lowerBound + 8) ..< stsd.payload.upperBound,
                      of: initSegment
                  ).first else { continue }
            guard let inserted = insertingCopy(
                of: entry.range,
                at: stsd.range.upperBound,
                growing: [stsd, stbl, minf, mdia, trak, moov],
                in: initSegment
            ) else { return nil }
            var out = inserted
            writeBE32(2, to: &out, at: stsd.payload.lowerBound + 4)
            return out
        }
        return nil
    }

    static func removingFirstVideoSampleIDR(
        from fragment: Data,
        videoTrackID: UInt32,
        codec: VideoCodec
    ) -> Data? {
        guard let location = firstSampleLocation(fragment, trackID: videoTrackID, mutation: nil) else { return nil }
        var out = fragment
        var cursor = location.sampleRange.lowerBound
        var changed = false
        while cursor < location.sampleRange.upperBound {
            guard let length = readNALLength(out, at: cursor, bytes: codec.nalLengthBytes), length > 0 else { return nil }
            let nalStart = cursor + codec.nalLengthBytes
            guard length <= location.sampleRange.upperBound - nalStart else { return nil }
            let nalEnd = nalStart + length
            switch codec {
            case .avc:
                if out[nalStart] & 0x1F == 5 {
                    out[nalStart] = (out[nalStart] & 0xE0) | 1
                    changed = true
                }
            case .hevc:
                let type = (out[nalStart] >> 1) & 0x3F
                if type == 19 || type == 20 {
                    out[nalStart] = (out[nalStart] & 0x81) | 0x02
                    changed = true
                }
            }
            cursor = nalEnd
        }
        return changed ? out : nil
    }

    static func settingFirstVideoSampleSyncMetadata(
        in fragment: Data,
        videoTrackID: UInt32,
        sync: Bool
    ) -> Data? {
        guard let moof = topLevelBox(named: "moof", in: fragment),
              let traf = selectTraf(in: moof, of: fragment, trackID: videoTrackID, mutation: nil),
              let trunBox = childBox(named: "trun", inContainer: traf.payload, of: fragment),
              let offset = firstSampleFlagsOffset(trunBox.payload, of: fragment) else { return nil }
        var out = fragment
        var flags = be32(out, offset)
        if sync { flags &= ~UInt32(0x0001_0000) } else { flags |= 0x0001_0000 }
        writeBE32(flags, to: &out, at: offset)
        return out
    }

    // MARK: - Track and sample resolution

    private static func handlerType(_ payload: Range<Data.Index>, of data: Data) -> String? {
        guard fullBoxHeader(payload, of: data, versions: [0], knownFlags: 0) != nil,
              payload.lowerBound + 12 <= payload.upperBound else { return nil }
        return String(bytes: data[(payload.lowerBound + 8) ..< (payload.lowerBound + 12)], encoding: .ascii)
    }

    private static func tkhdTrackID(
        _ payload: Range<Data.Index>,
        of data: Data,
        mutation: Mutation?
    ) -> UInt32? {
        guard payload.count >= 4 else {
            return mutation == .shortTkhdPayloadAccepted ? 1 : nil
        }
        let version = data[payload.lowerBound]
        let flags = be32(data, payload.lowerBound) & 0x00FF_FFFF
        guard flags & ~UInt32(0x00000F) == 0 else { return nil }
        let offset: Int
        switch version {
        case 0:
            offset = payload.lowerBound + 12
        case 1:
            offset = payload.lowerBound + 20
        default:
            guard mutation == .unknownTkhdAsVersion0 else { return nil }
            offset = payload.lowerBound + 12
        }
        guard offset + 4 <= payload.upperBound else { return nil }
        let id = be32(data, offset)
        return id == 0 ? nil : id
    }

    private static func videoCodec(inMdia mdia: Range<Data.Index>, of data: Data) -> VideoCodec? {
        guard let minf = childBox(named: "minf", inContainer: mdia, of: data),
              let stbl = childBox(named: "stbl", inContainer: minf.payload, of: data),
              let stsd = childBox(named: "stsd", inContainer: stbl.payload, of: data),
              let stsdHeader = fullBoxHeader(stsd.payload, of: data, versions: [0], knownFlags: 0),
              stsdHeader.cursor + 4 <= stsd.payload.upperBound else { return nil }

        let entryCount = be32(data, stsdHeader.cursor)
        let entriesRange = (stsdHeader.cursor + 4) ..< stsd.payload.upperBound
        let entries = childBoxes(in: entriesRange, of: data)
        guard entryCount == 1, entries.count == 1, let entry = entries.first,
              ["avc1", "avc3", "hvc1", "hev1"].contains(entry.type),
              entry.payload.lowerBound + 78 <= entry.payload.upperBound else { return nil }
        let children = (entry.payload.lowerBound + 78) ..< entry.payload.upperBound
        let configurationBoxes = childBoxes(in: children, of: data).filter {
            $0.type == "avcC" || $0.type == "hvcC"
        }
        guard configurationBoxes.count == 1, let configuration = configurationBoxes.first else { return nil }
        if entry.type == "avc1" || entry.type == "avc3",
           configuration.type == "avcC",
           let n = avcNALLengthBytes(configuration.payload, of: data) {
            return .avc(nalLengthBytes: n)
        }
        if configuration.type == "hvcC",
           let n = hevcNALLengthBytes(configuration.payload, of: data) {
            return .hevc(nalLengthBytes: n)
        }
        return nil
    }

    private struct SampleLocation {
        let tfhd: TFHD
        let trun: TRUN
        let sampleRange: Range<Data.Index>
    }

    private static func firstSampleLocation(
        _ data: Data,
        trackID: UInt32?,
        mutation: Mutation?
    ) -> SampleLocation? {
        guard let moof = topLevelBox(named: "moof", in: data),
              let traf = selectTraf(in: moof, of: data, trackID: trackID, mutation: mutation),
              let tfhdBox = childBox(named: "tfhd", inContainer: traf.payload, of: data),
              let tfhd = parseTFHD(tfhdBox.payload, of: data),
              tfhd.sampleDescriptionIndex == nil || tfhd.sampleDescriptionIndex == 1,
              let trunBox = childBox(named: "trun", inContainer: traf.payload, of: data),
              let trun = parseTRUN(trunBox.payload, of: data, defaultSampleSize: tfhd.defaultSampleSize),
              let dataOffset = trun.dataOffset,
              let sampleSize = trun.firstSampleSize,
              sampleSize > 0 else { return nil }

        let base: Int
        if let absolute = tfhd.baseDataOffset {
            guard absolute <= UInt64(Int.max) else { return nil }
            base = Int(absolute)
        } else {
            guard tfhd.defaultBaseIsMoof else { return nil }
            base = moof.range.lowerBound
        }

        let (start, startOverflow) = base.addingReportingOverflow(Int(dataOffset))
        let (end, endOverflow) = start.addingReportingOverflow(Int(sampleSize))
        guard !startOverflow, !endOverflow, start >= data.startIndex, end <= data.endIndex,
              let mdat = topLevelBoxes(in: data).first(where: {
                  $0.type == "mdat" && start >= $0.payload.lowerBound && end <= $0.payload.upperBound
              }) else { return nil }
        _ = mdat
        return SampleLocation(tfhd: tfhd, trun: trun, sampleRange: start ..< end)
    }

    private static func selectTraf(
        in moof: Box,
        of data: Data,
        trackID: UInt32?,
        mutation: Mutation?
    ) -> Box? {
        let trafs = childBoxes(in: moof.payload, of: data).filter { $0.type == "traf" }
        switch mutation {
        case .firstTrafOnly:
            return trafs.first
        case .lastTrafOnly:
            return trafs.last
        default:
            break
        }

        if let trackID {
            var matches: [Box] = []
            for traf in trafs {
                guard let tfhdBox = childBox(named: "tfhd", inContainer: traf.payload, of: data),
                      let tfhd = parseTFHD(tfhdBox.payload, of: data) else { return nil }
                if tfhd.trackID == trackID { matches.append(traf) }
            }
            guard matches.count == 1 else { return nil }
            return matches[0]
        }
        return mutation == .fallbackOnNilOrUnmatchedTrack ? trafs.first : nil
    }

    private static func parseTFHD(_ payload: Range<Data.Index>, of data: Data) -> TFHD? {
        let knownFlags: UInt32 = 0x000001 | 0x000002 | 0x000008 | 0x000010
            | 0x000020 | 0x010000 | 0x020000
        guard let header = fullBoxHeader(payload, of: data, versions: [0], knownFlags: knownFlags),
              header.cursor + 4 <= payload.upperBound else { return nil }
        let flags = header.flags
        guard !(flags & 0x000001 != 0 && flags & 0x020000 != 0) else { return nil }
        let trackID = be32(data, header.cursor)
        guard trackID != 0 else { return nil }
        var cursor = header.cursor + 4
        var baseDataOffset: UInt64?
        var sampleDescriptionIndex: UInt32?
        var defaultSampleSize: UInt32?
        var defaultSampleFlags: UInt32?

        if flags & 0x0000_0001 != 0 {
            guard cursor + 8 <= payload.upperBound else { return nil }
            baseDataOffset = be64(data, cursor); cursor += 8
        }
        if flags & 0x0000_0002 != 0 {
            guard cursor + 4 <= payload.upperBound else { return nil }
            sampleDescriptionIndex = be32(data, cursor)
            guard sampleDescriptionIndex != 0 else { return nil }
            cursor += 4
        }
        if flags & 0x0000_0008 != 0 {
            guard cursor + 4 <= payload.upperBound else { return nil }
            cursor += 4
        }
        if flags & 0x0000_0010 != 0 {
            guard cursor + 4 <= payload.upperBound else { return nil }
            defaultSampleSize = be32(data, cursor); cursor += 4
        }
        if flags & 0x0000_0020 != 0 {
            guard cursor + 4 <= payload.upperBound else { return nil }
            defaultSampleFlags = be32(data, cursor); cursor += 4
        }
        guard cursor == payload.upperBound else { return nil }
        return TFHD(
            trackID: trackID,
            baseDataOffset: baseDataOffset,
            sampleDescriptionIndex: sampleDescriptionIndex,
            defaultSampleSize: defaultSampleSize,
            defaultSampleFlags: defaultSampleFlags,
            defaultBaseIsMoof: flags & 0x0002_0000 != 0
        )
    }

    private static func parseTRUN(
        _ payload: Range<Data.Index>,
        of data: Data,
        defaultSampleSize: UInt32?
    ) -> TRUN? {
        let knownFlags: UInt32 = 0x000001 | 0x000004 | 0x000100 | 0x000200
            | 0x000400 | 0x000800
        guard let header = fullBoxHeader(payload, of: data, versions: [0, 1], knownFlags: knownFlags),
              header.cursor + 4 <= payload.upperBound else { return nil }
        let flags = header.flags
        guard !(flags & 0x000004 != 0 && flags & 0x000400 != 0) else { return nil }
        let rawSampleCount = be32(data, header.cursor)
        guard rawSampleCount > 0, UInt64(rawSampleCount) <= UInt64(Int.max) else { return nil }
        let sampleCount = Int(rawSampleCount)
        var cursor = header.cursor + 4
        var dataOffset: Int32?
        var firstSampleFlags: UInt32?

        if flags & 0x0000_0001 != 0 {
            guard cursor + 4 <= payload.upperBound else { return nil }
            dataOffset = Int32(bitPattern: be32(data, cursor)); cursor += 4
        }
        if flags & 0x0000_0004 != 0 {
            guard cursor + 4 <= payload.upperBound else { return nil }
            firstSampleFlags = be32(data, cursor); cursor += 4
        }
        var firstSampleSize = defaultSampleSize
        var recordWidth = 0
        for flag: UInt32 in [0x000100, 0x000200, 0x000400, 0x000800] where flags & flag != 0 {
            let (next, overflow) = recordWidth.addingReportingOverflow(4)
            guard !overflow else { return nil }
            recordWidth = next
        }
        let (recordsBytes, recordsOverflow) = recordWidth.multipliedReportingOverflow(by: sampleCount)
        guard !recordsOverflow, recordsBytes <= payload.upperBound - cursor,
              cursor + recordsBytes == payload.upperBound else { return nil }

        if flags & 0x000100 != 0 { cursor += 4 }
        if flags & 0x000200 != 0 {
            firstSampleSize = be32(data, cursor)
            cursor += 4
        }
        if flags & 0x000400 != 0 {
            firstSampleFlags = be32(data, cursor)
            cursor += 4
        }
        if flags & 0x000800 != 0 { cursor += 4 }
        _ = cursor
        return TRUN(dataOffset: dataOffset, firstSampleSize: firstSampleSize, firstSampleFlags: firstSampleFlags)
    }

    private static func firstSampleFlagsOffset(_ payload: Range<Data.Index>, of data: Data) -> Data.Index? {
        let knownFlags: UInt32 = 0x000001 | 0x000004 | 0x000100 | 0x000200
            | 0x000400 | 0x000800
        guard let header = fullBoxHeader(payload, of: data, versions: [0, 1], knownFlags: knownFlags),
              header.cursor + 4 <= payload.upperBound else { return nil }
        let flags = header.flags
        guard !(flags & 0x000004 != 0 && flags & 0x000400 != 0) else { return nil }
        var cursor = header.cursor + 4
        if flags & 0x0000_0001 != 0 { cursor += 4 }
        guard flags & 0x0000_0004 != 0, cursor + 4 <= payload.upperBound else { return nil }
        return cursor
    }

    static func sampleContainsIDR<C: Collection>(
        _ sample: C,
        codec: VideoCodec,
        mutation: Mutation? = nil
    ) -> Bool?
        where C.Element == UInt8, C.Index == Int {
        var cursor = sample.startIndex
        var sawNAL = false
        var sawIDR = false
        while cursor < sample.endIndex {
            guard let length = readNALLength(sample, at: cursor, bytes: codec.nalLengthBytes), length > 0 else { return nil }
            let nalStart = cursor + codec.nalLengthBytes
            guard length <= sample.endIndex - nalStart else { return nil }
            let nalEnd = nalStart + length
            sawNAL = true
            switch codec {
            case .avc:
                guard length >= 2 else { return nil }
                let header = sample[nalStart]
                let type = header & 0x1F
                let typeIsSpecified = (1 ... 16).contains(type) || (19 ... 21).contains(type)
                guard header & 0x80 == 0, typeIsSpecified else { return nil }
                if type == 5 {
                    guard header & 0x60 != 0 else { return nil }
                    sawIDR = true
                }
            case .hevc:
                guard length >= 3 else { return nil }
                let first = sample[nalStart]
                let second = sample[nalStart + 1]
                let type = (first >> 1) & 0x3F
                let layerID = Int(first & 0x01) << 5 | Int(second >> 3)
                // Types 48...63 are extension/unspecified space used by streams such
                // as Dolby Vision RPU (UNSPEC62), and nonzero layer ids are valid in
                // multilayer HEVC. They are structurally valid but never count as IDR.
                guard first & 0x80 == 0, second & 0x07 != 0 else { return nil }
                if (type == 19 || type == 20)
                    && (layerID == 0 || mutation == .hevcIDRIgnoresLayerID) {
                    sawIDR = true
                }
            }
            cursor = nalEnd
        }
        guard cursor == sample.endIndex else { return nil }
        return sawNAL ? sawIDR : nil
    }

    private static func avcNALLengthBytes(_ payload: Range<Data.Index>, of data: Data) -> Int? {
        guard payload.count >= 7,
              data[payload.lowerBound] == 1,
              data[payload.lowerBound + 4] & 0xFC == 0xFC,
              data[payload.lowerBound + 5] & 0xE0 == 0xE0 else { return nil }
        let lengthBytes = Int(data[payload.lowerBound + 4] & 0x03) + 1
        let sequenceCount = Int(data[payload.lowerBound + 5] & 0x1F)
        guard sequenceCount > 0 else { return nil }
        var cursor = payload.lowerBound + 6
        for _ in 0 ..< sequenceCount {
            guard cursor + 2 <= payload.upperBound else { return nil }
            let length = Int(data[cursor]) << 8 | Int(data[cursor + 1])
            cursor += 2
            guard length > 0, length <= payload.upperBound - cursor else { return nil }
            cursor += length
        }
        guard cursor < payload.upperBound else { return nil }
        let pictureCount = Int(data[cursor])
        cursor += 1
        guard pictureCount > 0 else { return nil }
        for _ in 0 ..< pictureCount {
            guard cursor + 2 <= payload.upperBound else { return nil }
            let length = Int(data[cursor]) << 8 | Int(data[cursor + 1])
            cursor += 2
            guard length > 0, length <= payload.upperBound - cursor else { return nil }
            cursor += length
        }
        if cursor < payload.upperBound {
            let profile = data[payload.lowerBound + 1]
            let extensionProfiles: Set<UInt8> = [100, 110, 122, 144]
            guard extensionProfiles.contains(profile), cursor + 4 <= payload.upperBound,
                  data[cursor] & 0xFC == 0xFC,
                  data[cursor + 1] & 0xF8 == 0xF8,
                  data[cursor + 2] & 0xF8 == 0xF8 else { return nil }
            let extensionCount = Int(data[cursor + 3])
            cursor += 4
            for _ in 0 ..< extensionCount {
                guard cursor + 2 <= payload.upperBound else { return nil }
                let length = Int(data[cursor]) << 8 | Int(data[cursor + 1])
                cursor += 2
                guard length > 0, length <= payload.upperBound - cursor else { return nil }
                cursor += length
            }
        }
        guard cursor == payload.upperBound else { return nil }
        return (1 ... 4).contains(lengthBytes) ? lengthBytes : nil
    }

    private static func hevcNALLengthBytes(_ payload: Range<Data.Index>, of data: Data) -> Int? {
        guard payload.count >= 23,
              data[payload.lowerBound] == 1,
              data[payload.lowerBound + 13] & 0xF0 == 0xF0,
              data[payload.lowerBound + 15] & 0xFC == 0xFC,
              data[payload.lowerBound + 16] & 0xFC == 0xFC,
              data[payload.lowerBound + 17] & 0xF8 == 0xF8,
              data[payload.lowerBound + 18] & 0xF8 == 0xF8 else { return nil }
        let lengthBytes = Int(data[payload.lowerBound + 21] & 0x03) + 1
        let arrayCount = Int(data[payload.lowerBound + 22])
        guard arrayCount > 0 else { return nil }
        var cursor = payload.lowerBound + 23
        for _ in 0 ..< arrayCount {
            guard cursor + 3 <= payload.upperBound else { return nil }
            let arrayHeader = data[cursor]
            guard arrayHeader & 0x40 == 0 else { return nil }
            let nalCount = Int(data[cursor + 1]) << 8 | Int(data[cursor + 2])
            cursor += 3
            guard nalCount > 0 else { return nil }
            for _ in 0 ..< nalCount {
                guard cursor + 2 <= payload.upperBound else { return nil }
                let length = Int(data[cursor]) << 8 | Int(data[cursor + 1])
                cursor += 2
                guard length > 0, length <= payload.upperBound - cursor else { return nil }
                cursor += length
            }
        }
        guard cursor == payload.upperBound else { return nil }
        return (1 ... 4).contains(lengthBytes) ? lengthBytes : nil
    }

    private static func fullBoxHeader(
        _ payload: Range<Data.Index>,
        of data: Data,
        versions: [UInt8],
        knownFlags: UInt32
    ) -> (version: UInt8, flags: UInt32, cursor: Data.Index)? {
        guard payload.lowerBound >= data.startIndex, payload.upperBound <= data.endIndex,
              payload.count >= 4 else { return nil }
        let word = be32(data, payload.lowerBound)
        let version = UInt8((word >> 24) & 0xFF)
        let flags = word & 0x00FF_FFFF
        guard versions.contains(version), flags & ~knownFlags == 0 else { return nil }
        return (version, flags, payload.lowerBound + 4)
    }

    private static func insertingCopy(
        of source: Range<Data.Index>,
        at insertion: Data.Index,
        growing boxes: [Box],
        in data: Data
    ) -> Data? {
        guard source.lowerBound >= data.startIndex, source.upperBound <= data.endIndex,
              insertion >= data.startIndex, insertion <= data.endIndex else { return nil }
        let bytes = Data(data[source])
        guard !bytes.isEmpty, UInt64(bytes.count) <= UInt64(UInt32.max) else { return nil }
        var out = data
        for box in boxes {
            guard box.range.lowerBound + 8 <= data.endIndex else { return nil }
            let oldSize = be32(data, box.range.lowerBound)
            guard oldSize > 1 else { return nil }
            let (newSize, overflow) = oldSize.addingReportingOverflow(UInt32(bytes.count))
            guard !overflow else { return nil }
            writeBE32(newSize, to: &out, at: box.range.lowerBound)
        }
        out.insert(contentsOf: bytes, at: insertion)
        return out
    }

    // MARK: - Minimal box walker

    private static func be32(_ data: Data, _ index: Data.Index) -> UInt32 {
        UInt32(data[index]) << 24
            | UInt32(data[index + 1]) << 16
            | UInt32(data[index + 2]) << 8
            | UInt32(data[index + 3])
    }

    private static func be64(_ data: Data, _ index: Data.Index) -> UInt64 {
        (0 ..< 8).reduce(UInt64(0)) { ($0 << 8) | UInt64(data[index + $1]) }
    }

    private static func writeBE32(_ value: UInt32, to data: inout Data, at index: Data.Index) {
        data[index] = UInt8((value >> 24) & 0xFF)
        data[index + 1] = UInt8((value >> 16) & 0xFF)
        data[index + 2] = UInt8((value >> 8) & 0xFF)
        data[index + 3] = UInt8(value & 0xFF)
    }

    private static func readNALLength<C: Collection>(
        _ data: C,
        at index: C.Index,
        bytes: Int
    ) -> Int? where C.Element == UInt8, C.Index == Int {
        guard (1 ... 4).contains(bytes), index >= data.startIndex, index <= data.endIndex,
              bytes <= data.endIndex - index else { return nil }
        var value = 0
        for offset in 0 ..< bytes { value = (value << 8) | Int(data[index + offset]) }
        return value
    }

    private static func nextBox(
        _ data: Data,
        _ start: Data.Index,
        _ end: Data.Index
    ) -> (Box, Data.Index)? {
        guard start >= data.startIndex, end <= data.endIndex, start <= end,
              end - start >= 8 else { return nil }
        var size = Int(be32(data, start))
        let type = String(bytes: data[(start + 4) ..< (start + 8)], encoding: .ascii) ?? "????"
        var headerLength = 8
        if size == 1 {
            guard end - start >= 16 else { return nil }
            let large = be64(data, start + 8)
            guard large <= UInt64(Int.max) else { return nil }
            size = Int(large)
            headerLength = 16
        } else if size == 0 {
            size = end - start
        }
        guard size >= headerLength, size <= end - start else { return nil }
        let boxEnd = start + size
        return (
            Box(type: type, range: start ..< boxEnd, payload: (start + headerLength) ..< boxEnd),
            boxEnd
        )
    }

    private static func topLevelBoxes(in data: Data) -> [Box] {
        var boxes: [Box] = []
        var cursor = data.startIndex
        while let (box, next) = nextBox(data, cursor, data.endIndex) {
            boxes.append(box)
            cursor = next
        }
        return cursor == data.endIndex ? boxes : []
    }

    private static func topLevelBox(named name: String, in data: Data) -> Box? {
        topLevelBoxes(in: data).first { $0.type == name }
    }

    private static func childBoxes(in container: Range<Data.Index>, of data: Data) -> [Box] {
        var boxes: [Box] = []
        var cursor = container.lowerBound
        while let (box, next) = nextBox(data, cursor, container.upperBound) {
            boxes.append(box)
            cursor = next
        }
        return cursor == container.upperBound ? boxes : []
    }

    private static func childBox(
        named name: String,
        inContainer container: Range<Data.Index>,
        of data: Data
    ) -> Box? {
        childBoxes(in: container, of: data).first { $0.type == name }
    }
}
