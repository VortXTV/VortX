import Foundation
import CoreFoundation

// This is an extraction regression, not live provider/native-ABI/device evidence. The script
// compiles the full production public resource DTO/bridge/projection and unchanged formatter,
// error enum, begin/current/invalidateScreens/loadMeta methods. Storage, lease, probe sink, and
// blocking transport are inert. No socket, account, Keychain, SDK, app, or media is accessed.
// Wire fixtures model the verified public resource_result ABI: group.error has a string code
// and optional numeric HTTP status. They contain no private engine implementation or identities.
// INSERT_ACTUAL_ERROR

enum StubCore {
    // INSERT_ACTUAL_FORMATTER
    static func describe(_ content: Any?) -> String? { describeResourceError(content) }
}

final class ReceiptSink: @unchecked Sendable {
    static let shared = ReceiptSink()
    private let lock = NSLock()
    private var values: [(String, String)] = []
    func append(category: String, text: String) { lock.withLock { values.append((category, text)) } }
    func reset() { lock.withLock { values.removeAll() } }
    func lines() -> [String] { lock.withLock { values.filter { $0.0 == "native-addon" }.map(\.1) } }
}
enum VXProbe {
    static func log(_ category: StaticString, _ message: @autoclosure () -> String) {
        ReceiptSink.shared.append(category: String(describing: category), text: message())
    }
}
private final class UpdateSink: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [VortxJSON] = []
    func append(_ value: VortxJSON) { lock.withLock { values.append(value) } }
    func snapshots() -> [VortxJSON] { lock.withLock { values } }
}
struct FixtureScope: Sendable {
    func validateSnapshot(_ value: String) throws -> VortxJSON {
        try JSONDecoder().decode(VortxJSON.self, from: Data(value.utf8))
    }
}
final class FixtureLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func withActive<T>(_ action: () throws -> T) throws -> T {
        try lock.withLock { guard active else { throw VortxNativeError.closed }; return try action() }
    }
    func revoke() { lock.withLock { active = false } }
}
enum VortxNativeScreenState: Sendable { case loading, ready(VortxJSON), failed }
actor VortxNativeSession {
    private let scope = FixtureScope()
    private let lease = FixtureLease()
    private let transport: any VortxResourceTransport
    private var profile = "synthetic-owner"
    private var closed = false
    private var epoch = UUID()
    private var tickets: [String: UUID] = [:]
    private var bridges: [String: VortxResourceBridge] = [:]
    private var resourceBatchBridges: [String: [VortxResourceBridge]] = [:]
    private var catalogPlans: [String: VortxJSON] = [:]
    private var pages: [String: [VortxResourceSnapshot]] = [:]
    private var screens: [String: VortxNativeScreenState] = [:]
    private var catalogRegistries: [String: [VortxResourceAddon]] = [:]
    init(transport: any VortxResourceTransport) { self.transport = transport }
    private func stateJSON() throws -> String {
        guard !closed else { throw VortxNativeError.closed }
        return try lease.withActive {
            String(decoding: try JSONEncoder().encode(VortxJSON.object(["activeProfileId": .string(profile)])), as: UTF8.self)
        }
    }
    func changeProfile() { profile = "synthetic-new-profile"; invalidateScreens() }
    func changeConfiguration() { invalidateScreens() }
    func revokeLeaseOnly() { lease.revoke() }
    func retireAccount() { lease.revoke(); closed = true; invalidateScreens() }
    // INSERT_ACTUAL_SESSION
}

