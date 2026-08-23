// Executable harness for the B5 phase-1 input read-liveness policy.
//
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors
//     -o /tmp/read-liveness-policy-test
//     app/Sources/Player/VortXRemuxReadLivenessPolicy.swift
//     app/Tests/VortXRemuxReadLivenessPolicyTests.swift
//
// Pure policy harness: no FFmpeg, no AVFoundation, no cell types. It checks the
// watchdog sampling table the soft-interrupt decision depends on.

import Foundation

@MainActor private var failures = 0

@MainActor private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

@main
@MainActor
enum VortXRemuxReadLivenessPolicyTests {
    static func main() {
        disarmedWhenReadLoopInactive()
        disarmedOnCancellation()
        firstFlatSampleStartsTheClockWithoutFiring()
        movingBytesNeverFireAndResetTheClock()
        flatBelowTheThresholdDoesNotFire()
        flatAtTheThresholdFires()
        freshMountResetsTheWatchedCounter()
        print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        if failures > 0 { exit(1) }
    }

    static func disarmedWhenReadLoopInactive() {
        let v = VortXRemuxReadLivenessPolicy.sample(
            bytesRead: 100, readLoopActive: false, cancelled: false,
            watchedBytes: 100, blockedSinceUptime: 10, nowUptime: 100)
        check("an inactive read loop never fires and clears the episode",
              !v.fire && v.blockedSinceUptime == nil)
    }

    static func disarmedOnCancellation() {
        let v = VortXRemuxReadLivenessPolicy.sample(
            bytesRead: 100, readLoopActive: true, cancelled: true,
            watchedBytes: 100, blockedSinceUptime: 10, nowUptime: 100)
        check("cancellation never fires", !v.fire && v.blockedSinceUptime == nil)
    }

    static func firstFlatSampleStartsTheClockWithoutFiring() {
        let v = VortXRemuxReadLivenessPolicy.sample(
            bytesRead: 500, readLoopActive: true, cancelled: false,
            watchedBytes: 0, blockedSinceUptime: nil, nowUptime: 42)
        check("the first flat sample only arms the clock",
              !v.fire && v.blockedSinceUptime == 42 && v.watchedBytes == 500)
    }

    static func movingBytesNeverFireAndResetTheClock() {
        var watched: Int64 = 0
        var blocked: Double? = 40.0
        var everFired = false
        for tick in 41...46 {
            watched += 1_000_000
            let v = VortXRemuxReadLivenessPolicy.sample(
                bytesRead: watched, readLoopActive: true, cancelled: false,
                watchedBytes: watched - 1_000_000, blockedSinceUptime: blocked,
                nowUptime: Double(tick))
            if v.fire { everFired = true }
            blocked = v.blockedSinceUptime
        }
        check("moving bytes never fire", !everFired)
        check("moving bytes keep resetting the block clock", blocked == 46.0)
    }

    static func flatBelowTheThresholdDoesNotFire() {
        let v = VortXRemuxReadLivenessPolicy.sample(
            bytesRead: 7, readLoopActive: true, cancelled: false,
            watchedBytes: 7, blockedSinceUptime: 3, nowUptime: 7.9)
        check("flat under the threshold stays quiet",
              !v.fire && v.blockedSinceUptime == 3)
    }

    static func flatAtTheThresholdFires() {
        let bytes: Int64 = 1_000
        let arm = VortXRemuxReadLivenessPolicy.sample(
            bytesRead: bytes, readLoopActive: true, cancelled: false,
            watchedBytes: bytes, blockedSinceUptime: nil, nowUptime: 10)
        guard let armedAt = arm.blockedSinceUptime else {
            check("arming produces a block timestamp", false)
            return
        }
        let before = VortXRemuxReadLivenessPolicy.sample(
            bytesRead: bytes, readLoopActive: true, cancelled: false,
            watchedBytes: bytes, blockedSinceUptime: armedAt, nowUptime: armedAt + 4.9)
        check("flat below five seconds does not fire", !before.fire)
        let at = VortXRemuxReadLivenessPolicy.sample(
            bytesRead: bytes, readLoopActive: true, cancelled: false,
            watchedBytes: bytes, blockedSinceUptime: armedAt, nowUptime: armedAt + 5)
        check("flat at the five-second threshold fires", at.fire)
    }

    static func freshMountResetsTheWatchedCounter() {
        let v = VortXRemuxReadLivenessPolicy.sample(
            bytesRead: 50, readLoopActive: true, cancelled: false,
            watchedBytes: 999_999, blockedSinceUptime: 1, nowUptime: 2)
        check("a counter reset (fresh mount) reads as progress",
              !v.fire && v.watchedBytes == 50 && v.blockedSinceUptime == 2)
    }
}