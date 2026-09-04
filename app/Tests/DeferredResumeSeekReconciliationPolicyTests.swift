import Foundation

@main
private enum DeferredResumeSeekReconciliationPolicyTests {
    static func main() {
        let abandoned = DeferredResumeSeekReconciliationPolicy.abandonment(
            targetSeconds: 1_041,
            actualPositionSeconds: 3,
            landingToleranceSeconds: 5,
            watchdogStillOwnsGeneration: true
        )
        precondition(
            abandoned?.presentationSeconds == 3
                && abandoned?.persistenceSeconds == 3
                && abandoned?.retiresResumeFloor == true,
            "a failed deferred resume must reconcile UI and persistence to the first trustworthy low engine tick"
        )
        precondition(
            DeferredResumeSeekReconciliationPolicy.abandonment(
                targetSeconds: 1_041,
                actualPositionSeconds: 1_040,
                landingToleranceSeconds: 5,
                watchdogStillOwnsGeneration: true
            ) == nil,
            "a near-target tick proves the resume landed"
        )
        precondition(
            DeferredResumeSeekReconciliationPolicy.abandonment(
                targetSeconds: 1_041,
                actualPositionSeconds: -1,
                landingToleranceSeconds: 5,
                watchdogStillOwnsGeneration: true
            ) == nil,
            "an untrusted raw position cannot overwrite presentation or persistence"
        )
        precondition(
            DeferredResumeSeekReconciliationPolicy.abandonment(
                targetSeconds: 1_041,
                actualPositionSeconds: 3,
                landingToleranceSeconds: 5,
                watchdogStillOwnsGeneration: false
            ) == nil,
            "a superseded watchdog cannot reconcile a newer source generation"
        )
        print("DeferredResumeSeekReconciliationPolicyTests: 4/4 passed")
    }
}
