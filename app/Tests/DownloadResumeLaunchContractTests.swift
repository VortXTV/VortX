import Foundation

@main enum DownloadResumeLaunchContractTests {
    static func main() throws {
        let root = try String(contentsOfFile: "app/SourcesiOS/iOSRootView.swift", encoding: .utf8)
        let downloads = root.components(separatedBy: "struct DownloadsView: View {")[1]
            .components(separatedBy: "struct iOSLibraryDownloadsPill")[0]
        precondition(downloads.contains("let onPlay: (DownloadRecord) -> Void"))
        precondition(downloads.contains("onPlay(record)"))
        precondition(!downloads.contains("resume: 0"), "downloads must not discard saved resume")
        let presenter = root.components(separatedBy: "struct iOSDownloadsScreen: View {")[1]
            .components(separatedBy: "struct iOSSearchView")[0]
        precondition(presenter.contains("DownloadsView(onPlay: playDownload)"))
        precondition(presenter.contains("core.engineResumeSecondsByLibraryId(for: meta)"))
        precondition(presenter.contains("await account.resumeOffset(for: meta)"))
        for gate in ["!Task.isCancelled", "downloadLaunchRequest == request",
                     "owner.stillOwnsCurrentContext(core: core)", "current.state == .completed",
                     "current.playbackMeta == meta", "DownloadStore.shared.fileExists(for: current)"] {
            precondition(presenter.contains(gate), "missing download launch gate: \(gate)")
        }
        precondition(presenter.contains("DownloadStore.shared.fileURL(for: current)"))
        precondition(presenter.contains("let activeProfileID = ProfileStore.shared.activeID"))
        precondition(presenter.components(separatedBy: "ProfileStore.shared.activeID == activeProfileID").count == 3,
                     "an extant inactive overlay may persist history but must never admit this launch")
        precondition(presenter.contains("meta: meta"))
        precondition(presenter.contains("isTorrent: false"))
        precondition(presenter.contains("downloadLaunchTask?.cancel()"))
        let player = try String(contentsOfFile: "app/Sources/PlayerScreen.swift", encoding: .utf8)
        let leave = player.components(separatedBy: "private func leavePlayback() {")[1]
            .components(separatedBy: "#if os(macOS)")[0]
        let previewStop = leave.range(of: "if skipDBPreviewing { stopSkipDBPreview() }")!.lowerBound
        precondition(previewStop < leave.range(of: "reportProgress(")!.lowerBound)
        precondition(previewStop < leave.range(of: "playbackStopped(")!.lowerBound)
        precondition(player.contains("currentTimeSeconds: ownedPreviewPosition ?? currentTime"))
        precondition(player.contains("skipDBPreviewOwner == coordinator.player?.activeLoadToken"))
        precondition(player.components(separatedBy: "if skipDBPreviewing, pendingAdvance == nil { stopSkipDBPreview() }").count == 3,
                     "same-media source and player changes must carry original preview transport")
        precondition(player.contains("let preservingPreviewPause = ownedPausedPreviewOwner != nil"))
        precondition(player.contains("preservingPreviewPause: preservingPreviewPause"))
        precondition(player.contains("(preservingAbandonedResume || preservingPreviewPause) && recoveryPauseIntent"))
        precondition(player.contains("let owner = skipDBPreviewOwner, owner == coordinator.player?.activeLoadToken"))
        precondition(player.contains("transfer.context == resumeSurfaceContext(engine: engine)"))
        precondition(player.contains("loadToken != transfer.retiringOwner"))
        precondition(player.contains(".initiallyPaused(previewPauseForSurface(engine: .avPlayer))"))
        precondition(player.contains(".initiallyPaused(previewPauseForSurface(engine: .libmpv))"))
        let play = player.components(separatedBy: "private func viewerPlay() {")[1]
            .components(separatedBy: "private func retryPlaybackByUser()")[0]
        precondition(play.contains("previewPauseSurfaceTransfer = nil"))
        let av = try String(contentsOfFile: "app/Sources/Player/AVPlayerEngineView.swift", encoding: .utf8)
        precondition(av.contains("private var startsPaused = false"))
        precondition(av.range(of: "engine.loadFile(")!.lowerBound < av.range(of: "if startsPaused { engine.pause() }")!.lowerBound)
        let mpv = try String(contentsOfFile: "app/Sources/Player/MPVMetalViewController.swift", encoding: .utf8)
        let setup = mpv.range(of: "        setupMpv()")!.lowerBound
        let pause = mpv.range(of: "if startPaused { pause() }")!.lowerBound
        let firstLoad = mpv.range(of: "loadFile(url, headers: playHeaders")!.lowerBound
        precondition(setup < pause && pause < firstLoad)
        let tv = try String(contentsOfFile: "app/SourcesTV/TVDownloadsView.swift", encoding: .utf8)
        precondition(tv.contains("record.playbackMeta"), "retain TV's existing download identity")
        print("PASS downloaded Apple resume lookup, owner/cancel/file guards and preview-exit persistence ordering")
    }
}
