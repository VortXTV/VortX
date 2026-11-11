import Foundation
import CoreFoundation

private enum CredentialScopeRegistry {
    struct Capture: Equatable { let generation: Int }
}
@MainActor private final class Authority {
    var generation = 1
    func capture() -> CredentialScopeRegistry.Capture { .init(generation: generation) }
}
@MainActor private enum DiagnosticsLog {
    static var messages: [String] = []
    static func log(_ category: String, _ message: String) { messages.append(message) }
}
@MainActor private final class UploadHarness {
    // These existing fixtures do not run a concurrent account-file restore.
    var accountFileRestoreBusy = false
    struct Account { let id: String }
    let credentialAuthority = Authority()
    var account: Account? = Account(id: "synthetic-account-" + UUID().uuidString)
    var dataKey: Data? = Data(repeating: 1, count: 32)
    static let writeSyncDocV2 = false
    var pendingApply = false
    var accountReconnectFailureCapture: CredentialScopeRegistry.Capture?
    var backupUploadFailure: SyncBackupUploadFailure?
    var lastSyncedVersion = 9
    var backupCount = 0
    var providerReceiptCount = 0
    var successCount = 0
    var persistenceCount = 0
    var receiptFails = false
    var backupFails = false
    var sourceCurrent = true
    var sentBodies: [[String: Any]] = []
    var reply: (Int, [String: Any]?) = (400, ["error": "bad_request"])
    var readReply: (Int, [String: Any]?) = (404, nil)
    var whileReading: (() -> Void)?
    var whileSending: (() -> Void)?
    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { capture == credentialAuthority.capture() }
    func hasPendingAccountDocApply(for capture: CredentialScopeRegistry.Capture) -> Bool { pendingApply }
    func request(_ method: String, _ path: String, body: [String: Any]? = nil, auth: Bool,
                 credentialCapture: CredentialScopeRegistry.Capture, ifNoneMatch: Int? = nil,
                 receiveETag: ((String?) -> Void)? = nil) async -> (Int, [String: Any]?) {
        if method == "GET" { whileReading?(); return readReply }
        precondition(method == "PUT" && path == "/v1/backup" && auth)
        let body = body!
        precondition(body["document"] is String)
        sentBodies.append(body)
        whileSending?()
        return reply
    }
    func rememberNativeBackup(capture: CredentialScopeRegistry.Capture) -> Bool { backupCount += 1; return !backupFails }
    func acknowledgeNativeProviders(_ document: [String: Any], capture: CredentialScopeRegistry.Capture) throws {
        providerReceiptCount += 1
        if receiptFails { throw NSError(domain: "fixture", code: 1) }
    }
    func persistLastSyncedVersion() { persistenceCount += 1 }
    func stampSyncSuccess() { successCount += 1 }
    static var versionBoundAccounts: Set<String> = []
    static func sawDocV2(_ accountID: String) -> Bool { versionBoundAccounts.contains(accountID) }
    static func markSawDocV2(_ accountID: String) { versionBoundAccounts.insert(accountID) }
    func accountReconnectRequired(for capture: CredentialScopeRegistry.Capture) -> Bool { accountReconnectFailureCapture == capture }
    func clearAccountReconnectFailure(for capture: CredentialScopeRegistry.Capture) {
        if accountReconnectFailureCapture == capture { accountReconnectFailureCapture = nil }
    }
    func pullDocument() async -> [String: Any]? {
        guard case .doc(let doc, _, _, _) = await pullDocVersionedResult() else { return nil }
        return doc
    }
    func supplyBackup(_ bytes: Data, version: Int = 9, writeV2: Bool = true) {
        let sealed = VortXSyncCrypto.sealDocument(dataKey: dataKey!, plaintext: bytes,
            accountId: account!.id, version: version, writeV2: writeV2)!
        readReply = (200, ["version": version, "document": sealed])
    }
    func seedAfterRead() async -> String {
        guard case .empty = await pullDocVersionedResult() else { return "no-seed" }
        return await send(base: nil, version: 0)
    }
    static func documentVersion(_ raw: Any?) -> Int? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue >= 0, n.doubleValue <= Double(SyncDocumentRevisionPolicy.maximumSafeRevision),
              n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
        return n.intValue
    }
    func send(base: Int? = 9, version: Int = 10) async -> String {
        switch await pushSyncDocAt(["synthetic": String(repeating: "x", count: 1_267_400)], version: version,
                                  baseRevision: base, sourceIsCurrent: { self.sourceCurrent }) {
        case .accepted: return "accepted"
        case .rejected: return "rejected"
        case .error: return "error"
        case .upgradeRequired: return "upgrade"
        }
    }
    /* PRODUCTION_UPLOAD */
}

