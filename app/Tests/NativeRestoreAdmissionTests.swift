import Foundation
import CoreFoundation
import CryptoKit

// Production KeychainFailureClosedStore and exact credential result declarations are inserted here.
// There is no Security adapter, app, credential file, network, native engine or preferences instance.
/* PRODUCTION_SECURE_BOUNDARY */

private final class SecureBackend {
    var values: [String: String] = [:]
    var failedReads: Set<String> = []
    var failedWrites: Set<String> = []
    var failedDeletes: Set<String> = []
    var failedReadsAfterWrite: Set<String> = []
    var mismatchedReads: Set<String> = []
    var writes: [String] = []
    func makeStore() -> KeychainFailureClosedStore {
        KeychainFailureClosedStore(readSecure: { [self] key in
            if failedReads.contains(key) { return .failure }
            if mismatchedReads.contains(key) { return .value("fixture-mismatch") }
            return values[key].map(CredentialDurableReadResult.value) ?? .missing
        }, writeSecure: { [self] value, key in
            writes.append(key)
            if failedWrites.contains(key) || (value == nil && failedDeletes.contains(key)) { return .failure }
            values[key] = value
            if failedReadsAfterWrite.contains(key) { failedReads.insert(key) }
            return .success
        }, invalidationAccount: { "invalidation:" + $0 }, invalidationSentinel: "invalidated",
           isLegacyInvalidated: { _ in false }, clearLegacyInvalidated: { _ in },
           purgeAllLegacy: {}, purgeLegacy: { _ in })
    }
}
@MainActor private enum Keychain {
    static var backend = SecureBackend()
    static var store = backend.makeStore()
    static func reset() { backend = SecureBackend(); store = backend.makeStore() }
    static func confirmedString(_ slot: String) -> CredentialDurableReadResult { store.confirmedString(slot) }
    static func set(_ value: String?, for slot: String) -> CredentialMutationResult { store.set(value, for: slot) }
}
private enum CredentialScope: Equatable { case account(String), signedOut }
@MainActor private final class CredentialScopeRegistry {
    struct Capture: Equatable {
        let scope: CredentialScope
        let generation: Int
        var namespace: String { if case .account(let account) = scope { return account }; return "signed-out" }
    }
    var scope = CredentialScope.account("fixture-account")
    var generation = 1
    func capture() -> Capture { .init(scope: scope, generation: generation) }
    func replace(_ name: String) { scope = .account(name); generation += 1 }
}
@MainActor private enum DiagnosticsLog {
    static var messages: [String] = []
    static func log(_ category: String, _ message: String) { messages.append(category + ":" + message) }
}
private struct UserProfile {
    static let ownerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let id: UUID
    let name: String
    let avatar: String
    let isOwner: Bool
}
private struct ProfileRosterSnapshot {
    let profiles: [UserProfile]
    static func wire(_ profiles: [UserProfile]) -> [[String: Any]]? {
        profiles.map { ["id": $0.id.uuidString, "name": $0.name, "isOwner": $0.isOwner] }
    }
}
@MainActor private final class ProfileStore {
    static let shared = ProfileStore()
    var activeID: UUID? = UserProfile.ownerID
}
private enum VortxNativeError: Error { case invalidSnapshot, unavailable }
private struct SymmetricKey { init(data: Data) {} }
@MainActor private enum VortxNativeStorage {
    // URL construction only. The inert encrypted store below never reads or writes it.
    static func root() throws -> URL { URL(fileURLWithPath: "/fixture-not-used") }
}
@MainActor private enum VortxNativeInstallationKey {
    static var unavailable = false
    static func loadOrCreate() throws -> SymmetricKey {
        if unavailable { throw VortxNativeError.unavailable }
        return SymmetricKey(data: Data(count: 32))
    }
}
private struct VortxAccountScope {
    let account: String
    let ownerProfileID: String
}
@MainActor private final class VortxEncryptedCheckpointStore {
    static var checkpointAdoption: Bool?
    struct Recovery { let bootstrap: Data }
    init(directory: URL, key: SymmetricKey, installationKey: SymmetricKey) throws {}
    func recovery(account: String) throws -> Recovery? { nil }
    func permitsWebsiteRosterAdoption(scope: VortxAccountScope, witness: Data, requiringCheckpoint: Bool) throws -> Bool {
        precondition(scope.account == "fixture-account" && scope.ownerProfileID == UserProfile.ownerID.uuidString && witness.count == 32)
        return Self.checkpointAdoption ?? !requiringCheckpoint
    }
}

