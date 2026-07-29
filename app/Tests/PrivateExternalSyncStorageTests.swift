// Standalone verification for private external-sync persistence.
//
// Run with:
//   swiftc -strict-concurrency=complete -warnings-as-errors \
//     -o /tmp/private-external-sync-storage \
//     app/SourcesShared/PrivateExternalSyncStorage.swift \
//     app/Tests/PrivateExternalSyncStorageTests.swift && /tmp/private-external-sync-storage

import Foundation

@main
struct PrivateExternalSyncStorageTestRunner {
    static func main() throws {
        var checks = 0
        var failures: [String] = []

        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortx-private-storage-\(UUID().uuidString)", isDirectory: true)
        let live = root
            .appendingPathComponent("ExternalSync", isDirectory: true)
            .appendingPathComponent("Trakt", isDirectory: true)
            .appendingPathComponent("sync-state.json")
        let legacy = root.appendingPathComponent("trakt-pending-pushes.json")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data("legacy-private-account-state".utf8).write(to: legacy)

        let storage = PrivateExternalSyncStorage(fileURL: live, legacyURLs: [legacy])
        let payload = Data("session-bound-private-state".utf8)
        try storage.save(payload)

        expect(!FileManager.default.fileExists(atPath: legacy.path),
               "sessionless legacy private state is deleted instead of migrated")
        expect(try storage.load() == payload,
               "protected storage returns the exact session-bound payload")

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: live.deletingLastPathComponent().path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: live.path)
#if os(iOS) || os(tvOS)
        expect(directoryAttributes[.protectionKey] as? FileProtectionType == .complete,
               "private state directory uses complete file protection")
        expect(fileAttributes[.protectionKey] as? FileProtectionType == .complete,
               "private state file uses complete file protection")
#else
        let directoryMode = (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
        let fileMode = (fileAttributes[.posixPermissions] as? NSNumber)?.intValue
        expect(directoryMode == 0o700,
               "private state directory is owner-only on macOS")
        expect(fileMode == 0o600,
               "private state file is owner-only on macOS")
#endif

        let directoryValues = try live.deletingLastPathComponent()
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        let fileValues = try live.resourceValues(forKeys: [.isExcludedFromBackupKey])
        expect(directoryValues.isExcludedFromBackup == true,
               "private state directory is excluded from backup")
        expect(fileValues.isExcludedFromBackup == true,
               "private state file is excluded from backup")

        try storage.reset()
        expect(!FileManager.default.fileExists(atPath: live.path),
               "boundary reset removes private state from disk")

        if failures.isEmpty {
            print("PASS: \(checks) private external-sync storage checks")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