@main @MainActor private enum UploadTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), label); checks += 1
    }
    static func main() async {
        for (status, body) in [(200, ["document": NSNull(), "version": 0] as [String: Any]),
                               (401, [:]), (403, [:]), (503, [:]), (200, ["document": "bad", "version": 0])] {
            let h = UploadHarness(); h.readReply = (status, body); h.reply = (200, ["accepted": true])
            let outcome = await h.seedAfterRead()
            expect(outcome == "no-seed" && h.sentBodies.isEmpty, "only authenticated404 may produce create witness;200null/failure/existing-zero cannot seed")
        }
        let existingZero = UploadHarness()
        existingZero.supplyBackup(Data("{}".utf8), version: 0, writeV2: false)
        let existingZeroOutcome = await existingZero.seedAfterRead()
        expect(existingZeroOutcome == "no-seed" && existingZero.sentBodies.isEmpty && existingZero.backupCount == 1,
               "an authenticated existing revision zero is not an absent account")
        let absent = UploadHarness(); absent.reply = (200, ["accepted": true])
        let absentOutcome = await absent.seedAfterRead()
        expect(absentOutcome == "accepted" && absent.sentBodies[0]["baseRevision"] is NSNull && absent.sentBodies[0]["version"] as? Int == 0,
               "actual authenticated404 creates explicit null base and versionzero")
        let retiredRead = UploadHarness(); retiredRead.whileReading = { retiredRead.credentialAuthority.generation += 1 }
        let retiredReadOutcome = await retiredRead.seedAfterRead()
        expect(retiredReadOutcome == "no-seed" && retiredRead.sentBodies.isEmpty, "retired authenticated read cannot seed another credential scope")
        for (status, code, expected) in [(413, nil, SyncBackupUploadFailure.tooLarge),
                                       (400, "document_too_large", .tooLarge),
                                       (400, "request_too_large", .tooLarge),
                                       (400, "bad_version", .invalidRevision),
                                       (400, "bad_request", .serverRejected),
                                       (400, "secret-token@example.com", .serverRejected),
                                       (401, nil, .authorization), (403, nil, .authorization),
                                       (0, nil, .unavailable), (500, nil, .unavailable)] {
            let harness = UploadHarness()
            harness.reply = (status, code.map { ["error": $0] })
            let outcome = await harness.send()
            expect(outcome == "error" && harness.backupUploadFailure == expected, "classified transport failure")
            expect(harness.lastSyncedVersion == 9 && harness.successCount == 0 && harness.persistenceCount == 0,
                   "failed upload cannot advance revision or last-sync time")
            expect(harness.backupCount == 0 && harness.providerReceiptCount == 0, "failed upload cannot ACK native evidence")
            expect(!DiagnosticsLog.messages.last!.contains("secret-token"), "server text cannot leak through logs")
            expect(DiagnosticsLog.messages.last!.contains("ciphertextBytes="), "transport diagnostic includes only safe size/category")
        }
        let accepted = UploadHarness()
        accepted.backupUploadFailure = .tooLarge
        accepted.reply = (200, ["accepted": true])
        let acceptedOutcome = await accepted.send()
        expect(acceptedOutcome == "accepted" && accepted.backupUploadFailure == nil, "durably accepted retry clears error")
        expect(accepted.lastSyncedVersion == 10 && accepted.successCount == 1 && accepted.persistenceCount == 1,
               "only durable acceptance records sync success")
#if VORTX_NATIVE_DATA_ENGINE
        expect(accepted.backupCount == 1 && accepted.providerReceiptCount == 1, "accepted payload persists both receipts")
#endif
        expect(accepted.sentBodies[0]["baseRevision"] as? Int == 9, "wire witness is exact candidate base")
        expect(!(accepted.sentBodies[0]["document"] as! String).hasPrefix(VortXSyncCrypto.docV2Prefix),
               "existing legacy rollout remains off for an unrelated account")
        let bound = UploadHarness()
        let largeBackup = Data(("{\"foreign\":[null" + String(repeating: ",null", count: 109_999) + "]}").utf8)
        bound.supplyBackup(largeBackup)
        let wrongKey = UploadHarness(); wrongKey.readReply = bound.readReply
        let foreign = await wrongKey.pullDocument()
        expect(foreign == nil && wrongKey.backupCount == 0, "v2 backup cannot open in another account")
        let originalKey = bound.dataKey
        bound.dataKey = Data(repeating: 2, count: 32)
        let corrupt = await bound.pullDocument()
        expect(corrupt == nil && bound.backupCount == 0, "wrong key cannot acknowledge a backup")
        bound.dataKey = originalKey
        let restored = await bound.pullDocument()
        expect((restored?["foreign"] as? [Any])?.count == 110_000, "authenticated large backup reaches the Apple document path")
        bound.reply = (200, ["accepted": true])
        let boundOutcome = await bound.send()
        expect(boundOutcome == "accepted", "ordinary upload after reading a version-bound backup succeeds")
        let ciphertext = bound.sentBodies[0]["document"] as! String
        let id = bound.account!.id, key = bound.dataKey!
        expect(ciphertext.hasPrefix(VortXSyncCrypto.docV2Prefix)
               && VortXSyncCrypto.openDocument(dataKey: key, stored: ciphertext, accountId: id, version: 10) != nil
               && VortXSyncCrypto.openDocument(dataKey: key, stored: ciphertext, accountId: id, version: 11) == nil,
               "replacement preserves the v2 binding to the exact accepted revision")
        bound.supplyBackup(Data("{}".utf8), version: 10, writeV2: false)
        let downgrade = await bound.pullDocument()
        expect(downgrade == nil, "real read path continues refusing downgraded ciphertext")
        bound.readReply = (404, nil)
        let missingBoundHead = await bound.seedAfterRead()
        expect(missingBoundHead == "error" && bound.sentBodies.count == 1,
               "an absent head cannot reseed an account that authenticated v2")
        let create = UploadHarness(); create.reply = (200, ["accepted": true])
        _ = await create.send(base: nil, version: 0)
        expect(create.sentBodies[0]["baseRevision"] is NSNull, "absence is explicit null, never omitted")
        for (base, version) in [(nil, 1), (9, 100), (-1, 0)] as [(Int?, Int)] {
            let invalid = UploadHarness()
            let outcome = await invalid.send(base: base, version: version)
            expect(outcome == "error" && invalid.sentBodies.isEmpty, "invalid proposal refused before transport")
        }
        let upgrade = UploadHarness(); upgrade.reply = (426, ["error": "upgrade_required", "accepted": false])
        let upgradeOutcome = await upgrade.send()
        expect(upgradeOutcome == "upgrade" && upgrade.backupUploadFailure == .upgradeRequired,
               "protected account returns update-needed, not retryable conflict")
        expect(upgrade.lastSyncedVersion == 9 && upgrade.successCount == 0 && upgrade.providerReceiptCount == 0,
               "upgrade-needed cannot stamp success or acknowledge intent")
        expect(upgrade.backupUploadFailure!.message.contains("Update VortX"), "simple actionable update message")

        let conflict = UploadHarness(); conflict.backupUploadFailure = .tooLarge
        conflict.reply = (200, ["accepted": false, "version": 11])
        let rejected = await conflict.send()
        expect(rejected == "rejected" && conflict.lastSyncedVersion == 9 && conflict.backupCount == 0,
               "CAS rejection is not an acknowledgement")
        expect(conflict.backupUploadFailure == .tooLarge, "rejection cannot claim failed backup saved")

        var stages = ["verdict", "missing-verdict", "retired-owner", "pending-restore", "replaced-key", "retired-mount"]
#if VORTX_NATIVE_DATA_ENGINE
        stages += ["backup", "receipt"]
#endif
        for stage in stages {
            let h = UploadHarness(); h.backupUploadFailure = .tooLarge
            h.reply = (200, stage == "verdict" ? ["accepted": 1] : ["accepted": true])
            if stage == "missing-verdict" { h.reply = (200, [:]) }
            h.backupFails = stage == "backup"; h.receiptFails = stage == "receipt"
            if stage == "retired-owner" { h.whileSending = { h.credentialAuthority.generation += 1 } }
            if stage == "pending-restore" { h.whileSending = { h.pendingApply = true } }
            if stage == "replaced-key" { h.whileSending = { h.dataKey = Data([2]) } }
            if stage == "retired-mount" { h.whileSending = { h.sourceCurrent = false } }
            let outcome = await h.send()
            expect(outcome == "error" && h.lastSyncedVersion == 9 && h.successCount == 0,
                   "unproven local or remote completion retains revision")
            expect(h.backupUploadFailure == .tooLarge, "incomplete acceptance retains failed-save status")
        }
        expect(!DiagnosticsLog.messages.joined().contains("synthetic-account"), "diagnostics contain no account identifiers")
        print("Sync backup production upload checks passed: \(checks)")
    }
}
