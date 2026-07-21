import Foundation
import CryptoKit

/// The SINK-side scrubber for the diagnostic log.
///
/// WHAT THIS IS FOR, stated without inflation. `VXProbe` is OFF BY DEFAULT (see VXProbe.enabled: it needs
/// either the VORTX_PROBE=1 launch flag or the Settings "Diagnostic logging" toggle). Nothing here is silent
/// collection from every user. It is OPT-IN exposure, and it lands at exactly the moment that matters: the
/// only reason a user turns probing on is to reproduce a problem and then EXPORT AND SHARE the file, usually
/// into a public issue or chat. So the risk is concentrated rather than broad, and the mitigation belongs at
/// the point of writing rather than at the point of reading.
///
/// WHY A SINK SCRUBBER AND NOT ONLY CLEAN PRODUCERS. Both, actually. Fixing the producers is the real fix and
/// is done separately; this is the BACKSTOP, and it exists because the producer set is not closed. 19 files
/// call `VXProbe`, and the same class of defect was reintroduced repeatedly by new call sites that were each
/// individually reasonable ("just log the key so I can tell which title this was"). A scrubber at the single
/// write path means a NEW producer cannot reintroduce the class, only reduce the log's usefulness.
///
/// WHAT IT DOES NOT DO, so nobody reads more into it than is there:
///   - It is pattern-based. It removes the identifier SHAPES that this codebase actually emits (catalog ids,
///     40-hex tokens, URL credentials). It cannot recognise an identifier with no shape, and a free-text
///     title ("open Breaking Bad S03E05") is not a shape. That is precisely why the producers are also fixed.
///   - The placeholder hash is a CORRELATION token, not an anonymity guarantee. Its salt is random per
///     process and never written anywhere, so two occurrences in ONE exported file are linkable and nothing
///     across two files is. Against an attacker who somehow knew the salt, the id space is small enough to
///     enumerate; the salt not existing outside the process is the whole protection.
enum VXProbeRedaction {

    /// Hard cap on one written line. A single line is a diagnostic, not a payload: anything past this is
    /// either a dumped body or a hostile identifier, and both are exactly what must not reach the file.
    static let maxLineBytes = 1024

    /// Per-process random salt for the placeholder hash. Never logged, never persisted, regenerated on every
    /// launch, so placeholders correlate within ONE exported run and are meaningless between runs.
    private static let salt: Data = {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }()

