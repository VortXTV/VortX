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

// MARK: - Internal cache-flush EOF ownership

for reason in [CacheFlushReason.pausedCacheClamp, .memoryWarning, .proactiveMemoryPressure] {
    var flight = CacheFlushSingleFlight<Int>()
    _ = flight.install(
        owner: 7, reason: reason, target: 42, targetArgument: "42.000", startUptime: 1,
        timeoutWorkItem: DispatchWorkItem {}
    )
    check("\(reason.rawValue): exact live owner suppresses synthetic EOF",
          flight.suppressesEOF(owner: 7))
    check("\(reason.rawValue): another load owner remains terminal",
          !flight.suppressesEOF(owner: 8))
    let consumed = flight.consumeSyntheticEOF(owner: 7)
    check("\(reason.rawValue): exact EOF consumes its one-shot ownership",
          consumed?.owner == 7 && consumed?.reason == reason)
    check("\(reason.rawValue): later EOF after synthetic edge remains genuine",
          !flight.suppressesEOF(owner: 7))
}

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

// MARK: - Pinned MPVKit disk-cache capability: preference cannot masquerade as payload offload

check("disk cache: pinned MPVKit payload offload remains explicitly unconfirmed",
      P.diskCachePayloadOffloadConfirmed == false)
check("disk cache settings: unconfirmed offload exposes an honest automatic RAM-bounded state",
      !P.diskCacheSizeSelectionAvailable
        && P.unavailableDiskCacheState == "Automatic RAM-bounded buffer"
        && P.unavailableDiskCacheAccessibilityHint.contains("unavailable")
        && P.unavailableDiskCacheAccessibilityHint.contains("RAM-bounded"))
check("disk cache settings: dormant nonzero and unlimited preferences cannot appear selected",
      P.presentedDiskCacheSizeSelection(storedBytes: 2 << 30) == nil
        && P.presentedDiskCacheSizeSelection(storedBytes: -1) == nil)
check("disk cache: a nonzero user preference cannot arm unsupported payload offload",
      P.shouldArmDiskCache(payloadOffloadRequested: true, muted: false) == false)
check("disk cache: the muted preview remains unarmed",
      P.shouldArmDiskCache(payloadOffloadRequested: true, muted: true) == false)
check("disk cache: a stale armed bit cannot select the metadata cap or ramp for remote VOD",
      P.shouldUseDiskCacheForLoad(
        payloadOffloadRequested: true,
        diskCacheOnDiskArmed: true,
        live: false,
        local: false
      ) == false)
check("disk cache: ordinary and reduced RAM baselines survive a nonzero preference",
      remoteVODCap(
        diskCacheEnabled: P.shouldUseDiskCacheForLoad(
            payloadOffloadRequested: true,
            diskCacheOnDiskArmed: true,
            live: false,
            local: false
        ),
        baselineMiB: 384,
        configuredDiskCacheMiB: 128,
        reduced: false
      ) == Int64(384 * mib)
        && remoteVODCap(
            diskCacheEnabled: P.shouldUseDiskCacheForLoad(
                payloadOffloadRequested: true,
                diskCacheOnDiskArmed: true,
                live: false,
                local: false
            ),
            baselineMiB: 96,
            configuredDiskCacheMiB: 128,
            reduced: true
        ) == Int64(96 * mib))
check("disk cache: live and local loads never use the offload-only path",
      P.shouldUseDiskCacheForLoad(
        payloadOffloadRequested: true,
        diskCacheOnDiskArmed: true,
        live: true,
        local: false
      ) == false
        && P.shouldUseDiskCacheForLoad(
            payloadOffloadRequested: true,
            diskCacheOnDiskArmed: true,
            live: false,
            local: true
        ) == false)

let controllerURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/Player/MPVMetalViewController.swift")
let controllerSource = (try? String(contentsOf: controllerURL, encoding: .utf8)) ?? ""
check("disk cache wiring: setup uses the authoritative capability gate",
      controllerSource.contains("VortXCacheShedPolicy.shouldArmDiskCache("))
check("disk cache wiring: per-load cap and ramp share the confirmed-offload decision",
      controllerSource.contains("let usesConfirmedDiskOffload = VortXCacheShedPolicy.shouldUseDiskCacheForLoad(")
        && controllerSource.components(separatedBy: "if usesConfirmedDiskOffload {").count == 3)
check("disk cache wiring: the saved preference is diagnostic input, not a direct per-load branch",
      !controllerSource.contains("if DiskCacheSetting.diskCacheEnabled, !live, !isLocalStream"))
