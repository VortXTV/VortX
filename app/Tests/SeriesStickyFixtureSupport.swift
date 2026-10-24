import Foundation

// Shared RAM-only collaborators for the whole-source sticky/health fixtures. Neither executable
// initializes the installed application's profile store, preferences, Keychain or history.
@MainActor final class ProfileStore {
    static let shared = ProfileStore()
    var activeID: UUID?
}

@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ value: Data, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

enum DiagnosticsLog { static func log(_ category: String, _ message: String) {} }
