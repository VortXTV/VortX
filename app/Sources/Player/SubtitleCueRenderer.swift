#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// One timed subtitle cue: the [start, end] window (media seconds) plus the already-cleaned display text.
struct SubtitleCue {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Parses SRT and WebVTT text into `[SubtitleCue]`, and (given an AVPlayer clock time and a manual delay)
/// picks the cue that should be on screen. This is how VortX renders EXTERNAL (add-on / community-pooled) srt/vtt
/// subtitles on the AVPlayer engine: AVFoundation has no API to side-load or time-shift an external SRT, so the
/// app owns parsing + drawing (the same approach Infuse / VLC / Stremio use over their players), and a sub-delay
/// is just an offset applied to the lookup time.
///
/// Threading: created + mutated on the main actor (the engine owns it). Pure value work otherwise; never crashes
/// on malformed input (bad lines are skipped, blank cues dropped).
@MainActor
final class SubtitleCueRenderer {
    /// Active cues, sorted by start. Empty when no external sub is loaded (the overlay then shows nothing).
    private(set) var cues: [SubtitleCue] = []
    /// Manual sync offset in seconds. Positive pushes subtitles LATER (matches libmpv `sub-delay`): a cue at
    /// media time T is shown when `clock - offset` is inside [start, end], i.e. it appears `offset` seconds later.
    var offset: TimeInterval = 0

    /// Resume cursor into `cues` for forward playback: the index of the earliest cue that could still be active.
    /// Because playback advances monotonically, a remembered cursor makes the lookup near-O(1) instead of walking
    /// the whole (start-sorted) array from 0 on every ~4 Hz tick. Reset to 0 on a backward jump (seek) and on
    /// any cue-set change. See `activeText`.
    private var searchHint = 0
    /// The last shifted lookup time, to detect a backward seek and reset the cursor.
    private var lastLookupTime: TimeInterval = -.infinity

    /// Replace the loaded cues (e.g. after parsing a freshly downloaded file). Resets the search cursor.
    func load(cues newCues: [SubtitleCue]) {
        cues = newCues.sorted { $0.start < $1.start }
        searchHint = 0
        lastLookupTime = -.infinity
    }

    /// Drop all cues (external sub turned off / player torn down).
    func clear() {
        cues = []
        searchHint = 0
        lastLookupTime = -.infinity
    }

    var hasCues: Bool { !cues.isEmpty }

    /// The cue text to display at AVPlayer clock time `clock`, or nil when none is active. Applies `offset`, then
    /// finds a cue whose [start, end] contains the shifted time; if two cues overlap, the first in start order wins.
    /// Uses a resume cursor so forward playback is near-O(1): the cursor only advances past cues that have fully
    /// ended (`end < t`), so the first non-skipped cue is still the earliest-start cue that hasn't ended (identical
    /// result to a full scan from 0). A backward jump resets the cursor before scanning.
    func activeText(atClock clock: TimeInterval) -> String? {
        guard !cues.isEmpty, clock.isFinite else { return nil }
        let t = clock - offset
        if t < lastLookupTime { searchHint = 0 }   // backward seek: the cursor may have overshot; restart
        lastLookupTime = t
        // Advance the cursor past cues that have fully ended; they can never match again on a forward tick.
        while searchHint < cues.count && cues[searchHint].end < t { searchHint += 1 }
        var i = searchHint
        while i < cues.count {
            let cue = cues[i]
            if t < cue.start { break }        // cues are sorted; nothing further can contain t
            if t <= cue.end { return cue.text }
            i += 1
        }
        return nil
    }

    // MARK: - Parsing

    /// Parse SRT or WebVTT bytes into cues. Format is detected from content (a leading `WEBVTT` header ⇒ VTT),
    /// but the timestamp grammar is unified so a mislabeled file still parses. Returns [] on undecodable data.
    static func parse(data: Data) -> [SubtitleCue] {
        guard let text = decodeText(data) else { return [] }
        return parse(text: text)
    }

