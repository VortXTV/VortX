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
//
// SCOPE: this asserts DESIGN PROPERTIES against faithful mirrors, NOT the shipped functions directly. A
// standalone script cannot link the Apple app target (CoreStream, SourcePreferences, and the SwiftUI stack
// come with it), so the real proof that the shipped StreamRanking / SourcePreferences code compiles and
// links is the 4-scheme Xcode build gate. This script guards the ranking MATH and the drop RULES (prefer/
// cache/tier ordering, Avoid hide-vs-rank, Only require, the HARD junk/Kids drops) against silent drift.

import Foundation

// MARK: - Re-implemented Lane A decision surface (mirror of StreamRanking + SourcePreferences)

/// Mirror of StreamRanking magnitudes that matter for Lane A ordering.
enum RankConst {
    static let preferBoost = 2500      // StreamRanking.chipScoreOffset prefer lift (sized to stay under the tier step)
    static let avoidSink = -20_000     // StreamRanking.chipScoreOffset avoid demotion in "rank" mode
    static let cacheBonus = 8000       // StreamRanking.computeScore cached-hit lift (+8000)
    static let tierStep = 15_000       // SourcePreferences tier-weight spacing (source-type = top-level key)
    static let maxQualitySpread = 4313 // EXACT max within-tier quality spread in computeScore: resolution 4000 + remux 230 + DV 45 + size 12 + Atmos 26
    static let seederTiebreakCap = 180 // StreamRanking.seederTiebreakCap max torrent swarm-health lift (<= 186 headroom)
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
    // Avoid / Hide: drops in "hide" mode; "rank" keeps it visible (demoted in the score) EXCEPT on a Kids
    // profile, where Avoid words are a parental hide tool and always drop (mirror of passesUserFilters'
    // `avoidRanks = avoidBehavior == "rank" && !kids`).
    let avoidHides = avoidBehavior == "hide" || kids
    if avoidHides, exclude.contains(where: { t.contains($0) }) { return false }
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

// MARK: - Parse-boundary clamp mirrors (mirror of StreamRanking.sizeGB / seederCount)

/// Full-match extractor standing in for StreamRanking.firstMatch for the size/seeder patterns (both of which
/// strip the unit off the FULL match rather than reading a capture group).
func mirrorFirstMatch(_ text: String, _ pattern: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = text as NSString
    guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return ns.substring(with: m.range)
}

/// Mirror of StreamRanking.sizeGB INCLUDING its parse-boundary clamp (min(parsed, 100_000)). Must stay in
/// lockstep with the shipped function: the clamp is what stops an unbounded Double from adversarial text
/// (e.g. "9999...9 GB" ~= 1e26) from trapping the `Int(...)` size-tiebreak conversion in computeScore.
func mirrorSizeGB(_ t: String) -> Double {
    guard let m = mirrorFirstMatch(t.lowercased(), #"(\d+(?:\.\d+)?)\s*g(i)?b"#) else { return 0 }
    let digits = m.replacingOccurrences(of: "gib", with: "").replacingOccurrences(of: "gb", with: "")
        .trimmingCharacters(in: .whitespaces)
    return min(Double(digits) ?? 0, 100_000)
}

/// Mirror of StreamRanking.seederCount INCLUDING its parse-boundary clamp (min(parsed, 1_000_000)). Must stay
/// in lockstep with the shipped function: the clamp is what stops a 19-digit-but-valid Int from trapping the
/// `seeders * 8` multiply in computeScore. nil is still returned above Int.max, exactly as shipped.
func mirrorSeederCount(_ text: String) -> Int? {
    let patterns = [#"👤[:\s]*([0-9]+)"#, #"(?<![a-z0-9])seed(er)?s?\s*:\s*([0-9]+)"#]
    for pattern in patterns {
        if let m = mirrorFirstMatch(text, pattern) {
            return Int(m.filter(\.isNumber)).map { min($0, 1_000_000) }
        }
    }
    return nil
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
    check(scoreB - scoreA == RankConst.preferBoost, "Prefer boost is exactly the tier-safe +2500 within the tier")
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

// 5. Anti-regression invariant: a preferred AND cached source can never cross its source-type tier step.
//    prefer + cache + the max within-tier quality spread must stay UNDER the 15000 tier-weight spacing, so
//    source-type order stays the top-level ranking key (StreamRanking.computeScore contract). This is the
//    property the Prefer-boost resize (8000 -> 2500) restored.
do {
    let worstCaseWithinTier = RankConst.preferBoost + RankConst.cacheBonus + RankConst.maxQualitySpread
    check(worstCaseWithinTier < RankConst.tierStep,
          "Prefer + cache + quality spread (\(worstCaseWithinTier)) stays under the 15000 tier step")
    // And the OLD +8000 prefer would have violated it (prefer + cache alone = 16000 > 15000), which is the
    // regression this guards against.
    check(8000 + RankConst.cacheBonus > RankConst.tierStep,
          "The pre-fix +8000 prefer boost DID cross the tier step (regression this test locks out)")
    // The torrent seeder tiebreak is ALSO a within-tier lift and stacks on top of prefer + cache + spread
    // for a cached raw torrent with a hot swarm. The FULL within-tier sum, seeder cap included, must still
    // stay under the tier step, or a preferred + cached + hot-swarm torrent could leapfrog the tier above it.
    let worstCaseWithSeeders = worstCaseWithinTier + RankConst.seederTiebreakCap
    check(worstCaseWithSeeders < RankConst.tierStep,
          "Prefer + cache + spread + seeder tiebreak (\(worstCaseWithSeeders)) stays under the 15000 tier step")
    // And the OLD +400 seeder cap DID push the full sum over (14800 + 400 = 15200 > 15000): the corner this fixes.
    check(worstCaseWithinTier + 400 > RankConst.tierStep,
          "The pre-fix +400 seeder cap DID cross the tier step in the cached-torrent corner (regression locked out)")
}

// 6. Kids profile: Avoid words are a parental hide tool, so they DROP even in "rank" mode (which keeps them
//    visible on a normal profile). Mirrors passesUserFilters' Kids-forces-hide guard.
do {
    let exclude = terms("hindi")
    let avoided = "Movie 2023 1080p WEB-DL Hindi"
    check(!passesFilters(text: avoided, include: [], exclude: exclude,
                         avoidBehavior: "rank", safetyOn: false, kids: true),
          "Kids profile hard-hides an Avoid word even in rank mode")
    check(passesFilters(text: avoided, include: [], exclude: exclude,
                        avoidBehavior: "rank", safetyOn: false, kids: false),
          "Non-Kids profile keeps the same Avoid word visible in rank mode")
}

// 7. Overflow safety (CEO-reported integer traps): absurd size / seeder figures from adversarial add-on text
//    must rank WITHOUT trapping and land in the SAME score bucket as their clamped-realistic equivalents.
do {
    // --- Size trap (computeScore line ~299: Int(min(sizeGB * 0.15, 12))) ---
    // Without the parse-boundary clamp, Double(digits) ~= 1e26 and Int(1e26 * 0.15) TRAPS (out of Int range).
    let absurdSize = "movie 2160p remux 99999999999999999999999999 gb"
    let realisticBig = "movie 2160p remux 90 gb"   // any real >80 GB release already pins the +12 ceiling
    check(Double("99999999999999999999999999")! > Double(Int.max),
          "the adversarial size really exceeds Int range (justifies the clamp)")
    check(mirrorSizeGB(absurdSize) == 100_000, "sizeGB clamps the adversarial figure to the 100k GB ceiling")
    let absurdSizeLift = Int(min(mirrorSizeGB(absurdSize) * 0.15, 12))   // the exact computeScore expression
    let realSizeLift = Int(min(mirrorSizeGB(realisticBig) * 0.15, 12))
    check(absurdSizeLift == 12, "absurd GB resolves into the +12 size-tiebreak ceiling (no trap)")
    check(absurdSizeLift == realSizeLift, "absurd GB lands in the same size bucket as a real >80 GB release")

    // --- Seeder trap (computeScore line ~350: min(seeders * 8, seederTiebreakCap)) ---
    // A 19-digit count UNDER Int.max parses to a valid huge Int; without the clamp `seeders * 8` TRAPS.
    let bigSeed = "1234567890123456789"   // 19 digits, < Int.max, but * 8 overflows
    let absurdSeedText = "movie 1080p webrip 👤 \(bigSeed)"
    let realisticSeedText = "movie 1080p webrip 👤 50000"   // any hot swarm (>= 23) already pins the cap
    check(Int(bigSeed)! < Int.max && Int(bigSeed)! > RankConst.seederTiebreakCap,
          "the 19-digit count is a valid Int whose * 8 would overflow (justifies the clamp)")
    check(mirrorSeederCount(absurdSeedText) == 1_000_000, "seederCount clamps the 19-digit count to the 1M ceiling")
    let absurdSeedLift = min(mirrorSeederCount(absurdSeedText)! * 8, RankConst.seederTiebreakCap)
    let realSeedLift = min(mirrorSeederCount(realisticSeedText)! * 8, RankConst.seederTiebreakCap)
    check(absurdSeedLift == RankConst.seederTiebreakCap, "absurd seeder count resolves into the capped tiebreak (no trap)")
    check(absurdSeedLift == realSeedLift, "absurd seeder count lands in the same tiebreak bucket as a hot real swarm")
}

// 8. Audio-language filter (#136): the `preferredAudioOnly` filter must drop a source ONLY when it POSITIVELY
//    advertises a single foreign audio language the viewer did not allow. A source that advertises an ALLOWED
//    language, states NO language, or is multi-language must always PASS. Mirror of StreamRanking.languageScore
//    (WITH the #136 langTokens-coverage guard) + the shipped `passesUserFilters` drop `languageScore(text) < 0`.
//    Keep in lockstep with StreamRanking.languageScore; the langTokens subset below is representative, not full.
do {
    // The 12 languages StreamRanking.langTokens can detect (keyed by ISO code; representative word tokens).
    let langTokens: [String: [String]] = [
        "en": ["english"], "es": ["spanish", "latino", "castellano"], "fr": ["french", "vostfr"],
        "de": ["german", "deutsch"], "it": ["italian"], "pt": ["portuguese", "dublado"],
        "hi": ["hindi"], "ja": ["japanese"], "ko": ["korean"], "zh": ["chinese", "mandarin"],
        "ar": ["arabic"], "ru": ["russian"],
    ]
    func claims(_ text: String, _ code: String) -> Bool {
        (langTokens[code] ?? []).contains { text.lowercased().contains($0) }
    }
    func isMulti(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.contains("multi") || t.contains("dual") { return true }
        return langTokens.keys.filter { claims(t, $0) }.count >= 2
    }
    // Mirror of the FIXED StreamRanking.languageScore (foreign demotion == -5000, with the #136 coverage guard).
    func languageScore(_ text: String, preferred: Set<String>) -> Int {
        guard !preferred.isEmpty else { return 0 }
        if preferred.contains(where: { claims(text, $0) }) { return 0 }   // advertises an allowed language
        if isMulti(text) { return 0 }                                     // multi/dual: viewer's track selectable
        guard preferred.contains(where: { langTokens[$0] != nil }) else { return 0 }   // #136: undetectable viewer language -> keep
        let foreign = langTokens.keys.filter { !preferred.contains($0) }
        return foreign.contains(where: { claims(text, $0) }) ? -5000 : 0
    }
    // The shipped filter drops only on a negative score.
    func audioHidden(_ text: String, preferred: Set<String>) -> Bool { languageScore(text, preferred: preferred) < 0 }

    // THE EXACT BUG: a stream that advertises an ALLOWED language must PASS.
    check(!audioHidden("Show S01E01 1080p WEB-DL English", preferred: ["en"]),
          "#136: an English source PASSES for an English-audio viewer")
    check(!audioHidden("Show S01E01 1080p WEB-DL Spanish", preferred: ["es"]),
          "#136: a Spanish source PASSES for a Spanish-audio viewer")
    // Unlabelled source: no language stated -> always kept.
    check(!audioHidden("Show S01E01 2160p REMUX HDR", preferred: ["en"]),
          "#136: an unlabelled source PASSES (no language advertised)")
    // Multi / dual release: the viewer's track is selectable -> kept.
    check(!audioHidden("Show S01E01 1080p Dual Audio Hindi English", preferred: ["en"]),
          "#136: a dual-audio release PASSES (multi-language)")
    // The regression the fix targets: an UNCOVERED viewer language (Turkish, not in langTokens) carried
    // alongside an English tag. The old code demoted it purely on the English tag, hiding a source that
    // advertised the allowed (Turkish) language. The coverage guard keeps it.
    check(!audioHidden("Show S01E01 1080p WEB-DL Turkish English", preferred: ["tr"]),
          "#136: a Turkish+English dual PASSES for a Turkish viewer (langTokens has no 'tr')")
    check(!audioHidden("Show S01E01 1080p WEB-DL English", preferred: ["nl"]),
          "#136: an uncovered-language viewer never has valid sources hidden by the audio filter")
    // The intended behavior is NOT broken: a single clearly-foreign release a COVERED viewer did not allow
    // is STILL demoted (dropped), so the filter keeps working for supported languages.
    check(audioHidden("Show S01E01 2160p WEB-DL Chinese", preferred: ["en"]),
          "#136: a Chinese-only source is still hidden for an English viewer (filter still works)")
}

if failures == 0 {
    print("PASS: all StreamRankingChips properties hold")
    exit(0)
} else {
    print("FAIL: \(failures) assertion(s) failed")
    exit(1)
}
