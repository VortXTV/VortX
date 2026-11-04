import Combine
import Foundation

/// Volatile UI ownership proof, issued inside the manager's successful adoption.
/// It contains no bearer, data key or recovery code and is never persisted.
struct VortXAuthenticationReceipt: Equatable, Sendable {
    let accountID: String
    let credential: CredentialScopeRegistry.Capture

    @MainActor func isCurrent(accountID currentAccountID: String?) -> Bool {
        currentAccountID == accountID && CredentialScopeRegistry.shared.isCurrent(credential)
    }
}

/// A decision for already authenticated account data, not an authentication result.
/// Both manual Sync now and auth reconciliation retain the exact original owner.
struct AccountActionLease: Equatable, Sendable {
    let id = UUID()
    let accountID: String
    let credential: CredentialScopeRegistry.Capture

    @MainActor func isCurrent(accountID currentAccountID: String?) -> Bool {
        currentAccountID == accountID && CredentialScopeRegistry.shared.isCurrent(credential)
    }
}

/// Shared synchronously with the presenting sheet: Done never relies on a delayed
/// preference/onChange callback to learn that a one-time code needs acknowledgement.
@MainActor
final class AccountAuthenticationPresentation: ObservableObject {
    @Published private(set) var working = false
    @Published private(set) var recoveryCode: String?
    @Published private(set) var reconciling = false
    @Published private(set) var qrAttempt: UUID?
    @Published private(set) var manualSync: AccountActionLease?
    @Published private(set) var pendingConflict: AccountActionLease?
    @Published private(set) var resolvingConflict: AccountActionLease?
    var qrPresented: Bool { qrAttempt != nil }
    private var attempt: UUID?
    private var initialCredential: CredentialScopeRegistry.Capture?
    private var owner: VortXAuthenticationReceipt?

    var blocksDismissal: Bool {
        working || recoveryCode != nil || reconciling || qrPresented || manualSync != nil ||
        pendingConflict != nil || resolvingConflict != nil
    }

    func begin() -> UUID? {
        guard !blocksDismissal else { return nil }
        let id = UUID()
        initialCredential = CredentialScopeRegistry.shared.capture()
        attempt = id
        owner = nil
        working = true
        return id
    }

    func mayStartRequest(attempt id: UUID) -> Bool {
        guard attempt == id, working else { return false }
        guard initialCredential.map({ CredentialScopeRegistry.shared.isCurrent($0) }) == true else {
            invalidate()
            return false
        }
        return true
    }

    @discardableResult
    func recordAuthenticated(_ receipt: VortXAuthenticationReceipt, recoveryCode: String? = nil,
                             attempt id: UUID, accountID: String?) -> Bool {
        guard attempt == id, working, receipt.isCurrent(accountID: accountID) else { return false }
        owner = receipt
        self.recoveryCode = recoveryCode
        return true
    }

    func finishAuthentication(attempt id: UUID, succeeded: Bool, accountID: String?) -> Bool {
        guard attempt == id else { return false }
        let current = succeeded
            ? owner?.isCurrent(accountID: accountID) == true
            : initialCredential.map { CredentialScopeRegistry.shared.isCurrent($0) } == true
        guard current else { invalidate(); return false }
        working = false
        if !succeeded { attempt = nil; initialCredential = nil; owner = nil }
        return true
    }

    func recoveryCodeForCurrentOwner(accountID: String?) -> String? {
        owner?.isCurrent(accountID: accountID) == true ? recoveryCode : nil
    }

    /// Set the next protection before releasing the held code. A second tap cannot
    /// acknowledge twice or start two reconcile tasks.
    func beginCompletion(acknowledgingCode: Bool, accountID: String?) -> VortXAuthenticationReceipt? {
        guard !working, !reconciling, let owner, owner.isCurrent(accountID: accountID),
              acknowledgingCode == (recoveryCode != nil) else { return nil }
        reconciling = true
        recoveryCode = nil
        return owner
    }

    func completionIsCurrent(_ receipt: VortXAuthenticationReceipt, accountID: String?) -> Bool {
        reconciling && owner == receipt && receipt.isCurrent(accountID: accountID)
    }

