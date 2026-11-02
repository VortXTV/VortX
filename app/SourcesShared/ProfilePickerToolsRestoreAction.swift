#if os(iOS) || os(macOS)
import Foundation

extension ProfilePickerToolsRestoreAction {
    /// This adapter requires the separately reviewed dedicated account-file restore service.
    /// No settings import, sync-document alias, automatic replay or local-adoption claim exists here.
    static var live: Self {
        let sync = VortXSyncManager.shared
        return .init(submit: { data in
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
