import Foundation

/// Saved magnets and pasted links, per profile, so a user can keep a magnet or a multi-file torrent
/// "playlist" and reopen it later (issue #81). This is the LOCAL layer by design: a magnet or ad-hoc
/// URL has no catalog meta id, and injecting a synthetic item into the stremio-core library corrupts
/// account-wide sync for the official clients (the documented poisoned-account incident, see
/// ProfileSync.swift). So saved links live only here. Because the store is in the app's UserDefaults
/// domain, SettingsBackup already sweeps it into Backup & Restore and the future cloud sync carries it
/// for free. Mirrors LastStreamStore.
@MainActor
enum SavedLinksStore {
    struct Entry: Codable, Identifiable, Hashable {
        var id: String          // the magnet / URL itself, used as the dedupe key
        var link: String        // "magnet:?xt=..." or "https://..."
        var name: String        // display name
        var poster: String?
        var isMagnet: Bool
        var savedAt: Date
        // #81: bind a saved magnet to the EXACT file the user actually played. When both are present,
        // re-opening rebuilds the play URL directly as {serverBase}/{infoHash}/{fileIdx}, so a season
        // pack reopens the same episode instead of re-showing the picker or replaying the biggest file.
        // Optional + decoded leniently so entries saved before this field still load (the magnet still
        // works, it just re-resolves the old way). Never carries catalog meta: the anti-poison invariant
        // (PlayedLinkLibrary) keeps magnets out of the account library; this binding is local only.
        var infoHash: String? = nil
        var fileIdx: Int? = nil
    }

    private static let cap = 100
    private static func key(_ profileID: UUID) -> String { "stremiox.savedLinks.\(profileID.uuidString)" }

    /// Decoded once per profile and kept in memory; the saved rail renders from this on every refresh.
    private static var cache: [UUID: [Entry]] = [:]

    private static func load(_ profileID: UUID) -> [Entry] {
        if let cached = cache[profileID] { return cached }
        var list: [Entry] = []
        if let data = UserDefaults.standard.data(forKey: key(profileID)) {
            if let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
                list = decoded
            } else {
                quarantineUndecodableBlob(data, profileID: profileID)
            }
        }
        cache[profileID] = list
        return list
    }

    /// A blob that does not decode leaves the in-memory view empty, and the very next `persist()` (any save,
    /// remove, or played-file bind) ENCODES that empty list straight back over it: one unreadable byte
    /// silently discards every saved magnet and pasted link (up to the per-profile cap) with nothing left to
    /// recover from. Copy the raw bytes aside ONCE, before any write can land, so a later migration or a
    /// support export still has them.
    ///
    /// Fail-open by construction: the session still runs on the empty view (a lost saved link costs a re-save,
    /// never playback), and a copy that cannot be written changes nothing. One-time per profile - a second
    /// failure must not overwrite the first, still-original copy with post-wipe bytes. The log line carries no
    /// link, name, or profile id, only that it happened and how big it was.
    private static func quarantineUndecodableBlob(_ data: Data, profileID: UUID) {
        let quarantineKey = key(profileID) + ".undecodable"
        guard UserDefaults.standard.data(forKey: quarantineKey) == nil else { return }
        UserDefaults.standard.set(data, forKey: quarantineKey)
        DiagnosticsLog.log("app", "saved links store did not decode; \(data.count) raw bytes kept aside before rewrite")
    }

    /// All saved entries for the profile, newest first.
    static func all(profileID: UUID?) -> [Entry] {
        guard let profileID else { return [] }
        return load(profileID).sorted { $0.savedAt > $1.savedAt }
    }

    static func isSaved(_ link: String, profileID: UUID?) -> Bool {
        guard let profileID else { return false }
        return load(profileID).contains { $0.id == link }
    }

    /// #81: pull `(infoHash, fileIdx)` out of a torrent play URL of the form
    /// `{serverBase}/{infoHash}/{fileIdx}` (what OpenLink builds for every magnet file). Returns nil for
    /// any other shape (direct/debrid/HLS links), so only real torrent files get the exact-file binding.
    /// A 40-hex or 32+-char info hash followed by an integer file index is required; anything else is nil.
    static func torrentParts(from playURL: URL) -> (infoHash: String, fileIdx: Int)? {
        let parts = playURL.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.count >= 2, let idx = Int(parts[parts.count - 1]) else { return nil }
        let hash = parts[parts.count - 2].lowercased()
        guard hash.count >= 32, hash.allSatisfy(\.isHexDigit) else { return nil }
        return (hash, idx)
    }

    /// #81: after a magnet file actually plays, remember the EXACT file on its ALREADY-saved entry so
    /// re-opening replays the same file (a season pack reopens the same episode, not the picker or the
    /// biggest file). Update-only: we never auto-add an entry the user did not choose to save, so the
    /// Saved list is not cluttered by every one-off play. Local only; never touches the account library.
    static func bindPlayedFile(magnetLink: String, playURL: URL, profileID: UUID?) {
        guard let profileID, let parts = torrentParts(from: playURL),
              let existing = load(profileID).first(where: { $0.id == magnetLink }) else { return }
        save(.init(id: existing.id, link: existing.link, name: existing.name,
                   poster: existing.poster, isMagnet: existing.isMagnet, savedAt: existing.savedAt,
                   infoHash: parts.infoHash, fileIdx: parts.fileIdx),
             profileID: profileID)
    }

    /// Save (or move-to-top) an entry. Keyed by the link, so saving the same one twice de-dupes.
    static func save(_ entry: Entry, profileID: UUID?) {
        guard let profileID else { return }
        var list = load(profileID).filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        if list.count > cap { list = Array(list.prefix(cap)) }
        persist(list, profileID)
    }

    static func remove(_ link: String, profileID: UUID?) {
        guard let profileID else { return }
        persist(load(profileID).filter { $0.id != link }, profileID)
    }

    /// Drop the in-memory cache so a profile switch re-reads the new profile's saved links.
    static func invalidate(_ profileID: UUID? = nil) {
        if let profileID { cache[profileID] = nil } else { cache.removeAll() }
    }

    private static func persist(_ list: [Entry], _ profileID: UUID) {
        cache[profileID] = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key(profileID))
        }
    }
}
