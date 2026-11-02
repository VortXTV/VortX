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
    /// No resubmission of unresolved earlier operations, including after process restart.
    /// Healthy receipts for refused/no-send operations permit a NEW explicit user request.
    func unresolved(account: String, key: Data) throws -> UUID? {
        guard let fd = try directory(create: false) else { return nil }
        defer { Darwin.close(fd) }
        let duplicate = Darwin.dup(fd)
        guard duplicate >= 0, let listing = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw VortxAccountFileRestoreFailure.recoveryUnavailable
        }
        defer { Darwin.closedir(listing) }
        let prefix = "intent-" + stem(account) + "-"
        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(listing) {
            let item = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if item.contains(stem(account)) && item.hasSuffix(".stage") { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
            if item.hasPrefix(prefix) { names.append(item) }
            guard names.count <= 128 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
            errno = 0
        }
        guard errno == 0 else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
        for item in names.sorted() {
            guard item.hasSuffix(".sealed"), let id = UUID(uuidString: String(item.dropFirst(prefix.count).dropLast(7))),
                  let bytes = try read(name(account, id, receipt: true), directory: fd) else {
                guard item.hasSuffix(".sealed"), let id = UUID(uuidString: String(item.dropFirst(prefix.count).dropLast(7))) else {
                    throw VortxAccountFileRestoreFailure.recoveryUnavailable
                }
                return id
            }
            let receipt = try open(VortxAccountFileRestore.Receipt.self, bytes: bytes, account: account, id: id, key: key, receipt: true)
            guard receipt.operationID == id else { throw VortxAccountFileRestoreFailure.recoveryUnavailable }
            if receipt.verdict != .notSubmitted && receipt.verdict != .conflict { return id }
        }
        return nil
    }
}
