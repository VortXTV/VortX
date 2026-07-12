// StreamRankingChipsTests: a standalone, runnable verification of the Smart Source Selection (Lane A)
// ranking rules: the Prefer boost, the Avoid "hide" vs "rank" behavior, the Only (Require) hard require, and
// the HARD junk / Kids drops that no chip may override.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per CLAUDE.md), so,
// exactly like app/Tests/HouseholdCryptoTests.swift, this is a self-contained Swift executable that runs
// directly with the system toolchain:
//
//     swift app/Tests/StreamRankingChipsTests.swift
//
// It re-implements ONLY the small Lane A decision surface (the exact offsets and the drop rules), not the
// whole scorer, so it stays focused and cheap. These re-implementations MUST stay in lockstep with
// StreamRanking.swift (chipScoreOffset / passesUserFilters) and SourcePreferences.swift; if the offsets or
// the hard-drop rules there drift, update the constants below so the properties are still asserted against
// the real design.

import Foundation

// MARK: - Re-implemented Lane A decision surface (mirror of StreamRanking + SourcePreferences)

/// Mirror of StreamRanking magnitudes that matter for Lane A ordering.
enum RankConst {
    static let preferBoost = 8000      // StreamRanking.chipScoreOffset prefer lift
    static let avoidSink = -20_000     // StreamRanking.chipScoreOffset avoid demotion in "rank" mode
    static let junkFloor = -100_000    // StreamRanking.computeScore junkClass drop
    // A tiny stand-in "quality spread" so we can assert an avoided source stays ABOVE the junk floor
    // (visible, just demoted) rather than being pushed into junk territory.
    static let sampleQuality = 4000
}

/// Faithful-but-minimal junkClass: the HARD CAM/TS class that Safety hides regardless of any chip. Mirrors
/// the unambiguous long forms + the bare-token forms guarded by "no good source marker" in StreamRanking.
func junkClass(_ text: String) -> String? {
    let t = text.lowercased()
    if t.contains("hdcam") || t.contains("camrip") { return "CAM" }
    if t.contains("hdts") || t.contains("telesync") { return "TS" }
    let hasGoodSource = t.contains("remux") || t.contains("bluray") || t.contains("web-dl")
        || t.contains("webrip") || t.contains("hdtv")
    if !hasGoodSource {
        if boundedToken(t, "cam") { return "CAM" }
        if boundedToken(t, "ts") { return "TS" }
    }
    return nil
}

/// A crude delimiter-bounded token check, standing in for StreamRanking.boundedMatch for the test tokens.
func boundedToken(_ text: String, _ token: String) -> Bool {
    let padded = " " + text.replacingOccurrences(of: ".", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ") + " "
    return padded.contains(" \(token) ")
}

/// Comma-separated, lowercased, non-empty terms (mirror of SourcePreferences.terms).
func terms(_ csv: String) -> [String] {
    csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
}

/// Mirror of StreamRanking.passesUserFilters for the Lane A surface: the Only (Require) hard require in both
/// modes, the Avoid (Hide) drop ONLY in "hide" mode, the HARD junk drop under Safety, and the HARD Kids drop.
/// Returns true when the source survives (is shown).
func passesFilters(text: String, include: [String], exclude: [String],
                   avoidBehavior: String, safetyOn: Bool, kids: Bool) -> Bool {
    let t = text.lowercased()
    // Kids: always hide CAM/TS junk regardless of any user setting.
    if kids, junkClass(t) != nil { return false }
    // Only / Require: hard require in BOTH avoid modes.
    if !include.isEmpty, !include.contains(where: { t.contains($0) }) { return false }
    // Avoid / Hide: drops only in "hide" mode; "rank" keeps it visible (demoted in the score).
    if avoidBehavior == "hide", exclude.contains(where: { t.contains($0) }) { return false }
    // Safety filter: CAM/TS junk hidden in BOTH modes, whatever the user filters say.
    if safetyOn, junkClass(t) != nil { return false }
    return true
}

/// Mirror of StreamRanking.chipScoreOffset: prefer boost + (in "rank" mode) avoid demotion.
func chipOffset(text: String, prefer: [String], exclude: [String], avoidBehavior: String) -> Int {
    let t = text.lowercased()
    var offset = 0
    if !prefer.isEmpty, prefer.contains(where: { t.contains($0) }) { offset += RankConst.preferBoost }
    if avoidBehavior == "rank", exclude.contains(where: { t.contains($0) }) { offset += RankConst.avoidSink }
    return offset
}

// MARK: - Tiny assertion harness

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
}

// MARK: - Tests