private final class FixtureToken: VortxResourceCancellation, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func isCancelled() -> Bool { lock.withLock { cancelled } }
}
private final class FixtureTransport: VortxResourceTransport, @unchecked Sendable {
    struct Input: Decodable {
        let requestId: String
        let generation: UInt64
        let request: VortxResourceRequest
        let addons: [VortxResourceAddon]
        let budgetMs: UInt64
    }
    private let condition = NSCondition()
    private var holding: Bool
    private var calls = 0
    private var budgets: [UInt64] = []
    private var resources: [VortxResourceRequest.Resource] = []
    private let mixed: Bool
    private let lateFailure: Bool
    init(held: Bool = false, mixed: Bool = true, lateFailure: Bool = false) {
        holding = held; self.mixed = mixed; self.lateFailure = lateFailure
    }
    func makeCancellation() throws -> any VortxResourceCancellation { FixtureToken() }
    func count() -> Int { condition.withLock { calls } }
    func observedBudgets() -> [UInt64] { condition.withLock { budgets } }
    func observedResources() -> [VortxResourceRequest.Resource] { condition.withLock { resources } }
    func release() { condition.lock(); holding = false; condition.broadcast(); condition.unlock() }
    func load(_ requestJSON: String, cancellation: any VortxResourceCancellation) throws -> String {
        let input = try JSONDecoder().decode(Input.self, from: Data(requestJSON.utf8))
        guard input.addons.count == 1, let addon = input.addons.first,
              let ordinal = Int(addon.id.dropFirst("source-".count)) else { throw VortxNativeError.invalidResponse }
        condition.lock(); calls += 1; budgets.append(input.budgetMs); resources.append(input.request.resource)
        while holding { condition.wait() }
        condition.unlock()
        // Intentionally ignore cancellation to test the production publication/receipt fences.
        _ = cancellation
        if lateFailure && ordinal == 1 { throw NSError(domain: "synthetic-secret", code: 1, userInfo: [NSLocalizedDescriptionKey: "https://synthetic-secret.invalid/apiKey=token"]) }
        if mixed && ordinal == 6 { throw VortxNativeError.unavailable }
        if mixed && ordinal == 8 { throw VortxNativeError.invalidResponse }
        if mixed && ordinal == 9 {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "synthetic-secret-must-not-escape"))
        }
        if mixed && ordinal == 10 { throw CancellationError() }
        if mixed && ordinal == 14 { throw NSError(domain: "synthetic-secret", code: 1, userInfo: [NSLocalizedDescriptionKey: "https://synthetic-secret.invalid/apiKey=token"]) }
        let resource = input.request.resource
        let group: VortxJSON
        if mixed && ordinal == 3 { group = Self.error(addon.id, code: "http", status: 429) }
        else if mixed && ordinal == 4 { group = Self.error(addon.id, code: "timeout", groupStatus: "timeout") }
        else if mixed && ordinal == 7 { group = Self.error(addon.id, code: "https://synthetic-secret.invalid/apiKey=token") }
        else if mixed && ordinal == 11 { group = Self.error(addon.id, code: "http", status: 503) }
        else if mixed && ordinal == 12 { group = Self.error(addon.id, code: "http", status: 401) }
        else if mixed && ordinal == 15 { group = .object(["addonId": .string(addon.id), "status": .string("error")]) }
        else {
            let content: VortxJSON
            if mixed && ordinal == 5 { content = .object(resource == .meta ? ["meta": .string("wrong-shape")] : ["streams": .array([.string("wrong-shape")])]) }
            else if resource == .meta {
                content = .object(["meta": mixed && ordinal == 2 ? .null : .object([
                    "id": .string(input.request.id), "type": .string(input.request.type), "name": .string("Synthetic title")])])
            } else {
                content = .object(["streams": .array(mixed && ordinal == 2 ? [] : [.object([
                    "name": .string("Synthetic stream"), "url": .string("https://media.invalid/synthetic-only")])])])
            }
            group = .object(["addonId": .string(addon.id), "status": .string("ready"), "content": content])
        }
        let request = try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(input.request))
        let result = VortxJSON.object(["kind": .string("resource_result"), "requestId": .string(input.requestId),
            "generation": .unsigned(input.generation), "request": request,
            "groups": .array(mixed && ordinal == 13 ? [] : [group]), "cancelled": .bool(false)])
        return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    }
    private static func error(_ addon: String, code: String, status: Int? = nil, groupStatus: String = "error") -> VortxJSON {
        var error: [String: VortxJSON] = ["code": .string(code)]
        if let status { error["status"] = .integer(Int64(status)) }
        return .object(["addonId": .string(addon), "status": .string(groupStatus), "error": .object(error)])
    }
}