@MainActor private final class RestoreAdmissionFixture {
    let credentialAuthority = CredentialScopeRegistry()
    var nativeCheckpointGeneration = UUID()
    var lastSyncedVersion = 0
    var account: Int? = 1
    var isSignedIn: Bool { account != nil }
    var dataKey: Data? = Data(count: 32)
    private var accountReconnectFailureCapture: CredentialScopeRegistry.Capture?
    static let owner = UserProfile(id: UserProfile.ownerID, name: "Fixture", avatar: "x", isOwner: true)
    static var resolvedRoster: ProfileRosterSnapshot? = .init(profiles: [owner])
    var seedCalls = 0
    var seedThrows = false
    var seedDocument: [String: Any]? = [:]
    var whileSeeding: (() -> Void)?
    var requests = 0
    var reply: (Int, [String: Any]?) = (404, nil)
    var responseETag: String?
    var whileReading: (() -> Void)?
    static var decodedHostDocuments = 0
    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { capture == credentialAuthority.capture() }
    static func resolveRoster(from document: [String: Any], fullOnly: Bool) -> ProfileRosterSnapshot? {
        precondition(fullOnly, "admission must never accept a lossy summary")
        if let resolvedRoster { return resolvedRoster }
        guard let rows = (document["vortx"] as? [String: Any])?["roster"] as? [[String: Any]] else { return nil }
        return .init(profiles: rows.compactMap { row in
            guard let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let name = row["name"] as? String, let owner = row["isOwner"] as? Bool else { return nil }
            return UserProfile(id: id, name: name, avatar: "", isOwner: owner)
        })
    }
    private func publishDetachedNativeSeed(_ value: [String: Any], capture: CredentialScopeRegistry.Capture, cloudAuthority: ReceivedProviderCloudAuthority) async throws -> [String: Any]? {
        seedCalls += 1
        whileSeeding?()
        if seedThrows { throw VortxNativeError.unavailable }
        return seedDocument
    }
    func request(_ method: String, _ path: String, auth: Bool, credentialCapture: CredentialScopeRegistry.Capture,
        ifNoneMatch: Int? = nil, receiveETag: ((String?) -> Void)? = nil) async -> (Int, [String: Any]?) {
        precondition(method == "GET" && path == "/v1/backup" && auth)
        requests += 1; whileReading?(); receiveETag?(responseETag)
        return reply
    }
    // Crypto is an explicit inert aperture; pull classification and admission are unchanged source.
    func openSyncDocument(_ document: String, version: Int) -> Data? { Data(base64Encoded: document) }
    static func decodeDecryptedSyncDocument(_ bytes: Data) throws -> [String: Any] {
        decodedHostDocuments += 1
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw VortxNativeError.invalidSnapshot }
        return object
    }
    static func documentVersion(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }
    // Declared no-pending-provider aperture; actual source epoch runs in local-adoption checks.
    private struct ReceivedProviderCloudAuthority { var isCurrent: Bool { true } }
    /* PRODUCTION_DECLARATIONS */

    static var checks = 0
    static func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
    static func fresh() -> RestoreAdmissionFixture {
        Keychain.reset(); DiagnosticsLog.messages = []; VortxNativeInstallationKey.unavailable = false
        VortxEncryptedCheckpointStore.checkpointAdoption = nil
        ProfileStore.shared.activeID = UserProfile.ownerID; resolvedRoster = .init(profiles: [owner])
        return RestoreAdmissionFixture()
    }
    var slot: String { "vortx.native.backupSeen." + credentialAuthority.capture().namespace }
    private func expectAdmission(_ expected: NativeRestoreAdmissionFailure, pulled: VersionedPull = .doc(doc: [:], version: 1, plaintext: Data("{}".utf8), observation: nil)) async {
        do {
            _ = try await nativeRestoreDocument(pulled, capture: credentialAuthority.capture(),
                selectedProfile: ProfileStore.shared.activeID, generation: nativeCheckpointGeneration, cloudAuthority: .init())
            preconditionFailure("unexpected admission: " + expected.rawValue)
        } catch let error as NativeRestoreAdmissionFailure {
            Self.check(error == expected, "exact typed admission failure: " + expected.rawValue)
        } catch { preconditionFailure("unexpected untyped error") }
    }
    static func markerCases() {
        let seen = fresh(); Keychain.backend.values[seen.slot] = "1"
        check(seen.rememberNativeBackup(capture: seen.credentialAuthority.capture()), "certified existing marker accepted")
        check(Keychain.backend.writes.isEmpty, "certified exact1 makes zero mutations")
        check(seen.nativeBackupHistory(capture: seen.credentialAuthority.capture()) == .seen, "certified seen floor")
        let absent = fresh()
        check(absent.nativeBackupHistory(capture: absent.credentialAuthority.capture()) == .confirmedAbsent, "only backend missing is absence")
        check(absent.rememberNativeBackup(capture: absent.credentialAuthority.capture()), "new marker durable stages succeed")
        check(Keychain.confirmedString(absent.slot) == .value("1"), "new marker exact certified readback")
        let malformed = fresh(); Keychain.backend.values[malformed.slot] = "unexpected-preserved"
        check(!malformed.rememberNativeBackup(capture: malformed.credentialAuthority.capture()), "unknown marker cannot certify")
        check(Keychain.backend.values[malformed.slot] == "unexpected-preserved" && Keychain.backend.writes.isEmpty, "unknown durable bytes preserved")
        for stage in ["marker-write", "target-write", "target-readback", "marker-clear"] {
            let f = fresh(), marker = "invalidation:" + f.slot
            switch stage {
            case "marker-write": Keychain.backend.failedWrites.insert(marker)
            case "target-write": Keychain.backend.failedWrites.insert(f.slot)
            case "target-readback": Keychain.backend.failedReadsAfterWrite.insert(f.slot)
            default: Keychain.backend.failedDeletes.insert(marker)
            }
            check(!f.rememberNativeBackup(capture: f.credentialAuthority.capture()), "failed durable stage cannot ACK: " + stage)
            check(f.nativeBackupHistory(capture: f.credentialAuthority.capture()) == .unavailable, "observed backup never becomes same-process absence")
            check(Keychain.store.string(f.slot) == "1", "fixture exercises real volatile compatibility override")
            let retained = Keychain.backend.values
            Keychain.store = Keychain.backend.makeStore() // Restart only the secure-store adapter, preserving durable bytes.
            check(f.nativeBackupHistory(capture: f.credentialAuthority.capture()) == .unavailable, "manager denial floor survives adapter restart")
            check(Keychain.backend.values == retained, "floor query conserves durable bytes")
            Keychain.backend.failedWrites = []; Keychain.backend.failedReads = []; Keychain.backend.failedDeletes = []
            Keychain.backend.failedReadsAfterWrite = []
            let writesBeforeRetry = Keychain.backend.writes.count
            if stage == "marker-write" {
                check(f.rememberNativeBackup(capture: f.credentialAuthority.capture()), "retry allowed only because no durable marker or target was installed")
                check(Keychain.confirmedString(f.slot) == .value("1"), "confirmed absent retry certifies new receipt")
            } else {
                check(!f.rememberNativeBackup(capture: f.credentialAuthority.capture()), "persisted tombstone remains blocked after backend recovery")
                check(Keychain.backend.values == retained && Keychain.backend.writes.count == writesBeforeRetry,
                      "unavailable state grants no same-constant repair authority")
            }
        }
        let failure = fresh(); Keychain.backend.failedReads.insert(failure.slot)
        check(failure.nativeBackupHistory(capture: failure.credentialAuthority.capture()) == .unavailable, "backend read failure is not absence")
        let tombstone = fresh(); Keychain.backend.values[tombstone.slot] = "1"; Keychain.backend.values["invalidation:" + tombstone.slot] = "invalidated"
        check(tombstone.nativeBackupHistory(capture: tombstone.credentialAuthority.capture()) == .unavailable, "durable invalidation cannot donate seen or absence")
        for target in [nil, "1", "future-target-format"] as [String?] {
            for invalidation in ["invalidated", "future-marker-format"] {
                let f = fresh(), marker = "invalidation:" + f.slot
                Keychain.backend.values[f.slot] = target
                Keychain.backend.values[marker] = invalidation
                let original = Keychain.backend.values
                for _ in 0..<2 {
                    check(!f.rememberNativeBackup(capture: f.credentialAuthority.capture()), "invalidated or unknown state cannot ACK")
                    check(f.nativeBackupHistory(capture: f.credentialAuthority.capture()) == .unavailable, "unknown bytes cannot authorize empty seed")
                    check(Keychain.backend.values == original && Keychain.backend.writes.isEmpty,
                          "known/unknown invalidation and hidden target bytes preserved exactly")
                    check(f.seedCalls == 0 && f.lastSyncedVersion == 0, "unavailable receipt does not seed or stamp")
                    Keychain.store = Keychain.backend.makeStore()
                }
            }
        }
        for readFailure in ["target", "invalidation"] {
            let f = fresh()
            Keychain.backend.values[f.slot] = "future-target-format"
            Keychain.backend.failedReads.insert(readFailure == "target" ? f.slot : "invalidation:" + f.slot)
            let original = Keychain.backend.values
            check(!f.rememberNativeBackup(capture: f.credentialAuthority.capture()), "failed pre-read cannot authorize overwrite")
            check(Keychain.backend.writes.isEmpty && Keychain.backend.values == original, "pre-read failure does not create a volatile write or mutate bytes")
            Keychain.backend.failedReads = []
            check(!f.rememberNativeBackup(capture: f.credentialAuthority.capture()), "recovered read reveals preserved unknown target")
            check(Keychain.backend.writes.isEmpty && Keychain.backend.values == original, "read recovery is not repair authority")
        }
        let bounded = fresh()
        for index in 0...Self.nativeObservedBackupAccountLimit {
            bounded.credentialAuthority.replace("fixture-\(index)")
            Keychain.backend.failedWrites.insert("invalidation:" + bounded.slot)
            check(!bounded.rememberNativeBackup(capture: bounded.credentialAuthority.capture()), "observed account write failure")
        }
        check(bounded.nativeObservedBackupAccounts.count == Self.nativeObservedBackupAccountLimit, "observation floor has finite growth")
        bounded.credentialAuthority.replace("unobserved-account")
        check(bounded.nativeBackupHistory(capture: bounded.credentialAuthority.capture()) == .unavailable, "saturation never evicts into seed permission")
        bounded.credentialAuthority.scope = .signedOut; bounded.credentialAuthority.generation += 1
        check(bounded.nativeBackupHistory(capture: bounded.credentialAuthority.capture()) == .unavailable, "signed-out capture has no seed authority")
        bounded.credentialAuthority.replace("fixture-0")
        check(bounded.nativeBackupHistory(capture: bounded.credentialAuthority.capture()) == .unavailable, "signout and account rebind do not clear denial floor")
    }
    static func admissionCases() async throws {
        let valid = fresh()
        let original = Data(#"{ "preserved":"exact", "unknown":9007199254740993, "negativeZero":-0.0 }"#.utf8)
        let accepted = try await valid.nativeRestoreDocument(.doc(doc: ["preserved": "exact"], version: 1, plaintext: original, observation: nil),
            capture: valid.credentialAuthority.capture(), selectedProfile: ProfileStore.shared.activeID, generation: valid.nativeCheckpointGeneration, cloudAuthority: .init())
        check(accepted.document["preserved"] as? String == "exact" && accepted.owners.count == 1, "valid document admitted without rewriting")
        check(accepted.plaintext == original, "admission retains original authenticated plaintext independently of the host projection")
        let old = fresh(); old.lastSyncedVersion = 2; await old.expectAdmission(.staleDocument)
        let missing = fresh(); resolvedRoster = nil; await missing.expectAdmission(.rosterUnavailable)
        let webBytes = Data(#"{"addons":[{"transportUrl":"https://addon.test/manifest.json"}],"apiKeys":{"tmdb":"synthetic"},"opaque":-0.0,"vortx":{"deletedAddons":["x"],"future":9007199254740993},"webProgress":{"owner":[],"removed":{"owner":[]}}}"#.utf8)
        let webDocument = try JSONSerialization.jsonObject(with: webBytes) as! [String: Any]
        let web = fresh(); resolvedRoster = nil
        let webCapture = web.credentialAuthority.capture()
        let pulled = VersionedPull.doc(doc: webDocument, version: 7, plaintext: webBytes, observation: UUID())
        await web.expectAdmission(.rosterUnavailable, pulled: pulled)
        VortxEncryptedCheckpointStore.checkpointAdoption = true
        let adoption = try await web.nativeRestoreDocument(pulled, capture: webCapture,
            selectedProfile: ProfileStore.shared.activeID, generation: web.nativeCheckpointGeneration, cloudAuthority: .init())
        check(adoption.adoptsWebsiteRoster && adoption.owners.first?.id == UserProfile.ownerID &&
              adoption.owners.first?.name == "Main", "authenticated existing website witness can reopen the deterministic owner")
        check(adoption.plaintext == webBytes && web.seedCalls == 0, "existing website witness keeps raw bytes and never sends create-only seed")
        check((adoption.websiteAdoption?.original["vortx"] as? [String: Any])?["roster"] == nil,
              "the interpretation-only owner is absent from the archived source input")
        let progressBytes = Data(#"{"webProgress":{"owner":[]}}"#.utf8)
        let progressDocument = try JSONSerialization.jsonObject(with: progressBytes) as! [String: Any]
        let progressAdoption = try NativeWebsiteAccountAdoption(progressDocument, plaintext: progressBytes, revision: 7)
        check(progressAdoption != nil, "website owner-only progress has the webapp's actual array shape")
        VortxEncryptedCheckpointStore.checkpointAdoption = false
        await web.expectAdmission(.rosterUnavailable, pulled: pulled)
        VortxEncryptedCheckpointStore.checkpointAdoption = true
        let warm = try web.authorizedWebsiteAccountAdoption(webDocument, plaintext: webBytes, revision: 7,
            capture: webCapture, requiringCheckpoint: true)!
        let outgoing = try warm.exportBase()
        let before = try OwnerHistoryExactJSON.Object(webBytes), after = try OwnerHistoryExactJSON.Object(outgoing)
        let beforeNamespace = try OwnerHistoryExactJSON.Object(before.required("vortx"))
        let afterNamespace = try OwnerHistoryExactJSON.Object(after.required("vortx"))
        check(after["addons"] == before["addons"] && after["apiKeys"] == before["apiKeys"]
              && after["webProgress"] == before["webProgress"] && after["opaque"] == before["opaque"],
              "outgoing roster base preserves unrelated exact root slices")
        check(afterNamespace["future"] == beforeNamespace["future"]
              && afterNamespace["deletedAddons"] == beforeNamespace["deletedAddons"]
              && afterNamespace["rosterModified"] == Data("0".utf8),
              "outgoing base retains exact nested slices and adds a zero baseline clock")
        let peer = try JSONSerialization.jsonObject(with: outgoing) as! [String: Any]
        let peerAdoption = try NativeWebsiteAccountAdoption(peer, plaintext: outgoing, revision: 8)
        check(peerAdoption == nil && resolveRoster(from: peer, fullOnly: true)?.profiles.first?.id == UserProfile.ownerID,
              "fresh device sees durable full roster and requires no adoption exception")
        for forbidden in [
            #"{"addons":[],"settings":null}"#,
            #"{"addons":[],"nativeSync":{}}"#,
            #"{"addons":[],"nativeAccountBootstrap":"authenticated-empty-v1"}"#,
            #"{"addons":[],"vortx":{"roster":"invalid"}}"#,
            #"{"addons":[],"vortx":{"rosterModified":null}}"#,
            #"{"addons":[],"vortx":{"profiles":[]}}"#,
            #"{"addons":[],"vortx":{"byProfile":{}}}"#,
            #"{"addons":[],"vortx":{"ownerWatched":{}}}"#,
            #"{"addons":[],"vortx":{"deletedProfiles":[]}}"#,
            #"{"addons":[],"webProgress":{"byProfile":{"p":{}}}}"#,
            #"{"addons":[],"webProgress":{"removed":{"byProfile":{"p":[]}}}}"#,
            #"{"future":1}"#
        ] {
            let raw = Data(forbidden.utf8)
            let existing = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
            let rejected = try NativeWebsiteAccountAdoption(existing, plaintext: raw, revision: 8)
            check(rejected == nil, "known ownership carrier or missing website evidence refuses synthetic owner")
        }
        let noKey = fresh(); noKey.dataKey = nil; await noKey.expectAdmission(.keyUnavailable)
        let short = fresh(); short.dataKey = Data(count: 31); await short.expectAdmission(.invalidKey)
        let noOwner = fresh(); resolvedRoster = .init(profiles: []); await noOwner.expectAdmission(.ownersUnavailable)
        let twoOwners = fresh(); resolvedRoster = .init(profiles: [owner, owner]); await twoOwners.expectAdmission(.ownersUnavailable)
        let noSelection = fresh(); ProfileStore.shared.activeID = nil; await noSelection.expectAdmission(.selectionUnavailable)
        let failed = fresh(); await failed.expectAdmission(.accountDocumentUnavailable, pulled: .failed(retryable: false))
        await failed.expectAdmission(.unexpectedUnchanged, pulled: .unchanged(version: 1))
        let seen = fresh(); Keychain.backend.values[seen.slot] = "1"; await seen.expectAdmission(.backupAlreadySeen, pulled: .empty)
        check(seen.seedCalls == 0, "known backup never seeds")
        let unavailable = fresh(); Keychain.backend.failedReads.insert(unavailable.slot)
        await unavailable.expectAdmission(.backupHistoryUnavailable, pulled: .empty)
        check(unavailable.seedCalls == 0, "failed floor lookup never seeds")
        for (target, invalidation) in [("future-target-format", "invalidated"), ("1", "future-marker-format")] {
            let hidden = fresh()
            Keychain.backend.values[hidden.slot] = target
            Keychain.backend.values["invalidation:" + hidden.slot] = invalidation
            let original = Keychain.backend.values
            check(!hidden.rememberNativeBackup(capture: hidden.credentialAuthority.capture()), "hidden or unknown bytes cannot acknowledge authenticated document")
            await hidden.expectAdmission(.backupHistoryUnavailable, pulled: .empty)
            check(hidden.seedCalls == 0 && hidden.lastSyncedVersion == 0 && Keychain.backend.writes.isEmpty
                  && Keychain.backend.values == original, "later404 preserves all unknown bytes without seed/ACK/stamp")
        }
        let observed = fresh(); Keychain.backend.failedWrites.insert("invalidation:" + observed.slot)
        check(!observed.rememberNativeBackup(capture: observed.credentialAuthority.capture()), "authenticated observation could not persist")
        await observed.expectAdmission(.backupHistoryUnavailable, pulled: .empty)
        check(observed.seedCalls == 0, "later authenticated404 cannot erase an observed backup")
        let install = fresh(); VortxNativeInstallationKey.unavailable = true
        await install.expectAdmission(.emptyBootstrapRejected, pulled: .empty)
        let rejected = fresh(); rejected.seedThrows = true; await rejected.expectAdmission(.emptySeedRejected, pulled: .empty)
        let unconfirmed = fresh(); unconfirmed.seedDocument = nil; await unconfirmed.expectAdmission(.emptySeedUnconfirmed, pulled: .empty)
        let empty = fresh()
        _ = try await empty.nativeRestoreDocument(.empty, capture: empty.credentialAuthority.capture(),
            selectedProfile: ProfileStore.shared.activeID, generation: empty.nativeCheckpointGeneration, cloudAuthority: .init())
        check(empty.seedCalls == 1, "confirmed absent authenticated-empty path retains seed attempt")
        let replaced = fresh(); replaced.whileSeeding = { replaced.credentialAuthority.replace("other"); replaced.credentialAuthority.replace("fixture-account") }
        await replaced.expectAdmission(.superseded, pulled: .empty)
        let selection = fresh(); selection.whileSeeding = { ProfileStore.shared.activeID = UUID() }
        await selection.expectAdmission(.superseded, pulled: .empty)
        let generation = fresh(); generation.whileSeeding = { generation.nativeCheckpointGeneration = UUID() }
        await generation.expectAdmission(.superseded, pulled: .empty)
        let cancelled = fresh()
        await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await cancelled.expectAdmission(.cancelled)
        }.value
    }
    static func pullCases() async {
        let encoded = Data("{}".utf8).base64EncodedString()
        let cases: [(Int, [String: Any]?, String)] = [
            (200, nil, "response_invalid"), (200, [:], "document_missing"),
            (200, ["document": ""], "document_missing"),
            (200, ["document": encoded, "version": true], "version_invalid"),
            (200, ["document": encoded, "version": 0.5], "version_invalid"),
            (200, ["document": "not-base64", "version": 1], "document_open_refused"),
            (200, ["document": Data(#"{"nativeSync":null}"#.utf8).base64EncodedString(), "version": 1],
                "owner_history_admission_failed"),
            (304, nil, "conditional_response_invalid")]
        for (status, body, reason) in cases {
            let f = fresh(); f.reply = (status, body)
            let pulled = await f.pullDocVersionedResult()
            if case .failed(retryable: false) = pulled {} else { preconditionFailure("deterministic pull must fail") }
            check(DiagnosticsLog.messages.last?.hasSuffix("reason=" + reason) == true, "fixed pull reason: " + reason)
            check(f.seedCalls == 0 && f.lastSyncedVersion == 0 && Keychain.backend.writes.isEmpty, "failed pull has no seed/ACK/stamp")
        }
        let marker = fresh(); marker.reply = (200, ["document": encoded, "version": 1])
        Keychain.backend.failedWrites.insert("invalidation:" + marker.slot)
        if case .failed(retryable: false) = await marker.pullDocVersionedResult() {} else { preconditionFailure("marker failure") }
        check(DiagnosticsLog.messages.last?.hasSuffix("reason=backup_marker_unavailable") == true, "marker failure has terminal pull reason")
        marker.reply = (404, nil)
        let absentAfterObservation = await marker.pullDocVersionedResult()
        await marker.expectAdmission(.backupHistoryUnavailable, pulled: absentAfterObservation)
        let nilKey = fresh(); nilKey.dataKey = nil
        _ = await nilKey.pullDocVersionedResult()
        check(nilKey.requests == 0 && DiagnosticsLog.messages.last?.hasSuffix("reason=data_key_unavailable") == true, "no-key refusal diagnosed before request")
        let stale = fresh(); let capture = stale.credentialAuthority.capture(); stale.credentialAuthority.replace("other")
        _ = await stale.pullDocVersionedResult(credentialCapture: capture)
        check(stale.requests == 0 && DiagnosticsLog.messages.last?.hasSuffix("reason=superseded") == true, "stale capture rejected before request")
        let aba = fresh(); aba.whileReading = { aba.credentialAuthority.replace("other"); aba.credentialAuthority.replace("fixture-account") }
        _ = await aba.pullDocVersionedResult()
        check(DiagnosticsLog.messages.last?.hasSuffix("reason=superseded") == true && Keychain.backend.writes.isEmpty, "same-account ABA cannot record receipt")
        for status in [0, 500, 401] {
            let f = fresh(); f.reply = (status, nil)
            if case .failed(let retryable) = await f.pullDocVersionedResult() { check(retryable == (status != 401), "retryability retained") }
            else { preconditionFailure("transport status must fail") }
        }
        let conditional = fresh(); conditional.reply = (304, nil); conditional.responseETag = "\"7\""
        if case .unchanged(version: 7) = await conditional.pullDocVersionedResult(ifNoneMatch: 7) {} else { preconditionFailure("valid304 preserved") }
        check(Keychain.backend.writes.isEmpty, "unchanged response does not manufacture history")
        let good = fresh(); good.reply = (200, ["document": encoded, "version": 1])
        if case .doc(_, 1, let plaintext, _) = await good.pullDocVersionedResult() {
            check(plaintext == Data("{}".utf8), "versioned pull carries the decrypted original bytes")
        } else { preconditionFailure("valid pull") }
        check(Keychain.confirmedString(good.slot) == .value("1"), "accepted pull requires certified receipt")
        let exact = fresh()
        let raw = Data(#"{ "unknown":9007199254740991, "negativeZero":-0.0, "nested":{"later":1e-99} }"#.utf8)
        exact.reply = (200, ["document": raw.base64EncodedString(), "version": 1])
        if case .doc(_, 1, let plaintext, _) = await exact.pullDocVersionedResult() {
            check(plaintext == raw, "raw numeric lexemes and whitespace survive the actual pull boundary")
        } else { preconditionFailure("valid exact pull") }
        let typed = fresh()
        let nativeRaw = Data(#"{ "nativeSync":{"schemaVersion":6,"ownerHistory":{"future":9007199254740993}}, "nativeOwnerHistorySources":{"future":-0.0} }"#.utf8)
        typed.reply = (200, ["document": nativeRaw.base64EncodedString(), "version": 1])
        let decodedBefore = decodedHostDocuments
        if case .ownerHistory(let plaintext, 1, let observation) = await typed.pullDocVersionedResult() {
            check(plaintext == nativeRaw && decodedHostDocuments == decodedBefore,
                "typed source classification bypasses the host decoder and retains exact original numbers")
            try! Self.xperienceExportObservation.withCurrent(observation) {}
            Self.xperienceExportObservation.observe()
            do { try Self.xperienceExportObservation.withCurrent(observation) {}; preconditionFailure("old pull observation revived") } catch {}
            await typed.expectAdmission(.accountDocumentUnavailable,
                pulled: .ownerHistory(plaintext: plaintext, version: 1, observation: observation))
            check(typed.seedCalls == 0, "typed response cannot enter a generic mount or empty seed fallback")
        } else { preconditionFailure("typed route was not retained") }
    }
    static func accountDataProbeCases() async {
        let storedDocuments = [#"{"addons":[]}"#, #"{"webProgress":{"owner":[]}}"#,
            #"{"vortx":{"roster":[]}}"#, "{}",
            #"{"nativeSync":{"schemaVersion":6,"ownerHistory":{}}}"#]
        for document in storedDocuments {
            let f = fresh()
            f.reply = (200, ["document": Data(document.utf8).base64EncodedString(), "version": 7])
            let probe = await f.accountHasSyncData()
            check(probe == .hasData && f.requests == 1 && f.seedCalls == 0,
                  "authenticated stored account data takes the existing-account path")
        }
        let absent = fresh()
        let absentProbe = await absent.accountHasSyncData()
        check(absentProbe == .empty && absent.requests == 1, "authenticated absence can seed")
        for status in [0, 304, 401, 500] {
            let f = fresh(); f.reply = (status, nil)
            let probe = await f.accountHasSyncData()
            check(probe == .unreachable, "failed or unsolicited conditional response cannot seed")
        }
        let stale = fresh(); stale.lastSyncedVersion = 8
        stale.reply = (200, ["document": Data("{}".utf8).base64EncodedString(), "version": 7])
        let staleProbe = await stale.accountHasSyncData()
        check(staleProbe == .unreachable, "older stored account revision is not sign-in evidence")
        let replaced = fresh()
        replaced.whileReading = { replaced.credentialAuthority.replace("other") }
        let replacedProbe = await replaced.accountHasSyncData()
        check(replacedProbe == .unreachable, "absence cannot seed a replacement sign-in")
        let rekeyed = fresh()
        rekeyed.whileReading = { rekeyed.dataKey = Data(repeating: 1, count: 32) }
        let rekeyedProbe = await rekeyed.accountHasSyncData()
        check(rekeyedProbe == .unreachable, "absence cannot seed using a replacement data key")
    }
    static func run() async throws {
        markerCases(); try await admissionCases(); await pullCases(); await accountDataProbeCases()
        try NativeWebsiteRosterPublicationReceiptTests.run()
        print("Native restore admission: \(checks) focused checks passed; no device/login or full mount proof")
    }
}
@main private enum NativeRestoreAdmissionTests {
    @MainActor static func main() async throws { try await RestoreAdmissionFixture.run() }
}
