import Foundation

// End-to-end harness for the issue #76 subtitle fix: Format-driven event splitting (extractor) and the
// vote-gated leaked-metadata scrub (renderer), including real ground-truth lines pulled from the live
// pool for imdb:tt32278481 (origin "embedded", poisoned by the pre-0.3.11 split-on-9 raw fallback).
// Run: swift tools/subtitle-harness/cue_harness.swift
//
// NON-SHIPPING: no target in app/project.yml globs this directory. The functions below are REPLICAS of
// the shipped logic and MUST be kept in sync:
//   - SubtitleCue / leakedASSPrefixPatterns / stripLeakedASSMetadata -> app/Sources/Player/SubtitleCueRenderer.swift
//   - preTextCommaCount / plainTextFromASS                           -> app/SourcesShared/SubtitleEmbeddedExtractor.swift

// ---- replicas: SubtitleEmbeddedExtractor ----
let standardASSPreTextCommas = 8

func preTextCommaCount(inASSHeader header: String) -> Int {
    var inEvents = false
    for rawLine in header.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("[") {
            inEvents = line.lowercased().hasPrefix("[events]")
            continue
        }
        guard inEvents, line.lowercased().hasPrefix("format:") else { continue }
        let fields = line.dropFirst("format:".count)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard fields.count >= 3, fields.last == "text",
              fields.contains("start"), fields.contains("end") else { return standardASSPreTextCommas }
        return fields.count - 2
    }
    return standardASSPreTextCommas
}

