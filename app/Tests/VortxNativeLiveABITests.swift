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
        _ = try await session.dispatch([#"{"type":"bind_sync_scope","scope":"fixture-account"}"#], now: 1000)
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: [addon], changed: { _ in })
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
        }
        try dispatch(["action": "Load", "args": ["model": "CatalogWithFilters", "args": NSNull()]], field: "discover")
        await facade.settled(); check(try field("discover")["catalog"]?.array?.count == 1)
        let metaPath = ["resource": "meta", "type": "series", "id": "tt-fixture", "extra": []] as [String: Any]
        let streamPath = ["resource": "stream", "type": "series", "id": "tt-fixture:1:2", "extra": []] as [String: Any]
        try dispatch(["action": "Load", "args": ["model": "MetaDetails", "args": ["metaPath": metaPath, "streamPath": streamPath]]], field: "meta_details")
        await facade.settled(); check(try field("meta_details")["streams"]?.array?.count == 1)
        try dispatch(["action": "Load", "args": ["model": "Subtitles", "args": ["resource": "subtitles", "type": "series", "id": "tt-fixture", "extra": []]]], field: "subtitles")
        await facade.settled(); check(try field("subtitles").array?.first?["content"]?["content"]?.array?.count == 2)
        try dispatch(["action": "Load", "args": ["model": "LibraryWithFilters", "args": ["request": ["sort": "lastwatched", "page": 1]]]], field: "library")
        await facade.settled(); check(try field("library")["catalog"] == .array([]))
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
        check(!facade.dispatch(data: Data(#"{"action":"Load","args":{"model":"CatalogWithFilters","args":null}}"#.utf8), field: "discover"))
        check(facade.lastFailure == "registry_rebind_required")
        do { try await facade.rebindRegistry([addon], expected: oldBinding); fatalError("stale profile rebound registry") }
        catch VortxNativeError.superseded {}
        try await facade.rebindRegistry([addon], expected: facade.registryBinding!)
        try dispatch(["action": "Load", "args": ["model": "CatalogWithFilters", "args": NSNull()]], field: "discover")
        await facade.settled(); check(try field("discover")["catalog"]?.array?.count == 1)
        let lastState = try await session.stateJSON()
        await facade.shutdown()
        let reopened = try VortxNativeSession(scope: scope, ownerName: "Fixture", abi: VortxCABI(), store: checkpoint, transport: VortxCResourceTransport())
        check(try await reopened.stateJSON() == lastState)
        await reopened.close()
        print("Live native Swift C ABI: hydration/deltas; full resources; facade Board/Discover/Search/Meta/streams/subtitles/library; scoped FIFO profile/progress, registry rebind and encrypted nativeSync/watchContexts cold reopen passed")
    }
}
