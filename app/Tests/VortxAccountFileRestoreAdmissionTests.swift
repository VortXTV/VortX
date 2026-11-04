import Foundation
import CryptoKit

@main
private enum VortxAccountFileRestoreAdmissionTests {
    typealias Service = VortxAccountFileRepairService
    typealias Restore = VortxAccountFileRestore
    typealias Exact = OwnerHistoryExactJSON
    static let accountID = "10000000-0000-0000-0000-000000000001"
    static let ownerID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    static let childID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    static let key = Data(repeating: 0x41, count: 32)
    static func check(_ value: Bool, _ name: String) { precondition(value, name); print("PASS: " + name) }
    static func source(name: String = "Synthetic Owner", owner: UUID = ownerID, childName: String? = nil) throws -> Data {
        var vx = try Exact.Object(Data("{}".utf8))
        var profiles = [UserProfile(id: owner, name: name, avatar: "O",
            pin: "sha256:" + String(repeating: "a", count: 64), isOwner: true, familyEdit: false, isKids: false)]
        if let childName {
            profiles.append(UserProfile(id: childID, name: childName, avatar: "K",
                pin: "sha256:" + String(repeating: "b", count: 64), usesOwnAccount: false,
                isOwner: false, familyEdit: true, isKids: true))
        }
        vx.set("roster", try JSONEncoder().encode(profiles))
        vx.set("rosterModified", Data("1700000000".utf8)); vx.set("library", Data("[]".utf8)); vx.set("addons", Data("[]".utf8))
        var root = try Exact.Object(Data("{}".utf8)); root.set("vortx", try vx.encoded())
        root.set("future", Data(#"{"number":1.00,"order":[3,2,1]}"#.utf8))
        root.set("apiKeys", Data(#"{"synthetic-provider":"preserve-only"}"#.utf8))
        return try root.encoded()
    }
    static func sealed(_ plaintext: Data, revision: Int, v2: Bool = false) -> String {
        VortXSyncCrypto.sealDocument(dataKey: key, plaintext: plaintext, accountId: accountID, version: revision, writeV2: v2)!
    }
    static func file(_ plaintext: Data) throws -> Data {
        try VortxAccountBackupFile.encode(document: sealed(plaintext, revision: 12), version: 12,
            username: "Synthetic", now: Date(timeIntervalSince1970: 1_700_000_000))
    }
    static func head(_ plaintext: Data, revision: Int = 24) throws -> Data {
        var root = try Exact.Object(Data("{}".utf8)); root.set("document", try Exact.string(sealed(plaintext, revision: revision)))
        root.set("version", Data(String(revision).utf8)); return try root.encoded()
    }
    static func input() -> Service.Input {
        let capture = CredentialScopeRegistry.shared.fixtureEstablish(.account(UUID(uuidString: accountID)!))
        return .init(accountID: accountID, capture: capture, dataKey: key, requiresVersionBoundHead: false)
    }
    static func prepare(_ bytes: Data, _ response: Data, _ input: Service.Input) throws -> Restore.Prepared {
        try Restore.prepare(file: bytes, response: response, input: input,
            fence: .init(capture: input.capture), abi: VortxCABI())
    }
    static func rejects(_ name: String, _ action: () throws -> Void) {
        do { try action(); preconditionFailure("accepted " + name) }
        catch { check(true, name) }
    }
    static func intent(_ prepared: Restore.Prepared) -> Restore.Intent {
        .init(format: "vortx-account-file-restore-intent-v1", sourceKind: "user_selected_file", operationID: UUID(),
            accountID: accountID, ownerProfileID: ownerID.uuidString, selectedFile: prepared.selectedFile,
            candidateFile: prepared.candidateFile, replacedHeadResponse: prepared.headResponse,
            plaintextSHA256: Restore.digest(prepared.plaintext), baseRevision: 24, revision: 25,
            submittedDocument: sealed(prepared.plaintext, revision: 25))
    }
    static func changedNative(_ file: Data, change: (inout Exact.Object) throws -> Void) throws -> Data {
        let inspected = try VortxAccountBackupFile.inspect(file)
        var envelope = try Exact.Object(file)
        var plaintext = try Exact.Object(VortXSyncCrypto.openDocument(dataKey: key, stored: inspected.document,
            accountId: accountID, version: inspected.version)!)
        var native = try Exact.Object(plaintext.required("nativeSync")); try change(&native)
        plaintext.set("nativeSync", try native.encoded()); let bytes = try plaintext.encoded()
        envelope.set("document", try Exact.string(sealed(bytes, revision: inspected.version, v2: true)))
        var metadata = try Exact.Object(envelope.required(VortxAccountBackupRepair.repairKey))
        metadata.set("candidatePlaintextSHA256", try Exact.string(Restore.digest(bytes)))
        if let schema = native["schemaVersion"] { metadata.set("nativeSchema", schema) }
        envelope.set(VortxAccountBackupRepair.repairKey, try metadata.encoded()); return try envelope.encoded()
    }
    static func main() async throws {
        let current = input(), originalPlaintext = try source()
        let original = try file(originalPlaintext), response = try head(originalPlaintext)
        let originalSHA = Restore.digest(original)
        let prepared = try prepare(original, response, current)
        check(prepared.selectedFile == original && Restore.digest(original) == originalSHA, "original selected bytes retained")
        let sourceRaw = try Exact.Object(originalPlaintext), candidateRaw = try Exact.Object(prepared.plaintext)
        check(sourceRaw.fields.allSatisfy { candidateRaw[$0.key] == $0.value }, "all original raw account values retained")
        check(Set(candidateRaw.fields.keys) == Set(sourceRaw.fields.keys).union(["nativeSync"]), "only nativeSync added to original account")
        let repair = try Service.prepare(file: original, authenticatedHeadResponse: response, input: current,
            fence: .init(capture: current.capture), abi: VortxCABI())
        let repaired = try prepare(repair.file, response, current)
        let counting = CountingRestoreABI()
        let admitted = try Restore.admitCandidate(file: repair.file, input: current, owner: ownerID,
            fence: .init(capture: current.capture), abi: counting)
        check(counting.created == 1 && counting.freed == 1, "common admission uses exactly one cold runtime without conversion recursion")
        check(admitted == repaired.plaintext, "common admission returns exact admitted bytes")
        check(repaired.selectedFile == repair.file && repaired.candidateFile == repair.file, "Repair output imports with exact candidate file bytes")
        let decoded = try VortxAccountBackupFile.inspect(repair.file)
        check(repaired.plaintext == VortXSyncCrypto.openDocument(dataKey: key, stored: decoded.document,
            accountId: accountID, version: decoded.version), "Repair output native history is not regenerated")
        rejects("ordinary Repair action still refuses reconversion") {
            _ = try Service.prepare(file: repair.file, authenticatedHeadResponse: response, input: current,
                fence: .init(capture: current.capture), abi: VortxCABI())
        }
        rejects("independent current head owner mismatch") { _ = try prepare(original,
            head(source(owner: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!)), current) }
        var badOuter = try Exact.Object(repair.file); badOuter.set("username", try Exact.string("Changed"))
        rejects("altered retained outer field") { _ = try prepare(badOuter.encoded(), response, current) }
        let schema6 = try changedNative(repair.file) { $0.set("schemaVersion", Data("6".utf8)) }
        rejects("schema6 cannot enter generic file restore") { _ = try prepare(schema6, response, current) }
        let foreignScope = try changedNative(repair.file) { $0.set("scope", try Exact.string("account:foreign")) }
        rejects("native source scope differs") { _ = try prepare(foreignScope, response, current) }
        let ownSource = try changedNative(repair.file) { $0.set("ownAccountSources", Data(#"{"future":{"verifiedStreamingUid":"synthetic"}}"#.utf8)) }
        rejects("unsupported own-source carrier retained and refused") { _ = try prepare(ownSource, response, current) }
        var opaqueHost = try Exact.Object(source()); opaqueHost.set("future", Data(#"{"name":"[Opaque] untyped value"}"#.utf8))
        rejects("Repair cannot export a candidate rejected by common full host admission") {
            _ = try Service.prepare(file: file(opaqueHost.encoded()), authenticatedHeadResponse: response, input: current,
                fence: .init(capture: current.capture), abi: VortxCABI())
        }
        let expired = Service.Fence(capture: current.capture); expired.revoke()
        rejects("revoked operation cannot produce candidate") { _ = try Restore.prepare(file: original, response: response,
            input: current, fence: expired, abi: VortxCABI()) }
        let wrongKey = Service.Input(accountID: accountID, capture: current.capture, dataKey: Data(repeating: 0x42, count: 32), requiresVersionBoundHead: false)
        rejects("wrong current key cannot authenticate owner or file") { _ = try prepare(original, response, wrongKey) }
        for (text, result) in [(#"{"accepted":true}"#, true), (#"{"accepted":false}"#, false)] {
            check(Restore.acceptedVerdict(status: 200, body: Data(text.utf8)) == result, "literal Boolean verdict " + String(result))
        }
        for text in [#"{"accepted":1}"#, #"{"accepted":"true"}"#, #"{"accepted":null}"#, #"{}"#, #"{"accepted":false,"accepted":true}"#] {
            check(Restore.acceptedVerdict(status: 200, body: Data(text.utf8)) == nil, "ambiguous raw verdict is not acceptance")
        }
        check(Restore.acceptedVerdict(status: 503, body: Data(#"{"accepted":true}"#.utf8)) == nil, "non-200 verdict remains unconfirmed")
        let retained = intent(repaired)
        check(Restore.confirms(try head(repaired.plaintext, revision: 25), intent: retained, key: key), "actual GET revision and plaintext match")
        check(!Restore.confirms(try head(repaired.plaintext, revision: 24), intent: retained, key: key), "old GET revision is not confirmation")
        check(!Restore.confirms(try head(source(), revision: 25), intent: retained, key: key), "same revision other plaintext is not confirmation")
        check(!Restore.confirms(try head(repaired.plaintext, revision: 25), intent: retained, key: Data(repeating: 0x42, count: 32)), "wrong key is not confirmation")
        guard CommandLine.arguments.count == 2 else { preconditionFailure("isolated journal root required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let journal = VortxAccountFileRestoreJournal(root: root)
        check(try await journal.unresolved(account: accountID, key: key) == nil, "empty journal has no unresolved operation")
        try await journal.retain(retained, key: key, fence: .init(capture: current.capture))
        let read = try await journal.load(account: accountID, id: retained.operationID, key: key)
        check(read.selectedFile == repair.file && read.candidateFile == repair.file && read.replacedHeadResponse == response,
            "durable encrypted journal retains complete original candidate and replaced head")
        check(try await journal.unresolved(account: accountID, key: key) == retained.operationID, "missing delivery receipt prevents replay")
        do { try await journal.retain(retained, key: key, fence: .init(capture: current.capture)); preconditionFailure("overwrote immutable intent") }
        catch { check(true, "intent publication is create-only") }
        do { _ = try await journal.load(account: accountID, id: retained.operationID, key: Data(repeating: 0x42, count: 32)); preconditionFailure("opened journal with wrong key") }
        catch { check(true, "journal authenticates original key") }
        try await journal.record(.init(operationID: retained.operationID, verdict: .uploadAccepted, revision: 25), account: accountID, key: key)
        check(try await journal.unresolved(account: accountID, key: key) == retained.operationID, "accepted upload cannot silently replay")
        try await journal.record(.init(operationID: retained.operationID, verdict: .serverConfirmed, revision: 25), account: accountID, key: key)
        check(try await journal.unresolved(account: accountID, key: key) == retained.operationID, "server confirmation does not certify local adoption")
        let originalTaggedSource = try source(name: "[RD] Synthetic Owner", childName: "[Kids] Synthetic Child")
        let taggedOriginal = try file(originalTaggedSource), taggedHead = try head(originalTaggedSource)
        let taggedRepair = try Service.prepare(file: taggedOriginal, authenticatedHeadResponse: taggedHead, input: current,
            fence: .init(capture: current.capture), abi: VortxCABI())
        // Required positive, not an expected rejection: must fail until the separate narrow archive
        // display-role defect is fixed. Never weaken this gate to ship a broken Repair->Restore journey.
        let tagged = try prepare(taggedRepair.file, taggedHead, current)
        check(tagged.candidateFile == taggedRepair.file, "tagged profile Repair output restores without changing bytes")
        let taggedRoot = try JSONDecoder().decode(VortxJSON.self, from: tagged.plaintext)
        let taggedNative = taggedRoot["nativeSync"]!
        check(taggedNative["profiles"]?[ownerID.uuidString]?["profile"]?["name"] == .string("[RD] Synthetic Owner"), "tagged owner native register survives")
        check(taggedNative["profiles"]?[childID.uuidString]?["profile"]?["name"] == .string("[Kids] Synthetic Child"), "tagged shared child native register survives")
        let originalTaggedVortx = try Exact.Object(Exact.Object(originalTaggedSource).required("vortx"))
        let expectedProfiles = try JSONDecoder().decode([UserProfile].self, from: originalTaggedVortx.required("roster"))
        let selectedInspection = try VortxAccountBackupFile.inspect(taggedRepair.file)
        let selectedPlaintext = VortXSyncCrypto.openDocument(dataKey: key, stored: selectedInspection.document,
            accountId: accountID, version: selectedInspection.version)!
        let selectedNative = try JSONDecoder().decode(VortxJSON.self, from: Exact.Object(selectedPlaintext).required("nativeSync"))
        let coldState = try VortxNativeSession.detachedFileRestoreState(scope: tagged.scope, nativeSync: taggedNative, abi: VortxCABI())
        for expected in expectedProfiles {
            let expectedAccount: VortxJSON = expected.isOwner ? .object(["kind": .string("local_only")])
                : .object(["kind": .string("shared"), "value": .string(ownerID.uuidString)])
            for native in [selectedNative, taggedNative, coldState["nativeSync"]!] {
                let register = native["profiles"]?[expected.id.uuidString]?["profile"]
                guard case .array(let baseline) = native["legacyImport"]?["baseline"]?["roster"],
                      let receiptProfile = baseline.first(where: { $0["id"] == .string(expected.id.uuidString) }) else {
                    preconditionFailure("missing selected native source roster")
                }
                for profile in [register, Optional(receiptProfile)] {
                    check(profile?["name"] == .string(expected.name) && profile?["owner"] == .bool(expected.isOwner)
                        && profile?["account"] == expectedAccount, "selected owner/shared binding and display name survive cold restore")
                    check(profile?["pin"] == .string(expected.pin!) && profile?["parental"]?["kids"] == .bool(expected.isKids)
                        && profile?["parental"]?["familyEdit"] == .bool(expected.familyEdit),
                        "selected PIN and parental policy survive wrapper baseline and cold restore")
                }
            }
        }
        let preserved = try Exact.Object(tagged.plaintext)
        check(preserved["vortx"] == (try Exact.Object(originalTaggedSource))["vortx"], "tagged full legacy roster bytes survive")
        print("All actual-source account file restore admission and journal checks passed with the linked native ABI.")
    }
}

// Forward every call to the real ABI; the count catches accidental workflow recursion.
private final class CountingRestoreABI: VortxRuntimeABI, @unchecked Sendable {
    private let lock = NSLock()
    private var creates = 0, frees = 0
    private let actual = VortxCABI()
    var created: Int { lock.lock(); defer { lock.unlock() }; return creates }
    var freed: Int { lock.lock(); defer { lock.unlock() }; return frees }
    func create(ownerID: String, ownerName: String) -> UInt {
        lock.lock(); creates += 1; let count = creates; lock.unlock()
        precondition(count <= 16, "unexpected candidate conversion recursion")
        return actual.create(ownerID: ownerID, ownerName: ownerName)
    }
    func hydrate(_ snapshot: String) -> UInt { actual.hydrate(snapshot) }
    func dispatch(_ handle: UInt, action: String, now: UInt64) -> String? { actual.dispatch(handle, action: action, now: now) }
    func resolve(_ handle: UInt, request: String) -> String? { actual.resolve(handle, request: request) }
    func state(_ handle: UInt) -> String? { actual.state(handle) }
    func delta(_ handle: UInt) -> String? { actual.delta(handle) }
    func canonicalizeOwnerHistoryEvidence(_ evidence: String) -> String? { actual.canonicalizeOwnerHistoryEvidence(evidence) }
    func free(_ handle: UInt) { lock.lock(); frees += 1; lock.unlock(); actual.free(handle) }
}