    @discardableResult
    func finishCompletion(_ receipt: VortXAuthenticationReceipt, accountID: String?) -> Bool {
        guard completionIsCurrent(receipt, accountID: accountID) else { return false }
        clearAuthentication()
        return true // A pending conflict keeps its own lease/hold after hydration.
    }

    func beginManualSync(accountID: String?) -> AccountActionLease? {
        guard !blocksDismissal, let accountID else { return nil }
        let lease = AccountActionLease(accountID: accountID, credential: CredentialScopeRegistry.shared.capture())
        manualSync = lease
        return lease
    }

    func manualSyncIsCurrent(_ lease: AccountActionLease, accountID: String?) -> Bool {
        manualSync == lease && lease.isCurrent(accountID: accountID)
    }

    @discardableResult
    func finishManualSync(_ lease: AccountActionLease, accountID: String?) -> Bool {
        guard manualSyncIsCurrent(lease, accountID: accountID) else { return false }
        manualSync = nil
        return true
    }

    func holdConflict(from receipt: VortXAuthenticationReceipt, accountID: String?) -> AccountActionLease? {
        guard completionIsCurrent(receipt, accountID: accountID),
              pendingConflict == nil, resolvingConflict == nil else { return nil }
        let lease = AccountActionLease(accountID: receipt.accountID, credential: receipt.credential)
        pendingConflict = lease
        return lease
    }

    func holdManualConflict(_ lease: AccountActionLease, accountID: String?) -> Bool {
        guard manualSyncIsCurrent(lease, accountID: accountID),
              pendingConflict == nil, resolvingConflict == nil else { return false }
        pendingConflict = lease // Establish the decision hold before releasing manual work.
        manualSync = nil
        return true
    }

    func pendingConflictIsCurrent(_ lease: AccountActionLease, accountID: String?) -> Bool {
        pendingConflict == lease && lease.isCurrent(accountID: accountID)
    }

    func claimConflict(_ lease: AccountActionLease, accountID: String?) -> Bool {
        guard !working, !reconciling, pendingConflictIsCurrent(lease, accountID: accountID) else { return false }
        resolvingConflict = lease // Establish queued-operation protection before dismissing its alert.
        pendingConflict = nil
        return true
    }

    func conflictActionIsCurrent(_ lease: AccountActionLease, accountID: String?) -> Bool {
        resolvingConflict == lease && lease.isCurrent(accountID: accountID)
    }

    @discardableResult
    func finishConflict(_ lease: AccountActionLease, accountID: String?) -> Bool {
        guard conflictActionIsCurrent(lease, accountID: accountID) else { return false }
        resolvingConflict = nil
        return true
    }

    func cancelConflict(_ lease: AccountActionLease, accountID: String?) -> Bool {
        guard !reconciling, pendingConflictIsCurrent(lease, accountID: accountID) else { return false }
        pendingConflict = nil
        return true
    }

    /// An in-flight manager call may itself publish its adopted credential. Keep its
    /// attempt alive until its original success receipt or failure arrives; never infer
    /// success from the notification/current account. Held codes and late reconcile
    /// outcomes, however, retire immediately when their exact owner changes.
    func credentialDidChange() {
        // QR adoption publishes a credential before its awaiting joiner can hand off.
        // Only that attempt's explicit success/cancel/view dismissal releases this hold.
        if qrAttempt != nil { return }
        let captures = [owner?.credential, manualSync?.credential,
                        pendingConflict?.credential, resolvingConflict?.credential].compactMap { $0 }
        if captures.contains(where: { !CredentialScopeRegistry.shared.isCurrent($0) }) { invalidate() }
        else if !working, captures.isEmpty { invalidate() }
    }

    func beginQR() -> UUID? {
        guard !blocksDismissal else { return nil }
        let id = UUID()
        qrAttempt = id
        return id
    }

    @discardableResult
    func endQR(attempt id: UUID) -> Bool {
        guard qrAttempt == id else { return false }
        qrAttempt = nil
        return true
    }

    private func clearAuthentication() {
        attempt = nil
        initialCredential = nil
        owner = nil
        recoveryCode = nil
        working = false
        reconciling = false
    }

    func invalidate() {
        clearAuthentication()
        qrAttempt = nil
        manualSync = nil
        pendingConflict = nil
        resolvingConflict = nil
    }
}
