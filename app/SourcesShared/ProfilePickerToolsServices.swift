import Foundation

#if os(iOS) || os(macOS) || os(tvOS)
extension ProfilePickerToolsController.Services {
    @MainActor
    static func live(restore: ProfilePickerToolsRestoreAction, accountGrant: ProfilePickerToolsAccountGrant) -> Self {
        let sync = VortXSyncManager.shared
        #if os(tvOS)
        return Self(owner: {
            // Freeze identity even if the presentation is briefly inactive. The live
            // grant still fences status, file actions and every asynchronous callback.
            guard let owner = accountGrant.owner, CredentialScopeRegistry.shared.isCurrent(owner.credential),
                  sync.isSignedIn, sync.account?.id == owner.accountID else { return nil }
            return owner
        }, isCurrent: { owner in
            accountGrant.permits(owner)
                && sync.isSignedIn && sync.account?.id == owner.accountID
        }, download: {
            try await sync.downloadAccountBackupFile()
        }, prepareRepair: { bytes in
            let preview = try await sync.prepareAccountBackupRepair(bytes)
            return .init(id: preview.id, profiles: preview.profileCount, bytes: preview.fileBytes)
        }, takeRepair: { id in
            try sync.takeAccountBackupRepairExport(id)
        }, cancelRepair: { id in
            sync.cancelAccountBackupRepair(id)
        }, restore: restore, transfer: .live, ownerIsCurrent: { owner in
            CredentialScopeRegistry.shared.isCurrent(owner.credential)
                && sync.isSignedIn && sync.account?.id == owner.accountID
        })
        #else
        return Self(owner: {
            // Freeze identity even if the presentation is briefly inactive. The live
            // grant still fences status, file actions and every asynchronous callback.
            guard let owner = accountGrant.owner, CredentialScopeRegistry.shared.isCurrent(owner.credential),
                  sync.isSignedIn, sync.account?.id == owner.accountID else { return nil }
            return owner
        }, isCurrent: { owner in
            accountGrant.permits(owner)
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
        }, restore: restore, ownerIsCurrent: { owner in
            CredentialScopeRegistry.shared.isCurrent(owner.credential)
                && sync.isSignedIn && sync.account?.id == owner.accountID
        })
        #endif
    }
}
#endif
