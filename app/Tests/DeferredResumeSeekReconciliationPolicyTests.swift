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
                && abandoned?.persistenceFloorSeconds == 1_041,
            "a failed deferred resume must reconcile UI to the low engine tick while retaining Continue Watching at the valid target"
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
        let field = DeferredResumeSeekReconciliationPolicy.abandonment(targetSeconds: 483,
            actualPositionSeconds: 2, landingToleranceSeconds: 5, watchdogStillOwnsGeneration: true)
        precondition(field?.presentationSeconds == 2 && field?.persistenceFloorSeconds == 483)
        precondition(field.map { $0.presentationSeconds + 0.1 } == 2.1)
        let stalled = DeferredResumeSeekReconciliationPolicy.abandonment(
            targetSeconds: 1_510.4, actualPositionSeconds: 1.12,
            landingToleranceSeconds: 5, watchdogStillOwnsGeneration: true
        )
        precondition(DeferredResumeSeekReconciliationPolicy.recoveryOrigin(
            presentationSeconds: 1_510.4, confirmedPositionSeconds: 1.12,
            abandonment: stalled, abandonmentOwnerIsCurrent: true
        ) == 1.12, "the diagnosed failed resume must never re-arm its optimistic target on same-source reload")
        precondition(stalled?.persistenceFloorSeconds == 1_510.4,
                     "recovery origin and Continue Watching floor must remain separate")
        precondition(DeferredResumeSeekReconciliationPolicy.recoveryOrigin(
            presentationSeconds: 1_510.4, confirmedPositionSeconds: .nan,
            abandonment: stalled, abandonmentOwnerIsCurrent: true
        ) == 1.12, "an invalid subsequent raw tick retains the owned proven origin")
        precondition(DeferredResumeSeekReconciliationPolicy.recoveryOrigin(
            presentationSeconds: 90, confirmedPositionSeconds: 1.12,
            abandonment: stalled, abandonmentOwnerIsCurrent: false
        ) == 90, "a retired source's abandonment cannot change the new source's recovery origin")
        precondition(DeferredResumeSeekReconciliationPolicy.recoveryOrigin(
            presentationSeconds: 1_510.4, confirmedPositionSeconds: 2.5,
            abandonment: stalled, abandonmentOwnerIsCurrent: true
        ) == 2.5, "natural playback progress supersedes the first proven abandonment position")
        precondition(DecoderResumeSeekabilityPolicy.permitsSeek(
            avPlayerActive: false, firstFrameRendered: false, runtimeSeekable: false
        ), "transient startup seekability must not disable normal VOD resume")
        precondition(!DecoderResumeSeekabilityPolicy.permitsSeek(
            avPlayerActive: false, firstFrameRendered: true, runtimeSeekable: false
        ), "a confirmed non-seekable mpv mount must not repeatedly receive the saved absolute seek")
        precondition(DecoderResumeSeekabilityPolicy.permitsSeek(
            avPlayerActive: true, firstFrameRendered: true, runtimeSeekable: false
        ), "forward-only AVPlayer remuxes retain logical-origin resume handling")
        precondition(DecoderResumeSeekabilityPolicy.permitsSeek(
            avPlayerActive: false, firstFrameRendered: true, runtimeSeekable: true
        ), "normal seekable mpv playback remains eligible")
        let floorBasedRetry = RetryResumeTargetPolicy.target(
            isLive: false, hasStartedPlaying: true, currentTimeSeconds: 1.12,
            activeRequestedResumeSeconds: 1_510.4, fallbackResumeSeconds: 1.12,
            persistenceFloorSeconds: stalled?.persistenceFloorSeconds
        )
        precondition(floorBasedRetry == 1_510.4, "ordinary retry keeps forward-remux persistence semantics")
        precondition(DeferredResumeSeekReconciliationPolicy.recoveryOrigin(
            presentationSeconds: floorBasedRetry, confirmedPositionSeconds: 1.12,
            abandonment: stalled, abandonmentOwnerIsCurrent: true
        ) == 1.12, "owned failed-seek recovery must override the floor-based retry on phone/Mac too")
        print("DeferredResumeSeekReconciliationPolicyTests: 17/17 passed")
    }
}
