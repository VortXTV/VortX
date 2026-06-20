import Foundation

/// Checks vortx.tv/appcast.json for a newer BUILD of this platform and remembers it so the UI can offer
/// an update. Sideloaded apps have no store update channel, so this is how users learn a new IPA exists.
///
/// Compares by BUILD (CFBundleVersion), NOT marketing version: the betas share the marketing version
/// ("0.3.8") and differ only by build (115 -> 116), and they ship as GitHub PRERELEASES. The old check
/// (/releases/latest + semver on the marketing version) could therefore NEVER see a beta -> beta update:
/// /latest excludes prereleases, and "0.3.8" is not newer than "0.3.8". A manifest we host carries the
/// build number, so the comparison is reliable. See [[vortx-inapp-update-design]].
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable, Identifiable {
        let version: String      // marketing, e.g. "0.3.8"
        let build: Int           // CFBundleVersion, e.g. 116 — the real beta discriminator
        let name: String         // release title, e.g. "Beta 4"
        let notes: String        // what's new (shown in the update sheet)
        let ipa: String?         // direct signed-IPA URL (a GitHub release asset)
        let altstore: String?    // AltStore/SideStore source URL for one-tap / auto update

        /// A stable key that distinguishes betas (which share `version`); used for the dismiss memory
        /// and as the `Identifiable` id so a `.sheet(item:)` re-presents when a still-newer build ships.
        var key: String { "\(version).\(build)" }
        var id: String { key }
        /// Where "Get the update" should send the user: the AltStore source (add once -> auto-updates) if
        /// present, else the direct IPA, else the releases page. iOS cannot self-install a sideloaded app,
        /// so this hands off to the install channel rather than pretending to overwrite in place.
        var installURL: URL? {
            if let a = altstore, let u = URL(string: a) { return u }
            if let i = ipa, let u = URL(string: i) { return u }
            return URL(string: "https://github.com/VortXTV/VortX/releases/latest")
        }
    }

    /// A build newer than the running one, or nil (also nil before/without a check, or when up to date).
    /// This is the PASSIVE signal: the tvOS Settings row and the iOS top banner read it.
    @Published private(set) var available: Release?

    /// The ACTIVE signal: when non-nil, every platform's root presents a modal update popup bound to it via
    /// `.sheet(item:)`. Set by `check()` for a newer build that has not yet been prompted THIS launch (see
    /// `promptedKeys`), so the popup appears automatically once per launch and again when the hourly re-check
    /// finds a still-newer build. Cleared by `dismissPrompt()`.
    @Published var prompt: Release?

    /// Builds already surfaced as a popup during THIS launch. In-memory (never persisted) on purpose: it
    /// suppresses a second popup for the same build within one session, but resets on relaunch so the user is
    /// reminded once every launch until they actually update. (The iOS banner's dismissal, by contrast, IS
    /// persisted, so dismissing the popup quiets the banner for that build but not the next-launch popup.)
    private var promptedKeys: Set<String> = []

    /// Hourly re-check while the app stays open, so a user who leaves the app running still learns about a
    /// release without relaunching. Started by `startMonitoring()`.
    private var hourlyTimer: Timer?
    private static let hourlyInterval: TimeInterval = 3600

    private static let lastCheckedKey = "stremiox.update.lastChecked"
    private static let dismissedKey = "stremiox.update.dismissedVersion"   // shared with the iOS banner
    private static let manifestURL = "https://vortx.tv/appcast.json"

    /// The running build, overridable for testing the Settings row + banner (-stremiox-fake-build 1).
    private var currentBuild: Int {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-stremiox-fake-build"), i + 1 < args.count, let b = Int(args[i + 1]) { return b }
        return Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    /// Which manifest entry this build reads.
    private var platformKey: String {
        #if os(tvOS)
        return "tvos"
        #elseif os(macOS)
        return "mac"
        #else
        return "ios"
        #endif
    }

    /// Call once from each platform's root view on appear. Fires an immediate (un-gated) check so the popup
    /// can appear once per launch when an update exists, then schedules an hourly re-check for as long as the
    /// app stays open. Idempotent: a second call won't stack a second timer.
    func startMonitoring() {
        check()   // un-gated: the once-per-launch popup must not be silenced by a recent check timestamp
        guard hourlyTimer == nil else { return }   // idempotent: the singleton keeps one timer for the app's life
        hourlyTimer = Timer.scheduledTimer(withTimeInterval: Self.hourlyInterval, repeats: true) { _ in
            // Capture `self` only inside the @MainActor Task so the weak load happens on the actor, not on the
            // timer's run-loop thread (sound under Swift 6 strict concurrency). The fetch is gated only by the
            // build comparison, so an hourly check is cheap.
            Task { @MainActor [weak self] in self?.check() }
        }
    }

    /// The user dismissed the popup ("Later" or after tapping "Get the update"). Clear it. The build's key is
    /// already in `promptedKeys`, so it won't re-pop this launch. Also persist the dismissal under the key the
    /// iOS banner reads, so dismissing the popup doesn't leave the passive banner nagging for the same build.
    func dismissPrompt() {
        if let key = prompt?.key {
            UserDefaults.standard.set(key, forKey: Self.dismissedKey)
        }
        prompt = nil
    }

    /// Re-check when the last check is older than maxAge (6h default). tvOS apps rarely relaunch (they
    /// suspend for days), so a once-per-launch check meant a user could sit a release behind forever;
    /// this is also called on every return to the foreground. Settings passes a short maxAge (a Settings
    /// visit usually MEANS "any updates?"). The fake-build test hook bypasses the gate.
    func checkIfStale(maxAge: TimeInterval = 6 * 3600) {
        let testing = ProcessInfo.processInfo.arguments.contains("-stremiox-fake-build")
        let last = UserDefaults.standard.double(forKey: Self.lastCheckedKey)
        guard testing || Date().timeIntervalSince1970 - last >= maxAge else { return }
        check()
    }

    @MainActor private func check() {
        Task { [weak self] in
            guard let self else { return }
            guard let url = URL(string: Self.manifestURL),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                return
            }
            // Only a successful fetch counts, so a network blip doesn't silence notices for 6h.
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckedKey)
            guard let e = manifest.entry(for: self.platformKey), e.build > self.currentBuild else {
                self.available = nil; self.prompt = nil; return
            }
            let release = Release(version: e.version ?? "", build: e.build, name: e.name ?? (e.version ?? "Update"),
                                  notes: e.notes ?? "", ipa: e.ipa, altstore: e.altstore)
            self.available = release
            // Raise the popup once per launch per build: the launch check shows it, and the hourly re-check
            // shows it again only when a genuinely newer build appears (a new key).
            if !self.promptedKeys.contains(release.key) {
                self.promptedKeys.insert(release.key)
                self.prompt = release
            }
        }
    }

    private struct Entry: Decodable {
        let version: String?
        let build: Int
        let name: String?
        let notes: String?
        let ipa: String?
        let altstore: String?
    }

    /// Typed wrapper over the manifest. Decoding into named optional fields (instead of `[String: Entry]`)
    /// makes the parse tolerant of non-entry top-level keys: the live manifest carries a `_comment` string,
    /// and a dictionary decode is all-or-nothing, so that one string used to fail the WHOLE decode and
    /// silence updates on every platform. Unknown keys (`_comment`, future additions) are now ignored.
    private struct Manifest: Decodable {
        let ios: Entry?
        let tvos: Entry?
        let mac: Entry?
        func entry(for key: String) -> Entry? {
            switch key {
            case "tvos": return tvos
            case "mac":  return mac
            default:     return ios
            }
        }
    }
}
