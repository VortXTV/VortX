// Executable harness for the tvOS AVPlayer startup-watchdog phase transition.
//
// The policy and engine signal are dependency-free production declarations. Extract both exact declarations,
// then compile them with this harness:
//
//   sed -n '/^enum TVAVStartWatchdogPolicy {/,/^\\/\\/\\/ Full-screen libmpv player/p' \
//     app/SourcesTV/TVPlayerView.swift | sed '$d' > /tmp/tv-av-start-watchdog-policy.swift && \
//   sed -n '/^struct AVPlayerRemuxStartupSignal:/,/^\\/\\/\\/ AVFoundation implementation/p' \
//     app/Sources/Player/AVPlayerEngine.swift | sed '$d' >> /tmp/tv-av-start-watchdog-policy.swift && \
//   xcrun swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/tv-av-start-watchdog-policy-test \
//     /tmp/tv-av-start-watchdog-policy.swift \
//     app/Tests/TVAVStartWatchdogPolicyTests.swift && \
//   /tmp/tv-av-start-watchdog-policy-test
//
// This exercises the production decision, not a mirrored test implementation. Boundary pairs make changing
// either timeout or reverting to a one-shot mount sample fail loudly.

import Foundation

private typealias Policy = TVAVStartWatchdogPolicy
private typealias Signal = AVPlayerRemuxStartupSignal
private typealias StartPolicy = TVPlaybackStartPolicy

@MainActor private var failures = 0

@MainActor
private func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func decision(
    elapsed: Double,
    signal: Signal,
    surfaceExpected: Bool = false,
    ownerCurrent: Bool = true,
    directTimeout: Double,
    remuxAttachTimeout: Double
) -> Policy.AwaitingMountDecision {
    Policy.awaitingMountDecision(
        elapsed: elapsed,
        ownerCurrent: ownerCurrent,
        remuxMounted: signal.mounted,
        remuxExpected: surfaceExpected || signal.pendingOrMounted,
        directTimeout: directTimeout,
        remuxAttachTimeout: remuxAttachTimeout)
}

