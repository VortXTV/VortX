import Foundation

/// The two decisions the diagnostic-log export has to get right, split out of `VXDiagExport` so they are
/// plain functions of their inputs and can be proven by a standalone test.
///
/// `VXDiagExport` itself imports Network, CoreImage and SwiftUI and owns a live NWListener, none of which a
/// test can drive. What actually needed proving is not the socket plumbing: it is WHO is allowed to fetch the
/// file and WHAT bytes the file contains. Both are pure, so both live here.
enum VXDiagExportPolicy {

    // MARK: - Capability

    /// Bytes of capability material minted per `start()`. 16 bytes is 128 bits, encoded below as 32 hex
    /// characters of URL path.
    static let capabilityBytes = 16

    /// SCOPE, stated honestly rather than as a security claim.
    ///
    /// This is a user-triggered, local-network, bounded-window transfer: the owner opens the export screen,
    /// the listener binds for as long as that screen is up, and the screen's dismissal tears it down. The
    /// capability below raises the bar from "any device on this Wi-Fi that connects to the port gets the
    /// log, repeatedly" to "one GET of one unguessable path, once". It is NOT authentication, it is NOT
    /// transport security (the body crosses the LAN as cleartext HTTP, which is what a QR-scanning phone
    /// with no trust anchor can consume), and a party that can already read the owner's screen has the
    /// capability. What it does close is the part that was actually wrong: the previous listener served ANY
    /// connection whose bytes happened to contain a CRLF pair, never checked the method or the path, and
    /// stayed up serving repeat pulls for the whole session.
    ///
    /// Uses the system CSPRNG (`SystemRandomNumberGenerator` backs `UInt8.random`), minted fresh per start,
    /// so the path from a previous session is worthless.
    static func makeCapabilityPath() -> String {
        var bytes = [UInt8](repeating: 0, count: capabilityBytes)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return "/" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// What to do with one accepted connection's request bytes.
    enum Decision: Equatable {
        /// Exactly one `GET <capabilityPath>` before anything has been served.
        case serve
        /// Everything else. The caller must close WITHOUT writing bytes: an error body is still a reply, and
        /// a reply is still a signal to a scanner that something is here.
        case reject
    }

    /// Longest request line we will even look at. A request line is a method, a path and a version; anything
    /// longer is not a phone downloading a log.
    static let maxRequestLineBytes = 2048

    /// Decide from the raw request bytes. Pure: same bytes plus same state give the same answer.
    ///
    /// Requires the request LINE to be complete (terminated by CRLF or LF) before deciding, so a peer cannot
    /// be judged on a partial path. Requires the method to be GET, requires the path to equal the capability
    /// exactly (a query string is allowed and ignored), and requires that nothing has been served yet.
    static func decide(request: Data, capabilityPath: String, alreadyServed: Bool) -> Decision {
        guard !alreadyServed else { return .reject }
        guard let lineEnd = request.firstIndex(of: 0x0A) else { return .reject }
        let lineBytes = request[request.startIndex..<lineEnd]
        guard lineBytes.count <= maxRequestLineBytes else { return .reject }
        guard let rawLine = String(data: Data(lineBytes), encoding: .utf8) else { return .reject }
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "GET" else { return .reject }
        let target = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        // Length-independent comparison is pointless here (the length is fixed and public); an exact string
        // compare of a 128-bit path is the whole check.
        guard String(target) == capabilityPath else { return .reject }
        return .serve
    }

    // MARK: - Export bytes

    /// Reduce every http(s) URL in a line to `scheme://host/path`, dropping query and fragment.
    ///
    /// Moved here from `VXDiagExport` unchanged in behaviour so the export body is testable end to end. It
    /// is the FIRST of two passes and cannot be the only one: it strips a token that lives in a query
    /// string, and cannot see a bare 40-hex infohash sitting in a free-text server line, which is exactly
    /// what the bundled server writes on engine created/destroyed/idle/inactive/error/invalid-piece.
    static func scrubURLs(_ line: String) -> String {
        guard let urlPattern else { return line }
        let nsLine = line as NSString
        let matches = urlPattern.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        guard !matches.isEmpty else { return line }
        var result = line
        // Replace back-to-front so each earlier match's NSRange (computed against the original line) still
        // lines up with `result`: only text AFTER the current match has been touched by prior iterations.
        for match in matches.reversed() {
            let raw = nsLine.substring(with: match.range)
            guard let url = URL(string: raw), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "\(url.scheme ?? "?")://\(url.host ?? "?")\(url.path)")
        }
        return result
    }

    private static let urlPattern = try? NSRegularExpression(pattern: #"https?://[^\s"'<>()\[\]]+"#)

    /// The COMPLETE body of an export, formed at export time from whatever is currently on disk.
    ///
    /// Formed here rather than by rewriting the retained files in place, and that choice is the answer to
    /// the legacy-bytes problem: a scrubber installed on the WRITE path does nothing for the megabytes
    /// already sitting in Caches from before it existed, and `Caches/vortx-diag.log` and
    /// `Caches/stremio-server.log` both survive app updates. Sanitising here means every byte that leaves
    /// the device passes the current rules regardless of which build wrote it, and it means a future rule
    /// improvement retroactively covers old bytes instead of only new ones.
    ///
    /// Every line, ours and the bundled server's alike, goes through `VXProbeRedaction.scrub`, so the
    /// per-line byte cap, the control-character neutralisation and the identifier rules apply uniformly.
    static func exportBody(logContents: String, serverStatus: String?, serverTailLines: [String]) -> Data {
        var out = logContents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { VXProbeRedaction.scrub(String($0)) }
            .joined(separator: "\n")
        if out.isEmpty { out = "(diagnostic log is empty)\n" }
        guard let serverStatus else { return Data(out.utf8) }
        var section = "\n\n===== streaming server =====\nstatus: \(VXProbeRedaction.scrub(serverStatus))\n"
        if serverTailLines.isEmpty {
            section += "(server log empty or unavailable)\n"
        } else {
            section += "--- stremio-server.log (last \(serverTailLines.count) lines) ---\n"
            section += serverTailLines.map { VXProbeRedaction.scrub(scrubURLs($0)) }.joined(separator: "\n")
            section += "\n"
        }
        return Data((out + section).utf8)
    }
}
