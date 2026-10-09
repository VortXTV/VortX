import Foundation

@main enum EpisodeResolutionBudgetTests {
    static func main() async {
        let auto = EpisodeResolutionBudget(episodeID: "episode2", origin: .automatic, now: 100)
        let manual = EpisodeResolutionBudget(episodeID: "episode2", origin: .manual, now: 100)
        precondition(auto.deadline == 165 && auto.deadline == manual.deadline)
        // Exact observed ordering: contributors take their full20s, then the preferred local
        // NNTP leg can use35s without losing a race to the old30s surface timer.
        let preferred = EpisodeResolutionBudget.candidateLegDeadline(
            overallDeadline: auto.candidateDeadline, now: 120, isUsenet: true, remainingCandidates: 2)
        precondition(preferred == 155 && auto.canAdmit(at: 155))
        precondition(auto.candidateDeadline - preferred! == 8, "failure leaves8s for an alternate")
        let fallback = EpisodeResolutionBudget.candidateLegDeadline(
            overallDeadline: auto.candidateDeadline, now: 155, isUsenet: false, remainingCandidates: 1)
        precondition(fallback == 160 && auto.admissionDeadline > fallback!)
        precondition(auto.canAdmit(at: 138), "late candidate within owned budget is not falsely terminal at30s")
        precondition(!auto.canAdmit(at: 165))
        precondition(EpisodeResolutionBudget.candidateLegDeadline(
            overallDeadline: auto.candidateDeadline, now: 163, isUsenet: true, remainingCandidates: 1) == nil)
        let inherited = await EpisodeResolutionBudget.$current.withValue(auto) {
            await Task { EpisodeResolutionBudget.current }.value
        }
        precondition(inherited == auto && EpisodeResolutionBudget.current == nil,
                     "nested resolver inherits exact absolute budget, not a renewed duration")
        let owner = EpisodeResolutionOwner(episodeGeneration: 1, sourceGeneration: 1, videoID: "episode2")
        let replacement = EpisodeResolutionOwner(episodeGeneration: 2, sourceGeneration: 2, videoID: "episode3")
        precondition(EpisodeResolutionDeadlinePolicy.decision(captured: owner, current: replacement,
            pendingVideoID: "episode3", admitted: false, exited: false) == .ignore)
        precondition(EpisodeResolutionDeadlinePolicy.decision(captured: owner, current: owner,
            pendingVideoID: "episode2", admitted: true, exited: false) == .ignore)
        precondition(EpisodeResolutionDeadlinePolicy.decision(captured: owner, current: owner,
            pendingVideoID: "episode2", admitted: false, exited: true) == .ignore)
        precondition(EpisodeResolutionDeadlinePolicy.decision(captured: owner, current: owner,
            pendingVideoID: "episode2", admitted: false, exited: false) == .timeOut)
        precondition(EpisodeResolutionBudget.protectsPendingResolution(deadlineScheduled: true,
            owner: owner, currentOwner: owner, admitted: false, exited: false),
                     "TV20s EOF escape must not cancel a valid35s local leg")
        // The main actor may deliver the prepared continuation BEFORE its overdue timer.
        // Keep ownership/timer state unchanged and exercise the production time admission itself.
        precondition(auto.canAdmit(at: 100), "an immediate prepared hit remains admissible")
        precondition(!auto.canAdmit(at: auto.admissionDeadline)
                     && !auto.canAdmit(at: auto.deadline + 1),
                     "an expired prepared hit is rejected even while its owner and timer remain current")
        for (scheduled, current, admitted, exited) in [
            (false, owner, false, false), (true, replacement, false, false),
            (true, owner, true, false), (true, owner, false, true)
        ] {
            precondition(!EpisodeResolutionBudget.protectsPendingResolution(deadlineScheduled: scheduled,
                owner: owner, currentOwner: current, admitted: admitted, exited: exited))
        }

        let ios = try! String(contentsOfFile: "app/Sources/PlayerScreen.swift", encoding: .utf8)
        let tv = try! String(contentsOfFile: "app/SourcesTV/TVPlayerView.swift", encoding: .utf8)
        let detail = try! String(contentsOfFile: "app/SourcesiOS/iOSDetailView.swift", encoding: .utf8)
        for surface in [ios, tv] {
            precondition(surface.contains("episodeResolutionDeadlineSeconds = EpisodeResolutionBudget.maximumDuration"))
            precondition(surface.contains("budget.deadline - ProcessInfo.processInfo.systemUptime"))
            precondition(surface.contains("origin=\\(budget.origin.rawValue)"))
            precondition(surface.contains("budget: resolutionBudget"))
        }
        precondition(ios.contains("EpisodeResolutionBudget.$current.withValue(resolutionBudget)"))
        precondition(detail.components(separatedBy: "deadline: resolutionBudget.candidateDeadline").count == 3,
                     "CW and detail callbacks pass the same deadline into actual candidate helper")
        precondition(tv.contains("ref = await BoundedPreloadWorkPool.valueBeforeDeadline(legDeadline)"))
        precondition(tv.contains("isUsenet: candidate.isUsenet, remainingCandidates: candidates.count - index"))
        precondition(detail.contains("isUsenet: stream.isUsenet, remainingCandidates: candidates.count - index"))
        precondition(tv.contains("resolutionBudget.admissionDeadline") && detail.contains("resolutionBudget.admissionDeadline"))
        precondition(detail.contains("SeriesSourceSticky.admits(choice)") && tv.contains("episodeSwitchIsCurrent("))
        precondition(tv.contains("guard !hasOwnedEpisodeResolutionDeadline else { return }"))
        precondition(tv.contains("if let target = failedEpisodeResolutionTarget {\n            play(episode: target)"))
        precondition(tv.contains("failedEpisodeResolutionTarget = v") && tv.contains("episodeResolutionAdmitted = true\n        failedEpisodeResolutionTarget = nil"))
        let preparedStart = tv.range(of: "// The preload already fetched and ranked this episode across every add-on")!.lowerBound
        let beforePreparedLoad = tv[preparedStart...].components(separatedBy: "guard let issuedToken = loadIntoPlayer(")[0]
        precondition(beforePreparedLoad.components(separatedBy: "resolutionBudget.canAdmit(at: ProcessInfo.processInfo.systemUptime)").count == 3,
                     "prepared continuation and pre-issue guards both execute the production deadline admission")
        precondition(beforePreparedLoad.contains("discardPreparedEpisode(pre, reason: \"episode admission became stale or expired\")")
                     && beforePreparedLoad.contains("discardPreparedEpisode(pre, reason: \"episode admission became stale or expired before issue\")"),
                     "expired prepared ownership is retired before pending source mutation and physical admission")
        print("PASS actual episode budget:20s settlement+35s NNTP+8s fallback+2s admission, automatic/manual parity, late candidate, owner/cancel fences")
    }
}
