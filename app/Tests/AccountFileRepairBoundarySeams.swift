import Foundation

/// SYNTHETIC SEAMS ONLY. The extractor composes the unchanged production manager file-repair
/// block into this shell. This supplies no auth/HTTP/session-renewal integration proof.
@MainActor
final class VortXSyncManager {
    struct Account { let id: String }
    var account: Account?
    var isSignedIn = true
    var token: String? = "synthetic-bearer"
    var dataKey: Data?
    private let credentialAuthority = CredentialScopeRegistry.shared
    var response = Data()
    var responseCode = 200
    var afterGET: (@MainActor () -> Void)?
    var afterWorker: (@MainActor () -> Void)?
    var getCount = 0
    static var fixtureSawV2 = false
    init(accountID: String, key: Data, response: Data) {
        self.account = .init(id: accountID); self.dataKey = key; self.response = response
    }
    private static func sawDocV2(_ accountID: String) -> Bool { fixtureSawV2 }
    private func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool {
        credentialAuthority.isCurrent(capture)
    }
    private func request(_ method: String, _ path: String, auth: Bool,
                         credentialCapture: CredentialScopeRegistry.Capture,
                         receiveBackupData: ((Data) -> Void)?) async -> (Int, [String: Any]?) {
        precondition(method == "GET" && path == "/v1/backup" && auth)
        getCount += 1
        await Task.yield() // A real suspension before the controlled post-GET boundary.
        afterGET?()
        guard isCurrent(credentialCapture) else { return (0, nil) }
        if responseCode == 200 { receiveBackupData?(response) }
        return (responseCode, nil)
    }
    func fixtureOwnerTransition(to accountID: String) {
        _ = credentialAuthority.fixtureEstablish(.account(UUID(uuidString: accountID)!))
        account = .init(id: accountID)
        retireAccountFileRepairForOwnerTransition()
    }
    func fixtureHasOperation() -> Bool { accountFileRepairOperation != nil }
    func fixturePreparing() -> Bool { accountFileRepairOperation?.preparing ?? false }
    func fixtureCancelCurrent() {
        if let current = accountFileRepairOperation { cancelAccountBackupRepair(current.id) }
    }
    // @@ACTUAL_FILE_REPAIR_MANAGER_BLOCK@@
}

@MainActor
enum AccountRepairBoundaryHooks {
    static var afterWorker: (@MainActor () -> Void)?
}

/// The production worker's real service+ABI call is retained; this test-only actor adds ONE
/// suspension/hook after that result, letting the actual manager post-await checks be exercised.
/// This actor is not compiled into production. It neither fakes a candidate nor overrides the ABI.
actor VortxAccountFileRepairWorker {
    static let shared = VortxAccountFileRepairWorker()
    func prepare(file: Data, authenticatedHeadResponse: Data, input: VortxAccountFileRepairService.Input,
                 fence: VortxAccountFileRepairService.Fence) async throws -> VortxAccountFileRepairService.Output {
        let result = try VortxAccountFileRepairService.prepare(file: file,
            authenticatedHeadResponse: authenticatedHeadResponse, input: input, fence: fence, abi: VortxCABI())
        await MainActor.run { AccountRepairBoundaryHooks.afterWorker?() }
        return result
    }
}

/// Only the production response budget is consumed by the file-only service. No transport call
/// is substituted inside a successful native conversion; manager HTTP is the explicit seam above.
enum AuthenticatedHTTPTransport {
    static let snapshotResponseLimit = 8 * 1024 * 1024
}
