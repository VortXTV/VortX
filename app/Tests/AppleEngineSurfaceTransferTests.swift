import Foundation

@main
private enum AppleEngineSurfaceTransferTests {
    private struct Context: Equatable {
        var episode = 1
        var source = 2
        var resume = 3
        var engine = "mpv"
    }

    private struct FakePlayer {
        let owner: String
        var paused: Bool
    }

    static func main() throws {
        let context = Context()
        let transfer = AppleEngineSurfaceTransfer(retiringOwner: "old", context: context)
        func mount(requestedPause: Bool, context: Context = Context(), exited: Bool = false) -> FakePlayer {
            FakePlayer(owner: "new", paused: transfer.startsPaused(
                requestedPause: requestedPause, currentContext: context, playbackExited: exited))
        }
        precondition(mount(requestedPause: true).paused,
                     "ordinary Pause must survive an engine switch without a skip preview")
        precondition(!mount(requestedPause: false).paused,
                     "ordinary playing switches must remain playing")

        // During the teardown await no controller may exist. The surface reads each latest intent,
        // including Play followed by another Pause, rather than a captured bool or a cleared transfer.
        var requestedPause = true
        requestedPause = false
        precondition(!mount(requestedPause: requestedPause).paused, "Play supersedes the original pause")
        requestedPause = true
        var replacement = mount(requestedPause: requestedPause)
        precondition(replacement.paused, "a later Pause still owns the pending replacement")
        precondition(!transfer.accepts(observedOwner: "old", activeOwner: "old", currentContext: context),
                     "the retiring player cannot consume its transfer")
        precondition(!transfer.accepts(observedOwner: "old", activeOwner: "new", currentContext: context),
                     "a queued retired callback cannot change the new player")
        precondition(!transfer.accepts(observedOwner: "new", activeOwner: nil, currentContext: context))
        precondition(transfer.accepts(observedOwner: replacement.owner, activeOwner: replacement.owner,
                                     currentContext: context))
        requestedPause = false
        if transfer.accepts(observedOwner: replacement.owner, activeOwner: replacement.owner,
                            currentContext: context) {
            replacement.paused = transfer.startsPaused(
                requestedPause: requestedPause, currentContext: context, playbackExited: false)
        }
        precondition(!replacement.paused, "a Play before admission cannot be replaced with an older Pause")
        for other in [Context(episode: 9), Context(source: 9), Context(resume: 9), Context(engine: "av")] {
            precondition(!mount(requestedPause: true, context: other).paused)
            precondition(!transfer.accepts(observedOwner: "new", activeOwner: "new", currentContext: other),
                         "episode, source, resume and engine changes independently retire old authority")
        }
        precondition(!mount(requestedPause: true, exited: true).paused)

        let source = try String(contentsOfFile: "app/Sources/PlayerScreen.swift", encoding: .utf8)
        func section(_ start: String, _ end: String) -> String {
            source.components(separatedBy: start)[1].components(separatedBy: end)[0]
        }
        let demote = section("private func demoteAVPlayerToMPV(", "private func awaitReplacementMPVMount(")
        precondition(demote.contains("if let owner = retiringAVPlayer.activeLoadToken {\n            engineSurfaceTransfer ="))
        precondition(demote.range(of: "engineSurfaceTransfer =")!.lowerBound
                     < demote.range(of: "stopForMPVFallback()")!.lowerBound)
        let swap = section("private func switchPlayerEngine(", "private func startAVStartWatchdog()")
        precondition(swap.contains("if let retiringOwner = coordinator.player?.activeLoadToken {\n            engineSurfaceTransfer ="))
        precondition(swap.range(of: "engineSurfaceTransfer =")!.lowerBound
                     < swap.range(of: "coordinator.player?.stop()")!.lowerBound)
        let pause = section("private func viewerPause()", "private func viewerPlay()")
        precondition(!pause.contains("guard coordinator.player != nil"),
                     "Pause must be recorded even while the old surface has been dismantled")
        let play = section("private func viewerPlay()", "private func retryPlaybackByUser()")
        precondition(!play.contains("engineSurfaceTransfer = nil"))
        let toggle = section("private func viewerToggle()", "private func waitForPlaybackTime(")
        precondition(toggle.contains("engineSurfaceTransfer != nil ? playbackDeadlineClock.isPaused : isPaused"),
                     "a second toggle during controller teardown must use the preceding viewer input")
        let sourceSwitch = section("private func switchStream(", "// MARK: - Episode navigation")
        precondition(sourceSwitch.contains("let preservingViewerPause = playbackDeadlineClock.isPaused"))
        precondition(sourceSwitch.contains("preservingViewerPause: preservingViewerPause"),
                     "an ordinary paused source change must not autoplay a new AVPlayer item")
        precondition(source.contains(".initiallyPaused(enginePauseForSurface(engine: .avPlayer))"))
        precondition(source.contains(".initiallyPaused(enginePauseForSurface(engine: .libmpv))"))
        let tv = try String(contentsOfFile: "app/SourcesTV/TVPlayerView.swift", encoding: .utf8)
        precondition(tv.contains(".initiallyPaused(enginePauseForSurface(engine: .avPlayer))"))
        precondition(tv.contains(".initiallyPaused(enginePauseForSurface(engine: .libmpv))"))
        precondition(tv.contains("if let owner = retiringAVPlayer.activeLoadToken {\n            engineSurfaceTransfer ="))
        precondition(tv.contains("if let retiringOwner = coordinator.player?.activeLoadToken {\n            engineSurfaceTransfer ="))
        let tvHandler = tv.components(separatedBy: "private func handleProperty(")[1]
            .components(separatedBy: "switch name {")[0]
        precondition(tvHandler.contains("transfer.accepts(observedOwner: loadToken"))
        precondition(tvHandler.contains("recoveryPauseOwner = loadToken"),
                     "a parked TV replacement must use the existing no-first-frame resume path")
        precondition(tvHandler.contains("bindIncomingTransportIntent(to: loadToken)"))
        let tvPause = tv.components(separatedBy: "private func viewerPause() {")[1]
            .components(separatedBy: "private func viewerPlay()")[0]
        precondition(!tvPause.contains("guard coordinator.player != nil"))
        print("PASS engine surface transport intent, teardown input, owner/context fencing and caller wiring")
    }
}
