import Foundation

/// Session-bound disk shape for reconstructed Trakt playback state.
struct TraktPlaybackCacheSnapshot: Codable, Equatable, Sendable {
    let sessionID: TraktSessionID
    var progress: [String: Double]
    /// Legacy single cursor retained only inside the new cache shape for downgrade compatibility.
    var stamp: String?
    var activity: TraktPlaybackActivityStamps?
    var items: [TraktContinueWatchingSeed]
    var hasSnapshot: Bool
}

/// Bounded error categories. Callers log only these categories, never paths, media ids, or system text.
enum TraktPlaybackCacheError: String, Error, Equatable, Sendable {
    case location
    case directory
    case backupExclusion
    case protection
    case encode
    case decode
    case read
    case write
    case reset
    case legacyReset
}

/// Protected, backup-excluded cache persistence for reconstructed viewing state.
///
/// The previous Application Support file is deleted, never migrated. It had no account identity and
/// therefore cannot be proven safe for the current login.
struct TraktPlaybackCacheStorage: Sendable {
    let cacheURL: URL
    let legacyURL: URL?

    static func live() throws -> TraktPlaybackCacheStorage {
        let manager = FileManager.default
        guard let caches = try? manager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            throw TraktPlaybackCacheError.location
        }
        let directory = caches
            .appendingPathComponent("StremioX", isDirectory: true)
            .appendingPathComponent("Trakt", isDirectory: true)
        let cache = directory.appendingPathComponent("trakt-shadow-playback.json")

        let support = try? manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let legacy = support?.appendingPathComponent("trakt-shadow-playback.json")
        return TraktPlaybackCacheStorage(cacheURL: cache, legacyURL: legacy)
    }

    /// Load only a snapshot proven to belong to the current auth session.
    func load(for sessionID: TraktSessionID) throws -> TraktPlaybackCacheSnapshot? {
        try deleteLegacy()
        let manager = FileManager.default
        guard manager.fileExists(atPath: cacheURL.path) else { return nil }
        // Refuse to read an existing cache until its directory and file protections are reasserted.
        // This also repairs permissions altered outside the app before private viewing state is decoded.
        try prepareDirectory()
        try protect(cacheURL)

        let data: Data
        do {
            data = try Data(contentsOf: cacheURL)
        } catch {
            throw TraktPlaybackCacheError.read
        }
        let snapshot: TraktPlaybackCacheSnapshot
        do {
            snapshot = try JSONDecoder().decode(TraktPlaybackCacheSnapshot.self, from: data)
        } catch {
            do {
                try manager.removeItem(at: cacheURL)
            } catch {
                throw TraktPlaybackCacheError.reset
            }
            throw TraktPlaybackCacheError.decode
        }
        guard snapshot.sessionID == sessionID else {
            do {
                try manager.removeItem(at: cacheURL)
            } catch {
                throw TraktPlaybackCacheError.reset
            }
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: TraktPlaybackCacheSnapshot) throws {
        try deleteLegacy()
        try prepareDirectory()
        let data: Data
        do {
            data = try JSONEncoder().encode(snapshot)
        } catch {
            throw TraktPlaybackCacheError.encode
        }
        do {
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            throw TraktPlaybackCacheError.write
        }
        do {
            try protect(cacheURL)
        } catch {
            do {
                try FileManager.default.removeItem(at: cacheURL)
            } catch {
                throw TraktPlaybackCacheError.reset
            }
            throw error
        }
    }

    /// Remove both the current cache and the old unsafe location. Every removal is attempted.
    func reset() throws {
        let manager = FileManager.default
        var failed = false
        if manager.fileExists(atPath: cacheURL.path) {
            do {
                try manager.removeItem(at: cacheURL)
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
            throw TraktPlaybackCacheError.reset
        }
    }

    private func prepareDirectory() throws {
        let manager = FileManager.default
        let directory = cacheURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw TraktPlaybackCacheError.directory
        }

        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(values)
        } catch {
            throw TraktPlaybackCacheError.backupExclusion
        }

        do {
            try protect(directory, isDirectory: true)
        } catch {
            throw error
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
            throw TraktPlaybackCacheError.protection
        }
#else
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: isDirectory ? 0o700 : 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw TraktPlaybackCacheError.protection
        }
#endif
    }

    private func deleteLegacy() throws {
        guard let legacyURL else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacyURL.path) else { return }
        do {
            try manager.removeItem(at: legacyURL)
        } catch {
            throw TraktPlaybackCacheError.legacyReset
        }
    }
}
