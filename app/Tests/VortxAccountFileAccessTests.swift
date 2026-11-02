#if os(macOS)
import Foundation
import Darwin

/// Standalone filesystem harness. Compile with the maintained helper, no account/ABI stub.
@main
struct VortxAccountFileAccessTests {
    static func main() async throws {
        typealias IO = VortxAccountFileAccess
        let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("app/build", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("account-file-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw NSError(domain: "FileAccessFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: name]) }
            count += 1
        }
        func refuses(_ action: () throws -> Void, _ name: String) throws {
            do { try action() }
            catch { count += 1; return }
            try check(false, name)
        }
        let original = root.appendingPathComponent("original.json")
        let bytes = Data("abc".utf8)
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try bytes.write(to: original)
        let selected = try await VortxAccountFileAccessWorker.shared.read(original)
        try check(selected.bytes == bytes && selected.sha256 == digest, "coordinated import exact bytes and known SHA")
        try check(try Data(contentsOf: original) == bytes, "import leaves original unchanged")
        let boundary = root.appendingPathComponent("boundary.json")
        try Data(repeating: 7, count: IO.maximumBytes).write(to: boundary)
        try check(try IO.readRegularFile(boundary).count == IO.maximumBytes, "exact10MiB accepted")
        let oversized = root.appendingPathComponent("oversized.json")
        try Data(repeating: 7, count: IO.maximumBytes + 1).write(to: oversized)
        try refuses({ _ = try IO.readSelected(oversized) }, "10MiB+1 rejected")
        try refuses({ _ = try IO.readRegularFile(root) }, "directory rejected")
        let fifo = root.appendingPathComponent("pipe")
        guard mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try refuses({ _ = try IO.readRegularFile(fifo) }, "FIFO rejected without waiting for a writer")
        let symlink = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        try refuses({ _ = try IO.readRegularFile(symlink) }, "leaf symlink import rejected")
        try refuses({ _ = try IO.readSelected(URL(string: "https://invalid.example/file")!) }, "nonfile URL rejected")
        try refuses({ _ = try IO.readRegularFile(original, expectedIdentity: (0, 0)) }, "readback descriptor identity checked")
        let exported = try await VortxAccountFileAccessWorker.shared.save(bytes, expectedSHA256: digest,
            kind: .repairedAccount, in: root)
        try check(exported.bytes == bytes.count && exported.sha256 == digest,
                  "export receipt has exact length and digest")
        try check(try Data(contentsOf: exported.url) == bytes, "receipt describes actual new file")
        try check(exported.url.lastPathComponent.hasPrefix("vortx-account-repaired-")
                  && exported.url.pathExtension == "json", "clear unique repaired filename")
        let second = try IO.saveCopy(bytes, expectedSHA256: digest, kind: .accountBackup, in: root)
        try check(second.url != exported.url && second.url.lastPathComponent.hasPrefix("vortx-account-backup-"),
                  "second export creates separate named copy")
        try refuses({ _ = try IO.writeNewFile(Data("different".utf8), expectedSHA256: IO.digest(Data("different".utf8)), to: original) },
                    "preexisting source cannot be overwritten")
        try check(try Data(contentsOf: original) == bytes, "source survives refused overwrite")
        try refuses({ _ = try IO.writeNewFile(bytes, expectedSHA256: digest, to: symlink) }, "existing symlink not followed or replaced")
        let hardlink = root.appendingPathComponent("hardlink.json")
        guard Darwin.link(original.path, hardlink.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try refuses({ _ = try IO.writeNewFile(bytes, expectedSHA256: digest, to: hardlink) }, "existing hardlink refused")
        let wrong = root.appendingPathComponent("wrong.json")
        try refuses({ _ = try IO.writeNewFile(bytes, expectedSHA256: String(repeating: "0", count: 64), to: wrong) }, "wrong digest rejected before create")
        try check(!FileManager.default.fileExists(atPath: wrong.path), "wrong digest leaves no file")
        var saved = stat()
        guard lstat(exported.url.path, &saved) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try check(saved.st_mode & mode_t(0o777) == mode_t(0o600), "new copy owner-only permissions")
        let incomplete = root.appendingPathComponent("incomplete.json")
        try bytes.write(to: incomplete)
        var owned = stat()
        guard lstat(incomplete.path, &owned) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        IO.removeOwnedIncompleteFile(incomplete, matching: owned)
        try check(!FileManager.default.fileExists(atPath: incomplete.path), "owned incomplete inode removed")
        try bytes.write(to: incomplete)
        let retainedDescriptor = try FileHandle(forReadingFrom: incomplete)
        defer { try? retainedDescriptor.close() }
        guard fstat(retainedDescriptor.fileDescriptor, &owned) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try FileManager.default.removeItem(at: incomplete)
        let replacement = Data("someone else's replacement".utf8)
        try replacement.write(to: incomplete)
        IO.removeOwnedIncompleteFile(incomplete, matching: owned)
        try check(try Data(contentsOf: incomplete) == replacement, "cleanup preserves replacement inode")
        IO.removeOwnedIncompleteFile(symlink, matching: saved)
        try check(try Data(contentsOf: original) == bytes, "cleanup never follows a symlink")
        print("PASS \(count) account file I/O checks")
    }
}
#endif
