import Foundation
import CryptoKit

/// EXPLICIT SYNTHETIC collaborators. This fixture proves the unchanged manager's orchestration,
/// not native candidate admission, secure storage, filesystem durability, HTTP or account adoption.
@MainActor
final class RestoreFixtureWorld {
    static var current = RestoreFixtureWorld()
    enum PutBehavior { case accepted, conflict, http409, ambiguousDelivered, ambiguousNotDelivered, throwsDelivered, throwsNotDelivered }
    struct Stored {
        let intent: VortxAccountFileRestore.Intent
        let key: Data
        var verdict: VortxAccountFileRestore.Verdict?
    }
    var currentHead = Data()
    var candidatePlaintext = Data(#"{"fixtureCandidate":true,"unknown":{"value":1.00}}"#.utf8)
    var selectedFile = Data("synthetic file input; admission is a seam".utf8)
    var putBehavior = PutBehavior.accepted
    var getStatus = 200
    var putCount = 0, getCount = 0, prepareCount = 0, absenceCount = 0, retainCount = 0
    var renewalCalls = 0
    var lastRequestBody: Data?
    var entries: [UUID: Stored] = [:]
    var failRetainBefore = false, failRetainAfter = false, failRecord = false
    var absenceRefusal: VortxAccountFileRestoreFailure?
    var preparationRefusal: VortxAccountFileRepairService.Failure?
    var onBoundary: (@MainActor (String) -> Void)?
    var pausedBoundary: String?
    private var visited: Set<String> = []
    private var observers: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func visit(_ boundary: String) async {
        await Task.yield()
        visited.insert(boundary)
        for waiter in observers.removeValue(forKey: boundary) ?? [] { waiter.resume() }
        onBoundary?(boundary)
        if pausedBoundary == boundary {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
    }
    func waitFor(_ boundary: String) async {
        if visited.contains(boundary) { return }
        await withCheckedContinuation { observers[boundary, default: []].append($0) }
    }
    func release() { let waiting = releaseContinuation; releaseContinuation = nil; pausedBoundary = nil; waiting?.resume() }
    func get() async -> (Int, Data) {
        getCount += 1
        await visit("GET.\(getCount)")
        return (getStatus, currentHead) // Deliberately returns even after cancellation/account change.
    }
    func put(_ request: URLRequest, allowedHosts: Set<String>, limit: Int) async throws -> AuthenticatedHTTPResponse {
        precondition(request.httpMethod == "PUT" && request.url?.path == "/v1/backup")
        precondition(allowedHosts == ["api.vortx.tv"] && limit == AuthenticatedHTTPTransport.controlResponseLimit)
        precondition(request.value(forHTTPHeaderField: "authorization")?.hasPrefix("Bearer ") == true)
        putCount += 1; precondition(putCount <= 1, "implicit PUT replay")
        guard let body = request.httpBody else { preconditionFailure("missing exact CAS body") }
        lastRequestBody = body
        let requestFields = try OwnerHistoryExactJSON.Object(body)
        let base = try JSONDecoder().decode(Int.self, from: requestFields.required("baseRevision"))
        let revision = try JSONDecoder().decode(Int.self, from: requestFields.required("version"))
        precondition(revision == base + 1, "invented revision ancestry")
        switch putBehavior {
        case .accepted, .ambiguousDelivered, .throwsDelivered:
            var raw = try OwnerHistoryExactJSON.Object(Data("{}".utf8))
            raw.set("document", try requestFields.required("document")); raw.set("version", try requestFields.required("version"))
            currentHead = try raw.encoded()
        case .conflict, .http409, .ambiguousNotDelivered, .throwsNotDelivered: break
        }
        await visit("PUT") // Models delivery before the return; noncooperative with cancellation.
        switch putBehavior {
        case .accepted: return .init(data: Data(#"{"accepted":true}"#.utf8), statusCode: 200, sessionRenewal: "synthetic-renewed")
        case .conflict: return .init(data: Data(#"{"accepted":false}"#.utf8), statusCode: 200)
        case .http409: return .init(data: Data(#"{"accepted":false}"#.utf8), statusCode: 409)
        case .ambiguousDelivered, .ambiguousNotDelivered: return .init(data: Data(#"{"accepted":"true"}"#.utf8), statusCode: 200)
        case .throwsDelivered, .throwsNotDelivered: throw FixtureError.transport
        }
    }
    enum FixtureError: Error { case transport, journal }
    func prepare(file: Data, response: Data, input: VortxAccountFileRepairService.Input) async throws -> VortxAccountFileRestore.Prepared {
        prepareCount += 1
        let read = try VortxAccountFileRestore.head(response)
        let result = VortxAccountFileRestore.Prepared(selectedFile: file, candidateFile: file,
            plaintext: candidatePlaintext, headResponse: response, headDocument: read.document,
            baseRevision: read.version, scope: .init(account: input.capture.namespace,
                ownerProfileID: RestoreFixtureValues.ownerID.uuidString))
        await visit("worker")
        if let preparationRefusal { throw preparationRefusal }
        return result // No synthetic post-await fence: the actual manager must enforce it.
    }
    func absence(scope: VortxAccountScope, key: Data) async throws {
        absenceCount += 1
        await visit("absence.\(absenceCount)")
        if let absenceRefusal { throw absenceRefusal }
    }
    func unresolved(account: String, key: Data) async throws -> UUID? {
        await visit("journal.unresolved")
        for (id, entry) in entries where entry.intent.accountID == account {
            guard entry.key == key else { throw FixtureError.journal }
            if entry.verdict != .notSubmitted && entry.verdict != .conflict { return id }
        }
        return nil
    }
    func retain(_ intent: VortxAccountFileRestore.Intent, key: Data) async throws {
        retainCount += 1
        if failRetainBefore { throw FixtureError.journal }
        precondition(entries[intent.operationID] == nil, "immutable intent overwritten")
        entries[intent.operationID] = .init(intent: intent, key: key, verdict: nil)
        await visit("journal.retain")
        if failRetainAfter { throw FixtureError.journal }
    }
    func load(account: String, id: UUID, key: Data) async throws -> VortxAccountFileRestore.Intent {
        await visit("journal.load")
        guard let entry = entries[id], entry.intent.accountID == account, entry.key == key else { throw FixtureError.journal }
        return entry.intent
    }
    func record(_ receipt: VortxAccountFileRestore.Receipt, account: String, key: Data) async throws {
        await visit("journal.record.\(receipt.verdict.rawValue)")
        if failRecord { throw FixtureError.journal }
        guard var entry = entries[receipt.operationID], entry.intent.accountID == account, entry.key == key,
              entry.intent.revision == receipt.revision else { throw FixtureError.journal }
        entry.verdict = receipt.verdict; entries[receipt.operationID] = entry
    }
}

enum RestoreFixtureValues {
    static let accountID = "10000000-0000-0000-0000-000000000001"
    static let otherAccountID = "10000000-0000-0000-0000-000000000002"
    static let ownerID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    static let key = Data(repeating: 0x41, count: 32)
    static func head(revision: Int = 24) throws -> Data {
        let sealed = VortXSyncCrypto.sealDocument(dataKey: key, plaintext: Data(#"{"fixturePrior":true}"#.utf8),
            accountId: accountID, version: revision, writeV2: false)!
        return try JSONSerialization.data(withJSONObject: ["document": sealed, "version": revision], options: [.sortedKeys])
    }
}

@MainActor final class CoreBridge {
    static let shared = CoreBridge()
    var hasNativeSession = false
}
@MainActor enum Keychain {
    static var result = CredentialDurableReadResult.missing
    static func confirmedString(_ name: String) -> CredentialDurableReadResult { result }
}

/// These actors intentionally suspend without rechecking ownership, so production manager checks
/// cannot accidentally be supplied by a helpful mock. No ABI/disk/network success is claimed.
actor VortxAccountFileRestoreWorker {
    static let shared = VortxAccountFileRestoreWorker()
    func prepare(file: Data, response: Data, input: VortxAccountFileRepairService.Input,
                 fence: VortxAccountFileRepairService.Fence) async throws -> VortxAccountFileRestore.Prepared {
        try await RestoreFixtureWorld.current.prepare(file: file, response: response, input: input)
    }
    func requireLocalAbsence(scope: VortxAccountScope, key: Data) async throws {
        try await RestoreFixtureWorld.current.absence(scope: scope, key: key)
    }
}
actor VortxAccountFileRestoreJournal {
    static let shared = VortxAccountFileRestoreJournal()
    func unresolved(account: String, key: Data) async throws -> UUID? { try await RestoreFixtureWorld.current.unresolved(account: account, key: key) }
    func retain(_ intent: VortxAccountFileRestore.Intent, key: Data, fence: VortxAccountFileRepairService.Fence) async throws {
        try await RestoreFixtureWorld.current.retain(intent, key: key)
    }
    func load(account: String, id: UUID, key: Data) async throws -> VortxAccountFileRestore.Intent {
        try await RestoreFixtureWorld.current.load(account: account, id: id, key: key)
    }
    func record(_ receipt: VortxAccountFileRestore.Receipt, account: String, key: Data) async throws {
        try await RestoreFixtureWorld.current.record(receipt, account: account, key: key)
    }
}
actor AuthenticatedHTTPTransport {
    static let shared = AuthenticatedHTTPTransport()
    // @@ACTUAL_HTTP_LIMITS@@
    func send(_ request: URLRequest, allowedHosts: Set<String>, maxResponseBytes: Int) async throws -> AuthenticatedHTTPResponse {
        try await RestoreFixtureWorld.current.put(request, allowedHosts: allowedHosts, limit: maxResponseBytes)
    }
}

@MainActor
final class VortXSyncManager {
    struct Account { let id: String }
    struct CaptureWork { let capture: CredentialScopeRegistry.Capture }
    struct PushQueue { var hasPendingPush = false }
    var account: Account? = Account(id: RestoreFixtureValues.accountID)
    var isSignedIn = true
    var token: String? = "synthetic-original-token"
    var dataKey: Data? = RestoreFixtureValues.key
    private let credentialAuthority = CredentialScopeRegistry.shared
    var accountFileRepairOperation: UUID?
    var activeSyncUp: CaptureWork?, activeSyncDown: CaptureWork?
    var nativeCheckpointCapture: CredentialScopeRegistry.Capture?, restoreTaskCapture: CredentialScopeRegistry.Capture?
    var providerLegacyMigrationCapture: CredentialScopeRegistry.Capture?, pendingSyncCapture: CredentialScopeRegistry.Capture?
    var pendingDebridApply: CaptureWork?, pendingProviderApply: CaptureWork?
    var nativeDurablePushPending = false
    var nativePushQueue = PushQueue()
    var dirtySettings: [String: Int] = [:]
    var pendingAddonOrderIntent: String?
    var lastSyncedVersion = 20
    private let base = "https://api.vortx.tv"
    static var writeSyncDocV2 = false
    static var fixtureSawV2 = false
    private static func sawDocV2(_ id: String) -> Bool { fixtureSawV2 }
    private func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { credentialAuthority.isCurrent(capture) }
    private func request(_ method: String, _ path: String, auth: Bool,
                         credentialCapture: CredentialScopeRegistry.Capture,
                         receiveBackupData: ((Data) -> Void)?) async -> (Int, [String: Any]?) {
        precondition(method == "GET" && path == "/v1/backup" && auth)
        let (status, bytes) = await RestoreFixtureWorld.current.get()
        if status == 200 { receiveBackupData?(bytes) }
        return (status, nil) // Stale results are returned: actual manager must reject them.
    }
    private func storeSessionRenewal(_ renewal: String?, sentToken: String, capture: CredentialScopeRegistry.Capture) {
        precondition(isCurrent(capture) && token == sentToken && account?.id == RestoreFixtureValues.accountID,
            "renewal crossed original owner/token fence")
        RestoreFixtureWorld.current.renewalCalls += 1
        if let renewal { token = renewal }
    }
    func fixtureChangeOwner(sameValue: Bool = false) {
        let id = sameValue ? RestoreFixtureValues.accountID : RestoreFixtureValues.otherAccountID
        _ = credentialAuthority.fixtureEstablish(.account(UUID(uuidString: id)!))
        account = Account(id: id)
    }
    func fixtureRevokeAuthentication() { credentialAuthority.fixtureRevokeAuthentication() }
    func fixtureHasOperation() -> Bool { accountFileRestoreOperation != nil }
    func fixtureOperationID() -> UUID? { accountFileRestoreOperation?.id }
    func fixtureFenceActive() -> Bool { accountFileRestoreOperation?.fence.isActive() ?? false }
    // @@ACTUAL_RESTORE_MANAGER_BLOCK@@
}

@MainActor final class RestoreFixtureTaskBox {
    var task: Task<VortxAccountFileRestoreResult, Never>?
}
