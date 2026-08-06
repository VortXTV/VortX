// Executable harness for the #148 memory-warning cache-shed decision.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/cache-shed-policy-test \
//     app/Sources/Player/CacheShedPolicy.swift \
//     app/Sources/Player/TVOSProactiveMemoryPressurePolicy.swift \
//     app/Tests/CacheShedPolicyTests.swift && /tmp/cache-shed-policy-test
//
// This suite CALLS the production decision (the DVPlaybackContractTests pattern). The property under test is the
// #148 field report "caches then stops caching ~40s in": the first memory warning must leave a USEFUL cache
// budget (half, not the 48 MiB floor), later warnings must land exactly where the old handler always ended (the
// floor), and the parser feeding the ladder must read both cap spellings the controller actually writes.
//
// The recovery section adds the other direction (FAIL-260804-04, a shed cap that stayed at the floor for the
// remaining 66 minutes of a film): the way back UP must be gated on headroom well clear of the clamp threshold,
// held for a sustained run of samples, must climb one rung at a time, and must never pass the per-file baseline.

import Foundation

@MainActor var failures = 0
@MainActor func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

@MainActor @main
enum CacheShedPolicyTests {
    static func main() { run() }
}

@MainActor func run() {

typealias P = VortXCacheShedPolicy
let mib = 1 << 20

// MARK: - The #148 property: the first warning keeps caching alive

check("floor is the historical 48 MiB", P.floorBytes == 48 * mib)
check("first warning halves the 768 MiB streaming-cache budget",
      P.forwardCapAfterWarning(currentBytes: 768 * mib, previouslyShed: false) == 384 * mib)
check("first warning halves the 256 MiB remote base budget",
      P.forwardCapAfterWarning(currentBytes: 256 * mib, previouslyShed: false) == 128 * mib)
check("first warning on a 96 MiB local budget floors (half would dip below the floor)",
      P.forwardCapAfterWarning(currentBytes: 96 * mib, previouslyShed: false) == P.floorBytes)

// MARK: - Later warnings terminate exactly where the old slam-to-floor handler did

check("second warning floors regardless of remaining budget",
      P.forwardCapAfterWarning(currentBytes: 384 * mib, previouslyShed: true) == P.floorBytes)
check("warning at the floor stays at the floor (idempotent terminal state)",
      P.forwardCapAfterWarning(currentBytes: P.floorBytes, previouslyShed: true) == P.floorBytes)

// MARK: - The ladder can never mint a cap below the floor or above the current budget

for budget in [64 * mib, 128 * mib, 256 * mib, 512 * mib, 768 * mib, 1024 * mib] {
    let first = P.forwardCapAfterWarning(currentBytes: budget, previouslyShed: false)
    check("budget \(budget >> 20)MiB: first-warning cap is within [floor, budget]",
          first >= P.floorBytes && first <= max(budget, P.floorBytes))
    check("budget \(budget >> 20)MiB: repeat warnings converge to the floor",
          P.forwardCapAfterWarning(currentBytes: first, previouslyShed: true) == P.floorBytes)
}

// MARK: - Cap-string parsing (the two spellings loadFile actually writes)

check("parses the MiB-suffixed static tier spelling", P.capBytes("256MiB") == 256 * mib)
check("parses the plain-bytes streaming-cache spelling", P.capBytes("268435456") == 256 * mib)
check("rejects zero", P.capBytes("0") == nil && P.capBytes("0MiB") == nil)
check("rejects negatives", P.capBytes("-1") == nil && P.capBytes("-4MiB") == nil)
check("rejects other suffixes rather than misreading them",
      P.capBytes("48KiB") == nil && P.capBytes("1GiB") == nil && P.capBytes("") == nil)

// MARK: - Proactive tvOS dirty-memory headroom policy

typealias Proactive = TVOSProactiveMemoryPressurePolicy
let twoGiB = UInt64(2) << 30
let threshold = Proactive.pressureThresholdBytes(physicalMemoryBytes: twoGiB)

check("proactive threshold has a 192 MiB minimum",
      Proactive.pressureThresholdBytes(physicalMemoryBytes: UInt64(1) << 30) == UInt64(192 * mib))
check("proactive threshold scales at one eighth of physical memory",
      threshold == UInt64(256 * mib))
check("proactive threshold has a 384 MiB maximum",
      Proactive.pressureThresholdBytes(physicalMemoryBytes: UInt64(4) << 30) == UInt64(384 * mib))

func proactiveTarget(
    available: UInt64,
    current: Int,
    alreadyClamped: Bool = false
) -> Int? {
    Proactive.clampTargetBytes(
        availableMemoryBytes: available,
        physicalMemoryBytes: twoGiB,
        currentCapBytes: current,
        floorBytes: P.floorBytes,
        alreadyClamped: alreadyClamped
    )
}

check("exact proactive threshold does not clamp",
      proactiveTarget(available: threshold, current: 256 * mib) == nil)
check("one byte below proactive threshold clamps",
      proactiveTarget(available: threshold - 1, current: 256 * mib) == 128 * mib)
check("zero available memory clamps because the dirty-memory allowance is exhausted",
      proactiveTarget(available: 0, current: 256 * mib) == 128 * mib)
check("recovered high headroom does not request a cache mutation",
      proactiveTarget(available: threshold + 1, current: 128 * mib) == nil)
check("proactive clamp halves 256 MiB to 128 MiB",
      proactiveTarget(available: threshold - 1, current: 256 * mib) == 128 * mib)
check("proactive clamp halves 128 MiB to 64 MiB",
      proactiveTarget(available: threshold - 1, current: 128 * mib) == 64 * mib)
check("proactive clamp floors 96 MiB at 48 MiB",
      proactiveTarget(available: threshold - 1, current: 96 * mib) == 48 * mib)
check("proactive clamp at the floor is a no-op",
      proactiveTarget(available: threshold - 1, current: P.floorBytes) == nil)
check("already-clamped proactive state is idempotent",
      proactiveTarget(available: 0, current: 128 * mib, alreadyClamped: true) == nil)

for budget in [64 * mib, 96 * mib, 128 * mib, 256 * mib, 512 * mib] {
    let target = proactiveTarget(available: 0, current: budget)
    let isWithinBounds = target.map { $0 >= P.floorBytes && $0 < budget }
        ?? (budget <= P.floorBytes)
    check("proactive target for \(budget >> 20)MiB stays within [floor, current)",
          isWithinBounds)
}

// MARK: - Hysteresis-gated recovery (FAIL-260804-04: a shed cap never came back)

func proactiveRestore(
    available: UInt64,
    current: Int,
    baseline: Int,
    samples: Int = Proactive.restoreSustainedSamples,
    cycles: Int = 0
) -> Int? {
    Proactive.restoreTargetBytes(
        availableMemoryBytes: available,
        physicalMemoryBytes: twoGiB,
        currentCapBytes: current,
        baselineCapBytes: baseline,
        consecutiveRecoveredSamples: samples,
        completedRestoreCycles: cycles
    )
}

let restoreThreshold = Proactive.restoreThresholdBytes(physicalMemoryBytes: twoGiB)

check("restore threshold sits at twice the clamp threshold so the two can never share a boundary",
      restoreThreshold == threshold * 2)
check("the sustained window is two minutes of samples",
      Double(Proactive.restoreSustainedSamples) * Proactive.sampleInterval == 120)

// Headroom gate: merely clearing the CLAMP threshold is not enough to raise anything.

check("headroom just past the clamp threshold does not restore",
      proactiveRestore(available: threshold + 1, current: P.floorBytes, baseline: 128 * mib) == nil)
check("headroom one byte below the restore threshold does not restore",
      proactiveRestore(available: restoreThreshold - 1, current: P.floorBytes, baseline: 128 * mib) == nil)
check("zero available memory never restores (strongest pressure signal, same as the clamp)",
      proactiveRestore(available: 0, current: P.floorBytes, baseline: 128 * mib) == nil)
check("headroom exactly at the restore threshold restores",
      proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 128 * mib) == 96 * mib)

