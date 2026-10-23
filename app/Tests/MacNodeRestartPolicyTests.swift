import Foundation
import os

// Standalone regression fixture for MacNodeRestartPolicy and MacNodeRestartStatus.
// Compile with their complete literal declarations extracted from MacNodeServer.swift.
// Keep production declaration bodies/defaults unchanged; do not compile NodeServer.
// Every policy call injects virtual monotonic time and pause; no real sleep is used.
// This fixture starts no Process, sends no OS signal, and reads no files/preferences.
// It covers helper/status behavior, not server lifecycle, kernel reaping, or UI visibility.

private final class FakeChild: Sendable {
    private struct State: Sendable {
        var running: Bool
        var termCount = 0
    }
    private let state: OSAllocatedUnfairLock<State>
    private let exitsOnTERM: Bool

    init(running: Bool = true, exitsOnTERM: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(running: running))
        self.exitsOnTERM = exitsOnTERM
    }

    var isRunning: Bool { state.withLock { $0.running } }
    var termCount: Int { state.withLock { $0.termCount } }

    func requestTERM() {
        state.withLock {
            $0.termCount += 1
            if exitsOnTERM { $0.running = false }
        }
    }

    func exit() { state.withLock { $0.running = false } }
}

private final class VirtualClock {
    private(set) var now: TimeInterval = 0
    private(set) var pauses: [TimeInterval] = []

    func advance(_ duration: TimeInterval) {
        precondition(duration > 0 && duration <= 0.05)
        pauses.append(duration)
        now += duration
    }
}

private final class DeinitHook: Sendable {
    private let callback: @Sendable () -> Void
    init(_ callback: @escaping @Sendable () -> Void) { self.callback = callback }
    deinit { callback() }
}

@main enum MacNodeRestartPolicyTests {
    static func main() {
        alreadyExitedDoesNotSignal()
        cooperativeTERMDoesNotWait()
        resistantTERMReturnsBoundedFailure()
        observedExitDuringGraceSucceeds()
        statusUsesExactOwnerAndTracksLateExit()
        runningClosureMayReenterStatus()
        replacingSnapshotReleasesCapturesOutsideLock()
        clearingSnapshotReleasesCapturesOutsideLock()
        runningClosureRetainsExactOwnerUntilClear()
        print("PASS synthetic Mac restart policy/status: virtual TERM grace, checked snapshots, reentry, capture retirement, owner lifetime")
    }

    private static func request(_ child: FakeChild, clock: VirtualClock) -> Bool {
        MacNodeRestartPolicy.requestTermination(
            grace: 2,
            isRunning: { child.isRunning },
            terminate: { child.requestTERM() },
            now: { clock.now },
            pause: { clock.advance($0) }
        )
    }

    private static func alreadyExitedDoesNotSignal() {
        let child = FakeChild(running: false)
        let clock = VirtualClock()
        precondition(request(child, clock: clock))
        precondition(child.termCount == 0 && clock.pauses.isEmpty)
    }

    private static func cooperativeTERMDoesNotWait() {
        let child = FakeChild(exitsOnTERM: true)
        let clock = VirtualClock()
        precondition(request(child, clock: clock))
        precondition(child.termCount == 1 && !child.isRunning && clock.pauses.isEmpty)
    }

    private static func resistantTERMReturnsBoundedFailure() {
        let child = FakeChild()
        let clock = VirtualClock()
        var unrelatedWallClock: TimeInterval = 0
        let result = MacNodeRestartPolicy.requestTermination(
            grace: 2,
            isRunning: { child.isRunning },
            terminate: { child.requestTERM() },
            now: { clock.now },
            pause: {
                unrelatedWallClock = unrelatedWallClock >= 0 ? -50_000 : 100_000
                clock.advance($0)
            }
        )
        precondition(!result && child.isRunning && child.termCount == 1)
        precondition(clock.now == 2 && !clock.pauses.isEmpty && clock.pauses.count <= 42)
        precondition(unrelatedWallClock != 0)
    }

    private static func observedExitDuringGraceSucceeds() {
        let child = FakeChild()
        let clock = VirtualClock()
        let result = MacNodeRestartPolicy.requestTermination(
            grace: 2,
            isRunning: { child.isRunning },
            terminate: { child.requestTERM() },
            now: { clock.now },
            pause: {
                clock.advance($0)
                if clock.now >= 0.15 { child.exit() }
            }
        )
        precondition(result && !child.isRunning && child.termCount == 1)
        precondition(clock.now < 2)
    }

    private static func statusUsesExactOwnerAndTracksLateExit() {
        let status = MacNodeRestartStatus()
        let owner = FakeChild()
        let other = FakeChild()
        let clock = VirtualClock()
        precondition(!request(owner, clock: clock))
        status.record(owner: owner, isRunning: { owner.isRunning })
        precondition(status.matches(owner: owner) && !status.matches(owner: other))
        precondition(status.message == "Restart did not complete: the previous streaming server is still running. Try restarting again.")
        owner.exit()
        precondition(status.message == "Restart did not complete: the previous streaming server has exited. Try restarting again.")
        precondition(status.matches(owner: owner)) // late exit does not silently clear retained ownership
        status.clear()
        precondition(status.message == nil && !status.matches(owner: owner))
    }

    private static func runningClosureMayReenterStatus() {
        let status = MacNodeRestartStatus()
        let owner = FakeChild()
        status.record(owner: owner, isRunning: {
            status.clear()
            return owner.isRunning
        })
        // The first call may report its copied snapshot; the next call observes the clear.
        precondition(status.message?.contains("still running") == true)
        precondition(status.message == nil)
    }

    private static func replacingSnapshotReleasesCapturesOutsideLock() {
        let status = MacNodeRestartStatus()
        let prior = FakeChild()
        let next = FakeChild()
        let retired = OSAllocatedUnfairLock(initialState: 0)
        do {
            let hook = DeinitHook {
                precondition(status.matches(owner: next)) // re-enters the same status lock
                retired.withLock { $0 += 1 }
            }
            status.record(owner: prior, isRunning: { [hook, prior] in
                withExtendedLifetime(hook) { prior.isRunning }
            })
        }
        status.record(owner: next, isRunning: { next.isRunning })
        precondition(retired.withLock { $0 } == 1)
        status.clear()
    }

    private static func clearingSnapshotReleasesCapturesOutsideLock() {
        let status = MacNodeRestartStatus()
        let owner = FakeChild()
        let retired = OSAllocatedUnfairLock(initialState: 0)
        do {
            let hook = DeinitHook {
                precondition(status.message == nil) // re-enters the same status lock
                retired.withLock { $0 += 1 }
            }
            status.record(owner: owner, isRunning: { [hook, owner] in
                withExtendedLifetime(hook) { owner.isRunning }
            })
        }
        status.clear()
        precondition(retired.withLock { $0 } == 1)
    }

    private static func runningClosureRetainsExactOwnerUntilClear() {
        let status = MacNodeRestartStatus()
        weak var weakOwner: FakeChild?
        do {
            let owner = FakeChild()
            weakOwner = owner
            status.record(owner: owner, isRunning: { owner.isRunning })
        }
        precondition(weakOwner != nil && status.message?.contains("still running") == true)
        status.clear()
        precondition(weakOwner == nil)
    }
}
