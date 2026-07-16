import Foundation

/// Device-local memory of the viewer's MANUAL subtitle-timing offset, keyed by title.
///
/// When the viewer nudges subtitle timing during playback (the Earlier / Later control in the player's
/// subtitle-settings menu), the chosen offset in seconds is remembered for that exact title, keyed by its
/// `imdb:tt…` / `imdb:tt…:s:e` content key (the same key `SubtitleReleaseFingerprint.contentKey` mints).
/// Reopening the same title restores the offset, so a rip that is consistently out of sync only has to be
/// corrected once instead of every session. Default is 0 (absent): a title the viewer never corrected
/// behaves exactly as it did before this store existed.
///
/// This is deliberately DISTINCT from the community pooled offset (`SubtitlePoolClient.fetchPooled` /
/// `postOffset`):
///   - the pooled offset is crowd-shared, network- and feature-gated, coarse (bucketed server-side), and
///     scoped to a rip fingerprint, so it can be absent (feature off / signed out / no votes yet);
///   - this store is device-local, exact, always available offline, and is the viewer's OWN last choice.
/// The chrome restores this local memory first (instant, offline); the pooled seed only fills in a title the
/// viewer has never corrected. Neither overrides an offset the viewer has already dialed in this session.
///
/// FOUNDATION-ONLY + dependency-free on purpose: it takes an already-computed content-key STRING, so it does
/// not import `SubtitleReleaseFingerprint` or anything in `SourcesShared`, and therefore compiles in every
/// target that pulls `Sources/Player` (including the legacy web-host target, which does not pull the rest of
/// `SourcesShared`).
///
/// FAIL-SOFT CONTRACT (every method): any missing / corrupt / out-of-range state degrades to the no-memory
/// result (nil on read, no-op on write). Nothing throws to a caller.
enum SubtitleOffsetMemory {

    /// UserDefaults key holding the JSON-encoded `[contentKey: Entry]` map. `.v1` so a future schema change
    /// can bump the key rather than mis-decode an old blob.
    private static let storeKey = "vortx.subtitleOffsetMemory.v1"

    /// Cap on remembered titles. Past this, the least-recently-saved entries are evicted so the store can
    /// never grow unbounded across years of use. Each entry is a short key plus two doubles, so this is a
    /// few tens of KB at most, generous on purpose.
    private static let maxEntries = 600

    /// Sane bound (seconds) on a manual sync offset. A value outside +/- this is treated as corrupt and
    /// rejected on both read and write, so a mangled store can never shove subtitles minutes off.
    private static let maxAbsSeconds = 120.0

    /// Guards the read-modify-write of the backing map (UserDefaults itself is thread-safe, but load ->
    /// mutate -> persist is not atomic across threads). Mirrors `SubtitlePoolClient`'s `NSLock` usage.
    private static let lock = NSLock()

    private struct Entry: Codable {
        var seconds: Double
        var updated: Double   // epoch seconds, for least-recently-saved eviction
    }

    // MARK: - Public API

    /// The remembered offset in seconds for `contentKey`, or nil when none is stored. A stored 0 (or an
    /// out-of-range / non-finite value) is also treated as "no memory" so the caller never issues a needless
    /// `setSubDelay(0)`. The value is normalized to the 0.1 s grid the +/- control uses.
    static func savedOffset(forContentKey contentKey: String?) -> Double? {
        guard let contentKey, !contentKey.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let entry = load()[contentKey] else { return nil }
        let seconds = entry.seconds
        guard seconds != 0, seconds.isFinite, abs(seconds) <= maxAbsSeconds else { return nil }
        return (seconds * 10).rounded() / 10
    }

    /// Remember (or update) the viewer's manual offset for `contentKey`. A 0 (or out-of-range / non-finite)
    /// value CLEARS the stored offset, so "Reset sync" (which brings the offset back to 0) also forgets the
    /// title rather than pinning it at 0 forever. Fail-soft: an empty key or an encode failure is a silent
    /// no-op.
    static func save(_ seconds: Double, forContentKey contentKey: String?) {
        guard let contentKey, !contentKey.isEmpty else { return }
        let rounded = (seconds * 10).rounded() / 10
        lock.lock(); defer { lock.unlock() }
        var map = load()
        if rounded == 0 || !rounded.isFinite || abs(rounded) > maxAbsSeconds {
            guard map[contentKey] != nil else { return }   // nothing stored: nothing to clear
            map[contentKey] = nil
        } else {
            map[contentKey] = Entry(seconds: rounded, updated: Date().timeIntervalSince1970)
            evictIfNeeded(&map)
        }
        persist(map)
    }

    // MARK: - Backing store (fail-soft)

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return map
    }

    private static func persist(_ map: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    /// Drop the least-recently-saved entries once the map exceeds the cap.
    private static func evictIfNeeded(_ map: inout [String: Entry]) {
        guard map.count > maxEntries else { return }
        let overflow = map.count - maxEntries
        let oldest = map.sorted { $0.value.updated < $1.value.updated }.prefix(overflow)
        for (key, _) in oldest { map[key] = nil }
    }
}
