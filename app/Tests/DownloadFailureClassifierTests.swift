// Executable harness for the download -3000 (NSURLErrorCannotCreateFile) save-failure recovery policy (#132).
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/download-failure-classifier-test \
//     app/SourcesShared/DownloadFailureClassifier.swift \
//     app/Tests/DownloadFailureClassifierTests.swift && /tmp/download-failure-classifier-test
//
// This suite CALLS the production decision (`DownloadFailureClassifier`), not a copy of it, so a mutation to
// the branch order, a threshold, or the ENOSPC check fails a case here. The classifier is the single lever that
// decides whether a completed-but-unsaved download RECOVERS (park on unlock, self-heal restart) or DEAD-ENDS,
// and #132 has already survived two false "fixed" claims, so the properties that matter most are:
//   - a LOCKED -3000 is ALWAYS parked and NEVER hard-fails (waiting for unlock is free and correct: an
//     overnight download must save in the morning, not fail at 3am);
//   - an UNLOCKED -3000 self-heals once, parks a few times, then HARD-FAILS once the cap is passed, so it must
//     TERMINATE, never loop re-downloading gigabytes forever (the defect this suite locks shut);
//   - genuine out-of-space (ENOSPC, top-level or underlying) hard-fails immediately instead of park-looping.

import Foundation

@MainActor var failures = 0
@MainActor func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

typealias Decision = DownloadFailureClassifier.SaveRetryDecision
let MAX = DownloadFailureClassifier.maxUnlockedSaveFailures   // production value (3)

func classify(_ p: Bool, _ o: Bool, _ n: Int) -> Decision {
    DownloadFailureClassifier.classifyCannotCreateFile(
        protectedDataAvailable: p, outOfSpace: o, unlockedSaveFailures: n, maxUnlockedSaveFailures: MAX)
}

func runUnlockedPersistent() -> [Decision] {
    var tally = 0
    var seq: [Decision] = []
    for _ in 0..<50 {   // hard ceiling: if the policy looped, we'd hit it and the assertions below would fail
        tally += 1                                   // unlocked && !oos -> increment first, as the manager does
        let d = classify(true, false, tally)
        seq.append(d)
        if d == .hardFail { break }
    }
    return seq
}

func runLockedPersistent() -> Bool {
    for _ in 0..<50 { if classify(false, false, 0) != .parkForUnlock { return false } }
    return true
}

@main
enum DownloadFailureClassifierTests {
    @MainActor static func main() { run() }
}

@MainActor func run() {

// ---- classify truth table --------------------------------------------------------------------------------

// LOCKED wins first: park regardless of out-of-space or tally.
check("locked, not-oos, n=0 -> park", classify(false, false, 0) == .parkForUnlock)
check("locked, oos, n=0 -> park (lock wins over oos)", classify(false, true, 0) == .parkForUnlock)
check("locked, not-oos, n=99 -> park (lock never hard-fails)", classify(false, false, 99) == .parkForUnlock)

// UNLOCKED + out-of-space: hard-fail immediately (a full volume is terminal, must not park-loop).
check("unlocked, oos, n=1 -> hardFail", classify(true, true, 1) == .hardFail)
check("unlocked, oos, n=99 -> hardFail", classify(true, true, 99) == .hardFail)

// UNLOCKED + not-oos: self-heal once, then park within the cap, then hard-fail past it.
check("unlocked, not-oos, n=1 -> selfHealRestart", classify(true, false, 1) == .selfHealRestart)
check("unlocked, not-oos, n=2 -> park", classify(true, false, 2) == .parkForUnlock)
check("unlocked, not-oos, n=3 (=cap) -> park", classify(true, false, MAX) == .parkForUnlock)
check("unlocked, not-oos, n=4 (>cap) -> hardFail", classify(true, false, MAX + 1) == .hardFail)
check("unlocked, not-oos, n=10 (>>cap) -> hardFail", classify(true, false, 10) == .hardFail)

// ---- isOutOfSpace ----------------------------------------------------------------------------------------

let enospcTop = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
let enospcUnder = NSError(domain: "tv.vortx.download", code: -3000,
                         userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
let plain3000 = NSError(domain: NSURLErrorDomain, code: -3000)
let permUnder = NSError(domain: "tv.vortx.download", code: -3000,
                        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
let generic = NSError(domain: "SomeOtherDomain", code: 42)

check("isOutOfSpace: top-level ENOSPC -> true", DownloadFailureClassifier.isOutOfSpace(enospcTop))
check("isOutOfSpace: underlying ENOSPC -> true", DownloadFailureClassifier.isOutOfSpace(enospcUnder))
check("isOutOfSpace: plain -3000 -> false", !DownloadFailureClassifier.isOutOfSpace(plain3000))
check("isOutOfSpace: underlying EACCES (not ENOSPC) -> false", !DownloadFailureClassifier.isOutOfSpace(permUnder))
check("isOutOfSpace: unrelated error -> false", !DownloadFailureClassifier.isOutOfSpace(generic))

// ---- termination: the anti-infinite-loop property --------------------------------------------------------
// runUnlockedPersistent mirrors DownloadManager's loop: each UNLOCKED, non-oos -3000 increments the tally
// BEFORE classify; a self-heal or park means the failure recurs, hard-fail stops it. Prove it TERMINATES and
// the sequence is exactly [selfHeal, park, park, hardFail] for the production cap (3).
let arc = runUnlockedPersistent()
check("unlocked-persistent -3000 TERMINATES (does not loop forever)", arc.last == .hardFail)
check("unlocked-persistent arc == [selfHeal, park, park, hardFail]",
      arc == [.selfHealRestart, .parkForUnlock, .parkForUnlock, .hardFail])

// A LOCKED-persistent -3000 must never hard-fail no matter how many times it recurs (tally never increments
// while locked): it parks every time and waits for the unlock that will let it save.
check("locked-persistent -3000 always parks, never hard-fails", runLockedPersistent())

// ----------------------------------------------------------------------------------------------------------
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
}
