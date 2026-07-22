import Foundation

/// Pure policy for the optional, separately muxed HLS alternate-audio rendition.
///
/// The FFmpeg-owning stream converts these value decisions into muxer operations. Keeping qualification,
/// topology, absolute resource lookup, alignment and startup failure policy here makes every safety gate
/// executable without linking the vendor frameworks.
enum MultiAudioPolicy {

    // MARK: - Track qualification and topology

    struct AudioTrack: Equatable, Sendable {
        let index: Int
        let codecID: UInt32
        let channels: Int
        let language: String
        let title: String
        let isJOC: Bool
        let usesDec3: Bool

        init(index: Int, codecID: UInt32, channels: Int, language: String, title: String = "",
             isJOC: Bool = false, usesDec3: Bool = false) {
            self.index = index
            self.codecID = codecID
            self.channels = channels
            self.language = language
            self.title = title
            self.isJOC = isJOC
            self.usesDec3 = usesDec3
        }
    }

    enum ChannelSignaling: Equatable, Sendable {
        case physical(Int)
        case pendingDec3(physical: Int, sourceExpectsJOC: Bool)
        case joc(complexityIndex: Int)

        fileprivate var attribute: String? {
            switch self {
            case .physical(let count): return String(count)
            case .joc(let complexityIndex): return "\(complexityIndex)/JOC"
            case .pendingDec3: return nil
            }
        }
    }

    struct Rendition: Equatable, Sendable {
        let id: Int
        let sourceIndex: Int
        let name: String
        let language: String
        let channelSignaling: ChannelSignaling
        let isInBand: Bool
    }

    struct RenditionPlan: Equatable, Sendable {
        let primary: Rendition
        let alternate: Rendition

        var primaryMuxSourceIndices: [Int] { [primary.sourceIndex] }
        var alternateMuxSourceIndex: Int { alternate.sourceIndex }
    }

    static func languageKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isUnknownLanguage(_ key: String) -> Bool {
        key.isEmpty || key == "und" || key == "unk" || key == "mis" || key == "zxx"
    }

    /// Selects the one metadata-qualified alternate without treating stream metadata as packet proof.
    static func alternateCandidate(from tracks: [AudioTrack], primaryIndex: Int) -> AudioTrack? {
        guard let primaryTrack = tracks.first(where: { $0.index == primaryIndex }) else { return nil }
        let primaryLanguage = languageKey(primaryTrack.language)
        guard !isUnknownLanguage(primaryLanguage) else { return nil }

        return tracks
            .filter { track in
                guard track.index != primaryIndex,
                      track.codecID == primaryTrack.codecID else { return false }
                let candidateLanguage = languageKey(track.language)
                return !isUnknownLanguage(candidateLanguage) && candidateLanguage != primaryLanguage
            }
            .min { lhs, rhs in
                if lhs.channels != rhs.channels { return lhs.channels > rhs.channels }
                return lhs.index < rhs.index
            }
    }

    /// Builds the only supported Beta 7 topology: the selected primary remains in the video fMP4 and one
    /// packet-proven, same-codec, different-language alternate receives its own audio-only fMP4 sink.
    static func renditionPlan(from tracks: [AudioTrack],
                              primaryIndex: Int,
                              provenPacketStreamIndices: Set<Int>) -> RenditionPlan? {
        guard let primaryTrack = tracks.first(where: { $0.index == primaryIndex }) else { return nil }
        let primaryLanguage = languageKey(primaryTrack.language)
        let provenTracks = tracks.filter {
            $0.index == primaryIndex || provenPacketStreamIndices.contains($0.index)
        }
        let alternateTrack = alternateCandidate(from: provenTracks, primaryIndex: primaryIndex)
        guard let alternateTrack else { return nil }

        let primaryName = renditionName(track: primaryTrack, fallback: "Primary")
        var alternateName = renditionName(track: alternateTrack, fallback: "Alternate")
        if alternateName.caseInsensitiveCompare(primaryName) == .orderedSame {
            alternateName = "\(alternateName) (\(languageKey(alternateTrack.language)))"
        }

        return RenditionPlan(
            primary: Rendition(
                id: -1,
                sourceIndex: primaryTrack.index,
                name: primaryName,
                language: primaryLanguage,
                channelSignaling: channelSignaling(for: primaryTrack),
                isInBand: true),
            alternate: Rendition(
                id: 0,
                sourceIndex: alternateTrack.index,
                name: alternateName,
                language: languageKey(alternateTrack.language),
                channelSignaling: channelSignaling(for: alternateTrack),
                isInBand: false))
    }

    private static func channelSignaling(for track: AudioTrack) -> ChannelSignaling {
        let physical = max(1, track.channels)
        return track.usesDec3
            ? .pendingDec3(physical: physical, sourceExpectsJOC: track.isJOC)
            : .physical(physical)
    }

