// swiftc -warnings-as-errors app/SourcesShared/DiagnosticPlaybackIntegrityPolicy.swift \
//   app/Tests/DeferredResumeUserSeekPolicyTests.swift -o <test-binary>
import Foundation

@main enum DeferredResumeUserSeekPolicyTests {
    static func main() {
        typealias P = DeferredResumeUserSeekPolicy
        func decide(_ intent: P.Intent, pending: Double? = 2260.258,
                    unsettled: Double? = nil, framed: Bool = false,
                    duration: Double = 3000) -> P.Decision {
            P.decision(intent: intent, pendingTarget: pending, unsettledTarget: unsettled,
                       firstFrameRendered: framed, duration: duration)
        }
        precondition(decide(.relative(10)) == .deferred(2270.258))
        precondition(decide(.relative(10), pending: 2270.258) == .deferred(2280.258))
        precondition(decide(.absolute(600)) == .deferred(600))
        precondition(decide(.absolute(0)) == .startAtBeginning)
        precondition(decide(.relative(-3000)) == .startAtBeginning)
        precondition(decide(.relative(10), pending: nil, unsettled: 2260.258, framed: true) == .absolute(2270.258))
        precondition(decide(.absolute(0), pending: nil, unsettled: 2260.258, framed: true) == .absolute(0))
        precondition(decide(.relative(10), pending: nil, framed: true) == .normal)
        precondition(decide(.relative(10), pending: nil) == .normal, "reset/cancel must not revive old resume")
        precondition(decide(.relative(10), framed: true) == .normal, "stale pre-frame target is not an owner")
        precondition(decide(.absolute(9000)) == .deferred(2999))
        precondition(decide(.relative(10), duration: 0) == .deferred(2270.258))
        precondition(decide(.relative(.infinity)) == .ignore)
        precondition(decide(.absolute(.nan)) == .ignore)
        precondition(decide(.relative(.greatestFiniteMagnitude), pending: .greatestFiniteMagnitude) == .ignore)
        for editedTarget in [0.0, 2270.258] {
            let owned = RetryResumeTargetPolicy.ownedRequestedResume(
                activeOwner: 7, attemptOwner: 7, terminalRetiredOwner: nil,
                requestedResumeSeconds: editedTarget)
            let retry = RetryResumeTargetPolicy.target(
                isLive: false, hasStartedPlaying: false, currentTimeSeconds: 0,
                activeRequestedResumeSeconds: owned, fallbackResumeSeconds: 2260.258,
                persistenceFloorSeconds: nil)
            precondition(retry == editedTarget, "retry must retain edited/zero target, not launch resume")
            precondition(RetryResumeTargetPolicy.ownedRequestedResume(
                activeOwner: 8, attemptOwner: 7, terminalRetiredOwner: nil,
                requestedResumeSeconds: editedTarget) == nil, "new owner must not inherit edited old resume")
        }
        print("PASS deferred resume input: logical relative, repeated input, zero/cancel, warm replacement, bounds and invalid values")
    }
}
