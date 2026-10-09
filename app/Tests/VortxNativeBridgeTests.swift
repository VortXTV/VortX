import Foundation

private final class FakeRuntime: VortxRuntimeABI, @unchecked Sendable {
    var values: [UInt: String] = [:]
    var next: UInt = 0
    var freed: [UInt] = []
    var dirty: Set<UInt> = []
    func create(ownerID: String, ownerName: String) -> UInt { hydrate("{\"owner\":\"\(ownerID)\"}") }
    func hydrate(_ snapshot: String) -> UInt {
        guard (try? JSONSerialization.jsonObject(with: Data(snapshot.utf8))) != nil else { return 0 }
        next += 1; values[next] = snapshot; return next
    }
    func dispatch(_ handle: UInt, action: String, now: UInt64) -> String? { dirty.insert(handle); return "{\"ok\":true}" }
    func resolve(_ handle: UInt, request: String) -> String? { request }
    func state(_ handle: UInt) -> String? { values[handle] }
    func delta(_ handle: UInt) -> String? { dirty.remove(handle) == nil ? "{}" : values[handle] }
    func free(_ handle: UInt) { precondition(values.removeValue(forKey: handle) != nil); freed.append(handle) }
}

private final class FixtureTransport: VortxResourceTransport, @unchecked Sendable {
    final class Token: VortxResourceCancellation, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    let fixture: [String: VortxJSON]
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    init(_ fixture: [String: VortxJSON]) { self.fixture = fixture }
    func waitForEntry() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                precondition(entered.wait(timeout: .now() + 5) == .success)
                continuation.resume()
            }
        }
    }
    func makeCancellation() throws -> any VortxResourceCancellation { Token() }
    func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String {
        let input = try JSONDecoder().decode(VortxJSON.self, from: Data(requestJSON.utf8))
        let request = input["request"]!
        if request["id"] == .string("slow") { entered.signal(); release.wait() }
        let resource = try request["resource"]!.decode(String.self)
        var response: [String: VortxJSON] = [
            "kind": .string("resource_result"), "requestId": input["requestId"]!, "generation": input["generation"]!,
            "request": request, "cancelled": .bool(false),
            "groups": .array([.object(["addonId": .string("a"), "status": .string("ready"), "content": fixture[resource]!]),
                              .object(["addonId": .string("b"), "status": .string("timeout"), "error": .object(["code": .string("timeout")])])]),
        ]
        if request["id"] == .string("wrong") { response["requestId"] = .string("foreign-request") }
        if request["id"] == .string("malformed") {
            response["groups"] = .array([
                .object(["addonId": .string("a"), "status": .string("ready"), "content": fixture[resource]!]),
                .object(["addonId": .string("b"), "status": .string("ready"), "content": .string("malformed-private-payload")]),
            ])
        }
        if request["id"] == .string("duplicate-source") {
            response["groups"] = .array([response["groups"]!.array![0], response["groups"]!.array![0]])
        }
        if request["id"] == .string("foreign-source") {
            response["groups"] = .array([.object(["addonId": .string("unknown"), "status": .string("ready"), "content": fixture[resource]!])])
        }
        if request["id"] == .string("wrong-generation") { response["generation"] = .integer(0) }
        if request["id"] == .string("wrong-path") {
            response["request"] = .object(["resource": .string(resource), "type": .string("movie"), "id": .string("other"), "extra": .array([])])
        }
        return String(decoding: try JSONEncoder().encode(VortxJSON.object(response)), as: UTF8.self)
    }
}

