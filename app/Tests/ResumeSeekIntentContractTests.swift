import Foundation

@main enum ResumeSeekIntentContractTests {
    static func main() throws {
        var attempt = DeferredResumeAttempt()
        let old = attempt.begin(targetSeconds: 365.865)
        attempt.invalidate()
        precondition(!attempt.owns(old) && !attempt.complete(old))
        let next = attempt.begin(targetSeconds: 90)
        precondition(attempt.owns(next) && attempt.complete(next))
        let unowned = InitialResumeUserIntentPolicy.target(applied: false, ownsRequest: false, requested: 0, launch: 1200)
        precondition(unowned == 1200, "nil source owner must not adopt the default zero request")
        precondition(DeferredResumeUserSeekPolicy.decision(intent: .relative(10), pendingTarget: unowned,
            unsettledTarget: unowned, firstFrameRendered: true, duration: 0) == .absolute(1210))
        precondition(InitialResumeUserIntentPolicy.target(applied: true, ownsRequest: true, requested: 1200, launch: 1200) == nil)
        let player = try String(contentsOfFile: "app/Sources/PlayerScreen.swift", encoding: .utf8)
        let cancel = player.components(separatedBy: "private func cancelPendingResumeForUserSeek() {")[1]
            .components(separatedBy: "private func handleDeferredResumeUserSeek")[0]
        precondition(cancel.contains("deferredResumeAttempt.invalidate()"))
        precondition(cancel.contains("appliedInitialResume = true"), "pre-duration user seek must retire launch resume too")
        precondition(player.contains("deferredResumeAttempt.targetSeconds ?? initialTarget"))
        precondition(player.contains("if oldTarget != nil { suppressedResumeFloor = nil }"))
        precondition(player.contains("if let av = coordinator.player as? AVPlayerEngineController { av.seek(to: 0) }"))
        precondition(!player.contains("initialResume < d - 10"), "valid tail resumes cannot silently restart at zero")
        for reason in ["chapter-previous", "chapter-next", "preview-start", "preview-end", "preview-exit", "editor-end", "editor-start"] {
            precondition(player.contains("\"\(reason)\""), "seek intent not centrally routed: \(reason)")
        }
        precondition(player.contains("if skipDBPreviewing {\n                        stopSkipDBPreview()"), "Stop must stop, not replay the preview")
        precondition(player.contains("issueSeek(to: returnPosition, reason: \"preview-exit\")"))
        let mpv = try String(contentsOfFile: "app/Sources/Player/MPVMetalViewController.swift", encoding: .utf8)
        let seekEvent = mpv.components(separatedBy: "case MPV_EVENT_SEEK:")[1].components(separatedBy: "case MPV_EVENT")[0]
        precondition(!seekEvent.contains("#else\n                    break"), "Mac must receive seek EOF recovery witnesses too")
        print("PASS actual resume generation policy; initial-duration/centralized-seek/preview-stop/Mac witness wiring")
    }
}