// Sustained-run gate: a lucky sample cannot raise the cap.

check("no restore before the sustained run completes",
      proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 128 * mib,
                       samples: Proactive.restoreSustainedSamples - 1) == nil)
check("no restore on the very first recovered sample",
      proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 128 * mib,
                       samples: 1) == nil)
check("no restore with no recovered run at all",
      proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 128 * mib,
                       samples: 0) == nil)
check("a longer run than required still restores exactly one rung",
      proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 128 * mib,
                       samples: 100) == 96 * mib)

// One rung at a time, and the per-file baseline is a hard ceiling (the DIAG-12 device-safe cap).

check("restore doubles 48 MiB to 96 MiB rather than jumping to the baseline",
      proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 256 * mib) == 96 * mib)
check("restore doubles 64 MiB to 128 MiB",
      proactiveRestore(available: restoreThreshold, current: 64 * mib, baseline: 256 * mib) == 128 * mib)
check("a rung that would overshoot lands exactly on the baseline",
      proactiveRestore(available: restoreThreshold, current: 96 * mib, baseline: 128 * mib) == 128 * mib)
check("a cap already at the baseline never restores",
      proactiveRestore(available: restoreThreshold, current: 128 * mib, baseline: 128 * mib) == nil)
check("a cap somehow above the baseline is never raised further",
      proactiveRestore(available: restoreThreshold, current: 256 * mib, baseline: 128 * mib) == nil)

