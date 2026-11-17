// Standalone tests for the macOS file-backed Keychain adapter and its failure-closed wrapper.
//
// Run with:
//   swiftc -swift-version 5 -o /private/tmp/keychain-file-adapter \
//     app/SourcesShared/CredentialScope.swift \
//     app/SourcesShared/Keychain.swift \
//     app/Tests/KeychainFileAdapterTests.swift && /private/tmp/keychain-file-adapter

import Foundation
import Darwin

private enum InjectedAtomicWriteFailure: Error {
    case beforeRename
}

@MainActor
@main
struct KeychainFileAdapterTests {
    final class MarkerStore {
        var legacyMarkers = Set<String>()
        var persistCalls = 0

        func makeStore(adapter: KeychainFileAdapter) -> KeychainFailureClosedStore {
            KeychainFailureClosedStore(
                readSecure: { account in adapter.read(account) },
                writeSecure: { [self] value, account in
                    persistCalls += 1
                    return adapter.write(value, for: account)
                },
                invalidationAccount: { Keychain.durableInvalidationAccount(for: $0) },
                invalidationSentinel: Keychain.durableInvalidationSentinel,
                isLegacyInvalidated: { [self] account in legacyMarkers.contains(account) },
                clearLegacyInvalidated: { [self] account in legacyMarkers.remove(account) },
                purgeAllLegacy: {},
                purgeLegacy: { _ in },
                mutationTransaction: { operation in adapter.withMutationTransaction(operation) }
            )
        }
    }

    static var passes = 0
    static var failures = 0

    static func check(
        _ name: String,
        _ condition: @autoclosure () -> Bool,
        _ detail: @autoclosure () -> String = ""
    ) {
        if condition() {
            passes += 1
            print("  PASS  \(name)")
        } else {
            failures += 1
            let message = detail()
            print("  FAIL  \(name)\(message.isEmpty ? "" : " [\(message)]")")
        }
    }

    static func main() {
        testReadAndDecodeResults()
        testPersistThenPermissionFailureIsUncertain()
        testCredentialAndTombstoneShareOneFileMap()
        testLegacyDescriptorReadHardening()
        testPreexistingApplicationSupportDirectory()
        testRealFilesystemAtomicPersistence()

        print("\n----------------------------------------")
        print("passes: \(passes)  failures: \(failures)")
        print("----------------------------------------")
        exit(failures == 0 ? 0 : 1)
    }

    static func testReadAndDecodeResults() {
        print("\n=== file adapter distinguishes missing, value, and decode failure ===")
        var file: [String: String]? = nil
        let adapter = KeychainFileAdapter(
            readFile: { file.map { .value($0) } ?? .missing },
            persistFile: { file = $0; return .success }
        )

        check("missing file is a certified missing key", adapter.read("account") == .missing)
        file = ["account": "file-secret"]
        check("decoded file value is returned", adapter.read("account") == .value("file-secret"))
        check("missing key in a decoded file is certified missing", adapter.read("other") == .missing)

        let corrupt = KeychainFileAdapter(
            readFile: { .failure },
            persistFile: { _ in .failure }
        )
        check("corrupt file is a read failure", corrupt.read("account") == .failure)
        check("corrupt file cannot be mutated", corrupt.write("new-secret", for: "account") == .failure)
    }

    static func testPersistThenPermissionFailureIsUncertain() {
        print("\n=== persist success followed by permission failure stays unconfirmed ===")
        var file: [String: String]? = nil
        var persistThenPermissionFailure = true
        let adapter = KeychainFileAdapter(
            readFile: { file.map { .value($0) } ?? .missing },
            persistFile: { next in
                file = next
                if persistThenPermissionFailure { return .failure }
                return .success
            }
        )
        let harness = MarkerStore()
        let store = harness.makeStore(adapter: adapter)

        check("post-persist permission failure is reported as failure",
              store.set("new-secret", for: "account") == .failure)
        let markerAccount = Keychain.durableInvalidationAccount(for: "account")
        check("failed tombstone persistence never touches credential bytes",
              file?["account"] == nil)
        check("a post-persist marker failure remains durably fail-closed",
              file?[markerAccount] == Keychain.durableInvalidationSentinel)
        check("marked bytes cannot be confirmed",
              store.confirmedString("account") == .failure)
        check("migration bypass sees no credential mutation",
              store.durableString("account") == .missing)

        persistThenPermissionFailure = false
        check("a later successful persist confirms the value",
              store.set("confirmed-secret", for: "account") == .success)
        check("successful file mutation clears the durable marker",
              file?[markerAccount] == nil)
        check("successful file mutation is certified",
              store.confirmedString("account") == .value("confirmed-secret"))
    }

