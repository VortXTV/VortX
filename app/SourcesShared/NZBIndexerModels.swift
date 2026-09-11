import Foundation

/// DIRECT NZB INDEXERS (Apple) — saved Newznab endpoint configurations.
///
/// NZBGeek (or any Newznab-compatible indexer) is queried DIRECTLY from the device and its results are
/// merged into the ordinary movie/episode source list (and auto-next), never into a separate download
/// flow. Playback reuses the existing `CoreStream` usenet resolution (nzbUrl → DebridResolver /
/// built-in usenet engine) unchanged.
///
/// SECURITY MODEL
///   * The whole configuration (version + id + name + endpoint + enabled) lives ONLY in the Keychain
///     (`Keychain.string` / `Keychain.set`, the platform secure backend). It is never written to
///     UserDefaults, so `SettingsBackup` (which captures only the UserDefaults domain) can never sync
///     or export it — same construction as the debrid keys.
///   * Configuration and API keys are committed together in one secure document, never in backups.
///   * Scope includes the VortX credential owner and a captured profile identity. A delayed editor or
///     search cannot switch its destination when the active profile changes.
///   * The stored document is versioned (`version` field); an unknown future version decodes to nil
///     rather than being misinterpreted.

// MARK: - Model

/// Public metadata for one saved Newznab indexer; API keys are held separately inside the secure blob.
struct NZBIndexerConfig: Identifiable, Equatable, Sendable, Codable {
    /// Opaque stable id (UUID string). Used as the stream-group identity (`nzbindexer:<id>`) so the
    /// source list NEVER keys a group by its credential-bearing endpoint URL.
    let id: String
    var name: String
    /// HTTPS Newznab endpoint base, e.g. `https://api.nzbgeek.info/api`. Validated by
    /// `NZBIndexerEndpointPolicy` before it can be saved.
    var endpoint: String
    var enabled: Bool

    init(id: String = UUID().uuidString, name: String, endpoint: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.enabled = enabled
    }

    /// Log/diagnostic-safe rendering: endpoint HOST only, never the full URL (query strings on a
    /// Newznab endpoint can carry credentials) and never the API key.
    var redactedDescription: String { "NZBIndexer(\(id)) name=\(name) host=\(NZBIndexerEndpointPolicy.hostOnly(endpoint) ?? "?") enabled=\(enabled)" }
}

// MARK: - Endpoint policy

/// Endpoint validation: HTTPS only, no userinfo, no fragment, real host. These are the only endpoints
/// whose responses we hand to the usenet resolver, so the transport must be TLS and unambiguous.
enum NZBIndexerEndpointPolicy {
    enum EndpointError: Equatable, Error {
        case notHTTPS
        case hasUserInfo
        case hasFragment
        case missingHost
        case malformed
    }

    static func validate(_ raw: String) -> Result<URL, EndpointError> {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.malformed)
        }
        return validate(url)
    }

    static func validate(_ url: URL) -> Result<URL, EndpointError> {
        guard url.scheme?.lowercased() == "https" else { return .failure(.notHTTPS) }
        guard url.user == nil, url.password == nil else { return .failure(.hasUserInfo) }
        guard url.fragment == nil else { return .failure(.hasFragment) }
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            return .failure(.missingHost)
        }
        return .success(url)
    }

    /// Host-only rendering for logs. nil when unparseable.
    static func hostOnly(_ raw: String) -> String? {
        URLComponents(string: raw)?.host
    }
}

// MARK: - Keychain document

/// The persisted, versioned, Keychain-only metadata document (NO API KEYS).
struct NZBIndexerStoreDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    var revision: Int          // bumps on every mutation; keys the search-result cache
    var indexers: [NZBIndexerConfig]

    init(version: Int = NZBIndexerStoreDocument.currentVersion, revision: Int = 1, indexers: [NZBIndexerConfig] = []) {
        self.version = version
        self.revision = revision
        self.indexers = indexers
    }

    var enabled: [NZBIndexerConfig] { indexers.filter(\.enabled) }
}

private struct NZBIndexerSecureDocument: Codable, Sendable {
    let document: NZBIndexerStoreDocument
    var keys: [String: String]
}

// MARK: - Store (Keychain-only, owner-scoped)

/// One atomic Keychain document per captured VortX owner and profile, outside backup/sync defaults.
@MainActor enum NZBIndexerStore {
    static let metadataAccountPrefix = "vortx.nzbindexer.v1."
    struct Scope: Sendable, Equatable {
        let capture: CredentialScopeRegistry.Capture
        let profileID: UUID
        var identity: String { capture.namespace + "." + String(capture.generation) + "." + profileID.uuidString }
    }
    static func captureScope() -> Scope {
        Scope(capture: CredentialScopeRegistry.shared.capture(),
              profileID: ProfileStore.shared.activeID ?? UserProfile.ownerID)
    }
    static func isCurrent(_ scope: Scope) -> Bool {
        CredentialScopeRegistry.shared.isCurrent(scope.capture)
            && scope.profileID == (ProfileStore.shared.activeID ?? UserProfile.ownerID)
    }
    static func metadataAccount(_ scope: Scope) -> String {
        metadataAccountPrefix + scope.capture.namespace + "." + scope.profileID.uuidString
    }

