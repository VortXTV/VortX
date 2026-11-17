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
        precondition(store.components(separatedBy: "guard ProfileStore.shared.active?.isKids != true").count == 6,
                     "all inferred lookup paths and local successor respect Kids mode")
        precondition(store.contains("isKids == (ProfileStore.shared.active?.isKids == true)"),
                     "a Kids setting change invalidates an asynchronous launch")
        precondition(store.contains("core.engineResumeSecondsByLibraryId(for: meta)"))
        precondition(store.contains("await core.nativeResumeSeconds(for: meta, target: current.owner)"))
        precondition(store.contains("ProfileStore.shared.resumeOffset(for: meta)"))
        let preparation = store.components(separatedBy: "@MainActor func prepareForPlayback(")[1]
            .components(separatedBy: "/// Offline entry choices")[0]
        let finalAdmission = preparation.range(of: "let final = current.revalidated()")!.lowerBound
        let bingeRefresh = preparation.range(of: "DownloadStore.shared.refreshSeasonBoundaries(")!.lowerBound
        let launchReturn = preparation.range(of: "return (final, resume.isFinite")!.lowerBound
        precondition(finalAdmission < bingeRefresh && bingeRefresh < launchReturn)
        precondition(preparation.contains("owner: final.owner, startingFrom: final.record"),
                     "a manual download may start a binge before its finale")
        precondition(!preparation.contains("await DownloadStore.shared.refreshSeasonBoundaries"))
        precondition(store.contains("possibleFinales.keys.filter { $0 >= start }.sorted()"),
                     "prioritize the launched season before later boundaries under the existing cap")
        precondition(store.contains("refreshSeasonBoundary(for: candidate, owner: owner, startingFrom: launch)"))
        precondition(store.contains("guard let origin = self.record(id: launch.id), origin.state == .completed"))
        precondition(store.contains("origin.playbackMeta == launch.playbackMeta"))
        precondition(store.contains("stillAdmitsSeasonRollover(seasonRollover, candidate: current.record)"))
        precondition(store.contains("current.seasonRollover = seasonRollover"))
        precondition(store.contains("current.seasonBoundary == saved"))
        precondition(store.contains("let verified = result.replacement(for: saved)"))
        precondition(store.contains("self.update(id: id) { $0.seasonBoundary = replacement }"))
        precondition(store.contains("pendingProgressRecords[next[index].id]?.seasonBoundary = nil"))
        let metadata = try String(contentsOfFile: "app/SourcesShared/TMDBClient.swift", encoding: .utf8)
        let refresh = metadata.components(separatedBy: "static func downloadSeasonBoundary(")[1]
            .components(separatedBy: "/// Season poster art")[0]
        let titleObservation = refresh.range(of: "observations.observe(seriesID: tvID)")!.lowerBound
        let seriesFetch = refresh.range(of: "let response = await get(")!.lowerBound
        let countObservation = refresh.range(of: "observations.observe(finaleEpisode: from?.episodeCount)")!.lowerBound
        let currentFetch = refresh.range(of: "let current = await downloadSeasonEpisodes")!.lowerBound
        let successorObservation = refresh.range(of: "observations.observe(successorID: next?.id)")!.lowerBound
        let complete = refresh.range(of: "guard let current, current.episodeNumber == episode")!.lowerBound
        precondition(titleObservation < seriesFetch && countObservation < currentFetch && successorObservation < complete,
                     "affirmative contradictions survive an unavailable companion lookup")
        precondition(store.contains("if let displayedResume, displayedResume.isFinite, displayedResume >= 0"))
        let iosCW = root.components(separatedBy: "private func iOSDirectResume(for item:")[1]
            .components(separatedBy: "private func iOSDirectStream")[0]
        precondition(iosCW.range(of: "if url.isFileURL")!.lowerBound < iosCW.range(of: "CWResume.resolvedURL")!.lowerBound)
        precondition(iosCW.contains("return .downloaded(prepared.copy, resume: prepared.resume)"))
        precondition(iosCW.contains("prepared.copy.ownsCurrentContext(core: core)"))
        precondition(iosCW.contains("stillCurrent(), ProfileStore.shared.activeID == pid"))
        let offlineIOS = iosCW.components(separatedBy: "if expectedTraktSession == nil, ConnectivityMonitor.shared.hasConfirmedOfflinePath")[1]
            .components(separatedBy: "guard let entry = remembered")[0]
        let iosAdmission = offlineIOS.range(of: "await candidate.prepareForPlayback")!.lowerBound
        let iosCommit = offlineIOS.components(separatedBy: "await candidate.prepareForPlayback")[1]
        precondition(offlineIOS.range(of: "isCurrentLocalDownloadTarget(target)")!.lowerBound < iosAdmission)
        for gate in ["refreshSeasonBoundary: false", "stillCurrent()",
                     "isCurrentLocalDownloadTarget(target)", "hasConfirmedOfflinePath",
                     "prepared.copy.record == candidate.record", "prepared.copy.url == candidate.url",
                     "prepared.copy.requiringConfirmedOfflineAtInitialMount()"] {
            precondition(iosCommit.contains(gate), "missing offline iOS gate: \(gate)")
        }
        precondition(offlineIOS.contains("remembered == nil || rememberedURL?.isFileURL == false"))
        precondition(root.contains("guard provenance.source == .local else { return false }"))
        precondition(root.contains("rendered.items.contains { $0.offlineDownloadTarget == target }"))
        let connectivity = try String(contentsOfFile: "app/SourcesShared/ConnectivityMonitor.swift", encoding: .utf8)
        precondition(connectivity.contains("launchOffline != nil && isOffline && lastRawOffline"))
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
        let tvOffline = tvResume.components(separatedBy: "private func resumeOfflineDownload(")[1]
            .components(separatedBy: "private func rememberedDirectResume(")[0]
        precondition(tvResume.contains("guard intent?.source == .local, traktSessionID == nil"))
        precondition(tvResume.contains("remembered == nil || rememberedURL?.isFileURL == false"))
        precondition(tvCW.contains("core: core, profiles: profiles, localOnly: true"))
        precondition(tvCW.contains("current.intent == renderedContinueWatching.intent"))
        precondition(tvOffline.contains("isCurrentLocalDownloadTarget(target)"))
        precondition(tvOffline.contains("requiresConfirmedOffline: true"))
        precondition(tvOffline.contains("!ConnectivityMonitor.shared.hasConfirmedOfflinePath, let resume = rememberedDirectResume(item)"))
        precondition(store.contains("exactCopy: record == revalidated.record && url == revalidated.url"))
        let revalidation = store.components(separatedBy: "@MainActor func revalidated()")[1]
            .components(separatedBy: "@MainActor func prepareForPlayback(")[0]
        precondition(!revalidation.contains("offlineInitialMount"),
                     "ordinary revalidation and successors do not inherit the one-time offline witness")
        precondition(!tvOffline.contains("CWResume.") && !tvOffline.contains("hoardResumedGroups"))
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
        precondition(mount.contains("let revalidated = downloadedPlayback.revalidated(), revalidated.url == url"))
        precondition(mount.contains("guard downloadedPlayback.permitsInitialMount(revalidated: revalidated) else"))
        let detail = try String(contentsOfFile: "app/SourcesiOS/iOSDetailView.swift", encoding: .utf8)
        let handoffs = [root, detail].flatMap {
            $0.components(separatedBy: "onDownloadedAdvance: { candidate, onFailure in").dropFirst()
        }
        precondition(handoffs.count == 3)
        for handoff in handoffs {
            let afterAwait = handoff.components(separatedBy: "await candidate.prepareForPlayback(core: core, refreshSeasonBoundary: false)")[1]
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
        precondition(tvRoot.contains("refreshSeasonBoundary: expectedRequestID == nil && !requiresConfirmedOffline"),
                     "EOF and inferred offline resume may not request season data")
        let tvPresentation = tvRoot.components(separatedBy: "@MainActor func presentDownloaded(")[1]
            .components(separatedBy: "func close(requestID:")[0]
        precondition(tvPresentation.components(separatedBy: "if requiresConfirmedOffline, !ConnectivityMonitor.shared.hasConfirmedOfflinePath").count == 3)
        let tvPrepared = tvPresentation.components(separatedBy: "await candidate.prepareForPlayback")[1]
        let tvRoute = tvPrepared.range(of: "request?.id == expectedRequestID, stillCurrent()")!.lowerBound
        let tvReconnect = tvPrepared.range(of: "onUnavailable?()")!.lowerBound
        precondition(tvRoute < tvReconnect)
        precondition(tvPrepared.contains("prepared.copy.record == candidate.record && prepared.copy.url == candidate.url"))
        precondition(tvPrepared.contains("prepared.copy.requiringConfirmedOfflineAtInitialMount()"))
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
            precondition(source.contains("nextPlayableDownload(after: downloadedPlayback.record)"))
            precondition(source.contains("meta == downloadedPlayback.record.playbackMeta"))
            precondition(source.contains("downloadProfileID == ProfileStore.shared.activeID"))
            precondition(source.contains("successor.consecutiveAutoAdvances = consecutiveAutoAdvances"))
            precondition(source.contains("pendingDownloadedAdvance = successor"))
            precondition(source.contains("guard confirmed != nil || !downloadedBoundaryConsumed else { return }"))
            precondition(source.contains("guard confirmed != nil || eligibleEOF else"))
            precondition(source.contains("DownloadRecord.permitsDownloadedAdvance("))
            precondition(source.contains("completionEvidence.settledProgress(owner:"))
            precondition(source.contains("transportSettled: event.transportSettled"))
            precondition(source.contains("let revalidated = downloadedPlayback.revalidated(), revalidated.url == url"))
            let initialAdmission = source.range(of: "guard downloadedPlayback.permitsInitialMount(revalidated: revalidated) else")!.lowerBound
            precondition(initialAdmission < source.range(of: "downloadMountAdmitted = true")!.lowerBound)
            precondition(source.contains("if let confirmed, confirmed.isSeasonRollover"))
            precondition(source.contains("next = confirmed.revalidated()"))
            precondition(source.contains("if downloadedPlayback == nil || downloadMountAdmitted"))
            precondition(source.contains("guard downloadedPlayback == nil else { return [] }"))
        }
        print("PASS downloaded Apple resume lookup, owner/cancel/file guards and preview-exit persistence ordering")
    }
}