    /// Parse subtitle TEXT (already decoded) into cues. Robust to CRLF/CR, BOM, WEBVTT headers, NOTE/STYLE/REGION
    /// blocks, numeric SRT indices, and cue identifiers; malformed blocks are skipped, never fatal.
    static func parse(text raw: String) -> [SubtitleCue] {
        // Normalize newlines and strip a leading BOM so line splitting is predictable across providers.
        var text = raw
        if text.first == "\u{FEFF}" { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        // ASS / SSA (Gap 5): an external add-on `.ass` subtitle used to fail to load entirely on the AVPlayer
        // lane (its grammar has no "-->" timing lines, so the SRT/VTT parser returned []). libmpv renders ASS
        // via libass; the VortX overlay is not libass, so parse the `[Events]` Dialogue lines into plain text
        // cues (override tags flattened). This is TEXT parity (the subtitle now shows), not full styled parity.
        let lower = text.lowercased()
        if lower.contains("[script info]") || (lower.contains("[events]") && lower.contains("dialogue:")) {
            let assCues = parseASS(text: text)
            if !assCues.isEmpty { return assCues }
        }

        var cues: [SubtitleCue] = []
        // Split into blocks on blank lines; each block is one cue (optionally with an index / id first line).
        let blocks = text.components(separatedBy: "\n\n")
        for rawBlock in blocks {
            var lines = rawBlock.components(separatedBy: "\n")
            // Drop the WEBVTT header and any VTT metadata block (NOTE / STYLE / REGION) wholesale.
            if let first = lines.first {
                let head = first.trimmingCharacters(in: .whitespaces).uppercased()
                if head.hasPrefix("WEBVTT") || head.hasPrefix("NOTE") || head.hasPrefix("STYLE") || head.hasPrefix("REGION") {
                    continue
                }
            }
            // Find the timing line ("start --> end"); everything after it is the cue body. A leading numeric
            // index (SRT) or cue identifier (VTT) sits before it and is ignored.
            guard let timingIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            guard let (start, end) = parseTiming(lines[timingIdx]) else { continue }
            let bodyLines = Array(lines[(timingIdx + 1)...])
            let cleaned = cleanText(bodyLines.joined(separator: "\n"))
            guard !cleaned.isEmpty, end > start else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: cleaned))
        }
        return stripLeakedASSMetadata(from: cues.sorted { $0.start < $1.start })
    }

    /// Parse ASS / SSA script text into cues (Gap 5). Reads the `[Events]` section: the `Format:` line names the
    /// field order (Start / End / Text indices, Text always last and may itself contain commas), and each
    /// `Dialogue:` line is one cue. Styling (`{\...}` override tags, `\N` line breaks) is FLATTENED to plain
    /// text, since the overlay is not libass. No `[Events]` / no valid Dialogue rows yields [] (the caller then
    /// falls through to the SRT/VTT parser). Robust to a missing Format line via the standard v4+ defaults.
    private static func parseASS(text: String) -> [SubtitleCue] {
        var startIdx = 1, endIdx = 2, textIdx = 9, fieldCount = 10   // ASS v4+ Dialogue defaults
        var inEvents = false
        var cues: [SubtitleCue] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {   // section header: [Events] enables Dialogue parsing, any other disables it
                inEvents = line.lowercased().hasPrefix("[events]")
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                let cols = line.dropFirst("format:".count)
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if let s = cols.firstIndex(of: "start") { startIdx = s }
                if let e = cols.firstIndex(of: "end") { endIdx = e }
                if let t = cols.firstIndex(of: "text") { textIdx = t }
                if cols.count > 1 { fieldCount = cols.count }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            let payload = String(line.dropFirst("dialogue:".count))
            // Split into at most `fieldCount` fields so the trailing Text field keeps its embedded commas.
            let fields = payload.split(separator: ",", maxSplits: max(fieldCount - 1, 0),
                                       omittingEmptySubsequences: false).map(String.init)
            guard fields.count > textIdx, fields.count > startIdx, fields.count > endIdx else { continue }
            guard let start = parseTimestamp(fields[startIdx]), let end = parseTimestamp(fields[endIdx]),
                  end > start else { continue }
            let cleaned = cleanASSText(fields[textIdx])
            guard !cleaned.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: cleaned))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Flatten one ASS Dialogue Text field to plain display text: convert `\N` / `\n` hard breaks to newlines
    /// and `\h` to a space, then reuse `cleanText` to strip `{\...}` override blocks, any inline tags, and HTML
    /// entities. (`parseTimestamp` already accepts the `H:MM:SS.cc` ASS time form.)
    private static func cleanASSText(_ input: String) -> String {
        var out = input
        out = out.replacingOccurrences(of: "\\N", with: "\n")
        out = out.replacingOccurrences(of: "\\n", with: "\n")
        out = out.replacingOccurrences(of: "\\h", with: " ")
        return cleanText(out)
    }