    struct Dec3Observation: Equatable, Sendable {
        let jocComplexityIndex: Int?
    }

    private struct MP4Box {
        let type: String
        let payloadStart: Int
        let end: Int
    }

    private struct BitCursor {
        let bytes: [UInt8]
        private(set) var bitOffset = 0

        var remainingBits: Int { bytes.count * 8 - bitOffset }

        mutating func read(_ width: Int) -> Int? {
            guard width > 0, width <= 16, remainingBits >= width else { return nil }
            var value = 0
            for _ in 0..<width {
                let byte = bytes[bitOffset / 8]
                let bit = (byte >> UInt8(7 - bitOffset % 8)) & 1
                value = (value << 1) | Int(bit)
                bitOffset += 1
            }
            return value
        }
    }

    /// Reads the `dec3` box from bytes emitted by one concrete muxer. Authorization requires a bounded box at
    /// the real `moov/trak/mdia/minf/stbl/stsd/ec-3/dec3` sample-entry path; an ASCII fourcc or even a valid-size
    /// decoy elsewhere in the init is not evidence. A nil result means the box was absent or malformed; a
    /// non-nil result with no complexity proves a valid non-JOC payload. The JOC extension is the final
    /// flag/index pair written by movenc for E-AC3 per ETSI TS 103 420.
    static func dec3Observation(in muxedInit: Data) -> Dec3Observation? {
        let bytes = [UInt8](muxedInit)
        guard let top = mp4Boxes(in: bytes, range: 0..<bytes.count) else { return nil }
        var observations: [Dec3Observation] = []
        for moov in top where moov.type == "moov" {
            guard let tracks = mp4Boxes(in: bytes, range: moov.payloadStart..<moov.end) else { return nil }
            for trak in tracks where trak.type == "trak" {
                guard let mdia = onlyChild(named: "mdia", of: trak, in: bytes),
                      let minf = onlyChild(named: "minf", of: mdia, in: bytes),
                      let stbl = onlyChild(named: "stbl", of: minf, in: bytes),
                      let stsd = onlyChild(named: "stsd", of: stbl, in: bytes),
                      stsd.payloadStart <= stsd.end - 8,
                      let entries = mp4Boxes(
                          in: bytes, range: (stsd.payloadStart + 8)..<stsd.end) else { continue }
                for entry in entries where entry.type == "ec-3" {
                    guard entry.payloadStart <= entry.end - 28,
                          entry.payloadStart <= bytes.count - 10 else { return nil }
                    let version = (Int(bytes[entry.payloadStart + 8]) << 8)
                        | Int(bytes[entry.payloadStart + 9])
                    let extensionLength: Int
                    switch version {
                    case 0: extensionLength = 0
                    case 1: extensionLength = 16
                    case 2: extensionLength = 36
                    default: return nil
                    }
                    let childrenStart = entry.payloadStart + 28 + extensionLength
                    guard childrenStart <= entry.end,
                          let children = mp4Boxes(
                              in: bytes, range: childrenStart..<entry.end) else { return nil }
                    for dec3 in children where dec3.type == "dec3" {
                        let payloadLength = dec3.end - dec3.payloadStart
                        guard payloadLength >= 5, payloadLength <= 64,
                              let observation = parseEC3SpecificBox(
                                  Array(bytes[dec3.payloadStart..<dec3.end])) else { return nil }
                        observations.append(observation)
                    }
                }
            }
        }
        return observations.count == 1 ? observations[0] : nil
    }

    /// Parses the exact EC3SpecificBox bit grammar emitted by FFmpeg movenc. The optional Dolby JOC type-A
    /// extension is meaningful only after every independent-substream record has been consumed. Treating the
    /// final base bytes as a flag/index pair confuses ordinary fields such as `lfeon` with JOC evidence.
    private static func parseEC3SpecificBox(_ payload: [UInt8]) -> Dec3Observation? {
        var cursor = BitCursor(bytes: payload)
        guard cursor.read(13) != nil,
              let numIndependentSubstreamsMinusOne = cursor.read(3) else { return nil }

        for _ in 0...numIndependentSubstreamsMinusOne {
            guard cursor.read(2) != nil,                       // fscod
                  cursor.read(5) != nil,                       // bsid
                  cursor.read(1) == 0,                         // reserved
                  cursor.read(1) != nil,                       // asvc
                  cursor.read(3) != nil,                       // bsmod
                  cursor.read(3) != nil,                       // acmod
                  cursor.read(1) != nil,                       // lfeon
                  cursor.read(3) == 0,                         // reserved
                  let dependentSubstreams = cursor.read(4) else { return nil }
            if dependentSubstreams == 0 {
                guard cursor.read(1) == 0 else { return nil }   // reserved
            } else {
                guard cursor.read(9) != nil else { return nil } // chan_loc
            }
        }

        guard cursor.bitOffset % 8 == 0 else { return nil }
        if cursor.remainingBits == 0 {
            return Dec3Observation(jocComplexityIndex: nil)
        }
        guard cursor.remainingBits == 16,
              cursor.read(7) == 0,                             // reserved extension bits
              cursor.read(1) == 1,                             // flag_ec3_extension_type_a
              let complexity = cursor.read(8),
              (1...16).contains(complexity),                   // ETSI TS 103 420 type-A maximum
              cursor.remainingBits == 0 else { return nil }
        return Dec3Observation(jocComplexityIndex: complexity)
    }

