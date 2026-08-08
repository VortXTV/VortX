// Executable harness for the tvOS memory-warning cache-shed decision.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/cache-shed-policy-test \
//     app/Sources/Player/CacheShedPolicy.swift \
//     app/Sources/Player/TVOSProactiveMemoryPressurePolicy.swift \
//     app/Tests/CacheShedPolicyTests.swift && /tmp/cache-shed-policy-test
//
// This suite CALLS the production decision (the DVPlaybackContractTests pattern). The property under test is
// the "buffers constantly after Beta 8" field campaign: twelve device logs proved the rebuffering was a
// SPURIOUS reactive shed. Across 743 os_proc_available_memory samples during playback the MINIMUM free was
// 712 MiB and NONE dipped below the ~384 MiB pressure threshold, yet the cap was slammed toward the floor
// 65+ times. So the ROOT FIX is asserted here: a warning with provably ample real headroom must leave the cap
// UNCHANGED (no shed at all), while genuine low headroom must STILL step the cap down toward the raised,
// device-scaled floor - jetsam relief preserved. The floor rose from 48 MiB to 192 MiB (normal) / 128 MiB
// (reduced), with a 150 MiB hard-never-below on the normal tier, so even a genuine shed keeps a playable 4K
// buffer instead of a razor-thin 48 MiB. The recovery section (FAIL-260804-04) keeps its hysteresis gate.

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
typealias Proactive = TVOSProactiveMemoryPressurePolicy
let mib = 1 << 20
let twoGiB = UInt64(2) << 30
let threshold = Proactive.pressureThresholdBytes(physicalMemoryBytes: twoGiB)          // 256 MiB
let restoreThreshold = Proactive.restoreThresholdBytes(physicalMemoryBytes: twoGiB)    // 512 MiB

// MARK: - The raised, device-scaled floor and the shed rung

check("normal shed floor is 192 MiB (up from the old 48 MiB)", P.floorBytes == 192 * mib)
check("hard-never-below is 150 MiB", P.hardMinFloorBytes == 150 * mib)
check("the normal floor is never below the hard-min", P.floorBytes >= P.hardMinFloorBytes)
check("the reduced (2 GB Apple TV HD) floor scales down to 128 MiB", P.reducedFloorBytes == 128 * mib)
check("one shed rung is 64 MiB", P.stepBytes == 64 * mib)

// A warning helper at the fixed 2 GiB physical so restoreThreshold == 512 MiB throughout.
func warnCap(current: Int, available: UInt64, floor: Int = P.floorBytes, step: Int = P.stepBytes) -> Int {
    P.forwardCapAfterWarning(
        currentBytes: current, availableBytes: available, physicalBytes: twoGiB,
        floorBytes: floor, stepBytes: step)
}

// MARK: - (a) ROOT FIX: an advisory warning with ample real headroom leaves the cap UNCHANGED

// The cap-lowering bar is now the PRESSURE threshold (the same bar the proactive clamp uses), NOT the restore
// bar. In this 2 GiB test harness pressure = 256 MiB, restore = 512 MiB.
check("(a) headroom exactly at the pressure bar holds the cap (only strictly below sheds)",
      warnCap(current: 384 * mib, available: threshold) == 384 * mib)
check("(a) headroom one byte above the pressure bar holds the cap",
      warnCap(current: 384 * mib, available: threshold + 1) == 384 * mib)
check("(a) the field-min case (712 MiB free) HOLDS - the whole point: on the real 3 GB box the restore bar (768) would have shed it, the pressure bar (384) does not",
      warnCap(current: 384 * mib, available: UInt64(712 * mib)) == 384 * mib)
check("(a) the entire [pressure, restore) band holds the cap (restore bar no longer sheds)",
      warnCap(current: 384 * mib, available: restoreThreshold - 1) == 384 * mib)
check("(a) headroom at and past the restore bar still holds",
      warnCap(current: 384 * mib, available: restoreThreshold) == 384 * mib
        && warnCap(current: 384 * mib, available: restoreThreshold * 8) == 384 * mib)
check("(a) a cap already at the floor is held under ample headroom",
      warnCap(current: P.floorBytes, available: threshold) == P.floorBytes)

// MARK: - (d) genuine low headroom (strictly below the PRESSURE bar) STILL sheds, one rung toward the floor

check("(d) one byte below the pressure bar sheds 256 MiB down one rung to the 192 MiB floor",
      warnCap(current: 256 * mib, available: threshold - 1) == 192 * mib)
