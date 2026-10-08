import Foundation
import CryptoKit

/// Runs only in the explicit ABI integration harness, against a caller-supplied private artifact.
/// No app process, real account, media decoder or external provider is involved.
@main enum VortxNativeLiveABITests {
    static func check(_ condition: Bool, line: Int = #line) { precondition(condition, "live ABI assertion at line \(line)") }
    static func main() async throws {
        let runtime = try VortxNativeRuntime(abi: VortxCABI(), ownerID: "fixture-owner", ownerName: "Fixture")
        let add = try runtime.dispatch(#"{"type":"add_profile","id":"fixture-kid","name":"Kid"}"#, now: 1000)
        check(add.contains("\"ok\":true"))
        let progress = try runtime.dispatch(#"{"type":"report_progress","metaId":"tt-fixture","videoId":"tt-fixture:1:2","name":"Fixture","positionMs":120000,"durationMs":1200000}"#, now: 1001)
        check(progress.contains("\"ok\":true"))
        let captured = try runtime.stateJSON()
        check(try runtime.takeDeltaJSON() != "{}")
        check(try runtime.takeDeltaJSON() == "{}")
        runtime.close()
        let cold = try VortxNativeRuntime(abi: VortxCABI(), snapshot: captured)
        check(try cold.stateJSON() == captured)
        check(try cold.takeDeltaJSON() == "{}")
        cold.close()

        let fixture = try JSONDecoder().decode([String: VortxJSON].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let port = CommandLine.arguments[2]
        let addon = VortxResourceAddon(id: "source-identity", transportUrl: "http://127.0.0.1:\(port)/manifest.json", manifest: fixture["manifest"])
        let bridge = VortxResourceBridge(transport: try VortxCResourceTransport())
        for resource in [VortxResourceRequest.Resource.catalog, .meta, .stream, .subtitles] {
            let id = resource == .catalog ? "popular" : "tt-fixture"
            let snapshot = try await bridge.load(ownerID: "fixture-owner", request: .init(resource: resource, type: "series", id: id), addons: [addon])
            check(snapshot.groups.count == 1 && snapshot.groups[0].addonId == "source-identity")
            check(snapshot.groups[0].status == .ready)
            check(snapshot.groups[0].content == fixture[resource.rawValue])
        }
        let empty = try await bridge.load(ownerID: "fixture-owner", request: .init(resource: .stream, type: "series", id: "tt-fixture"), addons: [])
        check(empty.groups.isEmpty)
        bridge.invalidate()
        let scope = VortxAccountScope(account: "fixture-account", ownerProfileID: "fixture-owner")
        let checkpoint = try VortxEncryptedCheckpointStore(directory: URL(fileURLWithPath: CommandLine.arguments[3]), key: SymmetricKey(size: .bits256))
        let session = try VortxNativeSession(scope: scope, ownerName: "Fixture", abi: VortxCABI(), store: checkpoint,
                                            transport: VortxCResourceTransport(), allowNewAccount: true)
        let install: VortxJSON = .object(["type": .string("install_addon"), "profileId": .string(scope.ownerProfileID),
                                         "addon": .object(["transportUrl": .string(addon.transportUrl), "manifest": addon.manifest!])])
        _ = try await session.dispatch([String(decoding: JSONEncoder().encode(install), as: UTF8.self)], now: 1000)
        let acceptedRegistry = try await session.resourceRegistry()
        check(acceptedRegistry.count == 1 && acceptedRegistry[0].transportUrl == addon.transportUrl)
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: acceptedRegistry, changed: { _ in })
        func dispatch(_ action: [String: Any], field: String) throws {
            check(facade.dispatch(data: try JSONSerialization.data(withJSONObject: action), field: field))
        }
        func field(_ name: String) throws -> VortxJSON { try JSONDecoder().decode(VortxJSON.self, from: facade.stateData(name)!) }
        for screen in ["board", "search"] {
            try dispatch(["action": "Load", "args": ["model": "CatalogsWithExtra", "args": ["extra": screen == "search" ? [["search", "fixture"]] : []]]], field: screen)
            check(try field(screen)["catalogs"]?.array?.first?.array?.first?["content"]?["type"] == .string("Loading"))
            try dispatch(["action": "CatalogsWithExtra", "args": ["action": "LoadRange", "args": ["start": 0, "end": 30]]], field: screen)
            await facade.settled()
            check(try field(screen)["catalogs"]?.array?.count == 1)
            try dispatch(["action": "CatalogsWithExtra", "args": ["action": "LoadNextPage", "args": 0]], field: screen)
            await facade.settled()
            check(try field(screen)["catalogs"]?.array?.first?.array?.count == 2)
        }
        try dispatch(["action": "Load", "args": ["model": "CatalogWithFilters", "args": NSNull()]], field: "discover")
        await facade.settled(); check(try field("discover")["catalog"]?.array?.count == 1)
        check(try field("discover")["selectable"]?["next_page"] != .null)
        try dispatch(["action": "CatalogWithFilters", "args": ["action": "LoadNextPage"]], field: "discover")
        await facade.settled(); check(try field("discover")["catalog"]?.array?.count == 2)
        let metaPath = ["resource": "meta", "type": "series", "id": "tt-fixture", "extra": []] as [String: Any]
        let streamPath = ["resource": "stream", "type": "series", "id": "tt-fixture:1:2", "extra": []] as [String: Any]
        try dispatch(["action": "Load", "args": ["model": "MetaDetails", "args": ["metaPath": metaPath, "streamPath": streamPath]]], field: "meta_details")
        await facade.settled(); check(try field("meta_details")["streams"]?.array?.count == 1)
        try dispatch(["action": "Load", "args": ["model": "Subtitles", "args": ["resource": "subtitles", "type": "series", "id": "tt-fixture", "extra": []]]], field: "subtitles")
        await facade.settled(); check(try field("subtitles").array?.first?["content"]?["content"]?.array?.count == 2)
        try dispatch(["action": "Load", "args": ["model": "LibraryWithFilters", "args": ["request": ["sort": "lastwatched", "page": 1]]]], field: "library")
        await facade.settled(); check(try field("library")["catalog"] == .array([]))
        check(try field("library")["selectable"]?["types"]?.array?.first?["request"]?["sort"] == .string("lastwatched"))
        try dispatch(["action": "Load", "args": ["model": "LocalSearch"]], field: "local_search")
        check(try field("local_search")["searchResults"] == .array([]))
        check(try await !facade.addCatalogItem(id: "tt-fixture", type: "series", profileID: scope.ownerProfileID, allowInsert: false))
        let detailBeforeAutoAdd = try field("meta_details")
        check(try await facade.addCatalogItem(id: "tt-fixture", type: "series", profileID: scope.ownerProfileID, allowInsert: true))
        check(try field("library")["catalog"]?.array?.count == 1)
        try dispatch(["action": "Load", "args": ["model": "LibraryWithFilters", "args": ["request": ["type": "series", "sort": "name", "page": 1]]]], field: "library")
        check(try field("library")["catalog"]?.array?.count == 1)
        check(try field("library")["selectable"]?["types"]?.array?.contains { $0["type"] == .string("series") && $0["selected"] == .bool(true) } == true)
        check(try field("library")["selectable"]?["sorts"]?.array?.contains { $0["sort"] == .string("name") && $0["selected"] == .bool(true) } == true)
        try dispatch(["action": "Search", "args": ["searchQuery": "fixture", "maxResults": 10]], field: "local_search")
        check(try field("local_search")["searchResults"]?.array?.map { $0["id"] } == [.string("tt-fixture")])
        check(try field("meta_details")["selected"] == detailBeforeAutoAdd["selected"])
        check(try field("meta_details")["metaItems"] == detailBeforeAutoAdd["metaItems"])
        do { _ = try await facade.addCatalogItem(id: "tt-fixture", type: "series", profileID: "kid", allowInsert: true); fatalError("stale profile auto-add admitted") }
        catch VortxNativeError.superseded {}
        try dispatch(["action": "Ctx", "args": ["action": "AddToLibrary", "args": ["id": "tt-fixture", "type": "series", "name": "Fixture"]]], field: "ctx")
        await facade.settled(); check(try field("library")["catalog"]?.array?.count == 1)
        try dispatch(["action": "Vortx", "args": ["type": "add_profile", "id": "kid", "name": "Kid"]], field: "native_state")
        try dispatch(["action": "Vortx", "args": ["type": "report_progress", "metaId": "tt-fixture", "name": "Fixture", "positionMs": 120000, "durationMs": 1200000]], field: "native_state")
        await facade.settled()
        check(try field("native_state")["roster"]?["profiles"]?["kid"] != nil)
        check(try field("native_state")["libraries"]?["fixture-owner"]?["resume"]?["tt-fixture"] != nil)
        let selected: [String: Any] = ["metaRequest": ["base": addon.transportUrl, "path": metaPath],
                                      "streamRequest": ["base": addon.transportUrl, "path": streamPath],
                                      "stream": ["url": "https://media.example/selected.m3u8"]]
        try dispatch(["action": "Load", "args": ["model": "Player", "args": selected]], field: "player")
        try dispatch(["action": "Player", "args": ["action": "TimeChanged", "args": ["time": 120000, "duration": 1200001]]], field: "player")
        await facade.settled()
        check(try field("native_state")["libraries"]?["fixture-owner"]?["watchContexts"]?["tt-fixture:1:2"]?["durationMs"] == .integer(1200001))
        let durable = try JSONDecoder().decode(VortxJSON.self, from: Data(checkpoint.read(scope: scope)!.utf8))
        check(try durable == field("native_state"))
        check(!facade.dispatch(data: Data(#"{"action":"Ctx","args":{"action":"LoginWithToken","args":"not-a-real-token"}}"#.utf8), field: nil))
        check(facade.lastFailure == "unsupported_action")
        let oldBinding = facade.registryBinding!
        try dispatch(["action": "Vortx", "args": ["type": "switch_profile", "id": "kid"]], field: "native_state")
        await facade.settled()
        do { try await facade.rebindRegistry([addon], expected: oldBinding); fatalError("stale profile rebound registry") }
        catch VortxNativeError.superseded {}
        // New profiles share the owner's installed registry. The accepted kernel query is now
        // rebound automatically; no restart/manual host registry injection is needed.
        check(facade.lastFailure == nil)
        try dispatch(["action": "Load", "args": ["model": "CatalogWithFilters", "args": NSNull()]], field: "discover")
        await facade.settled(); check(try field("discover")["catalog"]?.array?.count == 1)
        let exported = try await facade.mergeSyncDocument(nil)
        check(exported["scope"] == .string(scope.account) && exported["activeProfileId"] == nil)
        check(try await facade.mergeSyncDocument(exported) == exported)
        try dispatch(["action": "Load", "args": ["model": "CatalogWithFilters", "args": NSNull()]], field: "discover")
        await facade.settled(); check(try field("discover")["catalog"]?.array?.count == 1)
        let kidProgress: VortxJSON = .object(["type": .string("report_progress"), "metaId": .string("unsaved-kid"), "videoId": .string("opaque-kid-episode"),
                                             "name": .string("Kid episode"), "positionMs": .integer(3001), "durationMs": .integer(100001),
                                             "metadata": .object(["type": .string("series")])])
        check(!facade.dispatchForProfile(kidProgress, profileID: scope.ownerProfileID))
        check(facade.dispatchForProfile(kidProgress, profileID: "kid")); await facade.settled()
        check(try field("library")["catalog"] == .array([]))
        check(try field("continue_watching_preview")["items"]?.array?.first?["state"]?["video_id"] == .string("opaque-kid-episode"))
        check(facade.cachedResumeSeconds(id: "opaque-kid-episode") == 3.001)
        check(try await facade.resumeSeconds(id: "opaque-kid-episode", profileID: "kid") == 3.001)
        check(!facade.setWatchedVideos(metaID: "tt-fixture", videoIDs: [], name: "Fixture", type: "series", poster: nil,
                                       watched: true, profileID: "kid"))
        check(facade.lastFailure == "stale_or_empty_watched_inventory")
        check(facade.setWatchedVideos(metaID: "tt-fixture", videoIDs: ["opaque-kid-a", "opaque-kid-b"], name: "Fixture", type: "series", poster: nil,
                                      watched: true, profileID: "kid"))
        await facade.settled()
        check(try field("native_playback")["watchedVideoIdsByTitle"]?["tt-fixture"]?.array?.contains(.string("opaque-kid-a")) == true)
        check(try field("native_playback")["watchedVideoIdsByTitle"]?["tt-fixture"]?.array?.contains(.string("opaque-kid-b")) == true)
        let watchedMovie: VortxJSON = .object(["type": .string("mark_watched"), "metaId": .string("unsaved-movie"), "name": .string("Watched without saving"),
                                              "metadata": .object(["type": .string("movie")])])
        check(facade.dispatchForProfile(watchedMovie, profileID: "kid")); await facade.settled()
        check(try field("native_history")["items"]?.array?.contains { $0["_id"] == .string("unsaved-movie") && $0["state"]?["timesWatched"] == .integer(1) } == true)
        check(try field("library")["catalog"] == .array([]))
        // Ctx add-on mutations use the exact kernel actions. Invalid new descriptors are rejected before
        // old membership is considered; replacement, order and removal are committed through one FIFO.
        let replacementURL = "http://127.0.0.1:\(port)/replacement/manifest.json"
        let manifestObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture["manifest"]!))
        let originalDescriptor: [String: Any] = ["transportUrl": addon.transportUrl, "manifest": manifestObject]
        let replacementDescriptor: [String: Any] = ["transportUrl": replacementURL, "manifest": manifestObject]
        let invalidReplacement: [String: Any] = ["action": "Ctx", "args": [
            "action": "ReplaceAddonLocal", "args": ["old": originalDescriptor,
                                                        "new": ["transportUrl": replacementURL, "manifest": ["id": "bad"]]],
        ]]
        check(!facade.dispatch(data: try JSONSerialization.data(withJSONObject: invalidReplacement), field: "ctx"))
        check(facade.lastFailure == "invalid_addon_replacement")
        check(try field("ctx")["profile"]?["addons"]?.array?.map { $0["transportUrl"] } == [.string(addon.transportUrl)])
        try dispatch(["action": "Ctx", "args": ["action": "ReplaceAddonLocal", "args": ["old": originalDescriptor, "new": replacementDescriptor]]], field: "ctx")
        await facade.settled()
        check(try field("ctx")["profile"]?["addons"]?.array?.map { $0["transportUrl"] } == [.string(replacementURL)])
        try dispatch(["action": "Ctx", "args": ["action": "UninstallAddonLocal", "args": replacementDescriptor]], field: "ctx")
        await facade.settled()
        check(try field("ctx")["profile"]?["addons"] == .array([]))
        let lastState = try await session.stateJSON()
        await facade.shutdown()
        let reopened = try VortxNativeSession(scope: scope, ownerName: "Fixture", abi: VortxCABI(), store: checkpoint, transport: VortxCResourceTransport())
        check(try await reopened.stateJSON() == lastState)
        await reopened.close()

        // Full public Apple extractor -> real C import -> single sealed checkpoint -> cold reopen.
        // The fixture uses no live credentials, provider call or media load.
        var owner = UserProfile(id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!, name: "Owner", avatar: "O", isOwner: true)
        owner.pin = UserProfile.pinHash("1234", profileID: owner.id)
        let child = UserProfile(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, name: "Child", avatar: "C")
        let legacyScope = VortxAccountScope(account: "fixture-legacy-account", ownerProfileID: owner.id.uuidString)
        var source = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "app/Tests/Fixtures/legacy-bootstrap-apple.json"))) as! [String: Any]
        source.removeValue(forKey: "settings") // fixture's deliberately opaque placeholder is not a real settings backup
        source["apiKeys"] = ["provider": "fixture-must-not-persist"]
        let sourceBytes = try JSONSerialization.data(withJSONObject: source)
        let material = try VortxLegacyBootstrapMaterial.encode(document: sourceBytes, roster: [owner, child], ownerProfileID: owner.id, rosterModifiedSeconds: 1720000000.1234)
        let archive = try VortxNativeBootstrapArchive.encode(document: sourceBytes, material: material)
        let action: VortxJSON = .object(["type": .string("import_legacy_sync"), "scope": .string(legacyScope.account), "ownerProfileId": .string(legacyScope.ownerProfileID),
                                         "material": try JSONDecoder().decode(VortxJSON.self, from: material)])
        let rawImport = String(decoding: try JSONEncoder().encode(action), as: UTF8.self)
        let detached = try VortxNativeSession.detachedLegacySync(scope: legacyScope, ownerName: owner.name, material: material, abi: VortxCABI())
        check(detached["scope"] == .string(legacyScope.account) && detached["legacyImport"]?["schemaVersion"] == .integer(1))
        let rejectedScope = VortxAccountScope(account: "fixture-rejected-import", ownerProfileID: owner.id.uuidString)
        let rejectedStore = try VortxEncryptedCheckpointStore(directory: URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent("rejected"), key: SymmetricKey(size: .bits256))
        do {
            _ = try VortxNativeSession(scope: rejectedScope, ownerName: "Owner", abi: VortxCABI(), store: rejectedStore,
                                       transport: VortxCResourceTransport(), allowNewAccount: true, initialActions: [rawImport])
            fatalError("wrong-scope first import committed")
        } catch VortxNativeError.invalidResponse {}
        check(try rejectedStore.read(scope: rejectedScope) == nil)
        let migrationStore = try VortxEncryptedCheckpointStore(directory: URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent("migration"),
                                                               key: SymmetricKey(size: .bits256), bootstrap: archive, bootstrapScope: legacyScope)
        let migrated = try VortxNativeSession(scope: legacyScope, ownerName: "Owner", abi: VortxCABI(), store: migrationStore, transport: VortxCResourceTransport(),
                                              allowNewAccount: true, initialActions: [rawImport])
        let migrationState = try await migrated.stateJSON()
        try migrationStore.rememberAuthenticatedScope(legacyScope)
        let recovery = try migrationStore.recovery(account: legacyScope.account)
        check(recovery?.scope == legacyScope && recovery?.state == migrationState && recovery?.bootstrap == archive)
        let stateObject = try JSONDecoder().decode(VortxJSON.self, from: Data(migrationState.utf8))
        check(stateObject["roster"]?["profiles"]?[owner.id.uuidString]?["pin"] == .string(owner.pin!))
        check(stateObject["nativeSync"]?["legacyImport"]?["schemaVersion"] == .integer(1))
        check(stateObject["libraries"]?[child.id.uuidString]?["items"] == .array([]))
        let remoteCarrier = stateObject["nativeSync"]!
        try VortxNativeSession.validateLegacyCompatibility(scope: legacyScope, ownerName: owner.name, snapshot: migrationState,
                                                          nativeSync: nil, material: material, abi: VortxCABI())
        try VortxNativeSession.validateLegacyCompatibility(scope: legacyScope, ownerName: owner.name, snapshot: nil,
                                                          nativeSync: remoteCarrier, material: material, abi: VortxCABI())
        let localCandidate = try VortxNativeRuntime(abi: VortxCABI(), snapshot: migrationState)
        _ = try localCandidate.dispatch(#"{"type":"mark_watched","metaId":"new-native-movie","name":"New native movie","metadata":{"type":"movie"}}"#, now: 1720000010)
        try VortxNativeSession.validateLegacyCompatibility(scope: legacyScope, ownerName: owner.name, snapshot: localCandidate.stateJSON(),
                                                          nativeSync: nil, material: material, abi: VortxCABI())
        localCandidate.close()
        if case .object(var noReceipt) = remoteCarrier {
            noReceipt.removeValue(forKey: "legacyImport")
            do { try VortxNativeSession.validateLegacyCompatibility(scope: legacyScope, ownerName: owner.name, snapshot: nil,
                                                                   nativeSync: .object(noReceipt), material: material, abi: VortxCABI()); fatalError("missing peer import receipt silently seeded") }
            catch VortxNativeError.invalidSnapshot {}
        }
        var harmlessSource = source; harmlessSource["futureTheme"] = ["color": "blue", "unknown": true]
        let harmlessMaterial = try VortxLegacyBootstrapMaterial.encode(document: JSONSerialization.data(withJSONObject: harmlessSource), roster: [owner, child], ownerProfileID: owner.id, rosterModifiedSeconds: 1720000000.1234)
        check(try JSONDecoder().decode(VortxJSON.self, from: harmlessMaterial) == JSONDecoder().decode(VortxJSON.self, from: material))
        try VortxNativeSession.validateLegacyCompatibility(scope: legacyScope, ownerName: owner.name, snapshot: migrationState,
                                                          nativeSync: remoteCarrier, material: harmlessMaterial, abi: VortxCABI())
        var pendingSource = source; pendingSource["nativeSync"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(remoteCarrier))
        pendingSource["profileEdits"] = ["editedAt": 1720000100000.5, "roster": [["id": owner.id.uuidString, "name": "Pending web rename"]]]
        do { _ = try VortxLegacyBootstrapMaterial.encode(document: JSONSerialization.data(withJSONObject: pendingSource), roster: [owner, child], ownerProfileID: owner.id, rosterModifiedSeconds: 1720000000.1234); fatalError("native carrier bypassed pending web edits") }
        catch is VortxLegacyBootstrapMaterial.ReconciliationRequired {}
        _ = try await migrated.dispatch([rawImport], now: 10)
        check(try await migrated.stateJSON() == migrationState) // exact replay cannot change imported clocks
        var different = try JSONSerialization.jsonObject(with: Data(rawImport.utf8)) as! [String: Any]
        var changedMaterial = different["material"] as! [String: Any]; changedMaterial["rosterModifiedSeconds"] = 1720000001.1234
        different["material"] = changedMaterial
        do { _ = try await migrated.dispatch([String(decoding: JSONSerialization.data(withJSONObject: different), as: UTF8.self)], now: 11); fatalError("different legacy material replaced native authority") }
        catch VortxNativeError.invalidResponse {}
        check(try migrationStore.read(scope: legacyScope) == migrationState)
        // A changed field without a new source clock remains unsupported, including on kernels
        // that now reconcile properly timestamped old-client edits.
        var unsupportedMaterial = try JSONSerialization.jsonObject(with: material) as! [String: Any]
        var unsupportedProfiles = unsupportedMaterial["roster"] as! [[String: Any]]
        unsupportedProfiles[0]["name"] = "Unclocked legacy rename"
        unsupportedMaterial["roster"] = unsupportedProfiles
        let changedBytes = try JSONSerialization.data(withJSONObject: unsupportedMaterial)
        for remote in [nil, remoteCarrier] {
            do { try VortxNativeSession.validateLegacyCompatibility(scope: legacyScope, ownerName: owner.name, snapshot: migrationState,
                                                                   nativeSync: remote, material: changedBytes, abi: VortxCABI()); fatalError("changed legacy material silently mounted") }
            catch VortxNativeError.invalidResponse {}
        }
        do { try VortxNativeSession.validateLegacyCompatibility(scope: legacyScope, ownerName: owner.name, snapshot: nil,
                                                               nativeSync: remoteCarrier, material: changedBytes, abi: VortxCABI()); fatalError("incompatible native peer adopted") }
        catch VortxNativeError.invalidResponse {}
        let merge = String(decoding: try JSONEncoder().encode(VortxJSON.object(["type": .string("merge_native_sync"), "document": remoteCarrier])), as: UTF8.self)
        do { _ = try await migrated.dispatch([merge], now: 12, legacyMaterial: changedBytes); fatalError("warm sync committed incompatible legacy source") }
        catch VortxNativeError.invalidResponse {}
        check(try migrationStore.read(scope: legacyScope) == migrationState)
        _ = try await migrated.dispatch([merge], now: 13, legacyMaterial: material)
        check(try migrationStore.read(scope: legacyScope) == migrationState)
        var acceptedMigrationState = migrationState
        if remoteCarrier["legacyImport"]?["baseline"] != nil {
            var clockedMaterial = try JSONSerialization.jsonObject(with: material) as! [String: Any]
            var clockedRoster = clockedMaterial["roster"] as! [[String: Any]]
            let ownerIndex = clockedRoster.firstIndex { $0["id"] as? String == owner.id.uuidString }!
            clockedRoster[ownerIndex]["name"] = "Timestamped peer rename"
            clockedMaterial["roster"] = clockedRoster; clockedMaterial["rosterModifiedSeconds"] = 1720000100.0
            let clockedBytes = try JSONSerialization.data(withJSONObject: clockedMaterial)
            _ = try await migrated.dispatch([#"{"type":"get_state"}"#], now: 1720000200, legacyMaterial: clockedBytes)
            acceptedMigrationState = try await migrated.stateJSON()
            let acceptedState = try JSONDecoder().decode(VortxJSON.self, from: Data(acceptedMigrationState.utf8))
            check(acceptedState["roster"]?["profiles"]?[owner.id.uuidString]?["name"] == .string("Timestamped peer rename"))
            check(acceptedState["nativeSync"]?["legacyImport"]?["fingerprint"] == remoteCarrier["legacyImport"]?["fingerprint"])
            check(try migrationStore.readLegacyMaterial(scope: legacyScope).map { try JSONDecoder().decode(VortxJSON.self, from: $0) } == JSONDecoder().decode(VortxJSON.self, from: material))
            _ = try await migrated.dispatch([#"{"type":"get_state"}"#], now: 1720000300, legacyMaterial: material)
            check(try await migrated.stateJSON() == acceptedMigrationState) // acknowledged ancestor cannot undo rename
            try VortxNativeSession.validateLegacyCompatibility(scope: legacyScope, ownerName: owner.name, snapshot: nil,
                nativeSync: acceptedState["nativeSync"], material: clockedBytes, abi: VortxCABI())
            print("Live private legacy reconciliation: clocked peer rename, immutable original receipt/archive, ancestor no-op and cold native peer admission passed")
        }
        await migrated.close()
        let migratedCold = try VortxNativeSession(scope: legacyScope, ownerName: "Owner", abi: VortxCABI(), store: migrationStore, transport: VortxCResourceTransport())
        check(try await migratedCold.stateJSON() == acceptedMigrationState)
        _ = try await migratedCold.dispatch([#"{"type":"switch_profile","id":"10000000-0000-0000-0000-000000000001"}"#], now: 11)
        check(try await migratedCold.resumeSeconds(id: "opaque-episode", profileID: child.id.uuidString) == 12.345)
        let profilesFacade = try await VortxNativeCoreFacade.create(session: migratedCold, registry: [], changed: { _ in })
        var editedChild = child; editedChild.name = "Updated Child"; editedChild.avatar = "moon"; editedChild.textScale = 1.25
        let profileMutation = try VortxNativeProfiles.mutation(editedChild, previous: child, ownerID: owner.id.uuidString)
        try await profilesFacade.mutateProfiles(profileMutation.0, hostEdits: [profileMutation.1], expectedProfileID: child.id.uuidString)
        await profilesFacade.settled()
        let profileState = try JSONDecoder().decode(VortxJSON.self, from: profilesFacade.stateData("native_state")!)
        let hostState = try JSONDecoder().decode(VortxJSON.self, from: profilesFacade.stateData("native_host_preferences")!)
        let projectedProfiles = try VortxNativeProfiles.project(state: profileState, host: hostState, baseline: [owner, child])
        check(projectedProfiles.first(where: { $0.id == child.id })?.name == "Updated Child")
        check(projectedProfiles.first(where: { $0.id == child.id })?.avatar == "moon")
        check(projectedProfiles.first(where: { $0.id == child.id })?.textScale == 1.25)
        check(try migrationStore.readHostPreferences(scope: legacyScope) != nil)
        let newProfile = UserProfile(id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!, name: "New viewer", avatar: "star")
        let create = try VortxNativeProfiles.mutation(newProfile, previous: nil, ownerID: owner.id.uuidString)
        try await profilesFacade.mutateProfiles(create.0, hostEdits: [create.1], expectedProfileID: child.id.uuidString)
        await profilesFacade.settled()
        let addedState = try JSONDecoder().decode(VortxJSON.self, from: profilesFacade.stateData("native_state")!)
        check(addedState["roster"]?["profiles"]?[newProfile.id.uuidString]?["name"] == .string("New viewer"))
        try await profilesFacade.mutateProfiles([.object(["type": .string("delete_profile"), "id": .string(newProfile.id.uuidString)])], hostEdits: [], expectedProfileID: child.id.uuidString)
        await profilesFacade.settled()
        let deletedState = try JSONDecoder().decode(VortxJSON.self, from: profilesFacade.stateData("native_state")!)
        check(deletedState["roster"]?["profiles"]?[newProfile.id.uuidString]?["deleted"] == .bool(true))
        await profilesFacade.shutdown()
        print("Live native Swift C ABI: hydration/deltas; full resources; facade Board/Discover/Search/Meta/streams/subtitles/library; scoped FIFO profile/progress, registry rebind and encrypted nativeSync/watchContexts cold reopen passed")
        print("Live Apple authenticated importer: historical owner/PIN, fractional watch material, saved-vs-played separation, idempotent receipt and encrypted cold episode resume passed")
    }
}
