// Standalone adversarial tests for the session-bound Trakt playback cache.
//
// Run with:
//   swiftc -strict-concurrency=complete -warnings-as-errors -o /tmp/trakt-cache-security \
//     app/SourcesShared/TraktScrobbleProgressPolicy.swift \
//     app/SourcesShared/TraktContinueWatchingFold.swift \
//     app/SourcesShared/TraktPlaybackCacheStorage.swift \
//     app/Tests/TraktPlaybackCacheSecurityTests.swift && /tmp/trakt-cache-security

import Foundation

@MainActor private var failures: [String] = []
@MainActor private var checks = 0

@MainActor
private func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}

private func snapshot(sessionID: TraktSessionID, title: String) -> TraktPlaybackCacheSnapshot {
    TraktPlaybackCacheSnapshot(
        sessionID: sessionID,
        progress: ["tt1111111": 42],
        stamp: "2026-07-28T10:00:00.000Z",
        activity: TraktPlaybackActivityStamps(
            movies: "2026-07-28T10:00:00.000Z",
            episodes: nil
        ),
        items: [
            TraktContinueWatchingSeed(
                id: "tt1111111",
                type: "movie",
                name: title,
                progress: 42,
                pausedAt: "2026-07-28T10:00:00.000Z",
                runtimeMinutes: 100,
                videoID: nil,
                poster: nil
            )
        ],
        hasSnapshot: true
    )
}

@main
struct TraktPlaybackCacheSecurityTestRunner {
    @MainActor
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("trakt-cache-security-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let cacheURL = root
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("trakt-shadow-playback.json")
        let legacyURL = root
            .appendingPathComponent("legacy", isDirectory: true)
            .appendingPathComponent("trakt-shadow-playback.json")
        let storage = TraktPlaybackCacheStorage(cacheURL: cacheURL, legacyURL: legacyURL)
        let sessionA = TraktSessionID(rawValue: "session-a")
        let sessionB = TraktSessionID(rawValue: "session-b")

        try storage.save(snapshot(sessionID: sessionA, title: "Account A"))
        let loadedA = try storage.load(for: sessionA)
        expect(loadedA?.items.first?.name == "Account A",
               "matching session can relaunch its own playback snapshot")

        // Relaunch under B rejects and deletes A. A failed B refresh writes nothing, so local fallback
        // remains active instead of showing A.
        let loadedByB = try storage.load(for: sessionB)
        expect(loadedByB == nil,
               "relaunch cache and auth session mismatch returns local fallback")
        expect(!manager.fileExists(atPath: cacheURL.path),
               "mismatched A cache is deleted instead of migrated to B")
        expect(try storage.load(for: sessionB) == nil,
               "B login followed by failed refresh never resurrects A")

        // An old pull may not commit after an auth boundary, including one between last_activities and
        // either playback leg.
        expect(!TraktPlaybackSnapshotPolicy.canCommit(
            capturedSession: sessionA,
            stateSession: sessionB,
            currentSession: sessionB,
            capturedGeneration: 1,
            currentGeneration: 2
        ), "A pull cannot commit memory or disk after B becomes current")
        expect(!TraktPlaybackSnapshotPolicy.canRead(
            snapshotSession: sessionA,
            currentSession: sessionB
        ), "all synchronous reads reject a mismatched snapshot")
        expect(!TraktPlaybackSnapshotPolicy.canRead(
            snapshotSession: sessionA,
            currentSession: Optional<TraktSessionID>.none
        ), "all synchronous reads reject private playback state while signed out")

        // The old Application Support shape is deleted and never decoded or copied.
        try manager.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"progress":{"tt9999999":99}}"#.utf8).write(to: legacyURL)
        try storage.save(snapshot(sessionID: sessionB, title: "Account B"))
        expect(!manager.fileExists(atPath: legacyURL.path),
               "legacy sessionless Application Support cache is deleted")
        expect(try storage.load(for: sessionB)?.items.first?.name == "Account B",
               "only the protected session-bound cache is loaded")

        let directoryValues = try cacheURL.deletingLastPathComponent()
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        expect(directoryValues.isExcludedFromBackup == true,
               "private playback cache directory is excluded from backup")
        let fileValues = try cacheURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        expect(fileValues.isExcludedFromBackup == true,
               "private playback cache file is excluded from backup")
#if os(macOS)
        let directoryMode = try manager.attributesOfItem(
            atPath: cacheURL.deletingLastPathComponent().path
        )[.posixPermissions] as? NSNumber
        let fileMode = try manager.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? NSNumber
        expect(directoryMode?.intValue == 0o700,
               "macOS cache directory is owner-only")
        expect(fileMode?.intValue == 0o600,
               "macOS cache file is owner-only")
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cacheURL.path)
        _ = try storage.load(for: sessionB)
        let repairedMode = try manager.attributesOfItem(
            atPath: cacheURL.path
        )[.posixPermissions] as? NSNumber
        expect(repairedMode?.intValue == 0o600,
               "cache load reasserts owner-only file protection before decoding")
#endif

        // A structurally impossible destination makes a write failure observable to the caller.
        let invalid = TraktPlaybackCacheStorage(
            cacheURL: root.appendingPathComponent("plain-file/child/cache.json"),
            legacyURL: nil
        )
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("plain-file"))
        do {
            try invalid.save(snapshot(sessionID: sessionB, title: "Must Fail"))
            expect(false, "invalid cache destination must not report a successful write")
        } catch let error as TraktPlaybackCacheError {
            expect(error == .directory || error == .write,
                   "cache write failure returns a bounded observable category")
        }

        if failures.isEmpty {
            print("PASS: \(checks) Trakt playback cache security checks")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
