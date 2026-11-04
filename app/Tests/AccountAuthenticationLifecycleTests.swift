import Foundation

// Synthetic collaborators only. The runner inserts unchanged production submit,
// handle, completion and both parent dismissal methods; it compiles the actual
// AccountAuthenticationPresentation source. No accounts, files or credentials used.
@MainActor final class CredentialScopeRegistry {
    static let shared = CredentialScopeRegistry()
    struct Capture: Equatable, Sendable { let generation: Int }
    var generation = 1
    func capture() -> Capture { Capture(generation: generation) }
    func isCurrent(_ capture: Capture) -> Bool { generation == capture.generation }
}

@MainActor final class VortXSyncManager {
    enum AuthResult: Equatable { case ok, totpRequired, failed(String) }
    enum SignInReconcile { case hasAccountData, seededFromDevice, unreachable }
    enum ConflictResolutionOutcome: Equatable { case completed, pending, failed }
    enum RosterConflict { case conflict, unreachable, noConflict }
    struct Account { let id: String }
    var account: Account?
    var isSignedIn = true
    var reconcileResult = SignInReconcile.seededFromDevice
    var rosterConflict = RosterConflict.conflict
    var pauseHydrate = false
    var hydrateWaiter: CheckedContinuation<Void, Never>?
    var hydrateGenerations: [Int] = []
    var restored = true
    var pushed = true
    var backupUploadFailure: String?
    var accountReconnectRequired = false
    var result = AuthResult.ok
    var replaceAfterReceipt = false
    var onCredentialChange: () -> Void = {}
    var pauseAuthentication = false
    var authenticationStarted = false
    var authenticationWaiter: CheckedContinuation<Void, Never>?
    var pauseReconcile = false
    var reconciliationStarted = false
    var reconcileWaiter: CheckedContinuation<Void, Never>?
    var hydrateCalls = 0

    private func authenticate(_ emit: @MainActor (VortXAuthenticationReceipt) -> Void) async -> AuthResult {
        authenticationStarted = true
        if pauseAuthentication { await withCheckedContinuation { authenticationWaiter = $0 } }
        guard result == .ok else { return result }
        CredentialScopeRegistry.shared.generation += 1
        account = Account(id: "synthetic-account-A")
        onCredentialChange() // Mirrors own adoption notification before the receipt.
        let receipt = VortXAuthenticationReceipt(accountID: account!.id,
                                                 credential: CredentialScopeRegistry.shared.capture())
        emit(receipt)
        if replaceAfterReceipt {
            // Same-account new epoch before the awaiting view continuation runs.
            CredentialScopeRegistry.shared.generation += 1
            onCredentialChange()
        }
        return .ok
    }
    func register(email: String, username: String, password: String,
                  onAuthenticated: (@MainActor (VortXAuthenticationReceipt, String) -> Void)? = nil)
        async -> (AuthResult, String?) {
        let result = await authenticate { receipt in
            onAuthenticated?(receipt, "SYNTHETIC-ONLY-NOT-A-REAL-CODE")
        }
        return (result, result == .ok ? "SYNTHETIC-ONLY-NOT-A-REAL-CODE" : nil)
    }
    func signIn(login: String, password: String, totp: String?, requireCurrentAccount: Bool,
                onAuthenticated: (@MainActor (VortXAuthenticationReceipt) -> Void)? = nil) async -> AuthResult {
        await authenticate { onAuthenticated?($0) }
    }
    func recover(email: String, recoveryCode: String, newPassword: String,
                 onAuthenticated: (@MainActor (VortXAuthenticationReceipt) -> Void)? = nil) async -> AuthResult {
        await authenticate { onAuthenticated?($0) }
    }
    func reconcileAfterSignIn() async -> SignInReconcile {
        reconciliationStarted = true
        if pauseReconcile { await withCheckedContinuation { reconcileWaiter = $0 } }
        return reconcileResult
    }
    func hydrateEngineFromOwnedAddons(credentialCapture: CredentialScopeRegistry.Capture) async {
        precondition(CredentialScopeRegistry.shared.isCurrent(credentialCapture))
        hydrateCalls += 1
        hydrateGenerations.append(credentialCapture.generation)
        if pauseHydrate { await withCheckedContinuation { hydrateWaiter = $0 } }
        guard CredentialScopeRegistry.shared.isCurrent(credentialCapture) else { return }
    }
    func retryAccountRestore() async -> Bool { restored }
    func rosterConflictWithAccount() async -> RosterConflict { rosterConflict }
    func pushThisDevice() async -> Bool { pushed }
}

