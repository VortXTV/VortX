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
                && mapURI != nil
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
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var value = String(line[line.index(after: colon)...])
        if let comma = value.firstIndex(of: ",") { value = String(value[..<comma]) }
        return msFromSecondsText(value.trimmingCharacters(in: .whitespaces))
    }

    static func msFromSecondsText(_ text: String) -> Int? {
        let sign = text.hasPrefix("-") ? -1 : 1
        let unsigned = text.hasPrefix("-") || text.hasPrefix("+") ? String(text.dropFirst()) : text
        guard !unsigned.isEmpty,
              unsigned.filter({ $0 == "." }).count <= 1,
              unsigned.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let parts = unsigned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts[0].isEmpty, let seconds = Int(parts[0]) else { return nil }
        let (whole, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000)
        guard !multiplyOverflow else { return nil }
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        guard fraction.allSatisfy(\.isNumber) else { return nil }
        if fraction.count < 3 { fraction += String(repeating: "0", count: 3 - fraction.count) }
        if fraction.count > 3 { fraction = String(fraction.prefix(3)) }
        guard let fractionMs = Int(fraction.isEmpty ? "0" : fraction) else { return nil }
        let (milliseconds, addOverflow) = whole.addingReportingOverflow(fractionMs)
        guard !addOverflow else { return nil }
        return sign * milliseconds
    }

    static func parseMedia(_ body: String) -> Parsed {
        var segments: [Segment] = []
        var pendingMs: Int?
        var endlist = false
        var mediaSequence: Int?
        var targetDuration: Int?
        var mapURI: String?
        var sawMap = false
        var hasEvent = false
        var errors: [String] = []
        var observedKind: String?

        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                if pendingMs != nil { errors.append("EXTINF without a segment URI") }
                pendingMs = msFromExtinf(line)
                if pendingMs == nil { errors.append("invalid EXTINF: \(line)") }
            } else if line == "#EXT-X-ENDLIST" {
                endlist = true
            } else if line == "#EXT-X-PLAYLIST-TYPE:EVENT" {
                hasEvent = true
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let parsed = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count))
                if mediaSequence != nil { errors.append("duplicate MEDIA-SEQUENCE") }
                mediaSequence = parsed
                if parsed == nil || parsed! < 0 { errors.append("invalid MEDIA-SEQUENCE") }
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                let parsed = Int(line.dropFirst("#EXT-X-TARGETDURATION:".count))
                if targetDuration != nil { errors.append("duplicate TARGETDURATION") }
                targetDuration = parsed
                if parsed == nil || parsed! <= 0 { errors.append("invalid TARGETDURATION") }
            } else if line.hasPrefix("#EXT-X-MAP:URI=\"") {
                if sawMap { errors.append("duplicate EXT-X-MAP") }
                sawMap = true
                let rest = line.dropFirst("#EXT-X-MAP:URI=\"".count)
                if let quote = rest.firstIndex(of: "\"") {
                    let parsed = String(rest[..<quote])
                    if parsed.isEmpty { errors.append("empty EXT-X-MAP URI") }
                    else { mapURI = parsed }
                } else {
                    errors.append("invalid EXT-X-MAP")
                }
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
            }
        }
        if pendingMs != nil { errors.append("final EXTINF without a segment URI") }

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
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let value = Int(text), value >= 0 else { return nil }
        return value
    }

    static func cohortReady(count: Int, totalMs: Int) -> Bool {
        count >= Contract.minStartupSegments && totalMs >= Contract.minStartupMs
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
