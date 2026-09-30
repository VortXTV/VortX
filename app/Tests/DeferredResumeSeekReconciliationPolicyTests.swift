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
        var sequenceChecks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            sequenceChecks += 1
        }
        typealias Policy = DeferredResumeSeekReconciliationPolicy
        let a = Policy.OwnedAbandonment(owner: "A", decision: stalled!)
        let refused = Policy.afterAdmission(current: a, retiringOwner: "A", acceptedOwner: nil,
            preservingSourceChain: true, recoveryOriginSeconds: 1.12)
        check(refused == a, "refused replacement retains the old owner and exact retirement")
        let b = Policy.afterAdmission(current: a, retiringOwner: "A", acceptedOwner: "B",
            preservingSourceChain: true, recoveryOriginSeconds: 1.12)!
        check(b.owner == "B" && b.decision.persistenceFloorSeconds == 1_510.4,
              "same-source retry transfers retirement without losing saved progress")
        let staleRaw = Policy.confirmedPosition(seconds: 200, positionOwner: "A", currentOwner: "B",
            positionMountGeneration: 0, currentMountGeneration: 0)
        check(staleRaw.isNaN, "a new mount cannot use the old mount's position")
        let secondOrigin = Policy.recoveryOrigin(presentationSeconds: 1_510.4,
            confirmedPositionSeconds: staleRaw, abandonment: b.decision, abandonmentOwnerIsCurrent: true)
        check(secondOrigin == 1.12, "a second pre-frame failure cannot revive the abandoned 1510s target")
        let c = Policy.afterAdmission(current: b, retiringOwner: "B", acceptedOwner: "C",
            preservingSourceChain: true, recoveryOriginSeconds: secondOrigin)!
        check(c.owner == "C" && c.decision.presentationSeconds == 1.12,
              "retirement survives an arbitrary bounded automatic retry chain")
        let progressed = Policy.afterAdmission(current: b, retiringOwner: "B", acceptedOwner: "C",
            preservingSourceChain: true, recoveryOriginSeconds: 20)!
        check(Policy.recoveryOrigin(presentationSeconds: 1_510.4, confirmedPositionSeconds: .nan,
            abandonment: progressed.decision, abandonmentOwnerIsCurrent: true) == 20,
            "the newest proven recovery origin survives a replacement with no telemetry")
        check(Policy.afterAdmission(current: a, retiringOwner: "A", acceptedOwner: "D",
            preservingSourceChain: false, recoveryOriginSeconds: 90) == nil,
            "a new source or episode never inherits retirement authority")
        check(Policy.afterAdmission(current: a, retiringOwner: "B", acceptedOwner: "C",
            preservingSourceChain: true, recoveryOriginSeconds: 90) == nil,
            "a stale retirement cannot be rebound by an unrelated retry")
        check(Policy.confirmedPosition(seconds: 0, positionOwner: "B", currentOwner: "B",
            positionMountGeneration: 2, currentMountGeneration: 2) == 0,
            "an exact owned zero is valid evidence, not missing telemetry")
        check(Policy.confirmedPosition(seconds: 90, positionOwner: "B", currentOwner: "B",
            positionMountGeneration: 1, currentMountGeneration: 2).isNaN,
            "same-token AVPlayer item replacement invalidates old item telemetry")
        check(Policy.confirmedPosition(seconds: 90, positionOwner: "B", currentOwner: nil as String?,
            positionMountGeneration: 2, currentMountGeneration: 2).isNaN,
            "an absent owner cannot confirm a position")
        let manualFloor = Policy.floorAfterUserSeek(currentFloor: 1_510.4, abandonment: b, currentOwner: "B")
        check(manualFloor == nil, "manual seek retires the abandoned floor before any no-timer early return")
        check(RetryResumeTargetPolicy.target(isLive: false, hasStartedPlaying: true, currentTimeSeconds: 90,
            activeRequestedResumeSeconds: 1.12, fallbackResumeSeconds: 1.12,
            persistenceFloorSeconds: manualFloor) == 90, "manual backward seek remains the next recovery origin")
        check(Policy.floorAfterUserSeek(currentFloor: 1_510.4, abandonment: a, currentOwner: "B") == 1_510.4,
              "a stale owner's manual retirement cannot erase another source's progress floor")
        check(Policy.floorAfterAutomaticResume(currentFloor: 1_510.4, abandonment: b,
            currentOwner: "B", proposedFloor: nil) == 1_510.4,
            "a satisfied low remux origin does not authorize regressing Continue Watching")
        check(Policy.floorAfterAutomaticResume(currentFloor: 1_510.4, abandonment: a,
            currentOwner: "B", proposedFloor: nil) == nil, "old retirement cannot hold another source's floor")

        func context(engine: Policy.Engine = .libmpv, episode: Int = 1, source: Int = 2,
                     resume: Int = 3, videoID: String = "show:1:1", url: String = "https://example.test/file",
                     headers: [String: String]? = nil, live: Bool = false) -> Policy.SurfaceContext {
            .init(episodeGeneration: episode, sourceGeneration: source, resumeGeneration: resume,
                  libraryID: "show", videoID: videoID, sourceURL: URL(string: url)!, headers: headers,
                  isLive: live, engine: engine)
        }
        var transfer = Policy.surfaceTransfer(current: a, retiringOwner: "A", context: context(),
                                              recoveryOriginSeconds: 20)
        check(transfer?.retiring.decision.presentationSeconds == 20,
              "engine retirement captures the new proven origin before stop invalidates its token")
        check(Policy.surfaceTransfer(current: a, retiringOwner: "B", context: context(),
            recoveryOriginSeconds: 20) == nil, "only the actual retiring owner may prepare a handoff")
        check(Policy.consumeSurfaceTransfer(pending: &transfer, observedOwner: "A", activeOwner: "B",
            context: context()) == nil && transfer != nil, "outgoing queued callbacks cannot consume a handoff")
        check(Policy.consumeSurfaceTransfer(pending: &transfer, observedOwner: "A", activeOwner: "A",
            context: context()) == nil && transfer != nil, "the retiring surface cannot adopt itself")
        let staleContexts = [context(engine: .avPlayer), context(episode: 9), context(source: 9),
            context(resume: 9), context(videoID: "show:1:2"), context(url: "https://example.test/other"),
            context(headers: ["X-Test": "other"]), context(live: true)]
        for staleContext in staleContexts {
            check(Policy.consumeSurfaceTransfer(pending: &transfer, observedOwner: "B", activeOwner: "B",
                context: staleContext) == nil && transfer != nil,
                "engine, episode, source, resume, exact media, URL, headers and liveness each fence a handoff")
        }
        let adopted = Policy.consumeSurfaceTransfer(pending: &transfer, observedOwner: "B", activeOwner: "B",
                                                    context: context())!
        check(adopted.owner == "B" && adopted.decision.presentationSeconds == 20 && transfer == nil,
              "first exact replacement callback, including an error-before-time, adopts once")
        check(Policy.consumeSurfaceTransfer(pending: &transfer, observedOwner: "B", activeOwner: "B",
            context: context()) == nil, "a later mount receipt cannot re-adopt or reset the new raw position")
        check(Policy.confirmedPosition(seconds: 21, positionOwner: "B", currentOwner: "B",
            positionMountGeneration: 0, currentMountGeneration: 0) == 21,
            "telemetry produced before the later mount receipt stays authoritative")
        var nextTransfer = Policy.surfaceTransfer(current: adopted, retiringOwner: "B",
            context: context(engine: .avPlayer, resume: 4), recoveryOriginSeconds: 21)
        let next = Policy.consumeSurfaceTransfer(pending: &nextTransfer, observedOwner: "C", activeOwner: "C",
                                                context: context(engine: .avPlayer, resume: 4))!
        check(next.owner == "C" && next.decision.presentationSeconds == 21,
              "AV to MPV to AV switches retain the newest owned recovery origin")
        check(next.decision.persistenceFloorSeconds == 1_510.4,
              "engine and retry chains retain the original Continue Watching anti-regression floor")
        let media = Policy.MediaIdentity(libraryID: "show", videoID: "show:1:1")
        let nextMedia = Policy.MediaIdentity(libraryID: "show", videoID: "show:1:2")
        let protectedProgress = Policy.RetiredPersistenceFloor(media: media, seconds: 1_510.4)
        let hoppedFloor = Policy.persistenceFloorForSourceReplacement(currentFloor: 1_510.4,
            previousMedia: media, nextMedia: media)
        check(hoppedFloor == 1_510.4, "a same-episode source hop retains the valid saved progress")
        check(!DeferredResumeFloorPolicy.allowsPersistence(positionSeconds: 1.12, currentFloor: hoppedFloor),
              "accepted low progress from the new source cannot overwrite Continue Watching")
        let hopRecoveryFloor = Policy.recoveryEligibleFloor(currentFloor: hoppedFloor,
            retirement: protectedProgress, currentMedia: media)
        check(hopRecoveryFloor == nil, "the retained media-owned floor cannot choose a new source's retry target")
        check(RetryResumeTargetPolicy.target(isLive: false, hasStartedPlaying: false, currentTimeSeconds: 1.12,
            activeRequestedResumeSeconds: 1.12, fallbackResumeSeconds: 1_510.4,
            persistenceFloorSeconds: hopRecoveryFloor) == 1.12,
            "new-source pre-frame failure retries its own low origin without reviving old progress")
        check(Policy.floorAfterAutomaticResume(currentFloor: hoppedFloor, abandonment: nil as Policy.OwnedAbandonment<String>?,
            currentOwner: "B", proposedFloor: nil, retirement: protectedProgress, currentMedia: media) == 1_510.4,
            "native remux satisfaction also retains a persistence-only source-hop floor")
        check(Policy.persistenceFloorForSourceReplacement(currentFloor: 1_510.4,
            previousMedia: media, nextMedia: nextMedia) == nil,
            "a different episode inherits neither saved floor nor recovery eligibility")
        check(Policy.persistenceFloorForSourceReplacement(currentFloor: 1_510.4,
            previousMedia: nil, nextMedia: nil) == nil, "missing media identity cannot authorize carrying progress")
        check(Policy.retirementAfterMediaAdmission(current: protectedProgress, admittedMedia: media) == protectedProgress,
              "same-episode retirement follows a new accepted source")
        check(Policy.retirementAfterMediaAdmission(current: protectedProgress, admittedMedia: nextMedia) == nil,
              "accepted different media retires old floor authority")
        check(Policy.recoveryEligibleFloor(currentFloor: 1_800, retirement: protectedProgress,
            currentMedia: media) == 1_800, "a newer higher legitimate resume is not retired by an older floor")
        check(Policy.recoveryEligibleFloor(currentFloor: 1_510.4, retirement: protectedProgress,
            currentMedia: nextMedia) == 1_510.4, "retirement cannot silently change another episode's retry semantics")
        let terminalRetirement = Policy.afterAdmission(current: a, retiringOwner: "A", acceptedOwner: "A",
            preservingSourceChain: true, recoveryOriginSeconds: 20)!
        let terminalOrigin = Policy.recoveryOrigin(presentationSeconds: 1_510.4,
            confirmedPositionSeconds: .nan, abandonment: terminalRetirement.decision,
            abandonmentOwnerIsCurrent: true)
        check(terminalOrigin == 20, "terminal stop retains the last proven origin before retiring item telemetry")
        check(RetryResumeTargetPolicy.ownedRequestedResume(activeOwner: nil, attemptOwner: "A",
            terminalRetiredOwner: "A", requestedResumeSeconds: 20) == 20,
            "the exact recorded terminal owner remains usable while no active replacement exists")
        let terminalRetry = Policy.afterAdmission(current: terminalRetirement, retiringOwner: "A", acceptedOwner: "C",
            preservingSourceChain: true, recoveryOriginSeconds: terminalOrigin)!
        let followingRetry = Policy.afterAdmission(current: terminalRetry, retiringOwner: "C", acceptedOwner: "D",
            preservingSourceChain: true, recoveryOriginSeconds: terminalRetry.decision.presentationSeconds)!
        check(followingRetry.owner == "D" && followingRetry.decision.presentationSeconds == 20,
              "terminal stop, manual Retry, and another pre-frame failure preserve the chosen low origin")
        check(followingRetry.decision.persistenceFloorSeconds == 1_510.4,
              "terminal recovery never regresses the protected Continue Watching point")
        check(RetryResumeTargetPolicy.ownedRequestedResume(activeOwner: "C", attemptOwner: "A",
            terminalRetiredOwner: "A", requestedResumeSeconds: 20) == nil,
            "a newer active source always overrides stale terminal ownership")
        print("DeferredResumeSeekReconciliationPolicyTests: \(17 + sequenceChecks)/\(17 + sequenceChecks) passed")
    }
}
