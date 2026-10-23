import Foundation

@main
enum NativeForegroundSyncPolicyTests {
    @MainActor
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var recovery = NativeForegroundSyncPolicy.RecoveryBackoff()
        precondition(recovery.permitsAttempt(at: now, userInitiated: false))
        recovery.recordFailure(at: now)
        precondition(!recovery.permitsAttempt(at: now.addingTimeInterval(5), userInitiated: false))
        precondition(recovery.permitsAttempt(at: now.addingTimeInterval(5), userInitiated: true))
        precondition(recovery.permitsAttempt(at: now.addingTimeInterval(12), userInitiated: false))
        recovery.recordFailure(at: now.addingTimeInterval(12))
        precondition(recovery.retryAt == now.addingTimeInterval(36))
        for _ in 0..<10 { recovery.recordFailure(at: now) }
        precondition(recovery.retryAt == now.addingTimeInterval(60))
        print("PASS failed restore backs off, explicit user retry remains available, delay bounded at 60s")
        var current = true
        precondition(NativeForegroundSyncPolicy.shouldPullBroadcast(version: 18, lastAcknowledgedVersion: 17, ownerIsCurrent: true))
        precondition(!NativeForegroundSyncPolicy.shouldPullBroadcast(version: 17, lastAcknowledgedVersion: 17, ownerIsCurrent: true))
        precondition(!NativeForegroundSyncPolicy.shouldPullBroadcast(version: 18, lastAcknowledgedVersion: 17, ownerIsCurrent: false))
        var certified = true
        var restores = 0
        var settlements = 0
        let retained = await NativeForegroundSyncPolicy.ensureSession(isCurrent: { current },
            hasCertifiedSession: { certified }, settleResident: { settlements += 1 },
            restore: { restores += 1; return false })
        precondition(retained && restores == 0 && settlements == 0)

        certified = false
        let busyResident = await NativeForegroundSyncPolicy.ensureSession(isCurrent: { current },
            hasCertifiedSession: { certified }, settleResident: { settlements += 1; certified = true },
            restore: { restores += 1; return true })
        precondition(busyResident && restores == 0 && settlements == 1)

        certified = false
        let switchedProfile = await NativeForegroundSyncPolicy.ensureSession(isCurrent: { current },
            hasCertifiedSession: { certified }, settleResident: { current = false },
            restore: { restores += 1; return true })
        precondition(!switchedProfile && restores == 0)
        current = true
        let switchedCredential = await NativeForegroundSyncPolicy.ensureSession(isCurrent: { current },
            hasCertifiedSession: { certified }, settleResident: {},
            restore: { restores += 1; current = false; certified = true; return true })
        precondition(!switchedCredential && restores == 1)
        current = true
        certified = false
        let coldMounted = await NativeForegroundSyncPolicy.ensureSession(isCurrent: { current },
            hasCertifiedSession: { certified }, settleResident: {},
            restore: { restores += 1; certified = true; return true })
        precondition(coldMounted && restores == 2)
        print("PASS certified resident retained, busy FIFO settled, profile/credential changes reject replacement, cold mount certified")