// The ladder terminates: walking up from the floor converges on the baseline and then stops.

for baseline in [96 * mib, 128 * mib, 256 * mib, 512 * mib] {
    var walked = P.floorBytes
    var rungs = 0
    while let next = proactiveRestore(available: restoreThreshold, current: walked, baseline: baseline),
          rungs < 16 {
        check("baseline \(baseline >> 20)MiB: rung \(rungs) stays within (current, baseline]",
              next > walked && next <= baseline)
        walked = next
        rungs += 1
    }
    check("baseline \(baseline >> 20)MiB: the restore ladder converges on the baseline and stops",
          walked == baseline && rungs < 16)
}

// Clamp and restore compose without oscillating: a restored rung under renewed pressure sheds again to a
// value the restore ladder can only climb back from one rung at a time, never past the baseline.

let restoredRung = proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 128 * mib)
check("a restored rung is still clampable when pressure returns",
      restoredRung.flatMap { proactiveTarget(available: 0, current: $0) } == P.floorBytes)

// MARK: - Per-file restore cap: the clamp goes back to one-way once the budget is spent
//
// A restore RE-ARMS the one-shot clamp, so without a cap, external pressure oscillating around the threshold
// (another app allocating and freeing) turns one clamp into an endless clamp/restore ladder - and every rung
// down pays a drop-buffers plus an exact re-anchor seek, the "jumps forward after a pause" regression surface.

check("the per-file restore budget is two", Proactive.maxRestoreCyclesPerFile == 2)
check("cycles default to zero, so a caller that does not track them ranks exactly as before",
      proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 128 * mib)
        == proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 128 * mib,
                            cycles: 0))
for spent in 0 ..< Proactive.maxRestoreCyclesPerFile {
    check("restore \(spent + 1) of \(Proactive.maxRestoreCyclesPerFile) is still granted",
          proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 128 * mib,
                           cycles: spent) == 96 * mib)
}
check("the restore past the cap is refused: the clamp is one-way again for this file",
      proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 128 * mib,
                       cycles: Proactive.maxRestoreCyclesPerFile) == nil)
check("a cap-spent file is refused however long headroom holds",
      proactiveRestore(available: restoreThreshold * 8, current: P.floorBytes, baseline: 512 * mib,
                       samples: 10_000, cycles: Proactive.maxRestoreCyclesPerFile) == nil)
check("a cap-spent file stays refused as the cycle count grows further",
      proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 128 * mib,
                       cycles: Proactive.maxRestoreCyclesPerFile + 7) == nil)
// The cap bounds restores, never clamps: shedding under real pressure must keep working for the whole file.
check("a cap-spent file can still be clamped when pressure returns",
      proactiveTarget(available: 0, current: 128 * mib) == 64 * mib)