@main enum VortxNativeBridgeTests {
    static func check(_ value: Bool) { precondition(value) }
    static func main() async throws {
        let abi = FakeRuntime()
        let runtime = try VortxNativeRuntime(abi: abi, ownerID: "account/profile-a", ownerName: "A")
        _ = try runtime.dispatch("{}", now: 1)
        let captured = try runtime.stateJSON()
        check(try runtime.takeDeltaJSON() == captured)
        check(try runtime.takeDeltaJSON() == "{}")
        do { try runtime.replaceFromSnapshot("bad"); fatalError("bad snapshot accepted") } catch VortxNativeError.invalidSnapshot {}
        check(try runtime.stateJSON() == captured && abi.freed.isEmpty)
        try runtime.replaceFromSnapshot(captured)
        check(try runtime.takeDeltaJSON() == "{}" && abi.freed == [1])
        runtime.close(); runtime.close()
        precondition(abi.freed == [1, 2])
        do { _ = try runtime.stateJSON(); fatalError("closed handle used") } catch VortxNativeError.closed {}
        let cold = try VortxNativeRuntime(abi: abi, snapshot: captured)
        check(try cold.stateJSON() == captured); cold.close()

        let fixtures = try JSONDecoder().decode([String: VortxJSON].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let transport = FixtureTransport(fixtures)
        let bridge = VortxResourceBridge(transport: transport)
        let addons = ["a", "b"].map { VortxResourceAddon(id: $0, transportUrl: "https://\($0).example/manifest.json", manifest: fixtures["manifest"]) }
        func request(_ kind: VortxResourceRequest.Resource, _ id: String = "tt-fixture") -> VortxResourceRequest {
            VortxResourceRequest(resource: kind, type: "series", id: id)
        }
        let catalog = try await bridge.load(ownerID: "owner", request: request(.catalog, "popular"), addons: addons)
        var nextRequest = request(.catalog, "popular"); nextRequest.extra = [["skip", "100"]]
        let next = try await bridge.load(ownerID: "owner", request: nextRequest, addons: addons)
        let board = try VortxResourceProjection.board(pages: [catalog, next], registry: addons)
        precondition(board["catalogs"]?.array?.count == 2)
        precondition(board["catalogs"]?.array?.first?.array?.count == 2)
        let meta = try await bridge.load(ownerID: "owner", request: request(.meta), addons: addons)
        let streamRequest = request(.stream, "tt-fixture:1:2")
        let streams = try await bridge.load(ownerID: "owner", request: streamRequest, addons: addons)
        let detail = try VortxResourceProjection.metaDetails(meta: meta, streams: streams, expectedStream: streamRequest, registry: addons)
        precondition(detail["metaStreams"]?.array?.count == 1)
        let projected = detail["streams"]!.array![0]["content"]!["content"]!.array!
        precondition(projected.count == 2)
        precondition(projected[0]["behaviorHints"]?["videoSize"] == .integer(9007199254740993))
        precondition(projected[1]["fileIdx"] == .integer(3))
        let replacedRegistry = [VortxResourceAddon(id: "a", transportUrl: "https://replacement.example/manifest.json", manifest: fixtures["manifest"]), addons[1]]
        do { _ = try VortxResourceProjection.metaDetails(meta: meta, streams: streams, expectedStream: streamRequest, registry: replacedRegistry); fatalError("old source relabelled") }
        catch VortxNativeError.invalidResponse {}
        let emptyMeta = VortxResourceGroup(addonId: "a", status: .ready, content: .object(["meta": .null]), error: nil)
        let emptyEntry = try VortxResourceProjection.entry(emptyMeta, request: request(.meta), registry: addons)
        precondition(emptyEntry["content"]?["type"] == .string("Err"))
        let subtitles = try await bridge.load(ownerID: "owner", request: request(.subtitles), addons: addons)
        let subtitleRows = try VortxResourceProjection.subtitles(subtitles, registry: addons)
        precondition(subtitleRows.array![0]["content"]!["content"]!.array!.count == 2)
        precondition(subtitleRows.array![1]["content"]!["type"] == .string("Err"))
        for kind: VortxResourceRequest.Resource in [.catalog, .meta, .stream, .subtitles] {
            let isolated = try await bridge.load(ownerID: "owner", request: request(kind, "malformed"), addons: addons)
            check(isolated.groups.map(\.addonId) == ["a", "b"])
            check(isolated.groups[0].status == .ready && isolated.groups[0].content == fixtures[kind.rawValue])
            check(isolated.groups[1].status == .error && isolated.groups[1].content == nil)
            check(isolated.groups[1].error?.code == "invalid_response")
            let row = try VortxResourceProjection.entry(isolated.groups[1], request: isolated.request, registry: addons)
            check(row["content"]?["type"] == .string("Err"))
        }
        for id in ["wrong", "wrong-generation", "wrong-path", "duplicate-source", "foreign-source"] {
            do { _ = try await bridge.load(ownerID: "owner", request: request(.stream, id), addons: addons); fatalError("invalid envelope accepted: \(id)") }
            catch VortxNativeError.invalidResponse {}
        }

        let slow = Task { try await bridge.load(ownerID: "old-owner", request: request(.stream, "slow"), addons: addons) }
        await transport.waitForEntry()
        let newer = try await bridge.load(ownerID: "new-owner", request: streamRequest, addons: addons)
        transport.release.signal()
        do { _ = try await slow.value; fatalError("late old owner published") } catch VortxNativeError.superseded {}
        precondition(bridge.accepts(newer))
        let cancelled = Task { try await bridge.load(ownerID: "new-owner", request: request(.stream, "slow"), addons: addons) }
        await transport.waitForEntry()
        cancelled.cancel(); transport.release.signal()
        do { _ = try await cancelled.value; fatalError("cancelled request published") } catch {}
        precondition(!bridge.accepts(newer))
        bridge.invalidate()
        print("Native Swift bridge lifecycle, cold-load, grouped resources, projection, identity and cancellation contracts passed")
    }
}
