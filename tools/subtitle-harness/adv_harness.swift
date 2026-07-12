import Foundation

// Adversarial harness for the issue #76 subtitle-metadata leak (reviewer's escape-shape cases).
// Run: swift tools/subtitle-harness/adv_harness.swift
//
// NON-SHIPPING: no target in app/project.yml globs this directory (all target sources are explicit
// paths under app/). The functions below are REPLICAS of the shipped logic and MUST be kept in sync:
//   - leakedASSPrefixPatterns / leakedASSPrefixRange  -> app/Sources/Player/SubtitleCueRenderer.swift
//   - preTextCommaCount / plainTextFromASS            -> app/SourcesShared/SubtitleEmbeddedExtractor.swift
//
// The B1-B5 escape shapes (nonstandard-Format leak leftovers) are expected to MATCH and STRIP here:
// they are covered by the extended pattern list, always behind the per-file >=3-lines / >=20% vote.

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

func stripLine(_ line: String) -> String {
    guard let r = leakedASSPrefixRange(in: line) else { return line }
    return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
}

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

func plainTextFromASSNew(_ ass: String, preTextCommas: Int) -> String {
    let declared = max(1, preTextCommas)
    let rowCommas = ass.lazy.filter { $0 == "," }.count
    let splits = rowCommas >= declared
        ? declared
        : (rowCommas >= standardASSPreTextCommas ? standardASSPreTextCommas : declared)
    let parts = ass.split(separator: ",", maxSplits: splits, omittingEmptySubsequences: false)
    let textField = parts.count > splits ? String(parts[splits]) : ass
    return textField
}
// Shipped 5ad21bd behavior (0.3.11-0.3.13), for the equivalence checks:
func plainTextFromASSShipped(_ ass: String) -> String {
    let parts = ass.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
    return parts.count >= 9 ? String(parts[8]) : ass
}

var fails = 0
var checks = 0
func check(_ name: String, _ got: String, _ want: String) {
    checks += 1
    let ok = got == want
    if !ok { fails += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name): got=[\(got)] want=[\(want)]")
}
func checkMatch(_ name: String, _ line: String, _ wantMatch: Bool) {
    checks += 1
    let got = leakedASSPrefixRange(in: line) != nil
    let ok = got == wantMatch
    if !ok { fails += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name): match=\(got) want=\(wantMatch)  line=[\(line)]")
}
func checkInt(_ name: String, _ got: Int, _ want: Int) {
    checks += 1
    let ok = got == want
    if !ok { fails += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name): got=\(got) want=\(want)")
}

print("== P1/P2 stripper matches ==")
// Shape A: 0.3.9 raw-row fallback of a STANDARD row (the ground-truthed pool poison)
checkMatch("A1 standard raw row", "1,0,Default,,0,0,0,,Hello there", true)
check("A1 strip", stripLine("1,0,Default,,0,0,0,,Hello there"), "Hello there")
checkMatch("A2 styled row", "523,1,Sign,Actor,10,10,10,fx,Text with, commas", true)
check("A2 strip", stripLine("523,1,Sign,Actor,10,10,10,fx,Text with, commas"), "Text with, commas")
// Legit content that must NOT match
checkMatch("L1 spaced list", "1, 2, 3, 4, 5, 6, 7, 8, 9", false)
checkMatch("L2 money", "2,000!", false)
checkMatch("L3 score", "2,0", false)
checkMatch("L4 score sentence", "2,0,Arsenal are cruising", false)
checkMatch("L5 date csv", "In 1969,7,people walked", false)
// FP risk: unspaced numeric countdown (matches per-line, saved by the per-FILE vote in a healthy file)
checkMatch("FP1 unspaced countdown", "10,9,8,7,6,5,4,3,2,1", true)
check("FP1 strip residual", stripLine("10,9,8,7,6,5,4,3,2,1"), "2,1")
// Nonstandard-format pool poison shapes (the #76 escape class): now MATCH and STRIP (vote-gated)
checkMatch("B1 trimmed raw row (5 fields)", "7,0,0,0,,Hello there", true)
check("B1 strip", stripLine("7,0,0,0,,Hello there"), "Hello there")
checkMatch("B2 trimmed raw row (Style only)", "5,Default,Hello there", true)
check("B2 strip", stripLine("5,Default,Hello there"), "Hello there")
checkMatch("B3 missing-Name raw row (7 pre)", "12,0,Default,0,0,0,,Hello", true)
check("B3 strip", stripLine("12,0,Default,0,0,0,,Hello"), "Hello")
checkMatch("B4 partial-split leak comma", ",Hello there", true)
check("B4 strip", stripLine(",Hello there"), "Hello there")
checkMatch("B5 partial-split leak MarginB", "0,,Hello there", true)
check("B5 strip", stripLine("0,,Hello there"), "Hello there")
// P2 Dialogue rows
checkMatch("D1 Dialogue prefixed", "Dialogue: 0,0:00:01.00,0:00:03.20,Default,,0,0,0,,Hi", true)
check("D1 strip", stripLine("Dialogue: 0,0:00:01.00,0:00:03.20,Default,,0,0,0,,Hi"), "Hi")
checkMatch("D2 bare dialogue row", "0,0:00:01.00,0:00:03.20,Default,,0,0,0,,Hi", true)
checkMatch("D3 legit time in text", "At 0:01:02.5, we left", false)