check("disk cache diagnostics: requested and confirmed capability are recorded without a cache path",
      controllerSource.contains("streaming cache requestedMode=")
        && controllerSource.contains("enabledAfterFleetGate=")
        && controllerSource.contains("payloadOffloadConfirmed=")
        && !controllerSource.contains("disk cache armed at "))

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

// MARK: - Single-flight cache-flush lifecycle (deterministic; no timers or sleeps)

// The controller supplies the real PlayerLoadToken. This harness uses Int so the narrow value type stays
// dependency-free and its ownership rules can be exercised without UIKit/libmpv.
let firstTimeout = DispatchWorkItem { }
var flightGate = CacheFlushSingleFlight<Int>()
check("single-flight: an idle gate admits the first owner", flightGate.admit(owner: 1) == .started)
let firstFlight = flightGate.install(
    owner: 1,
    reason: .memoryWarning,
    target: 1604,
    targetArgument: "1604.000",
    startUptime: 10,
    timeoutWorkItem: firstTimeout
)
check("single-flight: first flight has monotonic id, exact owner, finite target, and one formatted argument",
      firstFlight.id == 1 && firstFlight.owner == 1 && firstFlight.target == 1604
        && firstFlight.targetArgument == "1604.000" && firstFlight.startUptime == 10
        && firstFlight.phase == .dropping && firstFlight.result == .pending)
check("single-flight: duplicate and triple warnings coalesce without changing reason or target",
      flightGate.admit(owner: 1) == .coalesced
        && flightGate.admit(owner: 1) == .coalesced
        && flightGate.current?.id == firstFlight.id
        && flightGate.current?.coalescedCount == 2
        && flightGate.current?.reason == .memoryWarning
        && flightGate.current?.targetArgument == "1604.000")
check("single-flight: drop success enters seeking only for the exact owner",
      flightGate.markDropSucceeded(id: firstFlight.id, owner: 2) == false
        && flightGate.markDropSucceeded(id: firstFlight.id, owner: 1)
        && flightGate.current?.phase == .seeking)
check("single-flight: exact seek acceptance enters settling and wrong identity is ignored",
      flightGate.markSeekCommandAccepted(id: firstFlight.id + 1, owner: 1) == false
        && flightGate.markSeekCommandAccepted(id: firstFlight.id, owner: 2) == false
        && flightGate.markSeekCommandAccepted(id: firstFlight.id, owner: 1)
        && flightGate.current?.phase == .settling
        && flightGate.markSeekCommandAccepted(id: firstFlight.id, owner: 1) == false)
check("single-flight: same-owner warnings coalesce for the full settle window",
      flightGate.admit(owner: 1) == .coalesced
        && flightGate.current?.coalescedCount == 3
        && flightGate.current?.phase == .settling)
check("single-flight: exact settle produces command-accepted and cancels the deadline once",
      flightGate.settle(id: firstFlight.id, owner: 1)?.result == .commandAccepted
        && flightGate.current == nil
        && firstTimeout.isCancelled
        && flightGate.settle(id: firstFlight.id, owner: 1) == nil)

check("single-flight: completion permits a later flight with a newer id",
      flightGate.admit(owner: 1) == .started)
let secondFlight = flightGate.install(
    owner: 1,
    reason: .pausedCacheClamp,
    target: 1404,
    targetArgument: "1404.000",
    startUptime: 20,
    timeoutWorkItem: DispatchWorkItem { }
)
check("single-flight: an old same-owner settle cannot clear a newer flight",
      flightGate.settle(id: firstFlight.id, owner: 1) == nil
        && flightGate.current?.id == secondFlight.id
        && flightGate.current?.phase == .dropping
        && flightGate.settle(id: secondFlight.id, owner: 1) == nil)
check("single-flight: stale or wrong-owner settle cannot clear the current flight",
      flightGate.settle(id: secondFlight.id - 1, owner: 2) == nil
        && flightGate.settle(id: secondFlight.id, owner: 2) == nil
        && flightGate.current?.id == secondFlight.id
        && flightGate.current?.owner == 1)
check("single-flight: exact settle clears the current flight once",
      flightGate.markDropSucceeded(id: secondFlight.id, owner: 1)
        && flightGate.markSeekCommandAccepted(id: secondFlight.id, owner: 1)
        && flightGate.settle(id: secondFlight.id, owner: 1)?.result == .commandAccepted
        && flightGate.current == nil
        && flightGate.settle(id: secondFlight.id, owner: 1) == nil)

