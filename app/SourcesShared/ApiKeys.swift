import SwiftUI

/// User-supplied API keys for the optional metadata enrichers (TMDB recommendations, MDBList ratings
/// and lists). Kept in the Keychain, not UserDefaults, since they are credentials. Everything that uses
/// them degrades gracefully when a key is absent, so VortX works fully without them.
@MainActor
final class ApiKeys: ObservableObject {
    static let shared = ApiKeys()

    private static let tmdbAccount = "vortx.apikey.tmdb"
    private static let mdblistAccount = "vortx.apikey.mdblist"
    private static let fanartAccount = "vortx.apikey.fanart"
    private static let skipdbAccount = "vortx.apikey.skipdb"
    private static let customSkipURLAccount = "vortx.skip.customurl"
    private static let customSkipKeyAccount = "vortx.apikey.customskip"
    private static let migrationGroup = "api-keys"
    private var isReloadingScope = false

    @Published var tmdb: String { didSet { persist(tmdb, for: Self.tmdbAccount) } }
    @Published var mdblist: String { didSet { persist(mdblist, for: Self.mdblistAccount) } }
    @Published var fanart: String { didSet { persist(fanart, for: Self.fanartAccount) } }
    @Published var skipdb: String { didSet { persist(skipdb, for: Self.skipdbAccount) } }

    /// An ADDITIONAL user-configured SkipDB-compatible provider: the base URL of a self-hosted mirror
    /// (e.g. https://my-mirror.example), plus an optional API key for it. When set, a submit fans out to
    /// it alongside skip.vortx.tv and skipdb.tv, and reads query it too. Both stay in the Keychain.
    @Published var customSkipURL: String { didSet { persist(customSkipURL, for: Self.customSkipURLAccount) } }
    @Published var customSkipKey: String { didSet { persist(customSkipKey, for: Self.customSkipKeyAccount) } }

    private init() {
        tmdb = Self.read(Self.tmdbAccount) ?? ""
        mdblist = Self.read(Self.mdblistAccount) ?? ""
        fanart = Self.read(Self.fanartAccount) ?? ""
        skipdb = Self.read(Self.skipdbAccount) ?? ""
        customSkipURL = Self.read(Self.customSkipURLAccount) ?? ""
        customSkipKey = Self.read(Self.customSkipKeyAccount) ?? ""
    }

    func reloadForCredentialScope() {
        isReloadingScope = true
        tmdb = Self.read(Self.tmdbAccount) ?? ""
        mdblist = Self.read(Self.mdblistAccount) ?? ""
        fanart = Self.read(Self.fanartAccount) ?? ""
        skipdb = Self.read(Self.skipdbAccount) ?? ""
        customSkipURL = Self.read(Self.customSkipURLAccount) ?? ""
        customSkipKey = Self.read(Self.customSkipKeyAccount) ?? ""
        isReloadingScope = false
    }

    private func persist(_ value: String, for account: String) {
        guard !isReloadingScope else { return }
        CredentialScopedKeychain.set(value.isEmpty ? nil : value, for: account)
        VortXSyncManager.shared.requestSyncSoon()
    }

    nonisolated private static func read(_ account: String) -> String? {
        CredentialScopedKeychain.string(account, migrationGroup: migrationGroup)
    }

    var hasTMDB: Bool { !tmdb.isEmpty }
    var hasMDBList: Bool { !mdblist.isEmpty }
    var hasFanart: Bool { !fanart.isEmpty }
    var hasSkipDB: Bool { !skipdb.isEmpty }
    var hasCustomSkip: Bool { !customSkipURL.isEmpty }

    /// Read the keys off the main actor (for use inside async network code).
    nonisolated static func tmdbKey() -> String? {
        let k = read(tmdbAccount); return (k?.isEmpty == false) ? k : nil
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
        let k = read(mdblistAccount); return (k?.isEmpty == false) ? k : nil
    }
    nonisolated static func fanartKey() -> String? {
        let k = read(fanartAccount); return (k?.isEmpty == false) ? k : nil
    }
    nonisolated static func skipDBKey() -> String? {
        let k = read(skipdbAccount); return (k?.isEmpty == false) ? k : nil
    }
    /// Base URL of the user's optional custom SkipDB-compatible provider (nil when unset).
    nonisolated static func customSkipURL() -> String? {
        let k = read(customSkipURLAccount); return (k?.isEmpty == false) ? k : nil
    }
    /// Optional API key for the custom provider (nil when unset; some mirrors are keyless).
    nonisolated static func customSkipKey() -> String? {
        let k = read(customSkipKeyAccount); return (k?.isEmpty == false) ? k : nil
    }
}