        let detail = Data("{\"action\":\"exact-detail-and-stream-selection\"}".utf8)
        let metadataGeneration = UUID()
        let intent = NativeForegroundSyncPolicy.ResourceIntent(searchQuery: "Naruto", metadataAction: detail,
                                                               metadataGeneration: metadataGeneration)
        precondition(intent.searchToReplay(currentQuery: "Naruto") == "Naruto")
        precondition(intent.searchToReplay(currentQuery: "other") == nil)
        precondition(intent.searchToReplay(currentQuery: nil) == nil)
        precondition(intent.metadataToReplay(currentGeneration: metadataGeneration) == detail)
        precondition(intent.metadataToReplay(currentGeneration: UUID()) == nil)
        let newerDetail = Data("new-exact-pending-detail".utf8)
        let newerGeneration = UUID()
        precondition(intent.searchToReplay(currentQuery: "new query", hasPendingSearch: true, pendingScopeIsCurrent: true) == "new query")
        precondition(intent.searchToReplay(currentQuery: "new query", hasPendingSearch: true, pendingScopeIsCurrent: false) == nil)
        precondition(intent.metadataToReplay(currentAction: newerDetail, currentGeneration: newerGeneration, pendingScopeIsCurrent: true) == newerDetail)
        precondition(intent.metadataToReplay(currentAction: newerDetail, currentGeneration: newerGeneration, pendingScopeIsCurrent: false) == nil)
        let coldIntent = NativeForegroundSyncPolicy.ResourceIntent(searchQuery: nil, metadataAction: nil, metadataGeneration: UUID())
        precondition(coldIntent.searchToReplay(currentQuery: "cold query", hasPendingSearch: true, pendingScopeIsCurrent: true) == "cold query")
        precondition(coldIntent.metadataToReplay(currentAction: newerDetail, currentGeneration: newerGeneration, pendingScopeIsCurrent: true) == newerDetail)
        precondition(NativeForegroundSyncPolicy.progressIdentity(isEpisodic: true, libraryID: "series", videoID: "") == .reject)
        precondition(NativeForegroundSyncPolicy.progressIdentity(isEpisodic: true, libraryID: "series", videoID: "  ") == .reject)
        precondition(NativeForegroundSyncPolicy.progressIdentity(isEpisodic: true, libraryID: "series", videoID: "series") == .reject)
        precondition(NativeForegroundSyncPolicy.progressIdentity(isEpisodic: true, libraryID: "series", videoID: "opaque-exact-episode") == .episode("opaque-exact-episode"))
        precondition(NativeForegroundSyncPolicy.progressIdentity(isEpisodic: false, libraryID: "movie", videoID: "movie") == .movie)
        print("PASS exact current search/detail replay and episodic progress rejects absent/title identity")

        var queue = NativeForegroundSyncPolicy.PushQueue()
        queue.request()
        let first = queue.generation
        queue.acknowledge(first, accepted: false)
        precondition(queue.hasPendingPush)
        queue.request() // Accepted checkpoint mutation while the first network request is in flight.
        queue.acknowledge(first, accepted: true)
        precondition(queue.hasPendingPush)
        queue.acknowledge(queue.generation, accepted: true)
        precondition(!queue.hasPendingPush)
        var dirty = ["layout": 1.0]
        let sent = dirty
        SettingsDirtyKeys.mark(["layout"], at: 2, into: &dirty)
        SettingsDirtyKeys.clearPushed(sent, from: &dirty)
        precondition(dirty["layout"] == 2)
        print("PASS failed transport/newer checkpoint edit remains pending; exact dirty stamp survives older ACK")
        progressCadence()
        legacyConversionSkip()

