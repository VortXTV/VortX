import Foundation
import Darwin

/// Persistence boundary for imported catalogs.
///
/// Public catalogs may use the ordinary preferences store. A catalog that required an authenticated
/// connection can contain private titles and source identity, so it must remain memory-only.
enum ImportedCatalogPersistencePolicy {
    static func isDurable(requiresConnection: Bool?) -> Bool {
        requiresConnection != true
    }
}

enum PrivateExternalSyncStorageError: String, Error, Sendable {
    case location
    case directory
    case backupExclusion
    case protection
    case read
    case write
    /// Replacement became visible, but the containing directory could not be certified durable.
    /// The caller must retain its pending intent; this error does not mean the old bytes survived.
    case uncertainCommit
    case reset
    case legacyReset
}

/// Protected, backup-excluded persistence for private external-account state.
///
/// Legacy root Application Support files are deleted rather than migrated because they carry no
/// account identity. Callers encode a session-bound envelope before saving.
struct PrivateExternalSyncStorage: Sendable {
    let fileURL: URL
    let legacyURLs: [URL]

    /// Synchronous fault boundaries for disposable real-file regression fixtures. Production uses
    /// save(_:) without a barrier. No barrier is retained or dispatched to another executor.
    enum SaveStage: Sendable, Equatable {
        case prepareDirectory, createNamespace, createStage, namespaceProtection, namespaceBackupExclusion
        case protection, backupExclusion, write, afterWriteChunk, fileSync, replace, directorySync
    }
    typealias SaveBarrier = (_ stage: SaveStage, _ stagingURL: URL?) throws -> Void

    static func live(provider: String, file: String, legacyFiles: [String]) throws -> Self {
        let manager = FileManager.default
        // A physical Apple TV cannot create Application Support; tvOS keeps these caches in Caches.
        #if os(tvOS)
        let base: FileManager.SearchPathDirectory = .cachesDirectory
        #else
        let base: FileManager.SearchPathDirectory = .applicationSupportDirectory
        #endif
        guard let support = try? manager.url(
            for: base,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            throw PrivateExternalSyncStorageError.location
        }
        let directory = support
            .appendingPathComponent("StremioX", isDirectory: true)
            .appendingPathComponent("ExternalSync", isDirectory: true)
            .appendingPathComponent(provider, isDirectory: true)
        return PrivateExternalSyncStorage(
            fileURL: directory.appendingPathComponent(file),
            legacyURLs: legacyFiles.map { support.appendingPathComponent($0) }
        )
    }