@MainActor final class AuthViewHarness {
    enum Mode { case signIn, create, recover }
    let sync = VortXSyncManager()
    let authentication = AccountAuthenticationPresentation()
    var effectiveMode = Mode.create
    var email = "synthetic@example.invalid", username = "synthetic"
    var password = "synthetic-input", totp = "", recoveryCodeInput = ""
    var needsTotp = false, failed = false, showConflict = false
    var message: String?, syncNote: String?
    var syncing = false
    struct QRPresentation: Identifiable { let id: UUID }
    var qrPresentation: QRPresentation?
    var onSignedIn: (() -> Void)?
    init() { sync.onCredentialChange = { [weak self] in self?.credentialChanged() } }
    func credentialChanged() { /* PRODUCTION_SCOPE_RESET */
    }
    func begin() { submit() }
    func acknowledge() { completeAuthentication(acknowledgingCode: true) }
    func beginSync() { syncNow() }
    func choose(_ decision: AccountActionLease, _ action: @escaping @MainActor () async -> VortXSyncManager.ConflictResolutionOutcome) {
        resolveConflict(decision, action)
    }
    func cancelDecision(_ decision: AccountActionLease) { cancelConflict(decision) }
    func reviewDecision(_ decision: AccountActionLease) { reviewConflict(decision) }
    func beginQR() { openQR() }
    func finishQR(_ attempt: UUID) { completeQR(attempt: attempt) }
    func cancelQRPresentation(_ attempt: UUID) { cancelQR(attempt: attempt) }
    /* PRODUCTION_SUBMIT */
    /* PRODUCTION_HANDLE */
    /* PRODUCTION_COMPLETE */
    /* PRODUCTION_SYNC_NOW */
    /* PRODUCTION_RESOLVE_CONFLICT */
    /* PRODUCTION_REVIEW_CONFLICT */
    /* PRODUCTION_CANCEL_CONFLICT */
    /* PRODUCTION_OPEN_QR */
    /* PRODUCTION_COMPLETE_QR */
    /* PRODUCTION_CANCEL_QR */
}

@MainActor final class RecoveryParentHarness {
    let authentication: AccountAuthenticationPresentation
    var dismissals = 0
    init(_ authentication: AccountAuthenticationPresentation) { self.authentication = authentication }
    func dismiss() { dismissals += 1 }
    func tryDismiss() { dismissIfAllowed() }
    /* PRODUCTION_RECOVERY_DISMISS */
}
@MainActor final class TouchParentHarness {
    let vortxAuthentication: AccountAuthenticationPresentation
    var dismissals = 0
    init(_ authentication: AccountAuthenticationPresentation) { vortxAuthentication = authentication }
    func dismiss() { dismissals += 1 }
    func tryDismiss() { dismissIfAllowed() }
    /* PRODUCTION_TOUCH_DISMISS */
}

