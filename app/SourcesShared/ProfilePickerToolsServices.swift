import Foundation

#if os(iOS) || os(macOS)
extension ProfilePickerToolsController.Services {
    @MainActor
    static func live(restore: ProfilePickerToolsRestoreAction) -> Self {
        let sync = VortXSyncManager.shared
        return Self(owner: {
            let credential = CredentialScopeRegistry.shared.capture()
            guard sync.isSignedIn, let account = sync.account,
                  let canonical = CredentialScope(canonicalRemoteAccountID: account.id),
                  credential.scope == canonical else { return nil }
            return .init(credential: credential, accountID: account.id)
        }, isCurrent: { owner in
            CredentialScopeRegistry.shared.isCurrent(owner.credential)
                && sync.isSignedIn && sync.account?.id == owner.accountID
        }, download: {
            try await sync.downloadAccountBackupFile()
        }, read: { url in
            let selected = try await VortxAccountFileAccessWorker.shared.read(url)
            return .init(bytes: selected.bytes, sha256: selected.sha256)
        }, digest: { data in
            // One owned caller awaits the actual digest completion before releasing its slot.
            await Task.detached(priority: .utility) { VortxAccountFileAccess.digest(data) }.value
        }, save: { data, digest, kind, directory in
            let mapped: VortxAccountFileAccess.CopyKind
            switch kind { case .accountBackup: mapped = .accountBackup; case .repairedAccount: mapped = .repairedAccount }
            let receipt = try await VortxAccountFileAccessWorker.shared.save(data,
                expectedSHA256: digest, kind: mapped, in: directory)
            return .init(filename: receipt.url.lastPathComponent, bytes: receipt.bytes, sha256: receipt.sha256)
        }, prepareRepair: { bytes in
            let preview = try await sync.prepareAccountBackupRepair(bytes)
            return .init(id: preview.id, profiles: preview.profileCount, bytes: preview.fileBytes)
        }, takeRepair: { id in
            try sync.takeAccountBackupRepairExport(id)
        }, cancelRepair: { id in
            sync.cancelAccountBackupRepair(id)
        }, restore: restore)
    }
}
#endif
