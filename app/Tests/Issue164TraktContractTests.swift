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
        require(occurrences(of: "dispatchLifecycle(meta", in: coordinator) >= 5,
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
        require(iosHome.contains("menu: continueWatchingSelection.source == .trakt")
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
        require(auth.contains("private static let sessionAccount = \"vortx.trakt.sessionID\"")
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
        require(auth.contains("await signOut(ifCurrent: expectedSession)"),
                "an old Trakt refresh failure must not sign out a replacement account")

        // SIMKL has the same exact-session transport authority as Trakt.
        require(simklAuth.contains("private static let sessionAccount = \"vortx.simkl.sessionID\"")
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
                "urlSession.data(for: request)",
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

        // A Trakt-only account boundary cannot reopen provider-neutral SIMKL completion.
        let traktInvalidation = segment(
            in: coordinator,
            from: "private func invalidateTraktSession()",
            to: "private func recordCompletion("
        )
        require(traktInvalidation.contains("traktCompleted = false")
                    && !traktInvalidation.contains("simklCompleted")
                    && coordinator.contains("if provider.id == \"simkl\", !sendSIMKL { return }"),
                "Trakt boundary invalidation must preserve the SIMKL completion latch")

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
                    && catalogs.contains("TraktAuth.storedSessionID == sessionID"),
                "private imported Trakt lists must be fingerprinted and cleared on every auth boundary")
        require(myLists.contains("validToken(for: expectedSession)")
                    && myLists.contains("connectionSessionID: list.requiresConnection ? sessionID : nil")
                    && occurrences(of: "TraktAuth.storedSessionID == sessionID", in: myLists) >= 3,
                "private list reads and publication must remain bound to their captured Trakt session")

        // A failed direct resume keeps the remote card's offset and episode identity through source choice.
        require(tvHome.contains("resumeSeconds: traktSessionID == nil ? nil : item.resumeSeconds")
                    && tvHome.contains("videoID: traktSessionID == nil ? nil : item.state.videoId")
                    && tvHome.contains("initialResumeSeconds: $0.resumeSeconds")
                    && tvSharedUI.contains("else if let onDetails"),
                "tvOS direct-resume fallback must retain the Trakt resume target")
        require(tvDetail.contains("var initialResumeSeconds: Double? = nil")
                    && tvDetail.contains("var initialVideoID: String? = nil")
                    && tvDetail.contains("didConsumeInitialStart")
                    && tvDetail.contains("return initialStartAtSeconds"),
                "tvOS detail/source selection must consume the remote offset on the first content play")
        require(iosHome.contains("resumeSeconds: carriesTraktResume ? item.resumeSeconds : nil")
                    && iosHome.contains("videoID: carriesTraktResume ? item.cwVideoId : nil")
                    && iosHome.contains("initialResumeSeconds: target.resumeSeconds"),
                "iOS direct-resume fallback must retain the Trakt resume target")
        require(iosDetail.contains("var initialResumeSeconds: Double? = nil")
                    && iosDetail.contains("var initialVideoID: String? = nil")
                    && iosDetail.contains("didConsumeInitialResume")
                    && iosDetail.contains("didConsumeInitialStart")
                    && iosDetail.contains("return initialResumeSeconds"),
                "iOS detail/source selection must consume the remote offset on the first content play")

        // Final review boundaries: stale login attempts, aggregate reads, Upcoming, and remote CW privacy.
        require(auth.contains("struct TraktLoginAttemptAuthority")
                    && auth.contains("expectedLoginGeneration: loginGeneration")
                    && auth.contains("loginAttempts.owns(code: deviceCode")
                    && auth.contains("func cancelLoginAttempt()"),
                "Trakt device-login responses must remain owned by one live generation")
        require(simklAuth.contains("struct SIMKLLoginAttemptAuthority")
                    && simklAuth.contains("expectedLoginGeneration: loginGeneration")
                    && simklAuth.contains("loginAttempts.owns(code: userCode")
                    && simklAuth.contains("func cancelLoginAttempt()"),
                "SIMKL PIN responses must remain owned by one live generation")
        require(occurrences(of: "catch SIMKLError.sessionChanged", in: simklService) >= 2
                    && !simklService.contains("out += (try? await list(")
                    && !simklService.contains("guard let leg = try? await ratingsRead"),
                "SIMKL aggregate reads must rethrow account boundaries instead of returning mixed partial data")
        require(releaseCalendar.contains("SIMKLAuthBoundary.observe(key: \"release-calendar-model\")")
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