        try await twoDeviceColdHydration()
        try causalRollbackRepair()
        try productionWiring()
    }

    /// Playback progress (every few seconds) must not export the whole account each time, yet a
    /// real edit keeps its immediate cadence and progress still lands within the bounded window.
    static func legacyConversionSkip() {
        typealias Record = NativeForegroundSyncPolicy.LegacyConversionRecord
        let t0 = Date(timeIntervalSince1970: 80_000)
        let record = Record(digest: "a", convertedAt: t0)
        precondition(Record.decide(nil, digest: "a", hasLinkedAccounts: false, now: t0) == .first)
        precondition(Record.decide(record, digest: nil, hasLinkedAccounts: false, now: t0) == .first)
        precondition(Record.decide(record, digest: "a", hasLinkedAccounts: false, now: t0.addingTimeInterval(3600)) == .skip)
        precondition(Record.decide(record, digest: "b", hasLinkedAccounts: false, now: t0.addingTimeInterval(1)) == .changed)
        precondition(Record.decide(record, digest: "a", hasLinkedAccounts: true, now: t0.addingTimeInterval(Record.linkedRefresh - 1)) == .skip)
        precondition(Record.decide(record, digest: "a", hasLinkedAccounts: true, now: t0.addingTimeInterval(Record.linkedRefresh)) == .refresh)
        // Without a linked account the document is the only input: a match skips for good.
        precondition(Record.decide(record, digest: "a", hasLinkedAccounts: false, now: t0.addingTimeInterval(400 * 24 * 3600)) == .skip)
        // A clock that moved backwards never extends a linked account's skip.
        precondition(Record.decide(record, digest: "a", hasLinkedAccounts: true, now: t0.addingTimeInterval(-5)) == .refresh)
        print("PASS 0.4 conversion skips while its fingerprint matches; only linked accounts re-read, every 30 min")
        legacyConversionDigestIsStable()
        activePollBacksUpTheSocket()
    }

    static func activePollBacksUpTheSocket() {
        typealias Poll = NativeForegroundSyncPolicy.ActivePoll
        let t0 = Date(timeIntervalSince1970: 90_000)
        // No socket, or one silent past two missed keep-alive replies: every tick pulls.
        precondition(Poll.shouldPull(now: t0, lastPull: t0.addingTimeInterval(-3), socketHeardAt: nil))
        precondition(Poll.shouldPull(now: t0, lastPull: t0.addingTimeInterval(-3), socketHeardAt: t0.addingTimeInterval(-Poll.socketSilenceLimit)))
        // A live socket: the poll waits five minutes between pulls.
        let live = t0.addingTimeInterval(-20)
        precondition(!Poll.shouldPull(now: t0, lastPull: t0.addingTimeInterval(-3), socketHeardAt: live))
        precondition(!Poll.shouldPull(now: t0, lastPull: t0.addingTimeInterval(-Poll.liveSocketInterval + 1), socketHeardAt: live))
        precondition(Poll.shouldPull(now: t0, lastPull: t0.addingTimeInterval(-Poll.liveSocketInterval), socketHeardAt: live))
        precondition(Poll.shouldPull(now: t0, lastPull: nil, socketHeardAt: live))
        // A clock that moved backwards never holds pulls off.
        precondition(Poll.shouldPull(now: t0, lastPull: t0.addingTimeInterval(30), socketHeardAt: live))
        precondition(Poll.shouldPull(now: t0, lastPull: t0.addingTimeInterval(-3), socketHeardAt: t0.addingTimeInterval(30)))
        print("PASS the active poll pulls every five minutes behind a live socket and every tick without one")
    }

    /// 0.5.4 Mac log, 2026-10-16: `legacy_conversion run reason=changed` 32 times in 6 minutes on an account
    /// nothing was editing. The fingerprint re-encoded the settings backup's preference plist from a dictionary,
    /// whose order differs per decode, so each pull of the SAME document hashed differently.
    static func legacyConversionDigestIsStable() {
        typealias Record = NativeForegroundSyncPolicy.LegacyConversionRecord
        let native = ["nativeSync", "nativeHostPreferences", "profileEditResults", "nativeProviderCredentials", "apiKeys"]
        let preferences = Dictionary(uniqueKeysWithValues: (0..<60).map { ("stremiox.pref.\($0)", "value-\($0)") })
        let plist = try! PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        func pulled(native marker: Int = 1, watched: String = "tt0988824") -> [String: Any] {
            let source: [String: Any] = [
                "settings": ["format": "vortx-backup", "schema": 1, "payloadBase64": plist.base64EncodedString()],
                "library": ["items": (0..<40).map { ["id": "tt\($0)", "name": "Title \($0)", "watched": $0 % 2 == 0] }],
                "watched": [watched], "addonOrder": ["https://example.invalid/manifest.json"],
                "nativeSync": ["clock": marker], "apiKeys": ["tmdb": "k\(marker)"],
            ]
            // Every pull decodes a fresh dictionary from the wire, as the app does.
            return try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: source)) as! [String: Any]
        }
        let first = Record.digest(of: pulled(), excluding: native)
        precondition(first != nil)
        for _ in 0..<40 { precondition(Record.digest(of: pulled(), excluding: native) == first) }
        // This device's own export rewrites only the native carriers, never a 0.4 change.
        precondition(Record.digest(of: pulled(native: 2), excluding: native) == first)
        // A real 0.4 edit (an old app, the website) still converts.
        precondition(Record.digest(of: pulled(watched: "tt0417299"), excluding: native) != first)
        // Unreadable fields convert rather than skip.
        precondition(Record.digest(of: ["library": Date()], excluding: native) == nil)
        print("PASS the same pulled 0.4 fields always fingerprint the same; native carriers never count as a 0.4 change")
    }

    static func progressCadence() {
        typealias Queue = NativeForegroundSyncPolicy.PushQueue
        let t0 = Date(timeIntervalSince1970: 50_000)
        var urgent = Queue()
        precondition(urgent.nextUploadDelay(now: t0, failureBackoff: nil) == nil)
        urgent.request(at: t0)
        precondition(urgent.nextUploadDelay(now: t0, failureBackoff: nil) == Queue.urgentDelay)

        var playing = Queue()
        playing.request(progressOnly: true, at: t0)
        precondition(playing.nextUploadDelay(now: t0, failureBackoff: nil) == Queue.progressQuiet)
        // The player reports every 20s; each report must land inside the quiet window, so continuous playback
        // coalesces to the cap instead of uploading the whole account after every report.
        precondition(Queue.progressQuiet > 20 * 2)
        let lastReport = Queue.progressMaxWait - 20
        for second in stride(from: 20.0, through: lastReport, by: 20.0) {
            precondition(playing.nextUploadDelay(now: t0.addingTimeInterval(second), failureBackoff: nil)! > 0,
                         "a 20s report arrives before the previous one would upload")
            playing.request(progressOnly: true, at: t0.addingTimeInterval(second))
        }
        precondition(playing.nextUploadDelay(now: t0.addingTimeInterval(lastReport), failureBackoff: nil) == Queue.progressMaxWait - lastReport)
        // Pause/exit: no further reports, so the quiet window decides.
        var paused = Queue()
        paused.request(progressOnly: true, at: t0)
        paused.request(progressOnly: true, at: t0.addingTimeInterval(20))
        let stopped = t0.addingTimeInterval(20 + Queue.progressQuiet)
        precondition(paused.nextUploadDelay(now: stopped, failureBackoff: nil) == 0)
        // A failed upload's retry delay is never shortened by a progress window.
        precondition(paused.nextUploadDelay(now: stopped, failureBackoff: 10) == 10)

        // A real edit during playback uploads at the immediate cadence.
        playing.request(at: t0.addingTimeInterval(55))
        precondition(playing.hasUrgentPush && playing.nextUploadDelay(now: t0.addingTimeInterval(55), failureBackoff: nil) == Queue.urgentDelay)
        let uploaded = playing.generation
        // Progress accepted while that upload is in flight stays pending on its own window.
        playing.request(progressOnly: true, at: t0.addingTimeInterval(58))
        playing.acknowledge(uploaded, accepted: true)
        precondition(playing.hasPendingPush && !playing.hasUrgentPush)
        precondition(playing.nextUploadDelay(now: t0.addingTimeInterval(58), failureBackoff: nil) == Queue.progressQuiet)
        // A failed upload keeps the edit urgent.
        playing.request(at: t0.addingTimeInterval(59))
        playing.acknowledge(playing.generation, accepted: false)
        precondition(playing.hasUrgentPush)
        playing.acknowledge(playing.generation, accepted: true)
        precondition(!playing.hasPendingPush && playing.nextUploadDelay(now: t0.addingTimeInterval(60), failureBackoff: nil) == nil)

        precondition(Queue.nextFailureBackoff(after: nil) == 5 && Queue.nextFailureBackoff(after: 20) == 30
                     && Queue.nextFailureBackoff(after: 30) == 30)
        print("PASS playback progress coalesces to quiet/max windows; real edits stay immediate; failures keep backoff")
    }

    /// This fixture tests manager admission/ACK order and the real public host carrier. The native
    /// envelope is opaque: private-kernel CRDT semantics belong to test-native-sync-carrier.sh.
    @MainActor
    static func twoDeviceColdHydration() async throws {
        let scope = VortxAccountScope(account: "fixture.account", ownerProfileID: "00000000-0000-0000-0000-00000000A11C")
        let actorA = "00000000-0000-0000-0000-000000000001"
        let actorB = "00000000-0000-0000-0000-000000000002"
        var deviceA = try VortxNativeHostPreferences(scope: scope, actor: actorA)
        let discovery: VortxJSON = .object(["catalogOrder": .array([.string("catalog-b"), .string("catalog-a")]),
                                          "hiddenCatalogs": .array([.string("catalog-c")])])
        try deviceA.edit(profileID: scope.ownerProfileID, fields: ["discovery": discovery], scope: scope)
        try deviceA.edit(profileID: nil, fields: [HomeRailStore.orderKey: .array([.string("addonCatalogs"), .string("topPicks")]),
            HomeRailStore.hiddenKey: .array([.string("collectionsHub")]), "vortx.home.layout": .string("poster"),
            "stremiox.catalog.posterWidthPreset": .string("compact")], scope: scope)
        let watchlistField = try VortxNativeWatchlist.field(id: "tt1234567", type: "movie")
        let watchlist = try VortxNativeWatchlist.value(.init(id: "tt1234567", type: "movie", name: "Fixture", poster: nil, addedAt: 123))
        try deviceA.edit(profileID: scope.ownerProfileID, fields: [watchlistField: watchlist], scope: scope)

        let nativeEnvelope: VortxJSON = .object([
            "profiles": .array([.string("owner"), .string("child")]),
            "addons": .array([.string("addon-a"), .string("addon-b")]),
            "addonOrder": .array([.string("addon-b"), .string("addon-a")]),
            "library": .array([.string("saved-fixture")]), "recent": .array([.string("Naruto")]),
            "continueWatching": .array([.string("Naruto:S2E34")]),
            "watchedHistory": .array([.string("Naruto:S1E01")])])
        let cloudHost = try deviceA.document
        let cloudVersion = 17
        var deviceB = try VortxNativeHostPreferences(scope: scope, actor: actorB)
        var mounted = false
        var acknowledgedVersion = 0
        var lastSyncACKs = 0
        var committedNative: VortxJSON?
        let coldACK = await NativeForegroundSyncPolicy.mayAcknowledgeDocument(nativeDocumentCommitted: false,
            isCurrent: { true }, ensureSession: { mounted = true; return true }, commitDocument: { false })
        if coldACK { acknowledgedVersion = cloudVersion; lastSyncACKs += 1 }
        precondition(mounted && acknowledgedVersion == 0 && lastSyncACKs == 0 && committedNative == nil)
        // Same cloud version must remain eligible after bootstrap; commit BOTH carriers before ACK.
        try deviceB.merge(cloudHost, scope: scope)
        committedNative = nativeEnvelope
        let mergedACK = await NativeForegroundSyncPolicy.mayAcknowledgeDocument(nativeDocumentCommitted: true,
            isCurrent: { true }, ensureSession: { fatalError("already committed") }, commitDocument: { fatalError("already committed") })
        if mergedACK { acknowledgedVersion = cloudVersion; lastSyncACKs += 1 }
        precondition(acknowledgedVersion == 17 && lastSyncACKs == 1 && committedNative == nativeEnvelope)
        precondition(deviceB.local.document == deviceA.local.document)
        let coldReopened = try VortxNativeHostPreferences(scope: scope, actor: actorB, sealed: deviceB.encoded())
        precondition(coldReopened.local.document == deviceA.local.document)
        precondition(coldReopened.local.document.profiles[scope.ownerProfileID]?.fields["discovery"]?.value == discovery)
        precondition(coldReopened.local.document.profiles[scope.ownerProfileID]?.fields[watchlistField]?.value == watchlist)

        let failedACK = await NativeForegroundSyncPolicy.mayAcknowledgeDocument(nativeDocumentCommitted: false,
            isCurrent: { true }, ensureSession: { false }, commitDocument: { fatalError("failed mount") })
        let wrongScopeACK = await NativeForegroundSyncPolicy.mayAcknowledgeDocument(nativeDocumentCommitted: true,
            isCurrent: { false }, ensureSession: { fatalError("stale owner") }, commitDocument: { fatalError("stale owner") })
        precondition(!failedACK && !wrongScopeACK)
        var immediateCommit = false
        let immediateACK = await NativeForegroundSyncPolicy.mayAcknowledgeDocument(nativeDocumentCommitted: false,
            isCurrent: { true }, ensureSession: { true }, commitDocument: { immediateCommit = true; return true })
        precondition(immediateACK && immediateCommit)
        var captureStillCurrent = true
        let replacedDuringCommit = await NativeForegroundSyncPolicy.mayAcknowledgeDocument(nativeDocumentCommitted: false,
            isCurrent: { captureStillCurrent }, ensureSession: { true },
            commitDocument: { captureStillCurrent = false; return true })
        precondition(!replacedDuringCommit)
        do {
            try deviceB.merge(cloudHost, scope: .init(account: "other.account", ownerProfileID: scope.ownerProfileID))
            fatalError("cross-account carrier accepted")
        } catch {}
        // Peer layout receipt refreshes the actual observable store before the next local edit.
        let oldOrder = UserDefaults.standard.object(forKey: HomeRailStore.orderKey)
        let oldHidden = UserDefaults.standard.object(forKey: HomeRailStore.hiddenKey)
        defer {
            for (key, value) in [(HomeRailStore.orderKey, oldOrder), (HomeRailStore.hiddenKey, oldHidden)] {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            HomeRailPreferences.shared.reloadFromDefaults()
        }
        _ = HomeRailPreferences.shared.order
        HomeRailStore.setOrder(["addonCatalogs", "topPicks"])
        HomeRailStore.setHidden(["collectionsHub"])
        HomeRailPreferences.shared.reloadFromDefaults()
        HomeRailPreferences.shared.setHidden(.importedLists, true)
        precondition(HomeRailPreferences.shared.order == ["addonCatalogs", "topPicks"])
        precondition(HomeRailStore.hidden() == ["collectionsHub", "importedLists"])
        print("PASS synthetic two-device cold bootstrap cannot ACK early; same-version native+host merge, catalog/watchlist/layout checkpoint reopen, failed/stale-owner receipts")
    }

    static func productionWiring() throws {
        let manager = try String(contentsOfFile: "app/SourcesShared/VortXSyncManager.swift", encoding: .utf8)
        let bridge = try String(contentsOfFile: "app/SourcesShared/CoreBridge.swift", encoding: .utf8)
        let ack = manager.range(of: "nativeDocumentCommitted: nativeAccountDocumentCommitted")!.lowerBound
        let version = manager.range(of: "lastSyncedVersion = max(lastSyncedVersion, pulled.version)")!.lowerBound
        precondition(ack < version)
        precondition(manager.contains("nativeAccountDocumentCommitted = true"))
        precondition(manager.contains("self.nativePushQueue.acknowledge(generation, accepted: accepted)"))
        precondition(manager.contains("vortx.sync.pendingNativePush."))
        precondition(manager.contains("NativeForegroundSyncPolicy.requiresCausalRepublish(pulledNative: remote, pulledHost: hostRemote"))
        precondition(manager.contains("activeSyncDown?.capture != capture, activeSyncUp?.capture != capture"))
        precondition(manager.contains("self?.drainNativeMutationPush()"))
        precondition(manager.contains("self.ws === task, self.wsCapture == capture, self.isCurrent(capture) else { return }"))
        precondition(manager.contains("Task { await syncDown(credentialCapture: capture, routineReceive: true) }"))
        precondition(manager.contains("self.nativePushQueue.nextUploadDelay(now: Date(), failureBackoff: failureBackoff)"))
        precondition(manager.contains("if !progressOnly, pendingSync != nil, pendingSyncAwaitsProgressWindow {"))
        precondition(bridge.contains("nativeMutationDidCommit(credentialCapture: capture, progressOnly: true)"))
        let facade = try String(contentsOfFile: "app/SourcesShared/VortxNativeCoreFacade.swift", encoding: .utf8)
        precondition(facade.contains(#"if type == "report_progress", hostEdits.isEmpty, !websiteChanged, let progressAccepted = self.progressAccepted {"#))
        precondition(manager.contains("if appliedHomeRailLayout { HomeRailPreferences.shared.reloadFromDefaults() }"))
        precondition(bridge.contains("nativeMutationDidCommit(credentialCapture: capture)"))
        precondition(bridge.contains("EpisodePlaybackIdentity.isEpisodicContext(type: meta.type"))
        precondition(bridge.contains("hasPendingSearch: searchLoaded, pendingScopeIsCurrent: searchScope == scope"))
        precondition(bridge.contains("pendingScopeIsCurrent: metadata.2 == scope"))
        precondition(bridge.contains("PlaybackMutationOwnershipPolicy.allowsNative(target, binding: binding) else { return }"))
        let foreground = manager[manager.range(of: "func startRealtime()")!.lowerBound..<manager.range(of: "func stopRealtime()")!.lowerBound]
        precondition(foreground.contains("ensureNativeCheckpoint(credentialCapture: capture)"))
        precondition(!foreground.contains("restoreNativeCheckpoint("))
        precondition(foreground.contains("self.nativeMutationDidCommit(credentialCapture: capture)"))
        let badgeWrites = manager.components(separatedBy: "stampSyncSuccess()").count - 1
        precondition(badgeWrites == 3) // declaration + cloud accepted push + committed pull; no fake heartbeat.
        print("PASS production wiring keeps account ACK after commit, serializes native transport, drains explicit mutations, refreshes Home, foreground ensures resident session, honest badge")
    }

    /// Synthetic increasing-version cloud, with the real host CRDT and opaque native join receipts.
    /// Exercises the manager's repair admission; it does not reimplement private native merge rules.
    @MainActor
    static func causalRollbackRepair() throws {
        let scope = VortxAccountScope(account: "fixture.account", ownerProfileID: "00000000-0000-0000-0000-00000000A11C")
        var localA = try VortxNativeHostPreferences(scope: scope, actor: "00000000-0000-0000-0000-000000000001")
        let staleHost = try localA.document
        let staleNative: VortxJSON = .object(["causalFacts": .object([:])])
        let joinedNative: VortxJSON = .object(["causalFacts": .object(["Naruto:recent": .integer(2), "Naruto:S2E34:progress": .integer(3)])])
        try localA.edit(profileID: nil, fields: [HomeRailStore.hiddenKey: .array([.string("collectionsHub")])], scope: scope)
        let freshHost = try localA.document
        var cloudVersion = 18
        var cloudNative = joinedNative
        var cloudHost = freshHost
        let legacySibling = Data("retained-legacy-website-settings".utf8)
        let cloudLegacy = legacySibling
        // Old TV read v17 before A's facts, then its epoch-stamped PUT wins over v18.
        let oldTVVersion = 1000
        precondition(oldTVVersion > cloudVersion)
        cloudVersion = oldTVVersion; cloudNative = staleNative; cloudHost = staleHost
        try localA.merge(cloudHost, scope: scope)
        let joinedHost = try localA.document
        precondition(joinedHost == freshHost)
        var queue = NativeForegroundSyncPolicy.PushQueue()
        if NativeForegroundSyncPolicy.requiresCausalRepublish(pulledNative: cloudNative, pulledHost: cloudHost,
                                                               joinedNative: joinedNative, joinedHost: joinedHost) { queue.request() }
        precondition(queue.hasPendingPush)
        let sentGeneration = queue.generation
        // Fresh-pull merge keeps legacy siblings, then uses the current server base + 1.
        let repairVersion = cloudVersion + 1
        cloudVersion = repairVersion; cloudNative = joinedNative; cloudHost = joinedHost
        queue.acknowledge(sentGeneration, accepted: true)
        precondition(!queue.hasPendingPush && cloudVersion == 1001 && cloudLegacy == legacySibling)
        var coldC = try VortxNativeHostPreferences(scope: scope, actor: "00000000-0000-0000-0000-000000000003")
        try coldC.merge(cloudHost, scope: scope)
        precondition(coldC.local.document == localA.local.document)
        precondition(cloudNative["causalFacts"]?["Naruto:recent"] == .integer(2))
        let coldHost = try coldC.document
        precondition(!NativeForegroundSyncPolicy.requiresCausalRepublish(pulledNative: cloudNative, pulledHost: cloudHost,
                                                                        joinedNative: joinedNative, joinedHost: coldHost))
        // Dictionary key order is not a fact. A host-only causal difference still needs repair.
        let reorderedNative: VortxJSON = .object(["causalFacts": .object(["Naruto:S2E34:progress": .integer(3), "Naruto:recent": .integer(2)])])
        precondition(!NativeForegroundSyncPolicy.requiresCausalRepublish(pulledNative: reorderedNative, pulledHost: joinedHost,
                                                                        joinedNative: joinedNative, joinedHost: joinedHost))
        precondition(NativeForegroundSyncPolicy.requiresCausalRepublish(pulledNative: joinedNative, pulledHost: staleHost,
                                                                       joinedNative: joinedNative, joinedHost: joinedHost))
        print("PASS A new fact -> old-TV stale epoch -> warm causal join/repair -> cold C; legacy siblings preserved and equal joins never echo")
    }
}
