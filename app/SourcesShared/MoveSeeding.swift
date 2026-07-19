import SwiftUI

/// Phase-0 seeding for the upcoming com.vortx home: the NEXT release keeps this bundle id, the one after
/// moves to com.vortx, which on iOS/tvOS gives the app a FRESH local data container. Everything synced to a
/// VortX account restores on sign-in; anything only local does not. So before the move, every device should
/// have pushed its encrypted doc to the account at least once. This type is the single shared authority the
/// launch nag and the Settings banners key on.
///
/// Semantics:
///  - `needsSeeding` is true until the signed-in account has completed one REAL sync round-trip
///    (VortXSyncManager.hasCompletedFirstSync). Signed-out is always "needs seeding".
///  - The launch nag shows AT MOST ONCE PER LAUNCH (`presentedThisLaunch`, in-memory only), is always
///    dismissible, and never blocks the app. It re-arms on the next launch until the device has synced.
///  - The Settings banner is persistent (not launch-gated) so the state is always inspectable there.
@MainActor
enum MoveSeeding {
    /// The one-per-launch latch for the launch nag. In-memory ON PURPOSE: "dismissible per launch,
    /// reappears next launch until synced" is the whole contract, so nothing is persisted.
    static var presentedThisLaunch = false

    /// True while this device still owes its first sync to a VortX account (signed out, or signed in but
    /// never completed a push/pull round-trip).
    static var needsSeeding: Bool { !VortXSyncManager.shared.hasCompletedFirstSync }

    /// Arm the launch nag: waits out the launch chores (splash, profile picker) and then fires `present`
    /// exactly once per launch IF the device still needs seeding. Cheap and cancellable (rides the caller's
    /// `.task`). The profile-picker wait is bounded so an abandoned picker never leaks an armed nag into a
    /// much later moment mid-use.
    static func armLaunchNag(present: @escaping () -> Void) async {
        guard !presentedThisLaunch else { return }
        // Let launch settle: splash (~2s on tvOS), Keychain session restore, and the first sync kick.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        // Wait for the profile picker to clear (bounded at ~30s) so the nag never fights a modal.
        var waited = 0
        while ProfileStore.shared.needsPicker, waited < 60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
        guard !Task.isCancelled, !presentedThisLaunch, needsSeeding else { return }
        presentedThisLaunch = true
        present()
    }

    /// "Last synced 2 hours ago" / "Last synced just now" for the signed-in confirmation states.
    static func lastSyncLine(_ date: Date?) -> String {
        guard let date else { return String(localized: "Waiting for the first sync to finish…") }
        if Date().timeIntervalSince(date) < 90 { return String(localized: "Last synced just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let rel = formatter.localizedString(for: date, relativeTo: Date())
        return String(format: String(localized: "Last synced %@"), rel)
    }

    // MARK: Shared copy (one source for the launch nag + both Settings banners)

    static let headline = String(localized: "VortX is moving to a new home soon")
    static let message = String(localized: "Sign in to your VortX account so your profiles, watch history, library, and settings carry over. Everything is end-to-end encrypted and restores automatically after the move.")
    static let backedUpLine = String(localized: "Your data is backed up to your VortX account.")
}
