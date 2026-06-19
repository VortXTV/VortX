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
}
