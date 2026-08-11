// Standalone executable tests for the stable local subtitle-timing scope and v2 memory.
//
// Run with the foundation-only production slice:
//
//   swiftc -strict-concurrency=complete -warnings-as-errors \
//     app/Sources/Player/SubtitleTimingScope.swift \
//     app/Sources/Player/SubtitleOffsetMemory.swift \
//     app/Tests/SubtitleTimingScopeTests.swift \
//     -o /tmp/subtitle-timing-scope-test && /tmp/subtitle-timing-scope-test
//
// The tests deliberately use only UserDefaults and the two dependency-free production types. The
// surface lifecycle is covered by SubtitleTimingSurfaceContractTests.swift.

import Foundation

private let v1StoreKey = "vortx.subtitleOffsetMemory.v1"
private let v2StoreKey = "vortx.subtitleOffsetMemory.v2"

@MainActor private var failures = 0

@MainActor private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func clearStores() {
    UserDefaults.standard.removeObject(forKey: v1StoreKey)
    UserDefaults.standard.removeObject(forKey: v2StoreKey)
}

private func scope(_ contentKey: String, _ releaseFingerprint: String) -> SubtitleTimingScope {
    guard let value = SubtitleTimingScope(contentKey: contentKey, releaseFingerprint: releaseFingerprint) else {
        fatalError("test fixture produced an invalid subtitle scope")
    }
    return value
}

private func storedV2EntryCount() -> Int? {
    guard let data = UserDefaults.standard.data(forKey: v2StoreKey),
          let object = try? JSONSerialization.jsonObject(with: data),
          let map = object as? [String: Any] else {
        return nil
    }
    return map.count
}

@MainActor @main
enum SubtitleTimingScopeTests {
    static func main() {
        defer { clearStores() }
        clearStores()

        let validRelease = "release-a"
        let invalidContents: [String?] = [nil, "", " ", "unknown", " UNKNOWN "]
        for (index, value) in invalidContents.enumerated() {
            check(
                SubtitleTimingScope(contentKey: value, releaseFingerprint: validRelease) == nil,
                "invalid content scope rejected \(index)"
            )
        }
        let invalidReleases: [String?] = [nil, "", " ", "unknown", " UnKnOwN "]
        for (index, value) in invalidReleases.enumerated() {
            check(
                SubtitleTimingScope(contentKey: "imdb:tt0000001", releaseFingerprint: value) == nil,
                "invalid release scope rejected \(index)"
            )
        }

        let trimmed = SubtitleTimingScope(
            contentKey: " imdb:tt0000001:1:1 ",
            releaseFingerprint: " release-a "
        )
        check(trimmed?.contentKey == "imdb:tt0000001:1:1", "scope trims content identity")
        check(trimmed?.releaseFingerprint == "release-a", "scope trims release identity")
        check(trimmed?.storageKey == "imdb:tt0000001:1:1|release-a", "scope exposes deterministic composite key")
        check(
            trimmed?.storageKey == SubtitleTimingScope(
                contentKey: "imdb:tt0000001:1:1",
                releaseFingerprint: "release-a"
            )?.storageKey,
            "equivalent scopes have the same storage key"
        )

        let scopeA = scope("imdb:tt0000001:1:1", "release-a")
        let scopeB = scope("imdb:tt0000001:1:1", "release-b")

        SubtitleOffsetMemory.save(2.35, for: scopeA)
        SubtitleOffsetMemory.save(-1.26, for: scopeB)
        check(SubtitleOffsetMemory.savedOffset(for: scopeA) == 2.4, "release A restores its normalized offset")
        check(SubtitleOffsetMemory.savedOffset(for: scopeB) == -1.3, "release B restores its normalized offset")
        check(scopeA != scopeB, "same content with different releases stays distinct")

        SubtitleOffsetMemory.save(0, for: scopeA)
        check(SubtitleOffsetMemory.savedOffset(for: scopeA) == nil, "zero clears the local v2 entry")
        check(SubtitleOffsetMemory.savedOffset(for: scopeB) == -1.3, "clearing A does not clear B")

        clearStores()
        for invalid in [Double.nan, Double.infinity, -Double.infinity, 120.1, -120.1] {
            SubtitleOffsetMemory.save(invalid, for: scopeA)
            check(SubtitleOffsetMemory.savedOffset(for: scopeA) == nil, "invalid offset is rejected: \(invalid)")
        }

        clearStores()
        let legacy = [
            "imdb:tt0000001": ["seconds": 9.0, "updated": 1.0]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: legacy) {
            UserDefaults.standard.set(data, forKey: v1StoreKey)
        }
        check(SubtitleOffsetMemory.savedOffset(for: scopeA) == nil, "v1-only data is ignored")

        clearStores()
        for index in 0..<650 {
            let entryScope = scope("imdb:tt\(String(format: "%07d", index))", "release-\(index)")
            SubtitleOffsetMemory.save(Double((index % 60) + 1), for: entryScope)
        }
        check(storedV2EntryCount() == 600, "v2 memory is capped at 600 entries")

        clearStores()
        let capturedScope = scope("imdb:tt0000002:1:1", "release-a")
        let currentScope = scope("imdb:tt0000002:1:1", "release-b")
        let pending = (delay: 3.7, scope: capturedScope)
        var current = capturedScope
        current = currentScope
        SubtitleOffsetMemory.save(pending.delay, for: pending.scope)
        check(current == currentScope, "current scope moved to B before the pending save landed")
        check(SubtitleOffsetMemory.savedOffset(for: capturedScope) == 3.7, "pending save remains captured against A")
        check(SubtitleOffsetMemory.savedOffset(for: currentScope) == nil, "pending save does not write the current B scope")

        if failures == 0 {
            print("ALL PASS")
            exit(0)
        }
        print("\(failures) FAILED")
        exit(1)
    }
}
