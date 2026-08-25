import Foundation

/// Checks GitHub's published releases for a newer build of this platform and remembers it so the UI can
/// offer an update. Sideloaded apps have no store update channel, so this is how users learn a new IPA or
/// DMG exists.
///
/// Marketing versions are compared as numeric components and builds as integers. This avoids lexical traps
/// such as 0.3.10 sorting before 0.3.9, while the build comparison distinguishes betas that share a marketing
/// version. Drafts are excluded. Published prereleases remain eligible because VortX betas are public releases.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Codable, Equatable, Identifiable {
        let version: String
        let build: Int
        let name: String
        let notes: String
        let ipa: String?
        let altstore: String?

        var key: String { "\(version).\(build)" }
        var id: String { key }

        var installURL: URL? {
            if let a = altstore, let u = URL(string: a) { return u }
            if let i = ipa, let u = URL(string: i) { return u }
            return URL(string: "https://github.com/VortXTV/VortX/releases/latest")
        }
    }

    /// A published release newer than the running app, or nil when the app is current.
    @Published private(set) var available: Release?

    /// The active signal consumed by the shared tvOS, iOS, and macOS update sheet.
    @Published var prompt: Release?

    /// Bumped after a manual check finds an update. Roots observe it and honor their launch/player gates before
    /// forcing the sheet to reappear, rather than letting the network layer present behind another surface.
    @Published private(set) var forcePresentationNonce = 0

    /// Builds already surfaced during this process. The set resets on relaunch, so a cached update can produce
    /// the requested one launch alert without another network request inside the daily gate.
    private var promptedKeys: Set<String> = []
    private var isChecking = false
    private var manualCheckPending = false
    private var restoredCache = false

    private static let lastCheckedKey = "stremiox.update.lastChecked"
    private static let dismissedKey = "stremiox.update.dismissedVersion"
    private static let cachedReleaseKey = "stremiox.update.cachedRelease"
    private static let releasesURL = "https://api.github.com/repos/VortXTV/VortX/releases?per_page=100"
    private static let automaticInterval: TimeInterval = 24 * 3600

    private var currentBuild: Int {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-stremiox-fake-build"), i + 1 < args.count,
           let build = Int(args[i + 1]) {
            return build
        }
        return Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    private var currentVersion: String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-stremiox-fake-version"), i + 1 < args.count {
            return args[i + 1]
        }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Called by each platform shell. Restores the last successful result immediately, then starts a network
    /// request only when the persisted daily gate is stale. The request runs asynchronously and never blocks UI.
    func startMonitoring() {
        restoreCachedReleaseIfNeeded()
        checkIfStale()
    }

    func dismissPrompt() {
        if let key = prompt?.key {
            UserDefaults.standard.set(key, forKey: Self.dismissedKey)
        }
        prompt = nil
    }

    /// Passing zero is the explicit manual path and always requests a fresh fetch. Every nonzero call is an
    /// automatic request and uses the fixed one-day gate, even when an older caller supplies a shorter age.
    /// Automatic attempts are timestamped before the request so failures remain silent without causing a retry
    /// loop on foreground or shell appearance.
    func checkIfStale(maxAge: TimeInterval = 24 * 3600) {
        restoreCachedReleaseIfNeeded()
        if maxAge <= 0 {
            if isChecking {
                manualCheckPending = true
            } else {
                check(forcePrompt: true)
            }
            return
        }

        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: Self.lastCheckedKey)
        guard now - last >= Self.automaticInterval, !isChecking else { return }
        UserDefaults.standard.set(now, forKey: Self.lastCheckedKey)
        check(forcePrompt: false)
    }

    private func check(forcePrompt: Bool) {
        isChecking = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.finishCheck() }
            guard let url = URL(string: Self.releasesURL) else { return }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("VortX-UpdateChecker", forHTTPHeaderField: "User-Agent")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
                return
            }

            guard let latest = releases
                .filter({ !$0.draft && $0.publishedAt != nil })
                .compactMap({ self.release(from: $0) })
                .max(by: { self.compare($0, $1) == .orderedAscending }) else {
                self.available = nil
                self.prompt = nil
                UserDefaults.standard.removeObject(forKey: Self.cachedReleaseKey)
                return
            }

            if let encoded = try? JSONEncoder().encode(latest) {
                UserDefaults.standard.set(encoded, forKey: Self.cachedReleaseKey)
            }

            guard self.isNewer(latest) else {
                self.available = nil
                self.prompt = nil
                return
            }
            self.available = latest
            if forcePrompt { self.forcePresentationNonce &+= 1 }
        }
    }

    private func finishCheck() {
        isChecking = false
        guard manualCheckPending else { return }
        manualCheckPending = false
        check(forcePrompt: true)
    }

    private func restoreCachedReleaseIfNeeded() {
        guard !restoredCache else { return }
        restoredCache = true
        guard let data = UserDefaults.standard.data(forKey: Self.cachedReleaseKey),
              let release = try? JSONDecoder().decode(Release.self, from: data),
              isNewer(release) else {
            UserDefaults.standard.removeObject(forKey: Self.cachedReleaseKey)
            return
        }
        available = release
    }

    /// Platform shells call this only after their launch surface is visible. Keeping presentation separate from
    /// discovery prevents a fast response from putting the sheet behind a splash, profile picker, or player.
    func presentAvailableIfNeeded(force: Bool = false) {
        guard let release = available else { return }
        guard force || !promptedKeys.contains(release.key) else { return }
        promptedKeys.insert(release.key)
        prompt = release
    }

    private func release(from github: GitHubRelease) -> Release? {
        guard let version = marketingVersion(in: github.tagName),
              let build = buildNumber(in: [github.name, github.body].compactMap { $0 }.joined(separator: "\n")),
              build > 0,
              let asset = github.assets.first(where: platformAsset) else {
            return nil
        }
        return Release(version: version, build: build,
                       name: github.name ?? github.tagName,
                       notes: github.body ?? "",
                       ipa: asset.browserDownloadURL,
                       altstore: nil)
    }

    private func platformAsset(_ asset: GitHubAsset) -> Bool {
        let name = asset.name.lowercased()
        #if os(tvOS)
        return name.contains("tvos") && !name.contains("lite") && name.hasSuffix(".ipa")
        #elseif os(macOS)
        return name.contains("macos") && (name.hasSuffix(".dmg") || name.hasSuffix(".pkg"))
        #else
        return name.contains("ios") && name.hasSuffix(".ipa")
        #endif
    }

    private func isNewer(_ release: Release) -> Bool {
        let remote = numericVersion(release.version)
        let installed = numericVersion(currentVersion)
        guard !remote.isEmpty, !installed.isEmpty else { return false }
        let versionOrder = compareComponents(remote, installed)
        return versionOrder == .orderedDescending ||
            (versionOrder == .orderedSame && release.build > currentBuild)
    }

    private func compare(_ lhs: Release, _ rhs: Release) -> ComparisonResult {
        let versionOrder = compareComponents(numericVersion(lhs.version), numericVersion(rhs.version))
        guard versionOrder == .orderedSame else { return versionOrder }
        if lhs.build == rhs.build { return .orderedSame }
        return lhs.build < rhs.build ? .orderedAscending : .orderedDescending
    }

    private func marketingVersion(in text: String) -> String? {
        firstMatch(in: text, pattern: #"(?i)(?:^|[^0-9])(\d+(?:\.\d+)+)"#)
    }

    private func buildNumber(in text: String) -> Int? {
        guard let value = firstMatch(in: text, pattern: #"(?i)\bbuild\s*[:#-]?\s*(\d+)\b"#) else { return nil }
        return Int(value)
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func numericVersion(_ version: String) -> [Int] {
        let numeric = marketingVersion(in: version) ?? version
        return numeric.split(separator: ".").compactMap { Int($0) }
    }

    private func compareComponents(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let publishedAt: String?
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body, draft, prerelease, assets
            case publishedAt = "published_at"
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}
