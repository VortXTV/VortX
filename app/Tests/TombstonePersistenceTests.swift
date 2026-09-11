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
        testCloudRestorePreservesPerEntryReceipts()
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

    private static func testCloudRestorePreservesPerEntryReceipts() {
        let defaults = UserDefaults.standard
        let prefixes = ["stremiox.addons.", "stremiox.library."]
        let keys = prefixes.flatMap { prefix in ["removedAt", "addedAt", "deleted"].map { prefix + $0 } }
        let before = keys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        defer {
            for key in keys {
                if let value = before[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for prefix in prefixes {
            defaults.set(["removed": 200.0, "reinstalled": 100.0], forKey: prefix + "removedAt")
            defaults.set(["removed": 100.0, "reinstalled": 300.0], forKey: prefix + "addedAt")
            defaults.set(["removed"], forKey: prefix + "deleted")
        }
        AddonTombstones.preservingLocalSyncStamps {
            for prefix in prefixes {
                defaults.set(["reinstalled": 100.0, "peer-only": 250.0], forKey: prefix + "removedAt")
                defaults.set(["removed": 100.0], forKey: prefix + "addedAt")
                defaults.set(["reinstalled", "peer-only"], forKey: prefix + "deleted")
            }
        }
        precondition(AddonTombstones.all() == ["removed", "peer-only"], "stale settings cannot resurrect removed add-ons or undo reinstalls")
        precondition(LibraryTombstones.all() == ["removed", "peer-only"], "stale settings cannot erase library receipts")
        let snapshot = AddonTombstones.timestampsForSync()
        AddonTombstones.preservingLocalSyncStamps {}
        precondition(AddonTombstones.timestampsForSync() == snapshot, "repeated restore is idempotent")
    }

    private static func isolatedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}
