// Standalone wiring contract for public issue #164.
//
// Run with:
//   swiftc -parse-as-library -o /tmp/issue164-trakt \
//     app/Tests/Issue164TraktContractTests.swift && /tmp/issue164-trakt

import Foundation

@main
struct Issue164TraktContractTests {
    @MainActor
    private static var checks = 0

    @MainActor
    static func main() {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let coordinator = read(app, "SourcesShared/ScrobbleCoordinator.swift")
        let sessionPolicy = read(app, "SourcesShared/ExternalSyncSessionPolicy.swift")
        let provider = read(app, "SourcesShared/ExternalScrobbleProvider.swift")
        let settings = read(app, "SourcesShared/ExternalServicesSettingsView.swift")
        let shadow = read(app, "SourcesShared/TraktPlaybackShadow.swift")
        let auth = read(app, "SourcesShared/TraktAuth.swift")
        let service = read(app, "SourcesShared/TraktService.swift")
        let syncEngine = read(app, "SourcesShared/TraktSyncEngine.swift")
        let ratingsStore = read(app, "SourcesShared/TraktRatingsStore.swift")
        let traktRails = read(app, "SourcesShared/TraktRailsModel.swift")
        let checkinModel = read(app, "SourcesShared/TraktCheckinModel.swift")
        let cacheStorage = read(app, "SourcesShared/TraktPlaybackCacheStorage.swift")
        let privateStorage = read(app, "SourcesShared/PrivateExternalSyncStorage.swift")
        let simklAuth = read(app, "SourcesShared/SIMKLAuth.swift")
        let simklService = read(app, "SourcesShared/SIMKLService.swift")
        let simklRatings = read(app, "SourcesShared/SIMKLRatingsStore.swift")
        let simklWatched = read(app, "SourcesShared/SIMKLWatchedShadow.swift")
        let simklRails = read(app, "SourcesShared/SIMKLRailsModel.swift")
        let releaseCalendar = read(app, "SourcesShared/ReleaseCalendarModel.swift")
        let catalogs = read(app, "SourcesShared/CatalogPreferences.swift")
        let myLists = read(app, "SourcesShared/TraktMyListsClient.swift")
        let player = read(app, "Sources/PlayerScreen.swift")
        let tvPlayer = read(app, "SourcesTV/TVPlayerView.swift")
        let tvHome = read(app, "SourcesTV/HomeView.swift")
        let tvDetail = read(app, "SourcesTV/DetailView.swift")
        let tvSharedUI = read(app, "SourcesTV/SharedUI.swift")
        let iosHome = read(app, "SourcesiOS/iOSRootView.swift")
        let iosDetail = read(app, "SourcesiOS/iOSDetailView.swift")

        // Blocker 1: start is a lifecycle transition only, and lifecycle operations cannot overtake.
        require(!coordinator.contains("func playbackProgressed("),
                "coordinator must not expose periodic progress-as-start")
        require(!player.contains("playbackProgressed"),
                "shared Apple player must not turn progress ticks into Trakt starts")
        require(!tvPlayer.contains("playbackProgressed"),
                "tvOS player must not turn progress/seek ticks into Trakt starts")
        require(occurrences(of: "await provider.scrobbleStart(ref, session: session)", in: coordinator) == 2,
                "only initial play and resume may send Trakt start")
        require(coordinator.contains("private let lifecycleQueue = TraktScrobbleLifecycleQueue()"),
                "Trakt lifecycle operations must share the FIFO")
        require(occurrences(of: "dispatchLifecycle(", in: coordinator) >= 6,
                "start, pause, resume, stop, and completion must use the serialized lane")

        // Existing issue #164 surface contracts.
        require(provider.contains("scrobble requested="),
                "Trakt operations must leave sanitized success/failure receipts")
        require(provider.contains("static let traktContinueWatching = \"vortx.trakt.continueWatching\""),
                "Continue Watching source key must stay stable")
        require(settings.contains("Use Trakt for Continue Watching"),
                "Trakt source selection must be user-visible")
        require(shadow.contains("TraktContinueWatchingFold.fold(playbackRows)"),
                "whole playback snapshots must feed the shared fold")
        require(shadow.contains("?extended=full"),
                "runtime-bearing Trakt rows must be requested")
        require(tvHome.contains("continueWatchingSelection(fallback: core.continueWatching)"),
                "tvOS Home must consume the selected Trakt source")
        require(iosHome.contains("continueWatchingSelection("),
                "iOS and macOS Home must consume the selected Trakt source")

        // Blocker 2: the offset printed on a Trakt card is the direct player's start offset.
        require(occurrences(of: "startAtSeconds: item.resumeSeconds", in: tvHome) == 2,
                "both tvOS direct-resume branches must pass the displayed card offset")
        require(iosHome.contains("if let displayed = item.resumeSeconds"),
                "iOS direct resume must prefer the displayed card offset")

        // Blocker 3: generation validation covers the disk commit, not only the memory assignment.
        require(appearsInOrder(
            in: shadow,
            [
                "guard TraktPlaybackSnapshotPolicy.canCommit(",
                "Self.saveCache(",
                "guard TraktPlaybackSnapshotPolicy.canCommit(",
                "lastActivityStamps = activity",
                "lock.unlock()",
                "Self.postChanged()",
            ]
        ), "old-account cache persistence must happen under the generation lock")

        // Blocker 4: Trakt rows never route their dismiss into the local engine.
        require(tvHome.contains("menu: continueWatchingSelection.source == .trakt")
                    && tvHome.contains("? .none"),
                "tvOS must use actual row provenance before omitting local dismiss")
        require(iosHome.contains("menu: renderedContinueWatching.provenance.source == .trakt")
                    && iosHome.contains("? .none"),
                "iOS/macOS must use actual row provenance before omitting local dismiss")

        // Blocker 5: each playback kind has its own invalidation cursor.
        require(shadow.contains("TraktPlaybackActivityStamps(movies: movies, episodes: episodes)"),
                "movie and episode activity timestamps must remain separate")
        require(shadow.contains("activity == known"),
                "the refresh gate must compare the full movie/episode activity pair")

        // Blocker 6: authentication forces a pull and signed-out work cannot consume its throttle window.
        require(appearsInOrder(
            in: settings,
            ["pollForToken(", "TraktPlaybackShadow.shared.refreshNow()"]
        ), "successful Trakt auth must force the playback-shadow refresh")
        require(shadow.contains("TraktPlaybackRefreshThrottlePolicy.shouldArm("),
                "refresh completion must use the signed-in throttle policy")

        // Security boundary: every lifecycle and pending retry is tied to one random auth session.
        require(auth.contains("private static let sessionAccount = TraktTokenSlots.legacySession")
                    && auth.contains("TraktSessionID.random()"),
                "every authenticated credential set must carry a random session id")
        require(auth.contains("func performSessionBoundWrite<Result: Sendable>(")
                    && auth.contains("activeSessionWrites += 1")
                    && auth.contains("await waitForSessionWrites()"),
                "auth boundaries and provider writes must share the non-racing lease authority")
        require(appearsInOrder(
            in: coordinator,
            [
                "traktSessionID: TraktAuth.storedSessionID",
                "TraktAuth.storedSessionID == captured",
                "guard await provider.isConnected()",
                "guard let ref = await makeRef(",
            ]
        ), "stale Trakt sessions must fail before identity resolution")
        require(service.contains("auth.performSessionBoundWrite(")
                    && occurrences(of: "expectedSession: sessionID", in: provider) >= 6,
                "provider writes must revalidate inside the auth authority")
        require(syncEngine.contains("let sessionID: TraktSessionID")
                    && syncEngine.contains("snapshot.sessionID == sessionID")
                    && syncEngine.contains("pendingPushes.filter { $0.sessionID == stateSessionID }")
                    && occurrences(of: "expectedSession: sessionID", in: syncEngine) >= 5,
                "legacy and cross-account pending pushes must fail closed")
        require(appearsInOrder(
            in: provider,
            [
                "func addToWatchlist(_ ref: ExternalMediaRef, session: ExternalProviderSession?) async",
                "guard case .trakt(let sessionID) = session,",
                "TraktAuth.storedSessionID == sessionID",
                "TraktService.shared.addToWatchlist(",
                "expectedSession: sessionID",
                "enqueueIfTransient(ref, .watchlistAdd, sessionID: sessionID, error)",
            ]
        )
                    && coordinator.contains("provider.addToWatchlist(ref, session: session)")
                    && coordinator.contains("provider.removeFromWatchlist(ref, session: session)"),
                "watchlist writes and their transient retries must retain the enqueue-time session")
        require(appearsInOrder(
            in: ratingsStore,
            [
                "let sessionID = TraktAuth.storedSessionID",
                "persistLocked()",
                "mirror(entry, gen: gen, sessionID: sessionID)",
            ]
        )
                    && occurrences(of: "expectedSession: sessionID", in: ratingsStore) == 2
                    && ratingsStore.contains("sessionID: sessionID,"),
                "rating writes and their transient retries must retain the pre-request session")
        require(occurrences(of: "let sessionID = TraktAuth.storedSessionID", in: checkinModel) >= 3
                    && occurrences(of: "expectedSession: sessionID", in: checkinModel) == 3,
                "check-in, replace, and cancel must capture and transport-bind one session")
        require(checkinModel.contains("TraktAuthBoundary.observe(key: \"trakt-checkin-model\")")
                    && checkinModel.contains("active?.sessionID == sessionID"),
                "a stale check-in receipt must not expose a cancel action in a replacement account")
        require(!service.contains("func cancelCheckIn()")
                    && occurrences(of: "expectedSession: TraktSessionID", in: service) >= 10,
                "Trakt mutation APIs must require an explicit captured session")

        // Private playback snapshots are visible and durable only for their exact current session.
        require(shadow.contains("TraktAuthBoundary.observe(key: \"trakt-playback-shadow\")")
                    && occurrences(of: "TraktAuth.storedSessionID", in: shadow) >= 8,
                "the playback shadow must synchronously observe and verify every auth boundary")
        require(shadow.contains("validToken(for: sessionID)")
                    && shadow.contains("token: token,")
                    && shadow.contains("sessionID: sessionID"),
                "one captured auth session and bearer must bind every pull leg")
        require(cacheStorage.contains("let sessionID: TraktSessionID")
                    && cacheStorage.contains("guard snapshot.sessionID == sessionID"),
                "disk snapshots must reject legacy or mismatched sessions")
        require(cacheStorage.contains("for: .cachesDirectory")
                    && cacheStorage.contains("values.isExcludedFromBackup = true")
                    && cacheStorage.contains(".protectionKey: FileProtectionType.complete"),
                "reconstructed viewing state must use protected backup-excluded cache storage")
        require(cacheStorage.contains("try deleteLegacy()")
                    && !shadow.contains("applicationSupportDirectory"),
                "the old sessionless Application Support cache must be deleted, never migrated")
        require(!shadow.contains("images.metahub.space"),
                "private Trakt rows must not construct a new direct poster request")
        require(!shadow.contains("CinemetaPreviewResolver")
                    && shadow.contains("poster: seed.poster ?? existing?.poster"),
                "private Trakt rows may reuse existing art but must not trigger metadata disclosure")

        // Boundary admission closes before drain, and remote token recovery cannot assume account sameness.
        require(appearsInOrder(
            in: auth,
            [
                "pendingCredentialBoundaries += 1",
                "await acquireCredentialBoundary()",
                "await waitForSessionWrites()",
                "mutation()",
            ]
        )
                    && occurrences(of: "pendingCredentialBoundaries == 0", in: auth) >= 4,
                "Trakt boundaries must announce pending intent before drain and block new admissions")
        require(auth.contains("different refresh token may")
                    && auth.contains("await performCredentialBoundary {")
                    && auth.contains("replaceCredentialsWithNewSession("),
                "synced Trakt recovery without account proof must rotate the session boundary")
        require(auth.contains("signOut(ifCurrent: expectedSession, ownerCapture: capture)"),
                "an old Trakt refresh failure must not sign out a replacement account")

        // SIMKL has the same exact-session transport authority as Trakt.
        require(simklAuth.contains("private static let sessionAccount = SIMKLTokenSlots.legacySession")
                    && simklAuth.contains("SIMKLSessionID.random()")
                    && simklAuth.contains("func performSessionBoundWrite<Result: Sendable>("),
                "SIMKL credentials must carry random session identity and a final write lease")
        require(appearsInOrder(
            in: simklAuth,
            [
                "pendingCredentialBoundaries += 1",
                "await acquireCredentialBoundary()",
                "while activeSessionWrites > 0",
                "mutation()",
            ]
        )
                    && occurrences(of: "pendingCredentialBoundaries == 0", in: simklAuth) >= 3,
                "SIMKL boundaries must close admission before draining active writes")
        require(appearsInOrder(
            in: simklService,
            [
                "try await rateGate()",
                "auth.performSessionBoundWrite(",
                "expectedSession: expectedSession",
                "transport.send(",
            ]
        ), "SIMKL writes must rate-wait before acquiring their exact-session credential lease")
        require(simklService.contains("auth.validToken(for: expectedSession)")
                    && occurrences(of: "guard await auth.sessionID == expectedSession", in: simklService) >= 2
                    && simklService.contains("auth.signOut(ifCurrent: expectedSession)"),
                "SIMKL reads and automatic auth loss must remain tied to their captured session")
        require(coordinator.contains("simklSessionID: SIMKLAuth.storedSessionID")
                    && coordinator.contains("connected.append((provider, .simkl(captured)))")
                    && simklService.contains("guard case .simkl(let sessionID) = session,"),
                "the coordinator and provider must transport the captured SIMKL session end to end")

        // Provider boundaries invalidate only that provider's exact playback owner. The item+player token
        // and completion latches survive, so the old playback cannot adopt a replacement account.
        let providerInvalidation = segment(
            in: coordinator,
            from: "private func invalidateTraktSession()",
            to: "private func recordCompletion("
        )
        let lifecycleDispatch = segment(
            in: coordinator,
            from: "private func dispatchLifecycle(",
            to: "private static func performDispatch("
        )
        require(providerInvalidation.contains("sessionOwnership.invalidateTrakt()")
                    && providerInvalidation.contains("sessionOwnership.invalidateSIMKL()")
                    && !providerInvalidation.contains("traktCompleted = false")
                    && !providerInvalidation.contains("simklCompleted = false")
                    && coordinator.contains("SIMKLAuthBoundary.observe(key: \"scrobble-coordinator\")")
                    && lifecycleDispatch.contains("providerSessions:")
                    && !lifecycleDispatch.contains("TraktAuth.storedSessionID")
                    && !lifecycleDispatch.contains("SIMKLAuth.storedSessionID")
                    && sessionPolicy.contains("struct PlaybackScrobbleSessionOwnership")
                    && coordinator.contains("if provider.id == \"simkl\", !sendSIMKL { return }"),
                "active playback must retain exact provider ownership across both account boundaries")

        // Ratings, watched caches, and rails publish only into the exact current account session.
        require(ratingsStore.contains("TraktAuthBoundary.observe(key: \"trakt-ratings-store\")")
                    && ratingsStore.contains("snapshot.sessionID == sessionID")
                    && ratingsStore.contains("stateSessionID == currentSession")
                    && syncEngine.contains("context.sessionID == expectedSession")
                    && syncEngine.contains("TraktService.shared.ratings("),
                "Trakt ratings memory, disk, and in-flight pulls must share one exact session")
        require(simklRatings.contains("SIMKLAuthBoundary.observe(key: \"simkl-ratings-store\")")
                    && simklRatings.contains("snapshot.sessionID == sessionID")
                    && simklRatings.contains("SIMKLService.shared.ratings(")
                    && simklRatings.contains("expectedSession: sessionID"),
                "SIMKL ratings state and durable unpushed edits must share one exact session")
        require(syncEngine.contains("TraktAuthBoundary.observe(key: \"trakt-sync-engine\")")
                    && syncEngine.contains("snapshot.sessionID == sessionID")
                    && syncEngine.contains("stateSessionID == expectedSession")
                    && syncEngine.contains("guard moviesOK, showsOK else { return }")
                    && syncEngine.contains("watchedIDs = next"),
                "Trakt watched state must reject stale sessions and accept truthful empty replacements")
        require(simklWatched.contains("SIMKLAuthBoundary.observe(key: \"simkl-watched-shadow\")")
                    && simklWatched.contains("snapshot.sessionID == sessionID")
                    && simklWatched.contains("guard allOK else { return }")
                    && simklWatched.contains("let changed = core.replace(with: next)"),
                "SIMKL watched state must reject stale sessions and accept truthful empty replacements")
        require(appearsInOrder(
            in: traktRails,
            [
                "let sessionID = TraktAuth.storedSessionID",
                "if stateSessionID != sessionID",
                "if let last = lastRefresh",
            ]
        )
                    && traktRails.contains("TraktAuthBoundary.observe(")
                    && traktRails.contains("TraktAuthBoundary.removeObserver(key: boundaryObserverKey)")
                    && traktRails.contains("expectedSession: sessionID")
                    && traktRails.contains("TraktAuth.storedSessionID == expectedSession"),
                "Trakt rail auth/session gates must precede throttle and fence response publication")
        require(appearsInOrder(
            in: simklRails,
            [
                "let sessionID = SIMKLAuth.storedSessionID",
                "if stateSessionID != sessionID",
                "if let last = lastRefresh",
            ]
        )
                    && simklRails.contains("SIMKLAuthBoundary.observe(")
                    && simklRails.contains("SIMKLAuthBoundary.removeObserver(key: boundaryObserverKey)")
                    && simklRails.contains("expectedSession: sessionID")
                    && simklRails.contains("SIMKLAuth.storedSessionID == expectedSession"),
                "SIMKL rail auth/session gates must precede throttle and fence response publication")

        // Every private durable class uses the protected, backup-excluded storage authority.
        require(privateStorage.contains("values.isExcludedFromBackup = true")
                    && privateStorage.contains(".protectionKey: FileProtectionType.complete")
                    && privateStorage.contains(".posixPermissions: isDirectory ? 0o700 : 0o600")
                    && occurrences(of: "try excludeFromBackup(fileURL)", in: privateStorage) == 2,
                "private storage must assert backup exclusion and platform protection on save and load")
        require(syncEngine.contains("file: \"sync-state.json\"")
                    && syncEngine.contains("watchedIDs:")
                    && syncEngine.contains("pendingPushes:")
                    && syncEngine.contains("lastActivityFingerprint:")
                    && ratingsStore.contains("file: \"ratings.json\"")
                    && simklRatings.contains("file: \"ratings.json\"")
                    && simklWatched.contains("file: \"watched.json\""),
                "watched, ratings, queue, and activity-fingerprint persistence must use protected snapshots")
        require(occurrences(of: "persistLocked()", in: syncEngine) >= 4
                    && syncEngine.contains("try? Self.storage?.reset()")
                    && ratingsStore.contains("try? Self.storage?.reset()")
                    && simklRatings.contains("try? Self.storage?.reset()")
                    && simklWatched.contains("try? Self.storage?.reset()"),
                "private saves and resets must share each store's generation/lock fence")

        // Connection-scoped imported catalogs disappear on automatic as well as manual boundaries.
        require(catalogs.contains("var connectionSessionID: TraktSessionID?")
                    && catalogs.contains("TraktAuthBoundary.observe(key: \"imported-catalogs\")")
                    && catalogs.contains("removeConnectionScoped(provider: .trakt)")
                    && catalogs.contains("TraktAuth.storedSessionID == sessionID")
                    && catalogs.contains("ImportedCatalogPersistencePolicy.isDurable("),
                "private imported Trakt lists must be fingerprinted and cleared on every auth boundary")
        let myListsImport = segment(
            in: myLists,
            from: "static func importList(",
            to: "// MARK: - HTTP"
        )
        require(myLists.contains("validToken(for: expectedSession)")
                    && myLists.contains("connectionSessionID: list.requiresConnection ? sessionID : nil")
                    && occurrences(of: "TraktAuth.storedSessionID == sessionID", in: myLists) >= 3
                    && !myListsImport.contains("DiagnosticsLog.log(\"trakt-my-lists\", \"\\(list.kind.rawValue) '\\(list.name)'"),
                "private list reads, publication, persistence, and logs must remain session-bound and private")

        // A failed direct resume keeps the remote card's offset and episode identity through source choice.
        require(tvHome.contains("resumeSeconds: traktSessionID == nil ? nil : item.resumeSeconds")
                    && tvHome.contains("videoID: traktSessionID == nil ? nil : item.state.videoId")
                    && tvHome.contains("initialResumeSeconds: $0.resumeSeconds")
                    && tvHome.contains("initialTraktSessionID: $0.traktSessionID")
                    && tvSharedUI.contains("else if let onDetails"),
                "tvOS direct-resume fallback must retain the Trakt resume target")
        require(tvDetail.contains("var initialResumeSeconds: Double? = nil")
                    && tvDetail.contains("var initialVideoID: String? = nil")
                    && occurrences(of: "var initialTraktSessionID: TraktSessionID? = nil", in: tvDetail) >= 3
                    && occurrences(of: "TraktAuth.storedSessionID == initialTraktSessionID", in: tvDetail) >= 3
                    && tvDetail.contains("OneShotResumeAdmissionGate<TraktSessionID>()")
                    && occurrences(of: "initialStartGate.admit(", in: tvDetail) == 4
                    && occurrences(of: "currentSessionID: TraktAuth.storedSessionID", in: tvDetail) == 4,
                "tvOS detail/source selection must revalidate the remote session and consume only after launch")
        require(iosHome.contains("resumeSeconds: carriesTraktResume ? item.resumeSeconds : nil")
                    && iosHome.contains("videoID: carriesTraktResume ? item.cwVideoId : nil")
                    && iosHome.contains("initialResumeSeconds: target.resumeSeconds")
                    && iosHome.contains("initialTraktSessionID: target.traktSessionID"),
                "iOS direct-resume fallback must retain the Trakt resume target")
        let iosContinueWatchingProvenance = segment(
            in: iosHome,
            from: "private struct iOSCWProducerProvenance: Sendable",
            to: "struct iOSHomeView: View"
        )
        require(iosContinueWatchingProvenance.contains("case .local:")
                    && iosContinueWatchingProvenance.contains("return traktSessionID == nil")
                    && iosContinueWatchingProvenance.contains("case .trakt:")
                    && iosContinueWatchingProvenance.contains(
                        "guard let traktSessionID else { return false }"
                    )
                    && iosContinueWatchingProvenance.contains(
                        "return currentSessionID == traktSessionID"
                    ),
                "iOS remote Continue Watching provenance must reject A-to-B account changes")
        let iosContinueWatchingSnapshot = segment(
            in: iosHome,
            from: "private var continueWatchingRenderSnapshot: iOSCWRenderSnapshot",
            to: "#if os(macOS)"
        )
        require(occurrences(of: "continueWatchingSelection", in: iosContinueWatchingSnapshot) == 1
                    && iosContinueWatchingSnapshot.contains("let selection = continueWatchingSelection")
                    && iosContinueWatchingSnapshot.contains("let items = selection.items.map")
                    && iosContinueWatchingSnapshot.contains("items: items")
                    && iosContinueWatchingSnapshot.contains("source: selection.source")
                    && iosContinueWatchingSnapshot.contains("traktSessionID: selection.sessionID"),
                "iOS rendered Continue Watching items and provenance must come from one selection snapshot")
        let iosHomeBody = segment(
            in: iosHome,
            from: """
            var body: some View {
                    let renderedContinueWatching = continueWatchingRenderSnapshot
            """,
            to: "private func refreshReleaseCalendar()"
        )
        require(iosHomeBody.contains(
                    "let renderedContinueWatching = continueWatchingRenderSnapshot"
                )
                    && iosHomeBody.contains("items: renderedContinueWatching.items")
                    && occurrences(
                        of: "provenance: renderedContinueWatching.provenance",
                        in: iosHomeBody
                    ) == 2
                    && !iosHomeBody.contains("continueWatchingSelection")
                    && !iosHomeBody.contains("continueWatchingItems"),
                "iOS stale rendered cards must retain their original producer/session in every action")
        let iosContinueWatchingTap = segment(
            in: iosHome,
            from: "private func handleContinueWatchingTap(",
            to: "private func cwDetailTarget("
        )
        require(iosContinueWatchingTap.contains("provenance: iOSCWProducerProvenance")
                    && appearsInOrder(in: iosContinueWatchingTap, [
                    "guard provenance.isCurrent(traktSessionID: TraktAuth.storedSessionID)",
                    "Task {",
                    "expectedTraktSession: provenance.traktSessionID",
                    "guard provenance.isCurrent(traktSessionID: TraktAuth.storedSessionID)",
                    "player = launch",
                    "resumeHoardTask?.cancel()",
                    "cwDetailTarget(for: item, provenance: provenance)"
                ])
                    && !iosContinueWatchingTap.contains("continueWatchingSelection")
                    && !iosContinueWatchingTap.contains("continueWatchingRenderSnapshot"),
                "iOS stale A cards must fail before launch, fallback, or hoard after local/B replaces A")
        let iosCapturedFallback = segment(
            in: iosHome,
            from: "private func cwDetailTarget(\n        for item: RailItem,",
            to: "@ViewBuilder private var emptyState"
        )
        require(iosCapturedFallback.contains("provenance: iOSCWProducerProvenance")
                    && iosCapturedFallback.contains(
                        "guard provenance.isCurrent(traktSessionID: TraktAuth.storedSessionID)"
                    )
                    && iosCapturedFallback.contains("let carriesTraktResume = provenance.source == .trakt")
                    && iosCapturedFallback.contains("traktSessionID: provenance.traktSessionID")
                    && !iosCapturedFallback.contains("continueWatchingSelection"),
                "iOS A-to-B account changes during direct-resume await must fail closed before fallback")
        let iosMovieContentLaunches = segment(
            in: iosDetail,
            from: "private func playMovie(",
            to: "#if !os(tvOS)\n    // MARK: Offline download"
        )
        let iosEpisodeContentLaunches = segment(
            in: iosDetail,
            from: "private func play(_ stream: CoreStream, url: URL, explicit: Bool = true) async",
            to: "private func autoPickAndPlayEpisode() async"
        )
        let iosEpisodeAutoPick = segment(
            in: iosDetail,
            from: "private func autoPickAndPlayEpisode() async",
            to: "#if !os(tvOS)"
        )
        require(iosDetail.contains("var initialResumeSeconds: Double? = nil")
                    && iosDetail.contains("var initialVideoID: String? = nil")
                    && occurrences(of: "var initialTraktSessionID: TraktSessionID? = nil", in: iosDetail) >= 2
                    && occurrences(of: "TraktAuth.storedSessionID == initialTraktSessionID", in: iosDetail) >= 3
                    && occurrences(of: "OneShotResumeAdmissionGate<TraktSessionID>()", in: iosDetail) == 2
                    && occurrences(of: "initialResumeGate.admit(", in: iosMovieContentLaunches) == 4
                    && occurrences(of: "currentSessionID: TraktAuth.storedSessionID", in: iosMovieContentLaunches) == 4
                    && occurrences(of: "presentation = .player", in: iosMovieContentLaunches) == 4
                    && occurrences(of: "initialStartGate.admit(", in: iosEpisodeContentLaunches) == 2
                    && occurrences(of: "currentSessionID: TraktAuth.storedSessionID", in: iosEpisodeContentLaunches) == 2
                    && occurrences(of: "presentation = .player", in: iosEpisodeContentLaunches) == 2
                    && iosEpisodeAutoPick.contains("await playBest(candidates, labeledBest: best)")
                    && !iosEpisodeAutoPick.contains("presentation = .player")
                    && !iosDetail.contains("didConsumeInitialResume")
                    && !iosDetail.contains("didConsumeInitialStart"),
                "iOS detail/source selection must revalidate the remote session on the first content play")
        require(shadow.contains("AccountBoundResumeSuggestion<TraktSessionID>?")
                    && shadow.contains("AccountBoundResumeSuggestion(seconds: seconds, sessionID: currentSession)")
                    && tvDetail.contains("resumeSuggestion: suggestion")
                    && iosDetail.contains("playMovie(resumeSuggestion: suggestion)")
                    && occurrences(of: "TraktAuth.storedSessionID", in: segment(
                        in: tvDetail,
                        from: "if let suggestion = traktSuggestion",
                        to: ".buttonStyle(ChipButtonStyle())"
                    )) == 0
                    && occurrences(of: "TraktAuth.storedSessionID", in: segment(
                        in: iosDetail,
                        from: "if movieReady, let suggestion = movieTraktSuggestion",
                        to: ".buttonStyle(ChipButtonStyle())"
                    )) == 0
                    && tvDetail.contains("return resumeSuggestion.proposal")
                    && iosDetail.contains("return resumeSuggestion.proposal"),
                "rendered Trakt suggestions must carry their producer session through final admission")
        require(traktRails.contains("ExternalRailFetchOutcome<MetaPreview>")
                    && traktRails.contains("case .success:")
                    && traktRails.contains("case .failure:")
                    && simklRails.contains("ExternalRailFetchOutcome<MetaPreview>")
                    && simklRails.contains("case .success:")
                    && simklRails.contains("case .failure:"),
                "successful empty rails must clear while failed reads preserve the last complete snapshot")
        require(traktRails.contains("guard !entries.isEmpty else { return .success([]) }")
                    && traktRails.contains("guard !capped.isEmpty else { return .failure }")
                    && simklRails.contains("guard !entries.isEmpty else { return .success([]) }")
                    && simklRails.contains("guard !capped.isEmpty else { return .failure }"),
                "only an authoritative empty provider response may clear a rail")

        // Final review boundaries: stale login attempts, aggregate reads, Upcoming, and remote CW privacy.
        require(auth.contains("struct TraktLoginAttemptAuthority")
                    && auth.contains("expectedLoginGeneration: loginGeneration")
                    && auth.contains("loginAttempts.owns(code: session")
                    && auth.contains("CredentialScopeRegistry.shared.isCurrent(capture)")
                    && auth.contains("func cancelLoginAttempt()"),
                "Trakt device-login responses must remain owned by one live generation")
        require(simklAuth.contains("struct SIMKLLoginAttemptAuthority")
                    && simklAuth.contains("expectedLoginGeneration: loginGeneration")
                    && simklAuth.contains("loginAttempts.owns(code: userCode")
                    && simklAuth.contains("func cancelLoginAttempt()"),
                "SIMKL PIN responses must remain owned by one live generation")
        let planToWatch = segment(
            in: simklService,
            from: "func planToWatch(expectedSession:",
            to: "private static func entry("
        )
        require(planToWatch.contains("out += try await list(")
                    && !planToWatch.contains("catch")
                    && !planToWatch.contains("continue"),
                "SIMKL plan-to-watch must fail as a whole instead of publishing mixed partial data")
        require(releaseCalendar.contains("private let simklBoundaryObserverKey = \"release-calendar-model-\\(UUID().uuidString)\"")
                    && releaseCalendar.contains("SIMKLAuthBoundary.observe(key: simklBoundaryObserverKey)")
                    && releaseCalendar.contains("SIMKLAuthBoundary.removeObserver(key: simklBoundaryObserverKey)")
                    && releaseCalendar.contains("simklSeedSessionID == currentSession")
                    && releaseCalendar.contains("simklSeedGeneration == generation")
                    && releaseCalendar.contains("SIMKLAuth.storedSessionID == sessionID"),
                "SIMKL Upcoming seeds, throttle, resolution, and publication must share one exact session")
        require(shadow.contains("let sessionID: TraktSessionID?")
                    && tvHome.contains("TraktAuth.storedSessionID == traktSessionID")
                    && iosHome.contains("TraktAuth.storedSessionID == expectedTraktSession"),
                "remote Continue Watching actions and targets must carry and revalidate their exact Trakt session")
        require(tvHome.contains("cw: localHistory")
                    && tvHome.contains("focusModel: continueWatchingSelection.source == .trakt ? nil")
                    && tvSharedUI.contains("struct WarmPosterArt")
                    && iosHome.contains("struct WarmCachedPosterImage")
                    && iosHome.contains("From Trakt")
                    && iosHome.contains("accessibilityProvenance"),
                "private remote rows must stay out of generic recommendation, hero, and artwork-fetch paths with visible provenance")

        print("PASS: \(checks) issue #164 Trakt wiring checks")
    }

    private static func read(_ app: URL, _ relative: String) -> String {
        let url = app.appendingPathComponent(relative)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            fputs("FAIL: could not read \(relative)\n", stderr)
            exit(1)
        }
        return source
    }

    @MainActor
    private static func require(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    private static func appearsInOrder(in source: String, _ needles: [String]) -> Bool {
        var remainder = source[...]
        for needle in needles {
            guard let range = remainder.range(of: needle) else { return false }
            remainder = remainder[range.upperBound...]
        }
        return true
    }

    private static func segment(in source: String, from start: String, to end: String) -> String {
        guard let startRange = source.range(of: start) else { return "" }
        let tail = source[startRange.lowerBound...]
        guard let endRange = tail.range(of: end) else { return String(tail) }
        return String(tail[..<endRange.lowerBound])
    }
}
