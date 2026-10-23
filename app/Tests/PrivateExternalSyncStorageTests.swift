// Disposable real-file regression fixtures for the private save transaction.
// Run through scripts/test-private-external-sync-storage.sh against the actual source/test files.
// The runner deliberately does not call live(), UserDefaults, Keychain, or any provider/account API.

import Foundation
import Darwin

@main
struct PrivateExternalSyncStorageTestRunner {
    struct PendingIntent: Codable, Equatable {
        let id: String
        let value: Int
    }
    struct Envelope: Codable, Equatable {
        let sessionID: String
        let pending: [PendingIntent]
        let padding: String
    }
    struct Snapshot {
        let bytes: Data
        let pending: [PendingIntent]
        let mode: Int
        let inode: UInt64
        let excluded: Bool
        #if os(iOS) || os(tvOS)
        let protection: FileProtectionType?
        #endif
    }

    static func main() throws {
        let manager = FileManager.default
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == "--fixture-root" else {
            throw FixtureError.invalidRoot
        }
        let source = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().standardizedFileURL
        let appDirectory = source.deletingLastPathComponent().deletingLastPathComponent()
        let allowed = appDirectory.appendingPathComponent("build", isDirectory: true).standardizedFileURL
        let root = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        let runDirectory = root.deletingLastPathComponent()
        let prefix = "private-external-sync-storage."
        let runName = runDirectory.lastPathComponent
        let suffix = runName.hasPrefix(prefix) ? String(runName.dropFirst(prefix.count)) : ""
        var runInfo = stat()
        var rootInfo = stat()
        guard source.lastPathComponent == "PrivateExternalSyncStorageTests.swift",
              source.deletingLastPathComponent().lastPathComponent == "Tests",
              appDirectory.lastPathComponent == "app",
              allowed.resolvingSymlinksInPath().path == allowed.path,
              root.resolvingSymlinksInPath().path == root.path,
              root.lastPathComponent == "fixtures",
              runDirectory.deletingLastPathComponent().path == allowed.path,
              suffix.utf8.count == 6,
              suffix.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              Darwin.lstat(runDirectory.path, &runInfo) == 0,
              runInfo.st_mode & S_IFMT == S_IFDIR,
              runInfo.st_uid == geteuid(),
              runInfo.st_mode & mode_t(0o7777) == mode_t(0o700),
              Darwin.lstat(root.path, &rootInfo) != 0, errno == ENOENT else {
            throw FixtureError.invalidRoot
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        // Retain disposable fixtures for evidence; no cleanup reaches outside this fresh root.
        var checks = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }

        expect(ImportedCatalogPersistencePolicy.isDurable(requiresConnection: nil),
               "legacy/public catalogs remain eligible for ordinary persistence")
        expect(ImportedCatalogPersistencePolicy.isDurable(requiresConnection: false),
               "explicitly public catalogs remain eligible for ordinary persistence")
        expect(!ImportedCatalogPersistencePolicy.isDurable(requiresConnection: true),
               "connection-scoped private catalogs remain memory-only")

        let prior = Envelope(sessionID: "disposable-session-a",
            pending: [PendingIntent(id: "pending-before-save", value: 7)], padding: "")
        let next = Envelope(sessionID: prior.sessionID,
            pending: prior.pending + [PendingIntent(id: "pending-next-save", value: 9)],
            padding: String(repeating: "x", count: 131_072))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let priorBytes = try encoder.encode(prior)
        let nextBytes = try encoder.encode(next)

        func storage(_ name: String) -> PrivateExternalSyncStorage {
            PrivateExternalSyncStorage(fileURL: root.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("state.json"), legacyURLs: [])
        }
        func snapshot(_ url: URL) throws -> Snapshot {
            let bytes = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(Envelope.self, from: bytes)
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
            #if os(iOS) || os(tvOS)
            return Snapshot(bytes: bytes, pending: document.pending, mode: mode, inode: inode,
                excluded: excluded, protection: attributes[.protectionKey] as? FileProtectionType)
            #else
            return Snapshot(bytes: bytes, pending: document.pending, mode: mode, inode: inode, excluded: excluded)
            #endif
        }
        func expectPreserved(_ actual: Snapshot, _ prior: Snapshot, _ name: String) {
            expect(actual.bytes == prior.bytes, "\(name): previous exact bytes survive")
            expect(actual.pending == prior.pending, "\(name): pending queue survives unchanged")
            expect(actual.mode == prior.mode, "\(name): previous permissions survive unchanged")
            expect(actual.inode == prior.inode, "\(name): previous inode survives unchanged")
            expect(actual.excluded == prior.excluded, "\(name): previous backup exclusion survives")
            #if os(iOS) || os(tvOS)
            expect(actual.protection == prior.protection, "\(name): previous complete protection survives")
            #endif
        }
        func expectPrivate(_ url: URL, _ name: String, empty: Bool = false) throws {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                   "\(name): staging inode is owner-only before payload")
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            expect(values.isExcludedFromBackup == true, "\(name): staging inode is backup-excluded before payload")
            #if os(iOS) || os(tvOS)
            expect(attributes[.protectionKey] as? FileProtectionType == .complete,
                   "\(name): staging inode has complete protection before payload")
            #endif
            if empty { expect(try Data(contentsOf: url).isEmpty, "\(name): metadata precedes all payload bytes") }
            if url.lastPathComponent == "payload" {
                let namespaceURL = url.deletingLastPathComponent()
                let namespaceAttributes = try manager.attributesOfItem(atPath: namespaceURL.path)
                expect((namespaceAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                       "\(name): operation namespace is owner-only")
                let namespaceValues = try namespaceURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                expect(namespaceValues.isExcludedFromBackup == true,
                       "\(name): operation namespace is backup-excluded before payload")
                #if os(iOS) || os(tvOS)
                expect(namespaceAttributes[.protectionKey] as? FileProtectionType == .complete,
                       "\(name): operation namespace has complete protection before payload")
                #endif
            }
        }

        let stages: [(PrivateExternalSyncStorage.SaveStage, PrivateExternalSyncStorageError)] = [
            (.prepareDirectory, .directory), (.createNamespace, .write), (.createStage, .write),
            (.namespaceProtection, .protection), (.namespaceBackupExclusion, .backupExclusion), (.protection, .protection),
            (.backupExclusion, .backupExclusion), (.write, .write), (.afterWriteChunk, .write),
            (.fileSync, .write), (.replace, .write)
        ]
        for (index, fault) in stages.enumerated() {
            let name = "precommit-\(index)"
            let subject = storage(name)
            try subject.save(priorBytes)
            let before = try snapshot(subject.fileURL)
            let directory = subject.fileURL.deletingLastPathComponent()
            let unrelated = directory.appendingPathComponent(".unrelated-owner.stage")
            let sentinel = Data("unrelated-disposable-evidence".utf8)
            try sentinel.write(to: unrelated)
            let namesBefore = try manager.contentsOfDirectory(atPath: directory.path).sorted()
            var reached = false
            do {
                try subject.save(nextBytes, barrier: { stage, stageURL in
                    if stage == .write, let stageURL { try expectPrivate(stageURL, name, empty: true) }
                    if stage == fault.0 {
                        reached = true
                        if stage == .protection || stage == .backupExclusion, let stageURL {
                            expect(try Data(contentsOf: stageURL).isEmpty,
                                   "\(name): protection/exclusion failure precedes payload")
                        }
                        if stage == .afterWriteChunk, let stageURL {
                            try expectPrivate(stageURL, name)
                            let stagedCount = try Data(contentsOf: stageURL).count
                            expect(stagedCount > 0 && stagedCount < nextBytes.count,
                                   "\(name): fault follows an actual partial file write")
                        }
                        throw fault.1
                    }
                })
                expect(false, "\(name): injected failure must throw")
            } catch let error as PrivateExternalSyncStorageError {
                expect(error == fault.1, "\(name): precommit failure retains its stage error")
            }
            expect(reached, "\(name): the intended production boundary was reached")
            expectPreserved(try snapshot(subject.fileURL), before, name)
            expect(try manager.contentsOfDirectory(atPath: directory.path).sorted() == namesBefore,
                   "\(name): only this operation's stage is cleaned")
            expect(try Data(contentsOf: unrelated) == sentinel, "\(name): unrelated evidence survives cleanup")
        }

        // Controlled substitution witnesses are within the disposable root. They demonstrate
        // observed path/FD mismatches, not immunity to arbitrary same-UID mutation between syscalls.
        let sentinelBytes = try encoder.encode(Envelope(sessionID: "disposable-sentinel",
            pending: [PendingIntent(id: "unowned-sentinel", value: 41)], padding: "sentinel"))
        func metadata(_ url: URL) throws -> [String: String] {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            return [
                "mode": String((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1),
                "inode": String((attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0),
                "excluded": String(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true),
                "protection": String(describing: attributes[.protectionKey])
            ]
        }
        for (index, fault) in [PrivateExternalSyncStorage.SaveStage.protection, .backupExclusion, .write, .replace].enumerated() {
            for useSymlink in [false, true] {
                let name = "payload-substitution-\(index)-\(useSymlink)"
                let subject = storage(name)
                try subject.save(priorBytes)
                let before = try snapshot(subject.fileURL)
                let sentinel = subject.fileURL.deletingLastPathComponent().appendingPathComponent("unowned-sentinel")
                try sentinelBytes.write(to: sentinel)
                let sentinelBefore = try snapshot(sentinel)
                var originalURL: URL?
                var originalBytes: Data?
                var substituteURL: URL?
                var reached = false
                do {
                    try subject.save(nextBytes, barrier: { stage, stageURL in
                        guard stage == fault, let stageURL else { return }
                        reached = true
                        let retained = stageURL.deletingLastPathComponent().appendingPathComponent("retained-owned-payload")
                        originalBytes = try Data(contentsOf: stageURL)
                        try manager.moveItem(at: stageURL, to: retained)
                        originalURL = retained
                        if useSymlink {
                            try manager.createSymbolicLink(at: stageURL, withDestinationURL: sentinel)
                            substituteURL = sentinel
                        } else {
                            try manager.moveItem(at: sentinel, to: stageURL)
                            substituteURL = stageURL
                        }
                    })
                    expect(false, "\(name): substituted payload must be rejected before commit")
                } catch let error as PrivateExternalSyncStorageError {
                    expect(error == .write, "\(name): observed identity mismatch fails closed")
                }
                expect(reached, "\(name): substitution boundary was reached")
                expectPreserved(try snapshot(subject.fileURL), before, name)
                if let substituteURL {
                    expectPreserved(try snapshot(substituteURL), sentinelBefore, "\(name) sentinel")
                } else { expect(false, "\(name): substitute witness URL exists") }
                if let originalURL, let originalBytes {
                    expect(try Data(contentsOf: originalURL) == originalBytes,
                           "\(name): displaced original stage is preserved after mismatch")
                } else { expect(false, "\(name): displaced original witness exists") }
            }
        }

        let namespaceFaults: [PrivateExternalSyncStorage.SaveStage] = [
            .namespaceProtection, .namespaceBackupExclusion, .protection, .backupExclusion, .replace
        ]
        for (index, fault) in namespaceFaults.enumerated() {
            // replacement directory, symlink to a different directory, and missing namespace.
            for variant in 0..<3 {
                let name = "namespace-substitution-\(index)-\(variant)"
                let subject = storage(name)
                try subject.save(priorBytes)
                let before = try snapshot(subject.fileURL)
                let parent = subject.fileURL.deletingLastPathComponent()
                let sentinelDirectory = parent.appendingPathComponent("unowned-directory", isDirectory: true)
                try manager.createDirectory(at: sentinelDirectory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o750])
                let sentinel = sentinelDirectory.appendingPathComponent("payload")
                try sentinelBytes.write(to: sentinel)
                let sentinelBefore = try snapshot(sentinel)
                let sentinelDirectoryBefore = try metadata(sentinelDirectory)
                var displacedPayload: URL?
                var displacedBytes: Data?
                var substitutePayload: URL?
                var substituteDirectory: URL?
                var reached = false
                do {
                    try subject.save(nextBytes, barrier: { stage, stageURL in
                        guard stage == fault, let stageURL else { return }
                        reached = true
                        let operationURL = stageURL.lastPathComponent == "payload"
                            ? stageURL.deletingLastPathComponent() : stageURL
                        let displaced = parent.appendingPathComponent("displaced-owned-namespace", isDirectory: true)
                        let payload = operationURL.appendingPathComponent("payload")
                        displacedBytes = try Data(contentsOf: payload)
                        try manager.moveItem(at: operationURL, to: displaced)
                        displacedPayload = displaced.appendingPathComponent("payload")
                        if variant == 0 {
                            try manager.moveItem(at: sentinelDirectory, to: operationURL)
                            substituteDirectory = operationURL
                            substitutePayload = operationURL.appendingPathComponent("payload")
                        } else if variant == 1 {
                            try manager.createSymbolicLink(at: operationURL, withDestinationURL: sentinelDirectory)
                            substituteDirectory = sentinelDirectory
                            substitutePayload = sentinel
                        }
                    })
                    expect(false, "\(name): displaced/substituted namespace must be rejected")
                } catch let error as PrivateExternalSyncStorageError {
                    expect(error == .write, "\(name): namespace mismatch fails closed before metadata/commit")
                }
                expect(reached, "\(name): namespace witness reached")
                expectPreserved(try snapshot(subject.fileURL), before, name)
                if let displacedPayload, let displacedBytes {
                    expect(try Data(contentsOf: displacedPayload) == displacedBytes,
                           "\(name): displaced namespace payload is preserved")
                } else { expect(false, "\(name): displaced namespace witness exists") }
                let checkedPayload = substitutePayload ?? sentinel
                let checkedDirectory = substituteDirectory ?? sentinelDirectory
                expectPreserved(try snapshot(checkedPayload), sentinelBefore, "\(name) sentinel")
                expect(try metadata(checkedDirectory) == sentinelDirectoryBefore,
                       "\(name): unowned directory mode/inode/protection/exclusion survives")
            }
        }

        // An unowned payload created just before O_EXCL must survive the genuine open failure.
        let openSubject = storage("exclusive-open-conflict")
        try openSubject.save(priorBytes)
        let openBefore = try snapshot(openSubject.fileURL)
        var conflictingURL: URL?
        var conflictingSnapshot: Snapshot?
        do {
            try openSubject.save(nextBytes, barrier: { stage, stageURL in
                if stage == .createStage, let stageURL {
                    try sentinelBytes.write(to: stageURL)
                    conflictingURL = stageURL
                    conflictingSnapshot = try snapshot(stageURL)
                }
            })
            expect(false, "exclusive open conflict: real O_EXCL failure throws")
        } catch let error as PrivateExternalSyncStorageError {
            expect(error == .write, "exclusive open conflict: production open error surfaces")
        }
        expectPreserved(try snapshot(openSubject.fileURL), openBefore, "exclusive open conflict")
        if let conflictingURL, let conflictingSnapshot {
            expectPreserved(try snapshot(conflictingURL), conflictingSnapshot, "exclusive open sentinel")
        } else { expect(false, "exclusive open conflict witness exists") }

        let siblingSubject = storage("unowned-operation-sibling")
        try siblingSubject.save(priorBytes)
        let siblingBefore = try snapshot(siblingSubject.fileURL)
        var siblingURL: URL?
        var siblingSnapshot: Snapshot?
        do {
            try siblingSubject.save(nextBytes, barrier: { stage, stageURL in
                if stage == .replace, let stageURL {
                    let sibling = stageURL.deletingLastPathComponent().appendingPathComponent("unowned-sibling")
                    try sentinelBytes.write(to: sibling)
                    siblingURL = sibling
                    siblingSnapshot = try snapshot(sibling)
                    throw PrivateExternalSyncStorageError.write
                }
            })
            expect(false, "unowned operation sibling: injected fault throws")
        } catch let error as PrivateExternalSyncStorageError {
            expect(error == .write, "unowned operation sibling: original fault surfaces")
        }
        expectPreserved(try snapshot(siblingSubject.fileURL), siblingBefore, "unowned operation sibling")
        if let siblingURL, let siblingSnapshot {
            expectPreserved(try snapshot(siblingURL), siblingSnapshot, "unowned operation sibling sentinel")
        } else { expect(false, "unowned operation sibling witness exists") }

        // Genuine local OS failures: immutable owned stage denies fchmod/xattr updates; a
        // read-only destination parent denies rename. Restore fixture flags/mode after inspection.
        // This requires the unprivileged macOS filesystem used by the bounded runner.
        guard geteuid() != 0 else { throw FixtureError.requiresUnprivilegedUser }
        for (index, fault) in [PrivateExternalSyncStorage.SaveStage.protection, .backupExclusion, .replace].enumerated() {
            let name = "actual-operation-failure-\(index)"
            let subject = storage(name)
            try subject.save(priorBytes)
            let before = try snapshot(subject.fileURL)
            var immutableStage: URL?
            var reached = false
            do {
                try subject.save(nextBytes, barrier: { stage, stageURL in
                    guard stage == fault, let stageURL else { return }
                    reached = true
                    if stage == .replace {
                        guard Darwin.chmod(subject.fileURL.deletingLastPathComponent().path, mode_t(0o500)) == 0 else {
                            throw FixtureError.failureSetup
                        }
                    } else {
                        guard Darwin.chflags(stageURL.path, UInt32(UF_IMMUTABLE)) == 0 else {
                            throw FixtureError.failureSetup
                        }
                        immutableStage = stageURL
                    }
                })
                expect(false, "\(name): actual filesystem operation must throw")
            } catch let error as PrivateExternalSyncStorageError {
                let expected: PrivateExternalSyncStorageError = fault == .protection ? .protection
                    : fault == .backupExclusion ? .backupExclusion : .write
                expect(error == expected, "\(name): real operation failure reaches production error branch")
            }
            if let immutableStage {
                guard Darwin.chflags(immutableStage.path, 0) == 0 else { throw FixtureError.failureSetup }
            }
            guard Darwin.chmod(subject.fileURL.deletingLastPathComponent().path, mode_t(0o700)) == 0 else {
                throw FixtureError.failureSetup
            }
            expect(reached, "\(name): intended actual operation failure boundary reached")
            expectPreserved(try snapshot(subject.fileURL), before, name)
        }

        let uncertain = storage("postrename-uncertainty")
        try uncertain.save(priorBytes)
        let beforeUncertain = try snapshot(uncertain.fileURL)
        do {
            try uncertain.save(nextBytes, barrier: { stage, _ in
                if stage == .directorySync { throw PrivateExternalSyncStorageError.write }
            })
            expect(false, "postrename uncertainty must throw")
        } catch let error as PrivateExternalSyncStorageError {
            expect(error == .uncertainCommit, "postrename failure explicitly reports an uncertain commit")
        }
        let visible = try snapshot(uncertain.fileURL)
        expect(visible.bytes == nextBytes && visible.inode != beforeUncertain.inode,
               "postrename failure preserves the visible replacement instead of claiming rollback")
        expect(visible.pending == next.pending, "postrename failure retains every candidate pending intent")
        try expectPrivate(uncertain.fileURL, "postrename uncertainty")

        let success = storage("success-and-policy")
        let legacy = root.appendingPathComponent("disposable-sessionless-legacy.json")
        try priorBytes.write(to: legacy)
        let policyStorage = PrivateExternalSyncStorage(fileURL: success.fileURL, legacyURLs: [legacy])
        try policyStorage.save(priorBytes)
        expect(!manager.fileExists(atPath: legacy.path), "existing sessionless legacy deletion policy is unchanged")
        try policyStorage.save(nextBytes, barrier: { stage, stageURL in
            if stage == .write, let stageURL { try expectPrivate(stageURL, "successful save", empty: true) }
        })
        expect(try policyStorage.load() == nextBytes, "successful replacement loads the exact session-bound envelope")
        try expectPrivate(policyStorage.fileURL, "successful save")
        let directoryAttributes = try manager.attributesOfItem(atPath: policyStorage.fileURL.deletingLastPathComponent().path)
        expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
               "private directory remains owner-only on macOS")
        let directoryValues = try policyStorage.fileURL.deletingLastPathComponent()
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        expect(directoryValues.isExcludedFromBackup == true, "private directory remains backup-excluded")
        try policyStorage.reset()
        expect(!manager.fileExists(atPath: policyStorage.fileURL.path), "explicit reset deletion policy is unchanged")

        if failures.isEmpty {
            print("PASS: \(checks) private external-sync storage checks; disposable fixtures retained at \(root.path)")
        } else {
            for failure in failures { print("FAIL: \(failure)") }
            throw FixtureError.failed
        }
    }

    enum FixtureError: Error { case invalidRoot, failed, requiresUnprivilegedUser, failureSetup }
}
