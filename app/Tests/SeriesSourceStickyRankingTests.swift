// SeriesSourceStickyRankingTests: a standalone, runnable verification of the sticky-source bonus and the
// provider-failure penalty added to StreamRanking for the diag-21 "I have to re-pick my source every episode"
// report, and of the ordering contract those two terms must not break.
//
// VortX's Apple app has no Xcode unit-test bundle (verification is build + on-device, per the repository guide),
// so, exactly like app/Tests/StreamRankingChipsTests.swift, this is a self-contained Swift executable that runs
// directly with the system toolchain:
//
//     swift app/Tests/SeriesSourceStickyRankingTests.swift
//
// SCOPE: this asserts DESIGN PROPERTIES against faithful mirrors, NOT the shipped functions directly. A
// standalone script cannot link the Apple app target (CoreStream, SourcePreferences and the SwiftUI stack come
// with it), so the real proof that the shipped code compiles and links is the 4-scheme Xcode build gate. The
// mirrors below MUST stay in lockstep with StreamRanking.stickyBonus / healthPenalty and the term lists inside
// best() and rankedCandidates(); if those drift, update this file so the properties are still asserted against
// the real design.
//
// The load-bearing invariant is the one the shipped doc comments state: best() and rankedCandidates() apply the
// SAME terms in the SAME order, so candidates.first is exactly the stream best() would have auto-picked. The
// player's invisible failover and the batch-download auto-retry both rely on it.

import Foundation

// MARK: - Mirrored magnitudes (mirror of StreamRanking)

enum StickyConst {
    static let stickyWeight = 6000     // StreamRanking.stickyWeight: the bonus, and negated, the penalty
    static let bingeBonus = 2500       // StreamRanking.bingeBonus exact-bingeGroup lift
    static let continuityMax = 1600    // StreamRanking.continuityBonus ceiling: 800 res + 500 remux + 300 HDR
    static let cacheBonus = 8000       // StreamRanking.computeScore cached-hit lift
    static let maxQualitySpread = 4313 // EXACT max within-tier quality spread in computeScore
    static let maxComputeScore = 14993 // EXACT computeScore ceiling within one tier (14813 + the 180 seeder cap)
    static let tierStep = 15_000       // SourcePreferences tier-weight spacing (source type = top-level key)
    static let pinBonus = 1_000_000    // StreamRanking.pinBonus: an explicit pin still dwarfs everything
    static let callerBonusCeiling = 8000  // StreamRanking.callerBonusCeiling: cap on continuity + binge + sticky
}

// MARK: - Mirrored decision surface

/// The only stream fields the two new terms read.
struct Stream {
    var id: String
    var bingeGroup: String?
}

/// A stream paired with its source group's add-on, the form StreamRanking.playablePairs produces.
struct Pair {
    var addon: String
    var stream: Stream
    /// The UNCLAMPED part of the score (computeScore + pin) this stream would carry, held as one number so the
    /// mirrors below exercise ONLY the terms under test and the ordering they participate in.
    var baseScore: Int
    /// The continuity bonus this stream would carry. Zero unless a scenario is exercising the clamp.
    var continuity: Int = 0
    /// The exact-bingeGroup bonus this stream would carry. Zero unless a scenario is exercising the clamp.
    var binge: Int = 0
}

/// Mirror of StreamRanking.stickyBonus: either signal earns the weight ONCE, add-on match is case-insensitive.
func stickyBonus(_ s: Stream, addon: String, sticky: (addon: String?, bingeGroup: String?)?) -> Int {
    guard let sticky else { return 0 }
    if let a = sticky.addon, !a.isEmpty, addon.caseInsensitiveCompare(a) == .orderedSame { return StickyConst.stickyWeight }
    if let g = sticky.bingeGroup, !g.isEmpty, s.bingeGroup == g { return StickyConst.stickyWeight }
    return 0
}

/// Mirror of StreamRanking.healthPenalty: a demotion of exactly the sticky weight, never an exclusion.
func healthPenalty(addon: String, isUnhealthy: ((String) -> Bool)?) -> Int {
    isUnhealthy?(addon) == true ? -StickyConst.stickyWeight : 0
}

/// Mirror of StreamRanking.callerBonuses: the SUM of the caller-applied POSITIVE bonuses, clamped. `pinBonus`
/// is outside it (it must dominate every tier) and so is `healthPenalty` (it is negative; clamping a sum that
/// included it would let the ceiling silently cancel a demotion).
func callerBonuses(_ p: Pair, sticky: (addon: String?, bingeGroup: String?)?) -> Int {
    let sum = p.continuity + p.binge + stickyBonus(p.stream, addon: p.addon, sticky: sticky)
    return min(sum, StickyConst.callerBonusCeiling)
}

