import Foundation
import CryptoKit

/// The SINK-side scrubber and the ONE durable-line formatter for every diagnostic channel this app writes.
///
/// WHAT THIS IS FOR, stated without inflation. There are three durable channels, and they do NOT share a
/// privacy posture, so the honest statement is per channel rather than one reassuring sentence:
///   - `vortx-diag.log` (VXProbe) is OPT-IN: it needs VORTX_PROBE=1 or the Settings "Diagnostic logging"
///     toggle. It is the file a user exports and pastes into a public issue, so the exposure is concentrated
///     at the moment of sharing.
///   - `diagnostics.log` (DiagnosticsLog) is ALWAYS ON for every user. It is not part of the normal export
///     (it is a pull-over-USB escape hatch), but it is durable on device regardless of any toggle.
///   - `stremio-server.log` (the embedded streaming server) is written by bundled JavaScript we do not own,
///     retained across boots, and DOES leave the device: the export appends a tail of it.
/// Every one of those lines is formed by `durableLine` below, so there is exactly one place where a string
/// becomes a durable diagnostic line.
///
/// WHY A SINK SCRUBBER AND NOT ONLY CLEAN PRODUCERS. Both, actually. Fixing the producers is the real fix and
/// is done separately; this is the BACKSTOP, and it exists because the producer set is not closed.
///
/// WHAT IT DOES NOT DO. Read this part twice, because the failure mode of a pattern scrubber is that people
/// stop reading it as best-effort:
///   - It is pattern-based and therefore PERMANENTLY BEST-EFFORT. Adversarial testing of an earlier revision
///     found seven distinct ways to walk an identifier straight through it (a six-digit `tt` id under a
///     seven-digit rule, a 41- and a 64-character hex run under an exactly-40 rule, `auth_token` missing from
///     a hand-written credential list, a forged second log line via an un-neutralised newline, zero-width and
///     homoglyph padding inside an id, `id_tt0903747` defeating a `\b` prefix, and an 11-digit `tmdb:` id
///     under a `{1,10}` bound). Those seven are closed. The eighth is not written yet. The TYPED-FIELD
///     contract at the producers is the real protection; this is the net under it, and a net has holes.
///   - It cannot recognise an identifier with no shape. A free-text title ("open Breaking Bad S03E05") is not
///     a shape, and no amount of pattern work will make it one.
///   - The placeholder hash is a CORRELATION token, not an anonymity guarantee. Its salt is random per
///     process and never written anywhere, so two occurrences in ONE exported file are linkable and nothing
///     across two files is. Remove the salt and every placeholder becomes a plain unkeyed SHA-256 prefix over
///     an id space small enough to enumerate exhaustively; the salt not existing outside the process is the
///     whole protection, and `VXProbeRedactionTests` proves the salt is actually mixed in.
enum VXProbeRedaction {

    /// Hard cap on one COMPLETE durable line: timestamp, brackets, category, spacing and the terminating
    /// newline all count against it. The earlier revision capped only the MESSAGE and then stapled a
    /// timestamp and category onto it, so the written line routinely exceeded the limit the constant claimed
    /// to set. A single line is a diagnostic, not a payload: anything past this is either a dumped body or a
    /// hostile identifier, and both are exactly what must not reach the file.
    static let maxLineBytes = 1024

    /// Hard cap on the category field of a durable line. `DiagnosticsLog` takes a free-form `String`
    /// category from 152 call sites, so the category is attacker-reachable in exactly the way the message is.
    static let maxCategoryBytes = 24

    /// Hard cap on the timestamp field. We form the timestamp ourselves, but an unguarded parameter is not a
    /// chokepoint, and this is the chokepoint.
    static let maxTimestampBytes = 32

    /// Hard cap on the bytes hashed for one placeholder. `token` used to build `Data(value.utf8)` over the
    /// COMPLETE raw value and `identityToken` accepts arbitrary producer strings, so unbounded allocation
    /// came back at the producer even with the sink bounded. Bounding here costs one property: two values
    /// sharing their first `maxTokenInputBytes` bytes collapse to one placeholder. Identifiers are far
    /// shorter than this, so that case is a bug at the producer rather than a loss of triage value.
    static let maxTokenInputBytes = 512

    /// Per-process random salt for the placeholder hash. Never logged, never persisted, regenerated on every
    /// launch, so placeholders correlate within ONE exported run and are meaningless between runs.
    private static let salt: Data = {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }()

    /// Short, stable, non-reversible stand-in for one redacted value.
    ///
    /// The input is BOUNDED BEFORE it is turned into `Data`. That ordering is the whole point: a hostile
    /// 200,000-character value must not be copied into a buffer just to be hashed down to three bytes.
    static func token(_ tag: String, _ value: String) -> String {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(clampBytes(value, maxTokenInputBytes).utf8))
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

