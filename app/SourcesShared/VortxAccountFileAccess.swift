#if os(iOS) || os(macOS)
import Foundation
import CryptoKit
import Darwin

/// File I/O only. No session, credential, account, restore or cloud-write capability.
/// Invoke on the worker actor; synchronous file-provider coordination may block.
enum VortxAccountFileAccess {
    static let maximumBytes = 10 * 1024 * 1024

    enum Failure: Error, Sendable {
        case invalidSelection, notRegularFile, tooLarge, coordinationFailed
        case outputChanged, destinationExists, readbackFailed
    }
    enum CopyKind: Sendable {
        case accountBackup, repairedAccount
        var prefix: String {
            switch self {
            case .accountBackup: return "vortx-account-backup"
            case .repairedAccount: return "vortx-account-repaired"
            }
        }
    }
    struct Selected: Sendable {
        let bytes: Data
        let sha256: String
    }
    struct Receipt: Sendable {
        let url: URL
        let bytes: Int
        let sha256: String
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func readSelected(_ selection: URL) throws -> Selected {
        try Task.checkCancellation()
        guard selection.isFileURL else { throw Failure.invalidSelection }
        let scoped = selection.startAccessingSecurityScopedResource()
        defer { if scoped { selection.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        var result: Result<Selected, Error>?
        NSFileCoordinator().coordinate(readingItemAt: selection, options: [], error: &error) { actual in
            result = Result {
                let bytes = try readRegularFile(actual)
                return Selected(bytes: bytes, sha256: digest(bytes))
            }
        }
        if let error { throw error }
        guard let result else { throw Failure.coordinationFailed }
        return try result.get()
    }

    /// The UI selects a DIRECTORY with .folder. Never pass a fileExporter result here.
    /// No existing destination is ever opened for writing. Success is local readback,
    /// not proof of remote-provider synchronization or crash durability.
    static func saveCopy(_ bytes: Data, expectedSHA256: String, kind: CopyKind,
                         in directory: URL) throws -> Receipt {
        try Task.checkCancellation()
        guard directory.isFileURL else { throw Failure.invalidSelection }
        guard bytes.count <= maximumBytes else { throw Failure.tooLarge }
        guard digest(bytes) == expectedSHA256 else { throw Failure.outputChanged }
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw Failure.invalidSelection
        }
        let destination = directory.appendingPathComponent(
            "\(kind.prefix)-\(UUID().uuidString.lowercased()).json", isDirectory: false)
        var error: NSError?
        var result: Result<Receipt, Error>?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: [], error: &error) { actual in
            result = Result {
                try writeNewFile(bytes, expectedSHA256: expectedSHA256, to: actual)
            }
        }
        if let error { throw error }
        guard let result else { throw Failure.coordinationFailed }
        return try result.get()
    }

    /// Actual bounded descriptor read. Neither metadata nor an unbounded Data initializer
    /// is the size gate. O_NONBLOCK prevents a selected FIFO from waiting for a writer.
    static func readRegularFile(_ url: URL, expectedIdentity: (device: dev_t, inode: ino_t)? = nil) throws -> Data {
        try Task.checkCancellation()
        guard url.isFileURL else { throw Failure.invalidSelection }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { throw posixError() }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.notRegularFile }
        if let expectedIdentity {
            guard attributes.st_dev == expectedIdentity.device, attributes.st_ino == expectedIdentity.inode else {
                throw Failure.readbackFailed
            }
        }
        guard attributes.st_size <= Int64(maximumBytes) else { throw Failure.tooLarge }
        var bytes = Data()
        while bytes.count <= maximumBytes {
            try Task.checkCancellation()
            let allowance = min(65_536, maximumBytes + 1 - bytes.count)
            guard let chunk = try handle.read(upToCount: allowance), !chunk.isEmpty else { break }
            bytes.append(chunk)
        }
        try Task.checkCancellation()
        guard bytes.count <= maximumBytes else { throw Failure.tooLarge }
        return bytes
    }

    /// Internal primitive also used by fixtures. Production calls it only inside
    /// the coordinated saveCopy accessor, with the selected directory's scope live.
    static func writeNewFile(_ bytes: Data, expectedSHA256: String, to url: URL) throws -> Receipt {
        try Task.checkCancellation()
        guard url.isFileURL else { throw Failure.invalidSelection }
        guard bytes.count <= maximumBytes else { throw Failure.tooLarge }
        guard digest(bytes) == expectedSHA256 else { throw Failure.outputChanged }
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                     mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            if errno == EEXIST { throw Failure.destinationExists }
            throw posixError()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var created = stat()
        guard fstat(descriptor, &created) == 0 else { throw posixError() }
        do {
            try Task.checkCancellation()
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            try Task.checkCancellation()
            var current = stat()
            guard lstat(url.path, &current) == 0,
                  current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  current.st_dev == created.st_dev, current.st_ino == created.st_ino else {
                throw Failure.readbackFailed
            }
            let actual = try readRegularFile(url, expectedIdentity: (created.st_dev, created.st_ino))
            guard actual.count == bytes.count, digest(actual) == expectedSHA256 else {
                throw Failure.readbackFailed
            }
            return Receipt(url: url, bytes: actual.count, sha256: digest(actual))
        } catch {
            // Called while the coordinated writer still owns the operation. Leave a
            // replaced/renamed entry alone; never remove a caller's pre-existing file.
            removeOwnedIncompleteFile(url, matching: created)
            throw error
        }
    }

    static func removeOwnedIncompleteFile(_ url: URL, matching created: stat) {
        var remaining = stat()
        if lstat(url.path, &remaining) == 0,
           remaining.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
           remaining.st_dev == created.st_dev, remaining.st_ino == created.st_ino {
            _ = Darwin.unlink(url.path)
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

/// One serial lane for bounded file I/O; never read external providers on MainActor.
actor VortxAccountFileAccessWorker {
    static let shared = VortxAccountFileAccessWorker()
    func read(_ url: URL) throws -> VortxAccountFileAccess.Selected {
        try VortxAccountFileAccess.readSelected(url)
    }
    func save(_ bytes: Data, expectedSHA256: String, kind: VortxAccountFileAccess.CopyKind,
              in directory: URL) throws -> VortxAccountFileAccess.Receipt {
        try VortxAccountFileAccess.saveCopy(bytes, expectedSHA256: expectedSHA256,
                                          kind: kind, in: directory)
    }
}
#endif
