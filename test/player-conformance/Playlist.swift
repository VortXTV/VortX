import Foundation

// HLS media-playlist parsing stays text-exact. EXTINF values are converted
// directly to integer milliseconds, and URI identity is never inferred from an
// array offset. This lets the harness verify the same absolute-id contract the
// server advertises in its seq/segs trace fields.

enum Playlist {
    struct Segment: Equatable {
        let id: Int
        let ms: Int
        let uri: String
        let renditionID: Int?
    }

    struct Parsed {
        let segments: [Segment]
        let endlist: Bool
        let mediaSequence: Int?
        let targetDuration: Int?
        let mapURI: String?
        let hasPlaylistTypeEvent: Bool
        let hasPreciseZeroStart: Bool
        let errors: [String]

        var count: Int { segments.count }
        var totalMs: Int {
            segments.reduce(into: 0) { total, segment in
                let (sum, overflow) = total.addingReportingOverflow(segment.ms)
                total = overflow ? Int.max : sum
            }
        }

        var advertisedRange: Range<Int>? {
            guard let mediaSequence, mediaSequence >= 0 else { return nil }
            let (end, overflow) = mediaSequence.addingReportingOverflow(segments.count)
            guard !overflow else { return nil }
            return mediaSequence..<end
        }

        var hasContiguousAbsoluteIDs: Bool {
            guard let mediaSequence else { return false }
            for (offset, segment) in segments.enumerated() {
                let (expected, overflow) = mediaSequence.addingReportingOverflow(offset)
                guard !overflow, segment.id == expected else { return false }
            }
            return true
        }

        var isValidAdvertisedWindow: Bool {
            errors.isEmpty && !segments.isEmpty && mediaSequence != nil && targetDuration != nil
                && mapURI != nil && (mediaSequence != 0 || hasPreciseZeroStart)
                && advertisedRange != nil && hasContiguousAbsoluteIDs
        }
    }

    enum StartupDisposition: Equatable {
        case ready
        case endedExempt
        case notReady
    }

    /// Read one rendered EXTINF as integer milliseconds without a Double.
    static func msFromExtinf(_ line: String) -> Int? {
        let prefix = "#EXTINF:"
        guard line.hasPrefix(prefix), line.hasSuffix(",") else { return nil }
        let value = String(line.dropFirst(prefix.count).dropLast())
        return msFromSecondsText(value)
    }

    static func msFromSecondsText(_ text: String) -> Int? {
        guard !text.isEmpty,
              text.filter({ $0 == "." }).count <= 1,
              text.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts[0].isEmpty, let seconds = Int(parts[0]) else { return nil }
        let (whole, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000)
        guard !multiplyOverflow else { return nil }
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        guard fraction.count <= 3, fraction.allSatisfy(\.isNumber) else { return nil }
        if fraction.count < 3 { fraction += String(repeating: "0", count: 3 - fraction.count) }
        guard let fractionMs = Int(fraction.isEmpty ? "0" : fraction) else { return nil }
        let (milliseconds, addOverflow) = whole.addingReportingOverflow(fractionMs)
        guard !addOverflow else { return nil }
        return milliseconds
    }

