import Foundation

enum PrivateExternalSyncStorageError: String, Error, Sendable {
    case location
    case directory
    case backupExclusion
    case protection
    case read
    case write
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

    static func live(provider: String, file: String, legacyFiles: [String]) throws -> Self {
        let manager = FileManager.default
        guard let support = try? manager.url(
            for: .applicationSupportDirectory,
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
        try deleteLegacy()
        try prepareDirectory()
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw PrivateExternalSyncStorageError.write
        }
        do {
            try protect(fileURL)
            try excludeFromBackup(fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
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
