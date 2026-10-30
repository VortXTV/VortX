import Foundation

@MainActor final class CredentialScopeRegistry {
    struct Capture: Equatable, Hashable, Sendable { let generation: UInt64 }
    private(set) var generation: UInt64 = 1
    func capture() -> Capture { Capture(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { capture.generation == generation }
    func replace() { generation += 1 }
}

enum CredentialScope {
    case account(UUID)
    init?(canonicalRemoteAccountID rawValue: String) {
        guard let id = UUID(uuidString: rawValue), rawValue == id.uuidString.lowercased() else { return nil }
        self = .account(id)
    }
}

enum CredentialMutationResult { case success, failure }
@MainActor final class SourceIndexLifecycleScope {
    static let shared = SourceIndexLifecycleScope()
    func sessionWillMutate() {}
}

@MainActor enum ProfileRosterSyncPolicy {
    static func validClock(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber else { return nil }
        return number.doubleValue
    }
}

@MainActor enum DiagnosticsLog {
    static var messages: [String] = []
    static func log(_ category: String, _ message: String) { messages.append("\(category):\(message)") }
}

@MainActor struct VortxNativeOwnerHistoryIngress {
    static let shared = VortxNativeOwnerHistoryIngress()
    func requiresTypedRoute(_ plaintext: Data) async throws -> Bool { false }
}

@MainActor final class XperienceObservationFixture {
    private(set) var current = UUID()
    func observe() -> UUID { current = UUID(); return current }
    func withCurrent<T>(_ id: UUID, _ body: () throws -> T) throws -> T {
        guard id == current else { throw FixtureError.superseded }
        return try body()
    }
}

enum FixtureError: Error { case superseded }
enum ObservedPull: Equatable, Sendable { case doc, ownerHistory, unchanged(Int), empty, failed(Bool) }

@MainActor final class CoreBridge {
    static let shared = CoreBridge()
    var certifiedCaptures = Set<CredentialScopeRegistry.Capture>()
    func hasCertifiedNativeSession(capture: CredentialScopeRegistry.Capture, profileID: UUID) -> Bool {
        certifiedCaptures.contains(capture)
    }
}

@MainActor final class ProfileStore {
    static let shared = ProfileStore()
    var activeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

@MainActor final class AuthRecoveryFixture {
    enum Reply {
        case immediate(status: Int, body: [String: Any]?, etag: String? = nil)
        case hold
    }
    struct AuthOperationCapture: Equatable, Sendable {
        let generation: UInt64
        let credential: CredentialScopeRegistry.Capture
    }
    let credentialAuthority = CredentialScopeRegistry()
    var dataKey: Data? = Data(repeating: 7, count: 32)
    var lastSyncedVersion = 0
    var isSignedIn = true
    var accountReconnectFailureCapture: CredentialScopeRegistry.Capture?
    var account: Account? = Account(id: "acct-original", email: "member@example.invalid", username: "member")
    var token: String? = "stored-session-token"
    var accountRestoreState: AccountRestoreState = .idle
    var restoreTask: Task<Bool, Never>?
    var restoreTaskCapture: CredentialScopeRegistry.Capture?
    var authOperationGeneration: UInt64 = 4
    var hasAppliedAccountDoc = false
    var pendingDocCaptures = Set<CredentialScopeRegistry.Capture>()
    var pendingPushes = false
    var requests: [(method: String, path: String, auth: Bool, bearer: String?, capture: CredentialScopeRegistry.Capture?, ifNoneMatch: Int?)] = []
    var replies: [Reply] = []
    var pushes = 0
    var nativeBackupMarks = 0
    var openDocumentCalls = 0
    var restoreSyncDownCalls = 0
    var persistCalls = 0
    var ownerAcquisitionCalls = 0
    var lateAuthMarkerDuringOwnerAcquisition = false
    var changeKeyDuringOwnerAcquisition = false
    var heldRequest: CheckedContinuation<(Int, [String: Any]?, String?), Never>?
    static let xperienceExportObservation = XperienceObservationFixture()

    struct Account: Equatable {
        let id: String
        let email: String
        let username: String
        var twoFactorEnabled = false
    }
    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { credentialAuthority.isCurrent(capture) }
    func request(_ method: String, _ path: String, body: [String: Any]? = nil, auth: Bool = false,
                 bearer: String? = nil, credentialCapture: CredentialScopeRegistry.Capture? = nil,
                 ifNoneMatch: Int? = nil, receiveETag: ((String?) -> Void)? = nil) async -> (Int, [String: Any]?) {
        requests.append((method, path, auth, bearer, credentialCapture, ifNoneMatch))
        guard !replies.isEmpty else { preconditionFailure("fixture response missing") }
        switch replies.removeFirst() {
        case .immediate(let status, let body, let etag): receiveETag?(etag); return (status, body)
        case .hold:
            let result = await withCheckedContinuation { heldRequest = $0 }
            receiveETag?(result.2); return (result.0, result.1)
        }
    }
    func releaseHeldRequest(status: Int, body: [String: Any]? = nil, etag: String? = nil) {
        guard let held = heldRequest else { preconditionFailure("no held pull") }
        heldRequest = nil
        held.resume(returning: (status, body, etag))
    }
    func openSyncDocument(_ stored: String, version: Int) -> Data? { openDocumentCalls += 1; return Data(stored.utf8) }
    static func decodeDecryptedSyncDocument(_ plaintext: Data) throws -> [String: Any] { ["decoded": true] }
    func rememberNativeBackup(capture: CredentialScopeRegistry.Capture) -> Bool { nativeBackupMarks += 1; return isCurrent(capture) }
    func hasPendingAccountDocApply(for capture: CredentialScopeRegistry.Capture) -> Bool { pendingDocCaptures.contains(capture) }
    func ensureNativeCheckpoint(credentialCapture capture: CredentialScopeRegistry.Capture) async -> Bool {
        CoreBridge.shared.hasCertifiedNativeSession(capture: capture, profileID: ProfileStore.shared.activeID)
    }
    func syncDown(force: Bool, credentialCapture capture: CredentialScopeRegistry.Capture) async -> Bool {
        precondition(force)
        restoreSyncDownCalls += 1
        switch await pullDocVersionedResult(credentialCapture: capture) {
        case .doc, .ownerHistory, .empty, .unchanged:
            hasAppliedAccountDoc = true
            return true
        case .failed:
            return false
        }
    }
    func requestSyncSoon() { pushes += 1 }
    func syncUp() async -> Bool { pushes += 1; return false }
    func replaceCredentialGeneration() { credentialAuthority.replace() }
    func currentCredentialOwnerIntent() -> AuthOperationCapture {
        AuthOperationCapture(generation: authOperationGeneration, credential: credentialAuthority.capture())
    }
    func isCurrent(_ operation: AuthOperationCapture) -> Bool {
        operation.generation == authOperationGeneration && credentialAuthority.isCurrent(operation.credential)
    }
    func acquireCredentialOwner(scope: CredentialScope, operation: String, fence: AuthOperationCapture,
                               certifying: @escaping @MainActor () -> CredentialMutationResult) async
      -> CredentialScopeRegistry.Capture? {
        ownerAcquisitionCalls += 1
        if lateAuthMarkerDuringOwnerAcquisition { accountReconnectFailureCapture = fence.credential }
        if changeKeyDuringOwnerAcquisition { dataKey = Data(repeating: 8, count: 32) }
        guard case .success = certifying() else { return nil }
        return fence.credential
    }
    func persist(token: String, account: Account, dataKey: Data) -> CredentialMutationResult {
        persistCalls += 1
        return .success
    }
    func establishCredentialOwner(_ capture: CredentialScopeRegistry.Capture) -> Bool { isCurrent(capture) }
    func reloadLastSyncStamp() {}
    func stopRealtime() {}
    func startRealtime() {}
    func hydrateEngineFromOwnedAddons(credentialCapture: CredentialScopeRegistry.Capture) async {}
}

@MainActor extension AuthRecoveryFixture {
    func exercisePull(credentialCapture: CredentialScopeRegistry.Capture? = nil,
                      ifNoneMatch: Int? = nil) async -> ObservedPull {
        switch await pullDocVersionedResult(credentialCapture: credentialCapture, ifNoneMatch: ifNoneMatch) {
        case .doc: return .doc
        case .ownerHistory: return .ownerHistory
        case .unchanged(let version): return .unchanged(version)
        case .empty: return .empty
        case .failed(let retryable): return .failed(retryable)
        }
    }
    func exerciseAdopt(token: String, account: [String: Any], dataKey: Data,
                       expectedOperation: AuthOperationCapture? = nil) async -> Bool {
        await adopt(token: token, account: account, dataKey: dataKey, expectedOperation: expectedOperation)
    }
}

@main @MainActor enum AuthRecoveryTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ label: String) {
        guard condition else { fatalError("FAIL: \(label)") }
        checks += 1
        print("PASS: \(label)")
    }
    static func current401IsTerminalAndRestoreDoesNotSeed() async {
        let manager = AuthRecoveryFixture()
        manager.replies = [.immediate(status: 401, body: nil)]
        let capture = manager.credentialAuthority.capture()
        let result = await manager.exercisePull(credentialCapture: capture)
        switch result {
        case .failed(let retryable): expect(!retryable, "current 401 is deterministic")
        default: expect(false, "current 401 must fail, never look empty")
        }
        expect(manager.accountReconnectRequired && manager.accountReconnectFailureCapture == capture,
               "401 marks only the exact currently adopted credential capture")
        expect(manager.requests.count == 1 && manager.requests[0].auth && manager.requests[0].bearer == nil
               && manager.requests[0].capture == capture,
               "backup request uses stored adopted-session auth, no one-off bearer, and original capture")
        expect(manager.openDocumentCalls == 0 && manager.nativeBackupMarks == 0,
               "401 cannot decrypt, mark a backup, or imply an empty account")

        let restoring = AuthRecoveryFixture()
        restoring.replies = [.immediate(status: 401, body: nil)]
        let restoreCapture = restoring.credentialAuthority.capture()
        restoring.pendingDocCaptures.insert(restoreCapture)
        restoring.pendingPushes = true
        let ready = await restoring.restoreAccountDocIfNeeded(credentialCapture: restoreCapture)
        expect(!ready && restoring.restoreSyncDownCalls == 1 && restoring.requests.count == 1,
               "restore stops after one current 401 instead of retrying the rejected credential")
        expect(restoring.accountRestoreState == .failed && !restoring.hasAppliedAccountDoc,
               "401 leaves restore failed and does not seed the account-document gate")
        expect(restoring.pushes == 0 && restoring.pendingDocCaptures.contains(restoreCapture) && restoring.pendingPushes,
               "401 issues no empty-account push and leaves original pending state intact")
    }
    static func superseded401CannotRejectSuccessor() async {
        let manager = AuthRecoveryFixture()
        let original = manager.credentialAuthority.capture()
        manager.replies = [.hold]
        let task = Task { @MainActor in await manager.exercisePull(credentialCapture: original) }
        while manager.requests.isEmpty { await Task.yield() }
        manager.replaceCredentialGeneration()
        manager.releaseHeldRequest(status: 401)
        if case .failed(let retryable) = await task.value {
            expect(!retryable, "late superseded 401 returns deterministic failure to its old caller")
        } else { expect(false, "late superseded 401 returns failure") }
        expect(manager.accountReconnectFailureCapture == nil,
               "a superseded response cannot publish a reconnect requirement for the successor")
    }
    static func rejectedSessionReconnectPreservesOnlySameAccountKey() async {
        let id = "00000000-0000-0000-0000-00000000000a"
        let originalKey = Data(repeating: 7, count: 32)
        let candidate: [String: Any] = ["id": id, "email": "member@example.invalid", "username": "member"]

        let wrongAccount = AuthRecoveryFixture()
        wrongAccount.account = AuthRecoveryFixture.Account(id: id, email: "member@example.invalid", username: "member")
        wrongAccount.accountReconnectFailureCapture = wrongAccount.credentialAuthority.capture()
        let wrong = await wrongAccount.exerciseAdopt(token: "new", account: ["id": "00000000-0000-0000-0000-00000000000b",
            "email": "other@example.invalid", "username": "other"], dataKey: originalKey,
            expectedOperation: wrongAccount.currentCredentialOwnerIntent())
        expect(!wrong && wrongAccount.persistCalls == 0 && wrongAccount.ownerAcquisitionCalls == 0,
               "rejected session cannot persist a different account")

        let wrongKey = AuthRecoveryFixture()
        wrongKey.account = AuthRecoveryFixture.Account(id: id, email: "member@example.invalid", username: "member")
        wrongKey.dataKey = originalKey
        wrongKey.accountReconnectFailureCapture = wrongKey.credentialAuthority.capture()
        let keyMismatch = await wrongKey.exerciseAdopt(token: "new", account: candidate,
            dataKey: Data(repeating: 9, count: 32), expectedOperation: wrongKey.currentCredentialOwnerIntent())
        expect(!keyMismatch && wrongKey.persistCalls == 0 && wrongKey.ownerAcquisitionCalls == 0,
               "rejected session cannot replace its data key")

        let sameOwner = AuthRecoveryFixture()
        sameOwner.account = AuthRecoveryFixture.Account(id: id, email: "member@example.invalid", username: "member")
        sameOwner.dataKey = originalKey
        let sameOwnerCapture = sameOwner.credentialAuthority.capture()
        sameOwner.accountReconnectFailureCapture = sameOwnerCapture
        sameOwner.hasAppliedAccountDoc = true
        CoreBridge.shared.certifiedCaptures.insert(sameOwnerCapture)
        let operationForSame = sameOwner.currentCredentialOwnerIntent()
        let accepted = await sameOwner.exerciseAdopt(token: "replacement", account: candidate, dataKey: originalKey,
            expectedOperation: operationForSame)
        expect(accepted && sameOwner.persistCalls == 1 && sameOwner.accountReconnectFailureCapture == nil,
               "same rejected account and data key can reconnect and clear the marker")

        let crossedAccount = AuthRecoveryFixture()
        crossedAccount.account = AuthRecoveryFixture.Account(id: id, email: "member@example.invalid", username: "member")
        crossedAccount.dataKey = originalKey
        crossedAccount.lateAuthMarkerDuringOwnerAcquisition = true
        let otherCandidate: [String: Any] = ["id": "00000000-0000-0000-0000-00000000000b",
            "email": "other@example.invalid", "username": "other"]
        let otherAccepted = await crossedAccount.exerciseAdopt(token: "replacement", account: otherCandidate,
            dataKey: originalKey, expectedOperation: crossedAccount.currentCredentialOwnerIntent())
        expect(!otherAccepted && crossedAccount.persistCalls == 0 && crossedAccount.ownerAcquisitionCalls == 1,
               "a late 401 refuses another account even when its candidate data key is unchanged")

        let crossedOwner = AuthRecoveryFixture()
        crossedOwner.account = AuthRecoveryFixture.Account(id: id, email: "member@example.invalid", username: "member")
        crossedOwner.dataKey = originalKey
        crossedOwner.lateAuthMarkerDuringOwnerAcquisition = true
        crossedOwner.changeKeyDuringOwnerAcquisition = true
        let late = await crossedOwner.exerciseAdopt(token: "replacement", account: candidate, dataKey: originalKey,
            expectedOperation: crossedOwner.currentCredentialOwnerIntent())
        expect(!late && crossedOwner.persistCalls == 0,
               "a 401 arriving during owner acquisition is rechecked before persistence")
    }
    static func statusClassificationAndRecoveryClear() async {
        let forbidden = AuthRecoveryFixture()
        forbidden.replies = [.immediate(status: 403, body: nil)]
        if case .failed(let retryable) = await forbidden.exercisePull() {
            expect(!retryable && !forbidden.accountReconnectRequired, "403 is deterministic but is not classified as backup 401")
        } else { expect(false, "403 returns failure") }

        let serverFault = AuthRecoveryFixture()
        serverFault.replies = [.immediate(status: 503, body: nil)]
        if case .failed(let retryable) = await serverFault.exercisePull() {
            expect(retryable && !serverFault.accountReconnectRequired, "5xx remains retryable and does not set reconnect marker")
        } else { expect(false, "5xx returns failure") }

        let recovered = AuthRecoveryFixture()
        let capture = recovered.credentialAuthority.capture()
        recovered.accountReconnectFailureCapture = capture
        recovered.replies = [.immediate(status: 304, body: nil, etag: "\"12\"")]
        if case .unchanged(12) = await recovered.exercisePull(credentialCapture: capture, ifNoneMatch: 12) {
            expect(!recovered.accountReconnectRequired, "valid matching 304 clears the exact capture marker")
        } else { expect(false, "valid matching 304 returns unchanged") }

        let absent = AuthRecoveryFixture()
        let absentCapture = absent.credentialAuthority.capture()
        absent.accountReconnectFailureCapture = absentCapture
        absent.replies = [.immediate(status: 404, body: nil)]
        if case .empty = await absent.exercisePull(credentialCapture: absentCapture) {
            expect(!absent.accountReconnectRequired, "authenticated 404 clears marker as definitive absence")
        } else { expect(false, "404 returns definitive empty") }
    }
    static func main() async {
        await current401IsTerminalAndRestoreDoesNotSeed()
        await superseded401CannotRejectSuccessor()
        await rejectedSessionReconnectPreservesOnlySameAccountKey()
        await statusClassificationAndRecoveryClear()
        print("PASS: \(checks) auth-recovery source checks")
    }
}