    // MARK: - Normalisation

    /// Scalars that carry no glyph and exist, for our purposes, to break a pattern apart: zero-width spaces
    /// and joiners, bidi overrides, variation selectors, and combining marks. `tt\u{200B}0903747` reads as an
    /// IMDb id to a human and to `Int()`, and read as nine separate things by a regex. They are DROPPED, and
    /// the folded form is what gets written: a diagnostic line is not user content, and preserving an
    /// attacker's zero-width padding is not a feature worth a fail-open.
    private static func isIgnorable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x061C, 0xFEFF: return true                       // soft hyphen, arabic letter mark, BOM
        case 0x200B...0x200F: return true                              // zero-width space/joiners, LRM/RLM
        case 0x202A...0x202E: return true                              // bidi embedding + OVERRIDE
        case 0x2060...0x2064, 0x2066...0x2069: return true             // word joiner, invisible ops, isolates
        case 0x0300...0x036F, 0x1AB0...0x1AFF: return true             // combining marks
        case 0x1DC0...0x1DFF, 0x20D0...0x20FF: return true             // combining marks (supplement/symbols)
        case 0xFE00...0xFE0F, 0xFE20...0xFE2F: return true             // variation selectors, combining halves
        default: return false
        }
    }

    /// A deliberately SMALL confusable table: the Cyrillic and Greek letters that render as the ASCII letters
    /// our identifier shapes are built from. It is not a general homoglyph defence and is not claimed to be
    /// one. Its job is that `\u{0442}\u{0442}0903747` cannot be spelled with lookalike `t`s and walk out.
    /// The cost, stated: a genuinely Cyrillic or Greek word in a diagnostic line comes out partly Latinised.
    /// A diagnostic line is machine chatter, so that is the cheaper side of the trade.
    private static let confusables: [Unicode.Scalar: Unicode.Scalar] = [
        // Cyrillic lowercase that render as Latin.
        "\u{0430}": "a", "\u{0432}": "b", "\u{0435}": "e", "\u{043A}": "k", "\u{043C}": "m",
        "\u{043D}": "h", "\u{043E}": "o", "\u{0440}": "p", "\u{0441}": "c", "\u{0442}": "t",
        "\u{0443}": "y", "\u{0445}": "x", "\u{0455}": "s", "\u{0456}": "i", "\u{0458}": "j",
        // Cyrillic uppercase that render as Latin.
        "\u{0410}": "A", "\u{0412}": "B", "\u{0415}": "E", "\u{041A}": "K", "\u{041C}": "M",
        "\u{041D}": "H", "\u{041E}": "O", "\u{0420}": "P", "\u{0421}": "C", "\u{0422}": "T",
        "\u{0425}": "X", "\u{0405}": "S", "\u{0406}": "I", "\u{0408}": "J",
        // Greek lowercase that render as Latin.
        "\u{03B1}": "a", "\u{03B5}": "e", "\u{03B9}": "i", "\u{03BA}": "k", "\u{03BD}": "v",
        "\u{03BF}": "o", "\u{03C1}": "p", "\u{03C4}": "t", "\u{03C5}": "u", "\u{03C7}": "x"
    ]

    /// Drop the invisible, fold the lookalike, and pull the compatibility digit forms back to ASCII, so the
    /// rules below see one spelling of an identifier rather than an open set of them.
    ///
    /// Linear in the input and allocation-bounded per scalar, so it is safe to run BEFORE the length bound
    /// (it has to run first: bounding a string whose bytes are mostly zero-width padding would otherwise
    /// throw away the part that matters).
    static func fold(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            if isIgnorable(scalar) { continue }
            switch scalar.value {
            case 0xFF01...0xFF5E:
                // Fullwidth ASCII forms: 'ｔｔ０９０３７４７' is an IMDb id to every eye but a regex's.
                out.append(Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar)
            case 0x1D7CE...0x1D7FF:
                // Mathematical bold/sans/monospace digit runs, all in blocks of ten.
                out.append(Unicode.Scalar(0x30 + (scalar.value - 0x1D7CE) % 10) ?? scalar)
            default:
                out.append(confusables[scalar] ?? scalar)
            }
        }
        return String(out)
    }

    /// Replace every character that could end or split a durable line with a printable escape.
    ///
    /// This is what stops LOG FORGERY, which is a different problem from leakage and was live: one record
    /// containing a newline wrote a SECOND line into the file, with an attacker-chosen timestamp and
    /// category, indistinguishable from a genuine entry to anyone reading the export. U+2028/U+2029 and
    /// U+0085 are included because plenty of viewers break lines on them too.
    static func neutralizeControls(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x0A: out.append(contentsOf: "\\n".unicodeScalars)
            case 0x0D: out.append(contentsOf: "\\r".unicodeScalars)
            case 0x09: out.append(contentsOf: "\\t".unicodeScalars)
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F:
                out.append(contentsOf: String(format: "\\x%02x", scalar.value).unicodeScalars)
            case 0x0085, 0x2028, 0x2029:
                out.append(contentsOf: String(format: "\\u%04x", scalar.value).unicodeScalars)
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: - Rules

    /// The redaction rules, most specific first. Ordering is load-bearing: credentials inside a URL must be
    /// removed before the generic hex rule turns a passkey into a plain hash token and loses the fact that
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
        // scrubber outright, and the scrubber sits on the path that writes the log. `scrub` bounds before it
        // redacts, which hides that cost, so the bound is proven directly against `redactAll` instead: see
        // the N16 case in VXProbeRedactionTests, which feeds an unbounded 200 KB line to `redactAll` under a
        // watchdog. No real scheme is longer than a handful of characters, so the bound costs nothing.
        if let r = compile(#"[a-z][a-z0-9+.\-]{0,15}://([^\s/@]+)@"#) { out.append(Rule(tag: "cred", regex: r, group: 1)) }
        // Authorization headers. `Authorization: Bearer <jwt>` had no rule at all, which is how the single
        // most standard way to spell a credential walked through a list of query-parameter names.
        if let r = compile(#"(?:proxy-)?authorization\s*[:=]\s*[a-z]+\s+([^\s"',;]+)"#) {
            out.append(Rule(tag: "auth", regex: r, group: 1))
        }
        if let r = compile(#"\bbearer\s+([a-z0-9._\-+/=]{8,})"#) { out.append(Rule(tag: "auth", regex: r, group: 1)) }
        // A JWT anywhere, header or not: three dot-separated base64url runs starting with the "eyJ" that a
        // JSON header always encodes to.
        if let r = compile(#"\beyj[a-z0-9._\-]{16,}"#) { out.append(Rule(tag: "jwt", regex: r, group: 0)) }
        // Credential-bearing query parameters, whatever the host and WHATEVER THE AFFIX. The previous rule
        // was a hand-written list of exact parameter names, so `auth_token` (Real-Debrid's actual spelling)
        // was not on it. Matching a credential word anywhere inside the parameter NAME closes the whole
        // family (`auth_token`, `x-api-key`, `session_id`, `dl_passkey`) instead of one member of it. The
        // name class excludes `=` and `&`, which keeps the match linear rather than backtracking.
        if let r = compile(#"[?&][^=&\s]{0,40}(?:api[_-]?key|apikey|access[_-]?token|token|passkey|password|passwd|secret|signature|sig|session|sid|auth|key)[^=&\s]{0,40}=([^&\s"']+)"#) {
            out.append(Rule(tag: "secret", regex: r, group: 1))
        }
        // Any long hex run: torrent infohashes (v1 is 40, v2 is 64), private-tracker passkeys, session ids
        // and API keys all share this shape. The previous rule matched EXACTLY 40 between word boundaries,
        // so a 41-hex run and a v2 infohash both passed untouched. A near-miss length has to DEGRADE, never
        // fail open, so the rule is a lower bound with no boundary anchors. It over-matches (a 32+ hex run
        // inside a longer word is redacted too) and that is the correct direction to be wrong in.
        if let r = compile(#"[0-9a-f]{32,}"#) { out.append(Rule(tag: "hex", regex: r, group: 0)) }
        // Catalog identities. These ARE viewing history: "tt0903747" plus an episode pair says what was
        // watched. The coordinates are deliberately left readable, because they carry the triage value
        // (which episode of SOMETHING) without the part that names the title.
        //
        // SIX digits, not seven, because our own producers accept six: `SourceIndexContract.canonicalContentID`
        // is `tt[0-9]{6,10}` and `CommunityTrickplay.ttPrefix` is `^tt\d{6,}`. A sink that is stricter than
        // its own producers is a sink with a documented hole in it. The leading `\b` is gone as well: it
        // required a non-word character before the id, so `id_tt0903747` survived intact.
        if let r = compile(#"tt[0-9]{6,}"#) { out.append(Rule(tag: "tt", regex: r, group: 0)) }
        // Typed catalog identities from every namespace this app speaks. The digit run is unbounded on
        // purpose: the previous `{1,10}` bound failed ENTIRELY on an 11-digit id rather than clipping it.
        if let r = compile(#"(?:tmdb|tvdb|kitsu|anidb|mal)[:_\-][0-9]+"#) { out.append(Rule(tag: "id", regex: r, group: 0)) }
        return out
    }()

    /// Apply every rule once, in order, with NO length bounding.
    ///
    /// Exposed separately from `scrub` because the bound and the redaction are two different properties and
    /// each needs to be provable on its own. In particular the bounded scheme quantifier above is invisible
    /// from `scrub` (which bounds first), so the only way to write a test that goes RED when that bound is
    /// removed is to drive the rules directly. Production always goes through `scrub` or `durableLine`.
    static func redactAll(_ text: String) -> String {
        var out = text
        for rule in rules { out = apply(rule, to: out) }
        return out
    }

    /// Normalise, bound, redact, then bound again.
    ///
    /// The order is deliberate and was learned the hard way. Redacting first means every regex runs over an
    /// attacker-chosen length, and this code runs on the path that writes the log: a pathological line must
    /// not be able to stall it. Bounding first makes the regex work fixed-cost no matter what was passed in.
    ///
    /// bound -> redact -> bound is NOT safe by ordering alone, which is the other thing that had to be
    /// learned: truncating mid-identifier used to leave a readable prefix (22 of 40 hex characters survived
    /// at one padding, which is plenty to search for). `bound` therefore cuts at a token boundary rather than
    /// at an arbitrary byte, so a value that straddles the cap is removed WHOLE instead of being halved.
    ///
    /// The second bound exists because redaction can lengthen a line: a short identifier becomes a longer
    /// placeholder, so a line just under the cap can cross it during replacement.
    static func scrub(_ raw: String) -> String {
        let normalized = neutralizeControls(fold(raw))
        var text = bound(normalized)
        text = redactAll(text)
        return bound(text)
    }

    /// Form ONE complete durable diagnostic line, terminated by exactly one newline.
    ///
    /// Every durable channel goes through this: `VXProbeFileLog.record` (vortx-diag.log and the NSLog
    /// mirror), `DiagnosticsLog.log`/`logSync` (diagnostics.log), and the export-time rewrite of retained
    /// bytes. All three fields are scrubbed, not just the message: an unguarded parameter means there is no
    /// chokepoint, and `DiagnosticsLog` is a free-form category caller. The COMPLETE line, newline included,
    /// is capped at `maxLineBytes`.
    static func durableLine(timestamp: String, category: String, message: String) -> String {
        let safeStamp = clampBytes(neutralizeControls(fold(timestamp)), maxTimestampBytes)
        let safeCategory = clampBytes(redactAll(neutralizeControls(fold(category))), maxCategoryBytes)
        let safeMessage = scrub(message)
        let line = boundTo("\(safeStamp) [\(safeCategory)] \(safeMessage)", budgetBytes: maxLineBytes - 1)
        return line + "\n"
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

    /// Characters no identifier shape in `rules` can contain, so a cut here cannot halve one.
    ///
    /// `<` is deliberately NOT in the set: a cut landing inside an emitted `<tag:abc123>` placeholder is
    /// harmless, and excluding it keeps the common case (cut at a space) unchanged.
    private static func isTokenBoundary(_ character: Character) -> Bool {
        if character.isWhitespace { return true }
        return ",;)]}\"'|>".contains(character)
    }

    /// Hard byte clamp with no marker, for the short fixed fields of a durable line.
    private static func clampBytes(_ text: String, _ budget: Int) -> String {
        guard text.utf8.count > budget else { return text }
        var out = ""
        var used = 0
        for character in text {
            let width = String(character).utf8.count
            if used + width > budget { break }
            out.append(character)
            used += width
        }
        return out
    }

    private static func bound(_ text: String) -> String { boundTo(text, budgetBytes: maxLineBytes) }

    /// Truncate on a UTF-8 byte budget without splitting a scalar AND without splitting an identifier, and
    /// say so in the line rather than silently dropping the tail.
    ///
    /// The cut retreats to the last token boundary that fits, so the surviving text ends where a value ends.
    /// A run with no boundary at all inside the budget (one 200 KB word) therefore truncates to nothing but
    /// the marker: dropping a hostile blob entirely is the right answer, and half of it is not.
    ///
    /// IDEMPOTENT: the marker is counted INSIDE the budget, so the result is always <= budget and a second
    /// pass over an already-bounded line is a no-op rather than a second marker stapled onto the first.
    private static func boundTo(_ text: String, budgetBytes: Int) -> String {
        guard text.utf8.count > budgetBytes else { return text }
        let budget = budgetBytes - truncationMarker.utf8.count
        var out = ""
        var used = 0
        var lastBoundary: String.Index?
        for character in text {
            let width = String(character).utf8.count
            if used + width > budget { break }
            out.append(character)
            used += width
            if isTokenBoundary(character) { lastBoundary = out.endIndex }
        }
        if let lastBoundary {
            out = String(out[out.startIndex..<lastBoundary])
        } else {
            out = ""
        }
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return out + truncationMarker
    }
}