// MARK: - tvOS remote VOD cap survives disk-cache selection

func remoteVODCap(
    diskCacheEnabled: Bool,
    baselineMiB: Int,
    configuredDiskCacheMiB: Int,
    reduced: Bool,
    enforceTVOSLimit: Bool = true
) -> Int64 {
    Proactive.remoteVODCapBytes(
        diskCacheEnabled: diskCacheEnabled,
        baselineBytes: Int64(baselineMiB * mib),
        configuredDiskCacheBytes: Int64(configuredDiskCacheMiB * mib),
        performanceReduced: reduced,
        enforceTVOSLimit: enforceTVOSLimit
    )
}

check("tvOS normal remote VOD stays at 128 MiB with disk cache off",
      remoteVODCap(
        diskCacheEnabled: false,
        baselineMiB: 128,
        configuredDiskCacheMiB: 256,
        reduced: false
      ) == Int64(128 * mib))
check("tvOS normal remote VOD cannot exceed 128 MiB with disk cache on",
      remoteVODCap(
        diskCacheEnabled: true,
        baselineMiB: 128,
        configuredDiskCacheMiB: 256,
        reduced: false
      ) == Int64(128 * mib))
check("tvOS reduced remote VOD stays at 96 MiB with disk cache off",
      remoteVODCap(
        diskCacheEnabled: false,
        baselineMiB: 96,
        configuredDiskCacheMiB: 192,
        reduced: true
      ) == Int64(96 * mib))
check("tvOS reduced remote VOD cannot exceed 96 MiB with disk cache on",
      remoteVODCap(
        diskCacheEnabled: true,
        baselineMiB: 96,
        configuredDiskCacheMiB: 192,
        reduced: true
      ) == Int64(96 * mib))
check("tvOS preserves a configured disk-cache ceiling below its hard limit",
      remoteVODCap(
        diskCacheEnabled: true,
        baselineMiB: 128,
        configuredDiskCacheMiB: 64,
        reduced: false
      ) == Int64(64 * mib))
check("iOS and macOS disk-cache selection is unchanged when tvOS limit is not applied",
      remoteVODCap(
        diskCacheEnabled: true,
        baselineMiB: 256,
        configuredDiskCacheMiB: 512,
        reduced: false,
        enforceTVOSLimit: false
      ) == Int64(512 * mib))
check("iOS and macOS baseline selection is unchanged when disk cache is off",
      remoteVODCap(
        diskCacheEnabled: false,
        baselineMiB: 512,
        configuredDiskCacheMiB: 256,
        reduced: false,
        enforceTVOSLimit: false
      ) == Int64(512 * mib))

// MARK: - Guarded flush-defer on a soft warning (diag-23 FIX-C)
//
// The shed's cap step-down is unconditional; only the immediate drop-buffers + exact re-anchor seek (the
// frame-drop burst diag-23 blamed) is gated. shouldDeferFlushOnWarning returns true - skip that flush -
// ONLY when free memory is provably ample (restore-grade headroom, twice the clamp threshold) AND the live
// cache already fits the reduced cap the warning applies, so the drop would free nothing the cap does not
// already bound. Any weaker headroom, or a cache that overflows the reduced cap, keeps the drastic path.

func deferFlush(
    available: UInt64,
    currentCap: Int,
    fill: Int,
    previouslyShed: Bool = false
) -> Bool {
    P.shouldDeferFlushOnWarning(
        availableBytes: available,
        physicalBytes: twoGiB,
        currentCapBytes: currentCap,
        cacheFillBytes: fill,
        previouslyShed: previouslyShed
    )
}

// The reduced cap the first warning applies to a 256 MiB budget is 128 MiB (halve); a later warning floors.
let reducedFirst = P.forwardCapAfterWarning(currentBytes: 256 * mib, previouslyShed: false)   // 128 MiB
let reducedLater = P.forwardCapAfterWarning(currentBytes: 256 * mib, previouslyShed: true)     // 48 MiB floor
check("defer setup: first-warning reduced cap is 128 MiB", reducedFirst == 128 * mib)
check("defer setup: later-warning reduced cap is the 48 MiB floor", reducedLater == P.floorBytes)