struct Binding<Value> {
    let get: () -> Value
    let set: (Value) -> Void
    var wrappedValue: Value { get { get() } nonmutating set { set(newValue) } }
}
@MainActor final class TestProfiles {
    var count = 2
    var pickedThisLaunch = false
    var needsPicker: Bool { count > 1 && !pickedThisLaunch }
}
@MainActor final class TestPresenter { var request: Int? }
@MainActor final class TestPlaybackGate { var playerActive = false }
@MainActor struct TVRootHarness {
    let profileAuthentication: AccountAuthenticationPresentation
    let profiles = TestProfiles(), presenter = TestPresenter()
    var splashDone = true
    init(_ authentication: AccountAuthenticationPresentation) { profileAuthentication = authentication }
    var presented: Bool { pickerPresented.wrappedValue }
    func dismissPicker() { pickerPresented.wrappedValue = false }
    /* PRODUCTION_TV_ROOT_BINDING */
}
@MainActor struct TouchRootHarness {
    let profileAuthentication: AccountAuthenticationPresentation
    let profiles = TestProfiles(), playbackGate = TestPlaybackGate()
    init(_ authentication: AccountAuthenticationPresentation) { profileAuthentication = authentication }
    var presented: Bool { pickerPresented.wrappedValue }
    func dismissPicker() { pickerPresented.wrappedValue = false }
    /* PRODUCTION_TOUCH_ROOT_OWED */
    /* PRODUCTION_TOUCH_ROOT_BINDING */
}

// The manager adoption's final receipt issuance guard is extracted unchanged.
@MainActor final class AdoptionReceiptHarness {
    struct Operation { let generation: Int }
    struct Account { let id: String }
    var authOperationGeneration = 1
    var isSignedIn = true
    var account: Account? = Account(id: "synthetic-account-A")
    func isCurrent(_ capture: CredentialScopeRegistry.Capture) -> Bool {
        CredentialScopeRegistry.shared.isCurrent(capture)
    }
    func issue(operation: Operation, adoptedCapture: CredentialScopeRegistry.Capture,
               candidateAccount: Account, onAuthenticated: (@MainActor (VortXAuthenticationReceipt) -> Void)?) -> Bool {
        /* PRODUCTION_MANAGER_RECEIPT */
        return true
    }
}

