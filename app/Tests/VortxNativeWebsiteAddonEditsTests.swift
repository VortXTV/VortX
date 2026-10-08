import Foundation
import CryptoKit

private final class ImportAuthority: VortxMutationAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    func invalidate() { lock.withLock { current = false } }
    func withActive(_ operation: () throws -> Void) throws {
        try lock.withLock { guard current else { throw VortxNativeError.superseded }; try operation() }
    }
}

private final class ImportCommitGate: VortxMutationAuthority, @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false
    var isStarted: Bool { condition.withLock { started } }
    func release() { condition.withLock { released = true; condition.broadcast() } }
    func withActive(_ operation: () throws -> Void) throws {
        condition.lock(); started = true; condition.broadcast()
        while !released { condition.wait() }
        condition.unlock(); try operation()
    }
}

private final class AddonCheckpointStore: VortxCheckpointStore, @unchecked Sendable {
    let sealed: VortxEncryptedCheckpointStore
    private let lock = NSLock()
    private var failing = false
    init(_ sealed: VortxEncryptedCheckpointStore) { self.sealed = sealed }
    func fail() { lock.withLock { failing = true } }
    func read(scope: VortxAccountScope) throws -> String? { try sealed.read(scope: scope) }
    func readHostPreferences(scope: VortxAccountScope) throws -> Data? { try sealed.readHostPreferences(scope: scope) }
    func commit(_ state: String, scope: VortxAccountScope) throws { try sealed.commit(state, scope: scope) }
    func commit(_ state: String, scope: VortxAccountScope, hostPreferences: Data) throws {
        if lock.withLock({ failing }) { throw VortxNativeError.unavailable }
        try sealed.commit(state, scope: scope, hostPreferences: hostPreferences)
    }
}

