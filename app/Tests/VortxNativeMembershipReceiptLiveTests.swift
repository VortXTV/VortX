import Foundation
import CryptoKit

/// Only synthetic account data crosses the real shipping C ABI in this fixture.
private final class MembershipCheckpointGate: VortxCheckpointStore, @unchecked Sendable {
    enum Failure: Error { case refused }
    let backing: VortxEncryptedCheckpointStore
    private let lock = NSLock()
    private var rejected = false
    private var override: Data?
    private var writes = 0
    init(_ backing: VortxEncryptedCheckpointStore, hostOverride: Data? = nil) {
        self.backing = backing; override = hostOverride
    }
    func rejectCommits() { lock.lock(); rejected = true; lock.unlock() }
    var commitCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    func read(scope: VortxAccountScope) throws -> String? { try backing.read(scope: scope) }
    func readHostPreferences(scope: VortxAccountScope) throws -> Data? {
        lock.lock(); let value = override; lock.unlock()
        return try value ?? backing.readHostPreferences(scope: scope)
    }
    func readLegacyMaterial(scope: VortxAccountScope) throws -> Data? { try backing.readLegacyMaterial(scope: scope) }
    func readLegacyProfileEdits(scope: VortxAccountScope) throws -> VortxJSON? { try backing.readLegacyProfileEdits(scope: scope) }
    private func authorize() throws {
        lock.lock(); defer { lock.unlock() }
        if rejected { throw Failure.refused }; writes += 1
    }
    func commit(_ snapshot: String, scope: VortxAccountScope) throws {
        try authorize(); try backing.commit(snapshot, scope: scope)
    }
    func commit(_ snapshot: String, scope: VortxAccountScope, hostPreferences: Data) throws {
        try authorize(); try backing.commit(snapshot, scope: scope, hostPreferences: hostPreferences)
    }
}

