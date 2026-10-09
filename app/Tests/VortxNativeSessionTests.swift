import Foundation
import CryptoKit

private final class SessionABI: VortxRuntimeABI, @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt = 0
    private var states: [UInt: String] = [:]
    private var playbackUnavailable = false
    func failPlaybackQueries() { lock.withLock { playbackUnavailable = true } }
    func create(ownerID: String, ownerName: String) -> UInt {
        hydrate("{\"roster\":{\"profiles\":{\"\(ownerID)\":{\"id\":\"\(ownerID)\",\"owner\":true,\"deleted\":false,\"addons\":\"own\"},\"kid\":{\"id\":\"kid\",\"owner\":false,\"addons\":\"share_primary\"}}},\"activeProfileId\":\"\(ownerID)\",\"libraries\":{\"kid\":{},\"\(ownerID)\":{\"watchContexts\":{\"episode\":{\"name\":\"Retain context\",\"durationMs\":1200001}}}}}")
    }
    func hydrate(_ snapshot: String) -> UInt {
        lock.lock(); defer { lock.unlock() }; next += 1; states[next] = snapshot; return next
    }
    func dispatch(_ handle: UInt, action: String, now: UInt64) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var state = try? JSONSerialization.jsonObject(with: Data(states[handle]!.utf8)) as? [String: Any],
              let action = try? JSONSerialization.jsonObject(with: Data(action.utf8)) as? [String: Any] else { return nil }
        if action["type"] as? String == "fail" { return "{\"ok\":false}" }
        if action["type"] as? String == "bind_sync_scope" {
            let roster = state["roster"] as! [String: Any]
            let profiles = roster["profiles"] as! [String: [String: Any]]
            let owner = profiles.first { $0.value["owner"] as? Bool == true }!.key
            state["nativeSync"] = ["schemaVersion": 1, "scope": action["scope"]!, "ownerProfileId": owner]
            states[handle] = String(decoding: try! JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self)
            return "{\"ok\":true}"
        }
        if action["type"] as? String == "switch_profile" { state["activeProfileId"] = action["id"] }
        if action["type"] as? String == "merge_native_sync" {
            guard let incoming = action["document"] as? [String: Any],
                  incoming["scope"] as? String == (state["nativeSync"] as? [String: Any])?["scope"] as? String else { return "{\"ok\":false}" }
            state["nativeSync"] = incoming
        }
        state["fixtureMutation"] = action["value"] ?? now
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) { states[handle] = String(decoding: data, as: UTF8.self) }
        return "{\"ok\":true}"
    }
    func resolve(_ handle: UInt, request: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var query = try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any] else { return nil }
        if query["kind"] as? String == "installed_addons" { query["addons"] = [] }
        if query["kind"] as? String == "profile_playback" {
            if playbackUnavailable { return "{\"kind\":\"error\"}" }
            query["continueWatching"] = [["metaId": "unsaved-series", "videoId": "opaque-video", "name": "In progress", "type": "series", "offsetMs": 120001, "durationMs": 1200001, "updatedAt": 1700000000, "watched": false, "timesWatched": 0]]
            query["history"] = [["metaId": "watched-movie", "name": "Watched movie", "type": "movie", "offsetMs": 0, "durationMs": 1000000, "updatedAt": 1700000001, "watched": true, "timesWatched": 2]]
            query["watchedVideoIdsByTitle"] = ["unsaved-series": ["other-video"]]
            query["watchedTitles"] = ["watched-movie": 2]
            query["resumeById"] = ["opaque-video": ["offsetMs": 120001, "durationMs": 1200001, "updatedAt": 1700000000], "finished": NSNull()]
        }
        if query["kind"] as? String == "resume_point" { query["resume"] = ["offsetMs": 3001, "durationMs": 100000, "updatedAt": 1700000000] }
        return String(decoding: try! JSONSerialization.data(withJSONObject: query), as: UTF8.self)
    }
    func state(_ handle: UInt) -> String? { lock.lock(); defer { lock.unlock() }; return states[handle] }
    func delta(_ handle: UInt) -> String? { "{}" }
    func free(_ handle: UInt) { lock.lock(); defer { lock.unlock() }; precondition(states.removeValue(forKey: handle) != nil) }
}

private final class MutationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class SessionStore: VortxCheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var host: Data?
    private var failure = false
    private var installBeforeFailure = false
    private var block = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func blockNextWrite() { lock.lock(); block = true; lock.unlock() }
    func failWrites(afterInstall: Bool = false) { lock.lock(); failure = true; installBeforeFailure = afterInstall; lock.unlock() }
    func recover() { lock.lock(); failure = false; lock.unlock() }
    func read(scope: VortxAccountScope) throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func readHostPreferences(scope: VortxAccountScope) throws -> Data? { lock.withLock { host } }
    func commit(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data) throws {
        try commit(snapshot, scope: scope); lock.withLock { host = hostPreferences }
    }
    func commit(_ snapshot: String, scope: VortxAccountScope) throws {
        lock.lock(); defer { lock.unlock() }
        if block { block = false; entered.signal(); precondition(release.wait(timeout: .now() + 5) == .success) }
        if !failure || installBeforeFailure { value = snapshot }
        if failure { throw VortxNativeError.unavailable }
    }
}

private final class SessionTransport: VortxResourceTransport, @unchecked Sendable {
    final class Token: VortxResourceCancellation, @unchecked Sendable { func cancel() {} }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func makeCancellation() throws -> any VortxResourceCancellation { Token() }
    func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String {
        var input = try JSONDecoder().decode(VortxJSON.self, from: Data(requestJSON.utf8))
        if input["request"]?["id"] == .string("slow") { entered.signal(); precondition(release.wait(timeout: .now() + 5) == .success) }
        var groups: [VortxJSON] = []
        if input["request"]?["resource"] == .string("catalog"), let addon = input["addons"]?.array?.first?["id"] {
            let extra = try input["request"]?["extra"]?.decode([[String]].self) ?? []
            let skip = extra.first { $0.first == "skip" }.flatMap { Int($0[1]) } ?? 0
            let items: [VortxJSON] = skip >= 2 ? [] : [.object(["id": .string("page-\(skip)"), "type": .string("movie"), "name": .string("Page \(skip)")])]
            groups = [.object(["addonId": addon, "status": .string("ready"), "content": .object(["metas": .array(items)])])]
        }
        input = .object(["kind": .string("resource_result"), "requestId": input["requestId"]!, "generation": input["generation"]!,
                         "request": input["request"]!, "groups": .array(groups), "cancelled": .bool(false)])
        return String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
    }
}

/// Gates individual requests without honoring cancellation, so stale-output tests exercise the
/// production fences rather than depending on a cooperative provider returning early.
private final class CatalogFanoutTransport: VortxResourceTransport, @unchecked Sendable {
    final class Token: VortxResourceCancellation, @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.withLock { value = true } }
        var cancelled: Bool { lock.withLock { value } }
    }
    private let lock = NSLock()
    private let gates: [String: DispatchSemaphore]
    private var requests: [String] = []
    private var tokens: [String: Token] = [:]
    private var active = 0
    private var peak = 0
    init(held: [String]) { gates = Dictionary(uniqueKeysWithValues: held.map { ($0, DispatchSemaphore(value: 0)) }) }
    var started: [String] { lock.withLock { requests } }
    var maximumActive: Int { lock.withLock { peak } }
    func wasCancelled(_ key: String) -> Bool { lock.withLock { tokens[key]?.cancelled == true } }
    func release(_ key: String) { gates[key]?.signal() }
    func makeCancellation() throws -> any VortxResourceCancellation { Token() }
    func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String {
        let input = try JSONDecoder().decode(VortxJSON.self, from: Data(requestJSON.utf8))
        let request = try input["request"]!.decode(VortxResourceRequest.self)
        let query = request.extra.first { $0.first == "search" }?.last ?? ""
        let skip = request.extra.first { $0.first == "skip" }?.last
        let key = query + "/" + request.id + (skip.map { "/skip" + $0 } ?? "")
        lock.withLock { requests.append(key); tokens[key] = cancellation as? Token; active += 1; peak = max(peak, active) }
        defer { lock.withLock { active -= 1 } }
        if let gate = gates[key] { precondition(gate.wait(timeout: .now() + 10) == .success, "unreleased catalog \(key)") }
        if request.id == "failure" || (request.id == "fifth" && skip != nil) { throw VortxNativeError.unavailable }
        let meta: VortxJSON = .object(["id": .string(key), "name": .string(key), "type": .string(request.type)])
        let groups: [VortxJSON] = [.object(["addonId": input["addons"]!.array!.first!["id"]!, "status": .string("ready"),
            "content": .object(["metas": .array([meta])])])]
        return String(decoding: try JSONEncoder().encode(VortxJSON.object(["kind": .string("resource_result"),
            "requestId": input["requestId"]!, "generation": input["generation"]!, "request": input["request"]!,
            "groups": .array(groups), "cancelled": .bool(false)])), as: UTF8.self)
    }
}

