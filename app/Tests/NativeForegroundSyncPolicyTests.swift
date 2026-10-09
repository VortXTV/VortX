import Foundation

@main
enum NativeForegroundSyncPolicyTests {
    @MainActor
    static func main() async throws {
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

        try await twoDeviceColdHydration()
        try productionWiring()
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
        precondition(manager.contains("activeSyncDown?.capture != capture, activeSyncUp?.capture != capture"))
        precondition(manager.contains("self?.drainNativeMutationPush()"))
        precondition(manager.contains("self.ws === task, self.wsCapture == capture, self.isCurrent(capture) else { return }"))
        precondition(manager.contains("Task { await syncDown(credentialCapture: capture) }"))
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
}