var errorGate = CacheFlushSingleFlight<Int>()
let dropErrorFlight = errorGate.install(
    owner: 11,
    reason: .memoryWarning,
    target: 11,
    targetArgument: "11.000",
    startUptime: 60,
    timeoutWorkItem: DispatchWorkItem { }
)
check("single-flight: drop command error clears without a seek or settle window",
      errorGate.dropCommandError(id: dropErrorFlight.id, owner: 11)?.result == .dropCommandError
        && errorGate.current == nil)
let seekErrorFlight = errorGate.install(
    owner: 11,
    reason: .memoryWarning,
    target: 12,
    targetArgument: "12.000",
    startUptime: 61,
    timeoutWorkItem: DispatchWorkItem { }
)
check("single-flight: seek command error enters settling and latches the outcome",
      errorGate.markDropSucceeded(id: seekErrorFlight.id, owner: 11)
        && errorGate.seekCommandError(id: seekErrorFlight.id, owner: 12) == false
        && errorGate.seekCommandError(id: seekErrorFlight.id, owner: 11)
        && errorGate.current?.result == .seekCommandError
        && errorGate.current?.phase == .settling
        && errorGate.seekCommandError(id: seekErrorFlight.id, owner: 11) == false
        && errorGate.admit(owner: 11) == .coalesced
        && errorGate.current?.result == .seekCommandError)
check("single-flight: settle preserves seekCommandError and clears only the exact flight",
      errorGate.settle(id: seekErrorFlight.id, owner: 12) == nil
        && errorGate.settle(id: seekErrorFlight.id, owner: 11)?.result == .seekCommandError
        && errorGate.current == nil
        && errorGate.settle(id: seekErrorFlight.id, owner: 11) == nil)

var lateDeadlineGate = CacheFlushSingleFlight<Int>()
let lateDeadlineFlight = lateDeadlineGate.install(
    owner: 13,
    reason: .memoryWarning,
    target: 14,
    targetArgument: "14.000",
    startUptime: 63,
    timeoutWorkItem: DispatchWorkItem { }
)
check("single-flight: reset before settle makes a late deadline a no-op",
      lateDeadlineGate.reset()?.result == .canceled
        && lateDeadlineGate.settle(id: lateDeadlineFlight.id, owner: 13) == nil
        && lateDeadlineGate.current == nil)

var replacementGate = CacheFlushSingleFlight<Int>()
let replacementFlight = replacementGate.install(
    owner: 7,
    reason: .memoryWarning,
    target: 7,
    targetArgument: "7.000",
    startUptime: 30,
    timeoutWorkItem: DispatchWorkItem { }
)
check("single-flight: accepted replacement reset cancels the old flight",
      replacementGate.reset()?.id == replacementFlight.id && replacementGate.current == nil)
let retainedFlight = replacementGate.install(
    owner: 8,
    reason: .memoryWarning,
    target: 8,
    targetArgument: "8.000",
    startUptime: 31,
    timeoutWorkItem: DispatchWorkItem { }
)
check("single-flight: rejected replacement identity retains the current flight",
      replacementGate.reset(owner: 7) == nil
        && replacementGate.current?.id == retainedFlight.id
        && replacementGate.current?.owner == 8)

var pauseGate = CacheFlushSingleFlight<Int>()
_ = pauseGate.install(
    owner: 9,
    reason: .pausedCacheClamp,
    target: 90,
    targetArgument: "90.000",
    startUptime: 40,
    timeoutWorkItem: DispatchWorkItem { }
)
check("single-flight: proactive and pause callbacks coalesce on the same owner",
      pauseGate.admit(owner: 9) == .coalesced
        && pauseGate.current?.reason == .pausedCacheClamp
        && pauseGate.current?.coalescedCount == 1)
var independentA = CacheFlushSingleFlight<Int>()
var independentB = CacheFlushSingleFlight<Int>()
_ = independentA.install(
    owner: 10,
    reason: .memoryWarning,
    target: 10,
    targetArgument: "10.000",
    startUptime: 50,
    timeoutWorkItem: DispatchWorkItem { }
)
check("single-flight: two helper instances have independent gates",
      independentA.current != nil && independentB.current == nil
        && independentB.admit(owner: 10) == .started)

