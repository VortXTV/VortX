import SwiftUI

/// Keychain accounts for optional metadata and SkipDB credentials.
///
/// The unqualified names are the beta global slots. They remain read-only migration sources; every live
/// read/write is owner-qualified with the canonical namespace already used by the other credential stores.
enum ApiKeySlots {
    static let legacyTMDB = "vortx.apikey.tmdb"
    static let legacyMDBList = "vortx.apikey.mdblist"
    static let legacyFanart = "vortx.apikey.fanart"
    static let legacySkipDB = "vortx.apikey.skipdb"
    static let legacyCustomSkipURL = "vortx.skip.customurl"
    static let legacyCustomSkipKey = "vortx.apikey.customskip"

    static func tmdb(_ owner: CredentialScope) -> String { scoped(legacyTMDB, owner) }
    static func mdblist(_ owner: CredentialScope) -> String { scoped(legacyMDBList, owner) }
    static func fanart(_ owner: CredentialScope) -> String { scoped(legacyFanart, owner) }
    static func skipDB(_ owner: CredentialScope) -> String { scoped(legacySkipDB, owner) }
    static func customSkipURL(_ owner: CredentialScope) -> String { scoped(legacyCustomSkipURL, owner) }
    static func customSkipKey(_ owner: CredentialScope) -> String { scoped(legacyCustomSkipKey, owner) }

    static func migrationMarker(for legacyAccount: String) -> String {
        legacyAccount + ".migration.owner"
    }

    private static func scoped(_ legacyAccount: String, _ owner: CredentialScope) -> String {
        legacyAccount + "." + owner.keychainOwnerID
    }
}

/// User-supplied API keys for the optional metadata enrichers (TMDB recommendations, MDBList ratings
/// and lists). Kept in the Keychain, not UserDefaults, since they are credentials. Everything that uses
/// them degrades gracefully when a key is absent, so VortX works fully without them.
@MainActor
final class ApiKeys: ObservableObject {
    static let shared = ApiKeys()

    /// The in-memory values always belong to this owner and exact authority capture. A bind clears and reloads
    /// all six values, so signing out or switching accounts cannot leave the prior account live in the singleton.
    private(set) var owner: CredentialScope = .signedOutDevice
    private var boundCapture: CredentialScopeRegistry.Capture?
    private var loadingScope = false

    @Published var tmdb: String = "" {
        didSet {
            persist(tmdb, previous: oldValue, account: ApiKeySlots.tmdb(owner), restore: { tmdb = oldValue })
        }
    }
    @Published var mdblist: String = "" {
        didSet {
            persist(mdblist, previous: oldValue, account: ApiKeySlots.mdblist(owner), restore: { mdblist = oldValue })
        }
    }
    @Published var fanart: String = "" {
        didSet {
            persist(fanart, previous: oldValue, account: ApiKeySlots.fanart(owner), restore: { fanart = oldValue })
        }
    }
    @Published var skipdb: String = "" {
        didSet {
            persist(skipdb, previous: oldValue, account: ApiKeySlots.skipDB(owner), restore: { skipdb = oldValue })
        }
    }

    /// An ADDITIONAL user-configured SkipDB-compatible provider: the base URL of a self-hosted mirror
    /// (e.g. https://my-mirror.example), plus an optional API key for it. When set, a submit fans out to
    /// it alongside skip.vortx.tv and skipdb.tv, and reads query it too. Both stay in the Keychain.
    @Published var customSkipURL: String = "" {
        didSet {
            persist(customSkipURL, previous: oldValue,
                    account: ApiKeySlots.customSkipURL(owner), restore: { customSkipURL = oldValue })
        }
    }
    @Published var customSkipKey: String = "" {
        didSet {
            persist(customSkipKey, previous: oldValue,
                    account: ApiKeySlots.customSkipKey(owner), restore: { customSkipKey = oldValue })
        }
    }

    private init() {
        let capture = CredentialScopeRegistry.shared.capture()
        owner = capture.scope
        boundCapture = capture
        loadScope()
    }

    /// Point the singleton at the exact owner currently authorized by the account session. A stale or
    /// mismatched bind fails closed by clearing memory and leaves Keychain untouched.
    func bind(owner newOwner: CredentialScope) {
        let capture = CredentialScopeRegistry.shared.capture()
        guard capture.scope == newOwner else {
            boundCapture = nil
            clearLoadedValues()
            return
        }
        let priorOwner = owner
        owner = newOwner
        boundCapture = capture
        if priorOwner != newOwner { clearLoadedValues() }
        loadScope()
    }

