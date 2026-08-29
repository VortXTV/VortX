import Combine
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

    typealias RequestLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias Sleeper = @Sendable (TimeInterval) async -> Void

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
    private var monitoringTask: Task<Void, Never>?
    private var didStartMonitoring = false
    private var lastSuccessfulCheckThisSession: TimeInterval?
    private var automaticCheckFailedThisSession = false
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let requestLoader: RequestLoader
    private let sleeper: Sleeper
    private let buildOverride: Int?
    private let versionOverride: String?

    private static let lastCheckedKey = "stremiox.update.lastChecked"
    private static let dismissedKey = "stremiox.update.dismissedVersion"
    private static let cachedReleaseKey = "stremiox.update.cachedRelease"
    private static let releasesURL = "https://api.github.com/repos/VortXTV/VortX/releases?per_page=100"
    /// A fresh automatic request is allowed on launch and once per hour while the app remains alive.
    /// This is deliberately much shorter than a day because sideloaded installs have no store daemon to
    /// surface a release on our behalf.
    private static let automaticInterval: TimeInterval = 3600
    private static let retryInterval: TimeInterval = 60

    /// Injectable dependencies keep the updater testable without a real bundle, wall clock, or GitHub call.
    /// Shipping targets use the defaults.
    init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        requestLoader: @escaping RequestLoader = { request in try await URLSession.shared.data(for: request) },
        sleeper: @escaping Sleeper = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        currentBuild: Int? = nil,
        currentVersion: String? = nil
    ) {
        self.defaults = defaults
        self.now = now
        self.requestLoader = requestLoader
        self.sleeper = sleeper
        self.buildOverride = currentBuild
        self.versionOverride = currentVersion
    }

    private var currentBuild: Int {
        if let buildOverride { return buildOverride }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-stremiox-fake-build"), i + 1 < args.count,
           let build = Int(args[i + 1]) {
            return build
        }
        return Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    private var currentVersion: String {
        if let versionOverride { return versionOverride }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-stremiox-fake-version"), i + 1 < args.count {
            return args[i + 1]
        }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Starts one process-lifetime hourly scheduler while the app is active. The first process start always
    /// fetches immediately, even when a previous launch wrote a recent success timestamp. Later lifecycle
    /// callbacks merely retain the one scheduler and cannot duplicate its request.
    func startMonitoring() {
        restoreCachedReleaseIfNeeded()
        if !didStartMonitoring {
            didStartMonitoring = true
            if !isChecking { check(forcePrompt: false) { [weak self] in self?.armScheduledCheck() } }
        }
        // While the initial forced fetch is in flight, its completion owns the first deadline. A repeated
        // scene callback must not arm a timer from the previous process's persisted timestamp.
        else if !isChecking { armScheduledCheck() }
    }

    /// Called when a platform scene becomes inactive/backgrounded. Cancelling the task releases the pending
    /// timer promptly; foregrounding may start exactly one new scheduler without changing first-launch semantics.
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func dismissPrompt() {
        if let key = prompt?.key {
            defaults.set(key, forKey: Self.dismissedKey)
        }
        prompt = nil
    }

    /// Passing zero is the explicit manual path and always requests a fresh fetch. Every nonzero call is an
    /// automatic request and uses the fixed hourly gate, even when an older caller supplies a shorter age.
    /// A failed request is intentionally not timestamped: it must be retried the next time the shell becomes
    /// active, while `isChecking` keeps repeated appearance notifications single-flight.
    func checkIfStale(maxAge: TimeInterval = 3600, onFinish: (() -> Void)? = nil) {
        restoreCachedReleaseIfNeeded()
        if maxAge <= 0 {
            if isChecking {
                manualCheckPending = true
            } else {
                check(forcePrompt: true, onFinish: onFinish)
            }
            return
        }

        let currentTime = now().timeIntervalSince1970
        let last = defaults.double(forKey: Self.lastCheckedKey)
        // A timestamp from a previous process is not a successful result for this one. Once this session has
        // failed its forced cold-launch request, its short retry loop must bypass that inherited timestamp.
        guard (automaticCheckFailedThisSession || currentTime - last >= Self.automaticInterval), !isChecking else {
            onFinish?()
            return
        }
        check(forcePrompt: false, onFinish: onFinish)
    }

    private func check(forcePrompt: Bool, onFinish: (() -> Void)? = nil) {
        isChecking = true
        Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            defer { self.finishCheck(success: succeeded, forcePrompt: forcePrompt, onFinish: onFinish) }
            guard let url = URL(string: Self.releasesURL) else { return }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("VortX-UpdateChecker", forHTTPHeaderField: "User-Agent")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            guard let (data, response) = try? await self.requestLoader(request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
                return
            }

            // Persist a check only after transport, status, and payload decoding all succeeded. Recording
            // before the request makes a temporary GitHub/DNS failure suppress every later foreground retry.
            self.defaults.set(self.now().timeIntervalSince1970, forKey: Self.lastCheckedKey)
            self.lastSuccessfulCheckThisSession = self.now().timeIntervalSince1970
            succeeded = true

            guard let latest = releases
                .filter({ !$0.draft && $0.publishedAt != nil })
                .compactMap({ self.release(from: $0) })
                .max(by: { self.compare($0, $1) == .orderedAscending }) else {
                self.available = nil
                self.prompt = nil
                self.defaults.removeObject(forKey: Self.cachedReleaseKey)
                return
            }

            if let encoded = try? JSONEncoder().encode(latest) {
                self.defaults.set(encoded, forKey: Self.cachedReleaseKey)
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

    private func finishCheck(success: Bool, forcePrompt: Bool, onFinish: (() -> Void)?) {
        isChecking = false
        if !forcePrompt { automaticCheckFailedThisSession = !success }
        onFinish?()
        guard manualCheckPending else { return }
        manualCheckPending = false
        check(forcePrompt: true)
    }

    /// Arms one one-shot task. The next deadline is always computed after the prior request finished,
    /// so transport latency cannot turn a one-hour cadence into nearly two hours.
    private func armScheduledCheck() {
        guard monitoringTask == nil else { return }
        let delay = nextScheduledDelay()
        let sleeper = self.sleeper
        monitoringTask = Task { [weak self] in
            await sleeper(delay)
            guard !Task.isCancelled, let self else { return }
            self.monitoringTask = nil
            self.checkIfStale { [weak self] in self?.armScheduledCheck() }
        }
    }

    private func nextScheduledDelay() -> TimeInterval {
        if let successful = lastSuccessfulCheckThisSession {
            return max(0, successful + Self.automaticInterval - now().timeIntervalSince1970)
        }
        return automaticCheckFailedThisSession ? Self.retryInterval : Self.automaticInterval
    }

    private func restoreCachedReleaseIfNeeded() {
        guard !restoredCache else { return }
        restoredCache = true
        guard let data = defaults.data(forKey: Self.cachedReleaseKey),
              let release = try? JSONDecoder().decode(Release.self, from: data),
              isNewer(release) else {
            defaults.removeObject(forKey: Self.cachedReleaseKey)
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
              // The public release title is canonical. Release-note bodies carry older beta history, so their
              // first "Build" marker is not necessarily the build of this release.
              let build = buildNumber(in: github.name ?? "") ?? highestBuildNumber(in: github.body ?? ""),
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

    private func highestBuildNumber(in text: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)\bbuild\s*[:#-]?\s*(\d+)\b"#) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range)
            .compactMap { match in
                guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
                return Int(text[valueRange])
            }
            .max()
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