print("StreamRankingChipsTests")

// 1. Prefer boost reorders: two equal-quality sources; the one matching a Prefer term outscores the other.
do {
    let prefer = terms("remux")
    let a = "Movie 2023 1080p WEB-DL"           // no prefer match
    let b = "Movie 2023 1080p REMUX"            // prefer match
    let scoreA = RankConst.sampleQuality + chipOffset(text: a, prefer: prefer, exclude: [], avoidBehavior: "hide")
    let scoreB = RankConst.sampleQuality + chipOffset(text: b, prefer: prefer, exclude: [], avoidBehavior: "hide")
    check(scoreB > scoreA, "Prefer boost lifts the matching source above an equal-quality peer")
    check(scoreB - scoreA == RankConst.preferBoost, "Prefer boost is exactly +8000 within the tier")
}

// 2. Avoid=rank sinks but keeps VISIBLE: a matching source is not dropped, its score sinks below the peer,
//    and it stays ABOVE the junk floor (still selectable, just last).
do {
    let exclude = terms("hindi")
    let avoided = "Movie 2023 1080p WEB-DL Hindi"
    let clean = "Movie 2023 1080p WEB-DL"
    let shown = passesFilters(text: avoided, include: [], exclude: exclude,
                              avoidBehavior: "rank", safetyOn: false, kids: false)
    check(shown, "Avoid=rank keeps the avoided source VISIBLE (not filtered out)")
    let scoreAvoided = RankConst.sampleQuality + chipOffset(text: avoided, prefer: [], exclude: exclude, avoidBehavior: "rank")
    let scoreClean = RankConst.sampleQuality + chipOffset(text: clean, prefer: [], exclude: exclude, avoidBehavior: "rank")
    check(scoreAvoided < scoreClean, "Avoid=rank sinks the avoided source below a clean peer")
    check(scoreAvoided > RankConst.junkFloor, "Avoid=rank stays above the junk floor (still visible/selectable)")
}

// 2b. Avoid=hide reproduces today's exact behavior: the matching source is DROPPED.
do {
    let exclude = terms("hindi")
    let avoided = "Movie 2023 1080p WEB-DL Hindi"
    let shown = passesFilters(text: avoided, include: [], exclude: exclude,
                              avoidBehavior: "hide", safetyOn: false, kids: false)
    check(!shown, "Avoid=hide drops the avoided source (today's default behavior)")
}

// 3. Only (Require) hides anything lacking the required term, in BOTH avoid modes.
do {
    let include = terms("remux")
    let hasIt = "Movie 2023 2160p REMUX"
    let lacksIt = "Movie 2023 1080p WEB-DL"
    for mode in ["hide", "rank"] {
        check(passesFilters(text: hasIt, include: include, exclude: [], avoidBehavior: mode, safetyOn: false, kids: false),
              "Only keeps a source that has the required term (\(mode) mode)")
        check(!passesFilters(text: lacksIt, include: include, exclude: [], avoidBehavior: mode, safetyOn: false, kids: false),
              "Only hides a source missing the required term (\(mode) mode)")
    }
}

// 4. CAM/TS are HARD-hidden by Safety in BOTH avoid modes, and on a Kids profile regardless of settings.
do {
    let cam = "Movie 2023 HDCAM x264"
    let ts = "Movie 2023 HDTS"
    for mode in ["hide", "rank"] {
        check(!passesFilters(text: cam, include: [], exclude: [], avoidBehavior: mode, safetyOn: true, kids: false),
              "CAM hard-hidden by Safety (\(mode) mode)")
        check(!passesFilters(text: ts, include: [], exclude: [], avoidBehavior: mode, safetyOn: true, kids: false),
              "TS hard-hidden by Safety (\(mode) mode)")
    }
    // Kids profile: hidden even with Safety off and no user filters, in both modes.
    for mode in ["hide", "rank"] {
        check(!passesFilters(text: cam, include: [], exclude: [], avoidBehavior: mode, safetyOn: false, kids: true),
              "CAM hard-hidden on a Kids profile (\(mode) mode, Safety off)")
    }
    // A legitimate source is NOT caught by the junk/Kids guard.
    check(passesFilters(text: "Movie 2023 1080p BluRay REMUX", include: [], exclude: [],
                        avoidBehavior: "rank", safetyOn: true, kids: true),
          "A clean BluRay Remux survives Safety + Kids guards")
}

if failures == 0 {
    print("PASS: all StreamRankingChips properties hold")
    exit(0)
} else {
    print("FAIL: \(failures) assertion(s) failed")
    exit(1)
}