// (a) Ample headroom AND the live cache already fits the reduced cap -> defer the flush (it would drop nothing).
check("(a) ample headroom + fill below reduced cap defers the flush",
      deferFlush(available: restoreThreshold, currentCap: 256 * mib, fill: 100 * mib) == true)
check("(a) fill exactly at the reduced cap still defers (nothing to free)",
      deferFlush(available: restoreThreshold, currentCap: 256 * mib, fill: reducedFirst) == true)
check("(a) headroom well past the restore bar still defers",
      deferFlush(available: restoreThreshold * 4, currentCap: 256 * mib, fill: 100 * mib) == true)

// (b) Low headroom -> the drastic shed+flush fires, jetsam protection unchanged.
check("(b) one byte below the restore bar does NOT defer (drastic flush fires)",
      deferFlush(available: restoreThreshold - 1, currentCap: 256 * mib, fill: 100 * mib) == false)
check("(b) merely clearing the CLAMP threshold is not enough to defer",
      deferFlush(available: threshold, currentCap: 256 * mib, fill: 100 * mib) == false)
check("(b) zero available memory (strongest pressure signal) never defers",
      deferFlush(available: 0, currentCap: 256 * mib, fill: 100 * mib) == false)

// (c) Ample headroom but the cache overflows the reduced cap -> the flush WOULD free real bytes, so do NOT defer.
check("(c) ample headroom + fill above the reduced cap does NOT defer (flush is doing real work)",
      deferFlush(available: restoreThreshold, currentCap: 256 * mib, fill: 200 * mib) == false)
check("(c) one byte over the reduced cap does not defer",
      deferFlush(available: restoreThreshold, currentCap: 256 * mib, fill: reducedFirst + 1) == false)
check("(c) an unreadable fill (Int.max sentinel) never defers, however ample the headroom",
      deferFlush(available: restoreThreshold * 8, currentCap: 256 * mib, fill: Int.max) == false)

// A later (previouslyShed) warning gates against the FLOOR, not the halved cap.
check("later warning: fill within the floor defers under ample headroom",
      deferFlush(available: restoreThreshold, currentCap: 256 * mib, fill: 40 * mib, previouslyShed: true) == true)
check("later warning: fill above the floor does not defer",
      deferFlush(available: restoreThreshold, currentCap: 256 * mib, fill: 60 * mib, previouslyShed: true) == false)

// (d) The cap the warning applies (forwardCapAfterWarning) stays NON-INCREASING in every branch: the defer
// query is orthogonal to it, so skipping the flush never lets the cap grow. The drastic and deferred paths
// apply the exact same reduced cap; only the flush differs.
for budget in [64 * mib, 96 * mib, 128 * mib, 256 * mib, 512 * mib, 768 * mib] {
    for previouslyShed in [false, true] {
        let reduced = P.forwardCapAfterWarning(currentBytes: budget, previouslyShed: previouslyShed)
        check("(d) budget \(budget >> 20)MiB shed=\(previouslyShed): reduced cap within [floor, budget]",
              reduced >= P.floorBytes && reduced <= max(budget, P.floorBytes))
        check("(d) budget \(budget >> 20)MiB shed=\(previouslyShed): reduced cap never exceeds a >=floor budget",
              budget < P.floorBytes || reduced <= budget)
        // Evaluate both branches, then re-derive the cap: it must be identical, proving the guard cannot
        // perturb the applied (non-increasing) cap regardless of whether the flush is deferred.
        let deferredBranch = deferFlush(available: restoreThreshold, currentCap: budget, fill: 0,
                                        previouslyShed: previouslyShed)                       // ample + empty -> true
        let drasticBranch = deferFlush(available: 0, currentCap: budget, fill: 0,
                                       previouslyShed: previouslyShed)                        // no headroom -> false
        let reducedAgain = P.forwardCapAfterWarning(currentBytes: budget, previouslyShed: previouslyShed)
        check("(d) budget \(budget >> 20)MiB shed=\(previouslyShed): applied cap is branch-independent",
              reducedAgain == reduced && deferredBranch == true && drasticBranch == false)
    }
}

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