    private static func onlyChild(named name: String,
                                  of parent: MP4Box,
                                  in bytes: [UInt8]) -> MP4Box? {
        guard let children = mp4Boxes(
            in: bytes, range: parent.payloadStart..<parent.end) else { return nil }
        let matches = children.filter { $0.type == name }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func mp4Boxes(in bytes: [UInt8], range: Range<Int>) -> [MP4Box]? {
        guard range.lowerBound >= 0,
              range.lowerBound <= range.upperBound,
              range.upperBound <= bytes.count else { return nil }
        var boxes: [MP4Box] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard cursor <= range.upperBound - 8 else { return nil }
            let compactSize = (UInt64(bytes[cursor]) << 24) | (UInt64(bytes[cursor + 1]) << 16)
                | (UInt64(bytes[cursor + 2]) << 8) | UInt64(bytes[cursor + 3])
            var headerLength = 8
            let size: UInt64
            if compactSize == 1 {
                guard cursor <= range.upperBound - 16 else { return nil }
                headerLength = 16
                size = bytes[(cursor + 8)..<(cursor + 16)].reduce(UInt64(0)) {
                    ($0 << 8) | UInt64($1)
                }
            } else if compactSize == 0 {
                size = UInt64(range.upperBound - cursor)
            } else {
                size = compactSize
            }
            guard size >= UInt64(headerLength),
                  size <= UInt64(range.upperBound - cursor) else { return nil }
            let boxEnd = cursor + Int(size)
            guard let type = String(
                bytes: bytes[(cursor + 4)..<(cursor + 8)], encoding: .ascii) else { return nil }
            boxes.append(MP4Box(type: type, payloadStart: cursor + headerLength, end: boxEnd))
            cursor = boxEnd
        }
        return boxes
    }

    /// Converts a packet-proven candidate into the only plan that may reach a master playlist. Every E-AC3 row
    /// is resolved from that row's own muxed init: the primary observation comes from the main A/V muxer and
    /// the alternate observation comes from the independent audio muxer. Missing or contradictory JOC proof
    /// withholds the optional group while the primary remains playable in-band.
    static func finalizeForPublication(_ candidate: RenditionPlan?,
                                       primaryDec3: Dec3Observation?,
                                       alternateDec3: Dec3Observation?) -> RenditionPlan? {
        guard let candidate,
              let primary = finalized(candidate.primary, observation: primaryDec3),
              let alternate = finalized(candidate.alternate, observation: alternateDec3) else { return nil }
        return RenditionPlan(primary: primary, alternate: alternate)
    }

    private static func finalized(_ rendition: Rendition,
                                  observation: Dec3Observation?) -> Rendition? {
        let resolved: ChannelSignaling
        switch rendition.channelSignaling {
        case .physical, .joc:
            resolved = rendition.channelSignaling
        case .pendingDec3(let physical, let sourceExpectsJOC):
            guard let observation else { return nil }
            if let complexity = observation.jocComplexityIndex {
                resolved = .joc(complexityIndex: complexity)
            } else {
                guard !sourceExpectsJOC else { return nil }
                resolved = .physical(physical)
            }
        }
        return Rendition(
            id: rendition.id,
            sourceIndex: rendition.sourceIndex,
            name: rendition.name,
            language: rendition.language,
            channelSignaling: resolved,
            isInBand: rendition.isInBand)
    }

    private static func renditionName(track: AudioTrack, fallback: String) -> String {
        let trimmed = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return quoteSafe(trimmed.isEmpty ? fallback : trimmed)
    }