check("(d) zero available memory (strongest pressure signal) sheds",
      warnCap(current: 256 * mib, available: 0) == 192 * mib)
check("(d) the 384 MiB baseline steps down exactly one 64 MiB rung to 320 MiB",
      warnCap(current: 384 * mib, available: 0) == 320 * mib)
check("(d) a 320 MiB cap steps down exactly one 64 MiB rung to 256 MiB",
      warnCap(current: 320 * mib, available: 0) == 256 * mib)
check("(d) a rung that would undershoot lands exactly on the floor",
      warnCap(current: 200 * mib, available: 0) == 192 * mib)

// MARK: - (b)/(c) the floor and the hard-min: no genuine-low shed on the normal tier drops below either

check("(b) a cap at the floor cannot shed lower even at zero headroom",
      warnCap(current: P.floorBytes, available: 0) == P.floorBytes)
for current in [P.floorBytes, 200 * mib, 224 * mib, 256 * mib, 320 * mib, 384 * mib] {
    let shed = warnCap(current: current, available: 0)
    check("(c) normal shed of \(current >> 20)MiB stays in [floor, current] and never below the hard-min",
          shed >= P.floorBytes && shed <= current && shed >= P.hardMinFloorBytes)
}

// MARK: - The reduced (2 GB Apple TV HD) tier: a warning NEVER inflates the tight 96 MiB buffer

// The reduced load cap is a tight 96 MiB, below the 128 MiB reduced floor. The shed is non-increasing, so
// neither an ample nor a low-headroom warning may raise it - HD stays crash-safe with its shipped buffer.
check("reduced: ample headroom holds the 96 MiB buffer",
      warnCap(current: 96 * mib, available: restoreThreshold, floor: P.reducedFloorBytes) == 96 * mib)
check("reduced: low headroom cannot inflate the 96 MiB buffer toward the 128 MiB floor (non-increasing)",
      warnCap(current: 96 * mib, available: 0, floor: P.reducedFloorBytes) == 96 * mib)
check("reduced: a cap at the reduced floor holds",
      warnCap(current: P.reducedFloorBytes, available: 0, floor: P.reducedFloorBytes) == P.reducedFloorBytes)

// MARK: - Non-increasing in every branch, at any headroom and any floor

for floor in [P.floorBytes, P.reducedFloorBytes, P.hardMinFloorBytes] {
    for current in [64 * mib, 96 * mib, 128 * mib, 192 * mib, 256 * mib, 384 * mib] {
        for available in [UInt64(0), threshold, restoreThreshold, restoreThreshold * 4] {
            let cap = warnCap(current: current, available: available, floor: floor)
            check("non-increasing: floor \(floor >> 20) current \(current >> 20) avail \(available >> 20) -> \(cap >> 20) <= current",
                  cap <= current && cap >= min(current, floor))
        }
    }
}

// MARK: - Cap-string parsing (the two spellings loadFile actually writes)

check("parses the MiB-suffixed static tier spelling", P.capBytes("256MiB") == 256 * mib)
check("parses the plain-bytes streaming-cache spelling", P.capBytes("268435456") == 256 * mib)
check("rejects zero", P.capBytes("0") == nil && P.capBytes("0MiB") == nil)
check("rejects negatives", P.capBytes("-1") == nil && P.capBytes("-4MiB") == nil)
check("rejects other suffixes rather than misreading them",
      P.capBytes("48KiB") == nil && P.capBytes("1GiB") == nil && P.capBytes("") == nil)

// MARK: - Proactive tvOS dirty-memory headroom policy (thresholds unchanged; floor now the raised floor)

check("proactive threshold has a 192 MiB minimum",
      Proactive.pressureThresholdBytes(physicalMemoryBytes: UInt64(1) << 30) == UInt64(192 * mib))
check("proactive threshold scales at one eighth of physical memory",
      threshold == UInt64(256 * mib))
check("proactive threshold has a 384 MiB maximum",
      Proactive.pressureThresholdBytes(physicalMemoryBytes: UInt64(4) << 30) == UInt64(384 * mib))

func proactiveTarget(
    available: UInt64,
    current: Int,
    floor: Int = P.floorBytes,
    alreadyClamped: Bool = false
) -> Int? {
    Proactive.clampTargetBytes(
        availableMemoryBytes: available,
        physicalMemoryBytes: twoGiB,
        currentCapBytes: current,
        floorBytes: floor,
        alreadyClamped: alreadyClamped
    )
}

