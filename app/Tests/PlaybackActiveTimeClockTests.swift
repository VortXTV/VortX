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
        print("PASS active-time deadlines retain their exact unpaused budget across repeated pauses")
    }
}