@main struct NativeAddonErrorReceiptTests {
    @MainActor private static var failures = 0
    @MainActor private static var checks = 0
    private static let meta = VortxResourceRequest(resource: .meta, type: "movie", id: "synthetic-title")
    private static let stream = VortxResourceRequest(resource: .stream, type: "movie", id: "synthetic-title")
    private static let registry: [VortxResourceAddon] = (1...38).map {
        .init(id: "source-\($0)", transportUrl: "https://source.invalid/provider-\($0)/synthetic-secret/manifest.json?apiKey=synthetic-secret", manifest: nil)
    }
    @MainActor private static func expect(_ condition: Bool, _ name: String) {
        checks += 1; if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL") \(name)")
    }
    @MainActor private static func waitUntil(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
    private static func decodeGroup(code: String, status: VortxJSON? = nil, groupStatus: String = "error") throws -> VortxResourceGroup {
        var error: [String: VortxJSON] = ["code": .string(code)]
        if let status { error["status"] = status }
        return try VortxJSON.object(["addonId": .string("source-1"), "status": .string(groupStatus), "error": .object(error)]).decode(VortxResourceGroup.self)
    }
    private static func reflectedStatus(_ error: VortxResourceGroup.Failure?) -> Int? {
        guard let error else { return nil }
        return Mirror(reflecting: error).children.first { $0.label == "status" }?.value as? Int
    }
    private static func fields(_ line: String) -> [String: String] {
        Dictionary(line.split(separator: " ").compactMap { part in
            let pair = part.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        }, uniquingKeysWith: { _, next in next })
    }
    @MainActor private static func dtoProjectionAndFormatter() throws {
        for status in [401, 429, 503] {
            let group = try decodeGroup(code: "http", status: .integer(Int64(status)))
            expect(reflectedStatus(group.error) == status, "HTTP \(status) DTO status retained")
            let row = try VortxResourceProjection.entry(group, request: stream, registry: registry)
            expect(row["content"]?["content"]?["status"] == .integer(Int64(status)), "HTTP \(status) projection status retained")
            let content = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row["content"]?["content"] ?? .null))
            let text = StubCore.describe(content) ?? ""
            expect(text != "error" && text.contains(String(status)), "HTTP \(status) friendly native message retains status")
        }
        for invalid in [VortxJSON.integer(99), .integer(600), .string("429"), .bool(true), .number(429.5), .null] {
            let group = try decodeGroup(code: "http", status: invalid)
            expect(group.error?.code == "http" && reflectedStatus(group.error) == nil, "invalid HTTP status omitted without losing safe code")
        }
        expect(reflectedStatus(try decodeGroup(code: "network", status: .integer(429)).error) == nil, "non-HTTP status cannot relabel network error")
        let secret = try decodeGroup(code: "https://synthetic-secret.invalid/apiKey=token\nnetwork", status: .integer(401))
        expect(secret.error?.code == "native_resource_failed" && reflectedStatus(secret.error) == nil, "unknown secret-like code canonicalized and status omitted")
        for code in ["timeout", "network", "malformed", "invalid_response", "unavailable", "body_too_large", "invalid_source", "cancelled", "superseded", "native_resource_failed"] {
            let text = StubCore.describe(["code": code]) ?? ""
            expect(!text.isEmpty && text != "error" && !text.contains("synthetic-secret"), "native \(code) has truthful non-generic message")
        }
        let emptyMessage = StubCore.describe(["code": "empty_resource"])
        expect(emptyMessage == nil || (emptyMessage != "error" && emptyMessage?.localizedCaseInsensitiveContains("no results") == true), "native empty resource is not presented as failed provider")
        expect(StubCore.describe(["code": "https://synthetic-secret.invalid/apiKey=token"])?.contains("synthetic-secret") == false, "formatter never exposes arbitrary native code")
        expect(StubCore.describe("legacy plain message") == "legacy plain message", "legacy bare error preserved")
        expect(StubCore.describe(["type": "EmptyContent"]) == nil, "legacy EmptyContent preserved")
        expect(StubCore.describe(["type": "EmptyContent", "code": "http", "status": 401]) == nil, "native-like extension cannot override legacy EmptyContent")
        expect(StubCore.describe(["type": "Fetch", "content": "legacy fetch"]) == "Fetch: legacy fetch", "legacy tagged error preserved")
        expect(StubCore.describe(["type": "Env", "content": ["type": "Fetch", "content": "legacy fetch"]]) == "Env: Fetch: legacy fetch", "legacy nested tagged error preserved")
        for status in [100, 599] {
            expect(reflectedStatus(try decodeGroup(code: "http", status: .integer(Int64(status))).error) == status, "HTTP status boundary \(status) retained")
        }
        for status in [NSNumber(value: true), NSNumber(value: 401.5), NSNumber(value: -1), NSNumber(value: 600)] {
            let text = StubCore.describe(["code": "http", "status": status]) ?? ""
            expect(text != "error" && !text.contains("HTTP \(status)"), "UI invalid numeric status cannot fabricate HTTP code")
        }
    }
    @MainActor private static func settledRegistryAndReceipts() async throws {
        ReceiptSink.shared.reset()
        let transport = FixtureTransport()
        let session = VortxNativeSession(transport: transport)
        let updates = UpdateSink()
        let value = try await session.loadMeta(request: meta, stream: stream, addons: registry, onUpdate: { updates.append($0) })
        let metas = value["metaItems"]?.array ?? [], streams = value["streams"]?.array ?? []
        expect(metas.count == 38 && streams.count == 38, "all 38 registry rows retained for both resource legs")
        expect(zip(streams, registry).allSatisfy { $0.0["request"]?["base"] == .string($0.1.transportUrl) }, "stream rows retain registry order despite concurrent completion")
        expect(zip(metas, registry).allSatisfy { $0.0["request"]?["base"] == .string($0.1.transportUrl) }, "metadata rows retain registry order despite concurrent completion")
        expect(updates.snapshots().allSatisfy { snapshot in
            ["metaItems", "streams"].allSatisfy { key in
                let rows = snapshot[key]?.array ?? []
                return rows.count == 38 && zip(rows, registry).allSatisfy { $0.0["request"]?["base"] == .string($0.1.transportUrl) }
            }
        }, "every interim publication preserves all 38 exact registry positions")
        expect(streams[0]["content"]?["type"] == .string("Ready") && streams[0]["content"]?["content"]?.array?.count == 1, "ready stream is distinct from empty and error")
        expect(streams[1]["content"]?["type"] == .string("Ready") && streams[1]["content"]?["content"]?.array?.isEmpty == true, "empty stream stays Ready empty rather than failure")
        expect(streams[2]["content"]?["type"] == .string("Err") && streams[2]["content"]?["content"]?["status"] == .integer(429), "failed stream stays Err with exact safe HTTP status")
        expect(streams[5]["content"]?["content"]?["code"] == .string("unavailable"), "thrown native unavailable retained instead of generic failure")
        expect(streams[7]["content"]?["content"]?["code"] == .string("invalid_response"), "thrown invalid response retained instead of generic failure")
        expect(streams[8]["content"]?["content"]?["code"] == .string("invalid_response"), "DecodingError reduces to safe invalid response")
        expect(streams[9]["content"]?["content"]?["code"] == .string("cancelled"), "per-leg CancellationError retains cancelled category")
        expect(streams[12]["content"]?["type"] == .string("Ready") && streams[12]["content"]?["content"]?.array?.isEmpty == true, "unsupported omitted singleton group settles to Ready empty")
        expect(streams[13]["content"]?["content"]?["code"] == .string("native_resource_failed"), "arbitrary NSError becomes controlled generic failure")
        expect(streams[14]["content"]?["content"]?["code"] == .string("native_resource_failed"), "missing failure object receives controlled generic category")
        expect((metas + streams).allSatisfy { $0["content"]?["type"] != .string("Loading") }, "no registry row remains Loading at settlement")
        expect(transport.count() == 76 && transport.observedBudgets().allSatisfy { $0 == 20_000 }, "every singleton leg receives own 20-second budget")
        let lines = ReceiptSink.shared.lines(), parsed = lines.map(fields)
        expect(lines.count == 76, "accepted terminal receipt emitted exactly once per meta and stream leg")
        let keys = parsed.map { ($0["resource"] ?? "") + ":" + ($0["source"] ?? "") }
        expect(Set(keys).count == 76 && parsed.filter { $0["resource"] == "meta" }.count == 38 && parsed.filter { $0["resource"] == "stream" }.count == 38, "receipt source ordinals cover each accepted resource leg exactly once")
        expect(parsed.allSatisfy { UUID(uuidString: $0["request"] ?? "") != nil } && Set(parsed.compactMap { $0["request"] }).count == 1, "receipt correlator is one opaque screen request UUID")
        expect(parsed.contains { $0["resource"] == "stream" && $0["source"] == "1" && $0["result"] == "ready" && $0["items"] == "1" }, "ready receipt carries truthful item count")
        expect(parsed.contains { $0["resource"] == "stream" && $0["source"] == "2" && $0["result"] == "empty" && $0["items"] == "0" }, "empty receipt remains distinct from failed provider")
        expect(parsed.contains { $0["resource"] == "meta" && $0["source"] == "2" && $0["result"] == "empty" && $0["items"] == "0" }, "meta null emits a truthful empty receipt")
        expect(parsed.contains { $0["resource"] == "stream" && $0["source"] == "13" && $0["result"] == "empty" }, "omitted unsupported response emits one empty terminal receipt")
        expect(parsed.contains { $0["resource"] == "stream" && $0["source"] == "3" && $0["result"] == "error" && $0["code"] == "http" && $0["status"] == "429" }, "HTTP receipt retains safe category and status")
        expect(lines.allSatisfy { !$0.contains("synthetic-secret") && !$0.contains("source.invalid") && !$0.contains("apiKey") && !$0.contains("synthetic-owner") }, "receipts never expose transport configuration or owner identity")
    }
    @MainActor private static func staleCompletion(_ boundary: String) async throws {
        ReceiptSink.shared.reset()
        let transport = FixtureTransport(held: true, mixed: false, lateFailure: true)
        let session = VortxNativeSession(transport: transport)
        let updates = UpdateSink()
        let pending = Task { try await session.loadMeta(request: meta, stream: stream, addons: Array(registry.prefix(8)), onUpdate: { updates.append($0) }) }
        expect(await waitUntil { transport.count() >= 6 }, "\(boundary) fixture holds both meta and stream windows")
        if boundary == "cancellation" { pending.cancel() }
        else if boundary == "profile" { await session.changeProfile() }
        else if boundary == "configuration" { await session.changeConfiguration() }
        else if boundary == "lease" { await session.revokeLeaseOnly() }
        else { await session.retireAccount() }
        let incumbentUpdates = updates.snapshots().count
        transport.release()
        do { _ = try await pending.value; expect(false, "\(boundary) rejects retired operation") }
        catch { expect(true, "\(boundary) rejects retired operation") }
        expect(ReceiptSink.shared.lines().isEmpty, "\(boundary) late responses cannot emit accepted terminal receipts")
        expect(updates.snapshots().count == incumbentUpdates, "\(boundary) late success and error cannot publish after retirement")
    }
    @MainActor private static func metadataOnlyAndNoSources() async throws {
        ReceiptSink.shared.reset()
        let transport = FixtureTransport(mixed: false)
        let session = VortxNativeSession(transport: transport)
        let value = try await session.loadMeta(request: meta, stream: nil, addons: registry)
        let lines = ReceiptSink.shared.lines()
        expect(value["metaItems"]?.array?.count == 38 && value["streams"]?.array?.isEmpty == true, "meta-only request retains 38 metadata rows and no stream rows")
        expect(lines.count == 38 && lines.map(fields).allSatisfy { $0["resource"] == "meta" }, "meta-only request emits exactly 38 metadata receipts")
        ReceiptSink.shared.reset()
        let empty = try await session.loadMeta(request: meta, stream: stream, addons: [])
        expect(empty["metaItems"]?.array?.isEmpty == true && empty["streams"]?.array?.isEmpty == true && ReceiptSink.shared.lines().isEmpty, "zero-source request settles empty without invented receipts")
        let priorCalls = transport.count()
        do {
            _ = try await session.loadMeta(request: meta, stream: stream, addons: registry, expectedProfileID: "synthetic-wrong-profile")
            expect(false, "expected-profile mismatch rejected before transport")
        } catch { expect(ReceiptSink.shared.lines().isEmpty && transport.count() == priorCalls, "expected-profile mismatch rejected before transport") }
    }
    @MainActor private static func newOwnerCompletion() async throws {
        ReceiptSink.shared.reset()
        let transport = FixtureTransport(held: true, mixed: false)
        let session = VortxNativeSession(transport: transport)
        let old = Task { try await session.loadMeta(request: meta, stream: stream, addons: Array(registry.prefix(8))) }
        expect(await waitUntil { transport.count() >= 6 }, "replacement fixture holds incumbent requests")
        let replacement = Task { try await session.loadMeta(request: meta, stream: stream, addons: Array(registry.prefix(2))) }
        expect(await waitUntil { transport.count() >= 10 }, "new screen owner begins before old completions")
        transport.release()
        do { _ = try await old.value; expect(false, "replacement rejects incumbent operation") }
        catch { expect(true, "replacement rejects incumbent operation") }
        let value = try await replacement.value
        expect(value["streams"]?.array?.count == 2, "replacement owns its exact two-source presentation")
        let lines = ReceiptSink.shared.lines(), parsed = lines.map(fields)
        expect(lines.count == 4 && Set(parsed.compactMap { $0["request"] }).count == 1, "only replacement emits its four accepted terminal receipts")
    }
    @MainActor static func main() async {
        do {
            try dtoProjectionAndFormatter()
            try await settledRegistryAndReceipts()
            try await metadataOnlyAndNoSources()
            for boundary in ["cancellation", "profile", "configuration", "lease", "account"] { try await staleCompletion(boundary) }
            try await newOwnerCompletion()
        } catch { expect(false, "fixture finished without unexpected error") }
        print("Native addon error receipt checks=\(checks) failures=\(failures)")
        if failures > 0 { exit(1) }
    }
}