@main enum VortxNativeWebsiteAddonEditsTests {
    static let scope = VortxAccountScope(account: "account.website-addon-fixture", ownerProfileID: "00000000-0000-0000-0000-00000000A11C")
    static let actor = "00000000-0000-0000-0000-000000000001"
    static let url = "https://fixture.invalid/Config/manifest.json"
    static let otherURL = "https://fixture.invalid/Other/manifest.json"
    static let empty: VortxJSON = .object(["records": .object([:]), "order": .object(["ids": .array([]), "updatedAt": .integer(0)])])
    static let binding: VortxJSON = .object(["account": .object(["kind": .string("local_only")]), "revision": .integer(0), "transactionId": .null])
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "website addon fixture line \(line)") }
    static func raw(_ value: VortxJSON) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func json(_ value: String) throws -> VortxJSON { try JSONDecoder().decode(VortxJSON.self, from: Data(value.utf8)) }
    static func replacing(_ value: VortxJSON, _ key: String, _ replacement: VortxJSON) -> VortxJSON {
        guard case .object(var fields) = value else { fatalError("fixture object") }; fields[key] = replacement; return .object(fields)
    }
    static func mutation(_ url: String, present: Bool = true) -> VortxJSON {
        var fields: [String: VortxJSON] = ["transportUrl": .string(url), "state": .string(present ? "present" : "removed")]
        if present {
            fields["addon"] = .object(["transportUrl": .string(url), "flags": .object([:]),
                "manifest": .object(["id": .string(url), "name": .string("Fixture"), "version": .string("1.0.0"),
                    "catalogs": .array([]), "resources": .array([]), "types": .array([]),
                    "extension": .object(["😀": .integer(1), "\u{e000}": .number(1e-7)])])])
        }
        return .object(fields)
    }
    static func event(_ id: Int, observed: VortxJSON = empty, mutations: [VortxJSON]? = nil, order: [String]? = nil) -> VortxJSON {
        var fields: [String: VortxJSON] = ["schemaVersion": .integer(1), "eventId": .string(String(format: "%032x", id)),
            "counter": .string(String(id)), "wallTime": .integer(1_000_000), "scope": .string(scope.account),
            "ownerProfileId": .string(scope.ownerProfileID), "profileId": .string(scope.ownerProfileID),
            "expectedBinding": binding, "observed": observed, "mutations": .array(mutations ?? [mutation(url)])]
        if let order { fields["order"] = .array(order.map(VortxJSON.string)) }; return .object(fields)
    }
    static func main() async throws {
        let first = event(1)
        let braceID = "e9" + String(repeating: "0", count: 30)
        let typedBrace = replacing(first, "eventId", .string(braceID))
        try VortxNativeWebsiteAddonEdits.validateSource([typedBrace])
        do {
            try VortxNativeWebsiteAddonEdits.validateSource([.object(["eventId": .string(braceID)])])
            fatalError("untyped event identifier bypassed opaque inspection")
        } catch VortxNativeBootstrapArchive.Failure.opaquePreference {}
        do {
            let credentialCarrier = Data("{\"authKey\":\"synthetic-token\"}".utf8).base64EncodedString()
            let sourceMutation = mutation(url)
            let sourceAddon = sourceMutation["addon"]!
            let credentialAddon = replacing(sourceAddon, "manifest", replacing(sourceAddon["manifest"]!, "opaque", .string(credentialCarrier)))
            let credentialMutation = replacing(sourceMutation, "addon", credentialAddon)
            try VortxNativeWebsiteAddonEdits.validateSource([replacing(typedBrace, "mutations", .array([credentialMutation]))])
            fatalError("typed eventId bypassed sibling credential inspection")
        } catch VortxNativeError.invalidSnapshot {}
        let carrier: VortxJSON = .object(["schemaVersion": .integer(1), "events": .array([first, event(2)])])
        check(try VortxNativeWebsiteAddonEdits.events(carrier) == [first, event(2)])
        do {
            _ = try VortxNativeWebsiteAddonEdits.events(replacing(carrier, "events", .array([first, first])))
            fatalError("duplicate incoming event IDs admitted")
        } catch VortxNativeError.invalidSnapshot {}
        let future = replacing(carrier, "schemaVersion", .integer(2))
        check(try VortxNativeWebsiteAddonEdits.events(future) == [future])
        check(try VortxNativeWebsiteAddonEdits.events(nil).isEmpty)
        do { try VortxNativeWebsiteAddonEdits.validateSource(Array(repeating: first, count: 129)); fatalError("unbounded queue admitted") }
        catch VortxNativeError.invalidSnapshot {}
        do {
            try VortxNativeWebsiteAddonEdits.validateSource([replacing(first, "extension", .string(String(repeating: "x", count: VortxNativeWebsiteAddonEdits.maximumBytes)))])
            fatalError("oversized carrier admitted")
        } catch VortxNativeError.invalidSnapshot {}
        check(VortxNativeWebsiteAddonEdits.memberKey(" HTTPS://User:Pass@FiXtUrE.invalid:443/Config/%2F?Token=AbC#Keep ")
            == "https://User:Pass@fixture.invalid:443/Config/%2F?Token=AbC#Keep")
        check(VortxNativeWebsiteAddonEdits.memberKey("HTTPS://ÉXAMPLE.invalid/Case") == "https://Éxample.invalid/Case")
        var host = try VortxNativeHostPreferences(scope: scope, actor: actor)
        host.local.websiteAddonPending = [first, future]
        let reopened = try VortxNativeHostPreferences(scope: scope, actor: actor, sealed: host.encoded())
        check(reopened.local.websiteAddonPending == [first, future])
        check(try reopened.document["websiteAddonPending"] == nil)
        let fingerprint = String(repeating: "a", count: 64)
        let receipt: VortxJSON = .object(["schemaVersion": .integer(1), "eventId": first["eventId"]!, "counter": first["counter"]!,
            "fingerprint": .string(fingerprint), "scope": .string(scope.account), "ownerProfileId": .string(scope.ownerProfileID),
            "profileId": .string(scope.ownerProfileID), "expectedBinding": binding])
        let result: VortxJSON = .object(["ok": .bool(true), "events": .array([.object(["event": .string("website_addon_edits_applied"), "receipt": receipt])])])
        let state: VortxJSON = .object(["nativeSync": .object(["schemaVersion": .integer(5), "websiteAddonReceipts": .object([String(format: "%032x", 1): receipt])])])
        check(try VortxNativeWebsiteAddonEdits.validatedReceipt(event: first, result: result, state: state, scope: scope).fingerprint == fingerprint)
        do {
            _ = try VortxNativeWebsiteAddonEdits.validatedReceipt(event: replacing(first, "counter", .string("2")), result: result, state: state, scope: scope)
            fatalError("receipt admitted for wrong event counter")
        } catch VortxNativeError.invalidResponse {}
        do {
            _ = try VortxNativeWebsiteAddonEdits.validatedReceipt(event: first, result: result, state: .object([:]), scope: scope)
            fatalError("receipt absent from state admitted")
        } catch VortxNativeError.invalidResponse {}
        print("Website add-on carrier preservation, separate sealed journal and exact receipt linkage passed")
        try await explicitImportFetch()
#if VORTX_ENGINE_STATE_BRIDGE
        try await live(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
#endif
    }

    static func explicitImportFetch() async throws {
        let owner = UserProfile(id: UUID(uuidString: scope.ownerProfileID)!, name: "Owner", avatar: "O", isOwner: true)
        let descriptor = mutation(url)["addon"]!
        let response = AuthenticatedHTTPResponse(data: try JSONEncoder().encode(VortxJSON.object(["result": .object(["addons": .array([descriptor])])])), statusCode: 200)
        let authority = ImportAuthority()
        let imported = try await VortxNativeOwnerAddonImport.fetch(authKey: "synthetic-token", verifiedUID: "verified-fixture-uid", owner: owner, authority: authority, send: { request in
            check(request.url?.absoluteString == "https://api.strem.io/api/addonCollectionGet" && request.httpMethod == "POST")
            let body = try JSONDecoder().decode(VortxJSON.self, from: request.httpBody!)
            check(body["update"] == .bool(false) && body["authKey"] == .string("synthetic-token"))
            return response
        })
        check(imported == [descriptor])
        do {
            _ = try await VortxNativeOwnerAddonImport.fetch(authKey: "synthetic-token", verifiedUID: "verified-fixture-uid", owner: owner, authority: authority, send: { _ in
                authority.invalidate(); return response
            })
            fatalError("late fetch crossed retired credential generation")
        } catch VortxNativeError.superseded {}
        do {
            _ = try await VortxNativeOwnerAddonImport.fetch(authKey: "synthetic-token", verifiedUID: "verified-fixture-uid", owner: owner, authority: ImportAuthority(), send: { _ in
                AuthenticatedHTTPResponse(data: Data("{\"result\":{}}".utf8), statusCode: 200)
            })
            fatalError("missing addons accepted as empty success")
        } catch VortxNativeError.invalidResponse {}
        print("Explicit owner import authenticated endpoint, unchanged descriptor projection, stale fetch and malformed response boundaries passed")
    }

#if VORTX_ENGINE_STATE_BRIDGE
    static func live(directory: URL) async throws {
        let store = AddonCheckpointStore(try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256)))
        let session = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), allowNewAccount: true, hostActor: actor)
        let initial = try json(await session.stateJSON())
        let first = event(1, observed: initial["nativeSync"]?["addons"]?[scope.ownerProfileID] ?? empty)
        _ = try await session.dispatch([], now: 1000, websiteAddonEvents: [first])
        let installed = try json(await session.stateJSON())
        check(installed["nativeSync"]?["schemaVersion"] == .integer(5))
        check(try await session.resourceRegistry().map(\.transportUrl) == [url])
        check(try await session.websiteEditOutcome()["addonConflicts"] == .array([]))
        let receipt = installed["nativeSync"]?["websiteAddonReceipts"]?[String(format: "%032x", 1)]
        check(receipt != nil)
        let expectedFingerprint = SHA256.hash(data: Data(("vortx.website-addon.v1\n" + (try VortxNativeProfileEditHost.canonicalJSON(first))).utf8))
            .map { String(format: "%02x", $0) }.joined()
        check(receipt?["fingerprint"] == .string(expectedFingerprint))
        // Concurrent native removal wins; replay must only acknowledge the immutable event.
        _ = try await session.dispatch([raw(.object(["type": .string("remove_addon"), "profileId": .string(scope.ownerProfileID), "transportUrl": .string(url)]))], now: 1001)
        let removed = try json(await session.stateJSON())
        _ = try await session.dispatch([], now: 1002, websiteAddonEvents: [first])
        check(try json(await session.stateJSON()) == removed)
        check(try await session.resourceRegistry().isEmpty)
        check(try await session.websiteEditOutcome()["addonConflicts"]?.array?.first?["code"] == .string("native_addon_state_changed"))
        let local = try JSONDecoder().decode(VortxNativeHostPreferences.Local.self, from: store.readHostPreferences(scope: scope)!)
        check(local.websiteAddonPending == [] && local.websiteAddonConflicts?.isEmpty == false)
        await session.close()
        let cold = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), hostActor: actor)
        _ = try await cold.dispatch([], now: 1003)
        check(try json(await cold.stateJSON()) == removed)
        let observed = removed["nativeSync"]?["addons"]?[scope.ownerProfileID] ?? empty
        let reinstall = event(2, observed: observed, mutations: [mutation(url), mutation(otherURL)], order: [otherURL, url])
        let wrongScope = replacing(event(3, observed: observed), "scope", .string("account.foreign"))
        let unknown = replacing(event(4, observed: observed), "schemaVersion", .integer(2))
        let wrongBinding = replacing(event(5, observed: observed), "expectedBinding", replacing(binding, "revision", .integer(1)))
        _ = try await cold.dispatch([], now: 1004, websiteAddonEvents: [wrongScope, unknown, wrongBinding, reinstall])
        check(try await cold.resourceRegistry().map(\.transportUrl) == [otherURL, url])
        let good = try json(await cold.stateJSON())
        check(good["nativeSync"]?["websiteAddonReceipts"]?[String(format: "%032x", 2)] != nil)
        for id in 3...5 { check(good["nativeSync"]?["websiteAddonReceipts"]?[String(format: "%032x", id)] == nil) }
        let altered = replacing(reinstall, "counter", .string("200"))
        _ = try await cold.dispatch([], now: 1005, websiteAddonEvents: [altered])
        check(try json(await cold.stateJSON()) == good)
        let retired = ImportAuthority(); retired.invalidate()
        do {
            _ = try await cold.dispatch([], now: 1005, websiteAddonEvents: [event(7, observed: good["nativeSync"]!["addons"]![scope.ownerProfileID]!, mutations: [mutation(otherURL, present: false)])], sourceAuthority: retired)
            fatalError("stale source committed")
        } catch VortxNativeError.superseded {}
        check(try json(await cold.stateJSON()) == good)
        let stable = try await cold.stateJSON(), stableHost = try store.readHostPreferences(scope: scope)
        store.fail()
        do {
            _ = try await cold.dispatch([], now: 1006, websiteAddonEvents: [event(6, observed: good["nativeSync"]!["addons"]![scope.ownerProfileID]!, mutations: [mutation(otherURL, present: false)])])
            fatalError("failed checkpoint published")
        } catch VortxNativeError.checkpointUncertain {}
        check(try await cold.stateJSON() == stable)
        check(try store.read(scope: scope) == stable && store.readHostPreferences(scope: scope) == stableHost)
        await cold.close()
        try await explicitImportBatch(directory: directory.appendingPathComponent("explicit-import"))
        try await eventQueueReplay(directory: directory.appendingPathComponent("peer-replay"))
        try await legacyV3Bootstrap(directory: directory.appendingPathComponent("legacy-v3"))
        print("Actual C ABI website add-ons: install/order, native-uninstall replay, encrypted cold pending, independent invalid events, altered-ID rejection and checkpoint rollback passed")
    }

    static func explicitImportBatch(directory: URL) async throws {
        let importScope = VortxAccountScope(account: "account.explicit-import-fixture", ownerProfileID: scope.ownerProfileID)
        let store = AddonCheckpointStore(try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256)))
        let session = try VortxNativeSession(scope: importScope, ownerName: "Owner", abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), allowNewAccount: true, hostActor: actor)
        let initial = try await session.stateJSON()
        let concurrent = try VortxNativeRuntime(abi: VortxCABI(), snapshot: initial)
        let tiedURL = "https://fixture.invalid/tied/manifest.json"
        _ = try concurrent.dispatch(raw(.object(["type": .string("install_addon"), "profileId": .string(scope.ownerProfileID), "addon": mutation(tiedURL)["addon"]!])), now: 0)
        let nativeTie = try json(concurrent.stateJSON())["nativeSync"]!
        concurrent.close()
        let webRemoval = replacing(event(10, mutations: [mutation(tiedURL, present: false)]), "scope", .string(importScope.account))
        _ = try await session.dispatch([], now: 1000, websiteAddonEvents: [webRemoval])
        _ = try await session.dispatch([raw(.object(["type": .string("merge_native_sync"), "document": nativeTie]))], now: 1000)
        let tied = try json(await session.stateJSON())["nativeSync"]!["addons"]![scope.ownerProfileID]!["records"]![tiedURL]!
        check(tied["addedAt"] == tied["removedAt"])
        check(try await session.resourceRegistry().map(\.transportUrl) == [tiedURL])
        let unrelated = "https://fixture.invalid/unrelated/manifest.json"
        let protected = replacing(mutation(unrelated)["addon"]!, "flags", .object(["official": .bool(true), "protected": .bool(true)]))
        _ = try await session.dispatch([raw(.object(["type": .string("install_addon"), "profileId": .string(scope.ownerProfileID), "addon": protected])),
            raw(.object(["type": .string("install_addon"), "profileId": .string(scope.ownerProfileID), "addon": mutation(url)["addon"]!])),
            raw(.object(["type": .string("remove_addon"), "profileId": .string(scope.ownerProfileID), "transportUrl": .string(url)])),
            raw(.object(["type": .string("patch_profile"), "id": .string(scope.ownerProfileID), "edits": .array([.object(["field": .string("disabledAddons"), "value": .array([.string(unrelated)])])])]))], now: 1000)
        // Reproduces the old split: native membership has a removal even though the authenticated
        // API fetch returns this descriptor. Only the explicit import transaction may reinstate it.
        let before = try await session.addonSnapshot()
        check(before.inventories[scope.ownerProfileID]?.map { $0["transportUrl"]! } == [.string(tiedURL), .string(unrelated)])
        check(try await session.resourceRegistry().map(\.transportUrl) == [tiedURL])
        let facade = try await VortxNativeCoreFacade.create(session: session, registry: session.resourceRegistry(), changed: { _ in })
        let duplicate: VortxJSON = .object(["action": .string("Ctx"), "args": .object(["action": .string("InstallAddonLocal"), "args": mutation(tiedURL)["addon"]!])])
        check(!facade.dispatch(data: try JSONEncoder().encode(duplicate), field: "ctx"))
        try await facade.importOwnerAddons([mutation(url)["addon"]!, mutation(otherURL)["addon"]!], expectedProfileID: scope.ownerProfileID,
            expectedAccountGeneration: facade.accountGeneration, sourceAuthority: ImportAuthority())
        let after = try await session.addonSnapshot()
        check(after.inventories[scope.ownerProfileID]?.map { $0["transportUrl"]! } == [.string(tiedURL), .string(unrelated), .string(url), .string(otherURL)])
        check(after.inventories[scope.ownerProfileID]?[1]["flags"]?["protected"] == .bool(true))
        check(try await session.resourceRegistry().map(\.transportUrl) == [tiedURL, url, otherURL])
        let current = try await session.stateJSON()
        let revoked = ImportAuthority(); revoked.invalidate()
        do {
            try await facade.importOwnerAddons([mutation("https://fixture.invalid/stale/manifest.json")["addon"]!], expectedProfileID: scope.ownerProfileID,
                expectedAccountGeneration: facade.accountGeneration, sourceAuthority: revoked)
            fatalError("retired explicit import accepted")
        } catch VortxNativeError.superseded {}
        check(try await session.stateJSON() == current)
        let checkpointBeforeCancellation = try store.read(scope: importScope)
        let hostBeforeCancellation = try store.readHostPreferences(scope: importScope)
        let gate = ImportCommitGate()
        let cancelledImport = Task {
            try await facade.importOwnerAddons([mutation("https://fixture.invalid/cancelled/manifest.json")["addon"]!], expectedProfileID: scope.ownerProfileID,
                expectedAccountGeneration: facade.accountGeneration, sourceAuthority: gate)
        }
        // This gate is entered by the facade's unstructured FIFO task, not the calling task.
        // Cancel the original operation before releasing its final source-authority checkpoint.
        while !gate.isStarted { await Task.yield() }
        cancelledImport.cancel(); gate.release()
        do { try await cancelledImport.value; fatalError("cancelled caller's import committed") }
        catch VortxNativeError.superseded {}
        check(try await session.stateJSON() == current)
        check(try store.read(scope: importScope) == checkpointBeforeCancellation && store.readHostPreferences(scope: importScope) == hostBeforeCancellation)
        await facade.shutdown()
        print("Actual C ABI explicit owner import: removed member reinstated, schema5 native winner, protected/disabled order, stale-source and caller-cancellation checkpoint rollback passed")
    }

    static func eventQueueReplay(directory: URL) async throws {
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256))
        let session = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), allowNewAccount: true, hostActor: actor)
        let peer = try VortxNativeRuntime(abi: VortxCABI(), snapshot: await session.stateJSON())
        let acknowledged = event(20)
        _ = try peer.dispatch(raw(VortxNativeWebsiteAddonEdits.request(event: acknowledged, scope: scope)), now: 1000)
        _ = try peer.dispatch(raw(.object(["type": .string("remove_addon"), "profileId": .string(scope.ownerProfileID), "transportUrl": .string(url)])), now: 1001)
        let remote = try json(peer.stateJSON())["nativeSync"]!; peer.close()
        _ = try await session.dispatch([raw(.object(["type": .string("merge_native_sync"), "document": remote]))], now: 1002)
        let merged = try await session.stateJSON()
        var host = try VortxNativeHostPreferences(scope: scope, actor: actor, sealed: store.readHostPreferences(scope: scope))
        check(host.local.websiteAddonReceipts?[String(format: "%032x", 20)] == nil)
        host.local.websiteAddonPending = [acknowledged]
        // Synthetic sealed pending models a previous failed delivery; no host receipt is forged.
        await session.close()
        try store.commit(merged, scope: scope, hostPreferences: host.encoded())
        let cold = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), hostActor: actor)
        _ = try await cold.dispatch([], now: 1003)
        check(try await cold.stateJSON() == merged)
        check(try await cold.resourceRegistry().isEmpty)
        let replayed = try VortxNativeHostPreferences(scope: scope, actor: actor, sealed: store.readHostPreferences(scope: scope))
        check(replayed.local.websiteAddonPending == [] && replayed.local.websiteAddonReceipts?[String(format: "%032x", 20)] != nil)
        let wrong = replacing(event(21), "scope", .string("account.foreign"))
        _ = try await cold.dispatch([], now: 1004, websiteAddonEvents: [wrong])
        let aliasURL = "https://fixture.invalid/Alias/manifest.json"
        let aliasMutation = replacing(mutation(aliasURL), "addon", replacing(mutation(aliasURL)["addon"]!, "transportUrl", .string("HTTPS://FIXTURE.INVALID/Alias/manifest.json")))
        let alias = event(22, observed: remote["addons"]![scope.ownerProfileID]!, mutations: [aliasMutation], order: [aliasURL])
        _ = try await cold.dispatch([], now: 1005, websiteAddonEvents: [event(21), alias])
        let applied = try json(await cold.stateJSON())
        check(applied["nativeSync"]?["websiteAddonReceipts"]?[String(format: "%032x", 21)] == nil)
        check(applied["nativeSync"]?["websiteAddonReceipts"]?[String(format: "%032x", 22)] != nil)
        let journal = try VortxNativeHostPreferences(scope: scope, actor: actor, sealed: store.readHostPreferences(scope: scope))
        check(journal.local.websiteAddonPending == [wrong, event(21)])
        check(journal.local.websiteAddonConflicts?.contains(where: { $0.eventId == String(format: "%032x", 22) }) == false)
        let stable = try await cold.stateJSON(), stableHost = try store.readHostPreferences(scope: scope)
        do {
            _ = try await cold.dispatch([], now: 1006, websiteAddonEvents: [event(23), replacing(event(23), "counter", .string("24"))])
            fatalError("duplicate incoming IDs mutated state")
        } catch VortxNativeError.invalidSnapshot {}
        check(try await cold.stateJSON() == stable && store.readHostPreferences(scope: scope) == stableHost)
        _ = try await cold.dispatch([], now: 1007)
        check(try await cold.stateJSON() == stable)
        await cold.close()
        print("Actual C ABI peer receipt cold replay, sealed collision quarantine, independent alias identity/order and duplicate-carrier rollback passed")
    }
    static func legacyV3Bootstrap(directory: URL) async throws {
        let owner = UserProfile(id: UUID(uuidString: scope.ownerProfileID)!, name: "Owner", avatar: "O", isOwner: true)
        let v3: VortxJSON = .object(["version": .integer(3), "counter": .string("5"), "eventId": .string(String(repeating: "a", count: 32)),
            "state": .string("removed"), "wallTime": .number(1000.25), "legacyAddedSeen": .integer(1000), "legacyRemovedSeen": .integer(500)])
        let document = try JSONEncoder().encode(VortxJSON.object(["vortx": .object(["addons": .array([mutation(url)["addon"]!]),
            "deletedAddonsTs": .object([url: .object(["addedAt": .integer(1000), "removedAt": .integer(500), "intentV3": v3])])])]))
        let material = try VortxLegacyBootstrapMaterial.encode(document: document, roster: [owner], ownerProfileID: owner.id, rosterModifiedSeconds: nil)
        let archive = try VortxNativeBootstrapArchive.encode(document: document, material: material)
        let v3Scope = VortxAccountScope(account: "account.v3-bootstrap-fixture", ownerProfileID: owner.id.uuidString)
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256), bootstrap: archive, bootstrapScope: v3Scope)
        let action: VortxJSON = .object(["type": .string("import_legacy_sync"), "scope": .string(v3Scope.account), "ownerProfileId": .string(v3Scope.ownerProfileID),
                                       "material": try JSONDecoder().decode(VortxJSON.self, from: material)])
        let session = try VortxNativeSession(scope: v3Scope, ownerName: "Owner", abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), allowNewAccount: true, initialActions: [raw(action)], hostActor: actor)
        let state = try json(await session.stateJSON())
        check(state["nativeSync"]?["schemaVersion"] == .integer(5))
        check(try await session.resourceRegistry().isEmpty)
        check(state["nativeSync"]?["legacyImport"]?["baseline"]?["addons"]?[owner.id.uuidString]?["intents"]?.array?.first?["intentV3"] == v3)
        let retained = try JSONDecoder().decode(VortxJSON.self, from: store.readLegacyMaterial(scope: v3Scope)!)
        check(try retained == JSONDecoder().decode(VortxJSON.self, from: material))
        await session.close()
        let cold = try VortxNativeSession(scope: v3Scope, ownerName: "Owner", abi: VortxCABI(), store: store, transport: VortxCResourceTransport(), hostActor: actor)
        check(try json(await cold.stateJSON()) == state)
        await cold.close()
        print("Actual C ABI typed legacy intentV3: authoritative removal, exact retained baseline/material and schema5 encrypted cold restart passed")
    }
#endif
}
