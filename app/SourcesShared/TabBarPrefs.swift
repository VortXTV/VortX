import Foundation

/// Per-tab tab-bar visibility (#117): which of the HIDEABLE tabs (Live, Discover, Library, Search) the
/// user has switched off. Home always stays (the landing anchor) and Add-ons / Settings always stay
/// (hiding Settings would leave no way to undo), so the app can never be bricked from here. Each tab
/// stores its own bool under "vortx.tabs.hide.<name>"; the platform shells (iOSRootView, RootTabView)
/// and both settings screens bind @AppStorage to these same keys, so no platform Tab type leaks into
/// shared code (the TabScrollKeys pattern).
enum TabBarPrefs {
    static let hideLive     = "vortx.tabs.hide.live"
    static let hideDiscover = "vortx.tabs.hide.discover"
    static let hideLibrary  = "vortx.tabs.hide.library"
    static let hideSearch   = "vortx.tabs.hide.search"

    /// The pre-#117 "Show Live TV tab" toggle's key, generalized into the per-tab keys above.
    static let legacyHideLiveKey = "stremiox.hideLiveTab"

    /// The one-line migration seam: seed the per-tab Live key from the legacy `stremiox.hideLiveTab`
    /// toggle the first time the new key is unset, so a user who had hidden Live keeps it hidden. The
    /// shells call this from init on every launch; once the new key exists (from this seed or the user
    /// touching the new toggle) it is a no-op. The legacy key itself is left in place so an older build
    /// sharing these defaults still honors it.
    static func migrateLegacyLiveKey() {
        let d = UserDefaults.standard
        if d.object(forKey: hideLive) == nil, d.bool(forKey: legacyHideLiveKey) {
            d.set(true, forKey: hideLive)
        }
    }
}