// Source contracts here are intentionally small and semantic: they keep this executable harness useful even
// when the controller cannot be compiled outside the Apple target. The full command/lifecycle mutants live in
// MPVCacheFlushReceiptContractTests.swift.
let policyURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/Player/CacheShedPolicy.swift")
if let policySource = try? String(contentsOf: policyURL, encoding: .utf8) {
    check("single-flight: policy source declares a finite reason and narrow value gate",
          policySource.contains("enum CacheFlushReason: String, Equatable")
            && policySource.contains("struct CacheFlushSingleFlight<Owner: Equatable>"))
    check("single-flight: correction pass 2 uses the synchronous settle-window phase model",
          policySource.contains("case settling")
            && policySource.contains("case commandAccepted = \"command-accepted\"")
            && policySource.contains("markSeekCommandAccepted")
            && policySource.contains("mutating func settle(id: UInt64, owner: Owner)")
            && !policySource.contains("awaitingSeekReply")
            && !policySource.contains("awaitingRestart")
            && !policySource.contains("playbackRestart")
            && !policySource.contains("markSeek(id:"))
    check("single-flight: flight source stores owner, immutable target argument, phase, result, and timeout",
          policySource.contains("let owner: Owner")
            && policySource.contains("let targetArgument: String")
            && policySource.contains("var phase: Phase")
            && policySource.contains("var result: Result")
            && policySource.contains("var timeoutWorkItem: DispatchWorkItem?"))
    check("single-flight: phase model has no generic seek latch",
          policySource.contains("case settling")
            && !policySource.contains("case awaitingSeekReply")
            && !policySource.contains("case awaitingRestart")
            && !policySource.contains("sawSeek")
            && !policySource.contains("mutating func markSeek(id:"))
}

// MARK: - Beta 26 stutter fix: the in-band flush is edge-triggered (one per headroom episode)

// The 3 GB Apple TV 4K field regime: pressure = 384 MiB, restore = 768 MiB, and os_proc_available_memory
// PARKED at ~410 MiB with advisory warnings every minute or two. Each warning used to re-run the destructive
// drop-buffers + re-anchor seek (~15 s of disruption) - the metronome-steady mid-play stutter. The gate must
// fire once per episode, hold while headroom stays parked in-band, never gate below the pressure bar, and
// leave the ample-headroom regime exactly as shipped.
let bandPressure = UInt64(384 * mib)
let bandRestore = UInt64(768 * mib)

check("(g) first in-band warning still flushes (latch unset)",
      !P.shouldDeferInBandFlush(
        availableBytes: UInt64(410 * mib), pressureThresholdBytes: bandPressure,
        restoreThresholdBytes: bandRestore, policyDefer: false,
        hasFlushedSinceHeadroomRecovered: false))
check("(g) second in-band warning at the same parked headroom defers",
      P.shouldDeferInBandFlush(
        availableBytes: UInt64(410 * mib), pressureThresholdBytes: bandPressure,
        restoreThresholdBytes: bandRestore, policyDefer: false,
        hasFlushedSinceHeadroomRecovered: true))
check("(g) below the pressure bar the latch NEVER defers (jetsam relief unconditional)",
      !P.shouldDeferInBandFlush(
        availableBytes: UInt64(300 * mib), pressureThresholdBytes: bandPressure,
        restoreThresholdBytes: bandRestore, policyDefer: false,
        hasFlushedSinceHeadroomRecovered: true)
      && !P.shouldDeferInBandFlush(
        availableBytes: 0, pressureThresholdBytes: bandPressure,
        restoreThresholdBytes: bandRestore, policyDefer: true,
        hasFlushedSinceHeadroomRecovered: true))
check("(g) at or above the restore bar the strict level-triggered gate alone decides (unchanged)",
      P.shouldDeferInBandFlush(
        availableBytes: bandRestore, pressureThresholdBytes: bandPressure,
        restoreThresholdBytes: bandRestore, policyDefer: true,
        hasFlushedSinceHeadroomRecovered: false)
      && !P.shouldDeferInBandFlush(
        availableBytes: bandRestore + UInt64(mib), pressureThresholdBytes: bandPressure,
        restoreThresholdBytes: bandRestore, policyDefer: false,
        hasFlushedSinceHeadroomRecovered: true))
check("(g) a level-triggered defer inside the band still holds even before any latch",
      P.shouldDeferInBandFlush(
        availableBytes: UInt64(420 * mib), pressureThresholdBytes: bandPressure,
        restoreThresholdBytes: bandRestore, policyDefer: true,
        hasFlushedSinceHeadroomRecovered: false))

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
