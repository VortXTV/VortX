import Foundation

/// Device-local memory of the viewer's manual subtitle-timing offset.
///
/// The value is scoped to a stable `SubtitleTimingScope`, so a correction for one release of a title cannot
/// silently affect another release. This store is deliberately separate from the community pooled offset:
/// local memory is exact and offline, while community timing is shared and fingerprinted independently.
///
/// The store is foundation-only and fail-soft. Missing, malformed, nonfinite, zero, or out-of-range state
/// degrades to no memory. A future schema uses a new key rather than decoding an older blob.
enum SubtitleOffsetMemory {
    private static let storeKey = "vortx.subtitleOffsetMemory.v2"
    private static let maxEntries = 600
    private static let maxAbsSeconds = 120.0
    private static let lock = NSLock()

    private struct Entry: Codable {
        var seconds: Double
        var updated: Double
    }

    /// The remembered offset for the complete scope, or nil when no valid nonzero value is stored.
    static func savedOffset(for scope: SubtitleTimingScope?) -> Double? {
        guard let scope else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let entry = load()[scope.storageKey],
              entry.seconds.isFinite,
              entry.seconds != 0,
              abs(entry.seconds) <= maxAbsSeconds else {
            return nil
        }
        let normalized = normalize(entry.seconds)
        guard normalized != 0, normalized.isFinite, abs(normalized) <= maxAbsSeconds else { return nil }
        return normalized
    }

    /// Remember a nonzero manual offset for the complete scope. Zero clears that exact scope.
    static func save(_ seconds: Double, for scope: SubtitleTimingScope?) {
        guard let scope, seconds.isFinite, abs(seconds) <= maxAbsSeconds else { return }
        let normalized = normalize(seconds)
        lock.lock(); defer { lock.unlock() }
        var map = load()
        if normalized == 0 || !normalized.isFinite || abs(normalized) > maxAbsSeconds {
            map.removeValue(forKey: scope.storageKey)
        } else {
            map[scope.storageKey] = Entry(
                seconds: normalized,
                updated: Date().timeIntervalSince1970
            )
            evictIfNeeded(&map)
        }
        persist(map)
    }

    private static func normalize(_ seconds: Double) -> Double {
        (seconds * 10).rounded() / 10
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func persist(_ map: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private static func evictIfNeeded(_ map: inout [String: Entry]) {
        guard map.count > maxEntries else { return }
        let overflow = map.count - maxEntries
        let oldest = map.sorted { $0.value.updated < $1.value.updated }.prefix(overflow)
        for (key, _) in oldest { map.removeValue(forKey: key) }
    }
}