check("exact proactive threshold does not clamp",
      proactiveTarget(available: threshold, current: 256 * mib) == nil)
check("one byte below proactive threshold clamps 256 MiB to the 192 MiB floor",
      proactiveTarget(available: threshold - 1, current: 256 * mib) == 192 * mib)
check("zero available memory clamps because the dirty-memory allowance is exhausted",
      proactiveTarget(available: 0, current: 256 * mib) == 192 * mib)
check("recovered high headroom does not request a cache mutation",
      proactiveTarget(available: threshold + 1, current: 256 * mib) == nil)
check("proactive clamp halves 384 MiB toward the floor (max(floor, 192) == 192)",
      proactiveTarget(available: threshold - 1, current: 384 * mib) == 192 * mib)
check("proactive clamp at the floor is a no-op",
      proactiveTarget(available: threshold - 1, current: P.floorBytes) == nil)
check("a cap below the floor never proactively clamps (guard current > floor)",
      proactiveTarget(available: 0, current: 96 * mib) == nil)
check("already-clamped proactive state is idempotent",
      proactiveTarget(available: 0, current: 256 * mib, alreadyClamped: true) == nil)

// MARK: - Hysteresis-gated recovery to the RAISED 256 MiB baseline (FAIL-260804-04)

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

check("restore threshold sits at twice the clamp threshold so the two can never share a boundary",
      restoreThreshold == threshold * 2)
check("the sustained window is two minutes of samples",
      Double(Proactive.restoreSustainedSamples) * Proactive.sampleInterval == 120)

// A shed file (cap at the 192 MiB floor) restores to the raised 256 MiB baseline once headroom is sustained.
check("headroom one byte below the restore threshold does not restore",
      proactiveRestore(available: restoreThreshold - 1, current: P.floorBytes, baseline: 256 * mib) == nil)
check("zero available memory never restores (strongest pressure signal)",
      proactiveRestore(available: 0, current: P.floorBytes, baseline: 256 * mib) == nil)
check("headroom exactly at the restore threshold restores the floor toward the 256 MiB baseline",
      proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 256 * mib) == 256 * mib)
check("no restore before the sustained run completes",
      proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 256 * mib,
                       samples: Proactive.restoreSustainedSamples - 1) == nil)
check("a rung that would overshoot lands exactly on the baseline",
      proactiveRestore(available: restoreThreshold, current: 192 * mib, baseline: 256 * mib) == 256 * mib)
check("a cap already at the baseline never restores",
      proactiveRestore(available: restoreThreshold, current: 256 * mib, baseline: 256 * mib) == nil)

