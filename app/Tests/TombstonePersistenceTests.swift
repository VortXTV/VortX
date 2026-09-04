// Standalone executable regression tests for deterministic, idempotent tombstone persistence.
//
// Run:
//   xcrun swiftc -parse-as-library -warnings-as-errors \
//     app/SourcesShared/LibraryTombstones.swift \
//     app/SourcesShared/AddonTombstones.swift \
//     app/Tests/TombstonePersistenceTests.swift \
//     -o /Users/daksh/VortXTV/.build/tombstone-persistence/TombstonePersistenceTests && \
//   /Users/daksh/VortXTV/.build/tombstone-persistence/TombstonePersistenceTests

import Foundation

// Production tombstone merge diagnostics are not under test here, but the real sources reference this sink.
enum DiagnosticsLog {
    static func log(_ category: String, _ message: String) {}
}

@main
enum TombstonePersistenceTests {
    static func main() {
        testCanonicalLegacyArrayIsStableAndSorted()
        testIdenticalSecondSaveDoesNotWrite()
        testChangedTimestampWrites()
        print("Tombstone persistence tests passed")
    }

    private static func testCanonicalLegacyArrayIsStableAndSorted() {
        let ids: Set<String> = ["tmdb:9", "tt0002", "tmdb:1"]
        let first = TombstonePersistence.canonicalLegacy(ids)
        let second = TombstonePersistence.canonicalLegacy(ids)
        precondition(first == ["tmdb:1", "tmdb:9", "tt0002"], "legacy representation must be sorted")
        precondition(first == second, "legacy representation must not inherit Set iteration order")
    }

    private static func testIdenticalSecondSaveDoesNotWrite() {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let mapKey = "removedAt"
        let arrayKey = "legacyDeleted"
        let map = ["tt0002": 2.0, "tmdb:1": 1.0]
        let array = TombstonePersistence.canonicalLegacy(Set(map.keys))

        precondition(TombstonePersistence.setMapIfChanged(map, forKey: mapKey, defaults: defaults))
        precondition(TombstonePersistence.setArrayIfChanged(array, forKey: arrayKey, defaults: defaults))
        // Defaults presents stored scalar timestamps as NSNumber. The second map save must still be a no-op.
        precondition(!TombstonePersistence.setMapIfChanged(map, forKey: mapKey, defaults: defaults))
        precondition(!TombstonePersistence.setArrayIfChanged(array, forKey: arrayKey, defaults: defaults))
    }

    private static func testChangedTimestampWrites() {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let key = "addedAt"

        precondition(TombstonePersistence.setMapIfChanged(["tt0002": 2.0], forKey: key, defaults: defaults))
        precondition(TombstonePersistence.setMapIfChanged(["tt0002": 3.0], forKey: key, defaults: defaults))
        precondition((defaults.dictionary(forKey: key)?["tt0002"] as? NSNumber)?.doubleValue == 3.0)
    }

    private static let defaultsSuiteName = "TombstonePersistenceTests"

    private static func isolatedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}
