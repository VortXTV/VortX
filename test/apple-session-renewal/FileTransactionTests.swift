// Authored UNRUN host controls. Compiles WHOLE actual Keychain.swift + CredentialScope.swift.
// No production lock/map/marker algorithm is duplicated; only disposable paths and coordination.
import Foundation
import Darwin

private enum FileTestFailure: Error { case failed }
@main struct FileTransactionTests {
    static let fm = FileManager.default
    static func check(_ value: Bool, _ label: String) throws {
        if !value { print("FAIL " + label); throw FileTestFailure.failed }
    }
    static func store(_ adapter: KeychainFileAdapter) -> KeychainFailureClosedStore {
        KeychainFailureClosedStore(readSecure: { adapter.read($0) }, writeSecure: { adapter.write($0, for: $1) },
            invalidationAccount: { "fixture.marker." + Data($0.utf8).base64EncodedString() }, invalidationSentinel: "invalidated",
            isLegacyInvalidated: { _ in false }, clearLegacyInvalidated: { _ in }, purgeAllLegacy: {}, purgeLegacy: { _ in },
            mutationTransaction: { adapter.withMutationTransaction($0) })
    }
    static func directory(_ root: URL, _ name: String) throws -> URL {
        let result = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return result
    }
    static func wait(_ predicate: () -> Bool, seconds: Double = 5) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() { guard Date() < deadline else { throw FileTestFailure.failed }; Thread.sleep(forTimeInterval: 0.01) }
    }
    static func signal(_ path: URL) throws { try Data("ready".utf8).write(to: path); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
    static func spawn(_ args: [String], log: URL) throws -> Process {
        _ = fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = args
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle; process.standardError = handle
        try process.run(); try handle.close()
        return process
    }
    static func settle(_ child: Process) {
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if child.isRunning {
            child.terminate()
            let term = Date().addingTimeInterval(1)
            while child.isRunning && Date() < term { Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning {
                _ = Darwin.kill(child.processIdentifier, SIGKILL)
                let killed = Date().addingTimeInterval(2)
                while child.isRunning && Date() < killed { Thread.sleep(forTimeInterval: 0.01) }
            }
        }
        // No unbounded waitUntilExit; only this owned child PID may be terminated.
    }
    static func childMode(_ args: [String]) throws -> Int32 {
        let file = URL(fileURLWithPath: args[2]); let adapter = KeychainFileAdapter(fileURL: file)
        switch args[1] {
        case "--hold":
            guard args.count == 5 else { throw FileTestFailure.failed }
            let ready = URL(fileURLWithPath: args[3]), release = URL(fileURLWithPath: args[4])
            let result = adapter.withMutationTransaction {
                do { try signal(ready); try wait({ fm.fileExists(atPath: release.path) }, seconds: 10); return .success }
                catch { return .failure }
            }
            return result == .success ? 0 : 3
        case "--delete": guard args.count == 3 else { throw FileTestFailure.failed }; return store(adapter).set(nil, for: "session") == .success ? 0 : 4
        case "--put": guard args.count == 5 else { throw FileTestFailure.failed }; return store(adapter).set(args[3], for: args[4]) == .success ? 0 : 4
        default: throw FileTestFailure.failed
        }
    }
    static func independentAdaptersAndNestedWrite(_ root: URL) throws {
        let dir = try directory(root, "adapters"), file = dir.appendingPathComponent("credentials.plist")
        let first = KeychainFileAdapter(fileURL: file), second = KeychainFileAdapter(fileURL: file)
        try check(first.write("keep", for: "unrelated") == .success, "initial-real-atomic-writer")
        var entered = false
        let accepted = first.withMutationTransaction {
            guard first.write("one", for: "a") == .success else { return .failure } // Actual nested write reuses the outer descriptor.
            let busy = second.withMutationTransaction { entered = true; return .success }
            return busy == .failure && second.write("must-not-land", for: "b") == .failure ? .success : .failure
        }
        try check(accepted == .success && !entered && first.read("b") == .missing, "nested-transaction-retains-lock")
        try check(second.write("two", for: "b") == .success && first.read("a") == .value("one") && first.read("unrelated") == .value("keep"), "independent-retry-conserves-map")
        let mode = try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        try check(mode?.intValue == 0o600, "real-atomic-file-owner-mode")
    }
    static func childContentionAndDelete(_ root: URL) throws {
        let dir = try directory(root, "process"), file = dir.appendingPathComponent("credentials.plist")
        let adapter = KeychainFileAdapter(fileURL: file), originalStore = store(adapter)
        try check(originalStore.set("old", for: "session") == .success && adapter.write("keep", for: "unrelated") == .success, "process-seed")
        let ready = dir.appendingPathComponent("ready"), release = dir.appendingPathComponent("release")
        let holder = try spawn(["--hold", file.path, ready.path, release.path], log: dir.appendingPathComponent("hold.log"))
        defer { try? signal(release); settle(holder) }
        try wait { fm.fileExists(atPath: ready.path) }
        let before = try Data(contentsOf: file); var entered = false
        let begin = ContinuousClock.now
        let failed = adapter.withMutationTransaction { entered = true; return .success }
        try check(begin.duration(to: .now) < .seconds(2) && failed == .failure && !entered, "actual-child-flock-is-nonblocking")
        let blockedSet = originalStore.set("must-not-land", for: "session")
        let blockedCAS = originalStore.replaceConfirmedUTF8(expected: Data("old".utf8), with: Data("renewed".utf8), account: "session")
        let afterBusy = try Data(contentsOf: file)
        try check(blockedSet == .failure && blockedCAS == .failure && afterBusy == before, "busy-store-no-marker-or-backend-write")
        try signal(release); try wait { !holder.isRunning }; try check(holder.terminationStatus == 0, "holder-joined")
        try check(originalStore.confirmedString("session") == .value("old"), "busy-intent-no-volatile-candidate")
        let deletion = try spawn(["--delete", file.path], log: dir.appendingPathComponent("delete.log")); defer { settle(deletion) }
        try wait { !deletion.isRunning }; try check(deletion.terminationStatus == 0, "child-store-delete-accepted")
        let deletedBytes = try Data(contentsOf: file)
        let staleCAS = originalStore.replaceConfirmedUTF8(expected: Data("old".utf8), with: Data("stale-resurrection".utf8), account: "session")
        let afterStale = try Data(contentsOf: file)
        try check(staleCAS == .failure && originalStore.confirmedString("session") == .missing &&
                  adapter.read("session") == .missing && adapter.read("unrelated") == .value("keep") && afterStale == deletedBytes,
                  "stale-parent-CAS-cannot-resurrect-child-signout")
        let write = try spawn(["--put", file.path, "child-value", "child-key"], log: dir.appendingPathComponent("put.log")); defer { settle(write) }
        try wait { !write.isRunning }; try check(write.terminationStatus == 0, "child-store-retry")
        try check(originalStore.set("parent-value", for: "parent-key") == .success &&
                  adapter.read("child-key") == .value("child-value") && adapter.read("unrelated") == .value("keep"), "cross-process-map-conservation")
    }
    static func unsafeSidecars(_ root: URL) throws {
        for kind in ["symlink", "directory", "permissive"] {
            let dir = try directory(root, "unsafe-" + kind), file = dir.appendingPathComponent("credentials.plist")
            let sidecar = URL(fileURLWithPath: file.path + ".lock")
            if kind == "symlink" {
                let target = dir.appendingPathComponent("target"); try signal(target)
                try fm.createSymbolicLink(atPath: sidecar.path, withDestinationPath: target.path)
            } else if kind == "directory" { try fm.createDirectory(at: sidecar, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            else { _ = fm.createFile(atPath: sidecar.path, contents: Data(), attributes: [.posixPermissions: 0o644]); try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecar.path) }
            var entered = false
            let transaction = KeychainFileMutationTransaction(fileURL: file)
            try check(transaction.perform { entered = true; return .success } == .failure && !entered && !fm.fileExists(atPath: file.path), "unsafe-sidecar-closure-not-entered")
        }
    }
    static func main() {
        do {
            let args = CommandLine.arguments
            if args.count >= 3 && args[1].hasPrefix("--") { exit(try childMode(args)) }
            guard args.count == 2 else { throw FileTestFailure.failed }
            let root = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
            try check(!fm.fileExists(atPath: root.path), "new-owned-root")
            try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try independentAdaptersAndNestedWrite(root); try childContentionAndDelete(root); try unsafeSidecars(root)
            print("PASS three actual-file groups only; original Keychain suite is selected separately")
        } catch { print("FAIL actual file transaction tests; disposable files/logs retained"); exit(1) }
    }
}
