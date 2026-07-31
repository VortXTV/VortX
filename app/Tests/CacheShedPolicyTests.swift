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

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
