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
        precondition(reload.contains("DeferredResumeSeekReconciliationPolicy.recoveryOrigin(")
                     && reload.contains("abandonmentOwnerIsCurrent: abandonedResumeRecovery?.owner == coordinator.player?.activeLoadToken")
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
        precondition(accepted.contains("abandonedResumeRecovery = nil") && accepted.contains("isSeekable = true"),
                     "only native load admission may reset the old seekability/recovery owner")
        let manual = body("private func cancelPendingLibmpvResumeForUserSeek()", "/// Returns true when input")
        precondition(manual.range(of: "abandonedResumeRecovery = nil")!.lowerBound
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
        print("TVDeferredResumeRecoveryWiringContractTests: 11/11 passed")
    }
}