    /// Short, stable, non-reversible stand-in for one redacted value.
    static func token(_ tag: String, _ value: String) -> String {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(value.utf8))
        let digest = hasher.finalize()
        let hex = digest.prefix(3).map { String(format: "%02x", $0) }.joined()
        return "<\(tag):\(hex)>"
    }

    /// The PRODUCER-side spelling of the same idea: a call site that wants to say WHICH title a line is
    /// about writes this instead of the identifier. It yields the identical placeholder the sink would have
    /// produced, so lines about one title still correlate inside one exported run, and the identifier is
    /// never built into a string in the first place.
    ///
    /// Producers use this rather than relying on the sink because the sink is pattern-based: it recognises
    /// the id SHAPES this codebase emits, and a producer that is already holding the value can be exact.
    static func identityToken(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "-" }
        return token("id", raw)
    }

    /// The redaction rules, most specific first. Ordering is load-bearing: credentials inside a URL must be
    /// removed before the generic 40-hex rule turns a passkey into a plain hash token and loses the fact that
    /// it was a credential at all.
    private struct Rule {
        let tag: String
        let regex: NSRegularExpression
        /// Capture group whose contents are replaced. 0 means the whole match.
        let group: Int
    }

    private static func compile(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let rules: [Rule] = {
        var out: [Rule] = []
        // user:password@host in any URL.
        //
        // The scheme repetition is BOUNDED ({0,15}) rather than `*`, and that is not cosmetic. With `*` this
        // pattern is quadratic on a long run of scheme-legal characters: at every start position the greedy
        // class consumes to end-of-line and then backtracks looking for "://". A single 200 KB line hung the
        // scrubber outright, and the scrubber sits on the path that writes the log. No real scheme is longer
        // than a handful of characters, so the bound costs nothing.
        if let r = compile(#"[a-z][a-z0-9+.\-]{0,15}://([^\s/@]+)@"#) { out.append(Rule(tag: "cred", regex: r, group: 1)) }
        // Credential-bearing query parameters, whatever the host.
        if let r = compile(#"[?&](?:api[_-]?key|apikey|token|access[_-]?token|key|passkey|auth|authorization|password|passwd|secret|sig|signature|session|sid)=([^&\s"']+)"#) {
            out.append(Rule(tag: "secret", regex: r, group: 1))
        }
        // Any 40-hex run: torrent infohashes AND private-tracker passkeys share this shape.
        if let r = compile(#"\b[0-9a-f]{40}\b"#) { out.append(Rule(tag: "hex40", regex: r, group: 0)) }
        // Catalog identities. These ARE viewing history: "tt0903747" plus an episode pair says what was
        // watched. The coordinates are deliberately left readable, because they carry the triage value
        // (which episode of SOMETHING) without the part that names the title.
        if let r = compile(#"\btt[0-9]{7,}\b"#) { out.append(Rule(tag: "tt", regex: r, group: 0)) }
        if let r = compile(#"\btmdb:[0-9]{1,10}\b"#) { out.append(Rule(tag: "tmdb", regex: r, group: 0)) }
        return out
    }()

    /// Bound the line FIRST, then redact, then bound again.
    ///
    /// The order is deliberate and was learned the hard way. Redacting first means every regex runs over an
    /// attacker-chosen length, and this code runs on the path that writes the log: a pathological line must
    /// not be able to stall it. Bounding first makes the regex work fixed-cost no matter what was passed in.
    ///
    /// The cost of that order, stated rather than hidden: truncation can cut an identifier in half, and half a
    /// 40-hex token no longer matches the 40-hex rule, so a prefix of it can survive on a line that was over
    /// the cap. That is accepted. Such a line is already a bug at the producer (a diagnostic is not a payload),
    /// the surviving fragment is a fragment, and the alternative is an unbounded-work path in the logger.
    ///
    /// The second bound exists because redaction can lengthen a line: a short identifier becomes a longer
    /// placeholder, so a line just under the cap can cross it during replacement.
    static func scrub(_ raw: String) -> String {
        var text = bound(raw)
        for rule in rules { text = apply(rule, to: text) }
        return bound(text)
    }

    private static func apply(_ rule: Rule, to text: String) -> String {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = rule.regex.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return text }
        var out = text
        // Reverse order so each replacement cannot invalidate the ranges still to be applied.
        for match in matches.reversed() {
            let target = match.range(at: rule.group)
            guard target.location != NSNotFound, let range = Range(target, in: out) else { continue }
            out.replaceSubrange(range, with: token(rule.tag, String(out[range])))
        }
        return out
    }

    private static let truncationMarker = " [truncated]"

    /// Truncate on a UTF-8 byte budget without splitting a scalar, and say so in the line rather than
    /// silently dropping the tail.
    ///
    /// IDEMPOTENT, because `scrub` bounds twice: the marker is counted INSIDE the budget, so the result is
    /// always <= maxLineBytes and a second pass over an already-bounded line is a no-op rather than a second
    /// marker stapled onto the first.
    private static func bound(_ text: String) -> String {
        guard text.utf8.count > maxLineBytes else { return text }
        let budget = maxLineBytes - truncationMarker.utf8.count
        var out = ""
        var used = 0
        for character in text {
            let width = String(character).utf8.count
            if used + width > budget { break }
            out.append(character)
            used += width
        }
        return out + truncationMarker
    }
}