    // MARK: - Leaked ASS metadata repair (issue #76)

    /// Anchored shapes of raw ASS/SSA event METADATA opening a cue line. TWO leak families exist in the
    /// wild and both must strip:
    ///  - STANDARD rows dumped raw by the pre-0.3.11 extractor's split-on-9 fallback
    ///    (`ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,text`). This is the GROUND-TRUTHED
    ///    live pool poison: the embedded-origin entries for imdb:tt32278481 carry exactly
    ///    `N,0,Default,,0,0,0,,text` on ~65-85% of their cue lines (the rest are wrapped continuations).
    ///  - NONSTANDARD-Format leftovers of any fixed-count split (0.3.11-0.3.13 uploads): trimmed-format
    ///    raw rows (`7,0,0,0,,text`, `5,Default,text`), missing-field rows (`12,0,Default,0,0,0,,text`),
    ///    and partial-split tails (`0,,text`, `,text`).
    /// Ordered most-specific first so the longest metadata run is consumed. The tail shapes are
    /// individually loose, which is why matching is NEVER per-line alone: the per-file vote below has to
    /// pass before anything is stripped.
    private static let leakedASSPrefixPatterns = [
        // Full script Dialogue row (Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,): the two
        // H:MM:SS.cc timestamps make it unmistakable.
        #"^(?:Dialogue:\s*)?\d+,\d+:\d{2}:\d{2}[.:]\d{1,3},\d+:\d{2}:\d{2}[.:]\d{1,3},[^,\n]*,[^,\n]*,\d+,\d+,\d+,[^,\n]*,"#,
        // Standard FFmpeg event row (ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,): two
        // leading integers, two free fields, three integer margins, one free field, comma-terminated.
        #"^\d+,\d+,[^,\n]*,[^,\n]*,\d+,\d+,\d+,[^,\n]*,"#,
        // Missing-Name 7-field row (ReadOrder,Layer,Style,MarginL,MarginR,MarginV,Effect,).
        #"^\d+,\d+,[^,\n]*,\d+,\d+,\d+,[^,\n]*,"#,
        // Trimmed-format raw row: a leading run of 2-8 integers ending in an EMPTY field (`7,0,0,0,,`).
        #"^\d+(?:,\d+){1,7},,"#,
        // Trimmed ReadOrder,Style row (`5,Default,`): digits, then a style-ish token that starts with a
        // letter DIRECTLY after the comma, so prose like "5, Default, ..." never matches.
        #"^\d+,[A-Za-z][A-Za-z0-9 _@-]*,"#,
        // Partial-split tails of a wrong-count split (`0,,text` from a v4++ MarginB row, bare `,text`).
        #"^\d+,,"#,
        #"^,"#,
    ]

    /// The range of a leaked ASS metadata prefix at the start of `line`, or nil.
    private static func leakedASSPrefixRange(in line: String) -> Range<String.Index>? {
        for pattern in leakedASSPrefixPatterns {
            if let r = line.range(of: pattern, options: .regularExpression), r.lowerBound == line.startIndex {
                return r
            }
        }
        return nil
    }