@main
private enum TVAVStartWatchdogPolicyTests {
    @MainActor
    static func main() {
        let directTimeout = 10.0
        let controlResourceTimeout = 15.0
        let signallingTimeout = 12.0
        let remuxAttachTimeout = Policy.remoteAttachTimeout(
            controlResourceTimeout: controlResourceTimeout,
            signallingTimeout: signallingTimeout)
        check(
            "attach budget: covers resource, signalling and scheduling margin",
            remuxAttachTimeout == 30)
        check(
            "attach budget: clamps invalid stage budgets without losing the margin",
            Policy.remoteAttachTimeout(
                controlResourceTimeout: -1,
                signallingTimeout: -1) == Policy.remoteAttachSchedulingMarginSeconds)
        let directSignal = Signal(
            itemGeneration: 1,
            pendingGeneration: nil,
            mounted: false)

        // Direct/native AVPlayer retains the old short deadline exactly.
        check("direct: initial signal is not pending", !directSignal.pendingOrMounted)
        check(
            "direct: just before 10s keeps waiting",
            decision(
                elapsed: directTimeout - 0.001,
                signal: directSignal,
                directTimeout: directTimeout,
                remuxAttachTimeout: remuxAttachTimeout
            ) == .keepWaiting
        )
        check(
            "direct: exactly 10s demotes",
            decision(
                elapsed: directTimeout,
                signal: directSignal,
                directTimeout: directTimeout,
                remuxAttachTimeout: remuxAttachTimeout
            ) == .demote
        )

        // A route known by the surface to require a remux keeps the bounded attach grace.
        check(
            "expected remux: exactly 10s keeps waiting for async attach",
            decision(
                elapsed: directTimeout,
                signal: directSignal,
                surfaceExpected: true,
                directTimeout: directTimeout,
                remuxAttachTimeout: remuxAttachTimeout
            ) == .keepWaiting
        )

        // The raw item starts direct. At t=1 its -11828 handler retries through hosted plain remux under the
        // same logical load token and a new item generation. Polling the engine signal must observe that change.
        var retrySignal = Signal(
            itemGeneration: 2,
            pendingGeneration: 2,
            mounted: false)
        check("dynamic retry: pending signal appears at t=1", retrySignal.pendingOrMounted)
        check(
            "dynamic retry: t=1 remains inside the direct budget",
            decision(
                elapsed: 1,
                signal: retrySignal,
                directTimeout: directTimeout,
                remuxAttachTimeout: remuxAttachTimeout
            ) == .keepWaiting
        )
        check(
            "dynamic retry: pending at exactly 10s keeps attach grace",
            decision(
                elapsed: directTimeout,
                signal: retrySignal,
                directTimeout: directTimeout,
                remuxAttachTimeout: remuxAttachTimeout
            ) == .keepWaiting
        )
        retrySignal = Signal(
            itemGeneration: 2,
            pendingGeneration: 2,
            mounted: true)
        check(
            "dynamic retry: attach at 10.5s transitions to progress monitoring",
            decision(
                elapsed: directTimeout + 0.5,
                signal: retrySignal,
                directTimeout: directTimeout,
                remuxAttachTimeout: remuxAttachTimeout
            ) == .monitorRemux
        )

        // A mount that never appears remains bounded and cannot turn into the 120-second progress ceiling.
        let pendingSignal = Signal(
            itemGeneration: 2,
            pendingGeneration: 2,
            mounted: false)
        check(
            "pending remux: just before attach deadline keeps waiting",
            decision(
                elapsed: remuxAttachTimeout - 0.001,
                signal: pendingSignal,
                directTimeout: directTimeout,
                remuxAttachTimeout: remuxAttachTimeout
            ) == .keepWaiting
        )
        check(
            "pending remux: no attach at exact derived deadline demotes",
            decision(
                elapsed: remuxAttachTimeout,
                signal: pendingSignal,
                directTimeout: directTimeout,
                remuxAttachTimeout: remuxAttachTimeout
            ) == .demote
        )

        // Runtime mount truth wins at every boundary, including the final poll at the attach deadline.
        let mountedSignal = Signal(
            itemGeneration: 3,
            pendingGeneration: nil,
            mounted: true)
        check(
            "runtime mount: exact attach deadline still transitions instead of demoting",
            decision(
                elapsed: remuxAttachTimeout,
                signal: mountedSignal,
                directTimeout: directTimeout,
                remuxAttachTimeout: remuxAttachTimeout
            ) == .monitorRemux
        )
        check(
            "runtime mount: unexpected remux also transitions",
            decision(
                elapsed: directTimeout,
                signal: mountedSignal,
                directTimeout: directTimeout,
                remuxAttachTimeout: remuxAttachTimeout
            ) == .monitorRemux
        )

        // The pending stamp belongs to item generation 2. Generation 3 is a fresh direct item, so that old
        // stamp cannot grant attach grace. The old watchdog also loses authority with its logical load token.
        let stalePendingSignal = Signal(
            itemGeneration: 3,
            pendingGeneration: 2,
            mounted: false)
        check("stale generation: pending signal is ignored", !stalePendingSignal.pendingOrMounted)
        check(
            "stale generation: current direct load still demotes at 10s",
            decision(
                elapsed: directTimeout,
                signal: stalePendingSignal,
                directTimeout: directTimeout,
                remuxAttachTimeout: remuxAttachTimeout
            ) == .demote
        )
        check(
            "stale owner: old pending watchdog cannot extend the new load",
            decision(
                elapsed: directTimeout,
                signal: pendingSignal,
                ownerCurrent: false,
                directTimeout: directTimeout,
                remuxAttachTimeout: remuxAttachTimeout
            ) == .cancel
        )
        check(
            "stale owner: old pending watchdog cannot demote the new load",
            decision(
                elapsed: remuxAttachTimeout,
                signal: pendingSignal,
                ownerCurrent: false,
                directTimeout: directTimeout,
                remuxAttachTimeout: remuxAttachTimeout
            ) == .cancel
        )

        check(
            "first frame: AVPlayer render proof commits playback while its clock is still zero",
            StartPolicy.hasStarted(positionSeconds: 0, avPlayerRenderedFrame: true)
        )
        check(
            "first frame: zero without render proof remains unstarted",
            !StartPolicy.hasStarted(positionSeconds: 0, avPlayerRenderedFrame: false)
        )
        check(
            "first frame: positive libmpv time still commits without AVPlayer proof",
            StartPolicy.hasStarted(positionSeconds: 0.001, avPlayerRenderedFrame: false)
        )
        check(
            "pending advance: zero-clock AVPlayer frame reaches first-frame commit",
            !StartPolicy.shouldIgnoreIssuedAdvanceTick(
                positionSeconds: 0,
                avPlayerRenderedFrame: true)
        )
        check(
            "pending advance: zero-clock tick without render proof remains ignored",
            StartPolicy.shouldIgnoreIssuedAdvanceTick(
                positionSeconds: 0,
                avPlayerRenderedFrame: false)
        )

        check(
            "load timeout: an active AVPlayer remux defers to its progress-aware watchdog",
            StartPolicy.genericLoadTimeoutDefersToRemuxWatchdog(
                avPlayerActive: true,
                remuxPendingOrMounted: true)
        )
        check(
            "load timeout: direct AVPlayer still uses the generic timeout",
            !StartPolicy.genericLoadTimeoutDefersToRemuxWatchdog(
                avPlayerActive: true,
                remuxPendingOrMounted: false)
        )
        check(
            "load timeout: libmpv never defers to the AVPlayer remux watchdog",
            !StartPolicy.genericLoadTimeoutDefersToRemuxWatchdog(
                avPlayerActive: false,
                remuxPendingOrMounted: true)
        )

        check(
            "load timeout: the exact episode, source, retry and token owner may fire",
            StartPolicy.loadTimeoutOwnerIsCurrent(
                capturedEpisodeGeneration: 3,
                currentEpisodeGeneration: 3,
                capturedSourceGeneration: 4,
                currentSourceGeneration: 4,
                capturedResumeGeneration: 5,
                currentResumeGeneration: 5,
                capturedLoadToken: 6,
                currentLoadToken: 6)
        )
        check(
            "load timeout: a new source generation retires the old timer",
            !StartPolicy.loadTimeoutOwnerIsCurrent(
                capturedEpisodeGeneration: 3,
                currentEpisodeGeneration: 3,
                capturedSourceGeneration: 4,
                currentSourceGeneration: 5,
                capturedResumeGeneration: 5,
                currentResumeGeneration: 5,
                capturedLoadToken: 6,
                currentLoadToken: 6)
        )
        check(
            "load timeout: a new logical load token retires the old timer",
            !StartPolicy.loadTimeoutOwnerIsCurrent(
                capturedEpisodeGeneration: 3,
                currentEpisodeGeneration: 3,
                capturedSourceGeneration: 4,
                currentSourceGeneration: 4,
                capturedResumeGeneration: 5,
                currentResumeGeneration: 5,
                capturedLoadToken: 6,
                currentLoadToken: 7)
        )
        check(
            "load timeout: a pre-mount timer adopts the first token only while every generation remains exact",
            StartPolicy.loadTimeoutOwnerIsCurrent(
                capturedEpisodeGeneration: 3,
                currentEpisodeGeneration: 3,
                capturedSourceGeneration: 4,
                currentSourceGeneration: 4,
                capturedResumeGeneration: 5,
                currentResumeGeneration: 5,
                capturedLoadToken: Optional<Int>.none,
                currentLoadToken: 7)
        )

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
