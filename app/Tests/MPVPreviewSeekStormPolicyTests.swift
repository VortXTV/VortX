import Foundation

// Standalone deterministic policy tests. No media, libmpv, network, timers, or devices.
// Compile only this file and Sources/Player/MPVPreviewSeekStormPolicy.swift.
@main
@MainActor
private enum MPVPreviewSeekStormPolicyTests {
    private typealias Storm = MPVPreviewSeekStormPolicy<Int>
    private static var failures = 0

    private static func check(_ name: String, _ value: @autoclosure () -> Bool) {
        if !value() {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    private static func sample(
        position: Double? = 0, seeking: Bool? = true, paused: Bool? = false,
        cache: Double? = 0, bytes: Int? = 0
    ) -> Storm.Sample {
        .init(position: position, seeking: seeking, paused: paused,
              cacheSeconds: cache, forwardBytes: bytes)
    }

    private static func armed(owner: Int = 1) -> Storm {
        var policy = Storm()
        policy.reset(owner: owner)
        check("first stalled sample never stops", !policy.observe(owner: owner, now: 10, sample: sample()))
        return policy
    }

    private static func seeks(_ count: Int, into policy: inout Storm, owner: Int = 1) {
        for _ in 0..<count { policy.recordNativeSeek(owner: owner) }
    }

    static func main() {
        var stall = armed()
        seeks(63, into: &stall)
        check("elapsed time alone is insufficient", !stall.observe(owner: 1, now: 12, sample: sample()))
        seeks(1, into: &stall)
        check("measured sustained storm contains once", stall.observe(owner: 1, now: 12, sample: sample()))
        check("failure owner retained", stall.hasFailed(owner: 1))
        check("failure never repeats", !stall.observe(owner: 1, now: 20, sample: sample()))
        stall.recordSettledPlayback(owner: 1)
        check("late settled event cannot undo containment", stall.hasFailed(owner: 1))

        var burst = armed()
        seeks(10_000, into: &burst)
        check("high event count alone is insufficient", !burst.observe(owner: 1, now: 11.999, sample: sample()))
        check("count and time together contain", burst.observe(owner: 1, now: 12, sample: sample()))

        for uncertain in [
            sample(position: nil), sample(position: .nan), sample(position: .infinity),
            sample(position: -1), sample(seeking: nil), sample(seeking: false),
            sample(paused: nil), sample(paused: true), sample(cache: nil),
            sample(cache: .nan), sample(cache: 0.001), sample(bytes: nil), sample(bytes: 1)
        ] {
            var policy = armed()
            seeks(100, into: &policy)
            check("unknown/paused/refilling sample cannot contain",
                  !policy.observe(owner: 1, now: 12, sample: uncertain))
            check("return from uncertainty starts a fresh window",
                  !policy.observe(owner: 1, now: 20, sample: sample()))
            check("pre-uncertainty seeks do not authorize a new window",
                  !policy.observe(owner: 1, now: 22, sample: sample()))
        }

        var playback = armed()
        seeks(100, into: &playback)
        playback.recordSettledPlayback(owner: 1)
        check("real settled playback clears the stall interval",
              !playback.observe(owner: 1, now: 12, sample: sample()))
        check("old seeks cannot stop resumed playback",
              !playback.observe(owner: 1, now: 14, sample: sample()))

        var normalLoops = Storm()
        normalLoops.reset(owner: 1)
        for cycle in 0..<200 {
            let now = Double(cycle)
            normalLoops.recordNativeSeek(owner: 1)
            check("normal full-file loop remains alive",
                  !normalLoops.observe(owner: 1, now: now, sample: sample()))
            normalLoops.recordSettledPlayback(owner: 1)
        }
        check("normal loops never latch failure", !normalLoops.hasFailed(owner: 1))

        var moving = armed()
        seeks(100, into: &moving)
        check("position movement starts a new evidence window",
              !moving.observe(owner: 1, now: 12, sample: sample(position: 0.251)))
        check("position movement retires preceding seek count",
              !moving.observe(owner: 1, now: 14, sample: sample(position: 0.251)))

        var successor = armed()
        seeks(100, into: &successor)
        successor.reset(owner: 2)
        check("stale sample cannot stop new load", !successor.observe(owner: 1, now: 12, sample: sample()))
        check("new load begins with a clean window", !successor.observe(owner: 2, now: 12, sample: sample()))
        seeks(100, into: &successor, owner: 1)
        check("stale native seeks cannot arm new load", !successor.observe(owner: 2, now: 14, sample: sample()))
        seeks(64, into: &successor, owner: 2)
        successor.recordSettledPlayback(owner: 1)
        check("stale progress cannot clear current storm", successor.observe(owner: 2, now: 14, sample: sample()))
        successor.reset(owner: nil)
        check("stop clears failure authority", !successor.hasFailed(owner: 2))
        check("post-stop sample inert", !successor.observe(owner: 2, now: 20, sample: sample()))

        var diagnostic = MPVNativeSeekDiagnosticPolicy<Int>()
        diagnostic.reset(owner: 1)
        for _ in 0..<4 {
            check("initial native events retained", diagnostic.admit(owner: 1, now: 0)?.suppressedEvents == 0)
        }
        for _ in 0..<10_000 {
            check("repeated native event samples bounded", diagnostic.admit(owner: 1, now: 0.1) == nil)
        }
        check("aggregate suppressed count retained",
              diagnostic.admit(owner: 1, now: 0.25)?.suppressedEvents == 10_000)
        check("same timestamp is bounded", diagnostic.admit(owner: 1, now: 0.25) == nil)
        check("old source cannot consume quota", diagnostic.admit(owner: 2, now: 0.5) == nil)
        check("next sample retains skipped count",
              diagnostic.admit(owner: 1, now: 0.5)?.suppressedEvents == 1)
        diagnostic.reset(owner: 2)
        check("successor's first event retained", diagnostic.admit(owner: 2, now: 0.5)?.suppressedEvents == 0)
        diagnostic.reset(owner: nil)
        check("invalidation blocks observations", diagnostic.admit(owner: 2, now: 1) == nil)

        guard failures == 0 else { exit(1) }
        print("MPVPreviewSeekStormPolicyTests: all checks passed")
    }
}
