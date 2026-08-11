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
        /// resume can regenerate a FRESH link straight from the provider when the stored one has expired,
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
        if let data = UserDefaults.standard.data(forKey: key(profileID)) {
            if let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
                dict = decoded
            } else {
                quarantineUndecodableBlob(data, profileID: profileID)
            }
        }
        cache[profileID] = dict
        return dict
    }

    /// A blob that does not decode leaves the in-memory view empty, and the very next `record()` ENCODES
    /// that empty dictionary straight back over it: one unreadable byte silently discards every remembered
    /// resume stream (up to the per-profile cap) with nothing left to recover from. Copy the raw bytes aside
    /// ONCE, before any write can land, so a later migration or a support export still has them.
    ///
    /// Fail-open by construction: the session still runs on the empty view (a missing entry costs the slow
    /// re-resolve resume the player already falls back to, never playback), and a copy that cannot be
    /// written changes nothing. One-time per profile - a second failure must not overwrite the first,
    /// still-original copy with post-wipe bytes. The log line carries no library id, url, or profile id,
    /// only that it happened and how big it was.
    private static func quarantineUndecodableBlob(_ data: Data, profileID: UUID) {
        let quarantineKey = key(profileID) + ".undecodable"
        guard UserDefaults.standard.data(forKey: quarantineKey) == nil else { return }
        UserDefaults.standard.set(data, forKey: quarantineKey)
        DiagnosticsLog.log("app", "last stream store did not decode; \(data.count) raw bytes kept aside before rewrite")
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
            // Membership probe, not a fixed lexicographic head (which never contained the MISSED id, so it
            // could not show a key mismatch). `present` says whether the exact missed key is in the store at
            // all (a true here with a "noEntry" outcome means the caller's lookup key differs from this one).
            // When absent, `variant` says whether a case-only or same-base-id (the part before the first ':')
            // key IS present, which is the id-format / legacy-key mismatch this miss is usually caused by.
            let present = dict[libraryId] != nil
            var variant = "none"
            if !present {
                let lower = libraryId.lowercased()
                let base = libraryId.split(separator: ":").first.map(String.init) ?? libraryId
                if dict.keys.contains(where: { $0.lowercased() == lower }) {
                    variant = "case"
                } else if dict.keys.contains(where: { ($0.split(separator: ":").first.map(String.init) ?? $0) == base }) {
                    variant = "base"
                }
            }
            detail = " present=\(present) variant=\(variant) count=\(dict.count)"
        }
        let pid = profileID.map { String($0.uuidString.prefix(8)) } ?? "nil"
        DiagnosticsLog.log("cw-resume", "\(outcome) id=\(VXProbeRedaction.identityToken(libraryId)) profile=\(pid)\(detail)")
    }
}