func total(_ p: Pair, sticky: (addon: String?, bingeGroup: String?)?, penalty: ((String) -> Bool)?) -> Int {
    p.baseScore + callerBonuses(p, sticky: sticky)
        + healthPenalty(addon: p.addon, isUnhealthy: penalty)
}

/// Mirror of best()'s scoring branch: `max(by:)` keeps the FIRST maximal element, which is what makes it agree
/// with the stable sort below on ties.
func mirrorBest(_ pairs: [Pair], sticky: (addon: String?, bingeGroup: String?)? = nil,
                penalty: ((String) -> Bool)? = nil) -> Stream? {
    pairs.max { total($0, sticky: sticky, penalty: penalty) < total($1, sticky: sticky, penalty: penalty) }?.stream
}

/// Mirror of rankedCandidates()'s scoring branch: sorted by total, stable on ties via the original offset.
func mirrorRanked(_ pairs: [Pair], sticky: (addon: String?, bingeGroup: String?)? = nil,
                  penalty: ((String) -> Bool)? = nil) -> [Stream] {
    pairs.enumerated()
        .map { (offset: $0.offset, pair: $0.element, score: total($0.element, sticky: sticky, penalty: penalty)) }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
        .map { $0.pair.stream }
}

// MARK: - Tiny assertion harness

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
}

// MARK: - Sizing: where the sticky weight sits in the documented ladder

print("sticky weight sizing")
check(StickyConst.stickyWeight < StickyConst.tierStep,
      "sticky stays UNDER the source-type tier step (a remembered source never crosses the user's order)")
check(StickyConst.stickyWeight > StickyConst.maxQualitySpread,
      "sticky clears the max within-tier quality spread (a better-tagged rival cannot steal the pick)")
check(StickyConst.stickyWeight > StickyConst.bingeBonus && StickyConst.stickyWeight > StickyConst.continuityMax,
      "sticky outweighs the in-session binge and continuity hints it exists to replace")
check(StickyConst.stickyWeight < StickyConst.pinBonus,
      "an EXPLICIT pin still dwarfs the automatic sticky record")

// MARK: - The bonus itself

print("sticky bonus")
let comet = Pair(addon: "Comet", stream: Stream(id: "comet", bingeGroup: "comet|rd|1080"), baseScore: 0)
let torrentio = Pair(addon: "Torrentio", stream: Stream(id: "torrentio", bingeGroup: "torrentio|rd|1080"), baseScore: 0)

check(stickyBonus(torrentio.stream, addon: torrentio.addon, sticky: (addon: "Torrentio", bingeGroup: nil))
        == StickyConst.stickyWeight,
      "an add-on-name match earns the bonus (the cross-add-on case bingeGroup can never cover)")
check(stickyBonus(torrentio.stream, addon: torrentio.addon, sticky: (addon: "torrentio", bingeGroup: nil))
        == StickyConst.stickyWeight,
      "the add-on match is case-insensitive, like SourcePinStore.matches")
check(stickyBonus(torrentio.stream, addon: torrentio.addon, sticky: (addon: nil, bingeGroup: "torrentio|rd|1080"))
        == StickyConst.stickyWeight,
      "a bingeGroup match alone earns the bonus")
check(stickyBonus(torrentio.stream, addon: torrentio.addon,
                  sticky: (addon: "Torrentio", bingeGroup: "torrentio|rd|1080")) == StickyConst.stickyWeight,
      "both signals matching pays the bonus ONCE, not twice")
check(stickyBonus(comet.stream, addon: comet.addon, sticky: (addon: "Torrentio", bingeGroup: "torrentio|rd|1080")) == 0,
      "a different add-on with a different bingeGroup earns nothing")
check(stickyBonus(comet.stream, addon: comet.addon, sticky: (addon: "", bingeGroup: "")) == 0,
      "empty signals are not a wildcard match")
check(stickyBonus(comet.stream, addon: comet.addon, sticky: nil) == 0,
      "no record means no bonus (every existing caller ranks exactly as before)")

// MARK: - The penalty, and its mirror-image relationship to the bonus

print("provider penalty")
let unhealthy: (String) -> Bool = { $0 == "Debridio" }
check(healthPenalty(addon: "Debridio", isUnhealthy: unhealthy) == -StickyConst.stickyWeight,
      "a provider inside the failure window is demoted by exactly the sticky weight")
check(healthPenalty(addon: "Torrentio", isUnhealthy: unhealthy) == 0,
      "a healthy provider is untouched")