    /// Strip raw ASS/SSA event fields that LEAKED into cue text (the issue #76 "0,0,0default…" prefixes):
    /// a subtitle converted from ASS with a wrong field count carries event metadata glued to the front
    /// of its lines. Community-pooled SRTs are the known live case (ground truth above: the pre-0.3.11
    /// extractor poisoned STANDARD rows, and nonstandard-Format files leak under any fixed-count split;
    /// the pool still serves both), and a provider-side bad conversion has the same shape. This is a
    /// per-FILE decision, not per-line: only when the leak shape opens at least 3 lines
    /// AND at least 20% of all lines is the file treated as corrupted and scrubbed, so a legitimate
    /// one-off comma-run line ("1,2,3,4,5,6,7,8!") in a healthy file is never touched. Runs inside
    /// `parse`, the single parser behind `addExternalSubtitle`, so the auto-selected and manually
    /// re-selected paths render identically. Fail-soft: only prefixes are removed; a cue left with no
    /// text is dropped (it carried nothing but metadata).
    private static func stripLeakedASSMetadata(from cues: [SubtitleCue]) -> [SubtitleCue] {
        guard !cues.isEmpty else { return cues }
        var totalLines = 0
        var leakedLines = 0
        for cue in cues {
            for line in cue.text.components(separatedBy: "\n") {
                totalLines += 1
                if leakedASSPrefixRange(in: line) != nil { leakedLines += 1 }
            }
        }
        guard leakedLines >= 3, leakedLines * 5 >= totalLines else { return cues }
        return cues.compactMap { cue in
            let cleanedLines = cue.text.components(separatedBy: "\n")
                .map { line -> String in
                    guard let r = leakedASSPrefixRange(in: line) else { return line }
                    return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                .filter { !$0.isEmpty }
            guard !cleanedLines.isEmpty else { return nil }
            return SubtitleCue(start: cue.start, end: cue.end, text: cleanedLines.joined(separator: "\n"))
        }
    }

    /// Parse a timing line "HH:MM:SS,mmm --> HH:MM:SS,mmm" (SRT) or "HH:MM:SS.mmm --> HH:MM:SS.mmm ..." (VTT,
    /// possibly with trailing cue settings like `line:90% align:middle` which are ignored). Hours are optional.
    private static func parseTiming(_ line: String) -> (TimeInterval, TimeInterval)? {
        guard let arrowRange = line.range(of: "-->") else { return nil }
        let lhs = String(line[..<arrowRange.lowerBound])
        // The end side may carry cue settings after a space; take the first token only.
        let rhsFull = String(line[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let rhs = rhsFull.split(separator: " ").first.map(String.init) ?? rhsFull
        guard let start = parseTimestamp(lhs), let end = parseTimestamp(rhs) else { return nil }
        return (start, end)
    }

    /// Parse one timestamp: `[HH:]MM:SS[,.]mmm`. Accepts both `,` (SRT) and `.` (VTT) as the millisecond
    /// separator, and 2- or 3-digit fractional parts. Returns nil on garbage.
    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // Separate the fractional part on the last ',' or '.'.
        var whole = s
        var millis = 0.0
        if let sepIdx = s.lastIndex(where: { $0 == "," || $0 == "." }) {
            whole = String(s[..<sepIdx])
            let frac = String(s[s.index(after: sepIdx)...])
            if let f = Double(frac), !frac.isEmpty {
                // "500" -> 0.5s, "50" -> 0.05s; scale by the digit count.
                millis = f / pow(10, Double(frac.count))
            }
        }
        let parts = whole.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let v = Double(part) else { return nil }
            seconds = seconds * 60 + v
        }
        return seconds + millis
    }

    /// Strip inline markup so the drawn text is clean: SRT/VTT tags (`<i>`, `<b>`, `<font ...>`, `<c.foo>`),
    /// ASS override blocks (`{\an8}`), and HTML entities. libmpv/libass would style these; our overlay renders
    /// plain text, so we remove the tags rather than half-render them. Leaves the line breaks intact.
    private static func cleanText(_ input: String) -> String {
        var out = input
        // Remove ASS/SSA override blocks: {\an8}, {\i1}, etc.
        out = out.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        // Remove any angle-bracket tag: <i>, </i>, <b>, <font color="...">, <c.yellow>, <00:00:01.000>, etc.
        out = out.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        // Decode the handful of entities that show up in subtitle text.
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, value) in entities { out = out.replacingOccurrences(of: entity, with: value) }
        // Trim trailing whitespace per line and collapse a fully-blank result to empty.
        let trimmedLines = out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return trimmedLines.joined(separator: "\n")
    }

    /// Decode subtitle bytes to a String. Tries UTF-8, then UTF-16, then Latin-1 (common for older SRT files),
    /// so a non-UTF-8 provider file still renders instead of failing silently.
    private static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return nil
    }
}