    func load() throws -> Data? {
        try deleteLegacy()
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            try prepareDirectory()
            try protect(fileURL)
            try excludeFromBackup(fileURL)
            return try Data(contentsOf: fileURL)
        } catch let error as PrivateExternalSyncStorageError {
            // Private account state is useful only while its storage guarantees hold. If an existing
            // file cannot be protected or excluded, fail closed instead of reading it.
            try? manager.removeItem(at: fileURL)
            throw error
        } catch {
            throw PrivateExternalSyncStorageError.read
        }
    }

    func save(_ data: Data) throws {
        try save(data, barrier: nil)
    }

    /// Payload bytes stay within an exclusively created owner-only operation namespace until
    /// protection/exclusion and file sync complete. Detectable path substitutions fail closed.
    /// This assumes no malicious same-UID or privileged mutation between a check and its syscall;
    /// POSIX pathname operations do not provide an atomic compare-inode-and-rename/unlink primitive.
    func save(_ data: Data, barrier: SaveBarrier?) throws {
        try deleteLegacy()
        try barrier?(.prepareDirectory, nil)
        try prepareDirectory()
        let directory = fileURL.deletingLastPathComponent()
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw PrivateExternalSyncStorageError.directory }
        defer { _ = Darwin.close(directoryFD) }

        try barrier?(.createNamespace, nil)
        let namespaceName = ".\(fileURL.lastPathComponent).\(UUID().uuidString).stage-directory"
        guard Darwin.mkdirat(directoryFD, namespaceName, mode_t(0o700)) == 0 else {
            throw PrivateExternalSyncStorageError.write
        }
        let namespaceFD = Darwin.openat(
            directoryFD, namespaceName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        // If the newly created directory cannot be opened and identified, leave it empty in place
        // rather than attempting pathname cleanup without an owned descriptor.
        guard namespaceFD >= 0 else { throw PrivateExternalSyncStorageError.write }
        let namespace = SaveNamespace(directoryURL: directory, directoryFD: directoryFD,
            name: namespaceName, descriptor: namespaceFD)
        var descriptor: Int32 = -1
        var renamed = false
        defer {
            namespace.cleanup(payloadDescriptor: descriptor, renamed: renamed)
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            _ = Darwin.close(namespaceFD)
        }
        guard Darwin.fchmod(namespaceFD, mode_t(0o700)) == 0 else {
            throw PrivateExternalSyncStorageError.protection
        }
        try namespace.verify()
        try barrier?(.createStage, namespace.payloadURL)
        try namespace.verify()
        descriptor = Darwin.openat(
            namespaceFD, SaveNamespace.payloadName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)
        )
        guard descriptor >= 0 else { throw PrivateExternalSyncStorageError.write }

        // Validate immediately after each injectable boundary and on both sides of pathname
        // metadata operations. The empty stage never receives bytes after a detected substitution.
        try barrier?(.namespaceProtection, namespace.url)
        try namespace.verify(payloadDescriptor: descriptor)
        try protect(namespace.url, isDirectory: true)
        try namespace.verify(payloadDescriptor: descriptor)
        try barrier?(.namespaceBackupExclusion, namespace.url)
        try namespace.verify(payloadDescriptor: descriptor)
        try excludeFromBackup(namespace.url)
        try namespace.verify(payloadDescriptor: descriptor)
        try barrier?(.protection, namespace.payloadURL)
        try namespace.verify(payloadDescriptor: descriptor)
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw PrivateExternalSyncStorageError.protection
        }
        try protect(namespace.payloadURL)
        try namespace.verify(payloadDescriptor: descriptor)
        try barrier?(.backupExclusion, namespace.payloadURL)
        try namespace.verify(payloadDescriptor: descriptor)
        try excludeFromBackup(namespace.payloadURL)
        try namespace.verify(payloadDescriptor: descriptor)
        try barrier?(.write, namespace.payloadURL)
        try namespace.verify(payloadDescriptor: descriptor)
        try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, address.advanced(by: offset), min(65_536, bytes.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PrivateExternalSyncStorageError.write }
                offset += count
                try barrier?(.afterWriteChunk, namespace.payloadURL)
                try namespace.verify(payloadDescriptor: descriptor)
            }
        }
        try barrier?(.fileSync, namespace.payloadURL)
        try namespace.verify(payloadDescriptor: descriptor)
        try sync(descriptor, error: .write)
        try barrier?(.replace, namespace.payloadURL)
        try namespace.verify(payloadDescriptor: descriptor)
        guard Darwin.renameat(namespaceFD, SaveNamespace.payloadName, directoryFD, fileURL.lastPathComponent) == 0 else {
            throw PrivateExternalSyncStorageError.write
        }
        renamed = true
        let closeResult = Darwin.close(descriptor)
        descriptor = -1
        do {
            guard closeResult == 0 else { throw PrivateExternalSyncStorageError.uncertainCommit }
            try barrier?(.directorySync, nil)
            try namespace.verify()
            try sync(namespaceFD, error: .uncertainCommit)
            try sync(directoryFD, error: .uncertainCommit)
        } catch {
            // The replacement is already visible. Preserve it and report uncertain durability.
            throw PrivateExternalSyncStorageError.uncertainCommit
        }
    }

    private struct SaveNamespace {
        static let payloadName = "payload"
        let directoryURL: URL
        let directoryFD: Int32
        let name: String
        let descriptor: Int32

        var url: URL { directoryURL.appendingPathComponent(name, isDirectory: true) }
        var payloadURL: URL { url.appendingPathComponent(Self.payloadName) }

        /// Only held descriptors and no-follow directory entries establish ownership here.
        /// These checks detect observed substitution; they are not an atomic inode CAS.
        func verify(payloadDescriptor: Int32 = -1) throws {
            guard namespaceIsCurrent() else { throw PrivateExternalSyncStorageError.write }
            if payloadDescriptor >= 0 {
                var opened = stat()
                var named = stat()
                guard Darwin.fstat(payloadDescriptor, &opened) == 0,
                      Darwin.fstatat(descriptor, Self.payloadName, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      sameInode(opened, named),
                      opened.st_mode & S_IFMT == S_IFREG, named.st_mode & S_IFMT == S_IFREG,
                      opened.st_uid == geteuid(),
                      opened.st_mode & mode_t(0o7777) == mode_t(0o600) else {
                    throw PrivateExternalSyncStorageError.write
                }
            }
        }

        private func namespaceIsCurrent() -> Bool {
            var openedParent = stat()
            var namedParent = stat()
            var opened = stat()
            var named = stat()
            return Darwin.fstat(directoryFD, &openedParent) == 0
                && Darwin.lstat(directoryURL.path, &namedParent) == 0
                && sameInode(openedParent, namedParent)
                && namedParent.st_mode & S_IFMT == S_IFDIR
                && openedParent.st_uid == geteuid()
                && Darwin.fstat(descriptor, &opened) == 0
                && Darwin.fstatat(directoryFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0
                && sameInode(opened, named)
                && opened.st_mode & S_IFMT == S_IFDIR && named.st_mode & S_IFMT == S_IFDIR
                && opened.st_uid == geteuid()
                && opened.st_mode & mode_t(0o7777) == mode_t(0o700)
        }

        private func sameInode(_ first: stat, _ second: stat) -> Bool {
            first.st_dev == second.st_dev && first.st_ino == second.st_ino
        }

        func cleanup(payloadDescriptor: Int32, renamed: Bool) {
            // Abandon a displaced/substituted namespace or payload without touching its entries.
            // An exclusively owned namespace excludes other UIDs. As with rename, arbitrary
            // malicious same-UID/privileged changes between check and unlink are outside the model.
            guard namespaceIsCurrent() else { return }
            if !renamed && payloadDescriptor >= 0 {
                guard (try? verify(payloadDescriptor: payloadDescriptor)) != nil else { return }
                guard Darwin.unlinkat(descriptor, Self.payloadName, 0) == 0 else { return }
            }
            guard namespaceIsCurrent() else { return }
            // rmdir fails if any unowned sibling exists. Never enumerate or recursively remove.
            _ = Darwin.unlinkat(directoryFD, name, AT_REMOVEDIR)
        }
    }

    private func sync(_ descriptor: Int32, error: PrivateExternalSyncStorageError) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno != EINTR { throw error }
        }
    }

    func reset() throws {
        let manager = FileManager.default
        var failed = false
        if manager.fileExists(atPath: fileURL.path) {
            do {
                try manager.removeItem(at: fileURL)
            } catch {
                failed = true
            }
        }
        do {
            try deleteLegacy()
        } catch {
            failed = true
        }
        if failed {
            throw PrivateExternalSyncStorageError.reset
        }
    }

    private func prepareDirectory() throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PrivateExternalSyncStorageError.directory
        }
        try excludeFromBackup(directory)
        try protect(directory, isDirectory: true)
    }

    private func excludeFromBackup(_ url: URL) throws {
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        } catch {
            throw PrivateExternalSyncStorageError.backupExclusion
        }
    }

    private func protect(_ url: URL, isDirectory: Bool = false) throws {
#if os(iOS) || os(tvOS)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        } catch {
            throw PrivateExternalSyncStorageError.protection
        }
#else
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: isDirectory ? 0o700 : 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw PrivateExternalSyncStorageError.protection
        }
#endif
    }

    private func deleteLegacy() throws {
        let manager = FileManager.default
        var failed = false
        for legacyURL in legacyURLs where manager.fileExists(atPath: legacyURL.path) {
            do {
                try manager.removeItem(at: legacyURL)
            } catch {
                failed = true
            }
        }
        if failed {
            throw PrivateExternalSyncStorageError.legacyReset
        }
    }
}
