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
        /// Debrid provenance of a NATIVELY-resolved link (via the user's own key), so a Continue-Watching
        /// resume can regenerate a FRESH link straight from the provider when the stored one has expired —
        /// skipping the slow full add-on re-resolve. All optional so old entries decode and a non-debrid
        /// (torrent / plain-direct) resume path is unchanged. Same privacy class as `url`: a device-local,
        /// per-profile playback hint. NEVER written into `libraryItem` or any account-parsed doc.
        var debridService: String? = nil
        var infoHash: String? = nil
        var debridFileId: Int? = nil
        var debridTorrentId: Int? = nil
        var fileIdx: Int? = nil
        /// When the stored `url` was minted, so a resume can decide it's likely fresh vs. worth reresolving.
        var linkSavedAt: Date? = nil
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

    private static var loggedResume: Set<String> = []
    /// Trace one Continue-Watching direct-resume decision per (title, outcome) per launch into the
    /// on-device diagnostics file. CW falling back to the slow re-resolve path (the user-visible
    /// "source failed, retry" sequence) is any non-"hit" outcome here; the line names which link in the
    /// record -> persist -> relaunch -> read chain broke. A "noEntry" miss also dumps the store
    /// inventory (count + first keys) so an item.id / profileID key mismatch is visible at a glance.
    /// Deduped because tvOS computes directResume in the card render path (per card, per render),
    /// which would otherwise flood the 512KB log and rotate the useful lines away.
    static func logResume(_ outcome: String, libraryId: String, profileID: UUID?) {
        guard loggedResume.insert("\(outcome):\(libraryId)").inserted else { return }
        var detail = ""
        if outcome == "noEntry", let profileID {
            let dict = load(profileID)
            let keys = dict.keys.sorted().prefix(8).joined(separator: ",")
            detail = " count=\(dict.count) keys=[\(keys)]"
        }
        let pid = profileID.map { String($0.uuidString.prefix(8)) } ?? "nil"
        DiagnosticsLog.log("cw-resume", "\(outcome) id=\(libraryId) profile=\(pid)\(detail)")
    }
}