/// Downloads external subtitle bytes for the AVPlayer overlay path, reusing the SAME cache policy as the
/// libmpv subtitle loader: a shared URLSession with a small on-disk/in-memory URLCache, a 12s-style timeout, and
/// ONE retry on a failed/empty response. It returns the raw `Data` (the AVPlayer path parses cues in-process,
/// unlike libmpv which is handed a local file path). A `file://` URL (used by the community-pool path, which
/// already downloaded to disk) is read straight off disk with no network.
enum SubtitleFileFetcher {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 8 * 1024 * 1024, diskPath: "stremiox-subs-av")
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// Fetch the subtitle bytes for `url`, calling `done` on a background thread with the data (or nil on
    /// failure). `file://` URLs read from disk; http(s) URLs download with a timeout + one retry.
    static func fetch(_ url: URL, timeout: TimeInterval, done: @escaping (Data?) -> Void) {
        if url.isFileURL {
            done(try? Data(contentsOf: url))
            return
        }
        download(url, timeout: timeout, retriesLeft: 1, done: done)
    }

    private static func download(_ url: URL, timeout: TimeInterval, retriesLeft: Int, done: @escaping (Data?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .returnCacheDataElseLoad
        session.dataTask(with: request) { data, response, _ in
            // Only a genuine 2xx body is a subtitle; a non-HTTP response (nil cast) or an unexpected 3xx that
            // slips past URLSession's auto-redirect falls into the retry/nil path rather than being parsed.
            let statusOK = (response as? HTTPURLResponse).map { (200 ..< 300).contains($0.statusCode) } ?? false
            guard statusOK, let data, !data.isEmpty else {
                if retriesLeft > 0 {
                    download(url, timeout: timeout, retriesLeft: retriesLeft - 1, done: done)
                } else { done(nil) }
                return
            }
            done(data)
        }.resume()
    }
}

#if canImport(UIKit)
/// Bottom-centre subtitle overlay for the AVPlayer engine (iOS + tvOS). A plain, non-interactive `UILabel`
/// host that sits ABOVE the `AVPlayerLayer`; the engine's periodic time observer pushes the active cue text in.
/// Styling mirrors the app's `SubtitleStyle` (colour + a shaded/box/outline background) so external subs on
/// AVPlayer look like the libmpv ones. `isUserInteractionEnabled = false` keeps it out of the tvOS focus engine
/// and off touch handling.
final class SubtitleOverlayView: UIView {
    private let label = UILabel()
    /// Bottom constraint of the label. Its constant is the base inset PLUS the current letterbox bar height, so
    /// the cue tracks the bottom of the actual picture rather than the host view when the video is letterboxed
    /// (e.g. a 2.39:1 film in .resizeAspect on a 16:9 screen). Updated live via `setVideoBottomInset`.
    private var labelBottom: NSLayoutConstraint!
    /// The letterbox bar height (points) between the picture's bottom edge and the host view's bottom, for the
    /// current gravity. Zero when the video fills the height (fill/zoom/stretch, or an exact aspect match).
    private var letterboxBottom: CGFloat = 0
    /// Last text pushed into the label, so `setText` can skip the reassign (and its layout invalidation) on the
    /// ~99% of ~4 Hz ticks where the active cue is unchanged.
    private var lastText: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        label.numberOfLines = 0
        label.textAlignment = .center
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        labelBottom = label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            // Sit above the picture's bottom (base inset + letterbox bar) so it clears home indicators / safe
            // areas / TV overscan AND stays over the video, not down in a black bar.
            labelBottom,
        ])
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var bottomInset: CGFloat {
        #if os(tvOS)
        return 60
        #else
        return 44
        #endif
    }

    /// Set the height of the bottom letterbox bar (the gap from the video picture's lower edge to the host
    /// view's bottom) so the cue rides just above the picture. Called from the AVPlayerLayer host on layout /
    /// gravity change, computed from the layer's `videoRect`. Idempotent and cheap; no-op when unchanged.
    func setVideoBottomInset(_ inset: CGFloat) {
        let clamped = max(0, inset)
        guard abs(clamped - letterboxBottom) > 0.5 else { return }
        letterboxBottom = clamped
        labelBottom.constant = -(bottomInset + clamped)
    }

    /// Set (or clear) the displayed cue. Empty / nil hides the label. Called on the main actor.
    /// The overlay is refreshed ~4x/second while an external sub is active, but the cue text is unchanged on
    /// the vast majority of ticks (a cue spans many ticks); early-return on an unchanged value so we don't
    /// invalidate the label's intrinsic size / re-run auto-layout on every tick for no visual change.
    func setText(_ text: String?) {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value != lastText else { return }
        lastText = value
        label.text = value
        label.isHidden = value.isEmpty
    }

    /// Apply the current `SubtitleStyle` (size / colour / background). Re-called live when the user changes it.
    func applyStyle() {
        let classic = SubtitleStyle.fontId == "classic"
        let color = uiColor(fromHex: SubtitleStyle.colorHex) ?? .white
        label.textColor = color
        // Map mpv's px font sizes (tuned for a 720-ish subtitle canvas) into a reasonable on-screen point size.
        let scaled = CGFloat(SubtitleStyle.fontSize) * fontScale
        // Font choice (Gap 6): the picker's Modern/Classic used to be a dead control on the AVPlayer overlay
        // (always systemFont/.semibold). Mirror the libmpv distinction instead: Modern = a lighter weight with a
        // thin shadow outline (sub-border-size 2 + soft shadow); Classic = a heavier weight and a stronger
        // border-like shadow (sub-border-size 3). So the Font toggle visibly changes AVPlayer subtitles too.
        label.font = .systemFont(ofSize: scaled, weight: classic ? .bold : .semibold)
        switch SubtitleStyle.backgroundId {
        case "box":
            label.backgroundColor = UIColor.black
            setShadow(on: false, heavy: classic)
        case "shaded":
            label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            setShadow(on: false, heavy: classic)
        default:   // outline: transparent background, rely on a dark shadow for contrast
            label.backgroundColor = .clear
            setShadow(on: true, heavy: classic)
        }
    }

    private var fontScale: CGFloat {
        #if os(tvOS)
        return 0.6
        #else
        return 0.42
        #endif
    }

    private func setShadow(on: Bool, heavy: Bool = false) {
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = on ? 0.9 : 0
        label.layer.shadowRadius = on ? (heavy ? 4 : 3) : 0   // Classic carries a wider border-like shadow
        label.layer.shadowOffset = CGSize(width: 0, height: heavy ? 2 : 1)
        label.layer.masksToBounds = false
    }

    private func uiColor(fromHex hex: String) -> UIColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
