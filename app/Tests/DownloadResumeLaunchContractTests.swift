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
        precondition(presenter.contains("await candidate.prepareForPlayback(core: core)"))
        precondition(!presenter.contains("await account.resumeOffset(for: meta)"), "local resume must not query account providers")
        for gate in ["!Task.isCancelled", "downloadLaunchRequest == request",
                     "owner.stillOwnsCurrentContext(core: core)",
                     "DownloadStore.shared.playableDownload(id: record.id, expected: meta)"] {
            precondition(presenter.contains(gate), "missing download launch gate: \(gate)")
        }
        let store = try String(contentsOfFile: "app/SourcesShared/DownloadStore.swift", encoding: .utf8)
        let admission = store.components(separatedBy: "func playableDownload(id: UUID, expected: PlaybackMeta)")[1]
            .components(separatedBy: "func playableDownload(for target:")[0]
        for gate in ["current.state == .completed", "current.playbackMeta == expected",
                     "validatedPlaybackURL(for: current)", "url: url"] {
            precondition(admission.contains(gate), "missing exact download admission check")
        }
        precondition(presenter.contains("let activeProfileID = ProfileStore.shared.activeID"))
        precondition(presenter.components(separatedBy: "ProfileStore.shared.activeID == activeProfileID").count == 3,
                     "an extant inactive overlay may persist history but must never admit this launch")
        precondition(!admission.contains("active?.isKids"), "the existing exact Downloads entry stays available")
        precondition(store.components(separatedBy: "guard ProfileStore.shared.active?.isKids != true").count == 5,
                     "all inferred lookup paths and local successor respect Kids mode")
        precondition(store.contains("isKids == (ProfileStore.shared.active?.isKids == true)"),
                     "a Kids setting change invalidates an asynchronous launch")
        precondition(store.contains("core.engineResumeSecondsByLibraryId(for: meta)"))
        precondition(store.contains("await core.nativeResumeSeconds(for: meta, target: current.owner)"))
        precondition(store.contains("ProfileStore.shared.resumeOffset(for: meta)"))
        precondition(store.contains("let final = current.revalidated()"))
        precondition(store.contains("if let displayedResume, displayedResume.isFinite, displayedResume >= 0"))
        let iosCW = root.components(separatedBy: "private func iOSDirectResume(for item:")[1]
            .components(separatedBy: "private func iOSDirectStream")[0]
        precondition(iosCW.range(of: "if url.isFileURL")!.lowerBound < iosCW.range(of: "CWResume.resolvedURL")!.lowerBound)
        precondition(iosCW.contains("return .downloaded(prepared.copy, resume: prepared.resume)"))
        precondition(iosCW.contains("prepared.copy.ownsCurrentContext(core: core)"))
        precondition(iosCW.contains("stillCurrent(), ProfileStore.shared.activeID == pid"))
        precondition(root.components(separatedBy: "didSet { if path != oldValue { continueWatchingRequestID = nil } }").count == 3)
        precondition(root.components(separatedBy: "Binding(get: { path }, set: { path = $0 })").count == 3)
        precondition(root.contains("didSet { if player?.id != oldValue?.id { continueWatchingRequestID = nil } }"))
        precondition(root.contains("didSet { if downloadPlayer?.id != oldValue?.id { continueWatchingRequestID = nil } }"))
        let libraryCW = root.components(separatedBy: "private func resumeLibraryContinueWatching(_ item:")[1]
            .components(separatedBy: "private func sortChips")[0]
        let ownerCheck = libraryCW.range(of: "owner == producer, owner.stillOwnsCurrentContext(core: core)")!.lowerBound
        let libraryTask = libraryCW.range(of: "Task { @MainActor in")!.lowerBound
        precondition(ownerCheck < libraryTask && libraryCW.contains("&& owner.stillOwnsCurrentContext(core: core)"))
        precondition(libraryCW.components(separatedBy: "guard stillCurrent() else { return }").count == 3)
        precondition(root.contains("items: shelf.items, onTap: { resumeLibraryContinueWatching($0, producer: shelf.owner) }"))
        let tvCW = try String(contentsOfFile: "app/SourcesTV/HomeView.swift", encoding: .utf8)
        let tvResume = tvCW.components(separatedBy: "private func directResume(_ item:")[1]
            .components(separatedBy: "private func resumeSource")[0]
        precondition(tvResume.range(of: "if url.isFileURL")!.lowerBound < tvResume.range(of: "CWResume.resolvedURL")!.lowerBound)
        precondition(tvResume.contains("presenter.presentDownloaded(candidate, core: core, displayedResume: item.resumeSeconds"))
        precondition(tvResume.contains("onUnavailable: { openDetails(item) }, stillCurrent: {"))
        precondition(tvResume.contains("continueWatchingRequestID == requestID"))
        precondition(tvResume.contains("candidate.ownsCurrentContext(core: core)"))
        precondition(presenter.contains("iOSPlayerLaunch.downloaded(prepared.copy, resume: prepared.resume)"))
        precondition(store.contains("attributes.isRegularFile == true"))
        precondition(store.contains("attributes.isSymbolicLink == false"))
        precondition(store.contains("resolved.deletingLastPathComponent().path == managedDirectory.path"))
        precondition(store.contains("resolved.path.hasPrefix(home.path +"))
        precondition(root.contains("meta: playback.record.playbackMeta"))
        precondition(root.contains("isTorrent: false, wasExplicitPick: true"))
        precondition(presenter.contains("downloadLaunchTask?.cancel()"))
        let player = try String(contentsOfFile: "app/Sources/PlayerScreen.swift", encoding: .utf8)
        let leave = player.components(separatedBy: "private func leavePlayback() {")[1]
            .components(separatedBy: "#if os(macOS)")[0]
        let backDuringHandoff = leave.components(separatedBy: "invalidateWatchPartyOwner()")[0]
        let activePresentation = backDuringHandoff.range(of: "guard ownsDownloadedPresentation?() == true")!.lowerBound
        let fullscreenExit = backDuringHandoff.range(of: "exitPlayerFullScreenIfNeeded()")!.lowerBound
        let close = backDuringHandoff.range(of: "onClose()")!.lowerBound
        precondition(activePresentation < fullscreenExit && fullscreenExit < close)
        precondition(leave.contains("onDownloadedAdvance(successor) { exitPlayerFullScreenIfNeeded() }"))
        let mount = player.components(separatedBy: "// A rejected new mount must still unwind")[1]
            .components(separatedBy: "downloadMountAdmitted = true")[0]
        precondition(mount.contains("macWasFullScreenAtOpen = downloadedPlayback.macWasFullScreenAtOpen"))
        precondition(mount.contains("downloadedPlayback.revalidated()?.url == url"))
        let detail = try String(contentsOfFile: "app/SourcesiOS/iOSDetailView.swift", encoding: .utf8)
        let handoffs = [root, detail].flatMap {
            $0.components(separatedBy: "onDownloadedAdvance: { candidate, onFailure in").dropFirst()
        }
        precondition(handoffs.count == 3)
        for handoff in handoffs {
            let afterAwait = handoff.components(separatedBy: "await candidate.prepareForPlayback(core: core)")[1]
                .components(separatedBy: "onClose:")[0]
            let requestFence = afterAwait.range(of: "?.id == item.id else { return }")!.lowerBound
            let failure = afterAwait.range(of: "onFailure()")!.lowerBound
            precondition(requestFence < failure)
        }
        let previewStop = leave.range(of: "if skipDBPreviewing { stopSkipDBPreview() }")!.lowerBound
        precondition(previewStop < leave.range(of: "reportProgress(")!.lowerBound)
        precondition(previewStop < leave.range(of: "playbackStopped(")!.lowerBound)
        precondition(player.contains("currentTimeSeconds: ownedPreviewPosition ?? currentTime"))
        precondition(player.contains("skipDBPreviewOwner == coordinator.player?.activeLoadToken"))
        precondition(player.components(separatedBy: "if skipDBPreviewing, pendingAdvance == nil { stopSkipDBPreview() }").count == 3,
                     "same-media source and player changes must carry original preview transport")
        precondition(player.contains("let preservingViewerPause = playbackDeadlineClock.isPaused"))
        precondition(player.contains("preservingViewerPause: preservingViewerPause"))
        precondition(player.contains("(preservingAbandonedResume || preservingViewerPause) && recoveryPauseIntent"))
        precondition(player.contains("currentContext: resumeSurfaceContext(engine: engine)"))
        precondition(player.contains("transfer.accepts(observedOwner: loadToken, activeOwner: coordinator.player?.activeLoadToken"))
        precondition(player.contains(".initiallyPaused(enginePauseForSurface(engine: .avPlayer))"))
        precondition(player.contains(".initiallyPaused(enginePauseForSurface(engine: .libmpv))"))
        let play = player.components(separatedBy: "private func viewerPlay() {")[1]
            .components(separatedBy: "private func retryPlaybackByUser()")[0]
        precondition(play.contains("playbackDeadlineClock.setPaused(false"))
        precondition(!play.contains("engineSurfaceTransfer = nil"), "Play then Pause during teardown must reach the same replacement")
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
        precondition(tv.contains("presentDownloaded(playback, core: CoreBridge.shared, stillCurrent: { downloadLaunchID == launchID })"))
        let tvDetail = try String(contentsOfFile: "app/SourcesTV/DetailView.swift", encoding: .utf8)
        precondition(tvDetail.contains("presentDownloaded(candidate, core: core, stillCurrent: { downloadLaunchID == launchID })"))
        precondition(tvDetail.contains("presentDownloaded(copy, core: core, stillCurrent: {"))
        let tvPlayer = try String(contentsOfFile: "app/SourcesTV/TVPlayerView.swift", encoding: .utf8)
        let tvRoot = try String(contentsOfFile: "app/SourcesTV/RootTabView.swift", encoding: .utf8)
        precondition(tvRoot.contains("startAtSeconds: resume, downloadedPlayback: playback"))
        precondition(tvRoot.contains("guard request?.id == expectedRequestID, stillCurrent()"))
        precondition(tvRoot.contains("if request?.id != oldValue?.id { requestGeneration = UUID() }"))
        precondition(tvRoot.contains("guard !Task.isCancelled, requestGeneration == presentation,"))
        precondition(tvPlayer.contains("if !downloadHandoffProgressFlushed"))
        precondition(tvPlayer.contains("$0.owner == coordinator.player?.activeLoadToken && $0.mountGeneration == mountGeneration"),
                     "paused EOF cannot authorize a new AVPlayer physical item under the same logical load")
        let tvLeave = tvPlayer.components(separatedBy: "private func leavePlayback() {")[1]
        let handoff = tvLeave.range(of: "let isDownloadedHandoff = downloadedSuccessor != nil")!.lowerBound
        let flush = tvLeave.range(of: "flushExitProgress(integrityOwner: exitLoadToken")!.lowerBound
        let invalidate = tvLeave.range(of: "coordinator.player?.invalidateLoadToken()")!.lowerBound
        precondition(handoff < flush && flush < invalidate)
        for source in [player, tvPlayer] {
            precondition(source.contains("nextPlayableDownload(after: meta)"))
            precondition(source.contains("meta == downloadedPlayback?.record.playbackMeta"))
            precondition(source.contains("downloadProfileID == ProfileStore.shared.activeID"))
            precondition(source.contains("successor.consecutiveAutoAdvances = consecutiveAutoAdvances"))
            precondition(source.contains("pendingDownloadedAdvance = true"))
            precondition(source.contains("guard confirmed || !downloadedBoundaryConsumed else { return }"))
            precondition(source.contains("guard confirmed || eligibleEOF else"))
            precondition(source.contains("DownloadRecord.permitsDownloadedAdvance("))
            precondition(source.contains("completionEvidence.settledProgress(owner:"))
            precondition(source.contains("transportSettled: event.transportSettled"))
            precondition(source.contains("downloadedPlayback.revalidated()?.url == url"))
            precondition(source.contains("if downloadedPlayback == nil || downloadMountAdmitted"))
            precondition(source.contains("guard downloadedPlayback == nil else { return [] }"))
        }
        print("PASS downloaded Apple resume lookup, owner/cancel/file guards and preview-exit persistence ordering")
    }
}