private final class CatalogPublications: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [VortxJSON] = []
    func append(_ value: VortxJSON) { lock.withLock { values.append(value) } }
    var count: Int { lock.withLock { values.count } }
}

private final class DetailFanoutTransport: VortxResourceTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let gates: [String: DispatchSemaphore]
    private var requests: [String] = []
    private var budgets: [UInt64] = []
    private var bodyLimits: [UInt64] = []
    private var totalLimits: [UInt64] = []
    private var active = 0
    private var peak = 0
    private var metaActive = 0, metaPeak = 0, streamActive = 0, streamPeak = 0
    init(held: [String]) { gates = Dictionary(uniqueKeysWithValues: held.map { ($0, DispatchSemaphore(value: 0)) }) }
    var started: [String] { lock.withLock { requests } }
    var requestBudgets: [UInt64] { lock.withLock { budgets } }
    var requestBodyLimits: [UInt64] { lock.withLock { bodyLimits } }
    var requestTotalLimits: [UInt64] { lock.withLock { totalLimits } }
    var maximumActive: Int { lock.withLock { peak } }
    var maximumMetaActive: Int { lock.withLock { metaPeak } }
    var maximumStreamActive: Int { lock.withLock { streamPeak } }
    func release(_ key: String) { gates[key]?.signal() }
    func makeCancellation() throws -> any VortxResourceCancellation { CatalogFanoutTransport.Token() }
    func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String {
        let input = try JSONDecoder().decode(VortxJSON.self, from: Data(requestJSON.utf8))
        let request = try input["request"]!.decode(VortxResourceRequest.self)
        let addons = input["addons"]!.array!
        precondition(addons.count == 1) // no native multi-addon queue can consume a leg's budget
        let addonID = try addons[0]["id"]!.decode(String.self)
        let key = request.id + "/" + request.resource.rawValue + "/" + addonID
        let budget = try input["budgetMs"]!.decode(UInt64.self)
        let bodyLimit = try input["maxResponseBytes"]!.decode(UInt64.self)
        let totalLimit = try input["maxTotalResponseBytes"]!.decode(UInt64.self)
        lock.withLock {
            requests.append(key); budgets.append(budget); bodyLimits.append(bodyLimit); totalLimits.append(totalLimit)
            active += 1; peak = max(peak, active)
            if request.resource == .meta { metaActive += 1; metaPeak = max(metaPeak, metaActive) }
            else { streamActive += 1; streamPeak = max(streamPeak, streamActive) }
        }
        defer { lock.withLock {
            active -= 1
            if request.resource == .meta { metaActive -= 1 } else { streamActive -= 1 }
        } }
        if let gate = gates[key] { precondition(gate.wait(timeout: .now() + 10) == .success, "unreleased detail leg") }
        // Cancellation deliberately ignored: session/publication fences must reject late output.
        if request.resource == .stream && addonID == "source6" { throw VortxNativeError.unavailable }
        let content: VortxJSON
        if request.resource == .meta {
            content = .object(["meta": .object(["id": .string(request.id), "type": .string(request.type), "name": .string("Fixture")])])
        } else if addonID == "source7" {
            content = .object(["streams": .array([.string("malformed")])])
        } else { content = .object(["streams": .array([.object(["url": .string("https://fixture.invalid/video.mp4")])])]) }
        let groups: [VortxJSON] = request.resource == .stream && addonID == "source8" ? [] : [
            .object(["addonId": .string(addonID), "status": .string("ready"), "content": content])]
        return String(decoding: try JSONEncoder().encode(VortxJSON.object(["kind": .string("resource_result"),
            "requestId": input["requestId"]!, "generation": input["generation"]!, "request": input["request"]!,
            "groups": .array(groups), "cancelled": .bool(false)])), as: UTF8.self)
    }
}

