import Foundation

/// The community provider registry format: a remote `manifest.json` listing one or more bundled provider
/// `.js` files. VortX ships NO curated or bundled provider list; the user pastes their OWN manifest URL and
/// VortX fetches the manifest and each pre-built provider file from it.
///
/// Every field is decoded defensively (all optional, unknown keys ignored) so a manifest with extra or missing
/// cosmetic fields still loads.
struct JSProviderManifest: Decodable, Equatable {
    let name: String?
    let version: String?
    let scrapers: [Entry]

    /// A deliberately small registry limit. The runtime executes sequentially, but accepting an arbitrary
    /// registry still turns a paste action into unbounded disk and network work.
    static let maximumEntries = 24

    struct Entry: Decodable, Equatable, Identifiable {
        let id: String
        let name: String?
        let version: String?
        let supportedTypes: [String]?
        let filename: String
        let enabled: Bool?
        let hasSettings: Bool?
        let contentLanguage: [String]?
        let logo: String?

        var displayName: String { name ?? id }
        var isEnabled: Bool { enabled ?? true }
        var supportsSettings: Bool { hasSettings ?? false }
        /// The community contract's `supportedTypes` are `"movie"` / `"tv"`; default to both when absent.
        func supports(mediaType: String) -> Bool {
            let types = (supportedTypes ?? ["movie", "tv"]).map { $0.lowercased() }
            return types.contains(mediaType.lowercased())
        }

        /// Validate every execution-relevant field before it can become a filename, cache component, or
        /// runtime identifier. Cosmetic fields intentionally remain permissive.
        var isSafeForInstallation: Bool {
            let decodedFilename = filename.removingPercentEncoding ?? filename
            let idIsSafe = id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
            let filenameIsSafe = !filename.isEmpty
                && filename.count <= 256
                && filename.hasSuffix(".js")
                && !filename.hasPrefix("/")
                && !filename.contains("\\\\")
                && !decodedFilename.split(separator: "/").contains(where: { $0 == ".." || $0.isEmpty })
                && URL(string: filename)?.scheme == nil
            let types = supportedTypes ?? ["movie", "tv"]
            let typesAreSafe = !types.isEmpty && types.allSatisfy {
                ["movie", "tv"].contains($0.lowercased())
            }
            return idIsSafe && filenameIsSafe && typesAreSafe
        }
    }
}

/// One installed provider: the manifest entry plus its fetched, pre-built JS code. Cached to disk so a repeat
/// launch does not re-download and providers keep working offline.
struct JSInstalledProvider: Equatable, Identifiable {
    let id: String
    let name: String
    let version: String?
    let supportedTypes: [String]
    let hasSettings: Bool
    let code: String

    func supports(mediaType: String) -> Bool {
        supportedTypes.map { $0.lowercased() }.contains(mediaType.lowercased())
    }
}

/// Fetches a manifest and its provider `.js` files over `URLSession`. Manifest/code hosting is the ONE narrow
/// backend-first role: the provider LOGIC updates propagate remotely (a fixed provider is a new bundle), while
/// EXECUTION stays on-device. The requests here go out on the user's IP like everything else.
enum JSProviderManifestLoader {

    enum LoadError: Error, Equatable {
        case invalidManifestURL
        case manifestFetchFailed(Int)
        case manifestDecodeFailed
        case manifestTooLarge
        case invalidEntries
        case providerFetchFailed(id: String, status: Int)
        case providerTooLarge(id: String)
    }

    private static let maximumManifestBytes = 256 * 1024
    private static let maximumProviderBytes = 2 * 1024 * 1024