@main enum VortxNativeMembershipReceiptLiveTests {
    typealias Object = [String: Any]
    static let owner = UserProfile(id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!, name: "Receipt Owner", avatar: "O", isOwner: true)
    static let shared = UserProfile(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, name: "Receipt Shared", avatar: "S")
    static let orphan = "https://synthetic-orphan.invalid/Configured/manifest.json"
    static let scope = VortxAccountScope(account: "account.membership-receipt-fixture", ownerProfileID: owner.id.uuidString)
    static func check(_ value: Bool, _ message: String, line: UInt = #line) {
        precondition(value, "Membership receipt fixture line \(line): \(message)")
    }
    static func bytes(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func typed(_ data: Data) throws -> VortxJSON { try JSONDecoder().decode(VortxJSON.self, from: data) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func movie(_ id: String, position: Double = 0) -> Object {
        ["id": id, "type": "movie", "name": "Synthetic movie", "poster": "https://synthetic.invalid/poster.jpg",
         "t": position, "d": 100, "lastWatched": "2026-01-01T00:00:00.123456Z"]
    }
    static func fixture() -> Object {
        var imdb = movie("tt111", position: 1); imdb["v"] = "same-exact-video"
        var history = movie("tmdb:222", position: 2); history["v"] = "same-exact-video"; history["eventEpochMs"] = 2000.125
        return ["webAddonRemovals": [orphan], "vortx": [
            "addons": [["transportUrl": "https://synthetic-present.invalid/manifest.json", "manifest": ["id": "present", "name": "Present", "version": "1.0.0"]]],
            "library": [imdb, movie("tt333", position: 3)],
            "deletedAddonsTs": [orphan: ["addedAt": 2000.75, "removedAt": 1000.125]],
            "deletedLibraryTs": ["untyped-absent": ["removedAt": 9000.875]], "deletedLibrary": ["untyped-absent"],
            "byProfile": [shared.id.uuidString: ["library": [movie("saved-only")]], owner.id.uuidString: ["ownerHistory": [history]]],
            "ownerWatched": ["original-intent": ["t": "tmdb:222", "v": "same-exact-video", "w": true, "u": 3000.75, "a": "actor"]]
        ]]
    }
    static func prepare(_ source: Data) throws -> VortxLegacyBootstrapMaterial.Preparation {
        try VortxLegacyBootstrapMaterial.prepare(document: source, roster: [owner, shared], ownerProfileID: owner.id,
            rosterModifiedSeconds: 1720000000.1234, accountID: scope.account)
    }
    static func archive(_ preparation: VortxLegacyBootstrapMaterial.Preparation, source: Data) throws -> Data {
        try VortxLegacyMembershipReceiptArchive.appending(preparation.pendingMembershipReceipts,
            to: VortxNativeBootstrapArchive.encode(document: bytes(["ownAccountSources": Object()])),
            scope: scope.account, ownerProfileID: scope.ownerProfileID, sourceDocumentSHA256: hash(source))
    }
    static func ledger(_ archive: Data) throws -> VortxJSON {
        guard let value = try typed(archive)["hostDocument"]?[VortxLegacyMembershipReceiptArchive.key] else { fatalError("missing ledger") }
        return value
    }
    static func ledger(_ session: VortxNativeSession) async throws -> VortxJSON {
        guard let archive = try await session.authenticatedSourceArchive() else { fatalError("missing archive") }
        return try ledger(archive)
    }
    static func raw(_ value: VortxJSON) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let original = fixture(), source = try bytes(original), preparation = try prepare(source), sourceArchive = try archive(preparation, source: source)
        check(preparation.pendingCount == 4, "all four unresolved categories retained")
        check(try bytes(original) == source, "pure preparation preserves the cloud carriers")
        let replay = try prepare(source)
        check(replay.material == preparation.material && replay.pendingMembershipReceipts == preparation.pendingMembershipReceipts, "deterministic preparation")
        let rows = try typed(preparation.pendingMembershipReceipts!).array!
        let kinds = Set(rows.compactMap { try? $0["kind"]?.decode(String.self) })
        check(kinds == ["addon_install", "library_removal", "profile_saved_overlay", "watch_identity_conflict"], "exact receipt categories")
        check(rows.allSatisfy { $0["sourceDocumentSha256"] == .string(hash(source)) }, "receipts bind exact source hash")
        let addonRow = rows.first { $0["kind"] == .string("addon_install") }!
        check(addonRow["receipt"] == (try typed(bytes(["deletedAddonsTs": [orphan: ["addedAt": 2000.75, "removedAt": 1000.125]], "deletedAddons": [String](), "webAddonRemovals": [orphan]]))), "orphan raw clocks remain exact")
        let savedRow = rows.first { $0["kind"] == .string("profile_saved_overlay") }!
        check(savedRow["receipt"] == (try typed(bytes(movie("saved-only")))) && savedRow["profileId"] == .string(shared.id.uuidString), "saved-only raw row and profile remain exact")
        let removalRow = rows.first { $0["kind"] == .string("library_removal") }!
        check(removalRow["receipt"] == (try typed(bytes(["deletedLibrary": ["untyped-absent"], "deletedLibraryTs": ["untyped-absent": ["removedAt": 9000.875]]]))), "untyped removal preserves raw identity and fractional clock")
        let conflictRow = rows.first { $0["kind"] == .string("watch_identity_conflict") }!
        let originalRoot = original["vortx"] as! Object, originalLibrary = originalRoot["library"] as! [Object]
        let originalProfiles = originalRoot["byProfile"] as! [String: Object], history = originalProfiles[owner.id.uuidString]!["ownerHistory"] as! [Object]
        let originalIntents = originalRoot["ownerWatched"] as! Object
        let conflictSources = conflictRow["receipt"]!["sources"]!.array!
        check(conflictRow["identity"] == .string("same-exact-video") && conflictSources.count == 3, "one pending conflict retains every contributing raw source")
        for (path, expected) in [("/vortx/library/0", originalLibrary[0]),
                                  ("/vortx/byProfile/" + owner.id.uuidString + "/ownerHistory/0", history[0]),
                                  ("/vortx/ownerWatched/original-intent", originalIntents["original-intent"] as! Object)] {
            check(conflictSources.contains(try typed(bytes(["sourceField": path, "receipt": expected]))), "conflicting watch source row retains original clocks and locator")
        }
        let material = try typed(preparation.material)
        check(material["addons"]?[owner.id.uuidString]?["intents"]?.array?.isEmpty == true
            && material["libraries"]?[owner.id.uuidString]?["intents"]?.array?.isEmpty == true
            && material["watches"]?[shared.id.uuidString]?.array?.isEmpty == true,
            "unresolved evidence never manufactures membership intents or saved-only viewing clocks")
        let bootstrap = try VortxNativeBootstrapArchive.encode(document: source, material: preparation.material, authenticatedSourceArchive: sourceArchive)
        let key = SymmetricKey(size: .bits256)
        let store = try VortxEncryptedCheckpointStore(directory: directory, key: key, bootstrap: bootstrap, bootstrapScope: scope)
        let gate = MembershipCheckpointGate(store)
        let action: VortxJSON = .object(["type": .string("import_legacy_sync"), "scope": .string(scope.account), "ownerProfileId": .string(scope.ownerProfileID), "material": try typed(preparation.material)])
        let session = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: gate,
            transport: VortxCResourceTransport(), allowNewAccount: true, initialActions: [raw(action)],
            authenticatedSourceArchive: sourceArchive, initialLegacyMaterial: preparation.material)
        let coldState = try typed(Data(try await session.stateJSON().utf8)), firstLedger = try await ledger(session)
        check(firstLedger["scope"] == .string(scope.account) && firstLedger["ownerProfileId"] == .string(scope.ownerProfileID), "scoped ledger")
        let firstRows = firstLedger["receipts"]!.array!
        check(firstRows.count == rows.count && rows.allSatisfy(firstRows.contains), "sealed ledger retains exact original raw receipts")
        let profiles = try VortxNativeProfiles.project(state: coldState, host: await session.hostPreferencesDocument(), baseline: [owner, shared])
        check(Set(profiles.map(\.id)) == [owner.id, shared.id] && profiles.contains { $0.id == shared.id && $0.name == shared.name }, "real native roster survives unrelated unresolved evidence")
        check(try !raw(coldState).contains(VortxLegacyMembershipReceiptArchive.key), "kernel snapshot excludes host ledger")
        check(try !raw(await session.hostPreferencesDocument()).contains(VortxLegacyMembershipReceiptArchive.key), "public host export excludes ledger")
        check(try !raw(coldState).contains(orphan), "orphan does not become native installed membership")
        let sealedFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "sealed" }
        check(!sealedFiles.isEmpty, "encrypted checkpoint exists")
        for file in sealedFiles { check(try Data(contentsOf: file).range(of: Data(orphan.utf8)) == nil, "ciphertext excludes raw orphan URL") }
        try store.rememberAuthenticatedScope(scope)
        check(try store.recovery(account: scope.account)?.bootstrap == bootstrap, "original source bootstrap retained exactly")
        _ = try await session.dispatch([#"{"type":"get_state"}"#], now: 1800000000, legacyMaterial: preparation.material, authenticatedSourceArchive: sourceArchive)
        check(try await ledger(session) == firstLedger, "same-source warm replay is idempotent")
        var unrelated = original; unrelated["futureHostPreference"] = "changed document only"
        let unrelatedSource = try bytes(unrelated), unrelatedPreparation = try prepare(unrelatedSource)
        check(hash(unrelatedSource) != hash(source), "changed complete source witness")
        _ = try await session.dispatch([#"{"type":"get_state"}"#], now: 1800000001, legacyMaterial: unrelatedPreparation.material,
            authenticatedSourceArchive: archive(unrelatedPreparation, source: unrelatedSource))
        check(try await ledger(session) == firstLedger, "changed source hash does not duplicate unchanged evidence")
        var changed = original, root = changed["vortx"] as! Object
        root["deletedAddonsTs"] = [orphan: ["addedAt": 2001.875, "removedAt": 1000.125]]; changed["vortx"] = root
        let changedSource = try bytes(changed), changedPreparation = try prepare(changedSource), changedArchive = try archive(changedPreparation, source: changedSource)
        _ = try await session.dispatch([#"{"type":"get_state"}"#], now: 1800000002, legacyMaterial: changedPreparation.material, authenticatedSourceArchive: changedArchive)
        let changedLedger = try await ledger(session), changedRows = changedLedger["receipts"]!.array!
        check(changedRows.count == 5 && rows.allSatisfy(changedRows.contains), "changed raw receipt appends without replacing original evidence")
        check(changedRows.contains { $0["kind"] == .string("addon_install") && $0["sourceDocumentSha256"] == .string(hash(changedSource)) }, "changed receipt retains new source witness")
        check(try bytes(original) == source, "warm projection preserves original cloud carriers")
        try await nativeProfileActions(session: session, store: store)
        check(try await ledger(session) == changedLedger, "native profile selection and edits preserve pending receipt ledger")
        let priorState = try await session.stateJSON(), priorHost = try store.readHostPreferences(scope: scope), priorArchive = try await session.authenticatedSourceArchive()
        let priorFiles = try Dictionary(uniqueKeysWithValues: sealedFiles.map { ($0, try Data(contentsOf: $0)) })
        gate.rejectCommits()
        var candidate = original, candidateRoot = candidate["vortx"] as! Object
        candidateRoot["deletedAddonsTs"] = [orphan: ["addedAt": 3000.25, "removedAt": 1000.125]]; candidate["vortx"] = candidateRoot
        let candidateSource = try bytes(candidate), candidatePreparation = try prepare(candidateSource)
        do {
            _ = try await session.dispatch([#"{"type":"patch_profile","id":"10000000-0000-0000-0000-000000000001","edits":[{"field":"name","value":"Must never be visible"}]}"#],
                now: 1800000003, legacyMaterial: candidatePreparation.material, authenticatedSourceArchive: archive(candidatePreparation, source: candidateSource))
            fatalError("refused checkpoint committed")
        } catch VortxNativeError.checkpointUncertain {}
        check(try await session.stateJSON() == priorState, "failed checkpoint does not expose candidate native profile")
        check(try await session.authenticatedSourceArchive() == priorArchive, "failed checkpoint does not expose candidate ledger")
        check(try store.read(scope: scope) == priorState && store.readHostPreferences(scope: scope) == priorHost, "failed checkpoint preserves durable state and archive")
        for (file, data) in priorFiles { check(try Data(contentsOf: file) == data, "failure preserves encrypted checkpoint bytes") }
        await session.close()
        let reopenedStore = try VortxEncryptedCheckpointStore(directory: directory, key: key)
        let reopened = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: reopenedStore, transport: VortxCResourceTransport())
        check(try await ledger(reopened) == changedLedger, "cold reopen retains complete accumulated ledger")
        let reopenedState = try typed(Data(try await reopened.stateJSON().utf8))
        let reopenedProfiles = try VortxNativeProfiles.project(state: reopenedState, host: await reopened.hostPreferencesDocument(), baseline: [])
        check(reopenedProfiles.contains { $0.id == shared.id && $0.name == shared.name }, "cold reopen retains native profile independent of host baseline")
        check(reopenedProfiles.contains { $0.id == createdProfileID && $0.name == "Saved native profile" }, "cold reopen retains new native profile and edited name")
        check(reopenedState["activeProfileId"] == .string(owner.id.uuidString), "cold reopen retains final native profile selection")
        await reopened.close()
        try rejectCorruptColdHydration(store: reopenedStore, host: priorHost!, ledger: changedLedger)
        print("Membership receipts actual static C ABI: cold scoped encrypted import, exact raw evidence, hash-independent deduplication, changed receipt retention, native profile switching/creation/name-save, cold reopen, failed-commit isolation, export exclusion and cold scope/shape/credential fences passed")
    }

    static let createdProfileID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    static func nativeProfileActions(session: VortxNativeSession, store: VortxEncryptedCheckpointStore) async throws {
        func dispatch(_ action: VortxJSON, now: UInt64) async throws -> VortxJSON {
            let responses = try await session.dispatch([raw(action)], now: now)
            check(responses.count == 1, "one acknowledgment for each real native profile action")
            let acknowledgment = try typed(Data(responses[0].utf8))
            check(acknowledgment["ok"] == .bool(true), "native profile action accepted by shipping ABI")
            let stateJSON = try await session.stateJSON()
            check(try store.read(scope: scope) == stateJSON, "accepted profile action checkpoint matches freshly read native state")
            return try typed(Data(stateJSON.utf8))
        }
        func selection(_ id: UUID, now: UInt64) async throws -> VortxJSON {
            let state = try await dispatch(.object(["type": .string("switch_profile"), "id": .string(id.uuidString)]), now: now)
            check(state["activeProfileId"] == .string(id.uuidString), "native activeProfileId acknowledges requested selection")
            return state
        }
        _ = try await selection(shared.id, now: 1800000010)
        _ = try await selection(owner.id, now: 1800000011)
        let added = try await dispatch(.object(["type": .string("add_profile"), "id": .string(createdProfileID.uuidString), "name": .string("New native profile")]), now: 1800000012)
        let addedRoster = try VortxNativeProfiles.project(state: added, host: await session.hostPreferencesDocument(), baseline: [])
        check(addedRoster.contains { $0.id == createdProfileID && $0.name == "New native profile" }, "fresh native roster contains newly saved profile")
        let renamed = try await dispatch(.object(["type": .string("patch_profile"), "id": .string(createdProfileID.uuidString),
            "edits": .array([.object(["field": .string("name"), "value": .string("Saved native profile")])])]), now: 1800000013)
        let renamedRoster = try VortxNativeProfiles.project(state: renamed, host: await session.hostPreferencesDocument(), baseline: [])
        check(renamedRoster.contains { $0.id == createdProfileID && $0.name == "Saved native profile" }, "fresh native roster contains durably edited profile name")
        _ = try await selection(createdProfileID, now: 1800000014)
        _ = try await selection(owner.id, now: 1800000015)
    }

    static func rejectCorruptColdHydration(store: VortxEncryptedCheckpointStore, host: Data, ledger: VortxJSON) throws {
        let originalLedger = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as! Object
        var foreign = originalLedger; foreign["scope"] = "account.foreign"
        var wrongOwner = originalLedger; wrongOwner["ownerProfileId"] = shared.id.uuidString
        var malformed = originalLedger; malformed["schemaVersion"] = true
        var malformedReceipt = originalLedger, malformedRows = malformedReceipt["receipts"] as! [Object]
        malformedRows[0].removeValue(forKey: "sourceDocumentSha256"); malformedReceipt["receipts"] = malformedRows
        var credential = originalLedger, rows = credential["receipts"] as! [Object]
        rows[0]["receipt"] = ["authorization": "synthetic-sensitive-value"]; credential["receipts"] = rows
        var nestedCredential = originalLedger, nestedRows = nestedCredential["receipts"] as! [Object]
        nestedRows[0]["receipt"] = ["encoded": try bytes(["token": "synthetic-nested-sensitive-value"]).base64EncodedString()]
        nestedCredential["receipts"] = nestedRows
        for invalid in [foreign, wrongOwner, malformed, malformedReceipt, credential, nestedCredential] {
            var local = try JSONDecoder().decode(VortxNativeHostPreferences.Local.self, from: host)
            let hostDocument: Object = ["ownAccountSources": Object(), VortxLegacyMembershipReceiptArchive.key: invalid]
            // Deliberately bypass the producer to simulate corrupted/restored sealed host bytes.
            local.authenticatedSourceArchive = try bytes(["schemaVersion": 1, "hostDocument": hostDocument, "excludedCredentialPaths": [String]()])
            let gate = MembershipCheckpointGate(store, hostOverride: try JSONEncoder().encode(local))
            var rejected = false
            do {
                _ = try VortxNativeSession(scope: scope, ownerName: owner.name, abi: VortxCABI(), store: gate, transport: VortxCResourceTransport())
            } catch { rejected = true }
            check(rejected && gate.commitCount == 0, "invalid restored scope, shape or credentials rejected before native checkpoint commit")
        }
    }
}