print("== vote gate ==")
// gate replica: leaked >= 3 && leaked*5 >= total
func gate(_ leaked: Int, _ total: Int) -> Bool { leaked >= 3 && leaked * 5 >= total }
checkInt("G1 2 of 10 (no strip)", gate(2, 10) ? 1 : 0, 0)
checkInt("G2 3 of 15 (strip)", gate(3, 15) ? 1 : 0, 1)
checkInt("G3 3 of 16 (no strip)", gate(3, 16) ? 1 : 0, 0)
checkInt("G4 3 of 3 (strip)", gate(3, 3) ? 1 : 0, 1)
checkInt("G5 2 of 2 short poisoned file (no strip)", gate(2, 2) ? 1 : 0, 0)

print("== Format-line derivation ==")
let v4plus = "[Script Info]\nTitle: x\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
checkInt("F1 standard v4+", preTextCommaCount(inASSHeader: v4plus), 8)
let v4ssa = "[Script Info]\n\n[V4 Styles]\nFormat: Name, Fontname\n\n[Events]\nFormat: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
checkInt("F2 SSA v4 Marked", preTextCommaCount(inASSHeader: v4ssa), 8)
let v4pp = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, MarginB, Effect, Text\n"
checkInt("F3 v4++ MarginB", preTextCommaCount(inASSHeader: v4pp), 9)
let trimmed = "[Events]\nFormat: Start, End, Style, Text\n"
checkInt("F4 trimmed machine format", preTextCommaCount(inASSHeader: trimmed), 2)
let textNotLast = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Text, Effect\n"
checkInt("F5 Text not last -> fallback 8", preTextCommaCount(inASSHeader: textNotLast), 8)
let noEvents = "[Script Info]\nTitle: y\n"
checkInt("F6 no events -> 8", preTextCommaCount(inASSHeader: noEvents), 8)
let crlf = "[Events]\r\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n"
checkInt("F7 CRLF header", preTextCommaCount(inASSHeader: crlf), 8)
let noStart = "[Events]\nFormat: Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
checkInt("F8 missing Start/End -> 8", preTextCommaCount(inASSHeader: noStart), 8)
let stylesAfter = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, MarginB, Effect, Text\n[Fonts]\nFormat: bogus, text\n"
checkInt("F9 later section ignored", preTextCommaCount(inASSHeader: stylesAfter), 9)
let emptyField = "[Events]\nFormat: Layer, Start, End, Style,, Name, MarginL, MarginR, MarginV, Effect, Text\n"
checkInt("F10 empty field dropped by split (count 10-2)", preTextCommaCount(inASSHeader: emptyField), 8)

print("== split equivalence (declared 8 == shipped) ==")
let rows = [
    "1,0,Default,,0,0,0,,Hello there",
    "1,0,Default,,0,0,0,,Well, hello",
    "1,0,Default,,0,0,0,,",
    "no commas at all",
    "1,2,3",
]
for row in rows {
    check("EQ [\(row)]", plainTextFromASSNew(row, preTextCommas: 8), plainTextFromASSShipped(row))
}
// New path on v4++ row with 9 pre-text commas
check("NEW v4++ row split-9", plainTextFromASSNew("1,0,Default,,0,0,0,0,,Hello, friend", preTextCommas: 9), "Hello, friend")
// Trimmed format row with 2 pre-text commas
check("NEW trimmed row split-2", plainTextFromASSNew("5,Default,Hi, there", preTextCommas: 2), "Hi, there")
// Guard: header over-declares (9) over a standard comma-FREE row -> standard split, correct text
// (previously this dumped the raw row).
check("GUARD over-declared header, comma-free row", plainTextFromASSNew("1,0,Default,,0,0,0,,Hello", preTextCommas: 9), "Hello")
// Mismuxed: header says 9, rows are standard 8, text HAS a comma -> row has >= 9 commas, is
// indistinguishable from a true 9-field row, and eats the first text segment. Documented residual.
check("RISK mismuxed comma text eats first segment", plainTextFromASSNew("1,0,Default,,0,0,0,,Well, hello", preTextCommas: 9), " hello")

print(fails == 0 ? "ALL \(checks) CHECKS PASSED" : "\(fails) of \(checks) FAILED")
exit(fails == 0 ? 0 : 1)
