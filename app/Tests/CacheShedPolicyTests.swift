// Executable harness for the #148 memory-warning cache-shed decision.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/cache-shed-policy-test \
//     app/Sources/Player/CacheShedPolicy.swift \
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

// MARK: - Result

print("")
if failures == 0 { print("ALL PASS"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
}