    static func testCredentialAndTombstoneShareOneFileMap() {
        print("\n=== credential and tombstone share the owner-only file map ===")
        var file: [String: String]? = ["account": "old-secret"]
        var persistCall = 0
        let adapter = KeychainFileAdapter(
            readFile: { file.map { .value($0) } ?? .missing },
            persistFile: { next in
                persistCall += 1
                file = next
                return persistCall == 2 ? .failure : .success
            }
        )
        let store = MarkerStore().makeStore(adapter: adapter)
        let markerAccount = Keychain.durableInvalidationAccount(for: "account")

        check("target persistence failure is reported",
              store.set("new-secret", for: "account") == .failure)
        check("one persisted map contains both uncertain target and tombstone",
              file?["account"] == "new-secret"
                && file?[markerAccount] == Keychain.durableInvalidationSentinel)
        check("a fresh wrapper rejects the uncertain map",
              MarkerStore().makeStore(adapter: adapter).confirmedString("account") == .failure)
        check("retry certifies target and clears tombstone in the same map",
              MarkerStore().makeStore(adapter: adapter).set("new-secret", for: "account") == .success
                && file?["account"] == "new-secret"
                && file?[markerAccount] == nil)
    }

    static func testLegacyDescriptorReadHardening() {
        print("\n=== legacy credential reads reject hostile filesystem objects ===")
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SourcesShared/Keychain.swift")
        let source = (try? String(contentsOf: sourceURL, encoding: .utf8)) ?? ""
        check("legacy reader opens without following symlinks", source.contains("O_NOFOLLOW"))
        check("legacy reader validates the opened descriptor", source.contains("Darwin.fstat("))
        check("legacy reader verifies the effective owner", source.contains("owner == effectiveOwner"))
        check("legacy reader decodes from the opened descriptor", source.contains("readAll(from: descriptor)"))
        check("legacy reader never reopens the credential path to decode",
              !source.contains("Data(contentsOf: fileURL)"))

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("vortx-keychain-legacy-read-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("credentials.plist")
        let targetURL = root.appendingPathComponent("target.plist")
        defer { try? fileManager.removeItem(at: root) }

        guard let secretBytes = try? PropertyListSerialization.data(
            fromPropertyList: ["account": "old-secret"], format: .binary, options: 0) else {
            check("legacy fixture encodes", false)
            return
        }

        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try secretBytes.write(to: fileURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            check("legacy fixture setup", false, "\(error)")
            return
        }

        let adapter = KeychainFileAdapter(fileURL: fileURL, fileManager: fileManager)
        check("valid old 0600 credential file remains readable",
              adapter.read("account") == .value("old-secret"))

        do {
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        } catch {
            check("permissive fixture setup", false, "\(error)")
            return
        }
        let permissiveResult = adapter.read("account")
        let permissiveMode = ((try? fileManager.attributesOfItem(atPath: fileURL.path)[.posixPermissions])
            as? NSNumber)?.intValue ?? -1
        check("permissive legacy credential file is certified failure", permissiveResult == .failure)
        check("permissive legacy credential file never publishes bytes",
              permissiveResult != .value("old-secret"))
        check("permissive legacy credential file is not silently chmodded",
              permissiveMode & 0o777 == 0o644, "mode \(permissiveMode)")
        check("permissive legacy credential file is not deleted",
              (try? Data(contentsOf: fileURL)) == secretBytes)

        do {
            try fileManager.removeItem(at: fileURL)
            try secretBytes.write(to: targetURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
            try fileManager.createSymbolicLink(atPath: fileURL.path, withDestinationPath: targetURL.path)
        } catch {
            check("symlink fixture setup", false, "\(error)")
            return
        }
        let symlinkResult = adapter.read("account")
        check("symlinked legacy credential file is certified failure", symlinkResult == .failure)
        check("symlinked legacy credential file never publishes target bytes",
              symlinkResult != .value("old-secret"))
        check("symlinked legacy credential file is not deleted",
              (try? fileManager.destinationOfSymbolicLink(atPath: fileURL.path)) == targetURL.path)
        check("symlink target bytes are not modified", (try? Data(contentsOf: targetURL)) == secretBytes)

        do {
            try fileManager.removeItem(at: fileURL)
            try fileManager.createDirectory(
                at: fileURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch {
            check("directory fixture setup", false, "\(error)")
            return
        }
        let directoryResult = adapter.read("account")
        check("directory at legacy credential path is certified failure", directoryResult == .failure)
        check("directory at legacy credential path never publishes bytes",
              directoryResult != .value("old-secret"))
        check("directory at legacy credential path is not deleted",
              fileManager.fileExists(atPath: fileURL.path))

        do {
            try fileManager.removeItem(at: fileURL)
            try Data([0x00]).write(to: fileURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            check("corrupt legacy fixture setup", false, "\(error)")
            return
        }
        let corruptResult = adapter.read("account")
        check("corrupt legacy credential file is certified failure", corruptResult == .failure)
        check("corrupt legacy credential file never publishes bytes",
              corruptResult != .value("old-secret"))
    }

    static func testPreexistingApplicationSupportDirectory() {
        print("\n=== credential writes protect the existing streaming-server parent ===")
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory
            .appendingPathComponent("vortx-keychain-parent-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: fixture) }

        func mode(of url: URL) -> Int? {
            ((try? manager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue
        }

        do {
            try manager.createDirectory(at: fixture, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            for existingCredential in [false, true] {
                let root = fixture.appendingPathComponent(existingCredential ? "existing" : "fresh", isDirectory: true)
                let serverData = root.appendingPathComponent("stremio-server", isDirectory: true)
                let fileURL = root.appendingPathComponent("credentials.plist")
                try manager.createDirectory(at: serverData, withIntermediateDirectories: true)
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
                if existingCredential {
                    let old = try PropertyListSerialization.data(
                        fromPropertyList: ["other": "existing-synthetic"], format: .binary, options: 0)
                    try old.write(to: fileURL)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                }
                let adapter = KeychainFileAdapter(fileURL: fileURL, fileManager: manager)
                let store = MarkerStore().makeStore(adapter: adapter)
                check("existing 0755 parent permits certified credential write (existing=\(existingCredential))",
                      store.set("new-synthetic", for: "account") == .success)
                check("certified read returns the newly stored value", store.confirmedString("account") == .value("new-synthetic"))
                check("other entries remain intact", adapter.read("other") ==
                      (existingCredential ? .value("existing-synthetic") : .missing))
                check("credential parent is 0700", mode(of: root) == 0o700)
                check("credential and lock files are 0600", mode(of: fileURL) == 0o600
                      && mode(of: root.appendingPathComponent("credentials.plist.lock")) == 0o600)
                check("streaming-server directory is retained", manager.fileExists(atPath: serverData.path))
            }

            let writable = fixture.appendingPathComponent("writable", isDirectory: true)
            try manager.createDirectory(at: writable, withIntermediateDirectories: false)
            try manager.setAttributes([.posixPermissions: 0o777], ofItemAtPath: writable.path)
            let rejectedFile = writable.appendingPathComponent("credentials.plist")
            let rejected = KeychainFileAdapter(fileURL: rejectedFile, fileManager: manager)
            check("world-writable parent cannot adopt credentials", rejected.write("synthetic", for: "account") == .failure)
            check("world-writable parent is left intact", mode(of: writable) == 0o777
                  && !manager.fileExists(atPath: rejectedFile.path))

            let aclParent = fixture.appendingPathComponent("extended-acl", isDirectory: true)
            try manager.createDirectory(at: aclParent, withIntermediateDirectories: false)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: aclParent.path)
            let grant = Process()
            grant.executableURL = URL(fileURLWithPath: "/bin/chmod")
            grant.arguments = ["+a", "everyone allow add_file,search", aclParent.path]
            try grant.run()
            grant.waitUntilExit()
            check("ACL fixture grants write access outside mode bits", grant.terminationStatus == 0)
            if grant.terminationStatus == 0 {
                let file = aclParent.appendingPathComponent("credentials.plist")
                let aclAdapter = KeychainFileAdapter(fileURL: file, fileManager: manager)
                check("ACL parent cannot adopt credentials", aclAdapter.write("synthetic", for: "account") == .failure)
                check("ACL parent mode and files stay untouched", mode(of: aclParent) == 0o755
                      && (try? manager.contentsOfDirectory(atPath: aclParent.path)) == [])
                let descriptor = aclParent.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_DIRECTORY) }
                if descriptor >= 0 {
                    let acl = Darwin.acl_get_fd(descriptor)
                    check("existing ACL is retained", acl != nil)
                    if let acl { _ = Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
                    _ = Darwin.close(descriptor)
                } else {
                    check("open rejected ACL parent for fixture readback", false)
                }
            }

            let target = fixture.appendingPathComponent("target", isDirectory: true)
            try manager.createDirectory(at: target, withIntermediateDirectories: false)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            let link = fixture.appendingPathComponent("link", isDirectory: true)
            try manager.createSymbolicLink(at: link, withDestinationURL: target)
            let linked = KeychainFileAdapter(fileURL: link.appendingPathComponent("credentials.plist"), fileManager: manager)
            check("symlinked parent cannot adopt credentials", linked.write("synthetic", for: "account") == .failure)
            check("symlink target permissions and files are untouched", mode(of: target) == 0o755
                  && (try? manager.contentsOfDirectory(atPath: target.path)) == [])
        } catch {
            check("preexisting-parent fixture setup", false, "\(error)")
        }
    }

    static func testRealFilesystemAtomicPersistence() {
        print("\n=== real file persistence is owner-only and atomic ===")
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("vortx-keychain-file-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("credentials.plist")
        defer { try? fileManager.removeItem(at: root) }

        let adapter = KeychainFileAdapter(fileURL: fileURL, fileManager: fileManager)
        check("initial real file write succeeds", adapter.write("old-secret", for: "account") == .success)

        let fileMode = ((try? fileManager.attributesOfItem(atPath: fileURL.path)[.posixPermissions])
            as? NSNumber)?.intValue ?? -1
        let directoryMode = ((try? fileManager.attributesOfItem(atPath: root.path)[.posixPermissions])
            as? NSNumber)?.intValue ?? -1
        check("credential file is 0600", fileMode & 0o777 == 0o600, "mode \(fileMode)")
        check("credential directory is 0700", directoryMode & 0o777 == 0o700,
              "mode \(directoryMode)")

        let oldBytes = try? Data(contentsOf: fileURL)
        let originalEntries = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        let replacement: [String: String] = ["account": "new-secret", "other": "other-secret"]
        let replacementBytes = try? PropertyListSerialization.data(
            fromPropertyList: replacement, format: .binary, options: 0)
        let interrupted = replacementBytes.map {
            KeychainAtomicFileWriter.persist($0, to: fileURL, fileManager: fileManager) {
                throw InjectedAtomicWriteFailure.beforeRename
            }
        } ?? .success
        check("injected pre-rename failure is reported", interrupted == .failure)
        check("pre-rename failure preserves exact destination bytes",
              (try? Data(contentsOf: fileURL)) == oldBytes)
        let residues = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        check("pre-rename failure removes its private temporary file",
              Set(residues) == Set(originalEntries), "entries \(residues)")

        let replaced = replacementBytes.map {
            KeychainAtomicFileWriter.persist($0, to: fileURL, fileManager: fileManager)
        } ?? .failure
        check("durable atomic replacement succeeds", replaced == .success)
        check("replacement publishes the complete new map",
              adapter.read("account") == .value("new-secret")
                && adapter.read("other") == .value("other-secret"))
        let replacementMode = ((try? fileManager.attributesOfItem(atPath: fileURL.path)[.posixPermissions])
            as? NSNumber)?.intValue ?? -1
        check("replacement inode remains 0600", replacementMode & 0o777 == 0o600,
              "mode \(replacementMode)")
    }
}
