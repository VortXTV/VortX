import Foundation

/// The single "give-to-get" consent gate for VortX's community data pool.
///
/// One master switch governs whether this device both CONTRIBUTES anonymized playback / source metadata to
/// the shared pool AND CONSUMES what the pool gives back. It is the opt-out for the WHOLE pool: turning it OFF
/// stops the device from contributing anything AND from consuming every pooled improvement (community scrub
/// previews, community subtitles, community skip segments, localized metadata, and the community source
/// index). Opt-out means out of the pool entirely, in both directions -- there is no take-without-give.
///
/// The default is ON. UserDefaults returns `false` for an unset Bool, so presence is checked before the value
/// (identical to the `CommunityTrickplay.isEnabled` pattern) -- a fresh install with no stored value is ON.
///
/// The user-facing disclosure is deliberately GENERIC. It says the app may collect anonymized playback and
/// source metadata to improve results, and nothing about how the pool is structured or used. Every moat
/// contribute + read call site consults `contributeAndConsume` (folded into each client's own feature gate),
/// so this one switch is the whole surface.
enum MoatConsent {
    /// The @AppStorage / UserDefaults key. Uses the `stremiox.` namespace like the other player-adjacent
    /// settings so the 0.4 `stremiox.` -> `vortx.` rename seam maps it uniformly.
    static let key = "stremiox.moatContribute"

    /// The one-line disclosure shown next to the toggle in Settings. Generic on purpose: it reveals nothing
    /// about the pool's design, only that anonymized playback + source metadata may be collected to improve
    /// results. Keep this wording opaque.
    static let disclosure = String(localized:
        "VortX may collect anonymized playback and source metadata to improve results.")

    /// The master gate. Default ON: an unset value (fresh install) reads as true because a bare
    /// `UserDefaults.bool` is false for an absent key, so we check object presence first.
    static var contributeAndConsume: Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }
}
