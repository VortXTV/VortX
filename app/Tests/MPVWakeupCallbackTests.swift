import Foundation
import os
import MPVWakeupProbe

// The production methods below are inserted literally by test-mpv-wakeup-callback.py.
// C registration uses the genuine selected libmpv header and calls the callback both inline
// and on a joined pthread. The counter replaces the relay's already-tested event scheduling;
// this fixture tests Swift's C/actor boundary, not renderer or shutdown behavior.
private final class WakeupRelay: Sendable {
    struct Counts: Sendable { var main = 0; var worker = 0 }
    private let counts = OSAllocatedUnfairLock(initialState: Counts())
    func signal() {
        counts.withLock {
            if Thread.isMainThread { $0.main += 1 } else { $0.worker += 1 }
        }
    }
    var observed: Counts { counts.withLock { $0 } }
}

private final class MPVNativeHandle: @unchecked Sendable {
    private struct Lifecycle: Sendable {
        var retired = false
        var relay: WakeupRelay?
    }
    private let lifecycle = OSAllocatedUnfairLock(initialState: Lifecycle())
    private let handle = OpaquePointer(bitPattern: 1)!

// @source:callback

// @source:install

    // Fixture-only cleanup after the C worker is joined; production retirement is not modeled.
    func detachAfterJoin() {
        mpv_set_wakeup_callback(handle, nil, nil)
        let relay = lifecycle.withLock { state -> WakeupRelay? in
            state.retired = true
            let relay = state.relay
            state.relay = nil
            return relay
        }
        if let relay { Unmanaged.passUnretained(relay).release() }
    }
}

@main
private struct MPVWakeupCallbackTests {
    @MainActor
    static func main() {
        MainActor.assertIsolated()
        let owner = MPVNativeHandle()
        let relay = WakeupRelay()
        owner.install(relay)
        precondition(relay.observed.main == 1 && relay.observed.worker == 0)
        print("PASS inline notification during MainActor registration")
        precondition(vx_probe_worker_wakeups(1, 0) == 0)
        precondition(relay.observed.main == 1 && relay.observed.worker == 1)
        print("PASS C callback on native background thread")
        precondition(vx_probe_worker_wakeups(100, 0) == 0)
        precondition(relay.observed.main == 1 && relay.observed.worker == 101)
        print("PASS repeated native notifications without MainActor assertion")
        precondition(vx_probe_worker_wakeups(1, 1) == 0)
        precondition(relay.observed.worker == 101)
        print("PASS nil callback context")
        owner.detachAfterJoin()
        precondition(vx_probe_worker_wakeups(1, 0) == 0)
        precondition(relay.observed.worker == 101)
        print("PASS detached callback receives no notification")
    }
}
