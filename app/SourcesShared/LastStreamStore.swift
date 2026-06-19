import Foundation

/// The exact stream each title last played, per profile, so Continue Watching can
/// resume the same link directly instead of routing through the detail page and
/// re-resolving sources. Links can expire (debrid URLs are time-limited); the
/// player's existing load-failure overlay is the fallback when one has.
@MainActor
enum LastStreamStore {
    struct Entry: Codable {
        var videoId: String
        var url: String
        var title: String
        var season: Int?
        var episode: Int?
        var name: String
        var poster: String?
        var type: String
        var qualityText: String?
        /// The playing stream's release group (behaviorHints.bingeGroup), so a Continue Watching resume's
        /// prev/next keeps the SAME release across episodes (the binge continuity the detail page already
        /// applies in-session). Optional, so old entries decode.
        var bingeGroup: String? = nil
        var torrent: Bool? = nil
        var savedAt: Date
        /// HTTP headers the stream's add-on requires; without them a direct resume of a
        /// header-gated stream is rejected by its CDN. Optional, so old entries decode.
        var headers: [String: String]? = nil
    }

    private static func key(_ profileID: UUID) -> String { "stremiox.lastStream.\(profileID.uuidString)" }

    /// Decoded once per profile and kept in memory: entry() runs in the Continue
    /// Watching cards' render path, and decoding the JSON dict per card per render
    /// was measurable jank on device.
    private static var cache: [UUID: [String: Entry]] = [:]

    private static func load(_ profileID: UUID) -> [String: Entry] {
        if let cached = cache[profileID] { return cached }
        var dict: [String: Entry] = [:]
        if let data = UserDefaults.standard.data(forKey: key(profileID)),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            dict = decoded
        }
        cache[profileID] = dict
        return dict
    }

    static func entry(for libraryId: String, profileID: UUID?) -> Entry? {
        guard let profileID else { return nil }
        return load(profileID)[libraryId]
    }

    static func record(libraryId: String, entry: Entry, profileID: UUID?) {
        guard let profileID else { return }
        var dict = load(profileID)
        dict[libraryId] = entry
        if dict.count > 60 {   // cap per profile, oldest out
            dict = Dictionary(uniqueKeysWithValues:
                dict.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(50).map { ($0.key, $0.value) })
        }
        cache[profileID] = dict
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: key(profileID))
        }
    }

    /// Drop the in-memory cache so the next `entry()`/`load()` re-reads UserDefaults. A VortX-account
    /// sync writes the restored streams straight into UserDefaults behind this cache (SettingsBackup.restore),
    /// so without this a synced Continue-Watching link stays invisible until relaunch and the resume falls
    /// back to re-resolving (and could grab the wrong source). Called from VortXSyncManager.syncDown.
    static func invalidateCache() { cache.removeAll() }
}
