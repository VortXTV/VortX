import Foundation

/// Per-profile recent search terms (last 5), stored in UserDefaults under a `stremiox.` key so they
/// ride SettingsBackup / VortX-account sync to the user's other devices. Shared by the tvOS SearchView
/// and the iOS/Mac search screen (#90, ported to touch + Mac).
enum SearchHistoryStore {
    private static let limit = 5

    private static func storageKey(_ profileID: UUID?) -> String {
        "stremiox.searchHistory.\(profileID?.uuidString ?? "default")"
    }

    static func load(profileID: UUID?) -> [String] {
        UserDefaults.standard.stringArray(forKey: storageKey(profileID)) ?? []
    }

    static func add(_ query: String, profileID: UUID?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = load(profileID: profileID).filter { $0.lowercased() != trimmed.lowercased() }
        history.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(history.prefix(limit)), forKey: storageKey(profileID))
    }

    static func clear(profileID: UUID?) {
        UserDefaults.standard.removeObject(forKey: storageKey(profileID))
    }

    /// All recent terms for a given profile (mirrors `load`, used by VortX-account sync to read every
    /// profile's list when building the sync doc).
    static func allTerms(for profileID: UUID?) -> [String] {
        load(profileID: profileID)
    }

    /// Apply pulled terms from another device into a profile's list, newest-wins and de-duplicated
    /// (case-insensitive), keeping the same cap. The pulled list leads, then this device's local terms
    /// fill in behind it, so nothing already here is lost. No-op on an empty pull.
    static func merge(_ terms: [String], for profileID: UUID?) {
        let incoming = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !incoming.isEmpty else { return }
        var seen = Set<String>()
        var merged: [String] = []
        for term in incoming + load(profileID: profileID) {
            let key = term.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(term)
        }
        UserDefaults.standard.set(Array(merged.prefix(limit)), forKey: storageKey(profileID))
    }
}
