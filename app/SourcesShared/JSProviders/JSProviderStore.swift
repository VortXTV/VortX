import Foundation
import CryptoKit

/// The install + enablement state for community JS providers, and the master gate.
///
/// GATED OFF BY DEFAULT, TWO WAYS (this feature ships dark in M1): the RemoteConfig fleet flag
/// `communityJSPlugins` (baked default FALSE, so an unreachable config keeps it off) AND a per-device
/// UserDefaults toggle (default FALSE). Both must be ON for any provider to run, mirroring how other new
/// features gate (see `RemoteConfig.isFeatureOn` + the TorBox-search pattern). With the gate off, `providers`
/// is treated as empty by every consumer and no provider code ever executes.
///
/// PASTE-YOUR-OWN model: the user supplies a manifest URL; VortX fetches the manifest and each pre-built
/// provider `.js`, caches the code on disk (so a relaunch is offline-capable and needs no re-download), and
/// persists the manifest URL. VortX bundles NO provider list.
@MainActor
final class JSProviderStore: ObservableObject {

    static let shared = JSProviderStore()

    // MARK: Persisted keys

    private enum Keys {
        static let userEnabled = "jsProviders.enabled"       // per-device master toggle (default OFF)
        static let manifestURL = "jsProviders.manifestURL"   // the pasted manifest URL
        static let repoName = "jsProviders.repoName"
    }

    /// The RemoteConfig feature key (tri-state; baked default lives in `RemoteConfigDefaults`).
    static let remoteFlagKey = "communityJSPlugins"

    // MARK: Published state

    /// The installed providers with their fetched code. Never surfaced to consumers while the gate is off
    /// (`enabledProviders` returns []); a monotonic epoch bump lets an auxiliary source fold changes into its
    /// rebuild signature cheaply.
    @Published private(set) var providers: [JSInstalledProvider] = [] { didSet { epoch &+= 1 } }
    private(set) var epoch = 0

    /// The per-device master toggle. Persisted; default OFF.
    @Published var userEnabled: Bool {
        didSet { defaults.set(userEnabled, forKey: Keys.userEnabled) }
    }