func plainTextFromASS(_ ass: String, preTextCommas: Int) -> String {
    let declared = max(1, preTextCommas)
    let rowCommas = ass.lazy.filter { $0 == "," }.count
    let splits = rowCommas >= declared
        ? declared
        : (rowCommas >= standardASSPreTextCommas ? standardASSPreTextCommas : declared)
    let parts = ass.split(separator: ",", maxSplits: splits, omittingEmptySubsequences: false)
    let textField = parts.count > splits ? String(parts[splits]) : ass
    let noTags = textField.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
    return noTags
        .replacingOccurrences(of: "\\N", with: "\n")
        .replacingOccurrences(of: "\\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// ---- replicas: SubtitleCueRenderer ----
struct SubtitleCue { let start: Double; let end: Double; let text: String }

let leakedASSPrefixPatterns = [
    #"^(?:Dialogue:\s*)?\d+,\d+:\d{2}:\d{2}[.:]\d{1,3},\d+:\d{2}:\d{2}[.:]\d{1,3},[^,\n]*,[^,\n]*,\d+,\d+,\d+,[^,\n]*,"#,
    #"^\d+,\d+,[^,\n]*,[^,\n]*,\d+,\d+,\d+,[^,\n]*,"#,
    #"^\d+,\d+,[^,\n]*,\d+,\d+,\d+,[^,\n]*,"#,
    #"^\d+(?:,\d+){1,7},,"#,
    #"^\d+,[A-Za-z][A-Za-z0-9 _@-]*,"#,
    #"^\d+,,"#,
    #"^,"#,
]

func leakedASSPrefixRange(in line: String) -> Range<String.Index>? {
    for pattern in leakedASSPrefixPatterns {
        if let r = line.range(of: pattern, options: .regularExpression), r.lowerBound == line.startIndex {
            return r
        }
    }
    return nil
}

func stripLeakedASSMetadata(from cues: [SubtitleCue]) -> [SubtitleCue] {
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

// ---- checks ----
var failures = 0
var checks = 0
func check(_ name: String, _ got: String, _ want: String) {
    checks += 1
    if got == want { print("PASS \(name)") } else { failures += 1; print("FAIL \(name): got [\(got)] want [\(want)]") }
}
func checkInt(_ name: String, _ got: Int, _ want: Int) {
    checks += 1
    if got == want { print("PASS \(name)") } else { failures += 1; print("FAIL \(name): got \(got) want \(want)") }
}

// 1. Format-line derivation
let stdHeader = """
[Script Info]
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize
Style: Default,Arial,20

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
checkInt("standard v4+ header -> 8", preTextCommaCount(inASSHeader: stdHeader), 8)

let v4ppHeader = """
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, MarginB, Effect, Text
"""
checkInt("v4++ MarginB header -> 9", preTextCommaCount(inASSHeader: v4ppHeader), 9)

let ssaHeader = "[Events]\r\nFormat: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n"
checkInt("SSA v4 Marked header (CRLF) -> 8", preTextCommaCount(inASSHeader: ssaHeader), 8)

let trimmedHeader = """
[Events]
Format: Layer, Start, End, Style, Text
"""
checkInt("trimmed 5-field header -> 3", preTextCommaCount(inASSHeader: trimmedHeader), 3)

checkInt("no events section -> 8", preTextCommaCount(inASSHeader: "[Script Info]\nTitle: x\n"), 8)
checkInt("styles-format only -> 8", preTextCommaCount(inASSHeader: "[V4+ Styles]\nFormat: Name, Fontname\n"), 8)
checkInt("format without text-last -> 8", preTextCommaCount(inASSHeader: "[Events]\nFormat: Layer, Start, End, Text, Style\n"), 8)

// 2. Event-row splitting (incl. the comma-count guard)
check("standard row, comma in text",
      plainTextFromASS("12,0,Default,,0,0,0,,Hello, world", preTextCommas: 8), "Hello, world")
check("standard row, no comma in text",
      plainTextFromASS("0,0,Default,,0,0,0,,Hello", preTextCommas: 8), "Hello")
check("v4++ row (extra MarginB) split by 9",
      plainTextFromASS("0,0,Default,,0,0,0,0,,Hi there", preTextCommas: 9), "Hi there")
check("trimmed row split by 3",
      plainTextFromASS("7,0,Default,Look, a comma", preTextCommas: 3), "Look, a comma")
check("override tags + \\N",
      plainTextFromASS(#"3,0,Default,,0,0,0,,{\an8}Top\Nline"#, preTextCommas: 8), "Top\nline")
check("malformed row (fewer fields) -> raw",
      plainTextFromASS("garbage without enough commas", preTextCommas: 8), "garbage without enough commas")
check("guard: over-declared header, standard comma-free row -> standard split",
      plainTextFromASS("1,0,Default,,0,0,0,,Hello", preTextCommas: 9), "Hello")

// 3. Renderer scrub: standard poisoned shape
let poisoned = [
    SubtitleCue(start: 1, end: 2, text: "0,0,Default,,0,0,0,,Hello"),
    SubtitleCue(start: 3, end: 4, text: "1,0,Default,,0,0,0,,How are you"),
    SubtitleCue(start: 5, end: 6, text: "2,1,Default,,0,0,0,,I am fine"),
    SubtitleCue(start: 7, end: 8, text: "well, this one was truncated"),
]
let scrubbed = stripLeakedASSMetadata(from: poisoned)
check("poisoned file scrubbed line 1", scrubbed[0].text, "Hello")
check("poisoned file scrubbed line 2", scrubbed[1].text, "How are you")
check("poisoned file scrubbed line 3", scrubbed[2].text, "I am fine")
check("truncated line untouched", scrubbed[3].text, "well, this one was truncated")

let dialoguePoisoned = (0..<4).map {
    SubtitleCue(start: Double($0), end: Double($0) + 1, text: "Dialogue: 0,0:00:0\($0).00,0:00:0\($0).50,Default,,0,0,0,,Line \($0)")
}
let dialogueScrubbed = stripLeakedASSMetadata(from: dialoguePoisoned)
check("full Dialogue rows scrubbed", dialogueScrubbed[0].text, "Line 0")

// Escape-shape poisoned file (nonstandard-Format leftovers): strips under the vote
let escapePoisoned = [
    SubtitleCue(start: 1, end: 2, text: "7,0,0,0,,Hello there"),
    SubtitleCue(start: 3, end: 4, text: "5,Default,Nice to meet you"),
    SubtitleCue(start: 5, end: 6, text: "12,0,Default,0,0,0,,How do you do"),
    SubtitleCue(start: 7, end: 8, text: ",And you"),
    SubtitleCue(start: 9, end: 10, text: "0,,Very well"),
]
let escapeScrubbed = stripLeakedASSMetadata(from: escapePoisoned)
check("escape B1 trimmed raw row scrubbed", escapeScrubbed[0].text, "Hello there")
check("escape B2 style-only raw row scrubbed", escapeScrubbed[1].text, "Nice to meet you")
check("escape B3 missing-Name raw row scrubbed", escapeScrubbed[2].text, "How do you do")
check("escape B4 partial tail scrubbed", escapeScrubbed[3].text, "And you")
check("escape B5 MarginB tail scrubbed", escapeScrubbed[4].text, "Very well")

// Healthy file: one comma-run line must survive (the vote never passes)
let healthy = [
    SubtitleCue(start: 1, end: 2, text: "1,2,3,4,5,6,7,8, go!"),
    SubtitleCue(start: 3, end: 4, text: "Ordinary line."),
    SubtitleCue(start: 5, end: 6, text: "Another ordinary line."),
    SubtitleCue(start: 7, end: 8, text: "Plenty of normal dialog."),
    SubtitleCue(start: 9, end: 10, text: "More normal dialog."),
]
let healthyOut = stripLeakedASSMetadata(from: healthy)
check("healthy file: countdown line untouched", healthyOut[0].text, "1,2,3,4,5,6,7,8, go!")
checkInt("healthy file: cue count unchanged", healthyOut.count, 5)

let metadataOnly = [
    SubtitleCue(start: 1, end: 2, text: "0,0,Default,,0,0,0,,"),
    SubtitleCue(start: 3, end: 4, text: "1,0,Default,,0,0,0,,Real text"),
    SubtitleCue(start: 5, end: 6, text: "2,0,Default,,0,0,0,,More text"),
]
let metaOut = stripLeakedASSMetadata(from: metadataOnly)
checkInt("metadata-only cue dropped", metaOut.count, 2)
check("remaining cue clean", metaOut[0].text, "Real text")

// Enumeration/money lines must not match the prefix shapes per-line
checkInt("money/enumeration line does not match prefix",
         leakedASSPrefixRange(in: "1,000,000 dollars, John, 3,2,1, go!") == nil ? 1 : 0, 1)

// 4. GROUND TRUTH: verbatim cue-text lines from the live pool (imdb:tt32278481, origin "embedded",
// spa id 119 and eng id 80, fetched 2026-07-12). First lines carry the standard raw-row prefix;
// wrapped continuation lines carry none and must survive intact.
let groundTruth = [
    SubtitleCue(start: 6.75, end: 9.75, text: "0,0,Default,,0,0,0,,[música intrigante]"),
    SubtitleCue(start: 26.8, end: 29.8, text: "1,0,Default,,0,0,0,,[gemidos indistintos a lo lejos]"),
    SubtitleCue(start: 37.2, end: 40.2, text: "3,0,Default,,0,0,0,,[hombre] Debo empezar diciendo\nel honor que es poder conocerla."),
    SubtitleCue(start: 42.2, end: 45.2, text: "4,0,Default,,0,0,0,,He leído sobre sus juegos."),
]
let gtOut = stripLeakedASSMetadata(from: groundTruth)
check("ground truth: first pool line scrubbed", gtOut[0].text, "[música intrigante]")
check("ground truth: second pool line scrubbed", gtOut[1].text, "[gemidos indistintos a lo lejos]")
check("ground truth: wrapped cue keeps continuation line",
      gtOut[2].text, "[hombre] Debo empezar diciendo\nel honor que es poder conocerla.")
check("ground truth: fourth pool line scrubbed", gtOut[3].text, "He leído sobre sus juegos.")

print(failures == 0 ? "ALL \(checks) CHECKS PASSED" : "\(failures) of \(checks) FAILED")
exit(failures == 0 ? 0 : 1)
