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
        check(!facade.setWatchedVideos(metaID: "tt-fixture", videoIDs: ["fabricated-episode"], name: "Fixture", type: "series", poster: nil,
                                       watched: true, profileID: scope.ownerProfileID))
        check(facade.lastFailure == "stale_or_empty_watched_inventory")
        check(facade.setWatchedVideos(metaID: "tt-fixture", videoIDs: ["tt-fixture:1:2"], name: "Fixture", type: "series", poster: nil,
                                      watched: true, profileID: scope.ownerProfileID))
        await facade.settled()
        check(try field("native_playback")["watchedVideoIdsByTitle"]?["tt-fixture"]?.array?.contains(.string("tt-fixture:1:2")) == true)
        // A catalog/library card has no resident detail inventory. Its isolated lookup must still
        // issue the complete opaque-id batch, while leaving the visible detail slot unloaded.
        try dispatch(["action": "Unload"], field: "meta_details")
        let unloadedDetail = try field("meta_details")
        check(unloadedDetail["metaItems"] == .array([]))
        check(await facade.resolveAndSetWatchedVideos(metaID: "tt-fixture", type: "series", name: "Fixture", poster: nil,
                                                       watched: false, profileID: scope.ownerProfileID))
        await facade.settled()
        check(try field("meta_details") == unloadedDetail)
        check(try field("native_playback")["watchedVideoIdsByTitle"]?["tt-fixture"]?.array?.contains(.string("tt-fixture:1:2")) != true)
        // An authoritative lookup failure must not submit even a partial watch transaction.
        let playbackBeforeFailedResolution = try field("native_playback")
        check(await !facade.resolveAndSetWatchedVideos(metaID: "tt-fixture", type: "movie", name: "Fixture", poster: nil,
                                                        watched: true, profileID: scope.ownerProfileID))
        await facade.settled()
        check(try field("native_playback") == playbackBeforeFailedResolution)
        // Start normal detail navigation, then resolve a card action. libraryMetadata owns a
        // separate slot, so it cannot cancel or replace the in-flight meta_details request.
        try dispatch(["action": "Load", "args": ["model": "MetaDetails", "args": ["metaPath": metaPath, "streamPath": streamPath]]], field: "meta_details")
        let navigatingSelection = try field("meta_details")["selected"]
        check(await facade.resolveAndSetWatchedVideos(metaID: "tt-fixture", type: "series", name: "Fixture", poster: nil,
                                                       watched: true, profileID: scope.ownerProfileID))
        await facade.settled()
        check(try field("meta_details")["selected"] == navigatingSelection)
        check(try field("meta_details")["streams"]?.array?.count == 1)
        // Once the isolated lookup has captured its resource request, an add-on mutation can
        // replace that registry before the watch batch is admitted. The stale resolver must
        // reject and leave the pre-existing watched set exact.
        let delayPath = CommandLine.arguments[4]
        let temporaryURL = "http://127.0.0.1:\(port)/temporary/manifest.json"
        let manifestObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture["manifest"]!))
        let temporaryDescriptor: [String: Any] = ["transportUrl": temporaryURL, "manifest": manifestObject]
        check(FileManager.default.createFile(atPath: delayPath, contents: Data()))
        let staleCardResolution = Task { await facade.resolveAndSetWatchedVideos(metaID: "tt-fixture", type: "series", name: "Fixture", poster: nil,
                                                                                   watched: false, profileID: scope.ownerProfileID) }
        let enteredPath = delayPath + ".entered"
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: enteredPath) {
            try await Task.sleep(for: .milliseconds(10))
        }
        check(FileManager.default.fileExists(atPath: enteredPath))
        try dispatch(["action": "Ctx", "args": ["action": "InstallAddonLocal", "args": temporaryDescriptor]], field: "ctx")
        await facade.settled()
        try FileManager.default.removeItem(atPath: delayPath)
        check(await !staleCardResolution.value)
        await facade.settled()
        check(try field("native_playback")["watchedVideoIdsByTitle"]?["tt-fixture"]?.array?.contains(.string("tt-fixture:1:2")) == true)
        // Remove the temporary source before the next mutation. Its retained CRDT identity must
        // not poison subsequent owner-bucket order reconstruction.
        try dispatch(["action": "Ctx", "args": ["action": "UninstallAddonLocal", "args": temporaryDescriptor]], field: "ctx")
        await facade.settled()
        // A native mutation republishes library, but must retain the selected type/sort even when
        // the matching type later has no rows.
        check(try field("library")["selectable"]?["sorts"]?.array?.contains { $0["sort"] == .string("name") && $0["selected"] == .bool(true) } == true)
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
        let watchedMovie: VortxJSON = .object(["type": .string("mark_watched"), "metaId": .string("unsaved-movie"), "name": .string("Watched without saving"),
                                              "metadata": .object(["type": .string("movie")])])
        check(facade.dispatchForProfile(watchedMovie, profileID: "kid")); await facade.settled()
        check(try field("native_history")["items"]?.array?.contains { $0["_id"] == .string("unsaved-movie") && $0["state"]?["timesWatched"] == .integer(1) } == true)
        check(try field("library")["catalog"] == .array([]))
        // Ctx add-on mutations use the exact kernel actions. Invalid new descriptors are rejected before
        // old membership is considered; replacement, order and removal are committed through one FIFO.
        let replacementURL = "http://127.0.0.1:\(port)/replacement/manifest.json"
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
        // Removed identities remain in CRDT order. A fresh install and replacement must use the
        // kernel's filtered-live ordering rather than reject that ordinary tombstone history.
        let laterURL = "http://127.0.0.1:\(port)/later/manifest.json"
        let laterDescriptor: [String: Any] = ["transportUrl": laterURL, "manifest": manifestObject]
        try dispatch(["action": "Ctx", "args": ["action": "InstallAddonLocal", "args": laterDescriptor]], field: "ctx")
        await facade.settled()
        try dispatch(["action": "Ctx", "args": ["action": "ReplaceAddonLocal", "args": ["old": laterDescriptor, "new": originalDescriptor]]], field: "ctx")
        await facade.settled()
        check(try field("ctx")["profile"]?["addons"]?.array?.map { $0["transportUrl"] } == [.string(addon.transportUrl)])
        // Kernel keys scheme/host case-insensitively but preserves descriptor spelling. A disabled
        // uppercase-host source is hidden from resourceRegistry yet still must participate in the
        // unfiltered owner-bucket replacement order.
        let uppercaseURL = "http://LOCALHOST:\(port)/uppercase/manifest.json"
        let uppercaseDescriptor: [String: Any] = ["transportUrl": uppercaseURL, "manifest": manifestObject]
        try dispatch(["action": "Ctx", "args": ["action": "InstallAddonLocal", "args": uppercaseDescriptor]], field: "ctx")
        await facade.settled()
        let caseOnlyURL = "http://localhost:\(port)/uppercase/manifest.json"
        let caseOnlyDescriptor: [String: Any] = ["transportUrl": caseOnlyURL, "manifest": manifestObject]
        try dispatch(["action": "Ctx", "args": ["action": "ReplaceAddonLocal", "args": ["old": uppercaseDescriptor, "new": caseOnlyDescriptor]]], field: "ctx")
        await facade.settled()
        check(try field("ctx")["profile"]?["addons"]?.array?.map { $0["transportUrl"] } == [.string(addon.transportUrl), .string(caseOnlyURL)])
        try dispatch(["action": "Vortx", "args": ["type": "patch_profile", "id": "kid",
                                                        "edits": [["field": "disabledAddons", "value": [caseOnlyURL]]]]], field: "native_state")
        await facade.settled()
        check(try field("ctx")["profile"]?["addons"]?.array?.map { $0["transportUrl"] } == [.string(addon.transportUrl)])
        try dispatch(["action": "Ctx", "args": ["action": "ReplaceAddonLocal", "args": ["old": caseOnlyDescriptor, "new": laterDescriptor]]], field: "ctx")
        await facade.settled()
        check(try field("ctx")["profile"]?["addons"]?.array?.map { $0["transportUrl"] } == [.string(addon.transportUrl), .string(laterURL)])
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
        var ownAccount = child; ownAccount.usesOwnAccount = true
        let pendingRecord: VortxJSON = .object([
            "name": .string(child.name), "owner": .bool(false),
            "account": .object(["kind": .string("pending_own")]), "addons": .string("own"),
            "parental": .object(["kids": .bool(false), "familyEdit": .bool(false)]),
            "settings": .object(["accent": .string("ember"), "oled": .bool(false), "textScale": .integer(1000), "disabledAddons": .array([])])
        ])
        let pendingState: VortxJSON = .object(["roster": .object(["profiles": .object([child.id.uuidString: pendingRecord])])])
        check(try VortxNativeProfiles.project(state: pendingState, host: .object([:]), baseline: [child]).first?.usesOwnAccount == true)

        let localBinding: VortxJSON = .object(["account": .object(["kind": .string("local_only")]),
                                                "revision": .integer(0), "transactionId": .null])
        let bindingState: VortxJSON = .object([
            "roster": .object(["profiles": .object([child.id.uuidString: .object(["account": .object(["kind": .string("local_only")])])])]),
            "nativeSync": .object(["accountSlots": .object([child.id.uuidString: .object(["activeBinding": localBinding])])])
        ])
        let expectedBinding = try VortxNativeProfiles.expectedBinding(state: bindingState, profileID: child.id)
        check(expectedBinding.account == .object(["kind": .string("local_only")]) && expectedBinding.revision == .integer(0) && expectedBinding.transactionID == nil)
        for invalidBinding in [
            VortxJSON.object(["account": .object(["kind": .string("local_only")]), "revision": .unsigned(9_007_199_254_740_992), "transactionId": .string("too-large")]),
            VortxJSON.object(["account": .object(["kind": .string("local_only")]), "revision": .integer(0), "transactionId": .string("zero-must-not-name-a-transaction")]),
            VortxJSON.object(["account": .object(["kind": .string("local_only")]), "revision": .integer(1), "transactionId": .null])
        ] {
            let invalidState: VortxJSON = .object(["roster": .object(["profiles": .object([child.id.uuidString: .object(["account": .object(["kind": .string("local_only")])])])]),
                                                     "nativeSync": .object(["accountSlots": .object([child.id.uuidString: .object(["activeBinding": invalidBinding])])])])
            do { _ = try VortxNativeProfiles.expectedBinding(state: invalidState, profileID: child.id); fatalError("Invalid account binding receipt accepted") }
            catch VortxNativeError.invalidSnapshot {}
        }
        let rebindMaterial: VortxJSON = .object([
            "schemaVersion": .integer(2),
            "ownAccountSources": .object([child.id.uuidString: .object(["verifiedStreamingUid": .string("verified-own-uid"),
                                                                          "sourceDocumentSha256": .string(String(repeating: "a", count: 64))])]),
            "addons": .object([child.id.uuidString: .object(["items": .array([]), "order": .array([]), "intents": .array([])])]),
            "libraries": .object([child.id.uuidString: .object(["items": .array([]), "intents": .array([])])]),
            "watches": .object([child.id.uuidString: .array([])]), "identityLinks": .object([child.id.uuidString: .array([])])
        ])
        let ownTarget = try VortxNativeProfiles.ownTarget(material: rebindMaterial, profileID: child.id)
        // A fresh authenticated v2 source has the mandatory overlay witness. It must survive the
        // public material encoder, target extraction and rebind action unchanged.
        let emptyLibraryResponse = try JSONSerialization.data(withJSONObject: ["result": []])
        let emptyAddonsResponse = try JSONSerialization.data(withJSONObject: ["result": ["addons": []]])
        let emptyOverlayResponse = Data("{}".utf8)
        let freshSourceEnvelope = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "libraryResponseBase64": emptyLibraryResponse.base64EncodedString(),
            "addonsResponseBase64": emptyAddonsResponse.base64EncodedString(),
            "profileOverlayBase64": emptyOverlayResponse.base64EncodedString()
        ], options: [.sortedKeys])
        let freshWitness = try VortxProfileOverlayWitness.digest(json: emptyOverlayResponse)
        let freshMaterialData = try VortxLegacyBootstrapMaterial.encode(
            document: try JSONSerialization.data(withJSONObject: ["vortx": [:]]), roster: [owner, ownAccount], ownerProfileID: owner.id,
            rosterModifiedSeconds: nil,
            ownAccountSources: [.init(profileID: child.id, verifiedStreamingUID: "verified-own-uid",
                                      sourceDocument: freshSourceEnvelope, profileOverlaySHA256: freshWitness)])
        let freshMaterial = try JSONDecoder().decode(VortxJSON.self, from: freshMaterialData)
        let freshOwnTarget = try VortxNativeProfiles.ownTarget(material: freshMaterial, profileID: child.id)
        // Exercise the reviewed schema-4 transaction against the actual C artifact: material-2
        // establishes the proven own account, a CAS visits shared, then the exact witnessed
        // carrier restores own. The exported cold state and cold nativeSync import must retain the
        // source proof verbatim.
        let rebindScope = VortxAccountScope(account: "fixture-rebind-witness", ownerProfileID: owner.id.uuidString)
        let rebindRuntime = try VortxNativeRuntime(abi: VortxCABI(), ownerID: owner.id.uuidString, ownerName: owner.name)
        defer { rebindRuntime.close() }
        func applyRebind(_ action: VortxJSON, now: UInt64) throws -> VortxJSON {
            let result = try rebindRuntime.dispatch(String(decoding: JSONEncoder().encode(action), as: UTF8.self), now: now)
            let response = try JSONDecoder().decode(VortxJSON.self, from: Data(result.utf8))
            check(response["ok"] == .bool(true))
            return response
        }
        _ = try applyRebind(.object(["type": .string("bind_sync_scope"), "scope": .string(rebindScope.account)]), now: 1)
        _ = try applyRebind(.object(["type": .string("import_legacy_sync"), "scope": .string(rebindScope.account),
                                     "ownerProfileId": .string(owner.id.uuidString), "material": freshMaterial]), now: 2)
        let importedRebindState = try JSONDecoder().decode(VortxJSON.self, from: Data(rebindRuntime.stateJSON().utf8))
        let importedBinding = try VortxNativeProfiles.expectedBinding(state: importedRebindState, profileID: child.id)
        let sharedRebind = try VortxNativeProfiles.rebindAction(profileID: child.id,
            request: .init(scope: rebindScope.account, ownerProfileID: owner.id.uuidString,
                           transactionID: "schema4-shared", expected: importedBinding, target: .shared))
        _ = try applyRebind(sharedRebind, now: 3)
        let sharedRebindState = try JSONDecoder().decode(VortxJSON.self, from: Data(rebindRuntime.stateJSON().utf8))
        let restoredOwn = try VortxNativeProfiles.rebindAction(profileID: child.id,
            request: .init(scope: rebindScope.account, ownerProfileID: owner.id.uuidString,
                           transactionID: "schema4-own", expected: try VortxNativeProfiles.expectedBinding(state: sharedRebindState, profileID: child.id),
                           target: .own(freshOwnTarget)))
        _ = try applyRebind(restoredOwn, now: 4)
        let rebindExport = try rebindRuntime.stateJSON()
        let rebindState = try JSONDecoder().decode(VortxJSON.self, from: Data(rebindExport.utf8))
        func activeOwnSource(_ state: VortxJSON) -> VortxJSON? {
            guard let binding = state["nativeSync"]?["accountSlots"]?[child.id.uuidString]?["activeBinding"]?["account"],
                  case .object(let slots)? = state["nativeSync"]?["accountSlots"]?[child.id.uuidString]?["slots"] else { return nil }
            return slots.values.first { $0["account"] == binding }?["sourceBaseline"]?["source"]
        }
        check(rebindState["nativeSync"]?["schemaVersion"] == .integer(4)
              && rebindState["roster"]?["profiles"]?[child.id.uuidString]?["account"]?["kind"] == .string("own")
              && activeOwnSource(rebindState)?["profileOverlaySha256"] == .string(freshWitness))
        let coldRebindRuntime = try VortxNativeRuntime(abi: VortxCABI(), snapshot: rebindExport)
        defer { coldRebindRuntime.close() }
        let coldRebindExport = try coldRebindRuntime.stateJSON()
        let coldRebindState = try JSONDecoder().decode(VortxJSON.self, from: Data(coldRebindExport.utf8))
        check(coldRebindExport == rebindExport
              && activeOwnSource(coldRebindState)?["profileOverlaySha256"] == .string(freshWitness))
        try VortxNativeSession.validateLegacyCompatibility(scope: rebindScope, ownerName: owner.name, snapshot: nil,
                                                           nativeSync: rebindState["nativeSync"], material: freshMaterialData, abi: VortxCABI())
        let pendingRequest = try VortxNativeProfiles.AccountRebindRequest(scope: "fixture-account", ownerProfileID: owner.id.uuidString,
                                                                            transactionID: "pending-own-transaction", expected: expectedBinding,
                                                                            target: .pendingOwn)
        let pendingAction = try VortxNativeProfiles.rebindAction(profileID: child.id, request: pendingRequest)
        check(pendingAction == .object(["type": .string("rebind_profile_account"), "scope": .string("fixture-account"),
                                        "ownerProfileId": .string(owner.id.uuidString), "profileId": .string(child.id.uuidString),
                                        "transactionId": .string("pending-own-transaction"), "expectedBinding": localBinding,
                                        "target": .object(["kind": .string("pending_own")])]))
        let provenRequest = try VortxNativeProfiles.AccountRebindRequest(scope: "fixture-account", ownerProfileID: owner.id.uuidString,
                                                                           transactionID: "proven-own-transaction", expected: expectedBinding,
                                                                           target: .own(ownTarget))
        let createOwn = try VortxNativeProfiles.mutation(ownAccount, previous: nil, ownerID: owner.id.uuidString,
                                                          rebind: try .initial(scope: "fixture-account", ownerProfileID: owner.id.uuidString,
                                                                               transactionID: "new-own-transaction", target: .pendingOwn))
        check(createOwn.0.compactMap { $0["type"] } == [.string("add_profile"), .string("patch_profile"), .string("rebind_profile_account")])
        let rebindExisting = try VortxNativeProfiles.mutation(ownAccount, previous: child, ownerID: owner.id.uuidString, rebind: provenRequest)
        let provenAction = try VortxNativeProfiles.rebindAction(profileID: child.id, request: provenRequest)
        check(rebindExisting.0.last == provenAction)
        let freshAction = try VortxNativeProfiles.rebindAction(profileID: child.id,
            request: try .init(scope: "fixture-account", ownerProfileID: owner.id.uuidString,
                               transactionID: "fresh-v2-own-transaction", expected: expectedBinding, target: .own(freshOwnTarget)))
        check(freshAction["target"]?["carrier"]?["source"]?["profileOverlaySha256"] == .string(freshWitness))
        do { _ = try VortxNativeProfiles.mutation(ownAccount, previous: child, ownerID: owner.id.uuidString); fatalError("generic own selection accepted") }
        catch VortxNativeError.invalidSnapshot {}
        let ownRecord: VortxJSON = .object([
            "name": .string(ownAccount.name), "owner": .bool(false),
            "account": .object(["kind": .string("own"), "value": .string("verified-own-uid")]),
            "addons": .string("own"), "parental": .object(["kids": .bool(false), "familyEdit": .bool(false)]),
            "settings": .object(["accent": .string("ember"), "oled": .bool(false), "textScale": .integer(1000), "disabledAddons": .array([])])
        ])
        let ownState: VortxJSON = .object(["roster": .object(["profiles": .object([ownAccount.id.uuidString: ownRecord])])])
        check(try VortxNativeProfiles.project(state: ownState, host: .object([:]), baseline: [ownAccount]).first?.usesOwnAccount == true)
        let sharedViewer = UserProfile(id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!, name: "Shared", avatar: "S")
        var pendingViewer = UserProfile(id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!, name: "Pending", avatar: "P")
        pendingViewer.usesOwnAccount = true
        func profileRecord(_ profile: UserProfile, account: VortxJSON, addons: VortxJSON) -> VortxJSON {
            .object(["name": .string(profile.name), "owner": .bool(profile.isOwner), "account": account, "addons": addons,
                     "parental": .object(["kids": .bool(false), "familyEdit": .bool(false)]),
                     "settings": .object(["accent": .string("ember"), "oled": .bool(false), "textScale": .integer(1000), "disabledAddons": .array([])])])
        }
        let mixedRecords: VortxJSON = .object([
            owner.id.uuidString: profileRecord(owner, account: .object(["kind": .string("local_only")]), addons: .string("own")),
            sharedViewer.id.uuidString: profileRecord(sharedViewer, account: .object(["kind": .string("shared"), "value": .string(owner.id.uuidString)]), addons: .string("share_primary")),
            pendingViewer.id.uuidString: profileRecord(pendingViewer, account: .object(["kind": .string("pending_own")]), addons: .string("own")),
            ownAccount.id.uuidString: profileRecord(ownAccount, account: .object(["kind": .string("own"), "value": .string("verified-own-uid")]), addons: .string("share_primary"))
        ])
        let mixedState: VortxJSON = .object(["roster": .object(["profiles": mixedRecords])])
        let mixedProjection = try VortxNativeProfiles.project(state: mixedState, host: .object([:]), baseline: [owner, sharedViewer, pendingViewer, ownAccount])
        check(mixedProjection.first(where: { $0.id == owner.id })?.usesOwnAccount == false
              && mixedProjection.first(where: { $0.id == sharedViewer.id })?.usesOwnAccount == false
              && mixedProjection.first(where: { $0.id == pendingViewer.id })?.usesOwnAccount == true
              && mixedProjection.first(where: { $0.id == ownAccount.id })?.usesOwnAccount == true)
        var renamedOwn = ownAccount; renamedOwn.name = "Renamed own account"
        let retainedOwnBinding = try VortxNativeProfiles.mutation(renamedOwn, previous: ownAccount, ownerID: owner.id.uuidString)
        check(retainedOwnBinding.0.count == 1 && retainedOwnBinding.0[0]["type"] == .string("patch_profile"))
        do { _ = try VortxNativeProfiles.mutation(ownAccount, previous: nil, ownerID: owner.id.uuidString); fatalError("unproven own binding created") }
        catch VortxNativeError.invalidSnapshot {}
        var shared = ownAccount; shared.usesOwnAccount = false
        do { _ = try VortxNativeProfiles.mutation(shared, previous: ownAccount, ownerID: owner.id.uuidString); fatalError("own binding cleared by generic patch") }
        catch VortxNativeError.invalidSnapshot {}
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
        print("Live Apple authenticated importer: historical owner/PIN, fractional watch material, saved-vs-played separation, material-2 witnessed own CAS/shared-return, nativeSync-4 cold export/import and encrypted cold episode resume passed")
    }
}