// The ladder terminates on the raised baselines.
for baseline in [192 * mib, 256 * mib, 320 * mib, 384 * mib] {
    var walked = P.reducedFloorBytes   // start below any of these baselines
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

check("the per-file restore budget is two", Proactive.maxRestoreCyclesPerFile == 2)
check("the restore past the cap is refused: the clamp is one-way again for this file",
      proactiveRestore(available: restoreThreshold, current: P.floorBytes, baseline: 256 * mib,
                       cycles: Proactive.maxRestoreCyclesPerFile) == nil)
// Even a cap-spent file lands no LOWER than the raised 192 MiB floor, so the FAIL-260804-04 pathology now
// strands (if ever) at a playable 4K buffer, not the old razor-thin 48 MiB.
check("a cap-spent file can still be clamped, but never below the raised floor",
      proactiveTarget(available: 0, current: 256 * mib) == 192 * mib)

// MARK: - tvOS remote VOD cap: the NORMAL tier now admits 256 MiB; reduced stays a tight 96 MiB

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

// The 384 MiB baseline (RemoteConfigDefaults.tvosReadAheadBaselineMiB) flows through: the normal-tier wall
// rose 256 -> 384 in lockstep so the baseline is applied, not clamped down.
check("tvOS normal remote VOD applies the raised 384 MiB baseline with disk cache off",
      remoteVODCap(diskCacheEnabled: false, baselineMiB: 384, configuredDiskCacheMiB: 512, reduced: false)
        == Int64(384 * mib))
check("tvOS normal remote VOD is capped at the 384 MiB RAM wall with disk cache on",
      remoteVODCap(diskCacheEnabled: true, baselineMiB: 384, configuredDiskCacheMiB: 512, reduced: false)
        == Int64(384 * mib))
check("tvOS reduced remote VOD stays at 96 MiB with disk cache off (unchanged)",
      remoteVODCap(diskCacheEnabled: false, baselineMiB: 96, configuredDiskCacheMiB: 192, reduced: true)
        == Int64(96 * mib))
check("tvOS reduced remote VOD cannot exceed 96 MiB with disk cache on (unchanged)",
      remoteVODCap(diskCacheEnabled: true, baselineMiB: 96, configuredDiskCacheMiB: 192, reduced: true)
        == Int64(96 * mib))
check("tvOS preserves a configured disk-cache ceiling below its 384 MiB wall",
      remoteVODCap(diskCacheEnabled: true, baselineMiB: 384, configuredDiskCacheMiB: 128, reduced: false)
        == Int64(128 * mib))
check("iOS and macOS disk-cache selection is unchanged when tvOS limit is not applied",
      remoteVODCap(diskCacheEnabled: true, baselineMiB: 256, configuredDiskCacheMiB: 512, reduced: false,
                   enforceTVOSLimit: false) == Int64(512 * mib))
check("iOS and macOS baseline selection is unchanged when disk cache is off",
      remoteVODCap(diskCacheEnabled: false, baselineMiB: 512, configuredDiskCacheMiB: 256, reduced: false,
                   enforceTVOSLimit: false) == Int64(512 * mib))

// MARK: - Guarded flush-defer on a warning (diag-23 FIX-C), now floor/step-parameterised

func deferFlush(
    available: UInt64,
    currentCap: Int,
    fill: Int,
    floor: Int = P.floorBytes,
    step: Int = P.stepBytes
) -> Bool {
    P.shouldDeferFlushOnWarning(
        availableBytes: available,
        physicalBytes: twoGiB,
        currentCapBytes: currentCap,
        cacheFillBytes: fill,
        floorBytes: floor,
        stepBytes: step
    )
}

// Under ample headroom the cap is held UNCHANGED, so the reduced cap the flush gate compares against is the
// current cap itself: defer iff the live cache already fits it (the drop would free nothing).
check("(a) ample headroom + fill below the (held) cap defers the flush",
      deferFlush(available: restoreThreshold, currentCap: 256 * mib, fill: 100 * mib) == true)
check("(a) fill exactly at the held cap still defers (nothing to free)",
      deferFlush(available: restoreThreshold, currentCap: 256 * mib, fill: 256 * mib) == true)
check("(a) headroom well past the restore bar still defers",
      deferFlush(available: restoreThreshold * 4, currentCap: 256 * mib, fill: 100 * mib) == true)

// Low headroom -> the drastic shed+flush fires, jetsam protection unchanged.
check("(b) one byte below the restore bar does NOT defer (drastic flush fires)",
      deferFlush(available: restoreThreshold - 1, currentCap: 256 * mib, fill: 100 * mib) == false)
check("(b) merely clearing the CLAMP threshold is not enough to defer",
      deferFlush(available: threshold, currentCap: 256 * mib, fill: 100 * mib) == false)
check("(b) zero available memory (strongest pressure signal) never defers",
      deferFlush(available: 0, currentCap: 256 * mib, fill: 100 * mib) == false)

// Ample headroom but the cache overflows the held cap -> the flush WOULD free real bytes, so do NOT defer.
check("(c) ample headroom + fill above the held cap does NOT defer (flush is doing real work)",
      deferFlush(available: restoreThreshold, currentCap: 256 * mib, fill: 300 * mib) == false)
check("(c) an unreadable fill (Int.max sentinel) never defers, however ample the headroom",
      deferFlush(available: restoreThreshold * 8, currentCap: 256 * mib, fill: Int.max) == false)

// The flush-defer query is orthogonal to the applied (non-increasing) cap: skipping the flush never grows it.
for current in [96 * mib, 128 * mib, 192 * mib, 256 * mib, 384 * mib] {
    let deferredBranch = deferFlush(available: restoreThreshold, currentCap: current, fill: 0)   // ample+empty
    let drasticBranch = deferFlush(available: 0, currentCap: current, fill: 0)                    // no headroom
    let capAmple = warnCap(current: current, available: restoreThreshold)
    let capLow = warnCap(current: current, available: 0)
    check("(d) current \(current >> 20)MiB: ample defers, low does not, and neither branch grows the cap",
          deferredBranch == true && drasticBranch == false && capAmple <= current && capLow <= current)
}

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
