import SwiftUI

/// User-supplied API keys for the optional metadata enrichers (TMDB recommendations, MDBList ratings
/// and lists). Kept in the Keychain, not UserDefaults, since they are credentials. Everything that uses
/// them degrades gracefully when a key is absent, so VortX works fully without them.
@MainActor
final class ApiKeys: ObservableObject {
    static let shared = ApiKeys()

    private let tmdbAccount = "vortx.apikey.tmdb"
    private let mdblistAccount = "vortx.apikey.mdblist"
    private let skipdbAccount = "vortx.apikey.skipdb"

    @Published var tmdb: String { didSet { Keychain.set(tmdb.isEmpty ? nil : tmdb, for: tmdbAccount); VortXSyncManager.shared.requestSyncSoon() } }
    @Published var mdblist: String { didSet { Keychain.set(mdblist.isEmpty ? nil : mdblist, for: mdblistAccount); VortXSyncManager.shared.requestSyncSoon() } }
    @Published var skipdb: String { didSet { Keychain.set(skipdb.isEmpty ? nil : skipdb, for: skipdbAccount); VortXSyncManager.shared.requestSyncSoon() } }

    private init() {
        tmdb = Keychain.string(tmdbAccount) ?? ""
        mdblist = Keychain.string(mdblistAccount) ?? ""
        skipdb = Keychain.string(skipdbAccount) ?? ""
    }

    var hasTMDB: Bool { !tmdb.isEmpty }
    var hasMDBList: Bool { !mdblist.isEmpty }
    var hasSkipDB: Bool { !skipdb.isEmpty }

    /// Read the keys off the main actor (for use inside async network code).
    nonisolated static func tmdbKey() -> String? {
        let k = Keychain.string("vortx.apikey.tmdb"); return (k?.isEmpty == false) ? k : nil
    }
    nonisolated static func mdblistKey() -> String? {
        let k = Keychain.string("vortx.apikey.mdblist"); return (k?.isEmpty == false) ? k : nil
    }
    nonisolated static func skipDBKey() -> String? {
        let k = Keychain.string("vortx.apikey.skipdb"); return (k?.isEmpty == false) ? k : nil
    }
}
