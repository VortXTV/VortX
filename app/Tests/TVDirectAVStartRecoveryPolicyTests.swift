// Executable harness for the direct AVPlayer -> libmpv startup recovery decision.
//
// Run:
//   sed -n '/^enum TVDirectAVStartRecoveryPolicy {/,/^\/\/\/ Pure ownership and first-frame gates/p' \
//     app/SourcesTV/TVPlayerView.swift | sed '$d' > /tmp/tv-direct-av-start-policy.swift && \
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/tv-direct-av-start-policy-test \
//     /tmp/tv-direct-av-start-policy.swift \
//     app/Tests/TVDirectAVStartRecoveryPolicyTests.swift && \
//   /tmp/tv-direct-av-start-policy-test
//
// The harness compiles the production policy rather than duplicating its logic. It proves the exact
// recovery contract: AVPlayer gets the short first-frame chance, libmpv gets one bounded same-source
// chance, a cold resume gets one safe relative nudge, then only the current unframed libmpv load may
// advance to source failover.

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
private enum TVDirectAVStartRecoveryPolicyTests {
    @MainActor
    static func main() {
        typealias Policy = TVDirectAVStartRecoveryPolicy
        typealias NudgePolicy = TVLibMPVStartupNudgePolicy

        check(
            "no-frame AVPlayer then no-frame libmpv hops exactly once",
            Policy.fallbackTimedOut(
                recoveryRecorded: true,
                sourceStillCurrent: true,
                fallbackIsLibMPV: true,
                firstFrameRendered: false
            ) == .hop
        )
        check(
            "a stale source-generation timeout cannot hop a replacement source",
            Policy.fallbackTimedOut(
                recoveryRecorded: true,
                sourceStillCurrent: false,
                fallbackIsLibMPV: true,
                firstFrameRendered: false
            ) == .cancel
        )
        check(
            "the AVPlayer watchdog cannot consume the fallback hop before libmpv owns the load",
            Policy.fallbackTimedOut(
                recoveryRecorded: true,
                sourceStillCurrent: true,
                fallbackIsLibMPV: false,
                firstFrameRendered: false
            ) == .cancel
        )
        check(
            "a first frame makes the deferred fallback timer inert",
            Policy.fallbackTimedOut(
                recoveryRecorded: true,
                sourceStillCurrent: true,
                fallbackIsLibMPV: true,
                firstFrameRendered: true
            ) == .cancel
        )
        check(
            "ordinary libmpv load timeouts keep their existing ladder",
            Policy.fallbackTimedOut(
                recoveryRecorded: false,
                sourceStillCurrent: true,
                fallbackIsLibMPV: true,
                firstFrameRendered: false
            ) == .cancel
        )
        check(
            "a current cold direct-fallback resume receives one startup nudge",
            NudgePolicy.decision(
                recoveryRecorded: true,
                sourceStillCurrent: true,
                firstFrameRendered: false,
                nudgeAlreadyIssued: false
            ) == .nudge
        )
        check(
            "an unframed source after the one nudge hops instead of reloading",
            NudgePolicy.decision(
                recoveryRecorded: true,
                sourceStillCurrent: true,
                firstFrameRendered: false,
                nudgeAlreadyIssued: true
            ) == .hop
        )
        check(
            "a stale nudge task cannot affect the replacement source",
            NudgePolicy.decision(
                recoveryRecorded: true,
                sourceStillCurrent: false,
                firstFrameRendered: false,
                nudgeAlreadyIssued: false
            ) == .cancel
        )

        if failures > 0 { exit(1) }
    }
}