#elseif canImport(AppKit)
/// macOS bottom-centre subtitle overlay for the AVPlayer engine. AppKit twin of the UIKit host above.
final class SubtitleOverlayView: NSView {
    private let label = NSTextField(labelWithString: "")
    /// Bottom constraint of the label; constant is the base inset plus the current letterbox bar height so the
    /// cue tracks the bottom of the picture, not the host view, when the video is letterboxed. See the UIKit twin.
    private var labelBottom: NSLayoutConstraint!
    private var letterboxBottom: CGFloat = 0
    /// Last text pushed into the label; lets `setText` skip the reassign (and its layout invalidation) on the
    /// ~99% of ~4 Hz ticks where the active cue is unchanged. See the UIKit twin.
    private var lastText: String?
    private static let baseInset: CGFloat = 44

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.alignment = .center
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        labelBottom = label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.baseInset)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            labelBottom,
        ])
        applyStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Set the bottom letterbox bar height so the cue rides just above the picture. Called from the AVPlayerLayer
    /// host on layout / gravity change, computed from the layer's `videoRect`. See the UIKit twin.
    func setVideoBottomInset(_ inset: CGFloat) {
        let clamped = max(0, inset)
        guard abs(clamped - letterboxBottom) > 0.5 else { return }
        letterboxBottom = clamped
        labelBottom.constant = -(Self.baseInset + clamped)
    }

    // The overlay never eats clicks (playback tap-to-toggle passes through to the video surface below).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setText(_ text: String?) {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value != lastText else { return }
        lastText = value
        label.stringValue = value
        label.isHidden = value.isEmpty
    }

    func applyStyle() {
        let classic = SubtitleStyle.fontId == "classic"
        let color = nsColor(fromHex: SubtitleStyle.colorHex) ?? .white
        label.textColor = color
        let scaled = CGFloat(SubtitleStyle.fontSize) * 0.42
        // Font choice (Gap 6): mirror the libmpv Modern/Classic distinction on the overlay (see the UIKit twin).
        label.font = .systemFont(ofSize: scaled, weight: classic ? .bold : .semibold)
        switch SubtitleStyle.backgroundId {
        case "box":
            label.drawsBackground = true
            label.backgroundColor = .black
            setShadow(on: false, heavy: classic)
        case "shaded":
            label.drawsBackground = true
            label.backgroundColor = NSColor.black.withAlphaComponent(0.5)
            setShadow(on: false, heavy: classic)
        default:
            label.drawsBackground = false
            setShadow(on: true, heavy: classic)
        }
    }

    private func setShadow(on: Bool, heavy: Bool = false) {
        if on {
            let shadow = NSShadow()
            shadow.shadowColor = .black
            shadow.shadowBlurRadius = heavy ? 4 : 3   // Classic carries a wider border-like shadow
            shadow.shadowOffset = NSSize(width: 0, height: heavy ? -2 : -1)
            label.shadow = shadow
        } else {
            label.shadow = nil
        }
    }

    private func nsColor(fromHex hex: String) -> NSColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return NSColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
#endif
#endif