check(healthPenalty(addon: "Debridio", isUnhealthy: nil) == 0,
      "no penalty closure means no penalty (the default for every existing caller)")

let stalledAndRemembered = Pair(addon: "Debridio", stream: Stream(id: "debridio", bingeGroup: nil), baseScore: 20_000)
check(total(stalledAndRemembered, sticky: (addon: "Debridio", bingeGroup: nil), penalty: unhealthy)
        == stalledAndRemembered.baseScore,
      "a remembered source that JUST stalled nets zero and ranks on its own merit again")

// MARK: - The caller-bonus clamp: three positive hints must not stack across two tier steps

print("caller-bonus clamp")
check(StickyConst.continuityMax + StickyConst.bingeBonus + StickyConst.stickyWeight
        > StickyConst.callerBonusCeiling,
      "the three positive hints really can exceed the ceiling, so the clamp is not decorative")

let everyHint = Pair(addon: "Torrentio",
                     stream: Stream(id: "every-hint", bingeGroup: "torrentio|rd|1080"),
                     baseScore: 0,
                     continuity: StickyConst.continuityMax,
                     binge: StickyConst.bingeBonus)
check(callerBonuses(everyHint, sticky: (addon: "Torrentio", bingeGroup: "torrentio|rd|1080"))
        == StickyConst.callerBonusCeiling,
      "continuity + binge + sticky is clamped at the ceiling, not the unclamped 10100")
check(callerBonuses(everyHint, sticky: nil)
        == StickyConst.continuityMax + StickyConst.bingeBonus,
      "a sum under the ceiling is passed through untouched (existing callers rank exactly as before)")

// The whole point of the ceiling: bound how far ONE stream can be carried past the user's source-type order.
check(StickyConst.maxComputeScore + StickyConst.continuityMax + StickyConst.bingeBonus - StickyConst.tierStep
        == 4093,
      "the PRE-EXISTING continuity+binge overshoot is 4093, retained by design")
check(StickyConst.maxComputeScore + StickyConst.callerBonusCeiling - StickyConst.tierStep == 7993,
      "the clamped worst case overshoots by 7993, up from 4093 but still inside ONE tier step")
check(StickyConst.maxComputeScore + StickyConst.continuityMax + StickyConst.bingeBonus
        + StickyConst.stickyWeight - StickyConst.tierStep == 10093,
      "UNCLAMPED those same three hints overshoot by 10093, 2.5x the pre-existing 4093: what the clamp bounds")
check(StickyConst.maxComputeScore + StickyConst.callerBonusCeiling - StickyConst.tierStep
        < StickyConst.maxComputeScore + StickyConst.continuityMax + StickyConst.bingeBonus
            + StickyConst.stickyWeight - StickyConst.tierStep,
      "the clamp strictly reduces the worst-case overshoot rather than merely renaming it")
check(StickyConst.callerBonusCeiling >= StickyConst.continuityMax + StickyConst.bingeBonus,
      "the ceiling is at or above the PRE-EXISTING continuity+binge sum, so no existing ranking moves")

// The penalty is applied AFTER the clamp, never inside it, so a demotion cannot be swallowed by the ceiling.
check(total(everyHint, sticky: (addon: "Torrentio", bingeGroup: nil), penalty: { $0 == "Torrentio" })
        == StickyConst.callerBonusCeiling - StickyConst.stickyWeight,
      "a demoted provider loses the full sticky weight even when its bonuses were clamped")

// Both ranking entry points must clamp IDENTICALLY, or candidates.first stops being best()'s winner.
let clampedFavourite = everyHint
let unclampedRival = Pair(addon: "Comet", stream: Stream(id: "rival", bingeGroup: nil),
                          baseScore: StickyConst.callerBonusCeiling + 1)
check(mirrorBest([clampedFavourite, unclampedRival], sticky: (addon: "Torrentio", bingeGroup: nil))?.id
        == "rival",
      "a rival just past the CLAMPED total wins: best() honours the ceiling")
check(mirrorRanked([clampedFavourite, unclampedRival], sticky: (addon: "Torrentio", bingeGroup: nil)).first?.id
        == "rival",
      "rankedCandidates honours the same ceiling, so its head is still best()'s winner")

// MARK: - Neither term may ever become a filter (MIS-260731-03)

print("bonus and penalty are never filters")
let onlyPenalized = [Pair(addon: "Debridio", stream: Stream(id: "last-resort", bingeGroup: nil), baseScore: 20_000)]
check(mirrorBest(onlyPenalized, penalty: unhealthy)?.id == "last-resort",
      "a penalized provider still WINS when it is the only thing that answers")
