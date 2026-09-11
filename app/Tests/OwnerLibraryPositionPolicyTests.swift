// OwnerLibraryPositionPolicyTests: standalone, runnable proof that the owner account library's
// per-title position rows merge by REAL lastWatched clocks, atomically, instead of a warm device's
// older positive engine state clobbering a newer remote playback (cross-device CW defect 1).
//
// Follows the repo's self-contained executable convention (no Xcode unit-test bundle):
//
//     xcrun swiftc -parse-as-library -o /tmp/ownerlibpolicytest \
//         app/SourcesShared/OwnerLibraryPositionPolicy.swift \
//         app/Tests/OwnerLibraryPositionPolicyTests.swift && /tmp/ownerlibpolicytest

import Foundation

@main
enum OwnerLibraryPositionPolicyTests {
static func main() {
var failures = 0
var checks = 0

func expect(_ condition: Bool, _ what: String) {
    checks += 1
    print(condition ? "  ok    \(what)" : "  FAIL  \(what)")
    if !condition { failures += 1 }
}

func row(_ t: Int, _ d: Int, _ v: String, _ lastWatched: String) -> [String: Any] {
    ["id": "tt100", "name": "N", "type": "movie", "poster": "p", "t": t, "d": d, "v": v, "lastWatched": lastWatched]
}

let older = "2026-09-09T10:00:00.000Z"
let newer = "2026-09-10T22:30:00.000Z"

// 1. OLDER positive ENGINE state must NOT overwrite a NEWER remote playback (the headline defect).
do {
    let engine = row(120, 600, "tt100:1:1", older)             // warm device, stale engine copy
    let prior = row(800, 2400, "tt100:2:4", newer)             // peer watched further, later
    let merged = OwnerLibraryPositionPolicy.resolve(engine: engine, prior: prior)
    expect(OwnerLibraryPositionPolicy.lastWatchedMillis(merged["lastWatched"]) ==
           OwnerLibraryPositionPolicy.lastWatchedMillis(newer), "older engine does not clobber newer remote clock")
    expect((merged["t"] as? Int) == 800 && (merged["d"] as? Int) == 2400, "newer remote position t/d kept")
    expect((merged["v"] as? String) == "tt100:2:4", "newer remote episode id kept (atomic t/d/v)")
}

// 2. NEWER engine rewind propagates (not dragged back by the older-but-further remote copy).
do {
    let engine = row(60, 2400, "tt100:1:1", newer)             // user rewound LATER on this device
    let prior = row(800, 2400, "tt100:2:4", older)
    let merged = OwnerLibraryPositionPolicy.resolve(engine: engine, prior: prior)
    expect((merged["t"] as? Int) == 60, "newer backward seek propagates (t)")
    expect((merged["v"] as? String) == "tt100:1:1", "newer backward seek propagates (v)")
}

// 3. NEWER explicit finish-0 propagates, atomically with d and the clock.
do {
    let engine = row(0, 2400, "tt100:2:4", newer)              // finished later on this device
    let prior = row(800, 2400, "tt100:2:4", older)
    let merged = OwnerLibraryPositionPolicy.resolve(engine: engine, prior: prior)
    expect((merged["t"] as? Int) == 0, "newer finish-0 propagates")
    expect((merged["d"] as? Int) == 2400, "finish keeps its duration")
}

// 4. BARE re-add metadata cannot manufacture (or erase) a watch clock: prior position+clock survive
//    onto the fresh engine metadata, even when the engine row carries positive-looking zeros.
do {
    let engine: [String: Any] = ["id": "tt100", "name": "Fresh", "type": "movie", "poster": "q",
                                 "t": 0, "d": 0, "v": "", "lastWatched": ""]
    let prior = row(800, 2400, "tt100:2:4", newer)
    let merged = OwnerLibraryPositionPolicy.resolve(engine: engine, prior: prior)
    expect((merged["t"] as? Int) == 800 && (merged["d"] as? Int) == 2400, "bare re-add keeps prior t/d")
    expect((merged["v"] as? String) == "tt100:2:4", "bare re-add keeps prior episode id")
    expect(OwnerLibraryPositionPolicy.lastWatchedMillis(merged["lastWatched"]) > 0,
           "bare re-add keeps the prior real clock (never dropped, never minted)")
    expect((merged["name"] as? String) == "Fresh", "bare re-add refreshes display metadata from engine")
}

// 5. Episode CHANGE travels with the newer position as one atomic unit (never mixed fields).
do {
    let engine = row(500, 2400, "tt100:3:1", newer)            // peer moved on to S3E1, later
    let prior = row(800, 2400, "tt100:2:4", older)
    let merged = OwnerLibraryPositionPolicy.resolve(engine: engine, prior: prior)
    expect((merged["v"] as? String) == "tt100:3:1" && (merged["t"] as? Int) == 500,
           "newer episode change adopts the whole newer row (v+t together)")
}

// 6. Clock parsing: raw ms numbers and unparsable strings behave as designed.
do {
    expect(OwnerLibraryPositionPolicy.lastWatchedMillis(1_700_000_000_000 as NSNumber) > 0,
           "raw ms number parses as a clock")
    expect(OwnerLibraryPositionPolicy.lastWatchedMillis("garbage") == 0, "unparsable string is no clock")
    expect(OwnerLibraryPositionPolicy.lastWatchedMillis("") == 0 && OwnerLibraryPositionPolicy.lastWatchedMillis(nil as Any?) == 0,
           "empty/missing is no clock")
    expect(OwnerLibraryPositionPolicy.lastWatchedMillis("2026-09-10T22:30:00Z") ==
           OwnerLibraryPositionPolicy.lastWatchedMillis("2026-09-10T22:30:00.000Z"),
           "fractional and plain ISO forms agree")
}

// 7. A delayed cache pull cannot replace a newer cached atomic row.
do {
    expect(!OwnerLibraryPositionPolicy.shouldReplaceCachedPosition(existingClock: 200, incomingClock: 199),
           "older pulled cache row cannot roll back a newer cached position")
    expect(OwnerLibraryPositionPolicy.shouldReplaceCachedPosition(existingClock: 200, incomingClock: 200),
           "equal clock may refresh the same atomic observation")
    expect(!OwnerLibraryPositionPolicy.shouldReplaceCachedPosition(existingClock: 200, incomingClock: 0),
           "clock-less metadata cannot erase a cached causal clock")
}

print(failures == 0 ? "PASS owner-library position policy (\(checks) checks)" : "FAIL (\(failures)/\(checks))")
exit(failures == 0 ? 0 : 1)
}
}
