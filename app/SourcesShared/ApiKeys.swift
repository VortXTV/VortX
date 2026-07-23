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
    ///
    /// Stored MASKED (XOR of two byte arrays), not as a plaintext string literal, so the key is not a
    /// `strings`/grep hit in the shipped binary. It is reassembled at runtime by
    /// `assembleBundledTMDBKey()` and is byte-for-byte identical to the original key. This is
    /// obfuscation-at-rest, not secrecy (the value is a free public read key); the primary keyless path
    /// is still the edge. BundledTMDBKeyAssemblyTests.swift asserts SHA256(assembled) matches the
    /// committed hash, proving the arrays reassemble the exact key.
    nonisolated static let bundledTMDBKey = assembleBundledTMDBKey()

    private static let maskedTMDBCipher: [UInt8] = [
        0xcd, 0x22, 0xa2, 0x7d, 0x55, 0x8d, 0x67, 0xd2, 0x92, 0xc6, 0x30, 0xa2, 0x68, 0xa4, 0x0f, 0x78, 0xd0, 0x13, 0xab, 0x65, 0x21, 0x17, 0xd6, 0x39, 0x06, 0x12, 0xa8, 0xcc, 0x60, 0xfb, 0xe1, 0xe0
    ]
    private static let maskedTMDBPad: [UInt8] = [
        0xa9, 0x13, 0x91, 0x4c, 0x65, 0xbc, 0x50, 0xb1, 0xf1, 0xa5, 0x06, 0xc7, 0x5d, 0x90, 0x39, 0x4a, 0xb1, 0x2b, 0x9a, 0x06, 0x18, 0x24, 0xe6, 0x0d, 0x62, 0x20, 0x99, 0xf8, 0x57, 0xcd, 0x85, 0x85
    ]

    /// Reassemble the bundled TMDB key by XORing the two masked byte arrays. `@inline(never)` stops the
    /// optimizer from constant-folding the result back into a plaintext literal in the binary.
    @inline(never)
    nonisolated static func assembleBundledTMDBKey() -> String {
        let cipher = maskedTMDBCipher, pad = maskedTMDBPad
        var bytes = [UInt8]()
        bytes.reserveCapacity(cipher.count)
        for i in cipher.indices { bytes.append(cipher[i] ^ pad[i]) }
        return String(decoding: bytes, as: UTF8.self)
    }

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
