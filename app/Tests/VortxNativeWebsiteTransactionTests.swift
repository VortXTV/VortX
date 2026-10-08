import Foundation
import CryptoKit

private final class WebsiteStore: VortxCheckpointStore, @unchecked Sendable {
    let store: VortxEncryptedCheckpointStore
    private let lock = NSLock()
    private var failing = false
    init(_ store: VortxEncryptedCheckpointStore) { self.store = store }
    func failNext() { lock.withLock { failing = true } }
    func read(scope: VortxAccountScope) throws -> String? { try store.read(scope: scope) }
    func readHostPreferences(scope: VortxAccountScope) throws -> Data? { try store.readHostPreferences(scope: scope) }
    func commit(_ state: String, scope: VortxAccountScope) throws { try store.commit(state, scope: scope) }
    func commit(_ state: String, scope: VortxAccountScope, hostPreferences: Data) throws {
        if lock.withLock({ failing }) { throw VortxNativeError.unavailable }
        try store.commit(state, scope: scope, hostPreferences: hostPreferences)
    }
}

@main struct VortxNativeWebsiteTransactionTests {
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "website transaction fixture line \(line)") }
    static func json(_ value: String) throws -> VortxJSON { try JSONDecoder().decode(VortxJSON.self, from: Data(value.utf8)) }
    static func raw(_ value: VortxJSON) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func main() async throws {
        let owner = "00000000-0000-0000-0000-00000000A11C"
        let scope = VortxAccountScope(account: "account.website-fixture", ownerProfileID: owner)
        let actor = "00000000-0000-0000-0000-000000000001"
        let eventID = "00000000-0000-4000-8000-000000000002"
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = WebsiteStore(try VortxEncryptedCheckpointStore(directory: directory, key: SymmetricKey(size: .bits256)))
        let base = try json(#"{"audioLang":"eng","subtitleLang":"hin","forcedPolicy":"forced","subFont":"system","subSize":"medium","subColor":"white","subBackground":"none"}"#)
        let baseline = [owner: ["avatar": VortxJSON.string("🍿"), "playback": base]]
        let session = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), allowNewAccount: true, hostActor: actor)
        func event(_ id: String, _ milliseconds: Int64, _ name: String, host: Bool = false) throws -> VortxJSON {
            var row: [String: VortxJSON] = ["id": .string(owner), "name": .string(name)]
            var fields: [String: VortxJSON] = ["eventId": .string(id), "editedAt": .integer(milliseconds),
                "observedNativeClock": .integer(1000), "roster": .array([]), "libraryAdds": .object([:])]
            if host {
                row["settings"] = .object(["playback": .object(["audioLang": .string("fr")])])
                fields["observedHostClock"] = .integer(0)
                fields["hostBases"] = .object([owner: .object(["playback": .object(["absent": .bool(true), "valueHash": .string(try VortxNativeProfileEditHost.valueHash(base))])])])
            }
            fields["roster"] = .array([.object(row)]); return .object(fields)
        }
        let first = try event(eventID, 1_000_001, "Web name", host: true)
        _ = try await session.dispatch([#"{"type":"get_state"}"#], now: 5000, websiteEvents: [first], websiteBaseline: baseline)
        let accepted = try json(await session.stateJSON())
        check(accepted["nativeSync"]?["schemaVersion"] == .integer(2))
        check(accepted["roster"]?["profiles"]?[owner]?["name"] == .string("Web name"))
        let host = try await session.hostPreferencesDocument()
        check(host["profiles"]?[owner]?["fields"]?["playback"]?["value"]?["audioLang"] == .string("fr"))
        check(host["profiles"]?[owner]?["fields"]?["playback"]?["value"]?["subtitleLang"] == .string("hin"))
        check(try await session.websiteEditOutcome()["conflicts"] == .array([]))
        guard case .object(let receipts) = accepted["nativeSync"]?["legacyProfileEditReceipts"] else { fatalError("missing atomic receipt") }
        check(receipts.count == 1 && receipts.values.first?["eventId"] == .string(eventID))
        let rejected = try event("00000000-0000-4000-8000-000000000003", 1_000_002, "Must not commit", host: true)
        let independent = try event("00000000-0000-4000-8000-000000000004", 1_000_003, "Independent")
        _ = try await session.dispatch([#"{"type":"get_state"}"#], now: 9000, websiteEvents: [rejected, independent], websiteBaseline: baseline)
        let after = try json(await session.stateJSON())
        check(after["roster"]?["profiles"]?[owner]?["name"] == .string("Independent"))
        guard case .object(let nextReceipts) = after["nativeSync"]?["legacyProfileEditReceipts"] else { fatalError("receipt map") }
        check(nextReceipts.count == 2 && !nextReceipts.values.contains { $0["eventId"] == rejected["eventId"] })
        check(try await session.websiteEditOutcome()["conflicts"]?.array?.first?["code"] == .string("host_base_changed"))
        let sealed = try store.readHostPreferences(scope: scope)!
        let local = try JSONDecoder().decode(VortxNativeHostPreferences.Local.self, from: sealed)
        check(local.websitePending == [rejected])
        await session.close()
        let cold = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: VortxCABI(), store: store,
            transport: VortxCResourceTransport(), hostActor: actor)
        _ = try await cold.dispatch([#"{"type":"get_state"}"#], now: 10000, websiteEvents: [first], websiteBaseline: baseline)
        check(try json(await cold.stateJSON()) == after)
        check(try await cold.hostPreferencesDocument() == host)
        let beforeFailure = try await cold.stateJSON(), beforeHost = try store.readHostPreferences(scope: scope)
        store.failNext()
        do {
            _ = try await cold.dispatch([#"{"type":"get_state"}"#], now: 11000,
                websiteEvents: [event("00000000-0000-4000-8000-000000000005", 1_000_004, "Failed write")], websiteBaseline: baseline)
            fatalError("failed checkpoint accepted")
        } catch VortxNativeError.checkpointUncertain {}
        check(try store.read(scope: scope) == beforeFailure && store.readHostPreferences(scope: scope) == beforeHost)
        await cold.close()
        func coldPeer(_ suffix: String, carrier: VortxJSON?, event: VortxJSON = first, conflict: Bool) async throws {
            let peerStore = try VortxEncryptedCheckpointStore(directory: directory.appendingPathComponent(suffix), key: SymmetricKey(size: .bits256))
            let peer = try VortxNativeSession(scope: scope, ownerName: "Owner", abi: VortxCABI(), store: peerStore,
                transport: VortxCResourceTransport(), allowNewAccount: true, hostActor: actor)
            _ = try await peer.dispatch([raw(.object(["type": .string("merge_native_sync"), "document": after["nativeSync"]!]))],
                now: 11001, hostRemote: carrier, websiteEvents: [event], websiteBaseline: baseline)
            check(try await !(peer.websiteEditOutcome()["conflicts"]?.array ?? []).isEmpty == conflict)
            check(try json(await peer.stateJSON())["nativeSync"] == after["nativeSync"])
            if let carrier { check(try await peer.hostPreferencesDocument() == carrier) }
            await peer.close()
        }
        try await coldPeer("peer-exact", carrier: host, conflict: false)
        var laterHost = try VortxNativeHostPreferences(scope: scope, actor: actor)
        try laterHost.merge(host, scope: scope)
        try laterHost.edit(profileID: owner, fields: ["playback": .null], scope: scope)
        try await coldPeer("peer-newer-clear", carrier: laterHost.document, conflict: false)
        try await coldPeer("peer-missing-host", carrier: nil, conflict: true)
        guard case .object(var wrongHost) = host, case .object(var wrongProfiles) = host["profiles"],
              case .object(var wrongProfile) = wrongProfiles[owner], case .object(var wrongFields) = wrongProfile["fields"],
              case .object(var wrongRegister) = wrongFields["playback"], case .object(var wrongPlayback) = wrongRegister["value"] else { fatalError("fixture host") }
        wrongPlayback["audioLang"] = .string("de"); wrongRegister["value"] = .object(wrongPlayback)
        wrongFields["playback"] = .object(wrongRegister); wrongProfile["fields"] = .object(wrongFields)
        wrongProfiles[owner] = .object(wrongProfile); wrongHost["profiles"] = .object(wrongProfiles)
        try await coldPeer("peer-inconsistent-host", carrier: .object(wrongHost), conflict: true)
        let foreign = try event(eventID, 1_000_001, "Different immutable payload", host: true)
        try await coldPeer("peer-foreign-receipt", carrier: host, event: foreign, conflict: true)
        // A freshly authenticated legacy source reaches the kernel's original-bootstrap proof
        // path, without inventing observed clocks or prematurely applying the old UI aggregate.
        let profile = UserProfile(id: UUID(uuidString: owner)!, name: "Original", avatar: "🍿", isOwner: true)
        let aggregate = try json("{\"editedAt\":1000001,\"roster\":[{\"id\":\"\(owner)\",\"name\":\"Legacy web\"}]}")
        let aggregateObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(aggregate))
        let source = try JSONSerialization.data(withJSONObject: ["profileEdits": aggregateObject])
        let material = try VortxLegacyBootstrapMaterial.encode(document: source, roster: [profile], ownerProfileID: profile.id,
            rosterModifiedSeconds: 1000, deferProfileEdits: true)
        let archive = try VortxNativeBootstrapArchive.encode(document: source, material: material)
        let legacyScope = VortxAccountScope(account: "account.website-bootstrap", ownerProfileID: owner)
        let legacyStore = try VortxEncryptedCheckpointStore(directory: directory.appendingPathComponent("bootstrap"),
            key: SymmetricKey(size: .bits256), bootstrap: archive, bootstrapScope: legacyScope)
        let importAction = VortxJSON.object(["type": .string("import_legacy_sync"), "scope": .string(legacyScope.account),
            "ownerProfileId": .string(owner), "material": try JSONDecoder().decode(VortxJSON.self, from: material)])
        let legacy = try VortxNativeSession(scope: legacyScope, ownerName: profile.name, abi: VortxCABI(), store: legacyStore,
            transport: VortxCResourceTransport(), allowNewAccount: true, initialActions: [raw(importAction)], hostActor: actor)
        let legacyEvent = VortxJSON.object(["eventId": .string("legacy-aggregate-" + (try VortxNativeProfileEditHost.valueHash(aggregate))), "legacyAggregate": aggregate])
        _ = try await legacy.dispatch([#"{"type":"get_state"}"#], now: 12000, legacyMaterial: material, websiteEvents: [legacyEvent])
        check(try json(await legacy.stateJSON())["roster"]?["profiles"]?[owner]?["name"] == .string("Legacy web"))
        check(try await legacy.websiteEditOutcome()["conflicts"] == .array([]))
        _ = try await legacy.dispatch([#"{"type":"get_state"}"#], now: 13000, legacyMaterial: material, websiteEvents: [legacyEvent])
        check(try await legacy.websiteEditOutcome()["conflicts"] == .array([]))
        await legacy.close()
        print("Website actual C transaction: native+host+receipt atomicity, per-event conflict isolation, sealed pending, cold replay and write-failure rollback passed")
        print("Website original authenticated bootstrap aggregate: retained-source proof, native receipt and replay passed")
        print("Website cold peers: exact paired replay, newer explicit clear, missing/inconsistent pair and changed-event receipt rejection passed")
    }
}