    static func quoteSafe(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func mediaTags(_ plan: RenditionPlan?) -> [String] {
        guard let plan,
              let primaryChannels = plan.primary.channelSignaling.attribute,
              let alternateChannels = plan.alternate.channelSignaling.attribute else { return [] }
        let primary = plan.primary
        let alternate = plan.alternate
        return [
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(quoteSafe(primary.name))\",LANGUAGE=\"\(quoteSafe(primary.language))\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"\(primaryChannels)\"",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(quoteSafe(alternate.name))\",LANGUAGE=\"\(quoteSafe(alternate.language))\",DEFAULT=NO,AUTOSELECT=YES,CHANNELS=\"\(alternateChannels)\",URI=\"audio\(alternate.id).m3u8\"",
        ]
    }

    static func streamInfAttribute(plan: RenditionPlan?) -> String {
        mediaTags(plan).isEmpty ? "" : ",AUDIO=\"audio\""
    }

    // MARK: - Absolute resources and playlists

    struct AudioResource: Equatable, Sendable {
        let segmentID: Int
        let byteOffset: Int
        let byteLength: Int
        let decodeStart: Double
        let decodeEnd: Double
        let leadingPacketDuration: Double
        let trailingPacketDuration: Double

        init(segmentID: Int, byteOffset: Int, byteLength: Int,
             decodeStart: Double, decodeEnd: Double,
             leadingPacketDuration: Double = 0,
             trailingPacketDuration: Double = 0) {
            self.segmentID = segmentID
            self.byteOffset = byteOffset
            self.byteLength = byteLength
            self.decodeStart = decodeStart
            self.decodeEnd = decodeEnd
            self.leadingPacketDuration = leadingPacketDuration
            self.trailingPacketDuration = trailingPacketDuration
        }
    }

    /// Audio coverage is all-or-nothing. Every advertised video segment must have a real, continuous alternate
    /// resource; otherwise the caller omits the alternate instead of manufacturing a silent `EXT-X-GAP`.
    static func alignedWindow(videoWindow: VortXHLSWindow,
                              audioResources: [AudioResource],
                              videoFrameDuration: Double) -> VortXHLSWindow? {
        guard !videoWindow.segments.isEmpty,
              videoFrameDuration.isFinite,
              videoFrameDuration > 0,
              audioResources.count == videoWindow.segments.count else { return nil }
        let grouped = Dictionary(grouping: audioResources, by: \AudioResource.segmentID)
        guard grouped.count == audioResources.count else { return nil }

        var aligned: [VortXHLSSegment] = []
        var previousDecodeEnd: Double?
        aligned.reserveCapacity(videoWindow.segments.count)
        for video in videoWindow.segments {
            let videoEnd = video.start + video.duration
            let leadingDrift: Double
            let trailingDrift: Double
            guard let resource = grouped[video.id]?.first,
                  resource.byteOffset >= 0,
                  resource.byteLength > 0,
                  resource.decodeStart.isFinite,
                  resource.decodeEnd.isFinite,
                  video.start.isFinite,
                  video.duration.isFinite,
                  video.duration > 0,
                  videoEnd.isFinite,
                  resource.decodeEnd > resource.decodeStart,
                  resource.leadingPacketDuration.isFinite,
                  resource.leadingPacketDuration >= 0,
                  resource.trailingPacketDuration.isFinite,
                  resource.trailingPacketDuration >= 0 else { return nil }
            leadingDrift = resource.decodeStart - video.start
            trailingDrift = resource.decodeEnd - videoEnd
            guard boundaryDriftIsValid(
                      leadingDrift,
                      packetDuration: resource.leadingPacketDuration,
                      videoFrameDuration: videoFrameDuration),
                  boundaryDriftIsValid(
                      trailingDrift,
                      packetDuration: resource.trailingPacketDuration,
                      videoFrameDuration: videoFrameDuration) else { return nil }
            if let previousDecodeEnd,
               abs(resource.decodeStart - previousDecodeEnd) > alignmentTolerance {
                return nil
            }
            aligned.append(VortXHLSSegment(
                id: video.id,
                byteOffset: resource.byteOffset,
                byteLength: resource.byteLength,
                start: resource.decodeStart,
                duration: resource.decodeEnd - resource.decodeStart))
            previousDecodeEnd = resource.decodeEnd
        }
        return VortXHLSWindow(segments: aligned)
    }

    /// Returns the longest contiguous alternate-audio prefix starting at the first currently resident video id.
    /// A missing newest audio resource is an ordinary demux interleave gap after the rendition is advertised;
    /// it must not make the already-valid prefix disappear. Duplicate or malformed coverage remains a hard
    /// rejection, and resources older than the primary resident floor can never re-enter the playlist.
    static func alignedPrefix(videoWindow: VortXHLSWindow,
                              audioResources: [AudioResource],
                              videoFrameDuration: Double) -> VortXHLSWindow? {
        guard !videoWindow.segments.isEmpty else { return nil }
        let grouped = Dictionary(grouping: audioResources, by: \AudioResource.segmentID)
        var videoPrefix: [VortXHLSSegment] = []
        var resourcePrefix: [AudioResource] = []
        for video in videoWindow.segments {
            guard let matches = grouped[video.id] else { break }
            guard matches.count == 1 else { return nil }
            videoPrefix.append(video)
            resourcePrefix.append(matches[0])
        }
        guard !videoPrefix.isEmpty else { return nil }
        return alignedWindow(
            videoWindow: VortXHLSWindow(segments: videoPrefix),
            audioResources: resourcePrefix,
            videoFrameDuration: videoFrameDuration)
    }

    private static let alignmentTolerance = 0.001

    private static func boundaryDriftIsValid(_ drift: Double,
                                             packetDuration: Double,
                                             videoFrameDuration: Double) -> Bool {
        if abs(drift) <= alignmentTolerance { return true }
        guard packetDuration > 0 else { return false }
        return abs(drift) <= packetDuration / 2 + alignmentTolerance
            && abs(drift) < videoFrameDuration
    }

    /// The optional audio byte prefix may follow the first absolute segment still resident in the primary
    /// video window. The init segment is held separately as immutable Data, so bytes before this floor are not
    /// needed even when the alternate has never been selected or read.
    static func retentionFloor(videoWindow: VortXHLSWindow,
                               audioResources: [AudioResource]) -> Int? {
        guard let firstVideo = videoWindow.segments.first else { return nil }
        let matches = audioResources.filter { $0.segmentID == firstVideo.id }
        guard matches.count == 1,
              matches[0].byteOffset >= 0,
              matches[0].byteLength > 0 else { return nil }
        return matches[0].byteOffset
    }

    static func mediaPlaylist(renditionID: Int,
                              window: VortXHLSWindow,
                              ended: Bool,
                              targetDuration: Int) -> [String] {
        guard renditionID >= 0, !window.segments.isEmpty else { return [] }
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(1, targetDuration))",
            "#EXT-X-MEDIA-SEQUENCE:\(window.mediaSequence)",
            "#EXT-X-MAP:URI=\"audio\(renditionID)-init.mp4\"",
        ]
        if window.mediaSequence == 0 {
            lines.append("#EXT-X-START:TIME-OFFSET=0.0,PRECISE=YES")
        }
        for segment in window.segments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("audio\(renditionID)-seg\(segment.id).m4s")
        }
        if ended { lines.append("#EXT-X-ENDLIST") }
        return lines
    }

    enum Request: Equatable, Sendable {
        case playlist(renditionID: Int)
        case initialization(renditionID: Int)
        case segment(renditionID: Int, segmentID: Int)
    }

    static func parseRequest(path: String) -> Request? {
        let component = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        guard component.hasPrefix("/audio") else { return nil }
        let name = String(component.dropFirst("/audio".count))

        if name.hasSuffix(".m3u8") {
            return nonnegativeInt(String(name.dropLast(".m3u8".count))).map { .playlist(renditionID: $0) }
        }
        if name.hasSuffix("-init.mp4") {
            return nonnegativeInt(String(name.dropLast("-init.mp4".count))).map {
                .initialization(renditionID: $0)
            }
        }
        guard name.hasSuffix(".m4s") else { return nil }
        let body = String(name.dropLast(".m4s".count))
        let pieces = body.components(separatedBy: "-seg")
        guard pieces.count == 2,
              let renditionID = nonnegativeInt(pieces[0]),
              let segmentID = nonnegativeInt(pieces[1]) else { return nil }
        return .segment(renditionID: renditionID, segmentID: segmentID)
    }

    private static func nonnegativeInt(_ source: String) -> Int? {
        guard !source.isEmpty,
              source.allSatisfy(\.isNumber),
              let value = Int(source),
              value >= 0 else { return nil }
        return value
    }

    // MARK: - Owned packet hold and shared boundaries

    static let maxHeldAudioPackets = 600
    static let maxHeldAudioBytes = 8 << 20
    /// A dormant, unselected alternate must not accumulate forever or backpressure primary A/V. Eighty MiB
    /// retains the buffer's 64 MiB reread floor plus startup headroom, then fails only the optional sink.
    static let maxResidentAudioBytes = 80 << 20

    enum PacketOwnership: Equatable, Sendable {
        case ownedReference
        case borrowed
    }

    struct PacketStamp: Equatable, Sendable {
        let token: Int
        let timestamp: Double
        let duration: Double
        let byteCount: Int
        let ownership: PacketOwnership

        init(token: Int, timestamp: Double, duration: Double = 0,
             byteCount: Int, ownership: PacketOwnership) {
            self.token = token
            self.timestamp = timestamp
            self.duration = duration
            self.byteCount = byteCount
            self.ownership = ownership
        }

        var decodeEnd: Double { timestamp + duration }
    }

    struct Boundary: Equatable, Sendable {
        let id: Int
        let start: Double
        let duration: Double

        var end: Double { start + duration }
    }

    struct DrainActions: Equatable, Sendable {
        let writeCurrentSegment: [Int]
        let closedBoundary: Boundary?
        let writeNextSegment: [Int]
        let audioCut: Double?
        let selectionFrameDuration: Double?
    }

    struct AlignmentState: Sendable {
        private var held: [PacketStamp] = []
        private(set) var heldBytes = 0
        private var lastVideoWatermark = -Double.infinity
        private var closedFrontier = -Double.infinity
        private var pendingBoundary: Boundary?

        var heldTokens: [Int] { held.map(\.token) }
        var hasPendingBoundary: Bool { pendingBoundary != nil }

        /// Once an audio sample boundary closes, a packet starting below that real sample cut can no longer be
        /// written into its rightful segment. A video boundary may remain pending until its straddling audio
        /// frame arrives, so late normal demux interleave is accepted until the actual audio cut is chosen.
        func isBehindClosedFrontier(_ timestamp: Double) -> Bool {
            timestamp < closedFrontier
        }

        func canAccept(byteCount: Int) -> Bool {
            byteCount >= 0
                && held.count < maxHeldAudioPackets
                && byteCount <= maxHeldAudioBytes - heldBytes
        }

        mutating func enqueue(_ packet: PacketStamp) -> Bool {
            guard packet.ownership == .ownedReference,
                  packet.timestamp.isFinite,
                  packet.duration.isFinite,
                  packet.duration >= 0,
                  packet.decodeEnd.isFinite,
                  !isBehindClosedFrontier(packet.timestamp),
                  canAccept(byteCount: packet.byteCount) else { return false }
            held.append(packet)
            heldBytes += packet.byteCount
            return true
        }

        mutating func advanceVideo(to watermark: Double, closing boundary: Boundary?) -> DrainActions {
            guard watermark.isFinite, watermark >= lastVideoWatermark else {
                return emptyDrainActions
            }
            lastVideoWatermark = watermark
            if let boundary {
                guard pendingBoundary == nil else { return emptyDrainActions }
                pendingBoundary = boundary
            }
            return drainHeldAudio()
        }

        /// Re-evaluate a pending video boundary after another audio packet arrives in normal demux order.
        /// Uses the last video watermark, so audio can prove the nearest sample cut without advancing video.
        mutating func drainAvailableAudio() -> DrainActions {
            drainHeldAudio()
        }

        private var emptyDrainActions: DrainActions {
            DrainActions(
                writeCurrentSegment: [],
                closedBoundary: nil,
                writeNextSegment: [],
                audioCut: nil,
                selectionFrameDuration: nil)
        }

        private mutating func drainHeldAudio() -> DrainActions {
            guard let boundary = pendingBoundary else {
                var current: [Int] = []
                var remaining: [PacketStamp] = []
                for (index, packet) in held.enumerated() {
                    // Keep one real trailing sample as lookahead. A later video boundary may fall inside it,
                    // and nearest-boundary selection cannot be recovered after the packet reaches the muxer.
                    let hasSuccessor = index < held.count - 1
                    if hasSuccessor, packet.decodeEnd <= lastVideoWatermark {
                        current.append(packet.token)
                        heldBytes -= packet.byteCount
                    } else {
                        remaining.append(packet)
                    }
                }
                held = remaining
                return DrainActions(
                    writeCurrentSegment: current,
                    closedBoundary: nil,
                    writeNextSegment: [],
                    audioCut: nil,
                    selectionFrameDuration: nil)
            }

            let videoCut = boundary.end
            guard let pivot = held.first(where: {
                $0.timestamp >= videoCut || $0.decodeEnd >= videoCut
            }) else {
                var current: [Int] = []
                var remaining: [PacketStamp] = []
                for packet in held {
                    if packet.timestamp <= lastVideoWatermark, packet.decodeEnd < videoCut {
                        current.append(packet.token)
                        heldBytes -= packet.byteCount
                    } else {
                        remaining.append(packet)
                    }
                }
                held = remaining
                return DrainActions(
                    writeCurrentSegment: current,
                    closedBoundary: nil,
                    writeNextSegment: [],
                    audioCut: nil,
                    selectionFrameDuration: nil)
            }

            let audioCut: Double
            if pivot.timestamp >= videoCut {
                audioCut = pivot.timestamp
            } else if pivot.decodeEnd <= videoCut {
                audioCut = pivot.decodeEnd
            } else {
                let distanceToStart = videoCut - pivot.timestamp
                let distanceToEnd = pivot.decodeEnd - videoCut
                audioCut = distanceToStart < distanceToEnd ? pivot.timestamp : pivot.decodeEnd
            }

            var current: [Int] = []
            var next: [Int] = []
            var remaining: [PacketStamp] = []
            current.reserveCapacity(held.count)
            next.reserveCapacity(held.count)
            remaining.reserveCapacity(held.count)

            for packet in held {
                guard packet.timestamp <= lastVideoWatermark else {
                    remaining.append(packet)
                    continue
                }
                if packet.timestamp >= audioCut {
                    next.append(packet.token)
                } else if packet.decodeEnd <= audioCut {
                    current.append(packet.token)
                } else {
                    remaining.append(packet)
                    continue
                }
                heldBytes -= packet.byteCount
            }
            held = remaining
            pendingBoundary = nil
            closedFrontier = max(closedFrontier, audioCut)
            return DrainActions(
                writeCurrentSegment: current,
                closedBoundary: boundary,
                writeNextSegment: next,
                audioCut: audioCut,
                selectionFrameDuration: pivot.duration)
        }

        mutating func drainAtEOF() -> [Int] {
            let tokens = held.map(\.token)
            held.removeAll(keepingCapacity: false)
            heldBytes = 0
            return tokens
        }
    }

    // MARK: - Packet-derived segment coverage

    struct AudioPacketTiming: Equatable, Sendable {
        let decodeStart: Double
        let duration: Double

        var decodeEnd: Double { decodeStart + duration }
    }

    struct AudioCoverageProof: Equatable, Sendable {
        let decodeStart: Double
        let decodeEnd: Double
        let leadingPacketDuration: Double
        let trailingPacketDuration: Double
    }

    /// Accumulates only timestamps and durations read from accepted source AVPackets. A segment can close only
    /// at one real sample boundary nearest the video cut, while the decode timeline remains continuous across
    /// the prior audio segment with no dropped or duplicated packet.
    /// Caller-supplied boundary values are validation targets; they are never substituted for packet times.
    struct AudioCoverageState: Sendable {
        private var openStart: Double?
        private var openEnd: Double?
        private var openFirstDuration: Double?
        private var openLastStart: Double?
        private var openLastDuration: Double?
        private var previousDecodeEnd: Double?
        private var previousBoundaryEnd: Double?
        private var previousBoundaryID: Int?
        private var isValid = true

        var currentDecodeEnd: Double? { openEnd }
        var currentTrailingPacketDuration: Double? { openLastDuration }

        mutating func accept(_ timing: AudioPacketTiming) -> Bool {
            guard isValid,
                  timing.decodeStart.isFinite,
                  timing.duration.isFinite,
                  timing.duration > 0,
                  timing.decodeEnd.isFinite,
                  timing.decodeEnd > timing.decodeStart else {
                isValid = false
                return false
            }

            if let expected = openEnd ?? previousDecodeEnd,
               abs(timing.decodeStart - expected) > MultiAudioPolicy.alignmentTolerance {
                isValid = false
                return false
            }
            if openStart == nil {
                openStart = timing.decodeStart
                openFirstDuration = timing.duration
            }
            openEnd = timing.decodeEnd
            openLastStart = timing.decodeStart
            openLastDuration = timing.duration
            return true
        }

        mutating func close(boundary: Boundary,
                            audioCut: Double? = nil,
                            selectionFrameDuration: Double? = nil) -> AudioCoverageProof? {
            let chosenCut = audioCut ?? boundary.end
            guard isValid,
                  boundary.id >= 0,
                  boundary.start.isFinite,
                  boundary.duration.isFinite,
                  boundary.duration > 0,
                  boundary.end.isFinite,
                  let decodeStart = openStart,
                  let decodeEnd = openEnd,
                  let firstDuration = openFirstDuration,
                  let lastDecodeStart = openLastStart,
                  let lastDuration = openLastDuration,
                  chosenCut.isFinite,
                  lastDecodeStart <= chosenCut + MultiAudioPolicy.alignmentTolerance,
                  abs(decodeEnd - chosenCut) <= MultiAudioPolicy.alignmentTolerance else {
                isValid = false
                return nil
            }
            let cutQuantum = selectionFrameDuration ?? lastDuration
            let videoDrift = chosenCut - boundary.end
            if abs(videoDrift) > MultiAudioPolicy.alignmentTolerance {
                guard cutQuantum.isFinite,
                      cutQuantum > 0,
                      abs(videoDrift) <= cutQuantum / 2 + MultiAudioPolicy.alignmentTolerance else {
                    isValid = false
                    return nil
                }
            }
            if let previousBoundaryEnd {
                guard abs(boundary.start - previousBoundaryEnd) <= MultiAudioPolicy.alignmentTolerance else {
                    isValid = false
                    return nil
                }
            } else {
                let startDrift = decodeStart - boundary.start
                if abs(startDrift) > MultiAudioPolicy.alignmentTolerance,
                   abs(startDrift) > firstDuration / 2 + MultiAudioPolicy.alignmentTolerance {
                    isValid = false
                    return nil
                }
            }
            if let previousBoundaryID, boundary.id != previousBoundaryID + 1 {
                isValid = false
                return nil
            }

            let proof = AudioCoverageProof(
                decodeStart: decodeStart,
                decodeEnd: decodeEnd,
                leadingPacketDuration: firstDuration,
                trailingPacketDuration: lastDuration)
            previousDecodeEnd = decodeEnd
            previousBoundaryEnd = boundary.end
            previousBoundaryID = boundary.id
            openStart = nil
            openEnd = nil
            openFirstDuration = nil
            openLastStart = nil
            openLastDuration = nil
            return proof
        }
    }

    // MARK: - Honest final media boundary

    enum MediaEndBasis: Equatable, Sendable {
        case packetDuration
        case derivedFrameDuration
    }

    struct MediaEndObservation: Equatable, Sendable {
        let seconds: Double
        let basis: MediaEndBasis
    }

    enum FinalizationDecision: Equatable, Sendable {
        case close(end: Double)
        case failUnproven
    }

    static func finalizationDecision(observedEnd: Double?) -> FinalizationDecision {
        guard let observedEnd, observedEnd.isFinite, observedEnd > 0 else { return .failUnproven }
        return .close(end: observedEnd)
    }

    /// Tracks the observed end of video packets for the final HLS segment. A real packet duration always wins.
    /// When it is absent, only a frame duration already established by an earlier packet/cadence may supply
    /// exactly one final frame. Classifier signaling alone cannot bootstrap an unobserved packet tail. Derived
    /// values remain explicitly marked and are never clamped to, or replaced with, a default/target duration.
    struct MediaEndState: Sendable {
        private static let minimumFrameDuration = 1.0 / 240.0
        private static let maximumFrameDuration = 1.0 / 15.0

        private var previousStart: Double?
        private var lastKnownFrameDuration: Double?
        private(set) var latest: MediaEndObservation?

        var latestEnd: Double? { latest?.seconds }

        @discardableResult
        mutating func observe(packetStart: Double,
                              packetDuration: Double?,
                              signaledFrameDuration: Double?) -> MediaEndObservation? {
            guard packetStart.isFinite else { return nil }
            if let previousStart {
                let delta = packetStart - previousStart
                if Self.isValidDerivedFrameDuration(delta) {
                    lastKnownFrameDuration = delta
                }
            }

            let duration: Double
            let basis: MediaEndBasis
            if let packetDuration, packetDuration.isFinite, packetDuration > 0 {
                duration = packetDuration
                basis = .packetDuration
                if Self.isValidDerivedFrameDuration(packetDuration) {
                    lastKnownFrameDuration = packetDuration
                }
            } else {
                guard let known = lastKnownFrameDuration else {
                    previousStart = packetStart
                    return nil
                }
                duration = known
                basis = .derivedFrameDuration
            }
            let end = packetStart + duration
            guard end.isFinite, end > packetStart else { return nil }
            previousStart = packetStart
            let observation = MediaEndObservation(seconds: end, basis: basis)
            if latest == nil || end > (latest?.seconds ?? -.infinity) {
                latest = observation
            }
            return observation
        }

        private static func isValidDerivedFrameDuration(_ candidate: Double) -> Bool {
            candidate.isFinite
                && candidate >= minimumFrameDuration
                && candidate <= maximumFrameDuration
        }
    }

    // MARK: - Fail-open startup

    static let alternateStartupWaitSeconds = 2.0

    enum StartupState: Equatable, Sendable {
        case pending
        case ready
        case failed
    }

    enum StartupDecision: Equatable, Sendable {
        case wait
        case advertise
        case omit
    }

    enum AlternateFailureCategory: String, Equatable, Sendable {
        case packetBudget
        case byteBudget
        case deadline
        case sourceEnded
        case cancelled
        case allocation
        case discontinuity
        case incompleteCoverage
        case muxer
    }

    static func startupDecision(state: StartupState, elapsed: Double) -> StartupDecision {
        switch state {
        case .ready:
            return .advertise
        case .failed:
            return .omit
        case .pending:
            return elapsed.isFinite && elapsed < alternateStartupWaitSeconds ? .wait : .omit
        }
    }

    /// Plan finalization and window readiness are distinct receipts. The initial master stays pending until the
    /// complete resident video window has matching audio bytes. Once that receipt has opened the rendition,
    /// readiness is latched so a normal late newest audio packet can expose the stable aligned prefix instead of
    /// making an already-advertised AUDIO group transiently vanish.
    static func snapshotState(current: StartupState,
                              planFinalized: Bool,
                              fullWindowResident: Bool) -> StartupState {
        switch current {
        case .failed:
            return .failed
        case .ready:
            return planFinalized ? .ready : .failed
        case .pending:
            return planFinalized && fullWindowResident ? .ready : .pending
        }
    }
}