    private enum ReadError: Error { case unavailable, invalid, stale }
    private static func validText(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximum && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    private static func valid(_ secure: NZBIndexerSecureDocument) -> Bool {
        let doc = secure.document
        return doc.version == NZBIndexerStoreDocument.currentVersion && doc.revision > 0
            && doc.revision < Int.max && doc.indexers.count <= 8
            && Set(doc.indexers.map(\.id)).count == doc.indexers.count
            && doc.indexers.allSatisfy {
                validText($0.id, maximum: 128) && validText($0.name, maximum: 100)
                && $0.endpoint.utf8.count <= 4096
                && (try? NZBIndexerEndpointPolicy.validate($0.endpoint).get()) != nil
                && secure.keys[$0.id].map { validText($0, maximum: 4096) } == true
            }
    }
    private static func read(_ scope: Scope) throws -> NZBIndexerSecureDocument {
        guard isCurrent(scope) else { throw ReadError.stale }
        switch Keychain.confirmedString(metadataAccount(scope)) {
        case .missing: return NZBIndexerSecureDocument(document: .init(), keys: [:])
        case .failure: throw ReadError.unavailable
        case .value(let raw):
            guard raw.utf8.count <= 128 * 1024,
                  let secure = try? JSONDecoder().decode(NZBIndexerSecureDocument.self, from: Data(raw.utf8)),
                  valid(secure) else { throw ReadError.invalid }
            return secure
        }
    }

    // Display may show an empty list with readError, but mutations always read throwing and never
    // replace a corrupt/unknown-version/unavailable document with a manufactured empty document.
    static func load(scope: Scope? = nil) -> NZBIndexerStoreDocument {
        (try? read(scope ?? captureScope()).document) ?? .init()
    }
    static func readError(scope: Scope? = nil) -> String? {
        do { _ = try read(scope ?? captureScope()); return nil }
        catch ReadError.stale { return "The active account or profile changed. Reopen this page." }
        catch ReadError.invalid { return "Saved indexer settings could not be read. They have not been replaced." }
        catch { return "Secure storage is unavailable. Your saved indexers have not been changed." }
    }
    static func apiKey(for indexerID: String, scope: Scope? = nil) -> String? {
        try? read(scope ?? captureScope()).keys[indexerID]
    }
    @discardableResult
    static func save(_ config: NZBIndexerConfig, apiKey: String?, scope: Scope? = nil) -> NZBIndexerStoreDocument? {
        let scope = scope ?? captureScope()
        guard var secure = try? read(scope),
              let endpoint = try? NZBIndexerEndpointPolicy.validate(config.endpoint).get(),
              validText(config.id, maximum: 128), validText(config.name, maximum: 100) else { return nil }
        var next = config
        next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
        next.endpoint = endpoint.absoluteString
        var doc = secure.document
        if let i = doc.indexers.firstIndex(where: { $0.id == next.id }) { doc.indexers[i] = next }
        else { guard doc.indexers.count < 8 else { return nil }; doc.indexers.append(next) }
        // Blank on edit retains the key; a new indexer cannot be saved without one.
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            secure.keys[next.id] = key
        }
        guard doc.revision < Int.max - 1 else { return nil }
        doc.revision += 1
        return persist(doc, keys: secure.keys, scope: scope) ? doc : nil
    }
    @discardableResult
    static func remove(indexerID: String, scope: Scope? = nil) -> NZBIndexerStoreDocument? {
        let scope = scope ?? captureScope()
        guard var secure = try? read(scope) else { return nil }
        var doc = secure.document
        guard doc.indexers.contains(where: { $0.id == indexerID }) else { return doc }
        doc.indexers.removeAll { $0.id == indexerID }; secure.keys.removeValue(forKey: indexerID)
        guard doc.revision < Int.max - 1 else { return nil }
        doc.revision += 1
        return persist(doc, keys: secure.keys, scope: scope) ? doc : nil
    }
    private static func persist(_ doc: NZBIndexerStoreDocument, keys: [String: String], scope: Scope) -> Bool {
        let secure = NZBIndexerSecureDocument(document: doc, keys: keys)
        guard valid(secure), isCurrent(scope), let data = try? JSONEncoder().encode(secure) else { return false }
        return Keychain.set(String(decoding: data, as: UTF8.self), for: metadataAccount(scope)) == .success
    }
}
