import SwiftUI

/// User-supplied API keys for the optional metadata enrichers (TMDB recommendations, MDBList ratings
/// and lists). Kept in the Keychain, not UserDefaults, since they are credentials. Everything that uses
/// them degrades gracefully when a key is absent, so VortX works fully without them.
@MainActor
final class ApiKeys: ObservableObject {
    static let shared = ApiKeys()

    private let tmdbAccount = "vortx.apikey.tmdb"
    private let mdblistAccount = "vortx.apikey.mdblist"

    @Published var tmdb: String { didSet { Keychain.set(tmdb.isEmpty ? nil : tmdb, for: tmdbAccount) } }
    @Published var mdblist: String { didSet { Keychain.set(mdblist.isEmpty ? nil : mdblist, for: mdblistAccount) } }

    private init() {
        tmdb = Keychain.string(tmdbAccount) ?? ""
        mdblist = Keychain.string(mdblistAccount) ?? ""
    }

    var hasTMDB: Bool { !tmdb.isEmpty }
    var hasMDBList: Bool { !mdblist.isEmpty }

    /// Read the keys off the main actor (for use inside async network code).
    nonisolated static func tmdbKey() -> String? {
        let k = Keychain.string("vortx.apikey.tmdb"); return (k?.isEmpty == false) ? k : nil
    }
    nonisolated static func mdblistKey() -> String? {
        let k = Keychain.string("vortx.apikey.mdblist"); return (k?.isEmpty == false) ? k : nil
    }
}
