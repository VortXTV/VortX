import Foundation

// =============================================================================
// HLS media-playlist measurement.
//
// The whole point of contract (1) is that the advertised duration is measured
// from the EXACT three-decimal EXTINF TEXT the server emits, as integer
// milliseconds, and compared as integers. So this parser NEVER routes the value
// through a Double: it reads the digits of the "%.3f" text directly. That is the
// only way the 14.999-vs-15.000 (1 ms) boundary is decided the same way the
// server's own `String(format:"%.3f", dur)` rounding decided it.
// =============================================================================

enum Playlist {

    /// Integer milliseconds from one `#EXTINF:<seconds>,` line, read from the
    /// three-decimal TEXT with no floating point:
    ///   "4.000" -> 4000, "14.999" -> 14999, "15.000" -> 15000, "1" -> 1000.
    /// The fractional field is padded/truncated to exactly three digits, which is
    /// what `%.3f` always emits, so this is an exact inverse of the server format.
    static func msFromExtinf(_ line: String) -> Int? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var value = String(line[line.index(after: colon)...])
        if let comma = value.firstIndex(of: ",") { value = String(value[..<comma]) }
        return msFromSecondsText(value.trimmingCharacters(in: .whitespaces))
    }

    /// Integer milliseconds from a bare seconds TEXT such as "4.000" (no `#EXTINF`
    /// prefix). Exposed so the oracle self-test can feed the boundary strings
    /// straight in and exercise the identical code path the playlist parser uses.
    static func msFromSecondsText(_ text: String) -> Int? {
        let sign = text.hasPrefix("-") ? -1 : 1
        let unsigned = text.hasPrefix("-") || text.hasPrefix("+") ? String(text.dropFirst()) : text
        guard !unsigned.isEmpty, unsigned.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let parts = unsigned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intMs = (Int(parts[0]) ?? 0) * 1000
        var frac = parts.count > 1 ? String(parts[1]) : ""
        if frac.count < 3 { frac += String(repeating: "0", count: 3 - frac.count) }
        else if frac.count > 3 { frac = String(frac.prefix(3)) }   // %.3f never emits more; guard anyway
        let fracMs = Int(frac) ?? 0
        return sign * (intMs + fracMs)
    }

    struct Parsed {
        let segments: [(id: Int, ms: Int)]   // in playlist order
        let endlist: Bool
        let mediaSequence: Int
        let targetDuration: Int
        var count: Int { segments.count }
        var totalMs: Int { segments.reduce(0) { $0 + $1.ms } }
    }

    /// Parse a media playlist body into its segment list (id + integer ms),
    /// ENDLIST flag, MEDIA-SEQUENCE and TARGETDURATION. Segment ids come from the
    /// `segN.m4s` URIs, so a mismatched EXTINF/URI pairing is caught rather than
    /// silently indexed by position.
    static func parseMedia(_ body: String) -> Parsed {
        var segs: [(Int, Int)] = []
        var pendingMs: Int?
        var endlist = false
        var mediaSeq = 0
        var target = 0
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                pendingMs = msFromExtinf(line)
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                endlist = true
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSeq = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                target = Int(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? 0
            } else if !line.isEmpty, !line.hasPrefix("#") {
                let id = segId(fromURI: line)
                segs.append((id ?? segs.count, pendingMs ?? -1))
                pendingMs = nil
            }
        }
        return Parsed(segments: segs, endlist: endlist, mediaSequence: mediaSeq, targetDuration: target)
    }

    /// `seg12.m4s` -> 12, `init.mp4` -> nil. Tolerates a leading path.
    static func segId(fromURI uri: String) -> Int? {
        let name = uri.split(separator: "/").last.map(String.init) ?? uri
        guard name.hasPrefix("seg"), name.hasSuffix(".m4s") else { return nil }
        return Int(name.dropFirst(3).dropLast(4))
    }

    // MARK: - Contract (1) predicate

    /// The startup cohort gate: both floors, ANDed, integer comparison. `ended`
    /// exempts a source that finished remuxing before the cohort could fill - a
    /// 3-second clip can never advertise 15 s, and the server must still start it
    /// (the beta gate's `|| ended`). The exemption is reported separately so it is
    /// never mistaken for a pass on a still-producing stream.
    static func cohortReady(count: Int, totalMs: Int) -> Bool {
        count >= Contract.minStartupSegments && totalMs >= Contract.minStartupMs
    }

    // MARK: - Server-faithful body build (exercises the REAL header builder)

    /// Rebuild a media body EXACTLY as `VortXRemuxHLSServer.buildMediaBody` does:
    /// the header from the real, dependency-free `DVPlaybackPolicy.mediaPlaylistHeader`
    /// (compiled into this harness), then one `#EXTINF:%.3f,` + `segN.m4s` per
    /// segment, then optional ENDLIST. Used by the self-test to prove the round
    /// trip (build -> parse -> measure) matches, so the measurement is validated
    /// against the shipping format rather than a guess of it.
    static func buildMediaBodyLikeServer(durations: [Double], ended: Bool, mapURI: String = "init.mp4") -> String {
        var lines = DVPlaybackPolicy.mediaPlaylistHeader(targetDuration: Contract.hlsTargetDuration, mapURI: mapURI)
        for (i, d) in durations.enumerated() {
            lines.append(String(format: "#EXTINF:%.3f,", d))
            lines.append("seg\(i).m4s")
        }
        if ended { lines.append("#EXT-X-ENDLIST") }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
