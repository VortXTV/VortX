import Foundation

private enum CredentialScopeRegistry {
    struct Capture: Equatable, Sendable { let generation: Int }
    @MainActor static var shared: Authority { Manager.shared.credentialAuthority }
}

private struct VortXAuthenticationReceipt: Equatable {
    let accountID: String
    let credential: CredentialScopeRegistry.Capture
}

@MainActor private final class Authority {
    var generation = 1
    func capture() -> CredentialScopeRegistry.Capture { .init(generation: generation) }
    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { capture == self.capture() }
}

/// The script extracts the production action/operation control. This fixture only
/// supplies deterministic native, credential, and network results for those boundaries.
@MainActor private final class Manager {
    struct Account { let id: String }
    static var shared = Manager()
    let credentialAuthority = Authority()
    var account: Account? = Account(id: "fixture-only-account")
    var accountSignInAgainRequired = false
    var isSignedIn = true
    var dataKey: Data? = Data([1])
    var pendingAddonOrderIntent: String?
    private var activeSyncUp: (id: UUID, capture: CredentialScopeRegistry.Capture)?
    private var activeSyncDown: (id: UUID, capture: CredentialScopeRegistry.Capture)?
    private var syncCompletionWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    var waits: Int { syncCompletionWaiters.values.reduce(0) { $0 + $1.count } }
    var reads = 0
    var writes = 0
    var queuedWrites = 0
    var nextPull = ConflictResolutionOutcome.completed
    var uploadAccepted = true
    var probeResults: [AccountDataProbe] = []
    var activeUpload: UUID? { activeSyncUp?.id }
    var activeReceive: UUID? { activeSyncDown?.id }
    var beforeUpload: (() -> Void)?

    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool { capture == credentialAuthority.capture() }
    func withRemoteApplySuppressed(_ body: () -> Void) { body() }
    func requestSyncSoon() { queuedWrites += 1 }
    func nativeMutationDidCommit(credentialCapture capture: CredentialScopeRegistry.Capture) {
        precondition(isCurrent(capture))
        requestSyncSoon()
    }
    func accountHasSyncData(credentialCapture capture: CredentialScopeRegistry.Capture) async -> AccountDataProbe {
        precondition(isCurrent(capture))
        return probeResults.removeFirst()
    }

    @discardableResult func syncDown(force: Bool, credentialCapture capture: CredentialScopeRegistry.Capture,
        reportOutcome: ((ConflictResolutionOutcome) -> Void)? = nil) async -> Bool {
        var outcome = ConflictResolutionOutcome.failed
        defer { reportOutcome?(outcome) }
        guard force, isCurrent(capture), !Task.isCancelled else { return false }
        /* PRODUCTION_RECEIVE_SLOT */
        reads += 1
        outcome = nextPull
        return outcome == .completed
    }

    func syncUp(credentialCapture capture: CredentialScopeRegistry.Capture, reportQueued: (() -> Void)? = nil) async -> Bool {
        guard isCurrent(capture), !Task.isCancelled else { return false }
        beforeUpload?()
        /* PRODUCTION_UPLOAD_QUEUE */
        writes += 1
        return uploadAccepted
    }

    @discardableResult func occupyUpload() -> UUID {
        let id = UUID(); activeSyncUp = (id, credentialAuthority.capture()); return id
    }
    func occupyReceive() -> UUID {
        let id = UUID(); activeSyncDown = (id, credentialAuthority.capture()); return id
    }
    func releaseUpload(_ id: UUID) { finishSyncUp(id) }
    func releaseReceive(_ id: UUID) { finishSyncDown(id) }
    func recoverSeed(_ id: UUID, capture: CredentialScopeRegistry.Capture) async {
        await recoverInitialBackupWinner(operationID: id, capture: capture)
    }

    /* PRODUCTION_METHODS */
}

private typealias VortXSyncManager = Manager

@MainActor private final class TVBackup {
    private var decisionOwner: VortXAuthenticationReceipt?
    private var retryDecision: BackupDecision?
    private var pollGeneration = UUID()
    private var poller: Task<Void, Never>?
    private var showConflict = false
    private(set) var status: Status = .decision
    private(set) var newCodes = 0

    init(owner: VortXAuthenticationReceipt) { self.decisionOwner = owner }

    func choose(_ decision: BackupDecision) async {
        resolve(decision)
        await poller?.value
    }

    func tryAgain() async {
        retry()
        await poller?.value
    }

    private func start() { newCodes += 1 }

    /* PRODUCTION_TV_METHODS */
}

