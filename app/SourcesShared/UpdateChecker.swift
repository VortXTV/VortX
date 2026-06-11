import Foundation

/// Once per launch, asks GitHub for the latest release and remembers whether it
/// is newer than the running build. Sideloaded apps have no update channel, so
/// this is how users find out a new IPA exists; Settings shows the result.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String   // "0.2.23", tag with the leading v stripped
        let name: String      // release title, e.g. "StremioX 0.2.23"
    }

    /// A release newer than the running build, or nil (also nil before/without a check).
    @Published private(set) var available: Release?

    private static let lastCheckedKey = "stremiox.update.lastChecked"

    /// The running version, overridable for testing the Settings row
    /// (-stremiox-fake-version 0.1.0).
    private var currentVersion: String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-stremiox-fake-version"), i + 1 < args.count { return args[i + 1] }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Re-check when the last check is older than maxAge (6h). tvOS apps rarely
    /// relaunch: they suspend for days, so a once-per-launch check meant a user
    /// could sit one release behind forever. Called from Settings and on every
    /// return to the foreground.
    /// Settings passes a short maxAge (visiting it usually MEANS "any updates?");
    /// background activations use the 6 hour default. The fake-version test hook
    /// bypasses the gate entirely.
    func checkIfStale(maxAge: TimeInterval = 6 * 3600) {
        let testing = ProcessInfo.processInfo.arguments.contains("-stremiox-fake-version")
        let last = UserDefaults.standard.double(forKey: Self.lastCheckedKey)
        guard testing || Date().timeIntervalSince1970 - last >= maxAge else { return }
        check()
    }

    private func check() {
        Task { [weak self] in
            guard let self else { return }
            // /releases/latest excludes drafts and prereleases (the vendor asset
            // release stays invisible here).
            guard let url = URL(string: "https://api.github.com/repos/mamaclapper/StremioX/releases/latest"),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try? JSONDecoder().decode(LatestRelease.self, from: data) else { return }
            // Only a successful check counts: a network blip must not silence
            // update notices for the next six hours.
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckedKey)
            let tag = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName
            if Self.isVersion(tag, newerThan: self.currentVersion) {
                self.available = Release(version: tag, name: payload.name ?? tag)
            }
        }
    }

    /// Plain numeric semver comparison; unparseable components count as zero.
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct LatestRelease: Decodable {
        let tagName: String
        let name: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
        }
    }
}
