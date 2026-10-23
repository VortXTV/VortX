// Exact extracted production touch-cycle policy. This does not synthesize UIKit touches.
@main enum PlayerVideoTouchPolicyFixture {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    static func main() {
        var policy = PlayerVideoTouchPolicy<Int>()
        let first = policy.began([1])
        policy.finished([1])
        check(policy.consumeTap(first), "first ordinary tap must be delivered")
        check(!policy.consumeTap(first), "duplicate delivery must not toggle twice")

        let two = policy.began([2])
        _ = policy.began([3])
        let heldPinch = policy.claimPinch()!
        check(!policy.consumeTap(two), "multi-touch cycle cannot toggle controls")
        policy.finished([2, 3])
        check(policy.consumePinch(heldPinch), "completed pinch may deliver once")
        check(!policy.consumePinch(heldPinch), "duplicate pinch end cannot repeat action")
        check(!policy.consumeTap(two), "tap after pinch end remains suppressed in same cycle")

        let afterPinch = policy.began([4])
        policy.finished([4])
        check(policy.consumeTap(afterPinch), "first new tap after pinch must work")
        check(!policy.consumePinch(heldPinch), "held old pinch cannot consume new cycle")
        check(!policy.consumeTap(first), "held old tap cannot consume new cycle")

        let cancelled = policy.began([5, 6])
        _ = policy.claimPinch()
        policy.finished([5, 6]) // Cancellation clears active touches but not ownership.
        check(!policy.consumeTap(cancelled), "cancelled pinch must not become a tap")
        let afterCancel = policy.began([7])
        policy.finished([7])
        check(policy.consumeTap(afterCancel), "cancellation must not strand next tap")

        let failedMulti = policy.began([8, 9])
        policy.finished([8, 9]) // No pinch callback: a two-finger gesture still owns its cycle.
        check(!policy.consumeTap(failedMulti), "two touches cannot toggle even if pinch never begins")
        let afterFailed = policy.began([10])
        policy.finished([10])
        check(policy.consumeTap(afterFailed), "failed recognizer must not strand next tap")

        let interrupted = policy.began([11])
        policy.invalidate()
        check(!policy.consumeTap(interrupted), "dismantled view must reject held event")
        let remounted = policy.began([12])
        policy.finished([12])
        check(policy.consumeTap(remounted), "fresh cycle after invalidate remains usable")
        print("PASS exact touch ownership policy: first tap, duplicates, pinch completion/cancellation, failed multi-touch, held stale callbacks")
    }
}