    @Published private(set) var manifestURLString: String
    @Published private(set) var repoName: String?
    @Published private(set) var isInstalling = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.userEnabled = defaults.bool(forKey: Keys.userEnabled)
        self.manifestURLString = defaults.string(forKey: Keys.manifestURL) ?? ""
        self.repoName = defaults.string(forKey: Keys.repoName)
        self.providers = Self.loadCachedProviders()
    }

    // MARK: Gate

    /// The master gate: the RemoteConfig fleet flag AND the per-device toggle. Both default OFF, so an
    /// untouched install (and an unreachable RemoteConfig) never runs a provider.
    var isFeatureEnabled: Bool {
        userEnabled && RemoteConfig.snapshot.isFeatureOn(
            Self.remoteFlagKey, default: RemoteConfigDefaults.featureCommunityJSPlugins
        )
    }

    /// The providers a consumer may actually run: empty whenever the gate is off, so no path can execute
    /// provider code without the feature being explicitly enabled.
    var enabledProviders: [JSInstalledProvider] {
        isFeatureEnabled ? providers : []
    }

    /// The providers that apply to a given media type, gate-respecting.
    func providers(forMediaType mediaType: String) -> [JSInstalledProvider] {
        enabledProviders.filter { $0.supports(mediaType: mediaType) }
    }

    // MARK: Install / remove

    struct InstallSummary { let repoName: String?; let installed: Int; let failed: Bool; let message: String }

    /// Fetch the manifest at `raw` and install every enabled provider, caching code to disk. Returns a summary
    /// for the settings UI. Does NOT flip the master toggle; the user enables the feature separately.
    func install(from raw: String) async -> InstallSummary {
        isInstalling = true
        defer { isInstalling = false }
        let result = await JSProviderManifestLoader.install(from: raw)
        switch result {
        case let .success((name, installed)):
            guard !installed.isEmpty else {
                return InstallSummary(repoName: name, installed: 0, failed: true,
                                      message: "No providers found in that manifest.")
            }
            guard Self.persist(installed) else {
                return InstallSummary(repoName: name, installed: 0, failed: true,
                                      message: "Could not save the installed providers.")
            }
            self.manifestURLString = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            self.repoName = name
            defaults.set(self.manifestURLString, forKey: Keys.manifestURL)
            defaults.set(name, forKey: Keys.repoName)
            self.providers = installed
            return InstallSummary(repoName: name, installed: installed.count, failed: false,
                                  message: "Installed \(installed.count) community provider\(installed.count == 1 ? "" : "s").")
        case let .failure(error):
            return InstallSummary(repoName: nil, installed: 0, failed: true, message: Self.describe(error))
        }
    }

    /// Re-fetch from the stored manifest URL (backend-first: providers auto-update with no app release). No-op
    /// when nothing is installed.
    func refreshFromStoredManifest() async -> InstallSummary? {
        guard !manifestURLString.isEmpty else { return nil }
        return await install(from: manifestURLString)
    }

    /// Remove all installed providers and forget the manifest URL. Leaves the master toggle where it is.
    func removeAll() {
        providers = []
        repoName = nil
        manifestURLString = ""
        defaults.removeObject(forKey: Keys.manifestURL)
        defaults.removeObject(forKey: Keys.repoName)
        Self.clearCache()
    }

    // MARK: Disk cache (Caches/jsproviders)

    private static func cacheDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("jsproviders", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct CachedIndexEntry: Codable {
        let id: String; let name: String; let version: String?
        let supportedTypes: [String]; let hasSettings: Bool; let file: String; let codeDigest: String
    }

    @discardableResult
    private static func persist(_ providers: [JSInstalledProvider]) -> Bool {
        guard let dir = cacheDirectory() else { return false }
        var index: [CachedIndexEntry] = []
        for p in providers {
            // A new immutable filename keeps a failed refresh from overwriting the provider code referenced by
            // the prior index. The index swap below is the single commit point for a complete install.
            let file = "\(p.id)-\(UUID().uuidString).js"
            let url = dir.appendingPathComponent(file)
            guard let data = p.code.data(using: .utf8),
                  (try? data.write(to: url, options: .atomic)) != nil else { return false }
            index.append(CachedIndexEntry(id: p.id, name: p.name, version: p.version,
                                          supportedTypes: p.supportedTypes, hasSettings: p.hasSettings, file: file, codeDigest: p.codeDigest))
        }
        guard let data = try? JSONEncoder().encode(index),
              (try? data.write(to: dir.appendingPathComponent("index.json"), options: .atomic)) != nil else { return false }
        let referenced = Set(index.map(\.file) + ["index.json"])
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for file in contents where !referenced.contains(file) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
        }
        return true
    }

    private static func loadCachedProviders() -> [JSInstalledProvider] {
        guard let dir = cacheDirectory(),
              let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
              let index = try? JSONDecoder().decode([CachedIndexEntry].self, from: data),
              index.count <= JSProviderManifest.maximumEntries else { return [] }
        return index.compactMap { entry in
            let fileURL = dir.appendingPathComponent(entry.file).standardizedFileURL
            guard entry.id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil,
                  entry.file.range(of: "^[A-Za-z0-9._-]+\\.js$", options: .regularExpression) != nil,
                  fileURL.deletingLastPathComponent() == dir.standardizedFileURL,
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let code = try? String(contentsOf: fileURL, encoding: .utf8), code.utf8.count <= 2 * 1024 * 1024,
                  !code.isEmpty,
                  SHA256.hash(data: Data(code.utf8)).map({ String(format: "%02x", $0) }).joined().caseInsensitiveCompare(entry.codeDigest) == .orderedSame else { return nil }
            return JSInstalledProvider(id: entry.id, name: entry.name, version: entry.version,
                                       supportedTypes: entry.supportedTypes, hasSettings: entry.hasSettings, code: code, codeDigest: entry.codeDigest)
        }
    }

    private static func clearCache() {
        guard let dir = cacheDirectory() else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Per-provider settings (onSettings blueprints), persisted as JSON

    /// The saved settings for one provider, surfaced to the provider as `globalThis.SCRAPER_SETTINGS`. Stored
    /// as an opaque JSON string per provider id. M1 persists/returns them; the settings UI to author them is M3.
    func settingsJSON(for providerID: String) -> String {
        defaults.string(forKey: "jsProviders.settings.\(providerID)") ?? "{}"
    }

    func setSettingsJSON(_ json: String, for providerID: String) {
        defaults.set(json, forKey: "jsProviders.settings.\(providerID)")
    }

    private static func describe(_ error: JSProviderManifestLoader.LoadError) -> String {
        switch error {
        case .invalidManifestURL: return "That does not look like a valid manifest URL."
        case let .manifestFetchFailed(code): return "Could not fetch the manifest (\(code == 0 ? "no response" : "HTTP \(code)"))."
        case .manifestDecodeFailed: return "The manifest could not be read."
        case .manifestTooLarge: return "That manifest is too large."
        case .invalidEntries: return "That manifest contains unsupported provider entries."
        case let .providerFetchFailed(id, status): return "Failed to fetch provider \(id) (HTTP \(status))."
        case let .providerTooLarge(id): return "Provider \(id) is too large."
        case let .providerDigestMismatch(id): return "Provider \(id) did not match its manifest digest."
        }
    }
}
