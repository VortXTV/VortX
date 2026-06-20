import Foundation

/// Post-update "What's New" highlights, shown once when the app's build number increases. It deliberately
/// never shows on a fresh install (a first-time user should not be greeted with a changelog) and never twice
/// for the same build. Highlights are curated per marketing version; a release cut updates `highlights` and
/// `version`. Pure logic so it compiles on every target; the sheet UI lives in WhatsNewView (iOS/Mac).
enum WhatsNew {
    static let version = "0.3.8"
    static let highlights: [String] = [
        "Per-profile libraries and Continue Watching now sync reliably across all your devices.",
        "Manage every profile, and set up a family household, from the vortx.tv dashboard.",
        "New video upscaling presets, including Anime4K for animation.",
        "Auto-playing trailers in the title hero, plus curated collections on Home.",
        "Share any title, and a cleaner, more readable account dashboard.",
    ]

    private static let seenKey = "stremiox.whatsNewSeenBuild"

    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    /// True only on an UPGRADE (a stored, lower build): not on a fresh install, and not once already seen
    /// for this build. The build that first introduces this mechanism cannot show (there is no prior
    /// baseline to compare against); the next build bump shows it.
    static func shouldShow() -> Bool {
        let seen = UserDefaults.standard.integer(forKey: seenKey)
        return seen != 0 && seen < currentBuild && !highlights.isEmpty
    }

    /// Record the current build WITHOUT showing, so a fresh install starts in the "already seen" state.
    static func recordFreshInstallIfNeeded() {
        if UserDefaults.standard.integer(forKey: seenKey) == 0 { markSeen() }
    }

    static func markSeen() { UserDefaults.standard.set(currentBuild, forKey: seenKey) }
}