    private static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg, delegate: ManifestNoRedirectDelegate(), delegateQueue: nil)
    }

    private enum DownloadResult {
        case success(data: Data, status: Int)
        case failed(status: Int)
        case tooLarge
    }

    /// Stream into a bounded buffer instead of letting `URLSession.data(for:)` allocate an arbitrary response.
    /// Redirects are refused by the session delegate, so DNS validation cannot be bypassed after the first URL.
    private static func download(_ request: URLRequest, maximumBytes: Int) async -> DownloadResult {
        do {
            let (bytes, response) = try await session().bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed(status: 0) }
            guard (200...299).contains(http.statusCode) else { return .failed(status: http.statusCode) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBytes else { return .tooLarge }
                data.append(byte)
            }
            return .success(data: data, status: http.statusCode)
        } catch {
            return .failed(status: 0)
        }
    }

    /// Normalize a pasted repo/manifest URL to a manifest.json URL: a bare directory or repo URL gets
    /// `manifest.json` appended; an explicit `...manifest.json` is used as-is.
    static func manifestURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              JSProviderURLPolicy.default.isAllowed(url) else { return nil }
        if url.lastPathComponent.lowercased() == "manifest.json" { return url }
        return url.appendingPathComponent("manifest.json")
    }

    /// Resolve a provider entry's `filename` (relative, e.g. `providers/4khdhub.js`) against the manifest URL's
    /// directory. Provider paths are deliberately relative, preventing a manifest from delegating execution to
    /// a different origin.
    static func providerURL(for entry: JSProviderManifest.Entry, manifestURL: URL) -> URL? {
        guard entry.isSafeForInstallation else { return nil }
        let base = manifestURL.deletingLastPathComponent()
        guard let url = URL(string: entry.filename, relativeTo: base)?.absoluteURL,
              url.scheme?.caseInsensitiveCompare(manifestURL.scheme ?? "") == .orderedSame,
              url.host?.caseInsensitiveCompare(manifestURL.host ?? "") == .orderedSame,
              url.port == manifestURL.port,
              JSProviderURLPolicy.default.isAllowed(url) else { return nil }
        return url
    }

    /// Fetch and decode the manifest.
    static func fetchManifest(from raw: String) async -> Result<(url: URL, manifest: JSProviderManifest), LoadError> {
        guard let url = manifestURL(from: raw), await JSProviderURLPolicy.default.isAllowedResolved(url) else {
            return .failure(.invalidManifestURL)
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(JSProviderURLPolicy.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        let result = await download(request, maximumBytes: maximumManifestBytes)
        let data: Data
        switch result {
        case let .success(value, _): data = value
        case let .failed(status): return .failure(.manifestFetchFailed(status))
        case .tooLarge: return .failure(.manifestTooLarge)
        }
        guard let manifest = try? JSONDecoder().decode(JSProviderManifest.self, from: data) else {
            return .failure(.manifestDecodeFailed)
        }
        guard !manifest.scrapers.isEmpty, manifest.scrapers.count <= JSProviderManifest.maximumEntries,
              Set(manifest.scrapers.map(\.id)).count == manifest.scrapers.count,
              manifest.scrapers.allSatisfy(\.isSafeForInstallation) else {
            return .failure(.invalidEntries)
        }
        return .success((url, manifest))
    }

    /// Fetch one provider's pre-built JS text.
    static func fetchProviderCode(for entry: JSProviderManifest.Entry, manifestURL: URL) async -> Result<String, LoadError> {
        guard let url = providerURL(for: entry, manifestURL: manifestURL),
              await JSProviderURLPolicy.default.isAllowedResolved(url) else {
            return .failure(.providerFetchFailed(id: entry.id, status: 0))
        }
        var request = URLRequest(url: url)
        request.setValue(JSProviderURLPolicy.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        let result = await download(request, maximumBytes: maximumProviderBytes)
        let data: Data
        let code: Int
        switch result {
        case let .success(value, status):
            data = value
            code = status
        case let .failed(status): return .failure(.providerFetchFailed(id: entry.id, status: status))
        case .tooLarge: return .failure(.providerTooLarge(id: entry.id))
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return .failure(.providerFetchFailed(id: entry.id, status: code))
        }
        return .success(text)
    }

    /// Fetch the manifest and every enabled provider's code, returning the installable set. Failed providers are
    /// skipped (fail-soft), so one bad entry does not sink the rest.
    static func install(from raw: String) async -> Result<(manifestName: String?, providers: [JSInstalledProvider]), LoadError> {
        let manifestResult = await fetchManifest(from: raw)
        guard case let .success((manifestURL, manifest)) = manifestResult else {
            if case let .failure(error) = manifestResult { return .failure(error) }
            return .failure(.manifestDecodeFailed)
        }
        var installed: [JSInstalledProvider] = []
        for entry in manifest.scrapers where entry.isEnabled {
            if case let .success(code) = await fetchProviderCode(for: entry, manifestURL: manifestURL) {
                installed.append(JSInstalledProvider(
                    id: entry.id,
                    name: entry.displayName,
                    version: entry.version,
                    supportedTypes: entry.supportedTypes ?? ["movie", "tv"],
                    hasSettings: entry.supportsSettings,
                    code: code
                ))
            }
        }
        return .success((manifest.name, installed))
    }
}

private final class ManifestNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