@main enum VortxNativeSessionTests {
    static func check(_ value: Bool, line: Int = #line) { precondition(value, "session assertion at line \(line)") }
    static func eventually(_ predicate: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        check(false, line: line)
    }
    static func detailFanoutTests() async throws {
        let registry = (0..<22).map { VortxResourceAddon(id: "source\($0)", transportUrl: "https://source\($0).fixture/manifest.json",
            manifest: .object(["resources": .array([.string("meta"), .string("stream")])])) }
        let blocked = (0..<4).map { "title:1:1/stream/source\($0)" }
        let blockedMeta = (0..<4).map { "title/meta/source\($0)" }
        let transport = DetailFanoutTransport(held: blocked + blockedMeta)
        let session = try VortxNativeSession(scope: .init(account: "detail-fanout", ownerProfileID: "owner"), ownerName: "Owner",
            abi: SessionABI(), store: SessionStore(), transport: transport, allowNewAccount: true)
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: registry, changed: { _ in })
        func load(_ target: VortxNativeCoreFacade, _ id: String) throws {
            let meta = try VortxResourceProjection.path(.init(resource: .meta, type: "series", id: id))
            let stream = try VortxResourceProjection.path(.init(resource: .stream, type: "series", id: id + ":1:1"))
            let action: VortxJSON = .object(["action": .string("Load"), "args": .object(["model": .string("MetaDetails"),
                "args": .object(["metaPath": meta, "streamPath": stream])])])
            check(target.dispatch(data: try JSONEncoder().encode(action), field: "meta_details"))
        }
        func state(_ target: VortxNativeCoreFacade) -> VortxJSON? {
            target.stateData("meta_details").flatMap { try? JSONDecoder().decode(VortxJSON.self, from: $0) }
        }
        try load(facade, "title")
        try await eventually { transport.started.count == 6 && transport.started.filter { $0.contains("/stream/") }.count == 4 }
        check(transport.maximumActive == 6 && transport.started.count == 6)
        check(!transport.started.contains("title:1:1/stream/source4"))
        check(state(facade)?["streams"]?.array?.count == 22)
        transport.release(blocked[2])
        try await eventually { state(facade)?["streams"]?.array?[2]["content"]?["type"] == .string("Ready") }
        check(state(facade)?["streams"]?.array?[0]["content"]?["type"] == .string("Loading"))
        try await eventually { transport.started.contains("title:1:1/stream/source4") }
        check(!transport.started.contains("title/meta/source2")) // slow metadata cannot occupy stream slots
        check(transport.requestBudgets.allSatisfy { $0 == 20_000 }) // fifth starts with a fresh full budget
        for index in [0, 1, 3] { transport.release(blocked[index]) }
        try await eventually { transport.started.filter { $0.contains("/stream/") }.count == 22 }
        check(state(facade)?["metaItems"]?.array?[0]["content"]?["type"] == .string("Loading"))
        for key in blockedMeta { transport.release(key) }
        await facade.settled()
        let result = state(facade)!, rows = result["streams"]!.array!
        check(transport.started.count == 44 && transport.maximumActive == 6)
        check(transport.maximumMetaActive == 2 && transport.maximumStreamActive == 4)
        check(transport.requestBodyLimits.allSatisfy { $0 == 8_388_608 })
        check(transport.requestTotalLimits.allSatisfy { $0 == 33_554_432 })
        check(rows.count == 22 && result["metaItems"]?.array?.count == 22)
        check(rows.enumerated().allSatisfy { $0.element["request"]?["base"] == .string(registry[$0.offset].transportUrl) })
        check(rows[6]["content"]?["type"] == .string("Err") && rows[7]["content"]?["type"] == .string("Err"))
        check(rows[8]["content"]?["type"] == .string("Ready") && rows[8]["content"]?["content"] == .array([]))
        check(rows[21]["content"]?["type"] == .string("Ready")) // tail sources never silently cut off
        check(!rows.contains { $0["content"]?["type"] == .string("Loading") })
        await facade.shutdown()

        for unload in [false, true] {
            let held = DetailFanoutTransport(held: ["old/meta/source0", "old:1:1/stream/source0"])
            let scoped = try VortxNativeSession(scope: .init(account: "details-latest-\(unload)", ownerProfileID: "owner"),
                ownerName: "Owner", abi: SessionABI(), store: SessionStore(), transport: held, allowNewAccount: true)
            let target = try await VortxNativeCoreFacade.create(session: scoped, registry: [registry[0]], changed: { _ in })
            try load(target, "old"); try await eventually { held.started.count == 2 }
            let previous = Task { await target.settled() }; await Task.yield()
            if unload { check(target.dispatch(data: Data(#"{"action":"Unload"}"#.utf8), field: "meta_details")) }
            else { try load(target, "new"); try await eventually { state(target)?["streams"]?.array?.first?["content"]?["type"] == .string("Ready") } }
            held.release("old/meta/source0"); held.release("old:1:1/stream/source0")
            await previous.value; await target.settled()
            check(state(target)?["selected"] == (unload ? .null : .object([
                "metaPath": try VortxResourceProjection.path(.init(resource: .meta, type: "series", id: "new")),
                "streamPath": try VortxResourceProjection.path(.init(resource: .stream, type: "series", id: "new:1:1"))])))
            await target.shutdown()
        }
        for boundary in ["profile", "resources", "owner", "cancel"] {
            let held = DetailFanoutTransport(held: ["old/meta/source0", "old:1:1/stream/source0"])
            let scoped = try VortxNativeSession(scope: .init(account: "details-boundary-" + boundary, ownerProfileID: "owner"),
                ownerName: "Owner", abi: SessionABI(), store: SessionStore(), transport: held, allowNewAccount: true)
            let publications = CatalogPublications()
            let operation = Task { try await scoped.loadMeta(request: .init(resource: .meta, type: "series", id: "old"),
                stream: .init(resource: .stream, type: "series", id: "old:1:1"), addons: [registry[0]],
                expectedProfileID: "owner", onUpdate: { publications.append($0) }) }
            try await eventually { held.started.count == 2 }; check(publications.count == 1)
            switch boundary {
            case "profile": _ = try await scoped.dispatch([#"{"type":"switch_profile","id":"kid"}"#], now: 1)
            case "resources": await scoped.invalidateResources()
            case "owner": scoped.revoke()
            default: operation.cancel()
            }
            held.release("old/meta/source0"); held.release("old:1:1/stream/source0")
            do { _ = try await operation.value; check(false) } catch {}
            check(publications.count == 1)
            if boundary == "profile" {
                do { _ = try await scoped.loadMeta(request: .init(resource: .meta, type: "series", id: "new"), stream: nil,
                    addons: [registry[0]], expectedProfileID: "owner"); check(false) } catch VortxNativeError.superseded {}
                check(held.started.count == 2)
                check(await scoped.screen("meta_details") == nil)
            }
            await scoped.close()
        }
        print("Native detail fanout: all22 providers, singleton20s budgets, meta2/stream4 bounds,32MiB aggregate/resource, early partial/order/failure/empty rows and latest-request/owner cancellation passed")
    }
    static func catalogFanoutTests() async throws {
        let ids = ["slow", "failure", "fast", "fourth", "fifth", "sixth", "unrequested"]
        let transport = CatalogFanoutTransport(held: ids.prefix(6).map { "first/" + $0 } + ["first/fast/skip1"])
        let session = try VortxNativeSession(scope: .init(account: "catalog-fanout", ownerProfileID: "owner"),
            ownerName: "Owner", abi: SessionABI(), store: SessionStore(), transport: transport, allowNewAccount: true)
        let registry = ids.map { id in VortxResourceAddon(id: "source-" + id, transportUrl: "https://\(id).fixture/manifest.json",
            manifest: .object(["catalogs": .array([.object(["id": .string(id), "type": .string("movie"),
                "extraSupported": .array(id == "fourth" ? [.string("search")] : [.string("search"), .string("skip")])])])])) }
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: registry, changed: { _ in })
        func state() -> VortxJSON? { facade.stateData("board").flatMap { try? JSONDecoder().decode(VortxJSON.self, from: $0) } }
        func rows() -> [VortxJSON] { state()?["catalogs"]?.array ?? [] }
        func status(_ index: Int) -> VortxJSON? { let rows = rows(); return index < rows.count ? rows[index].array?.first?["content"]?["type"] : nil }
        func load(_ query: String) throws {
            let action: VortxJSON = .object(["action": .string("Load"), "args": .object(["model": .string("CatalogsWithExtra"),
                "args": .object(["extra": .array([.array([.string("search"), .string(query)])])])])])
            check(facade.dispatch(data: try JSONEncoder().encode(action), field: "board"))
        }
        func range(_ start: Int, _ end: Int) throws {
            let action: VortxJSON = .object(["action": .string("CatalogsWithExtra"), "args": .object(["action": .string("LoadRange"),
                "args": .object(["start": .integer(Int64(start)), "end": .integer(Int64(end))])])])
            check(facade.dispatch(data: try JSONEncoder().encode(action), field: "board"))
        }
        try load("first"); try range(0, 5)
        try await eventually { transport.started.count == 4 }
        check(Set(transport.started) == Set(ids.prefix(4).map { "first/" + $0 }))
        check(transport.maximumActive == 4)
        transport.release("first/fast")
        try await eventually { status(2) == .string("Ready") && transport.started.count == 5 }
        check(status(0) == .string("Loading")) // fast row publishes before the deliberately blocked first row
        let horizontalPage = Data(#"{"action":"CatalogsWithExtra","args":{"action":"LoadNextPage","args":2}}"#.utf8)
        check(!facade.dispatch(data: horizontalPage, field: "board"))
        check(facade.lastFailure == "catalog_range_loading" && !transport.wasCancelled("first/slow"))
        check(facade.dispatchCatalogPage(field: "board", index: 2) == .busy)
        check(rows().count == ids.count && rows()[6].array?.first?["content"] == .null)
        transport.release("first/failure")
        try await eventually { status(1) == .string("Err") && transport.started.count == 6 }
        check(status(2) == .string("Ready")) // one thrown request cannot discard another catalog
        for id in ids[3...5] { transport.release("first/" + id) }
        try await eventually { status(5) == .string("Ready") }
        check(status(0) == .string("Loading") && transport.maximumActive == 4)
        transport.release("first/slow"); await facade.settled()
        check(rows().enumerated().allSatisfy { index, row in row.array?.first?["request"]?["path"]?["id"] == .string(ids[index]) })
        check(state()?["selected"]?["extra"] == .array([.array([.string("search"), .string("first")])]))
        try range(0, 5); await facade.settled(); check(transport.started.count == 6) // settled rows are reused
        check(facade.dispatchCatalogPage(field: "board", index: 3) == .exhausted) // no skip support: no global latch
        check(transport.started.count == 6)
        check(facade.dispatchCatalogPage(field: "board", index: 2) == .started(itemCount: 1, pageCount: 1))
        try await eventually { transport.started.contains("first/fast/skip1") }
        check(rows()[2].array?.count == 2 && rows()[2].array?.last?["content"]?["type"] == .string("Loading"))
        transport.release("first/fast/skip1")
        await facade.settled()
        check(rows()[2].array?.count == 2 && status(0) == .string("Ready"))
        check(!rows().contains { $0.array?.contains { $0["content"]?["type"] == .string("Loading") } == true })
        try range(6, 6); await facade.settled(); check(transport.started.count == 8 && status(6) == .string("Ready"))
        check(facade.dispatchCatalogPage(field: "board", index: 4) == .started(itemCount: 1, pageCount: 1))
        await facade.settled()
        check(rows()[4].array?.count == 2 && rows()[4].array?.last?["content"]?["type"] == .string("Err"))
        check(rows().count == ids.count && rows()[2].array?.count == 2 && status(0) == .string("Ready"))
        check(facade.dispatchCatalogPage(field: "board", index: 4) == .exhausted)
        check(facade.dispatchCatalogPage(field: "board", index: 5) == .started(itemCount: 1, pageCount: 1))
        await facade.settled()
        check(rows()[5].array?.last?["content"]?["type"] == .string("Ready"))
        check(rows()[4].array?.last?["content"]?["type"] == .string("Err")) // peer paging retains failure receipt
        try load("range"); try range(2, 2); await facade.settled()
        check(transport.started.filter { $0.hasPrefix("range/") } == ["range/fast"])
        check(status(2) == .string("Ready") && rows()[0].array?.first?["content"] == .null)
        await facade.shutdown()

        // The old provider ignores cancellation. Facade generation ownership must still protect a
        // replacement query and Unload, even after its callback is already running on a worker.
        for unload in [false, true] {
            let blocked = CatalogFanoutTransport(held: ["old/slow"])
            let scoped = try VortxNativeSession(scope: .init(account: "latest-query-\(unload)", ownerProfileID: "owner"),
                ownerName: "Owner", abi: SessionABI(), store: SessionStore(), transport: blocked, allowNewAccount: true)
            let bridge = try await VortxNativeCoreFacade.create(session: scoped, registry: [registry[0]], changed: { _ in })
            func dispatch(_ raw: String) { check(bridge.dispatch(data: Data(raw.utf8), field: "search")) }
            dispatch(#"{"action":"Load","args":{"model":"CatalogsWithExtra","args":{"extra":[["search","old"]]}}}"#)
            dispatch(#"{"action":"CatalogsWithExtra","args":{"action":"LoadRange","args":{"start":0,"end":0}}}"#)
            try await eventually { blocked.started.count == 1 }
            let oldCompletion = Task { await bridge.settled() }
            // Allow settled() to capture the currently admitted task before replacement.
            await Task.yield()
            if unload { dispatch(#"{"action":"Unload"}"#) }
            else {
                dispatch(#"{"action":"Load","args":{"model":"CatalogsWithExtra","args":{"extra":[["search","new"]]}}}"#)
                dispatch(#"{"action":"CatalogsWithExtra","args":{"action":"LoadRange","args":{"start":0,"end":0}}}"#)
                try await eventually { blocked.started.contains("new/slow") }
            }
            blocked.release("old/slow"); await oldCompletion.value; await bridge.settled()
            let latest = try JSONDecoder().decode(VortxJSON.self, from: bridge.stateData("search")!)
            check(blocked.wasCancelled("old/slow"))
            if unload { check(latest["selected"] == .null && latest["catalogs"] == .array([])) }
            else { check(latest["catalogs"]?.array?.first?.array?.first?["content"]?["content"]?.array?.first?["id"] == .string("new/slow")) }
            await bridge.shutdown()
        }
        // Actor epoch, profile change, synchronous owner revocation and explicit task cancellation
        // independently fence the batch, including when the transport eventually returns success.
        for boundary in ["profile", "resources", "owner", "cancel"] {
            let blocked = CatalogFanoutTransport(held: ["old/slow"]), publications = CatalogPublications()
            let scoped = try VortxNativeSession(scope: .init(account: "batch-\(boundary)", ownerProfileID: "owner"),
                ownerName: "Owner", abi: SessionABI(), store: SessionStore(), transport: blocked, allowNewAccount: true)
            let operation = Task { try await scoped.loadCatalogs(.search,
                catalogs: [(registry[0], .init(resource: .catalog, type: "movie", id: "slow", extra: [["search", "old"]]))],
                selection: .object(["extra": .array([.array([.string("search"), .string("old")])])]), range: 0...0,
                previous: nil, expectedProfileID: "owner", onUpdate: { publications.append($0) }) }
            try await eventually { blocked.started.count == 1 }
            check(publications.count == 1)
            switch boundary {
            case "profile": _ = try await scoped.dispatch([#"{"type":"switch_profile","id":"kid"}"#], now: 1)
            case "resources": await scoped.invalidateResources()
            case "owner": scoped.revoke()
            default: operation.cancel()
            }
            blocked.release("old/slow")
            do { _ = try await operation.value; check(false) } catch {}
            check(publications.count == 1)
            if boundary == "profile" {
                do {
                    _ = try await scoped.loadCatalogs(.search, catalogs: [(registry[0], .init(resource: .catalog, type: "movie", id: "slow"))],
                        selection: .object([:]), range: 0...0, previous: nil, expectedProfileID: "owner", onUpdate: { publications.append($0) })
                    check(false)
                } catch VortxNativeError.superseded {}
                check(blocked.started.count == 1 && publications.count == 1)
                check(await scoped.screen("search") == nil) // stale admission cannot replace the new owner's screen
            }
            await scoped.close()
        }
        print("Native catalog fanout: incremental rows, four-request bound, partial errors, inclusive range/order, latest-query cancellation and owner/profile fences passed")
    }
    static func watchlistAdmissionTests() async throws {
        let profile = UUID(uuidString: "00000000-0000-0000-0000-00000000A11C")!
        let scope = VortxAccountScope(account: "watchlist-busy", ownerProfileID: profile.uuidString)
        let store = SessionStore()
        let session = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: SessionABI(),
            store: store, transport: SessionTransport(), allowNewAccount: true)
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: [], changed: { _ in })
        let binding = facade.watchlistBinding!
        let entry = VortxNativeWatchlist.Entry(id: "tt-busy", type: "movie", name: "Queued title", poster: nil, addedAt: 123)
        store.blockNextWrite()
        let pending = Task { try await facade.mutateProfiles([], hostEdits: [.init(profileID: profile.uuidString, fields: ["avatar": .string("moon")])],
            expectedProfileID: profile.uuidString, expectedAccountGeneration: binding.accountGeneration) }
        await withCheckedContinuation { done in DispatchQueue.global().async { precondition(store.entered.wait(timeout: .now() + 5) == .success); done.resume() } }
        check(facade.registryBinding == nil && facade.watchlistBinding == binding)
        let add = Task { try await facade.setWatchlist(entry, present: true, expected: binding) }
        store.release.signal(); try await pending.value
        check(try await add.value)
        check(facade.watchlistBinding == binding)
        check(try VortxNativeWatchlist.entries(host: facade.profileSnapshot()!.host, profileID: profile) == [entry])
        // Another busy host edit does not invalidate a durable add receipt or its owner's target.
        store.blockNextWrite()
        let later = Task { try await facade.mutateProfiles([], hostEdits: [.init(profileID: profile.uuidString, fields: ["avatar": .string("sun")])],
            expectedProfileID: profile.uuidString, expectedAccountGeneration: binding.accountGeneration) }
        await withCheckedContinuation { done in DispatchQueue.global().async { precondition(store.entered.wait(timeout: .now() + 5) == .success); done.resume() } }
        check(facade.registryBinding == nil && facade.watchlistBinding == binding)
        let remove = Task { try await facade.setWatchlist(entry, present: false, expected: binding) }
        store.release.signal(); try await later.value
        check(try await !remove.value)
        check(try VortxNativeWatchlist.entries(host: facade.profileSnapshot()!.host, profileID: profile).isEmpty)
        func switchTo(_ id: String) throws {
            let action: VortxJSON = .object(["action": .string("Vortx"), "args": .object(["type": .string("switch_profile"), "id": .string(id)])])
            check(facade.dispatch(data: try JSONEncoder().encode(action), field: "native_state"))
        }
        try switchTo("kid"); await facade.settled(); try switchTo(profile.uuidString); await facade.settled()
        check(facade.watchlistBinding != binding && facade.watchlistBinding?.accountGeneration == binding.accountGeneration)
        do { _ = try await facade.setWatchlist(entry, present: true, expected: binding); check(false) } catch VortxNativeError.superseded {}
        let rebound = facade.watchlistBinding!
        var remote = try facade.profileSnapshot()!.state["nativeSync"]!.decode([String: VortxJSON].self)
        remote["accountSlots"] = .object([profile.uuidString: .object(["activeBinding": .object(["revision": .integer(1)])])])
        _ = try await facade.mergeSyncDocument(.object(remote))
        check(facade.watchlistBinding?.accountGeneration != rebound.accountGeneration)
        do { _ = try await facade.setWatchlist(entry, present: true, expected: rebound); check(false) } catch VortxNativeError.superseded {}
        let beforeClose = facade.watchlistBinding!
        await facade.shutdown()
        do { _ = try await facade.setWatchlist(entry, present: true, expected: beforeClose); check(false) } catch VortxNativeError.superseded {}
        let cold = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: SessionABI(), store: store, transport: SessionTransport())
        check(try VortxNativeWatchlist.entries(host: await cold.hostPreferencesDocument(), profileID: profile).isEmpty)
        await cold.close()
        print("Native watchlist: busy host FIFO add/remove, acknowledged membership, stable busy target, profile ABA/account rebind/logout rejection and cold readback passed")
    }
    static func main() async throws {
        try await detailFanoutTests()
        try await catalogFanoutTests()
        try await watchlistAdmissionTests()
        check(VortxNativeSyncExportPolicy.permitsStateOnlyExport(hasDirtySettings: false, hasLegacyAddonOrderIntent: false))
        check(!VortxNativeSyncExportPolicy.permitsStateOnlyExport(hasDirtySettings: true, hasLegacyAddonOrderIntent: false))
        check(!VortxNativeSyncExportPolicy.permitsStateOnlyExport(hasDirtySettings: false, hasLegacyAddonOrderIntent: true))
        check(!VortxNativeSyncExportPolicy.permitsStateOnlyExport(hasDirtySettings: false, hasLegacyAddonOrderIntent: false, overridingLegacySource: true))
        for key in ["vortx.watchlist", "vortx.watchlist.00000000-0000-0000-0000-00000000A11C", "future.unknown.setting"] {
            check(!VortxNativeSyncExportPolicy.acknowledgesSetting(key, syncable: true, profileProjection: false, projectionAcknowledged: false))
        }
        check(VortxNativeSyncExportPolicy.acknowledgesSetting("vortx.quickViewEnabled", syncable: true, profileProjection: false, projectionAcknowledged: false))
        check(!VortxNativeSyncExportPolicy.acknowledgesSetting("profile-field", syncable: true, profileProjection: true, projectionAcknowledged: false))
        check(VortxNativeSyncExportPolicy.acknowledgesSetting("profile-field", syncable: true, profileProjection: true, projectionAcknowledged: true))
        let scope = VortxAccountScope(account: "account-a", ownerProfileID: "owner")
        let actorA = "00000000-0000-0000-0000-000000000001", actorB = "00000000-0000-0000-0000-000000000002"
        var hostA = try VortxNativeHostPreferences(scope: scope, actor: actorA)
        var hostB = try VortxNativeHostPreferences(scope: scope, actor: actorB)
        try hostA.edit(profileID: "owner", fields: ["avatar": .string("🍿")], scope: scope)
        try hostB.edit(profileID: "owner", fields: ["avatar": .string("moon")], scope: scope)
        try hostA.merge(hostB.document, scope: scope)
        check(try hostA.document["profiles"]?["owner"]?["fields"]?["avatar"]?["value"] == .string("moon"))
        try hostA.edit(profileID: "owner", fields: ["avatar": .null], scope: scope)
        check(try hostA.document["profiles"]?["owner"]?["fields"]?["avatar"]?["clock"] == .integer(2))
        do { try hostA.edit(profileID: "owner", fields: ["pin": .string("1234")], scope: scope); fatalError("host carrier accepted native PIN") } catch {}
        do { try hostA.edit(profileID: "owner", fields: ["future": .object(["apiKey": .string("fixture-secret")])], scope: scope); fatalError("host carrier accepted nested credential") } catch {}
        var equivocal = try VortxNativeHostPreferences(scope: scope, actor: actorB)
        try equivocal.edit(profileID: "owner", fields: ["avatar": .string("different")], scope: scope)
        do { try hostB.merge(equivocal.document, scope: scope); fatalError("host carrier accepted equivocal event") } catch {}
        let restoredHost = try VortxNativeHostPreferences(scope: scope, actor: actorB, sealed: hostA.encoded())
        check(restoredHost.local.actor == actorB && restoredHost.local.counter == 2)
        var homePreference = try VortxNativeHostPreferences(scope: scope, actor: actorA)
        check(try homePreference.document["globals"]?["fields"]?["vortx.mergeHomeDiscover"] == nil) // UI owns default-on; no synthetic edit.
        try homePreference.edit(profileID: nil, fields: ["vortx.mergeHomeDiscover": .bool(false)], scope: scope)
        var homePeer = try VortxNativeHostPreferences(scope: scope, actor: actorB)
        try homePeer.merge(homePreference.document, scope: scope)
        check(try homePeer.document["globals"]?["fields"]?["vortx.mergeHomeDiscover"]?["value"] == .bool(false))
        try homePeer.edit(profileID: nil, fields: ["vortx.mergeHomeDiscover": .null], scope: scope)
        try homePreference.merge(homePeer.document, scope: scope)
        check(try homePreference.document["globals"]?["fields"]?["vortx.mergeHomeDiscover"]?["value"] == .null) // Clear restores UI default.
        do { try homePeer.edit(profileID: nil, fields: ["vortx.mergeHomeDiscover": .integer(1)], scope: scope); fatalError("home/discover accepted non-Bool") } catch VortxNativeError.invalidSnapshot {}
        for key in ["vortx.quickViewEnabled", "vortx.cinema.quickView", "vortx.downloads.autoDeleteWatched"] {
            check(try homePeer.document["globals"]?["fields"]?[key] == nil)
            try homePeer.edit(profileID: nil, fields: [key: .bool(false)], scope: scope)
            do { try homePeer.edit(profileID: nil, fields: [key: .integer(0)], scope: scope); check(false) } catch VortxNativeError.invalidSnapshot {}
        }
        let watchProfile = UUID(uuidString: "00000000-0000-0000-0000-00000000A11C")!
        var watchA = try VortxNativeHostPreferences(scope: scope, actor: actorA)
        var watchB = try VortxNativeHostPreferences(scope: scope, actor: actorB)
        let movie = VortxNativeWatchlist.Entry(id: "tt123", type: "movie", name: "Saved", poster: nil, addedAt: 123.25)
        let series = VortxNativeWatchlist.Entry(id: "tt123", type: "series", name: nil, poster: nil, addedAt: 124)
        let movieKey = try VortxNativeWatchlist.field(id: movie.id, type: movie.type)
        let seriesKey = try VortxNativeWatchlist.field(id: series.id, type: series.type)
        check(movieKey == "watchlist.movie.dHQxMjM" && movieKey != seriesKey)
        try watchA.edit(profileID: watchProfile.uuidString, fields: [movieKey: VortxNativeWatchlist.value(movie)], scope: scope)
        try watchB.edit(profileID: watchProfile.uuidString, fields: [seriesKey: VortxNativeWatchlist.value(series)], scope: scope)
        try watchA.merge(watchB.document, scope: scope)
        check(try VortxNativeWatchlist.entries(host: watchA.document, profileID: watchProfile).count == 2)
        try watchA.edit(profileID: watchProfile.uuidString, fields: [movieKey: .null], scope: scope)
        try watchA.merge(watchB.document, scope: scope)
        try VortxNativeWatchlist.seed([movie], profileID: watchProfile, into: &watchA)
        check(try VortxNativeWatchlist.entries(host: watchA.document, profileID: watchProfile) == [series])
        check(try watchA.document["profiles"]?[watchProfile.uuidString]?["fields"]?[movieKey]?["value"] == .null)
        var baselineWatch = try VortxNativeHostPreferences(scope: scope, actor: actorA)
        try VortxNativeWatchlist.seed([movie], profileID: watchProfile, into: &baselineWatch)
        check(baselineWatch.local.counter == 0 && baselineWatch.local.document.profiles[watchProfile.uuidString]?.fields[movieKey]?.clock == 0)
        var otherBaseline = try VortxNativeHostPreferences(scope: scope, actor: actorB)
        let changedMovie = VortxNativeWatchlist.Entry(id: "tt123", type: "movie", name: "🍿 / Revised", poster: nil, addedAt: 123.5)
        check(try VortxNativeWatchlist.baselineActor(profileID: watchProfile, field: movieKey,
            value: VortxNativeWatchlist.value(changedMovie)) == "e2845c02-42cf-6e8c-1cc4-bef50778d4b4")
        try VortxNativeWatchlist.seed([changedMovie], profileID: watchProfile, into: &otherBaseline)
        let firstBaseline = try baselineWatch.document, secondBaseline = try otherBaseline.document
        try baselineWatch.merge(secondBaseline, scope: scope)
        try otherBaseline.merge(firstBaseline, scope: scope)
        check(baselineWatch.local.document == otherBaseline.local.document)
        let seedWinner = try baselineWatch.document
        try VortxNativeWatchlist.seed([movie], profileID: watchProfile, into: &baselineWatch)
        check(try baselineWatch.document == seedWinner)
        try baselineWatch.edit(profileID: watchProfile.uuidString, fields: [movieKey: .null], scope: scope)
        try baselineWatch.merge(secondBaseline, scope: scope)
        check(try VortxNativeWatchlist.entries(host: baselineWatch.document, profileID: watchProfile).isEmpty)
        // JSONEncoder does not promise dictionary key order across separate encodes. Compare the
        // complete local state, including counters and journals, rather than incidental byte order.
        let beforeBadWatch = try JSONDecoder().decode(VortxJSON.self, from: watchA.encoded())
        do { try watchA.edit(profileID: watchProfile.uuidString, fields: [movieKey: .object(["id": .string("ttOther")])], scope: scope); check(false) } catch {}
        check(try JSONDecoder().decode(VortxJSON.self, from: watchA.encoded()) == beforeBadWatch)
        check(try VortxNativeWatchlist.entries(host: watchA.document, profileID: UUID()).isEmpty)
        var credentials = try VortxNativeProviderCredentials(scope: scope.account, actor: actorA)
        try credentials.edit(["tmdb": .string("fixture-nonproduction")])
        let sentCredentials = credentials.local.pending
        try credentials.edit(["tmdb": .null])
        credentials.acknowledge(sentCredentials)
        check(credentials.local.pending["tmdb"]?.value == .null) // old push cannot acknowledge newer clear
        var credentialPeer = try VortxNativeProviderCredentials(scope: scope.account, actor: actorB)
        try credentialPeer.merge(credentials.document)
        check(credentialPeer.mirror(into: ["tmdb": "fixture-old", "future": "retained"]) == ["future": "retained"])
        do { try credentials.edit(["unknownProvider": .string("not-exportable")]); fatalError("unknown provider accepted") } catch {}
        do { try credentials.edit(["traktAccess": .string("incomplete")]); fatalError("incomplete OAuth group accepted") } catch {}
        let credentialArchive = try VortxNativeBootstrapArchive.encode(document: JSONEncoder().encode(VortxJSON.object(["nativeProviderCredentials": try credentials.document])))
        let credentialArchiveJSON = try JSONDecoder().decode(VortxJSON.self, from: credentialArchive)
        check(credentialArchiveJSON["hostDocument"]?["nativeProviderCredentials"] == nil)
        check(credentialArchiveJSON["excludedCredentialPaths"] == .array([.string("/nativeProviderCredentials")]))
        let abi = SessionABI(), store = SessionStore(), transport = SessionTransport()
        let session = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: store, transport: transport, allowNewAccount: true)
        for _ in 0..<2 {
            do { _ = try VortxNativeSession(scope: scope, ownerName: "Other", abi: abi, store: SessionStore(), transport: transport, allowNewAccount: true); fatalError("overlapping account writer admitted") }
            catch VortxNativeError.unavailable {}
        }
        do { _ = try VortxNativeSession(scope: .init(account: scope.account, ownerProfileID: "other-owner"), ownerName: "Other", abi: abi, store: SessionStore(), transport: transport, allowNewAccount: true); fatalError("same account with a different owner admitted a second writer") }
        catch VortxNativeError.unavailable {}
        let before = try await session.stateJSON()
        do { _ = try await session.dispatch(["{\"type\":\"fail\"}"], now: 2); fatalError("invalid action accepted") }
        catch VortxNativeError.invalidResponse {}
        store.failWrites()
        do { _ = try await session.dispatch(["{\"type\":\"edit\",\"value\":42}"], now: 2); fatalError("unacknowledged state published") }
        catch VortxNativeError.checkpointUncertain {}
        check(try await session.stateJSON() == before)
        do { _ = try await session.dispatch(["{\"type\":\"edit\"}"], now: 3); fatalError("uncertain checkpoint overwritten") }
        catch VortxNativeError.checkpointUncertain {}
        let slow = Task { try await session.loadMeta(request: .init(resource: .meta, type: "series", id: "slow"), stream: nil,
            addons: [.init(id: "slow", transportUrl: "https://slow.fixture/manifest.json", manifest: nil)]) }
        await withCheckedContinuation { done in DispatchQueue.global().async { precondition(transport.entered.wait(timeout: .now() + 5) == .success); done.resume() } }
        _ = try await session.loadCatalog(.search, request: .init(resource: .catalog, type: "series", id: "popular"), addons: [])
        if case .loading = await session.screen("meta_details") {} else { fatalError("search clobbered meta slot") }
        await session.close(); transport.release.signal()
        do { _ = try await slow.value; fatalError("closed owner published") } catch VortxNativeError.superseded {}
        check(await session.screen("meta_details") == nil)

        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("sealed")
        let key = SymmetricKey(size: .bits256)
        let archive = try VortxNativeBootstrapArchive.encode(document: Data(#"{"futurePreference":{"keep":42},"apiKeys":{"provider":"fixture-excluded"}}"#.utf8),
                                                              material: Data(#"{"schemaVersion":1,"sourceClock":1000.125}"#.utf8))
        // A separate installation proof authenticates the inventory without sharing account keys.
        // Legacy/unindexed and corrupt history never establish absence for a different account.
        let indexedDirectory = directory.deletingLastPathComponent().appendingPathComponent("indexed-accounts")
        let installKey = SymmetricKey(size: .bits256), keyB = SymmetricKey(size: .bits256)
        let scopeB = VortxAccountScope(account: "account-b", ownerProfileID: scope.ownerProfileID)
        let scopeC = VortxAccountScope(account: "account-c", ownerProfileID: scope.ownerProfileID)
        let legacyA = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: key, bootstrap: archive, bootstrapScope: scope)
        try legacyA.commit(before, scope: scope); try legacyA.rememberAuthenticatedScope(scope)
        let indexedB = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: keyB, installationKey: installKey, bootstrap: archive, bootstrapScope: scopeB)
        do { _ = try indexedB.authenticatedCheckpoint(scope: scopeB); fatalError("legacy other-account history admitted new account") } catch {}
        let indexedA = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: key, installationKey: installKey)
        check(try indexedA.authenticatedCheckpoint(scope: scope) == before)
        try indexedA.rememberAuthenticatedScope(scope)
        check(try indexedB.authenticatedCheckpoint(scope: scopeB) == nil)
        do { _ = try indexedB.recovery(account: scope.account); fatalError("inventory key decrypted another account") } catch {}
        let stateB = before.replacingOccurrences(of: "account-a", with: "account-b")
        try indexedB.commit(stateB, scope: scopeB)
        let indexedC = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: SymmetricKey(size: .bits256), installationKey: installKey)
        do { _ = try indexedC.authenticatedCheckpoint(scope: scopeC); fatalError("crash between checkpoint and locator admitted new account") } catch {}
        try indexedB.rememberAuthenticatedScope(scopeB)
        check(try indexedC.authenticatedCheckpoint(scope: scopeC) == nil)
        try indexedA.commit(before, scope: scope)
        check(try indexedC.authenticatedCheckpoint(scope: scopeC) == nil)
        let indexedFiles = try FileManager.default.contentsOfDirectory(at: indexedDirectory, includingPropertiesForKeys: nil)
        let accountIndexes = indexedFiles.filter { $0.lastPathComponent.hasPrefix("native-account-v2-") }
        check(accountIndexes.count == 2)
        for file in indexedFiles {
            let sealedBytes = try Data(contentsOf: file)
            check(sealedBytes.range(of: Data("account-a".utf8)) == nil)
            check(sealedBytes.range(of: Data("Retain context".utf8)) == nil)
        }
        let indexPath = accountIndexes[0], indexBytes = try Data(contentsOf: accountIndexes[0])
        try Data("corrupt-index".utf8).write(to: indexPath)
        do { _ = try indexedC.authenticatedCheckpoint(scope: scopeC); fatalError("corrupt inventory admitted new account") } catch {}
        try indexBytes.write(to: indexPath)
        try FileManager.default.removeItem(at: indexPath)
        do { _ = try indexedC.authenticatedCheckpoint(scope: scopeC); fatalError("missing index admitted new account") } catch {}
        try indexedA.rememberAuthenticatedScope(scope); try indexedB.rememberAuthenticatedScope(scopeB)
        check(try indexedC.authenticatedCheckpoint(scope: scopeC) == nil)
        let pairedLocator = indexedFiles.first { $0.lastPathComponent.hasPrefix("native-account-v1-") }!
        let pairedBytes = try Data(contentsOf: pairedLocator)
        try FileManager.default.removeItem(at: pairedLocator)
        do { _ = try indexedC.authenticatedCheckpoint(scope: scopeC); fatalError("v2 inventory without paired v1 locator admitted absence") } catch {}
        try Data("altered-account-locator".utf8).write(to: pairedLocator)
        do { _ = try indexedC.authenticatedCheckpoint(scope: scopeC); fatalError("corrupt paired v1 locator admitted absence") } catch {}
        try pairedBytes.write(to: pairedLocator)
        let orphanDirectory = directory.deletingLastPathComponent().appendingPathComponent("orphan-locator")
        try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
        try pairedBytes.write(to: orphanDirectory.appendingPathComponent(pairedLocator.lastPathComponent))
        let orphanNoKey = try VortxEncryptedCheckpointStore(directory: orphanDirectory, key: keyB)
        do { _ = try orphanNoKey.authenticatedCheckpoint(scope: scopeC); fatalError("nil install key ignored orphan account locator") } catch {}
        let orphanWithKey = try VortxEncryptedCheckpointStore(directory: orphanDirectory, key: keyB, installationKey: installKey)
        do { _ = try orphanWithKey.authenticatedCheckpoint(scope: scopeC); fatalError("orphan legacy locator established absence") } catch {}
        for prefix in [".native-checkpoint-", ".native-locator-", ".native-index-"] {
            let staged = indexedDirectory.appendingPathComponent(prefix + "fixture.sealed")
            try Data("interrupted-durable-stage".utf8).write(to: staged)
            check(try indexedA.authenticatedCheckpoint(scope: scope) == before)
            do { _ = try indexedC.authenticatedCheckpoint(scope: scopeC); fatalError("interrupted durable stage established absence") } catch {}
            try FileManager.default.removeItem(at: staged)
        }
        try Data("unrelated-file".utf8).write(to: indexedDirectory.appendingPathComponent("unrelated.txt"))
        check(try indexedC.authenticatedCheckpoint(scope: scopeC) == nil)
        let stateDigest = SHA256.hash(data: scope.authenticatedData).map { String(format: "%02x", $0) }.joined()
        let indexedStateA = indexedDirectory.appendingPathComponent("native-state-v1-\(stateDigest).sealed")
        let validIndexedState = try Data(contentsOf: indexedStateA)
        let prefix = Data("vortx-native-indexed-ciphertext-v2\n".utf8)
        var corrupted = try JSONSerialization.jsonObject(with: validIndexedState.dropFirst(prefix.count)) as! [String: Any]
        var ciphertext = Data(base64Encoded: corrupted["ciphertext"] as! String)!
        ciphertext[ciphertext.startIndex] ^= 1
        corrupted["ciphertext"] = ciphertext.base64EncodedString()
        try (prefix + JSONSerialization.data(withJSONObject: corrupted)).write(to: indexedStateA)
        do { _ = try indexedC.authenticatedCheckpoint(scope: scopeC); fatalError("altered account ciphertext passed inventory proof") } catch {}
        do { _ = try indexedA.recovery(account: scope.account); fatalError("altered account ciphertext passed account authentication") } catch {}
        try validIndexedState.write(to: indexedStateA)
        try FileManager.default.removeItem(at: indexedStateA)
        do { _ = try indexedC.authenticatedCheckpoint(scope: scopeC); fatalError("dangling authenticated index admitted absence") } catch {}
        try validIndexedState.write(to: indexedStateA)
        let accountOnly = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: key)
        check(try accountOnly.recovery(account: scope.account)?.state == before)
        // Device-key loss invalidates absence proofs, never the independently encrypted account data.
        let rotatedKey = SymmetricKey(size: .bits256)
        let rotatedA = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: key, installationKey: rotatedKey)
        let rotatedB = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: keyB, installationKey: rotatedKey)
        let rotatedC = try VortxEncryptedCheckpointStore(directory: indexedDirectory, key: SymmetricKey(size: .bits256), installationKey: rotatedKey)
        do { _ = try rotatedC.authenticatedCheckpoint(scope: scopeC); fatalError("lost installation key established absence") } catch {}
        check(try rotatedA.recovery(account: scope.account)?.state == before)
        try rotatedA.rememberAuthenticatedScope(scope)
        do { _ = try rotatedC.authenticatedCheckpoint(scope: scopeC); fatalError("partially repaired inventory established absence") } catch {}
        check(try rotatedB.recovery(account: scopeB.account)?.state == stateB)
        try rotatedB.rememberAuthenticatedScope(scopeB)
        check(try rotatedC.authenticatedCheckpoint(scope: scopeC) == nil)
        print("Native installation inventory: independent second-account admission, legacy/crash/corrupt/missing-index rejection, account-key isolation and install-key-loss repair passed")
        let encrypted = try VortxEncryptedCheckpointStore(directory: directory, key: key, bootstrap: archive, bootstrapScope: scope)
        try encrypted.commit(before, scope: scope)
        check(try encrypted.read(scope: scope) == before)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let stateFiles = files.filter { $0.lastPathComponent.hasPrefix("native-state-v1-") }
        precondition(stateFiles.count == 1)
        let bytes = try Data(contentsOf: stateFiles[0])
        precondition(bytes.range(of: Data("Retain context".utf8)) == nil)
        func archived(_ bytes: Data) throws -> Data? {
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: scope.authenticatedData)
            let envelope = try JSONSerialization.jsonObject(with: plain) as! [String: Any]
            return (envelope["bootstrap"] as? String).flatMap { Data(base64Encoded: $0) }
        }
        check(try archived(bytes) == archive)
        let coldStore = try VortxEncryptedCheckpointStore(directory: directory, key: key)
        check(try coldStore.read(scope: scope) == before)
        check(try coldStore.recovery(account: scope.account) == nil)
        check(try coldStore.authenticatedCheckpoint(scope: scope) == before)
        let changedOwner = VortxAccountScope(account: scope.account, ownerProfileID: "replacement-owner")
        do { _ = try coldStore.authenticatedCheckpoint(scope: changedOwner); fatalError("unindexed checkpoint reset by replacement owner") } catch {}
        try coldStore.rememberAuthenticatedScope(scope)
        let offlineRecovery = try coldStore.recovery(account: scope.account)
        check(offlineRecovery?.scope == scope && offlineRecovery?.state == before && offlineRecovery?.bootstrap == archive)
        check(try coldStore.recovery(account: "other-account") == nil)
        do { _ = try coldStore.authenticatedCheckpoint(scope: changedOwner); fatalError("authenticated locator owner replaced") } catch {}
        try coldStore.commit(before, scope: scope)
        check(try archived(Data(contentsOf: files[0])) == archive)
        let otherScope = VortxAccountScope(account: "account-b", ownerProfileID: scope.ownerProfileID)
        let otherState = before.replacingOccurrences(of: "account-a", with: "account-b")
        try encrypted.commit(otherState, scope: otherScope)
        let otherFile = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0 != files[0] && $0.lastPathComponent.hasPrefix("native-state-") }!
        let otherPlain = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: otherFile)), using: key, authenticating: otherScope.authenticatedData)
        check((try JSONSerialization.jsonObject(with: otherPlain) as! [String: Any])["bootstrap"] == nil)
        // Prior raw-runtime files remain readable; their next commit adopts a sealed envelope.
        let legacySealed = try AES.GCM.seal(Data(before.utf8), using: key, authenticating: scope.authenticatedData).combined!
        try legacySealed.write(to: files[0], options: .atomic)
        check(try encrypted.read(scope: scope) == before)
        try encrypted.commit(before, scope: scope)
        check(try archived(Data(contentsOf: files[0])) == archive)
        let wrongKey = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256))
        do { _ = try wrongKey.recovery(account: scope.account); fatalError("wrong key recovered account locator") } catch {}
        do { _ = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: wrongKey, transport: transport, allowNewAccount: true); fatalError("decrypt failure seeded empty owner") }
        catch {}
        let restarted = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: encrypted, transport: transport)
        check(try await restarted.stateJSON() == before)
        await restarted.close()
        let hostSession = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: encrypted, transport: transport, hostActor: actorA)
        _ = try await hostSession.dispatch([#"{"type":"edit","value":711}"#], now: 7,
                                          hostEdits: [.init(profileID: "owner", fields: ["avatar": .string("moon")])])
        let sealedHost = try encrypted.readHostPreferences(scope: scope)!
        check(try await VortxNativeHostPreferences(scope: scope, actor: actorA, sealed: sealedHost).document == hostSession.hostPreferencesDocument())
        check(try encrypted.read(scope: scope)?.contains("711") == true)
        let validHostState = try encrypted.read(scope: scope)
        for (field, malformed) in [("avatar", VortxJSON.integer(1)), ("playback", .string("invalid")), ("discovery", .string("invalid")), ("addonPreferences", .array([]))] {
            do {
                _ = try await hostSession.dispatch([#"{"type":"edit","value":999}"#], now: 8,
                    hostEdits: [.init(profileID: "owner", fields: [field: malformed])])
                fatalError("malformed presentation field was committed")
            } catch {}
            check(try encrypted.read(scope: scope) == validHostState)
            check(try encrypted.readHostPreferences(scope: scope) == sealedHost)
        }
        await hostSession.close()
        let legacyJSON = "{\"profiles\":[{\"id\":\"retained\"}]}"
        let legacy = try VortxLegacyImport(scope: scope, documents: [VortxLegacyImport.rosterID: legacyJSON])
        do { _ = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: SessionStore(), transport: transport, allowNewAccount: true, legacy: legacy); fatalError("legacy account overwritten") }
        catch VortxNativeError.invalidSnapshot {}
        precondition(legacy.documents[VortxLegacyImport.rosterID] == legacyJSON)
        let ambiguousStore = SessionStore()
        let ambiguous = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: ambiguousStore, transport: transport, allowNewAccount: true)
        ambiguousStore.failWrites(afterInstall: true)
        do { _ = try await ambiguous.dispatch(["{\"type\":\"edit\",\"value\":99}"], now: 4); fatalError("uncertain commit acknowledged") }
        catch VortxNativeError.checkpointUncertain {}
        let priorPublication = try await ambiguous.stateJSON()
        let uncertainDisk = try ambiguousStore.read(scope: scope)!
        precondition(priorPublication != uncertainDisk)
        await ambiguous.close(); ambiguousStore.recover()
        let recovered = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: ambiguousStore, transport: transport)
        check(try await recovered.stateJSON() == uncertainDisk)
        await recovered.close()
        let firstImportStore = SessionStore()
        do {
            _ = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: firstImportStore,
                                       transport: transport, allowNewAccount: true, initialActions: [#"{"type":"fail"}"#])
            fatalError("failed cold import published a checkpoint")
        } catch VortxNativeError.invalidResponse {}
        check(try firstImportStore.read(scope: scope) == nil)
        let candidate = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: firstImportStore,
                                                transport: transport, allowNewAccount: true,
                                                initialActions: [#"{"type":"edit","value":314}"#])
        let firstImport = try firstImportStore.read(scope: scope)
        check(firstImport?.contains("314") == true)
        // Revocation reaches a candidate before any facade is installed, not just active UI state.
        VortxNativeSession.revokeAllForOwnerBoundary()
        do { _ = try await candidate.dispatch([#"{"type":"edit","value":315}"#], now: 5); fatalError("uninstalled revoked candidate wrote state") }
        catch VortxNativeError.closed {}
        check(try firstImportStore.read(scope: scope) == firstImport)
        await candidate.close()
        let pagingSession = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: SessionStore(), transport: transport, allowNewAccount: true)
        let pagingManifest = try JSONDecoder().decode(VortxJSON.self, from: Data(#"{"catalogs":[{"id":"popular","type":"movie","name":"Popular","extra":[{"name":"skip"},{"name":"genre","options":["Drama","Comedy"]}]},{"id":"recent","type":"movie","extra":[{"name":"skip"}]}]}"#.utf8))
        let paging = try await VortxNativeCoreFacade.create(session: pagingSession, registry: [.init(id: "paging", transportUrl: "https://fixture.example/manifest.json", manifest: pagingManifest)], changed: { _ in })
        func pagingField(_ field: String) throws -> VortxJSON { try JSONDecoder().decode(VortxJSON.self, from: paging.stateData(field)!) }
        func pageDispatch(_ raw: String, _ field: String) async {
            check(paging.dispatch(data: Data(raw.utf8), field: field)); await paging.settled()
        }
        await pageDispatch(#"{"action":"Load","args":{"model":"CatalogsWithExtra","args":{"extra":[]}}}"#, "board")
        await pageDispatch(#"{"action":"CatalogsWithExtra","args":{"action":"LoadRange","args":{"end":1}}}"#, "board")
        await pageDispatch(#"{"action":"CatalogsWithExtra","args":{"action":"LoadNextPage","args":0}}"#, "board")
        check(try pagingField("board")["catalogs"]?.array?.first?.array?.count == 2)
        await pageDispatch(#"{"action":"CatalogsWithExtra","args":{"action":"LoadRange","args":{"end":2}}}"#, "board")
        check(try pagingField("board")["catalogs"]?.array?.count == 2)
        check(try pagingField("board")["catalogs"]?.array?.first?.array?.count == 2) // widening keeps horizontal pages
        await pageDispatch(#"{"action":"Load","args":{"model":"CatalogWithFilters","args":null}}"#, "discover")
        let selectable = try pagingField("discover")["selectable"]!
        check(selectable["types"]?.array?.count == 1 && selectable["catalogs"]?.array?.count == 2)
        check(selectable["extra"]?.array?.first?["options"]?.array?.count == 3)
        let genreRequest = selectable["extra"]!.array![0]["options"]!.array![1]["request"]!
        let genreAction: VortxJSON = .object(["action": .string("Load"), "args": .object(["model": .string("CatalogWithFilters"), "args": .object(["request": genreRequest])])])
        check(paging.dispatch(data: try JSONEncoder().encode(genreAction), field: "discover")); await paging.settled()
        await pageDispatch(#"{"action":"CatalogWithFilters","args":{"action":"LoadNextPage"}}"#, "discover")
        check(try pagingField("discover")["catalog"]?.array?.count == 2)
        let secondPath = try pagingField("discover")["catalog"]!.array![1]["request"]!["path"]!
        check(try secondPath["extra"]?.decode([[String]].self) == [["genre", "Drama"], ["skip", "1"]])
        await pageDispatch(#"{"action":"CatalogWithFilters","args":{"action":"LoadNextPage"}}"#, "discover")
        check(try pagingField("discover")["selectable"]?["next_page"] == .null)
        let exhausted = try pagingField("discover")
        await pageDispatch(#"{"action":"CatalogWithFilters","args":{"action":"LoadNextPage"}}"#, "discover")
        check(try pagingField("discover") == exhausted)
        check(!paging.dispatch(data: Data(#"{"action":"Load","args":{"model":"CatalogWithFilters","args":{"request":{"base":"https://fixture.example/manifest.json","path":{"resource":"catalog","type":"movie","id":"popular","extra":[["genre","Unknown"]]}}}}}"#.utf8), field: "discover"))
        await paging.shutdown()
        let transitionStore = SessionStore()
        let transitionSession = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: transitionStore, transport: transport, allowNewAccount: true)
        let mutations = MutationCounter()
        let facade = try await VortxNativeCoreFacade.create(session: transitionSession, registry: [], mutationAccepted: { mutations.increment() }, changed: { _ in })
        let nativeCW = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("continue_watching_preview")!)
        check(nativeCW["items"]?.array?.first?["state"]?["timeOffset"] == .integer(120001))
        check(nativeCW["items"]?.array?.first?["state"]?["video_id"] == .string("opaque-video"))
        let nativeLibrary = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("library")!)
        check(nativeLibrary["catalog"] == .array([])) // history/resume is not saved membership
        check(facade.cachedResumeSeconds(id: "opaque-video") == 120.001)
        check(facade.cachedResumeSeconds(id: "finished") == 0)
        check(facade.cachedResumeSeconds(id: "unknown") == nil)
        check(try await facade.resumeSeconds(id: "unknown", profileID: "owner", expectedAccountGeneration: facade.accountGeneration) == 3.001)
        transitionStore.blockNextWrite()
        check(facade.dispatch(data: Data(#"{"action":"Vortx","args":{"type":"switch_profile","id":"kid"}}"#.utf8), field: nil))
        await withCheckedContinuation { done in DispatchQueue.global().async { precondition(transitionStore.entered.wait(timeout: .now() + 5) == .success); done.resume() } }
        check(!facade.dispatch(data: Data(#"{"action":"Ctx","args":{"action":"AddToLibrary","args":{"id":"tt-old","type":"movie","name":"Old"}}}"#.utf8), field: nil))
        check(facade.lastFailure == "profile_transition_pending")
        check(!facade.dispatchForProfile(.object(["type": .string("report_progress")]), profileID: "owner", expectedAccountGeneration: facade.accountGeneration))
        check(facade.dispatch(data: Data(#"{"action":"Vortx","args":{"type":"get_state"}}"#.utf8), field: nil))
        transitionStore.release.signal(); await facade.settled()
        let published = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("native_state")!)
        check(published["activeProfileId"] == .string("kid"))
        check(facade.registryBinding?.profileID == "kid")
        check(facade.lastFailure == nil)
        check(!facade.dispatchForProfile(.object(["type": .string("mark_watched"), "metaId": .string("late")]), profileID: "owner", expectedAccountGeneration: facade.accountGeneration))
        check(mutations.value == 1) // switch acknowledged; queued get_state does not schedule a push
        check(!facade.reorderAddonURLs([], profileID: "owner"))
        check(facade.reorderAddonURLs([], profileID: "kid"))
        await facade.settled()
        check(mutations.value == 2) // the single admitted local reorder acknowledges once
        let remote: VortxJSON = .object(["schemaVersion": .integer(1), "scope": .string(scope.account), "ownerProfileId": .string(scope.ownerProfileID), "fixturePeer": .string("retained")])
        let exported = try await facade.mergeSyncDocument(remote)
        check(exported == remote && exported["activeProfileId"] == nil && exported["libraries"] == nil)
        check(mutations.value == 2) // remote merge must not self-echo
        let durable = try JSONDecoder().decode(VortxJSON.self, from: Data(try transitionStore.read(scope: scope)!.utf8))
        check(durable["nativeSync"] == remote && durable["activeProfileId"] == .string("kid"))
        do { _ = try await facade.mergeSyncDocument(.object(["scope": .string("another-account")])); fatalError("foreign account carrier exported") }
        catch VortxNativeError.invalidResponse {}
        abi.failPlaybackQueries()
        do { _ = try await facade.mergeSyncDocument(nil); fatalError("failed playback query exported successful empty history") }
        catch VortxNativeError.invalidResponse {}
        check(!facade.isAvailable && facade.stateData("continue_watching_preview") == nil)
        check(facade.lastFailure == "native_projection_unavailable_reopen_required")
        await facade.shutdown()
        let unavailableSession = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: transitionStore, transport: transport)
        do { _ = try await VortxNativeCoreFacade.create(session: unavailableSession, registry: [], changed: { _ in }); fatalError("unsupported playback query mounted") }
        catch VortxNativeError.invalidResponse {}
        await unavailableSession.close()
        print("Native session: acknowledged transactions, sealed cold state/context, legacy preservation and independent screen/logout fences passed")
    }
}