    static func parseMedia(_ body: String) -> Parsed {
        var segments: [Segment] = []
        var pendingMs: Int?
        var endlist = false
        var mediaSequence: Int?
        var targetDuration: Int?
        var mapURI: String?
        var sawMap = false
        var sawHeader = false
        var version: Int?
        var sawStart = false
        var hasEvent = false
        var errors: [String] = []
        var observedKind: String?
        var ended = false

        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if index != lines.indices.last { errors.append("empty line before playlist end") }
                continue
            }
            if !sawHeader {
                sawHeader = true
                if line != "#EXTM3U" { errors.append("missing leading EXTM3U") }
                continue
            }
            if ended {
                errors.append("content after ENDLIST")
                continue
            }
            if line == "#EXTM3U" {
                errors.append("duplicate EXTM3U")
            } else if line.hasPrefix("#EXT-X-VERSION:") {
                let parsed = strictNonnegativeInt(String(line.dropFirst("#EXT-X-VERSION:".count)))
                if version != nil { errors.append("duplicate VERSION") }
                version = parsed
                if parsed != 7 { errors.append("VERSION must be 7") }
            } else if line.hasPrefix("#EXTINF:") {
                if pendingMs != nil { errors.append("EXTINF without a segment URI") }
                pendingMs = msFromExtinf(line)
                if pendingMs == nil { errors.append("invalid EXTINF: \(line)") }
            } else if line == "#EXT-X-ENDLIST" {
                if pendingMs != nil { errors.append("ENDLIST before segment URI") }
                endlist = true
                ended = true
            } else if line == "#EXT-X-PLAYLIST-TYPE:EVENT" {
                hasEvent = true
                errors.append("EVENT playlists are forbidden")
            } else if line == "#EXT-X-START:TIME-OFFSET=0,PRECISE=YES"
                        || line == "#EXT-X-START:TIME-OFFSET=0.0,PRECISE=YES" {
                if sawStart { errors.append("duplicate EXT-X-START") }
                sawStart = true
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let parsed = strictNonnegativeInt(String(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)))
                if mediaSequence != nil { errors.append("duplicate MEDIA-SEQUENCE") }
                mediaSequence = parsed
                if parsed == nil { errors.append("invalid MEDIA-SEQUENCE") }
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                let parsed = strictNonnegativeInt(String(line.dropFirst("#EXT-X-TARGETDURATION:".count)))
                if targetDuration != nil { errors.append("duplicate TARGETDURATION") }
                targetDuration = parsed
                if parsed == nil || parsed == 0 { errors.append("invalid TARGETDURATION") }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                if sawMap { errors.append("duplicate EXT-X-MAP") }
                sawMap = true
                let prefix = "#EXT-X-MAP:URI=\""
                guard line.hasPrefix(prefix), line.hasSuffix("\"") else {
                    errors.append("invalid EXT-X-MAP")
                    continue
                }
                let parsed = String(line.dropFirst(prefix.count).dropLast())
                if parsed.isEmpty || parsed.contains("\"") { errors.append("invalid EXT-X-MAP URI") }
                else { mapURI = parsed }
            } else if !line.isEmpty, !line.hasPrefix("#") {
                guard let milliseconds = pendingMs else {
                    errors.append("segment URI without EXTINF: \(line)")
                    continue
                }
                pendingMs = nil
                if milliseconds <= 0 { errors.append("nonpositive EXTINF for \(line)") }
                guard let identity = segmentIdentity(fromURI: line) else {
                    errors.append("unrecognized segment URI: \(line)")
                    continue
                }
                let kind = identity.renditionID.map { "audio:\($0)" } ?? "video"
                if let observedKind {
                    if observedKind != kind { errors.append("mixed video/audio URI grammar") }
                } else {
                    observedKind = kind
                }
                segments.append(Segment(
                    id: identity.segmentID,
                    ms: milliseconds,
                    uri: line,
                    renditionID: identity.renditionID))
            } else {
                errors.append("unknown or malformed tag: \(line)")
            }
        }
        if pendingMs != nil { errors.append("final EXTINF without a segment URI") }
        if !sawHeader { errors.append("empty playlist") }
        if version == nil { errors.append("missing VERSION") }

        var durationTotal = 0
        for segment in segments {
            let (sum, overflow) = durationTotal.addingReportingOverflow(segment.ms)
            if overflow {
                errors.append("rendered duration total overflow")
                break
            }
            durationTotal = sum
        }

        if let sequence = mediaSequence {
            if sequence != 0 && sawStart { errors.append("EXT-X-START is valid only at sequence zero") }
            for (offset, segment) in segments.enumerated() {
                let (expected, overflow) = sequence.addingReportingOverflow(offset)
                if overflow || segment.id != expected {
                    errors.append("URI id \(segment.id) does not equal seq+offset")
                    break
                }
            }
            let (_, overflow) = sequence.addingReportingOverflow(segments.count)
            if overflow { errors.append("advertised range overflow") }
        } else {
            errors.append("missing MEDIA-SEQUENCE")
        }

        return Parsed(
            segments: segments,
            endlist: endlist,
            mediaSequence: mediaSequence,
            targetDuration: targetDuration,
            mapURI: mapURI,
            hasPlaylistTypeEvent: hasEvent,
            hasPreciseZeroStart: sawStart,
            errors: errors)
    }

    /// Exact relative-URI grammar emitted by production. Paths, queries, fragments,
    /// and aliases such as aseg0.m4s are deliberately rejected.
    static func segmentIdentity(fromURI uri: String) -> (renditionID: Int?, segmentID: Int)? {
        guard !uri.contains("/"), !uri.contains("?"), !uri.contains("#") else { return nil }
        let name = uri
        guard name.hasSuffix(".m4s") else { return nil }
        let stem = String(name.dropLast(4))
        if stem.hasPrefix("seg") {
            guard let id = nonnegativeInt(String(stem.dropFirst(3))) else { return nil }
            return (nil, id)
        }
        guard stem.hasPrefix("audio") else { return nil }
        let fields = String(stem.dropFirst(5)).components(separatedBy: "-seg")
        guard fields.count == 2,
              let renditionID = nonnegativeInt(fields[0]),
              let segmentID = nonnegativeInt(fields[1]) else { return nil }
        return (renditionID, segmentID)
    }

    static func segId(fromURI uri: String) -> Int? {
        guard let identity = segmentIdentity(fromURI: uri), identity.renditionID == nil else { return nil }
        return identity.segmentID
    }

    private static func nonnegativeInt(_ text: String) -> Int? {
        strictNonnegativeInt(text)
    }

    private static func strictNonnegativeInt(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let value = Int(text) else { return nil }
        return value
    }

    static func cohortReady(count: Int, totalMs: Int) -> Bool {
        count >= Contract.minStartupSegments && totalMs >= Contract.minStartupMs
    }

    static func isMinimalStartupCohort(_ playlist: Parsed) -> Bool {
        guard playlist.isValidAdvertisedWindow,
              playlist.mediaSequence == 0,
              !playlist.endlist,
              cohortReady(count: playlist.count, totalMs: playlist.totalMs),
              let final = playlist.segments.last else { return false }
        return !cohortReady(
            count: playlist.count - 1,
            totalMs: playlist.totalMs - final.ms)
    }

    static func startupDisposition(count: Int, totalMs: Int, ended: Bool) -> StartupDisposition {
        if cohortReady(count: count, totalMs: totalMs) { return .ready }
        return ended ? .endedExempt : .notReady
    }

    /// Use the production renderer with an explicit absolute start id.
    static func buildMediaBodyLikeServer(
        durations: [Double],
        ended: Bool,
        startID: Int = 0,
        mapURI: String = "init.mp4"
    ) -> String {
        var segments: [VortXHLSSegment] = []
        for (offset, duration) in durations.enumerated() {
            let (id, overflow) = startID.addingReportingOverflow(offset)
            guard !overflow else { return "" }
            segments.append(VortXHLSSegment(
                id: id, byteOffset: 0, byteLength: 0, duration: duration))
        }
        return DVPlaybackPolicy.mediaPlaylistLines(
            window: VortXHLSWindow(segments: segments),
            ended: ended,
            targetDuration: Contract.hlsTargetDuration,
            mapURI: mapURI
        ).joined(separator: "\n")
    }
}
