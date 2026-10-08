import Foundation
import CryptoKit

private final class SessionABI: VortxRuntimeABI, @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt = 0
    private var states: [UInt: String] = [:]
    func create(ownerID: String, ownerName: String) -> UInt {
        hydrate("{\"roster\":{\"profiles\":{\"\(ownerID)\":{\"id\":\"\(ownerID)\",\"owner\":true,\"deleted\":false},\"kid\":{\"id\":\"kid\",\"owner\":false}}},\"activeProfileId\":\"\(ownerID)\",\"libraries\":{\"kid\":{},\"\(ownerID)\":{\"watchContexts\":{\"episode\":{\"name\":\"Retain context\",\"durationMs\":1200001}}}}}")
    }
    func hydrate(_ snapshot: String) -> UInt {
        lock.lock(); defer { lock.unlock() }; next += 1; states[next] = snapshot; return next
    }
    func dispatch(_ handle: UInt, action: String, now: UInt64) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var state = try? JSONSerialization.jsonObject(with: Data(states[handle]!.utf8)) as? [String: Any],
              let action = try? JSONSerialization.jsonObject(with: Data(action.utf8)) as? [String: Any] else { return nil }
        if action["type"] as? String == "fail" { return "{\"ok\":false}" }
        if action["type"] as? String == "switch_profile" { state["activeProfileId"] = action["id"] }
        state["fixtureMutation"] = action["value"] ?? now
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) { states[handle] = String(decoding: data, as: UTF8.self) }
        return "{\"ok\":true}"
    }
    func resolve(_ handle: UInt, request: String) -> String? { request }
    func state(_ handle: UInt) -> String? { lock.lock(); defer { lock.unlock() }; return states[handle] }
    func delta(_ handle: UInt) -> String? { "{}" }
    func free(_ handle: UInt) { lock.lock(); defer { lock.unlock() }; precondition(states.removeValue(forKey: handle) != nil) }
}

private final class SessionStore: VortxCheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var failure = false
    private var installBeforeFailure = false
    private var block = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func blockNextWrite() { lock.lock(); block = true; lock.unlock() }
    func failWrites(afterInstall: Bool = false) { lock.lock(); failure = true; installBeforeFailure = afterInstall; lock.unlock() }
    func recover() { lock.lock(); failure = false; lock.unlock() }
    func read(scope: VortxAccountScope) throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
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
        input = .object(["kind": .string("resource_result"), "requestId": input["requestId"]!, "generation": input["generation"]!,
                         "request": input["request"]!, "groups": .array([]), "cancelled": .bool(false)])
        return String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
    }
}

@main enum VortxNativeSessionTests {
    static func check(_ value: Bool) { precondition(value) }
    static func main() async throws {
        let scope = VortxAccountScope(account: "account-a", ownerProfileID: "owner")
        let abi = SessionABI(), store = SessionStore(), transport = SessionTransport()
        let session = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: store, transport: transport, allowNewAccount: true)
        for _ in 0..<2 {
            do { _ = try VortxNativeSession(scope: scope, ownerName: "Other", abi: abi, store: SessionStore(), transport: transport, allowNewAccount: true); fatalError("overlapping account writer admitted") }
            catch VortxNativeError.unavailable {}
        }
        let before = try await session.stateJSON()
        do { _ = try await session.dispatch(["{\"type\":\"fail\"}"], now: 2); fatalError("invalid action accepted") }
        catch VortxNativeError.invalidResponse {}
        store.failWrites()
        do { _ = try await session.dispatch(["{\"type\":\"edit\",\"value\":42}"], now: 2); fatalError("unacknowledged state published") }
        catch VortxNativeError.checkpointUncertain {}
        check(try await session.stateJSON() == before)
        do { _ = try await session.dispatch(["{\"type\":\"edit\"}"], now: 3); fatalError("uncertain checkpoint overwritten") }
        catch VortxNativeError.checkpointUncertain {}
        let slow = Task { try await session.loadMeta(request: .init(resource: .meta, type: "series", id: "slow"), stream: nil, addons: []) }
        await withCheckedContinuation { done in DispatchQueue.global().async { precondition(transport.entered.wait(timeout: .now() + 5) == .success); done.resume() } }
        _ = try await session.loadCatalog(.search, request: .init(resource: .catalog, type: "series", id: "popular"), addons: [])
        if case .loading = await session.screen("meta_details") {} else { fatalError("search clobbered meta slot") }
        await session.close(); transport.release.signal()
        do { _ = try await slow.value; fatalError("closed owner published") } catch VortxNativeError.superseded {}
        check(await session.screen("meta_details") == nil)

        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("sealed")
        let key = SymmetricKey(size: .bits256)
        let encrypted = try VortxEncryptedCheckpointStore(directory: directory, key: key)
        try encrypted.commit(before, scope: scope)
        check(try encrypted.read(scope: scope) == before)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        precondition(files.count == 1)
        let bytes = try Data(contentsOf: files[0])
        precondition(bytes.range(of: Data("Retain context".utf8)) == nil)
        let wrongKey = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256))
        do { _ = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: wrongKey, transport: transport, allowNewAccount: true); fatalError("decrypt failure seeded empty owner") }
        catch {}
        let restarted = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: encrypted, transport: transport)
        check(try await restarted.stateJSON() == before)
        await restarted.close()
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
        let transitionStore = SessionStore()
        let transitionSession = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: abi, store: transitionStore, transport: transport, allowNewAccount: true)
        let facade = try await VortxNativeCoreFacade.create(session: transitionSession, registry: [], changed: { _ in })
        transitionStore.blockNextWrite()
        check(facade.dispatch(data: Data(#"{"action":"Vortx","args":{"type":"switch_profile","id":"kid"}}"#.utf8), field: nil))
        await withCheckedContinuation { done in DispatchQueue.global().async { precondition(transitionStore.entered.wait(timeout: .now() + 5) == .success); done.resume() } }
        check(!facade.dispatch(data: Data(#"{"action":"Ctx","args":{"action":"AddToLibrary","args":{"id":"tt-old","type":"movie","name":"Old"}}}"#.utf8), field: nil))
        check(facade.lastFailure == "profile_transition_pending")
        check(facade.dispatch(data: Data(#"{"action":"Vortx","args":{"type":"get_state"}}"#.utf8), field: nil))
        transitionStore.release.signal(); await facade.settled()
        let published = try JSONDecoder().decode(VortxJSON.self, from: facade.stateData("native_state")!)
        check(published["activeProfileId"] == .string("kid"))
        check(facade.registryBinding?.profileID == "kid")
        await facade.shutdown()
        print("Native session: acknowledged transactions, sealed cold state/context, legacy preservation and independent screen/logout fences passed")
    }
}
