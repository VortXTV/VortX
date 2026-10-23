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
private enum VortXSyncCrypto {
    static func sealDocument(dataKey: Data, plaintext: Data, accountId: String, version: Int, writeV2: Bool) -> String? {
        // Encryption is a fixture aperture. The production upload/verdict/ACK method is extracted unchanged.
        plaintext.base64EncodedString()
    }
}
@MainActor private final class UploadHarness {
    struct Account { let id = "synthetic-account" }
    let credentialAuthority = Authority()
    var account: Account? = Account()
    var dataKey: Data? = Data([1])
    static let writeSyncDocV2 = false
    var pendingApply = false
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
    static func markSawDocV2(_ accountID: String) { preconditionFailure("v2 writes remain disabled") }
    func openSyncDocument(_ document: String, version: Int) -> Data? { Data(base64Encoded: document) }
    static func decodeDecryptedSyncDocument(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
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
                               (401, [:]), (403, [:]), (503, [:]), (200, ["document": "bad", "version": 0]),
                               (200, ["document": Data("{}".utf8).base64EncodedString(), "version": 0])] {
            let h = UploadHarness(); h.readReply = (status, body); h.reply = (200, ["accepted": true])
            let outcome = await h.seedAfterRead()
            expect(outcome == "no-seed" && h.sentBodies.isEmpty, "only authenticated404 may produce create witness;200null/failure/existing-zero cannot seed")
        }
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