@main enum Checks {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        precondition(condition(), name); count += 1
    }
    @MainActor static func settle(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        precondition(condition(), "bounded synthetic actor drain timed out")
    }
    @MainActor static func parentsBlocked(_ view: AuthViewHarness) {
        let recovery = RecoveryParentHarness(view.authentication), touch = TouchParentHarness(view.authentication)
        recovery.tryDismiss(); touch.tryDismiss()
        check(recovery.dismissals == 0 && touch.dismissals == 0, "both actual parent handlers block synchronously")
    }
    @MainActor static func run() async {
        // Create: protection starts in the actual button action, before its task runs.
        let create = AuthViewHarness(); create.sync.pauseAuthentication = true
        var completions = 0; create.onSignedIn = { completions += 1 }
        create.begin(); parentsBlocked(create)
        check(create.authentication.working, "auth blocks before task scheduling")
        await settle { create.sync.authenticationWaiter != nil }
        parentsBlocked(create)
        create.sync.authenticationWaiter?.resume(); create.sync.authenticationWaiter = nil
        await settle { !create.authentication.working }
        check(create.authentication.recoveryCode != nil, "actual create handler retains its one-time code after success")
        check(completions == 0 && !create.sync.reconciliationStarted, "success cannot dismiss or reconcile before acknowledgement")
        parentsBlocked(create)
        create.acknowledge()
        check(completions == 1 && !create.authentication.blocksDismissal, "acknowledgement releases confirmed handoff once")
        create.acknowledge(); check(completions == 1, "second acknowledgement cannot duplicate handoff")

        let replacedBeforeTask = AuthViewHarness()
        replacedBeforeTask.begin()
        CredentialScopeRegistry.shared.generation += 1
        replacedBeforeTask.authentication.credentialDidChange()
        await settle { !replacedBeforeTask.authentication.working }
        check(!replacedBeforeTask.sync.authenticationStarted,
              "replacement before actor task starts cannot initiate auth for successor")

        let failedAfterReplacement = AuthViewHarness()
        failedAfterReplacement.sync.pauseAuthentication = true
        failedAfterReplacement.sync.result = .failed("synthetic superseded result")
        failedAfterReplacement.begin()
        await settle { failedAfterReplacement.sync.authenticationWaiter != nil }
        CredentialScopeRegistry.shared.generation += 1
        failedAfterReplacement.authentication.credentialDidChange()
        failedAfterReplacement.sync.authenticationWaiter?.resume()
        failedAfterReplacement.sync.authenticationWaiter = nil
        await settle { !failedAfterReplacement.authentication.working }
        check(failedAfterReplacement.message == nil && !failedAfterReplacement.failed,
              "late old-owner failed result cannot repaint successor")

        let rootCreate = AuthViewHarness()
        let tvRoot = TVRootHarness(rootCreate.authentication), touchRoot = TouchRootHarness(rootCreate.authentication)
        rootCreate.onSignedIn = {}
        rootCreate.begin()
        tvRoot.profiles.count = 1; touchRoot.profiles.count = 1
        check(tvRoot.presented && touchRoot.presented, "both actual root getters hold a one-profile roster during auth")
        tvRoot.dismissPicker(); touchRoot.dismissPicker()
        check(!tvRoot.profiles.pickedThisLaunch && !touchRoot.profiles.pickedThisLaunch,
              "root false setters cannot finish picker during auth")
        await settle { !rootCreate.authentication.working }
        check(tvRoot.presented && touchRoot.presented, "both root getters preserve held code after one-profile restore")
        tvRoot.dismissPicker(); touchRoot.dismissPicker()
        check(!tvRoot.profiles.pickedThisLaunch && !touchRoot.profiles.pickedThisLaunch,
              "root false setters cannot finish picker before code acknowledgement")
        rootCreate.acknowledge()
        check(!tvRoot.presented && !touchRoot.presented, "post-ack root hold releases to ordinary one-profile semantics")
        tvRoot.dismissPicker(); touchRoot.dismissPicker()
        check(tvRoot.profiles.pickedThisLaunch && touchRoot.profiles.pickedThisLaunch,
              "ordinary root dismissal regains its original semantics after release")

        let rootReplacement = AuthViewHarness()
        let replacementTV = TVRootHarness(rootReplacement.authentication)
        let replacementTouch = TouchRootHarness(rootReplacement.authentication)
        rootReplacement.begin(); await settle { !rootReplacement.authentication.working }
        replacementTV.profiles.count = 1; replacementTouch.profiles.count = 1
        CredentialScopeRegistry.shared.generation += 1
        rootReplacement.authentication.credentialDidChange()
        check(!replacementTV.presented && !replacementTouch.presented,
              "credential replacement retires old code hold in both roots")
        check(rootReplacement.authentication.recoveryCode == nil,
              "host release on replacement never retains old recovery secret")
        let idle = AccountAuthenticationPresentation()
        let idleTV = TVRootHarness(idle), idleTouch = TouchRootHarness(idle)
        idleTV.profiles.count = 1; idleTouch.profiles.count = 1
        check(!idleTV.presented && !idleTouch.presented, "idle presentation does not invent a picker for a single profile")

        // The exact same account ID with a new epoch is a replacement, including
        // replacement between manager receipt and the awaiting view continuation.
        let replacedBeforeReturn = AuthViewHarness(); replacedBeforeReturn.sync.replaceAfterReceipt = true
        var staleDismissals = 0; replacedBeforeReturn.onSignedIn = { staleDismissals += 1 }
        replacedBeforeReturn.begin()
        await settle { !replacedBeforeReturn.authentication.working }
        check(replacedBeforeReturn.authentication.recoveryCode == nil && staleDismissals == 0,
              "same-account replacement after receipt cannot publish old code or dismiss")

        let waitingCode = AuthViewHarness(); waitingCode.begin()
        await settle { !waitingCode.authentication.working }
        CredentialScopeRegistry.shared.generation += 1
        check(waitingCode.authentication.recoveryCodeForCurrentOwner(accountID: waitingCode.sync.account?.id) == nil,
              "code is hidden against current epoch before notification delivery")
        waitingCode.authentication.credentialDidChange(); waitingCode.acknowledge()
        check(waitingCode.authentication.recoveryCode == nil && !waitingCode.sync.reconciliationStarted,
              "replaced held code is erased and cannot acknowledge into successor")

        // Ordinary Account settings reconcile only after ack and remain protected
        // through the actual network-bound completion method.
        let reconcile = AuthViewHarness(); reconcile.sync.pauseReconcile = true
        reconcile.begin(); await settle { !reconcile.authentication.working }
        check(!reconcile.sync.reconciliationStarted, "ordinary account cannot reconcile while code is unacknowledged")
        reconcile.acknowledge(); parentsBlocked(reconcile)
        await settle { reconcile.sync.reconcileWaiter != nil }
        parentsBlocked(reconcile)
        CredentialScopeRegistry.shared.generation += 1
        reconcile.authentication.credentialDidChange()
        reconcile.sync.reconcileWaiter?.resume(); reconcile.sync.reconcileWaiter = nil
        for _ in 0..<30 { await Task.yield() }
        check(reconcile.sync.hydrateCalls == 0 && !reconcile.authentication.blocksDismissal,
              "stale reconcile completion cannot hydrate replacement or retain old lock")

        let currentReconcile = AuthViewHarness(); currentReconcile.sync.pauseReconcile = true
        currentReconcile.begin(); await settle { !currentReconcile.authentication.working }
        currentReconcile.acknowledge(); await settle { currentReconcile.sync.reconcileWaiter != nil }
        currentReconcile.sync.reconcileWaiter?.resume(); currentReconcile.sync.reconcileWaiter = nil
        await settle { !currentReconcile.authentication.blocksDismissal }
        check(currentReconcile.sync.hydrateCalls == 1, "current ack reconcile hydrates its exact credential")

        for mode in [AuthViewHarness.Mode.signIn, .recover] {
            let ordinary = AuthViewHarness(); ordinary.effectiveMode = mode
            var handedOff = 0; ordinary.onSignedIn = { handedOff += 1 }
            ordinary.begin(); await settle { !ordinary.authentication.blocksDismissal }
            check(handedOff == 1 && ordinary.authentication.recoveryCode == nil,
                  "existing password/recovery protocol needs no invented code acknowledgement")
        }
        let totp = AuthViewHarness(); totp.effectiveMode = .signIn; totp.sync.result = .totpRequired
        totp.begin(); await settle { !totp.authentication.working }
        check(totp.needsTotp && totp.message != nil && !totp.authentication.blocksDismissal,
              "TOTP challenge stays retryable without retaining dismissal lock")

        // Actual manager-tail guard proves that a receipt is never borrowed from a
        // replacement owner or an auth operation that superseded the original.
        let manager = AdoptionReceiptHarness(), authority = CredentialScopeRegistry.shared
        let candidate = AdoptionReceiptHarness.Account(id: "synthetic-account-A")
        let captured = authority.capture(); var issued = 0
        check(manager.issue(operation: .init(generation: 1), adoptedCapture: captured,
                            candidateAccount: candidate, onAuthenticated: { _ in issued += 1 }), "current adoption emits receipt")
        manager.authOperationGeneration = 2
        check(!manager.issue(operation: .init(generation: 1), adoptedCapture: captured,
                             candidateAccount: candidate, onAuthenticated: { _ in issued += 100 }), "superseded auth intent cannot emit receipt")
        manager.authOperationGeneration = 1; authority.generation += 1
        check(!manager.issue(operation: .init(generation: 1), adoptedCapture: captured,
                             candidateAccount: candidate, onAuthenticated: { _ in issued += 100 }), "same-account new epoch cannot emit old receipt")
        manager.account = .init(id: "synthetic-account-B")
        check(!manager.issue(operation: .init(generation: 1), adoptedCapture: authority.capture(),
                             candidateAccount: candidate, onAuthenticated: { _ in issued += 100 }), "wrong account cannot emit candidate receipt")
        check(issued == 1, "only exact original successful adoption issued a receipt")

        // Execute the actual QR open/success/cancel helpers across the manager's
        // credential publication gap and the root's one-profile transition.
        let qrView = AuthViewHarness()
        let qrTV = TVRootHarness(qrView.authentication), qrTouch = TouchRootHarness(qrView.authentication)
        var qrCompletions = 0; qrView.onSignedIn = { qrCompletions += 1 }
        qrView.beginQR(); let qrAttempt = qrView.qrPresentation!.id
        CredentialScopeRegistry.shared.generation += 1
        qrView.sync.account = .init(id: "synthetic-QR-account")
        qrView.credentialChanged() // OWN adoption publishes before joiner resumes.
        qrTV.profiles.count = 1; qrTouch.profiles.count = 1
        check(qrView.authentication.qrPresented && qrTV.presented && qrTouch.presented,
              "own QR adoption notification cannot release one-profile root hold")
        qrTV.dismissPicker(); qrTouch.dismissPicker()
        check(!qrTV.profiles.pickedThisLaunch && !qrTouch.profiles.pickedThisLaunch,
              "root false setters remain blocked before QR success callback")
        qrView.finishQR(qrAttempt)
        check(qrCompletions == 1 && !qrTV.presented && !qrTouch.presented,
              "explicit QR success releases exact hold after publication gap")
        qrView.beginQR(); let cancelledQR = qrView.qrPresentation!.id
        CredentialScopeRegistry.shared.generation += 1; qrView.credentialChanged()
        check(qrView.authentication.blocksDismissal, "replacement alone is not invented QR success")
        qrView.cancelQRPresentation(cancelledQR)
        qrView.finishQR(cancelledQR)
        check(qrCompletions == 1 && !qrView.authentication.blocksDismissal,
              "explicit QR cancel retires replacement presentation and rejects late success")
        qrView.beginQR(); let newQR = qrView.qrPresentation!.id
        qrView.cancelQRPresentation(cancelledQR)
        check(qrView.authentication.qrAttempt == newQR, "old QR cleanup cannot release newer attempt")
        qrView.cancelQRPresentation(newQR)

        // The actual .hasAccountData completion must retain a decision lease through
        // hydration and until a user chooses or explicitly abandons that decision.
        let conflictView = AuthViewHarness()
        conflictView.sync.reconcileResult = .hasAccountData
        conflictView.sync.pauseHydrate = true
        let conflictTV = TVRootHarness(conflictView.authentication)
        let conflictTouch = TouchRootHarness(conflictView.authentication)
        conflictView.begin(); await settle { !conflictView.authentication.working }
        conflictView.acknowledge()
        await settle { conflictView.sync.hydrateWaiter != nil }
        conflictTV.profiles.count = 1; conflictTouch.profiles.count = 1
        check(conflictView.authentication.pendingConflict != nil && !conflictView.showConflict,
              "hasAccountData owns pending conflict while initial hydrate is suspended")
        parentsBlocked(conflictView); conflictTV.dismissPicker(); conflictTouch.dismissPicker()
        check(conflictTV.presented && conflictTouch.presented && !conflictTV.profiles.pickedThisLaunch,
              "pending conflict keeps both root getters and setters protected during hydration")
        conflictView.sync.hydrateWaiter?.resume(); conflictView.sync.hydrateWaiter = nil
        await settle { conflictView.showConflict }
        let pendingDecision = conflictView.authentication.pendingConflict!
        check(!conflictView.authentication.reconciling && conflictView.authentication.blocksDismissal,
              "finished hydrate cannot erase conflict decision hold")
        parentsBlocked(conflictView)
        conflictView.showConflict = false // Simulated system alert dismissal.
        conflictView.reviewDecision(pendingDecision)
        check(conflictView.showConflict && conflictView.authentication.blocksDismissal,
              "review reopens same decision after alert dismissal")
        conflictView.cancelDecision(pendingDecision)
        check(!conflictView.showConflict && !conflictView.authentication.blocksDismissal,
              "Not now explicitly releases unresolved decision without mutation")

        // Sync now can create the same exact-owner decision without a new auth receipt.
        let manual = AuthViewHarness(); manual.sync.account = .init(id: "synthetic-account-A")
        manual.beginSync(); parentsBlocked(manual)
        await settle { manual.showConflict }
        let manualDecision = manual.authentication.pendingConflict!
        check(manual.authentication.blocksDismissal, "manual sync conflict retains shared dismissal hold")
        var actionCalls = 0
        manual.choose(manualDecision) { actionCalls += 1; return .completed }
        check(manual.authentication.resolvingConflict == manualDecision && manual.authentication.blocksDismissal,
              "claim retains exact decision before queued action starts")
        CredentialScopeRegistry.shared.generation += 1; manual.credentialChanged()
        for _ in 0..<30 { await Task.yield() }
        check(actionCalls == 0 && manual.sync.hydrateCalls == 0 && manual.syncNote == nil,
              "replacement after selection before task start cannot invoke successor action")

        let duringAction = AuthViewHarness(); duringAction.sync.account = .init(id: "synthetic-account-A")
        duringAction.beginSync(); await settle { duringAction.showConflict }
        let actionDecision = duringAction.authentication.pendingConflict!
        var actionWaiter: CheckedContinuation<Void, Never>?
        duringAction.choose(actionDecision) {
            await withCheckedContinuation { actionWaiter = $0 }
            return .completed
        }
        await settle { actionWaiter != nil }
        CredentialScopeRegistry.shared.generation += 1; duringAction.credentialChanged()
        actionWaiter?.resume(); actionWaiter = nil
        for _ in 0..<30 { await Task.yield() }
        check(duringAction.sync.hydrateCalls == 0 && duringAction.syncNote == nil && !duringAction.syncing,
              "replacement during conflict action cannot hydrate or repaint successor")

        let duringHydrate = AuthViewHarness(); duringHydrate.sync.account = .init(id: "synthetic-account-A")
        duringHydrate.sync.pauseHydrate = true
        duringHydrate.beginSync(); await settle { duringHydrate.showConflict }
        let hydrateDecision = duringHydrate.authentication.pendingConflict!
        duringHydrate.choose(hydrateDecision) { .completed }
        await settle { duringHydrate.sync.hydrateWaiter != nil }
        let originalGeneration = hydrateDecision.credential.generation
        CredentialScopeRegistry.shared.generation += 1; duringHydrate.credentialChanged()
        duringHydrate.sync.hydrateWaiter?.resume(); duringHydrate.sync.hydrateWaiter = nil
        for _ in 0..<30 { await Task.yield() }
        check(duringHydrate.sync.hydrateGenerations == [originalGeneration] && duringHydrate.syncNote == nil,
              "conflict hydration uses original capture and late completion cannot repaint replacement")

        let freshDecision = AuthViewHarness(); freshDecision.sync.account = .init(id: "synthetic-account-A")
        freshDecision.beginSync(); await settle { freshDecision.showConflict }
        let currentDecision = freshDecision.authentication.pendingConflict!
        freshDecision.cancelDecision(hydrateDecision)
        freshDecision.choose(hydrateDecision) { actionCalls += 100; return .completed }
        check(freshDecision.authentication.pendingConflict == currentDecision && freshDecision.showConflict,
              "old alert action/cancel cannot claim or dismiss a newer decision")
        freshDecision.choose(currentDecision) { .pending }
        await settle { !freshDecision.authentication.blocksDismissal }
        check(freshDecision.syncNote?.contains("still waiting") == true,
              "current pending resolution releases hold with truthful retry status")
        print("PASS actual auth lifecycle/parent/receipt extraction: \(count) checks, synthetic data only")
    }
    static func main() async { await run() }
}