@main @MainActor private enum AppleSyncRecoveryTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ name: String) {
        precondition(condition, name)
        checks += 1
    }
    static func waitForJoin(_ manager: Manager) async {
        for _ in 0..<100 where manager.waits == 0 { await Task.yield() }
        expect(manager.waits == 1, "exact current operation has one registered waiter")
    }
    static func main() async {
        let existingReceive = Manager()
        let receiveID = existingReceive.occupyReceive()
        let merge = Task { await existingReceive.mergeBoth() }
        await waitForJoin(existingReceive)
        expect(existingReceive.reads == 0 && existingReceive.writes == 0, "does not overlap the active restore")
        existingReceive.releaseReceive(receiveID)
        let merged = await merge.value
        expect(merged == .completed && existingReceive.reads == 1 && existingReceive.writes == 1,
               "a settled owner gets one explicit merge retry and upload")

        let currentUpload = Manager()
        let uploadID = currentUpload.occupyUpload()
        let adoption = Task { await currentUpload.useAccountData() }
        await waitForJoin(currentUpload)
        currentUpload.releaseUpload(uploadID)
        let applied = await adoption.value
        expect(applied == .completed && currentUpload.reads == 1 && currentUpload.writes == 0,
               "use account waits for the exact upload without writing a backup itself")

        let superseded = Manager()
        let oldID = superseded.occupyReceive()
        let old = Task { await superseded.mergeBoth() }
        await waitForJoin(superseded)
        superseded.credentialAuthority.generation += 1
        let replacement = superseded.occupyReceive()
        superseded.releaseReceive(oldID)
        let rejected = await old.value
        expect(rejected == .failed && superseded.reads == 0 && superseded.writes == 0 && superseded.activeReceive == replacement,
               "stale same-account operation cannot release or act on a replacement")

        let cancelled = Manager()
        let held = cancelled.occupyUpload()
        let dismissed = Task { await cancelled.useAccountData() }
        await waitForJoin(cancelled)
        dismissed.cancel()
        let discarded = await dismissed.value
        expect(discarded == .failed && cancelled.waits == 0 && cancelled.activeUpload == held,
               "dismissal removes only the waiter")

        let queued = Manager()
        queued.beforeUpload = { queued.occupyUpload() }
        let pending = await queued.mergeBoth()
        expect(pending == .pending && queued.reads == 1 && queued.queuedWrites == 1 && queued.writes == 0,
               "a completed pull plus queued upload stays pending")

        let failed = Manager()
        failed.nextPull = .failed
        let unmerged = await failed.mergeBoth()
        expect(unmerged == .failed && failed.writes == 0 && failed.queuedWrites == 0,
               "failed restore never triggers the merge upload")

        let seed = Manager()
        let capture = seed.credentialAuthority.capture()
        let rejectedSeed = seed.occupyUpload()
        await seed.recoverSeed(rejectedSeed, capture: capture)
        expect(seed.activeUpload == nil && seed.reads == 1 && seed.writes == 0,
               "create-only rejection releases its own slot before reading the winner")
        let currentSeed = seed.occupyUpload()
        await seed.recoverSeed(rejectedSeed, capture: capture)
        expect(seed.activeUpload == currentSeed && seed.reads == 1,
               "old rejection cannot release a different upload")

        let lostACK = Manager()
        lostACK.uploadAccepted = false
        lostACK.probeResults = [.empty, .hasData]
        let found = await lostACK.reconcileAfterSignIn()
        expect(found == .hasAccountData && lostACK.writes == 1,
               "fresh authenticated winner after a lost seed ACK presents a reviewable choice")
        let unavailable = Manager()
        unavailable.uploadAccepted = false
        unavailable.probeResults = [.empty, .unreachable]
        let unreachable = await unavailable.reconcileAfterSignIn()
        expect(unreachable == .unreachable && unavailable.writes == 1,
               "readback failure never repeats the create attempt")

        let television = Manager()
        Manager.shared = television
        let tvReceipt = VortXAuthenticationReceipt(accountID: "fixture-only-account",
                                                   credential: television.credentialAuthority.capture())
        let tvMerge = TVBackup(owner: tvReceipt)
        television.beforeUpload = { television.occupyUpload() }
        await tvMerge.choose(.merge)
        expect(tvMerge.status == .pending && television.writes == 0 && television.queuedWrites == 1,
               "TV does not announce a queued merge as backed up")
        television.beforeUpload = nil
        television.releaseUpload(television.activeUpload!)
        await tvMerge.tryAgain()
        expect(tvMerge.status == .backedUp && tvMerge.newCodes == 0 && television.writes == 1,
               "TV retries the original authenticated merge without requesting another code")

        let tvRestore = TVBackup(owner: tvReceipt)
        television.nextPull = .failed
        await tvRestore.choose(.useAccount)
        expect(tvRestore.status == .failed, "TV shows a failed account restore")
        let completedReads = television.reads
        television.credentialAuthority.generation += 1
        television.nextPull = .completed
        await tvRestore.tryAgain()
        expect(tvRestore.newCodes == 1 && television.reads == completedReads && television.writes == 1,
               "TV cannot retry a stale decision against the same account's replacement sign-in")
        print("Apple account recovery: \(checks) focused checks passed")
    }
}