check(mirrorRanked([comet, torrentio], sticky: (addon: "Torrentio", bingeGroup: nil)).count == 2,
      "a sticky record demotes nothing out of the list; every playable source stays visible")

// MARK: - The reported bug: the remembered source keeps the pick within its tier

print("diag-21 ordering")
// Same source-type tier. The rival is cached (+8000) and better tagged; the remembered add-on is neither.
// Cache is the one within-tier term deliberately sized ABOVE sticky, so it still wins - but a rival that is
// merely better TAGGED does not.
let rememberedPlain = Pair(addon: "Torrentio", stream: Stream(id: "remembered", bingeGroup: nil), baseScore: 30_000)
let rivalBetterTagged = Pair(addon: "Comet", stream: Stream(id: "rival", bingeGroup: nil),
                             baseScore: 30_000 + StickyConst.maxQualitySpread)
check(mirrorBest([rivalBetterTagged, rememberedPlain], sticky: (addon: "Torrentio", bingeGroup: nil))?.id == "remembered",
      "the remembered add-on holds the pick against a better-tagged rival in the same tier")

let rivalHigherTier = Pair(addon: "Comet", stream: Stream(id: "higher-tier", bingeGroup: nil),
                           baseScore: 30_000 + StickyConst.tierStep)
check(mirrorBest([rivalHigherTier, rememberedPlain], sticky: (addon: "Torrentio", bingeGroup: nil))?.id == "higher-tier",
      "the remembered add-on can NEVER cross the user's explicit source-type order")

let stalledFast = Pair(addon: "Debridio", stream: Stream(id: "stalled", bingeGroup: nil), baseScore: 30_000 + 100)
let slowerHealthy = Pair(addon: "Torrentio", stream: Stream(id: "healthy", bingeGroup: nil), baseScore: 30_000)
check(mirrorBest([stalledFast, slowerHealthy], penalty: unhealthy)?.id == "healthy",
      "diag-21: the provider that just true-stalled no longer wins the next episode on a hair")

// MARK: - THE contract: best() and rankedCandidates() must rank identically

print("best == rankedCandidates.first")
let scenarios: [(name: String, pairs: [Pair], sticky: (addon: String?, bingeGroup: String?)?, penalty: ((String) -> Bool)?)] = [
    ("no sticky, no penalty", [comet, torrentio, rememberedPlain], nil, nil),
    ("sticky only", [rivalBetterTagged, rememberedPlain, comet], (addon: "Torrentio", bingeGroup: nil), nil),
    ("bingeGroup sticky only", [comet, torrentio], (addon: nil, bingeGroup: "comet|rd|1080"), nil),
    ("penalty only", [stalledFast, slowerHealthy], nil, unhealthy),
    ("sticky and penalty together", [stalledAndRemembered, slowerHealthy, rivalBetterTagged],
     (addon: "Debridio", bingeGroup: nil), unhealthy),
    ("clamped hints vs an unclamped rival", [clampedFavourite, unclampedRival],
     (addon: "Torrentio", bingeGroup: nil), nil),
    ("clamped hints, and the clamped source is also demoted", [clampedFavourite, unclampedRival, slowerHealthy],
     (addon: "Torrentio", bingeGroup: nil), { $0 == "Torrentio" }),
    // Exact ties are where the two implementations could silently disagree: max(by:) keeps the first maximal
    // element and the sort is stable on the original offset, so both must land on the EARLIER source.
    ("exact tie falls to the earlier source",
     [Pair(addon: "A", stream: Stream(id: "first", bingeGroup: nil), baseScore: 1000),
      Pair(addon: "B", stream: Stream(id: "second", bingeGroup: nil), baseScore: 1000)], nil, nil),
    ("tie created BY the sticky bonus",
     [Pair(addon: "A", stream: Stream(id: "first", bingeGroup: nil), baseScore: 1000 + StickyConst.stickyWeight),
      Pair(addon: "B", stream: Stream(id: "second", bingeGroup: nil), baseScore: 1000)],
     (addon: "B", bingeGroup: nil), nil),
]
for scenario in scenarios {
    let winner = mirrorBest(scenario.pairs, sticky: scenario.sticky, penalty: scenario.penalty)?.id
    let head = mirrorRanked(scenario.pairs, sticky: scenario.sticky, penalty: scenario.penalty).first?.id
    check(winner != nil && winner == head,
          "\(scenario.name): candidates.first is exactly best()'s winner")
}

if failures == 0 {
    print("PASS: all SeriesSourceSticky ranking properties hold")
    exit(0)
} else {
    print("FAIL: \(failures) assertion(s) failed")
    exit(1)
}
