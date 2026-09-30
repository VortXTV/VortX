import Foundation

@main
private enum TVDeferredResumeRecoveryWiringContractTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        let tv = try String(contentsOf: root.appendingPathComponent("app/SourcesTV/TVPlayerView.swift"), encoding: .utf8)
        let apple = try String(contentsOf: root.appendingPathComponent("app/Sources/PlayerScreen.swift"), encoding: .utf8)
        func body(_ start: String, _ end: String) -> String {
            guard let a = tv.range(of: start),
                  let b = tv.range(of: end, range: a.upperBound..<tv.endIndex) else {
                preconditionFailure("missing production boundary: \(start)")
            }
            return String(tv[a.lowerBound..<b.lowerBound])
        }
        let reload = body("private func reloadAtPlayhead()", "private func presentTerminalLoadFailure()")
        precondition(reload.contains("let recoveryOrigin = recoveryResumeTarget()")
                     && reload.contains("preservingAbandonedResume: true")
                     && reload.contains("resumeSeconds = recoveryOrigin")
                     && reload.contains("resumeOrigin: recoveryOrigin"),
                     "same-source replacement must consume the exact-owner proven origin, not the persistence floor")
        let reconciliation = body("private func reconcileUnavailableResume(", "private func armPostFrameResumeSeekWatchdog(")
        precondition(reconciliation.contains("watchdogStillOwnsGeneration: coordinator.player?.activeLoadToken == owner")
                     && reconciliation.contains("clearPostFrameResumeSeekWatchdog()")
                     && reconciliation.contains("inFlightSeekTarget = nil")
                     && reconciliation.contains("pendingLibmpvResumeSeek = nil"),
                     "unavailable resume must retire all pending seek state for the exact load")
        precondition(reconciliation.contains("resumeSeconds = reconciliation.presentationSeconds")
                     && reconciliation.contains("suppressedResumeFloor = max(suppressedResumeFloor ?? 0, reconciliation.persistenceFloorSeconds)"),
                     "recovery target and persistence floor must remain separate")
        precondition(reconciliation.contains("if permitsDecoderResumeSeek {")
                     && reconciliation.contains("seekForResume(to: reconciliation.presentationSeconds + 0.1)"),
                     "the bounded recovery nudge cannot seek a known non-seekable mpv mount")
        let firstFrame = body("if let t = pendingLibmpvResumeSeek", "// FIRST-FRAME COMMIT")
        precondition(firstFrame.contains("if permitsDecoderResumeSeek {")
                     && firstFrame.contains("reconcileUnavailableResume(target: t, actualPosition: d, owner: event.loadToken)"),
                     "first-frame admission must not blindly apply an unavailable saved offset")
        let accepted = body("if let issuedToken {\n            cancelEmptySourceRecovery()", "if pendingAdvance != nil")
        precondition(accepted.contains("DeferredResumeSeekReconciliationPolicy.afterAdmission(")
                     && accepted.contains("preservingSourceChain: preservingAbandonedResume")
                     && accepted.contains("resetRawPosition(owner: issuedToken)")
                     && accepted.contains("pendingResumeSurfaceTransfer = nil")
                     && accepted.contains("isSeekable = true"),
                     "only native admission transfers or retires recovery authority and resets old position evidence")
        let manual = body("private func cancelPendingLibmpvResumeForUserSeek()", "/// Returns true when input")
        precondition(manual.range(of: "retireAbandonedResumeForUserSeek()")!.lowerBound
                     < manual.range(of: "guard let oldTarget else")!.lowerBound,
                     "an explicit user destination must retire abandonment even after its timer is gone")
        let seekability = body("case MPVProperty.seekable:", "case MPVProperty.videoParamsSigPeak:")
        precondition(seekability.contains("loadToken == coordinator.player?.activeLoadToken"),
                     "an old source cannot change the new mount's runtime seekability")
        precondition(apple.contains("midPlayFailureResume = reconciliation.presentationSeconds")
                     && apple.contains("DecoderResumeSeekabilityPolicy.permitsSeek("),
                     "phone/Mac must also retire the abandoned logical target and protect non-seekable nudges")
        precondition(apple.contains("let target = RetryResumeTargetPolicy.target(")
                     && apple.contains("return DeferredResumeSeekReconciliationPolicy.recoveryOrigin(")
                     && apple.contains("abandonmentOwnerIsCurrent: abandonedResumeRecovery?.owner == activeLoadToken"),
                     "phone/Mac same-source retries cannot re-arm the saved floor after owned abandonment")
        precondition(apple.contains("abandonedResumeRecovery = nil")
                     && apple.contains("guard let armedToken = coordinator.player?.activeLoadToken else { return }")
                     && apple.contains("reconcileUnavailableResume(target: t, actualPosition: d, owner: event.loadToken)"),
                     "phone/Mac retirement and first-frame checks share the exact load ownership")
        var additionalChecks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            additionalChecks += 1
        }
        let retryTarget = body("private func recoveryResumeTarget(", "/// The shared mid-play same-engine reload")
        check(retryTarget.contains("confirmedRawPosition(owner: owner)")
              && retryTarget.contains("abandonmentOwnerIsCurrent: abandonedResumeRecovery?.owner == owner"),
              "every TV recovery target consumes only this mount's confirmed position and retirement")
        let freshLink = body("private func recoverCurrentNativeDebridLink(", "/// Compatibility spelling retained")
        check(freshLink.contains("let resume = recoveryResumeTarget()")
              && freshLink.contains("preservingAbandonedResume: true")
              && freshLink.contains("recoveryOwner: retryToken"),
              "fresh provider links must transfer retirement even after invalidating the outgoing token")
        let failure = body("private func handleMidPlayFailure(", "private func handleLoadFailure(")
        check(failure.contains("recoveryResumeTarget(confirmedPositionOverride: resumeOverride)"),
              "mid-play failure uses the same authority, with proven EOF position overrides retained")
        let retry = body("private func retryLoad(", "private func handleLiveStreamEOF()")
        check(retry.contains("let resume = recoveryResumeTarget()") && retry.contains("preservingAbandonedResume: true"),
              "repeated pre-frame retries cannot revive the saved floor")
        let foreground = body("private func healLoopbackMountOnForeground(", "private func resumeSurfaceContext(")
        check(foreground.contains("let resume = recoveryResumeTarget()")
              && foreground.contains("preservingAbandonedResume: true"),
              "foreground loopback replacement transfers the same-source retirement")
        let demote = body("private func demoteAVPlayerToMPV()", "private func awaitReplacementMPVMount(")
        check(demote.range(of: "reconcileResume = recoveryResumeTarget()")!.lowerBound
              < demote.range(of: "retiringAVPlayer.stopForMPVFallback()")!.lowerBound
              && demote.range(of: "prepareResumeSurfaceTransfer(engine: .libmpv")!.lowerBound
              < demote.range(of: "retiringAVPlayer.stopForMPVFallback()")!.lowerBound,
              "demotion chooses and captures the owned origin before stop clears the retiring token")
        check(demote.contains("adoptResumeSurfaceIfCurrent(loadToken: mpvToken)"),
              "a proven replacement mount can adopt even before any property callback")
        let engineSwitch = body("private func performPlayerEngineSwitch(", "private func showEngineNote(")
        check(engineSwitch.range(of: "prepareResumeSurfaceTransfer(")!.lowerBound
              < engineSwitch.range(of: "coordinator.player?.stop()")!.lowerBound,
              "user engine changes carry retirement before tearing down the old surface")
        let property = body("private func handleProperty(", "case MPVProperty.pausedForCache:")
        check(property.range(of: "adoptResumeSurfaceIfCurrent(loadToken: loadToken)")!.lowerBound
              < property.range(of: "completionEvidence.begin(")!.lowerBound,
              "any first exact-token callback adopts before completion, asset or error handling")
        let time = body("case MPVProperty.timePos:", "// FIRST-FRAME COMMIT")
        check(time.range(of: "lastRawTimePosOwner = event.loadToken")!.lowerBound
              < time.range(of: "if let t = pendingLibmpvResumeSeek")!.lowerBound,
              "first-frame reconciliation reads the incoming mount's tick, not an outgoing position")
        let adoption = body("private func adoptResumeSurfaceIfCurrent(", "private func prepareResumeSurfaceTransfer(")
        check(adoption.contains("consumeSurfaceTransfer(")
              && adoption.contains("lastRawTimePosOwner != loadToken || lastRawTimePosMountGeneration != mountGeneration"),
              "late mount receipts are idempotent and same-token item generations invalidate old raw telemetry")
        let retire = body("private func retireAbandonedResumeForUserSeek()", "private func cancelPendingLibmpvResumeForUserSeek()")
        check(retire.contains("floorAfterUserSeek(") && retire.contains("pendingResumeSurfaceTransfer = nil"),
              "manual seeking retires both the automatic target's floor eligibility and pending engine transfers")
        check(apple.contains("retryResumeTarget(confirmedPositionOverride: resumeOverride)")
              && apple.contains("preservingAbandonedResume: true, recoveryOwner: recoveryOwner")
              && apple.contains("recoveryOwner: retryLoadToken"),
              "phone/Mac automatic failures, retries and fresh links use the same fenced recovery authority")
        check(apple.contains("lastRawTimePosOwner != loadToken || lastRawTimePosMountGeneration != mountGeneration")
              && apple.contains("prepareResumeSurfaceTransfer(engine: .libmpv, origin: resume)")
              && apple.contains("adoptResumeSurfaceIfCurrent(loadToken: token)"),
              "phone/Mac surface remounts cannot leak raw positions or revive retired automatic seeks")
        check(tv.contains("floorAfterAutomaticResume(") && apple.contains("floorAfterAutomaticResume("),
              "satisfied low replacement origins cannot silently clear the saved Continue Watching floor")
        check(tv.contains("persistenceFloorForSourceReplacement(")
              && apple.contains("persistenceFloorForSourceReplacement(")
              && tv.contains("recoveryEligibleFloor(") && apple.contains("recoveryEligibleFloor("),
              "source hops retain same-episode progress without granting the retired floor playback authority")
        let terminal = body("private func presentTerminalLoadFailure()", "private func startLoadTimeout()")
        check(terminal.range(of: "terminalRetiredAssetSanityOwner = owner")!.lowerBound
              < terminal.range(of: "coordinator.player?.stop()")!.lowerBound
              && retry.contains("recoveryOwner: recoveryOwner")
              && retryTarget.contains("activeLoadToken ?? terminalRetiredAssetSanityOwner"),
              "TV terminal Retry retains and passes the exact stopped owner until new admission")
        check(apple.contains("activeLoadToken ?? terminalRetiredAssetSanityOwner")
              && apple.contains("resumeTarget: resume,\n            recoveryOwner: recoveryOwner"),
              "phone/Mac terminal Retry passes its recorded owner rather than dropping retirement on admission")
        check(retire.contains("retiredResumePersistenceFloor = nil")
              && tv.contains("let unresolvedResumeTarget = sameEpisode ? inFlightSeekTarget : nil"),
              "manual intent retires media-only protection and a new episode never inherits the old seek")
        print("TVDeferredResumeRecoveryWiringContractTests: \(11 + additionalChecks)/\(11 + additionalChecks) passed")
    }
}
