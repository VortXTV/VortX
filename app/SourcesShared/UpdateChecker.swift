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
        /// Exact public release tag. Marketing version comparison intentionally excludes a beta suffix.
        let tag: String?
        let build: Int
        let name: String
        let notes: String
        let ipa: String?
        let altstore: String?
        /// Published appcast metadata. It is not a claim that a downloaded artifact was locally verified.
        let size: Int?
        let sha256: String?

        init(version: String, tag: String? = nil, build: Int, name: String, notes: String,
             ipa: String?, altstore: String?, size: Int?, sha256: String?) {
            self.version = version
            self.tag = tag
            self.build = build
            self.name = name
            self.notes = notes
            self.ipa = ipa
            self.altstore = altstore
            self.size = size
            self.sha256 = sha256
        }

        var key: String { "\(version).\(build)" }
        var id: String { key }

        var installURL: URL? {
            if let a = altstore, let u = URL(string: a) { return u }
            if let i = ipa, let u = URL(string: i) { return u }
            return URL(string: "https://github.com/VortXTV/VortX/releases/latest")
        }
    }

    /// User-visible state for an explicit Settings or macOS menu check. The generic failure case intentionally
    /// keeps transport, HTTP, and decoding details out of the UI while still making every failed manual request
    /// visibly retryable.
    enum ManualCheckOutcome: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(Release)
        case failure

        var isChecking: Bool {
            if case .checking = self { return true }
            return false
        }

        var accessibilityText: String {
            switch self {
            case .idle: return ""
            case .checking: return "Checking for updates"
            case .upToDate: return "You’re up to date"
            case .updateAvailable(let release): return "Update available: \(release.name)"
            case .failure: return "Unable to check for updates. Try again."
            }
        }
    }

    /// A published release newer than the running app, or nil when the app is current.
    @Published private(set) var available: Release?

    /// The active signal consumed by the shared tvOS, iOS, and macOS update sheet.
    @Published var prompt: Release?

    /// Bumped after a manual check finds an update. Roots observe it and honor their launch/player gates before
    /// forcing the sheet to reappear, rather than letting the network layer present behind another surface.
    @Published private(set) var forcePresentationNonce = 0

    /// The outcome of the latest explicit check. Automatic monitoring intentionally leaves this untouched so a
    /// background retry never replaces a Settings result the user is reading.
    @Published private(set) var manualOutcome: ManualCheckOutcome = .idle

    var isManualCheckInProgress: Bool { manualOutcome.isChecking }

    /// Builds already surfaced during this process. The set resets on relaunch, so a cached update can produce
    /// the requested one launch alert without another network request inside the daily gate.
    private var promptedKeys: Set<String> = []
    private var isChecking = false
    private var manualCheckPending = false
    private var pendingManualFinishHandlers: [() -> Void] = []
    private var restoredCache = false
    private var monitoringTask: Task<Void, Never>?
    private var didStartMonitoring = false
    private var isMonitoring = false
    private var monitoringGeneration: UInt64 = 0
    private var pendingMonitoringGeneration: UInt64?
    private var lastSuccessfulCheckThisSession: TimeInterval?
    private var automaticCheckFailedThisSession = false
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let requestLoader: RequestLoader
    private let sleeper: Sleeper
    private let buildOverride: Int?
    private let versionOverride: String?
    private let liteOverride: Bool?

    private static let lastCheckedKey = "stremiox.update.lastChecked"
    private static let dismissedKey = "stremiox.update.dismissedVersion"
    private static let cachedReleaseKey = "stremiox.update.cachedRelease"
    private static let appcastURL = "https://vortx.tv/appcast.json"
    private static let releasesURL = "https://api.github.com/repos/VortXTV/VortX/releases?per_page=20"
    private static let maxResponseBytes = 512 * 1024
    private static let maxReleaseCount = 20
    private static let maxAssetCount = 100
    private static let maxNameLength = 240
    private static let maxNotesLength = 50_000
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
        currentVersion: String? = nil,
        isLite: Bool? = nil
    ) {
        self.defaults = defaults
        self.now = now
        self.requestLoader = requestLoader
        self.sleeper = sleeper
        self.buildOverride = currentBuild
        self.versionOverride = currentVersion
        self.liteOverride = isLite
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
        if !isMonitoring {
            isMonitoring = true
            monitoringGeneration &+= 1
        }
        let generation = monitoringGeneration
        if !didStartMonitoring {
            didStartMonitoring = true
            if !isChecking {
                check(forcePrompt: false, isManual: false) { [weak self] in self?.completeMonitoringCheck(generation) }
            } else {
                pendingMonitoringGeneration = generation
            }
        }
        // While the initial forced fetch is in flight, its completion owns the first deadline. A repeated
        // scene callback must not arm a timer from the previous process's persisted timestamp.
        else if !isChecking { armScheduledCheck(generation) }
        else { pendingMonitoringGeneration = generation }
    }

    /// Called when a platform scene becomes inactive/backgrounded. Cancelling the task releases the pending
    /// timer promptly; foregrounding may start exactly one new scheduler without changing first-launch semantics.
    func stopMonitoring() {
        isMonitoring = false
        monitoringGeneration &+= 1
        pendingMonitoringGeneration = nil
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func dismissPrompt() {
        if let key = prompt?.key {
            defaults.set(key, forKey: Self.dismissedKey)
        }
        prompt = nil
    }

    /// Performs an explicit fresh update check. If automatic monitoring already owns the one network request,
    /// this queues exactly one forced check behind it rather than opening a second request in parallel.
    func checkNow() {
        checkNow(onFinish: nil)
    }

    private func checkNow(onFinish: (() -> Void)?) {
        restoreCachedReleaseIfNeeded()
        manualOutcome = .checking
        if isChecking {
            manualCheckPending = true
            if let onFinish { pendingManualFinishHandlers.append(onFinish) }
        } else {
            check(forcePrompt: true, isManual: true, onFinish: onFinish)
        }
    }

    /// Passing zero remains the legacy explicit-manual path and always requests a fresh fetch. Every nonzero call
    /// is an automatic request and uses the fixed hourly gate, even when an older caller supplies a shorter age.
    /// A failed request is intentionally not timestamped: it must be retried the next time the shell becomes
    /// active, while `isChecking` keeps repeated appearance notifications single-flight.
    func checkIfStale(maxAge: TimeInterval = 3600, onFinish: (() -> Void)? = nil) {
        restoreCachedReleaseIfNeeded()
        if maxAge <= 0 {
            checkNow(onFinish: onFinish)
            return
        }

        let currentTime = now().timeIntervalSince1970
        let last = defaults.double(forKey: Self.lastCheckedKey)
        if isChecking {
            // A scheduler tick that lands while a manual request owns discovery must transfer its next-deadline
            // responsibility to that request. Calling onFinish here can re-arm at zero delay and hot-loop.
            if isMonitoring { pendingMonitoringGeneration = monitoringGeneration }
            return
        }
        // A timestamp from a previous process is not a successful result for this one. Once this session has
        // failed its forced cold-launch request, its short retry loop must bypass that inherited timestamp.
        guard automaticCheckFailedThisSession || currentTime - last >= Self.automaticInterval else {
            onFinish?()
            return
        }
        check(forcePrompt: false, isManual: false, onFinish: onFinish)
    }

    private func check(forcePrompt: Bool, isManual: Bool, onFinish: (() -> Void)? = nil) {
        isChecking = true
        Task { [weak self] in
            guard let self else { return }
            var succeeded = false
            var outcome: ManualCheckOutcome = .failure
            defer {
                self.finishCheck(success: succeeded, forcePrompt: forcePrompt, isManual: isManual,
                                 manualOutcome: outcome, onFinish: onFinish)
            }
            let discovery = await self.discoverLatestRelease(cached: self.validatedRelease(self.available))
            guard case let .release(latest) = discovery else {
                if case .current = discovery {
                    self.recordSuccessfulCheck()
                    if isManual { self.replaceMonitoringDeadlineAfterManualSuccess() }
                    succeeded = true
                    self.available = nil
                    self.prompt = nil
                    self.defaults.removeObject(forKey: Self.cachedReleaseKey)
                    outcome = .upToDate
                }
                return
            }

            // Persist a check only after transport, status, and payload decoding all succeeded. Recording
            // before the request makes a temporary GitHub/DNS failure suppress every later foreground retry.
            self.recordSuccessfulCheck()
            if isManual { self.replaceMonitoringDeadlineAfterManualSuccess() }
            succeeded = true

            // Never regress a cached/newer candidate because a successful but older endpoint replied later.
            let selected = self.newerRelease(latest, than: self.validatedRelease(self.available))
            guard let latest = selected else { return }
            if let encoded = try? JSONEncoder().encode(latest) {
                self.defaults.set(encoded, forKey: Self.cachedReleaseKey)
            }

            guard self.isNewer(latest) else {
                self.available = nil
                self.prompt = nil
                outcome = .upToDate
                return
            }
            self.available = latest
            if !isManual, case .upToDate = self.manualOutcome { self.manualOutcome = .idle }
            outcome = .updateAvailable(latest)
            if forcePrompt { self.forcePresentationNonce &+= 1 }
        }
    }

    private func recordSuccessfulCheck() {
        let timestamp = now().timeIntervalSince1970
        defaults.set(timestamp, forKey: Self.lastCheckedKey)
        lastSuccessfulCheckThisSession = timestamp
    }

    /// A successful manual recovery supersedes a short retry that was armed after a failed automatic request.
    /// Replacing it here keeps the next automatic attempt on the normal hourly cadence.
    private func replaceMonitoringDeadlineAfterManualSuccess() {
        automaticCheckFailedThisSession = false
        guard isMonitoring else { return }
        monitoringTask?.cancel()
        monitoringTask = nil
        armScheduledCheck(monitoringGeneration)
    }

    /// The appcast names exactly one asset for this platform and carries the release integrity receipt. It is
    /// authoritative whenever it passes the client-side schema and artifact checks. GitHub is only a fallback
    /// for transport, HTTP, decoding, schema, or selected-entry validation failure, never a second source to
    /// merge or rank against it.
    private func discoverLatestRelease(cached: Release?) async -> DiscoveryResult {
        let appcast = await appcastDiscovery()
        if case .release(let release) = appcast,
           isNewer(release), newerRelease(release, than: cached) == release {
            // A valid, actually newer appcast is the authoritative source. Do not merge it with GitHub.
            return .release(release)
        }

        // A current or stale appcast is not sufficient evidence to suppress an already-known newer release or a
        // newer GitHub fallback. This also repairs a stale edge cache without trusting it over a validated cache.
        let github = await gitHubDiscovery()
        let appcastCandidate: Release?
        if case .release(let release) = appcast { appcastCandidate = release }
        else { appcastCandidate = nil }
        let githubCandidate: Release?
        if case .release(let release) = github { githubCandidate = release }
        else { githubCandidate = nil }
        if let newest = newestRelease(in: [cached, appcastCandidate, githubCandidate]) {
            return .release(newest)
        }
        if case .failure = github { return .failure }
        return .current
    }

    private func appcastDiscovery() async -> DiscoveryResult {
        // appcast's tvOS entry is the Full target. Lite has a distinct bundle identifier and exact IPA, so it
        // deliberately uses the strictly bound GitHub asset path below instead of ever being offered Full.
        guard !isLiteBuild else { return .current }
        guard let url = URL(string: Self.appcastURL),
              let (data, response) = try? await request(url, githubAPI: false),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let appcast = try? JSONDecoder().decode(Appcast.self, from: data),
              appcast.schemaVersion == 2,
              let entry = appcastEntry(in: appcast),
              let release = release(from: entry) else {
            return .failure
        }
        return .release(release)
    }

    private func gitHubDiscovery() async -> DiscoveryResult {
        guard let url = URL(string: Self.releasesURL),
              let (data, response) = try? await request(url, githubAPI: true),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data),
              releases.count <= Self.maxReleaseCount else {
            return .failure
        }
        guard let latest = releases
            .filter({ !$0.draft && $0.publishedAt != nil && $0.assets.count <= Self.maxAssetCount })
            .compactMap({ release(from: $0) })
            .max(by: { compare($0, $1) == .orderedAscending }) else {
            return .current
        }
        return .release(latest)
    }

    private func request(_ url: URL, githubAPI: Bool) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        // The updater's cadence is its cache policy. A manual check must not receive a prior URLSession response
        // merely because the user opened Settings shortly after an automatic attempt.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(githubAPI ? "application/vnd.github+json" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("VortX-UpdateChecker", forHTTPHeaderField: "User-Agent")
        if githubAPI { request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version") }
        let (data, response) = try await requestLoader(request)
        guard data.count <= Self.maxResponseBytes,
              let finalURL = response.url,
              isExpectedFinalResponseURL(finalURL, githubAPI: githubAPI) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    private func finishCheck(success: Bool, forcePrompt: Bool, isManual: Bool,
                             manualOutcome: ManualCheckOutcome, onFinish: (() -> Void)?) {
        isChecking = false
        if !forcePrompt { automaticCheckFailedThisSession = !success }
        if isManual { self.manualOutcome = manualOutcome }
        onFinish?()
        guard manualCheckPending else {
            completePendingMonitoringIfNeeded()
            return
        }
        manualCheckPending = false
        let pendingHandlers = pendingManualFinishHandlers
        pendingManualFinishHandlers.removeAll()
        check(forcePrompt: true, isManual: true) {
            pendingHandlers.forEach { $0() }
        }
    }

    /// A manual request can be in flight when monitoring first starts, or when an hourly timer becomes due.
    /// Its completion takes over the pending generation exactly once, after any queued manual check has settled.
    private func completePendingMonitoringIfNeeded() {
        guard !isChecking, isMonitoring,
              let generation = pendingMonitoringGeneration,
              generation == monitoringGeneration else { return }
        pendingMonitoringGeneration = nil
        completeMonitoringCheck(generation)
    }

    /// Arms one one-shot task. The next deadline is always computed after the prior request finished,
    /// so transport latency cannot turn a one-hour cadence into nearly two hours.
    private func completeMonitoringCheck(_ generation: UInt64) {
        guard isMonitoring, generation == monitoringGeneration else {
            if isMonitoring, pendingMonitoringGeneration == monitoringGeneration {
                let pending = monitoringGeneration
                pendingMonitoringGeneration = nil
                check(forcePrompt: false, isManual: false) { [weak self] in self?.completeMonitoringCheck(pending) }
            }
            return
        }
        pendingMonitoringGeneration = nil
        armScheduledCheck(generation)
    }

    private func armScheduledCheck(_ generation: UInt64) {
        guard isMonitoring, generation == monitoringGeneration, monitoringTask == nil else { return }
        let delay = nextScheduledDelay()
        let sleeper = self.sleeper
        monitoringTask = Task { [weak self] in
            await sleeper(delay)
            guard !Task.isCancelled, let self, self.isMonitoring,
                  self.monitoringGeneration == generation else { return }
            self.monitoringTask = nil
            self.checkIfStale { [weak self] in self?.completeMonitoringCheck(generation) }
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
              let release = validatedRelease(release),
              isNewer(release) else {
            defaults.removeObject(forKey: Self.cachedReleaseKey)
            return
        }
        available = release
    }

    /// Platform shells call this only after their launch surface is visible. Keeping presentation separate from
    /// discovery prevents a fast response from putting the sheet behind a splash, profile picker, or player.
    func presentAvailableIfNeeded(force: Bool = false) {
        guard let release = validatedRelease(available), isNewer(release) else {
            available = nil
            prompt = nil
            return
        }
        guard force || !promptedKeys.contains(release.key) else { return }
        promptedKeys.insert(release.key)
        prompt = release
    }

    private enum DiscoveryResult {
        case release(Release)
        case current
        case failure
    }

    private func appcastEntry(in appcast: Appcast) -> AppcastEntry? {
        #if os(tvOS)
        return appcast.tvos
        #elseif os(macOS)
        return appcast.mac
        #else
        return appcast.ios
        #endif
    }

    private func release(from entry: AppcastEntry) -> Release? {
        guard entry.artifactType == expectedArtifactType else { return nil }
        let release = Release(version: entry.version, tag: entry.tag, build: entry.build, name: entry.name, notes: entry.notes,
                              ipa: entry.url ?? entry.ipa, altstore: entry.altstore,
                              size: entry.size, sha256: entry.sha256)
        return validatedRelease(release, requiresIntegrity: true)
    }

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    /// Final sink validation for network releases and persisted cache alike. Discovery adapters may parse their
    /// own schemas, but nothing reaches `available`, `prompt`, or `openURL` without this exact platform binding.
    private func validatedRelease(_ release: Release?, requiresIntegrity: Bool = false) -> Release? {
        guard let release,
              let version = numericVersion(release.version),
              release.build > 0,
              release.name.count > 0, release.name.count <= Self.maxNameLength,
              release.notes.count <= Self.maxNotesLength,
              release.name.localizedCaseInsensitiveContains(release.version),
              let tag = validatedReleaseTag(release.tag, version: release.version),
              let artifact = exactArtifactURL(release.ipa, tag: tag),
              release.ipa == artifact.absoluteString else {
            return nil
        }
        let hasIntegrity = release.size != nil || release.sha256 != nil
        guard !hasIntegrity || (release.size ?? 0) > 0 && isLowercaseSHA256(release.sha256 ?? ""),
              !requiresIntegrity || hasIntegrity,
              release.altstore == nil || exactAltstoreURL(release.altstore) != nil else {
            return nil
        }
        // Bind the fully parsed numeric version, so a string that merely contains a valid numeric fragment cannot
        // reach the install URL sink.
        guard !version.isEmpty else { return nil }
        return release
    }

    private func exactArtifactURL(_ rawURL: String?, tag: String) -> URL? {
        guard let rawURL, let url = URL(string: rawURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.path == "/VortXTV/VortX/releases/download/\(tag)/\(expectedArtifactFilename(tag))" else {
            return nil
        }
        return url
    }

    private func exactAltstoreURL(_ rawURL: String?) -> URL? {
        guard let rawURL, let url = URL(string: rawURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "vortx.tv",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.path == "/altstore.json" else {
            return nil
        }
        return url
    }

    private func isExpectedFinalResponseURL(_ url: URL, githubAPI: Bool) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil else { return false }
        if githubAPI {
            return components.host == "api.github.com" &&
                components.path == "/repos/VortXTV/VortX/releases" &&
                components.queryItems == [URLQueryItem(name: "per_page", value: "20")]
        }
        return components.host == "vortx.tv" && components.path == "/appcast.json" && components.query == nil
    }

    private var expectedArtifactType: String {
        if isLiteBuild { return "ipa" }
        #if os(macOS)
        return "dmg"
        #else
        return "ipa"
        #endif
    }

    private func expectedArtifactFilename(_ tag: String) -> String {
        #if os(tvOS)
        return isLiteBuild ? "VortX-tvOS-lite-\(tag)-ci.ipa" : "VortX-tvOS-\(tag)-ci.ipa"
        #elseif os(macOS)
        return isLiteBuild ? "VortX-tvOS-lite-\(tag)-ci.ipa" : "VortX-macOS-\(tag)-ci.dmg"
        #else
        return isLiteBuild ? "VortX-tvOS-lite-\(tag)-ci.ipa" : "VortX-iOS-\(tag)-ci.ipa"
        #endif
    }

    private var isLiteBuild: Bool {
        if let liteOverride { return liteOverride }
        #if os(tvOS)
        return Bundle.main.bundleIdentifier == "com.stremiox.tv.lite"
        #else
        return false
        #endif
    }

    private func newerRelease(_ candidate: Release, than existing: Release?) -> Release? {
        guard let candidate = validatedRelease(candidate) else { return existing }
        guard let existing = validatedRelease(existing) else { return candidate }
        return compare(candidate, existing) == .orderedAscending ? existing : candidate
    }

    private func newestRelease(in candidates: [Release?]) -> Release? {
        candidates.compactMap { validatedRelease($0) }
            .max(by: { compare($0, $1) == .orderedAscending })
    }

    private func release(from github: GitHubRelease) -> Release? {
        guard let identity = releaseIdentity(from: github.tagName),
              // The public release title is canonical. Release-note bodies carry older beta history, so their
              // first "Build" marker is not necessarily the build of this release.
              let build = buildNumber(in: github.name ?? "") ?? highestBuildNumber(in: github.body ?? ""),
              build > 0,
              let asset = github.assets.first(where: { $0.name == expectedArtifactFilename(identity.tag) }) else {
            return nil
        }
        let release = Release(version: identity.version, tag: identity.tag, build: build,
                              name: github.name ?? github.tagName,
                              notes: github.body ?? "",
                              ipa: asset.browserDownloadURL,
                              altstore: nil,
                              size: nil,
                              sha256: nil)
        return validatedRelease(release)
    }

    private func isNewer(_ release: Release) -> Bool {
        guard let remote = numericVersion(release.version),
              let installed = numericVersion(currentVersion) else { return false }
        let versionOrder = compareComponents(remote, installed)
        return versionOrder == .orderedDescending ||
            (versionOrder == .orderedSame && release.build > currentBuild)
    }

    private func compare(_ lhs: Release, _ rhs: Release) -> ComparisonResult {
        guard let left = numericVersion(lhs.version), let right = numericVersion(rhs.version) else {
            return .orderedSame
        }
        let versionOrder = compareComponents(left, right)
        guard versionOrder == .orderedSame else { return versionOrder }
        if lhs.build == rhs.build { return .orderedSame }
        return lhs.build < rhs.build ? .orderedAscending : .orderedDescending
    }

    private func releaseIdentity(from tag: String) -> (tag: String, version: String)? {
        guard tag.first == "v" else { return nil }
        let body = String(tag.dropFirst())
        let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let version = parts.first.map(String.init), numericVersion(version) != nil,
              parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }) else {
            return nil
        }
        return (tag, version)
    }

    private func validatedReleaseTag(_ explicitTag: String?, version: String) -> String? {
        let candidate = explicitTag ?? "v\(version)"
        guard let identity = releaseIdentity(from: candidate), identity.version == version else { return nil }
        return identity.tag
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

    private func numericVersion(_ version: String) -> [Int]? {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        let values = components.compactMap { Int($0) }
        return values.count == components.count ? values : nil
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

    private struct Appcast: Decodable {
        let schemaVersion: Int
        let ios: AppcastEntry?
        let tvos: AppcastEntry?
        let mac: AppcastEntry?
    }

    private struct AppcastEntry: Decodable {
        let tag: String
        let version: String
        let build: Int
        let name: String
        let notes: String
        let ipa: String?
        let url: String?
        let size: Int
        let sha256: String
        let altstore: String?
        let artifactType: String
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
