import SwiftUI

/// User-supplied API keys for the optional metadata enrichers (TMDB recommendations, MDBList ratings
/// and lists). Kept in the Keychain, not UserDefaults, since they are credentials. Everything that uses
/// them degrades gracefully when a key is absent, so VortX works fully without them.
@MainActor
final class ApiKeys: ObservableObject {
    static let shared = ApiKeys()

    private let tmdbAccount = "vortx.apikey.tmdb"
    private let mdblistAccount = "vortx.apikey.mdblist"
    private let fanartAccount = "vortx.apikey.fanart"
    private let skipdbAccount = "vortx.apikey.skipdb"
    private let customSkipURLAccount = "vortx.skip.customurl"
    private let customSkipKeyAccount = "vortx.apikey.customskip"

    @Published var tmdb: String { didSet { Keychain.set(tmdb.isEmpty ? nil : tmdb, for: tmdbAccount); VortXSyncManager.shared.requestSyncSoon() } }
    @Published var mdblist: String { didSet { Keychain.set(mdblist.isEmpty ? nil : mdblist, for: mdblistAccount); VortXSyncManager.shared.requestSyncSoon() } }
    @Published var fanart: String { didSet { Keychain.set(fanart.isEmpty ? nil : fanart, for: fanartAccount); VortXSyncManager.shared.requestSyncSoon() } }
    @Published var skipdb: String { didSet { Keychain.set(skipdb.isEmpty ? nil : skipdb, for: skipdbAccount); VortXSyncManager.shared.requestSyncSoon() } }

    /// An ADDITIONAL user-configured SkipDB-compatible provider: the base URL of a self-hosted mirror
    /// (e.g. https://my-mirror.example), plus an optional API key for it. When set, a submit fans out to
    /// it alongside skip.vortx.tv and skipdb.tv, and reads query it too. Both stay in the Keychain.
    @Published var customSkipURL: String { didSet { Keychain.set(customSkipURL.isEmpty ? nil : customSkipURL, for: customSkipURLAccount); VortXSyncManager.shared.requestSyncSoon() } }
    @Published var customSkipKey: String { didSet { Keychain.set(customSkipKey.isEmpty ? nil : customSkipKey, for: customSkipKeyAccount); VortXSyncManager.shared.requestSyncSoon() } }

    private init() {
        tmdb = Keychain.string(tmdbAccount) ?? ""
        mdblist = Keychain.string(mdblistAccount) ?? ""
        fanart = Keychain.string(fanartAccount) ?? ""
        skipdb = Keychain.string(skipdbAccount) ?? ""
        customSkipURL = Keychain.string(customSkipURLAccount) ?? ""
        customSkipKey = Keychain.string(customSkipKeyAccount) ?? ""
    }

    var hasTMDB: Bool { !tmdb.isEmpty }
    var hasMDBList: Bool { !mdblist.isEmpty }
    var hasFanart: Bool { !fanart.isEmpty }
    var hasSkipDB: Bool { !skipdb.isEmpty }
    var hasCustomSkip: Bool { !customSkipURL.isEmpty }

    /// Read the keys off the main actor (for use inside async network code).
    nonisolated static func tmdbKey() -> String? {
        let k = Keychain.string("vortx.apikey.tmdb"); return (k?.isEmpty == false) ? k : nil
    }

    /// VortX's own TMDB read key, used ONLY as the last-resort fallback when the keyless edge
    /// (catalogs.vortx.tv, which holds this key server-side) is unreachable. A free public read key, so
    /// shipping it costs little; the edge is the primary keyless path and keeps it off the wire normally.
    nonisolated static let bundledTMDBKey = "d131017ccc6e5462a81c9304d21476de"

    /// The key TMDB calls build their `api_key=` with: the user's key when set, else VortX's bundled key
    /// so the catalogs/hub work with NO user key. `TMDBClient.get` decides the ROUTE from `tmdbKey()`
    /// (a real user key -> TMDB direct; no user key -> the keyless edge, which injects its own key).
    nonisolated static func effectiveTMDBKey() -> String { tmdbKey() ?? bundledTMDBKey }
    nonisolated static func mdblistKey() -> String? {
        let k = Keychain.string("vortx.apikey.mdblist"); return (k?.isEmpty == false) ? k : nil
    }
    nonisolated static func fanartKey() -> String? {
        let k = Keychain.string("vortx.apikey.fanart"); return (k?.isEmpty == false) ? k : nil
    }
    nonisolated static func skipDBKey() -> String? {
        let k = Keychain.string("vortx.apikey.skipdb"); return (k?.isEmpty == false) ? k : nil
    }
    /// Base URL of the user's optional custom SkipDB-compatible provider (nil when unset).
    nonisolated static func customSkipURL() -> String? {
        let k = Keychain.string("vortx.skip.customurl"); return (k?.isEmpty == false) ? k : nil
    }
    /// Optional API key for the custom provider (nil when unset; some mirrors are keyless).
    nonisolated static func customSkipKey() -> String? {
        let k = Keychain.string("vortx.apikey.customskip"); return (k?.isEmpty == false) ? k : nil
    }
}
