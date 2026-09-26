import Foundation

@main
enum PlaybackActiveTimeClockTests {
    static func main() {
        var clock = PlaybackActiveTimeClock()
        precondition(clock.value(at: 100) == 100 && !clock.isPaused)
        let deadline = clock.value(at: 100) + 12
        clock.setPaused(true, now: 105)
        precondition(clock.value(at: 405) == 105)
        clock.setPaused(true, now: 406) // duplicate explicit Pause must not shorten the suspension
        precondition(clock.value(at: 407) == 105)
        clock.setPaused(false, now: 407)
        precondition(clock.value(at: 413) == 111)
        precondition(clock.value(at: 414) == deadline)
        clock.setPaused(false, now: 415) // duplicate Play cannot add parked time twice
        precondition(clock.value(at: 415) == 113)
        clock.setPaused(true, now: 420)
        clock.setPaused(false, now: 450)
        precondition(clock.value(at: 450) == 118)
        var lease = PlaybackIdleTimerLease<Int>()
        precondition(!lease.owns(1))
        lease.claim(1)
        precondition(lease.owns(1))
        lease.claim(2) // replacement appears before the previous view's late disappearance
        precondition(!lease.release(1) && lease.owns(2))
        precondition(lease.release(2) && !lease.owns(2))
        precondition(!lease.release(2)) // late callback cannot reacquire/release a disappeared view
        lease.claim(3)
        clock.setPaused(true, now: 451)
        precondition(clock.isPaused && lease.owns(3)) // pause allows idle without losing presentation ownership
        clock.setPaused(false, now: 452)
        precondition(!clock.isPaused && lease.owns(3))
        print("PASS idle ownership survives stale view teardown and explicit pause/resume")
        print("PASS active-time deadlines retain their exact unpaused budget across repeated pauses")
    }
}
