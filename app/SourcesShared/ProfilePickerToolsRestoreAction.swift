#if os(iOS) || os(macOS)
import Foundation

extension ProfilePickerToolsRestoreAction {
    /// This adapter requires the separately reviewed dedicated account-file restore service.
    /// Transport verification and durable historical local completion have separate typed results.
    static var live: Self {
        let sync = VortXSyncManager.shared
        return .init(status: {
            switch await sync.accountBackupFileRestoreStatus() {
            case .available(let records):
                return .available(records.compactMap { record in
                    let state: Retained.State
                    switch record.state {
                    case .notSubmitted, .conflict: return nil
                    case .deliveryUnconfirmed, .uploadAccepted: state = .needsVerification
                    case .serverConfirmed: state = .serverConfirmed
                    case .localAdoptionRecorded: state = .loaded
                    }
                    return Retained(operationID: record.operationID, state: state,
                        providerSettlementUnavailable: record.pendingReason == .legacyProviderSettlementUnavailable)
                })
            case .accountChanged: return .accountChanged
            case .recoveryUnavailable: return .recoveryUnavailable
            }
        }, finish: { originalOperation in
            switch await sync.finishAccountBackupFileRestore(originalOperation) {
            case .localAdoptionRecorded(let id, revision: _): return .loaded(id)
            case .pending(let id, let reason):
                return reason == .legacyProviderSettlementUnavailable ? .providerSettlementUnavailable(id) : .pending(id)
            case .accountChanged: return .accountChanged
            case .recoveryUnavailable: return .recoveryUnavailable
            }
        }, submit: { data in
            map(await sync.restoreAccountBackupFile(data))
        }, verify: { originalOperation in
            map(await sync.verifyAccountBackupFileRestore(originalOperation))
        })
    }
    private static func map(_ result: VortxAccountFileRestoreResult) -> Outcome {
        switch result {
        case .notSubmitted(let refusal):
            // The service enum owns these fixed messages; no raw provider body/error reaches UI.
            return .notSubmitted(refusal.errorDescription ?? "Restore did not start. The account backup was not replaced.")
        case .conflict: return .conflict
        case .deliveryUnconfirmed(let id): return .deliveryUnconfirmed(id)
        case .uploadAccepted(let id): return .uploadAccepted(id)
        case .serverConfirmed(let id, revision: _): return .serverConfirmed(id)
        }
    }
}
#endif
