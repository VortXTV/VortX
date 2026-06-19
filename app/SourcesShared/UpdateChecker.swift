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

    struct Release: Equatable {
        let version: String      // marketing, e.g. "0.3.8"
        let build: Int           // CFBundleVersion, e.g. 116 — the real beta discriminator
        let name: String         // release title, e.g. "Beta 4"
        let notes: String        // what's new (shown in the update sheet)
        let ipa: String?         // direct signed-IPA URL (a GitHub release asset)
        let altstore: String?    // AltStore/SideStore source URL for one-tap / auto update

        /// A stable key that distinguishes betas (which share `version`); used for the dismiss memory.
        var key: String { "\(version).\(build)" }
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
    @Published private(set) var available: Release?

    private static let lastCheckedKey = "stremiox.update.lastChecked"
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

    private func check() {
        Task { [weak self] in
            guard let self else { return }
            guard let url = URL(string: Self.manifestURL),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let manifest = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
            // Only a successful fetch counts, so a network blip doesn't silence notices for 6h.
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckedKey)
            guard let e = manifest[self.platformKey], e.build > self.currentBuild else { self.available = nil; return }
            self.available = Release(version: e.version ?? "", build: e.build, name: e.name ?? (e.version ?? "Update"),
                                     notes: e.notes ?? "", ipa: e.ipa, altstore: e.altstore)
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
}