    /// Migrate the old global slots only after the registry has marked this exact account capture as
    /// authenticated. Each slot is destination-first, read-back verified, and independently retry-safe;
    /// a marker prevents a later unrelated account from claiming a source after a partial migration.
    @discardableResult
    func migrateLegacyIfEligible(
        owner expectedOwner: CredentialScope,
        capture: CredentialScopeRegistry.Capture
    ) -> Bool {
        guard owner == expectedOwner,
              boundCapture == capture,
              capture.scope == expectedOwner,
              CredentialScopeRegistry.shared.isMigrationEligible(capture) else { return false }

        let slots: [(source: String, destination: String)] = [
            (ApiKeySlots.legacyTMDB, ApiKeySlots.tmdb(expectedOwner)),
            (ApiKeySlots.legacyMDBList, ApiKeySlots.mdblist(expectedOwner)),
            (ApiKeySlots.legacyFanart, ApiKeySlots.fanart(expectedOwner)),
            (ApiKeySlots.legacySkipDB, ApiKeySlots.skipDB(expectedOwner)),
            (ApiKeySlots.legacyCustomSkipURL, ApiKeySlots.customSkipURL(expectedOwner)),
            (ApiKeySlots.legacyCustomSkipKey, ApiKeySlots.customSkipKey(expectedOwner))
        ]
        var safe = true
        for slot in slots {
            let result = CredentialLegacyClaim.claimGlobalSlot(
                sourceAccount: slot.source,
                destinationAccount: slot.destination,
                claimMarkerAccount: ApiKeySlots.migrationMarker(for: slot.source),
                ownerNamespace: expectedOwner.storageNamespace,
                write: { value, account in Keychain.set(value, for: account) },
                durableRead: { account in Keychain.confirmedString(account) },
                sourceRead: { account in Keychain.durableString(account) },
                provenanceTag: "api-key-\(slot.source)")
            switch result {
            case .noSource, .targetPresent, .migrated:
                break
            case .durableReadFailed, .claimWriteFailed, .claimConflict, .claimedByOtherOwner, .sourceLostAfterClaim,
                 .sourceDeleteFailed, .targetReadbackMismatch:
                safe = false
            }
        }
        loadScope()
        return safe
    }

    private func persist(
        _ value: String,
        previous: String,
        account: String,
        restore: () -> Void
    ) {
        guard !loadingScope else { return }
        guard value != previous else { return }
        guard let boundCapture,
              boundCapture.scope == owner,
              CredentialScopeRegistry.shared.isCurrent(boundCapture) else {
            clearLoadedValues()
            return
        }

        let storedValue = value.isEmpty ? nil : value
        var result = CredentialMutationResult.failure
        for _ in 0..<2 {
            result = Keychain.set(storedValue, for: account)
            if result == CredentialMutationResult.success { break }
        }
        guard result == .success else {
            loadingScope = true
            restore()
            loadingScope = false
            return
        }
        VortXSyncManager.shared.requestSyncSoon()
    }

    private func loadScope() {
        loadingScope = true
        tmdb = loadedValue(ApiKeySlots.tmdb(owner), preserving: tmdb)
        mdblist = loadedValue(ApiKeySlots.mdblist(owner), preserving: mdblist)
        fanart = loadedValue(ApiKeySlots.fanart(owner), preserving: fanart)
        skipdb = loadedValue(ApiKeySlots.skipDB(owner), preserving: skipdb)
        customSkipURL = loadedValue(ApiKeySlots.customSkipURL(owner), preserving: customSkipURL)
        customSkipKey = loadedValue(ApiKeySlots.customSkipKey(owner), preserving: customSkipKey)
        loadingScope = false
    }

    private func loadedValue(_ account: String, preserving prior: String) -> String {
        switch Self.confirmedValue(account) {
        case let .value(value): return value
        case .missing: return ""
        case .failure: return prior
        }
    }

    private func clearLoadedValues() {
        loadingScope = true
        tmdb = ""
        mdblist = ""
        fanart = ""
        skipdb = ""
        customSkipURL = ""
        customSkipKey = ""
        loadingScope = false
    }

    var hasTMDB: Bool { !tmdb.isEmpty }
    var hasMDBList: Bool { !mdblist.isEmpty }
    var hasFanart: Bool { !fanart.isEmpty }
    var hasSkipDB: Bool { !skipdb.isEmpty }
    var hasCustomSkip: Bool { !customSkipURL.isEmpty }

    /// Read the keys off the main actor (for use inside async network code).
    nonisolated static func tmdbKey() -> String? {
        scopedValue { ApiKeySlots.tmdb($0) }
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

    private nonisolated static let maskedTMDBCipher: [UInt8] = [
        0xcd, 0x22, 0xa2, 0x7d, 0x55, 0x8d, 0x67, 0xd2, 0x92, 0xc6, 0x30, 0xa2, 0x68, 0xa4, 0x0f, 0x78, 0xd0, 0x13, 0xab, 0x65, 0x21, 0x17, 0xd6, 0x39, 0x06, 0x12, 0xa8, 0xcc, 0x60, 0xfb, 0xe1, 0xe0
    ]
    private nonisolated static let maskedTMDBPad: [UInt8] = [
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
        scopedValue { ApiKeySlots.mdblist($0) }
    }
    nonisolated static func fanartKey() -> String? {
        scopedValue { ApiKeySlots.fanart($0) }
    }
    nonisolated static func skipDBKey() -> String? {
        scopedValue { ApiKeySlots.skipDB($0) }
    }
    /// Base URL of the user's optional custom SkipDB-compatible provider (nil when unset).
    nonisolated static func customSkipURL() -> String? {
        scopedValue { ApiKeySlots.customSkipURL($0) }
    }
    /// Optional API key for the custom provider (nil when unset; some mirrors are keyless).
    nonisolated static func customSkipKey() -> String? {
        scopedValue { ApiKeySlots.customSkipKey($0) }
    }

    private nonisolated static func scopedValue(_ account: (CredentialScope) -> String) -> String? {
        let authority = CredentialScopeRegistry.shared
        let capture = authority.capture()
        let result = confirmedValue(account(capture.scope))
        guard authority.isCurrent(capture) else { return nil }
        guard case let .value(value) = result, !value.isEmpty else { return nil }
        return value
    }

    private nonisolated static func confirmedValue(_ account: String) -> CredentialDurableReadResult {
        var result = Keychain.confirmedString(account)
        if result == .failure {
            // A single retry repairs transient backend reads without allowing an uncertain value to publish.
            result = Keychain.confirmedString(account)
        }
        return result
    }

}
