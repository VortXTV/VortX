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
    }

    private static let cap = 100
    private static func key(_ profileID: UUID) -> String { "stremiox.savedLinks.\(profileID.uuidString)" }

    /// Decoded once per profile and kept in memory; the saved rail renders from this on every refresh.
    private static var cache: [UUID: [Entry]] = [:]

    private static func load(_ profileID: UUID) -> [Entry] {
        if let cached = cache[profileID] { return cached }
        var list: [Entry] = []
        if let data = UserDefaults.standard.data(forKey: key(profileID)),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            list = decoded
        }
        cache[profileID] = list
        return list
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
