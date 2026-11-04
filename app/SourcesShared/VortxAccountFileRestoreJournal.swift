import Foundation
import CryptoKit
import Darwin

/// Separate file-origin evidence, never a native bootstrap/checkpoint or authenticated peer receipt.
/// Original intent is immutable. Only a small separately sealed transport/readback receipt is replaced.
actor VortxAccountFileRestoreJournal {
    static let shared = VortxAccountFileRestoreJournal()
    private let maximumBytes = 64 * 1024 * 1024
    private let rootOverride: URL?
    // Production uses the existing OS root. Synthetic disk fixtures may supply an already-created
    // isolated root; this is not an alternate account authority or a path from a selected backup.
    init(root: URL? = nil) { rootOverride = root }
    private func stem(_ account: String) -> String { VortxAccountFileRestore.digest(Data(account.utf8)) }
    private func name(_ account: String, _ id: UUID, receipt: Bool = false) -> String {
        (receipt ? "receipt-" : "intent-") + stem(account) + "-" + id.uuidString.lowercased() + ".sealed"
    }
    private func localAdoptionName(_ account: String, _ id: UUID) -> String {
        "local-adoption-" + stem(account) + "-" + id.uuidString.lowercased() + ".sealed"
    }
    private func localAdoptionAAD(_ account: String, _ id: UUID) -> Data {
        Data(("vortx-account-file-local-adoption-v1" + "\u{0}" + account + "\u{0}" + id.uuidString.lowercased()).utf8)
    }
    private func aad(_ account: String, _ id: UUID, receipt: Bool = false) -> Data {
        Data(((receipt ? "vortx-file-restore-receipt-v1" : "vortx-file-restore-intent-v1")
            + "\u{0}" + account + "\u{0}" + id.uuidString.lowercased()).utf8)
    }
    private func directory(create: Bool) throws -> Int32? {
        let root = try rootOverride ?? VortxNativeStorage.root(create: false)
        var fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if !create && errno == ENOENT { return nil }
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
        do {
            for component in ["VortX", "account-file-restores"] {
                if create {
                    guard Darwin.mkdirat(fd, component, mode_t(0o700)) == 0 || errno == EEXIST else {
                        throw VortxAccountFileRestoreFailure.recoveryUnavailable
                    }
                    guard Darwin.fsync(fd) == 0 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
                }
                let next = Darwin.openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                if next < 0 {
                    if !create && errno == ENOENT { Darwin.close(fd); return nil }
                    throw VortxAccountFileRestoreFailure.recoveryUnavailable
                }
                Darwin.close(fd); fd = next
                var info = stat()
                guard Darwin.fstat(fd, &info) == 0, info.st_uid == geteuid(),
                      info.st_mode & mode_t(0o022) == 0 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    private func read(_ name: String, directory: Int32) throws -> Data? {
        let fd = Darwin.openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & mode_t(0o077) == 0,
              info.st_size >= 28, info.st_size <= maximumBytes else {
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
        var result = Data(count: Int(info.st_size))
        try result.withUnsafeMutableBytes { bytes in
            var count = 0
            while count < bytes.count {
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: count), bytes.count - count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
                count += n
            }
        }
        var extra: UInt8 = 0
        guard Darwin.read(fd, &extra, 1) == 0 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        return result
    }
    private func write(_ bytes: Data, name: String, directory: Int32, replace: Bool) throws {
        guard bytes.count <= maximumBytes else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        let temporary = "." + name + "." + UUID().uuidString.lowercased() + ".stage"
        let fd = Darwin.openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        var closed = false
        defer { if !closed { Darwin.close(fd) }; Darwin.unlinkat(directory, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var count = 0
            while count < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
                count += n
            }
        }
        guard Darwin.fsync(fd) == 0 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        let close = Darwin.close(fd); closed = true
        guard close == 0, try read(temporary, directory: directory) == bytes else {
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
        if replace {
            guard Darwin.renameat(directory, temporary, directory, name) == 0 else {
                throw VortxAccountFileRestoreFailure.recoveryUnavailable
            }
        } else {
            // Create-only publication. A collision never overwrites retained source evidence.
            guard Darwin.linkat(directory, temporary, directory, name, 0) == 0,
                  Darwin.unlinkat(directory, temporary, 0) == 0 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        }
        guard Darwin.fsync(directory) == 0, try read(name, directory: directory) == bytes else {
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
    }
    private func seal<T: Encodable>(_ value: T, account: String, id: UUID, key: Data, receipt: Bool = false) throws -> Data {
        guard key.count == 32 else { throw VortxAccountFileRestoreFailure.accountChanged }
        let plain = try JSONEncoder().encode(value)
        guard plain.count <= maximumBytes - 28,
              let bytes = try AES.GCM.seal(plain, using: SymmetricKey(data: key),
                authenticating: aad(account, id, receipt: receipt)).combined else {
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
        return bytes
    }
    private func open<T: Decodable>(_ type: T.Type, bytes: Data, account: String, id: UUID,
                                   key: Data, receipt: Bool = false) throws -> T {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: SymmetricKey(data: key),
                                     authenticating: aad(account, id, receipt: receipt))
        return try JSONDecoder().decode(type, from: plain)
    }
    func retain(_ intent: VortxAccountFileRestore.Intent, key: Data,
                fence: VortxAccountFileRepairService.Fence) throws {
        try fence.check()
        let sealed = try seal(intent, account: intent.accountID, id: intent.operationID, key: key)
        guard let fd = try directory(create: true) else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        defer { Darwin.close(fd) }
        try fence.check()
        try write(sealed, name: name(intent.accountID, intent.operationID), directory: fd, replace: false)
        let restored: VortxAccountFileRestore.Intent = try open(VortxAccountFileRestore.Intent.self,
            bytes: sealed, account: intent.accountID, id: intent.operationID, key: key)
        guard restored.selectedFile == intent.selectedFile, restored.candidateFile == intent.candidateFile,
              restored.replacedHeadResponse == intent.replacedHeadResponse else {
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
    }
    func load(account: String, id: UUID, key: Data) throws -> VortxAccountFileRestore.Intent {
        guard let fd = try directory(create: false) else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        defer { Darwin.close(fd) }
        guard let bytes = try read(name(account, id), directory: fd) else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        let value = try open(VortxAccountFileRestore.Intent.self, bytes: bytes, account: account, id: id, key: key)
        guard value.format == "vortx-account-file-restore-intent-v1", value.sourceKind == "user_selected_file",
              value.accountID == account, value.operationID == id,
              SyncDocumentRevisionPolicy.next(after: value.baseRevision) == value.revision else {
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
        return value
    }
    func record(_ receipt: VortxAccountFileRestore.Receipt, account: String, key: Data) throws {
        guard let fd = try directory(create: false) else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        defer { Darwin.close(fd) }
        guard let original = try read(name(account, receipt.operationID), directory: fd) else {
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
        let intent = try open(VortxAccountFileRestore.Intent.self, bytes: original,
            account: account, id: receipt.operationID, key: key)
        guard intent.operationID == receipt.operationID, intent.accountID == account, intent.revision == receipt.revision else {
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
        let bytes = try seal(receipt, account: account, id: receipt.operationID, key: key, receipt: true)
        try write(bytes, name: name(account, receipt.operationID, receipt: true), directory: fd, replace: true)
    }
    private struct Retained {
        let intent: VortxAccountFileRestore.Intent
        let sealedIntent: Data
        let completion: VortxAccountFileRestore.LocalAdoption?
        let status: VortxAccountFileRestore.OperationStatus
    }
    private func validatedIntent(_ bytes: Data, account: String, id: UUID, key: Data) throws -> VortxAccountFileRestore.Intent {
        let intent = try open(VortxAccountFileRestore.Intent.self, bytes: bytes, account: account, id: id, key: key)
        guard intent.format == "vortx-account-file-restore-intent-v1", intent.sourceKind == "user_selected_file",
              intent.accountID == account, intent.operationID == id,
              SyncDocumentRevisionPolicy.next(after: intent.baseRevision) == intent.revision,
              let owner = UUID(uuidString: intent.ownerProfileID), owner.uuidString == intent.ownerProfileID,
              intent.plaintextSHA256.count == 64,
              intent.plaintextSHA256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
        return intent
    }
    private func validates(_ record: VortxAccountFileRestore.LocalAdoption,
                           intent: VortxAccountFileRestore.Intent, sealedIntent: Data, key: Data) -> Bool {
        guard let canonical = CredentialScope(canonicalRemoteAccountID: intent.accountID),
              record.format == "vortx-account-file-local-adoption-v1",
              record.operationID == intent.operationID, record.accountID == intent.accountID,
              record.scope.account == canonical.storageNamespace, record.scope.ownerProfileID == intent.ownerProfileID,
              record.revision == intent.revision, record.plaintextSHA256 == intent.plaintextSHA256,
              record.sealedIntentSHA256 == VortxAccountFileRestore.digest(sealedIntent),
              let submitted = VortXSyncCrypto.openDocument(dataKey: key, stored: intent.submittedDocument,
                accountId: intent.accountID, version: intent.revision),
              VortxAccountFileRestore.digest(submitted) == intent.plaintextSHA256 else { return false }
        return true
    }
    /// Validate the whole bounded current-account inventory before yielding ANY releasable state.
    /// Orphan records, malformed names, unsafe files and surviving stages must not disappear behind
    /// a healthy earlier entry. Other accounts are never decrypted with this account's key.
    private func retained(account: String, key: Data, directory fd: Int32) throws -> [Retained] {
        guard key.count == 32 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        // Each validation/readback needs a fresh open-file description at directory offset zero.
        // dup(fd) would share the previous scan's offset and could strand later matching intents.
        // Resolve only relative to the already pinned descriptor, never through a reopened path.
        var originalDirectory = stat()
        guard Darwin.fstat(fd, &originalDirectory) == 0,
              originalDirectory.st_mode & S_IFMT == S_IFDIR, originalDirectory.st_uid == geteuid(),
              originalDirectory.st_mode & mode_t(0o022) == 0 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        let scan = Darwin.openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard scan >= 0 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        var scanDirectory = stat()
        guard Darwin.fstat(scan, &scanDirectory) == 0,
              scanDirectory.st_dev == originalDirectory.st_dev, scanDirectory.st_ino == originalDirectory.st_ino,
              scanDirectory.st_mode & S_IFMT == S_IFDIR, scanDirectory.st_uid == geteuid(),
              scanDirectory.st_mode & mode_t(0o022) == 0 else {
            Darwin.close(scan)
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
        guard let listing = Darwin.fdopendir(scan) else {
            Darwin.close(scan)
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
        defer { Darwin.closedir(listing) }
        let accountStem = stem(account)
        let prefixes = ["intent-", "receipt-", "local-adoption-"].map { $0 + accountStem + "-" }
        var ids = Set<UUID>(), intents = Set<UUID>()
        var visited = 0, owned = 0
        errno = 0
        while let entry = Darwin.readdir(listing) {
            let item = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            visited += 1
            guard visited <= 4096 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
            if item.contains(accountStem) {
                owned += 1
                guard owned <= 384, !item.hasSuffix(".stage"), item.hasSuffix(".sealed"),
                      let prefix = prefixes.first(where: { item.hasPrefix($0) }),
                      let id = UUID(uuidString: String(item.dropFirst(prefix.count).dropLast(7))),
                      item == prefix + id.uuidString.lowercased() + ".sealed" else {
                    throw VortxAccountFileRestoreFailure.recoveryUnavailable
                }
                ids.insert(id)
                if prefix == prefixes[0] { intents.insert(id) }
            }
            errno = 0
        }
        guard errno == 0, ids == intents, intents.count <= 128 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        var inventoryBytes = 0
        func admitInventoryBytes(_ count: Int) throws {
            inventoryBytes += count
            guard inventoryBytes <= 128 * 1024 * 1024 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        }
        return try intents.sorted(by: { $0.uuidString < $1.uuidString }).map { id in
            guard let sealed = try read(name(account, id), directory: fd) else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
            try admitInventoryBytes(sealed.count)
            let intent = try validatedIntent(sealed, account: account, id: id, key: key)
            guard let submitted = VortXSyncCrypto.openDocument(dataKey: key, stored: intent.submittedDocument,
                accountId: intent.accountID, version: intent.revision),
                VortxAccountFileRestore.digest(submitted) == intent.plaintextSHA256 else {
                throw VortxAccountFileRestoreFailure.recoveryUnavailable
            }
            let pendingReason: VortxAccountFileRestore.LocalPendingReason =
                VortxAccountFileRestore.hasUnacknowledgedProviderCarrier(submitted) ? .legacyProviderSettlementUnavailable : .receivePending
            var state = VortxAccountFileRestore.LocalState.deliveryUnconfirmed
            if let bytes = try read(name(account, id, receipt: true), directory: fd) {
                try admitInventoryBytes(bytes.count)
                let transport = try open(VortxAccountFileRestore.Receipt.self, bytes: bytes, account: account, id: id, key: key, receipt: true)
                guard transport.operationID == id, transport.revision == intent.revision,
                      let transportState = VortxAccountFileRestore.LocalState(rawValue: transport.verdict.rawValue) else {
                    throw VortxAccountFileRestoreFailure.recoveryUnavailable
                }
                state = transportState
            }
            var completion: VortxAccountFileRestore.LocalAdoption?
            if let bytes = try read(localAdoptionName(account, id), directory: fd) {
                try admitInventoryBytes(bytes.count)
                let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: SymmetricKey(data: key),
                    authenticating: localAdoptionAAD(account, id))
                let record = try JSONDecoder().decode(VortxAccountFileRestore.LocalAdoption.self, from: plaintext)
                guard validates(record, intent: intent, sealedIntent: sealed, key: key) else {
                    throw VortxAccountFileRestoreFailure.recoveryUnavailable
                }
                completion = record; state = .localAdoptionRecorded
            }
            return Retained(intent: intent, sealedIntent: sealed, completion: completion,
                status: .init(operationID: id, revision: intent.revision, state: state, pendingReason: pendingReason))
        }
    }
    func status(account: String, key: Data) throws -> [VortxAccountFileRestore.OperationStatus] {
        guard let fd = try directory(create: false) else { return [] }
        defer { Darwin.close(fd) }
        return try retained(account: account, key: key, directory: fd).map(\.status)
    }
    /// Completed evidence is immutable and manager-minted. No current owner/key is acquired here;
    /// after mint, this records the original account's historical fact even if its UI was cancelled.
    @discardableResult
    func recordLocalAdoption(_ completed: VortXSyncManager.CompletedFileRestoreReceive) throws -> [UUID] {
        guard let fd = try directory(create: false) else { return [] }
        defer { Darwin.close(fd) }
        let entries = try retained(account: completed.accountID, key: completed.dataKey, directory: fd)
        var recorded: [UUID] = []
        for entry in entries {
            let intent = entry.intent
            guard intent.revision == completed.revision, intent.plaintextSHA256 == completed.plaintextSHA256,
                  intent.accountID == completed.accountID, intent.ownerProfileID == completed.scope.ownerProfileID,
                  completed.scope.account == completed.capture.namespace else { continue }
            let record = VortxAccountFileRestore.LocalAdoption(format: "vortx-account-file-local-adoption-v1",
                operationID: intent.operationID, accountID: intent.accountID, scope: completed.scope,
                revision: completed.revision, plaintextSHA256: completed.plaintextSHA256,
                sealedIntentSHA256: VortxAccountFileRestore.digest(entry.sealedIntent), observation: completed.observation)
            guard validates(record, intent: intent, sealedIntent: entry.sealedIntent, key: completed.dataKey) else {
                throw VortxAccountFileRestoreFailure.recoveryUnavailable
            }
            if entry.completion == nil {
                let plain = try JSONEncoder().encode(record)
                guard let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: completed.dataKey),
                    authenticating: localAdoptionAAD(intent.accountID, intent.operationID)).combined else {
                    throw VortxAccountFileRestoreFailure.recoveryUnavailable
                }
                try write(sealed, name: localAdoptionName(intent.accountID, intent.operationID), directory: fd, replace: false)
            }
            // Read and authenticate the installed record, including an idempotent pre-existing one.
            guard try retained(account: completed.accountID, key: completed.dataKey, directory: fd)
                .contains(where: { $0.status.operationID == intent.operationID && $0.status.state == .localAdoptionRecorded }) else {
                throw VortxAccountFileRestoreFailure.recoveryUnavailable
            }
            recorded.append(intent.operationID)
        }
        return recorded
    }
    /// A filename, transport confirmation or version floor alone never releases this blocker.
    func unresolved(account: String, key: Data) throws -> UUID? {
        try status(account: account, key: key).first(where: { $0.state.unresolved })?.operationID
    }
}
