import SwiftUI
import UIKit
import os

/// A request to play something full-screen.
struct PlaybackRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var meta: PlaybackMeta? = nil
    var episodes: [CoreVideo] = []
    /// Quality signature of the stream being played, so auto-next can prefer the
    /// same release family for the following episode.
    var sourceHint: String? = nil
    /// True when the stream rides the embedded torrent engine, which needs warm-up
    /// patience the player gives it.
    var torrent: Bool = false
    /// The add-on's release-group tag for the playing stream, so auto-next can lock
    /// the next episode to the same release.
    var bingeGroup: String? = nil
    /// HTTP request headers the stream's add-on requires (behaviorHints.proxyHeaders).
    var headers: [String: String]? = nil
    /// Force the libmpv player even when the router would pick AVPlayer (the last-resort escape hatch).
    /// TVPlayerView now demotes a failed AVPlayer item to libmpv IN PLACE (`avEngineFailed`), so this is no
    /// longer needed for the common load failure; it remains for any path that wants to bypass AVPlayer
    /// routing entirely and mount libmpv directly.
    var forceMPV: Bool = false
    /// FIX I: this request plays a TRAILER clip (the {server}/yt/{id} route), not a content stream. When a
    /// trailer fails to load, the player must NOT fall back to the engine's content streams (that would
    /// substitute the actual/random movie for the dead trailer); it shows the error overlay and stops.
    var isTrailer: Bool = false
    /// #95: the YouTube id behind a trailer request (the D11 language-preferred pick when one resolved,
    /// else the meta's default id), so a dead in-app trailer can be RESCUED by handing it to the YouTube
    /// app instead of dead-ending on "Trailer unavailable". nil for a direct (non-YouTube) trailer stream
    /// whose meta carries no YouTube id, and for every content play.
    var trailerYouTubeID: String? = nil
    /// When this request plays a NATIVELY-resolved debrid link, its provenance so the play-record can store
    /// enough to reresolve a fresh link on a later Continue-Watching resume. nil for torrent/direct/trailer.
    var debridRef: DebridPlaybackRef? = nil
    /// yt-direct adaptive pair (trailers / pasted YouTube links): the separate AUDIO stream mpv mounts
    /// alongside the video-only `url` (`--audio-files`). Forces the libmpv engine in TVPlayerView.
    var audioSidecarURL: URL? = nil
    /// True when the user explicitly chose this exact source (a tapped source-list row / quality pick),
    /// false for an auto-pick (Watch Now / a Continue-Watching resume). TVPlayerView honors an explicit
    /// pick on a start-timeout (retries in place) instead of silently hopping to a lower-quality source.
    var wasExplicitPick: Bool = false
    /// True when this play is a Continue-Watching RESUME (directResume). A resume plays its exact stored source
    /// FIRST (like an explicit pick, so a slow warming link retries in place rather than hopping), but on a HARD
    /// load failure it MUST hop to a fresh source instead of dead-ending: a stored debrid link expires, and the
    /// resume's job is to get you watching. Distinct from wasExplicitPick, where a manual source-row tap dead-ends.
    var wasResume: Bool = false
    /// "Play from start" (backlog E): start this playback at 0:00 even when a saved resume position exists,
    /// WITHOUT re-running source selection. It rides the SAME source-resolution path as Watch Now / Resume
    /// (so the source is identical, per the play-from-start invariant); only the start position differs. The
    /// stored resume point is left untouched. TVPlayerView reads it to skip its engine/account resume lookup.
    var startFromZero: Bool = false
}

/// Holds the active playback request. Set it to present the player; clear it to dismiss.
final class PlayerPresenter: ObservableObject {
    @Published var request: PlaybackRequest? {
        didSet {
            if request?.torrent == true && PlaybackSettings.torrentsDisabled {
                request = nil
            }
        }
    }
}

/// App root, three focus rules learned the hard way:
///  - The shell (and its UITabBarController) is mounted ONCE and never torn down. Conditionally
///    recreating the TabView (the 0.2.9 "root replacement" picker) made UIKit initialize the tab
///    bar's auto-hide offsets against a mid-transition layout, intermittently parking the bar
///    absurdly far offscreen (observed live at y = -1288) where the focus engine cannot summon it:
///    THE vanishing tab bar bug, which did not exist while the shell was permanent (through 0.2.8).
///  - The profile picker presents as a REAL modal (fullScreenCover). UIKit moves focus into actual
///    presentations natively on a Siri remote; the hand-rolled ZStack overlay it replaces could
///    never receive focus on device. (The editor and login covers prove modal focus works here.)
///  - The player presents OVER the live but hidden + disabled shell, so closing it returns to the
///    exact page playback started from; the player's catcher window owns the remote (TVPlayerView).
struct RootView: View {
    @EnvironmentObject private var presenter: PlayerPresenter
    @EnvironmentObject private var profiles: ProfileStore
    @State private var splashDone = false

    var body: some View {
        ZStack {
            // Brand canvas behind everything, so the moment between the splash fading
            // and the profile picker animating in shows the app's own background, never
            // a flash of the main profile's Home underneath.
            Theme.Palette.canvas.ignoresSafeArea()
            RootTabView()
                .opacity(shellVisible ? 1 : 0)
                .disabled(!shellVisible)
            if let req = presenter.request {
                // #76: AVPlayer is now FIRST-CLASS under the full TVPlayerView chrome. Every request goes to
                // TVPlayerView, which picks the engine per stream in `playerSurface` (AVPlayer for HLS / Dolby
                // Vision in an AVPlayer-playable container, libmpv for torrents / MKV / everything else) and
                // demotes AVPlayer to libmpv in place on a load failure. The chrome (control bar, scrubber,
                // panels, failover) renders identically over either engine, and remote input always stays on
                // the UIKit RemoteCatcher, so AVKit never fights the Siri-remote focus engine. `forceMPV` (the
                // last-resort escape hatch) just means TVPlayerView mounts libmpv directly.
                TVPlayerView(url: req.url, title: req.title, meta: req.meta, episodes: req.episodes,
                             sourceHint: req.sourceHint, torrent: req.torrent, bingeGroup: req.bingeGroup,
                             headers: req.headers, forceMPV: req.forceMPV, isTrailer: req.isTrailer,
                             trailerYouTubeID: req.trailerYouTubeID,
                             audioSidecarURL: req.audioSidecarURL, debridRef: req.debridRef,
                             startedFromExplicitPick: req.wasExplicitPick, startedFromResume: req.wasResume,
                             startFromZero: req.startFromZero,
                             onClose: { presenter.request = nil })
                    .id(req.id)   // clean player teardown per request
            }
            // The launch splash sits above everything for its ~2 seconds. It has no
            // focusable content, so the focus engine settles on the shell underneath
            // and nothing fights it; the profile picker waits for it (binding below).
            if !splashDone {
                SplashView { splashDone = true }
                    .zIndex(10)
            }
        }
        .fullScreenCover(isPresented: pickerPresented) { ProfilePickerView() }
        // Re-sync the bar's visibility after playback ends: two shots, because the desync can
        // assert itself after the first layout settles.
        .onChange(of: presenter.request?.id) {
            guard presenter.request == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { TabBarHealer.heal("player-closed") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { TabBarHealer.heal("player-closed+3s") }
        }
        // The picker dismissing (or a profile switch settling) makes the shell visible again; re-assert
        // the bar in case it desynced while hidden, so the menu is never missing on return (issue #75).
        .onChange(of: profiles.needsPicker) {
            guard !profiles.needsPicker, presenter.request == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { TabBarHealer.heal("picker-dismissed") }
        }
    }

    /// Cold start with a real choice, or Settings' "Switch Profile". Dismissing with Menu counts
    /// as picking the current profile, so the binding's setter just marks the launch as picked.
    /// Home stays hidden until a profile is settled: while the picker is owed (more
    /// than one profile, none chosen this launch) the shell is invisible, so nothing
    /// of the main profile leaks out before the picker arrives.
    private var shellVisible: Bool {
        presenter.request == nil && !profiles.needsPicker
    }

    private var pickerPresented: Binding<Bool> {
        Binding(
            get: { splashDone && profiles.needsPicker && presenter.request == nil },
            set: { presented in if !presented { profiles.pickedThisLaunch = true } }
        )
    }
}

/// The app shell: Home · Discover · Library · Add-ons · Search · Settings.
///
/// Uses the native tvOS `TabView` so the top tab bar gets correct focus behaviour for free: tabs switch
/// as focus crosses them, and focus moves cleanly between the tab bar and the page content (up/down). The
/// player no longer depends on the shell being a custom bar, it locks focus on its own catcher while up,
/// so the native tab bar can't steal the remote.
struct RootTabView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var selection = 0
    // Per-tab identity token. Each tab owns its own NavigationStack whose pushed pages persist
    // while the tab stays alive (tvOS keeps tabs mounted). Bumping the token of the tab you LEAVE
    // changes that tab's view identity, so the next time you open it SwiftUI rebuilds it fresh at
    // its root instead of re-showing the detail page you had pushed (the "Search still shows the
    // series I opened" bug). Cheap because the data lives in CoreBridge, not in the view.
    @State private var resetTokens = [Int](repeating: 0, count: 7)
    /// Per-tab bar visibility (#117): hide Live / Discover / Library / Search from the bar (Settings >
    /// Tab bar). Home, Add-ons, and Settings are not hideable, so the shell always keeps its landing
    /// anchor and the way back to this setting. Live's value is seeded from the legacy
    /// stremiox.hideLiveTab toggle in init; selection heals to Home whenever the active tab is hidden
    /// (the onChange observers below), so the TabView never points at a tag that no longer exists.
    @AppStorage(TabBarPrefs.hideLive) private var hideLiveTab = false
    @AppStorage(TabBarPrefs.hideDiscover) private var hideDiscoverTab = false
    @AppStorage(TabBarPrefs.hideLibrary) private var hideLibraryTab = false
    @AppStorage(TabBarPrefs.hideSearch) private var hideSearchTab = false
    /// Live connectivity (#120): drives the quiet "You're offline" chip and the one-shot offline
    /// launch routing below. The monitor debounces changes, so a brief flap never thrashes the shell.
    @ObservedObject private var connectivity = ConnectivityMonitor.shared
    /// One-shot latch for the offline LAUNCH routing (#120): set when the monitor's first verdict is
    /// consumed, so no later connectivity change can ever move tabs (mid-session offline = chip only).
    @State private var offlineLaunchRouted = false

    /// Seed the per-tab Live key from the legacy toggle before the first @AppStorage read, so a user
    /// who had hidden Live keeps it hidden across the #117 generalization.
    init() {
        TabBarPrefs.migrateLegacyLiveKey()
    }

    /// The tvOS scroll-to-top key for a tab tag, matching the `TabScrollKeys` the screens observe.
    /// tvOS `TabView` selection uses integer tags; only Home / Discover / Library carry a scrollable
    /// hero screen wired for scroll-to-top. Search / Add-ons / Settings are lists or their own
    /// containers, and Live (tag 6) is an EPG grid, so they are intentionally omitted here (returning
    /// nil means a re-select is a plain no-op, not a bump nobody observes).
    private func scrollKey(for tag: Int) -> String? {
        switch tag {
        case 0: return TabScrollKeys.home
        case 1: return TabScrollKeys.discover
        case 2: return TabScrollKeys.library
        default: return nil
        }
    }

    /// Human-readable name for a tab tag, used for VXProbe route/nav probes. Matches the tab tags
    /// (Live 6, Search 4, Add-ons 3, Settings 5) so a diagnostic log names the screen the user is on.
    static func tabName(_ tag: Int) -> String {
        switch tag {
        case 0: return "Home"
        case 1: return "Discover"
        case 2: return "Library"
        case 3: return "Add-ons"
        case 4: return "Search"
        case 5: return "Settings"
        case 6: return "Live"
        default: return "tab\(tag)"
        }
    }

    /// Selection binding that turns a re-select of the ALREADY-active tab into a scroll-to-top signal.
    /// tvOS `TabView` calls this setter when the user activates a tab item; when the new value equals the
    /// current selection (re-tapping the active tab) we bump that tab's token instead of a no-op set, so
    /// the mounted screen scrolls to its top. A genuine tab switch sets `selection` as before.
    private var selectionBinding: Binding<Int> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == selection, let key = scrollKey(for: newValue) {
                    TabScrollToTop.shared.bump(key)
                } else {
                    selection = newValue
                }
            }
        )
    }

    var body: some View {
        TabView(selection: selectionBinding) {
            HomeView().id(resetTokens[0])
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            // Discover / Live / Library / Search are the hideable tabs (#117): each drops out of the
            // TabView entirely when its Settings > Tab bar toggle hides it, and the matching .onChange
            // below heals the selection to Home so the TabView never points at a missing tag.
            if !hideDiscoverTab {
                DiscoverView().id(resetTokens[1])
                    .tabItem { Label("Discover", systemImage: "safari.fill") }.tag(1)
            }
            // Live TV sits after Discover. Tags 0–5 were already taken (Search uses 4, Add-ons 3),
            // so Live takes the next free tag 6 and reset slot 6 — the selection-reset .onChange
            // below stays in bounds against the resized 7-slot array.
            if !hideLiveTab {
                LiveView().id(resetTokens[6])
                    .tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }.tag(6)
            }
            if !hideLibraryTab {
                LibraryView().id(resetTokens[2])
                    .tabItem { Label("Library", systemImage: "books.vertical.fill") }.tag(2)
            }
            if !hideSearchTab {
                NavigationStack { SearchView() }.id(resetTokens[4])
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(4)
            }
            AddonsView().id(resetTokens[3])
                .tabItem { Label("Add-ons", systemImage: "puzzlepiece.extension.fill") }.tag(3)
            SettingsView().id(resetTokens[5])
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(5)
        }
        .tint(theme.accent)
        // Offline chip (#120): a quiet bottom capsule while the device has no network path. Pure
        // signal (never focusable, never navigates); it clears on its own when connectivity returns,
        // and online tabs stay reachable for cached browsing.
        // STRUCTURE-DEPENDENT: the chip hides with the shell only because it lives INSIDE
        // RootTabView, which RootView wraps in the shell-opacity gate (shellVisible); hoisting it to
        // RootView's ZStack would strand a visible chip over the profile picker / player.
        .overlay(alignment: .bottom) { offlineBanner }
        .animation(.easeOut(duration: 0.25), value: connectivity.isOffline)
        // Offline-at-LAUNCH routing (#120): the monitor's FIRST verdict (and only that one) may move
        // the initial selection off Home to the Library tab, where the Downloads section
        // (TVDownloadsView) lives, so an Apple TV opened with no connection lands on something usable.
        // Strictly one-shot and pre-navigation: the latch consumes the verdict, and the
        // `selection == 0` guard skips the redirect if the user already moved on their own (a late
        // first verdict must never yank navigation). Going offline MID-SESSION only shows the chip.
        .onReceive(connectivity.$launchOffline) { verdict in
            guard let verdict, !offlineLaunchRouted else { return }
            offlineLaunchRouted = true
            // Never route to a hidden tab (#117 x #120): a user who hid Library keeps the offline
            // chip but stays on Home, the same fallback every other healer uses.
            guard verdict, selection == 0, !hideLibraryTab else { return }
            selection = 2   // Library (tag 2): Downloads section + the cached library grid
        }
        // Back/Menu floor, depth-aware. SwiftUI routes the exit command to the NEAREST .onExitCommand in the
        // focused view's ancestry BEFORE UIKit's default NavigationStack pop, so this shell-level handler
        // fires from ANY push depth on a non-Home tab (55ceff8 assumed pushed pages kept a deeper Menu
        // responder; none exists, and the system pop never outranks a SwiftUI handler). When the active
        // tab's stack has a page pushed, pop exactly one level (the same UINavigationController pop the
        // system default performs on the Home tab, where this handler is nil); only at the tab's ROOT does
        // Menu route to Home (the Beta-10 floor; the .onChange below then resets the tab we left). Home
        // keeps nil so Menu at the Home root still suspends to tvOS.
        .onExitCommand(perform: selection == 0 ? nil : {
            if let nav = focusedNavigationController(), nav.viewControllers.count > 1 {
                nav.popViewController(animated: true)
            } else {
                selection = 0
            }
        })
        // Automatic update popup on the shell (never over the player, which replaces this view). Appears once
        // per launch when a newer build exists, and again when the hourly re-check finds a still-newer one.
        .sheet(item: $updates.prompt) { release in
            UpdatePromptView(release: release) { updates.dismissPrompt() }
        }
        .onAppear {
            applyTabBarAccent()
            updates.startMonitoring()   // launch check + hourly re-check while open
            let name = Self.tabName(selection)
            VXProbeState.shared.setRoute(name)
            VXProbe.event("nav", "tab \(name)")
        }
        // Reset the tab being LEFT to its root, so returning to it lands on the root page.
        .onChange(of: selection) { old, new in
            if old >= 0, old < resetTokens.count { resetTokens[old] += 1 }
            let name = Self.tabName(new)
            VXProbeState.shared.setRoute(name)
            VXProbe.event("nav", "tab \(name)")
        }
        // If a hideable tab is hidden while it was the selected one (Settings toggle, or synced from
        // another device), fall back to Home so the TabView never points at a tag that no longer exists
        // (the TabBarHealer-adjacent selection heal, one observer per hideable tab).
        .onChange(of: hideLiveTab) { _, hidden in
            if hidden, selection == 6 { selection = 0 }
        }
        .onChange(of: hideDiscoverTab) { _, hidden in
            if hidden, selection == 1 { selection = 0 }
        }
        .onChange(of: hideLibraryTab) { _, hidden in
            if hidden, selection == 2 { selection = 0 }
        }
        .onChange(of: hideSearchTab) { _, hidden in
            if hidden, selection == 4 { selection = 0 }
        }
        // The active profile owns the theme: mirror Settings changes into it so they survive a switch.
        .onChange(of: theme.accentID) { applyTabBarAccent(); ProfileStore.shared.captureTheme() }
        .onChange(of: theme.oled) { applyTabBarAccent(); ProfileStore.shared.captureTheme() }
        .onChange(of: theme.textScale) { ProfileStore.shared.captureTheme() }
    }

    /// Quiet, persistent "You're offline" chip (#120), pinned to the bottom of the shell while the
    /// device has no network path. A subdued surface capsule, not an alert: it says the app knows,
    /// points at what still works (Downloads in Library), and clears on its own when connectivity
    /// returns (the monitor's debounced signal, so a brief flap never flashes it). Hit-testing is off
    /// so the focus engine never sees it; the remote keeps driving the tabs and content beneath.
    @ViewBuilder private var offlineBanner: some View {
        if connectivity.isOffline {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 22, weight: .semibold))
                Text("You're offline. Downloads in your Library still play.")
                    .font(Theme.Typography.label)
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.Palette.surface1.opacity(0.92), in: Capsule())
            .overlay(Capsule().stroke(Theme.Palette.hairline, lineWidth: 1))
            .padding(.bottom, Theme.Space.lg)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The UIKit navigation controller backing the ACTIVE tab's `NavigationStack`, resolved from the
    /// focused item's responder chain (SwiftUI's NavigationStack is UINavigationController-backed on
    /// tvOS). Focus always lives inside the visible tab, so a dormant tab's stack can never resolve.
    /// Returns nil when the focused item is not inside a navigation controller (tab bar focused,
    /// mid-transition, or a future OS changing internals); the caller treats nil as "at root", so the
    /// worst case is the old go-Home behavior, never a crash or a dead Menu press.
    private func focusedNavigationController() -> UINavigationController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return nil }
        // The focused item can be a non-view SwiftUI focus proxy: climb the focus-environment chain to
        // the first real UIView / UIViewController, then walk the responder chain to the enclosing stack.
        var environment: (any UIFocusEnvironment)? = UIFocusSystem.focusSystem(for: window)?.focusedItem
        var responder: UIResponder?
        while let env = environment {
            if let view = env as? UIView { responder = view; break }
            if let vc = env as? UIViewController { responder = vc; break }
            environment = env.parentFocusEnvironment
        }
        while let r = responder {
            if let nav = r as? UINavigationController { return nav }
            if let vc = r as? UIViewController, let nav = vc.navigationController { return nav }
            responder = r.next
        }
        return nil
    }

    /// The focused / selected tab pill is system white by default; recolor it to the active accent
    /// with dark on-accent ink, and push the appearance onto any live tab bars so an accent change
    /// repaints without a relaunch.
    private func applyTabBarAccent() {
        let item = UITabBarItemAppearance()
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(Theme.Palette.textSecondary)]
        item.normal.iconColor = UIColor(Theme.Palette.textSecondary)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(Theme.Palette.onAccent)]
        item.selected.iconColor = UIColor(Theme.Palette.onAccent)
        item.focused.titleTextAttributes = [.foregroundColor: UIColor(Theme.Palette.onAccent)]
        item.focused.iconColor = UIColor(Theme.Palette.onAccent)
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.selectionIndicatorTintColor = UIColor(Theme.Palette.accent)
        appearance.inlineLayoutAppearance = item
        appearance.stackedLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { retintTabBars(under: window.rootViewController, with: appearance) }
        }
    }

    private func retintTabBars(under controller: UIViewController?, with appearance: UITabBarAppearance) {
        guard let controller else { return }
        if let tabs = controller as? UITabBarController {
            tabs.tabBar.standardAppearance = appearance
            tabs.tabBar.scrollEdgeAppearance = appearance
            tabs.tabBar.setNeedsLayout()
        }
        controller.children.forEach { retintTabBars(under: $0, with: appearance) }
        retintTabBars(under: controller.presentedViewController, with: appearance)
    }
}

/// Re-sync the tab bar's visibility after something full-screen (the player, the system keyboard)
/// takes focus and gives it back. Symptom caught live: focus could sit ON the bar's pills (Right
/// switched tabs) while the bar itself stayed invisible, its container parked offscreen, until a
/// tab change forced a real layout pass. The heal uses the SUPPORTED visibility API (frame surgery
/// on the private container gets stomped by the next layout pass) and logs what it saw, so a
/// failed heal explains itself in the log.
enum TabBarHealer {
    private static let log = Logger(subsystem: "com.stremiox.app", category: "tabbar")

    static func heal(_ reason: String) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                guard let tabs = firstTabBarController(under: window.rootViewController) else { continue }
                let bar = tabs.tabBar
                let container = bar.superview
                let containerY = container?.frame.origin.y ?? .nan
                if #available(tvOS 18.0, *) {
                    log.info("heal(\(reason, privacy: .public)): containerY=\(containerY, privacy: .public) barHidden=\(bar.isHidden) controllerHidden=\(tabs.isTabBarHidden)")
                    if tabs.isTabBarHidden {
                        tabs.setTabBarHidden(false, animated: false)
                        log.info("heal: setTabBarHidden(false) applied")
                    }
                } else {
                    log.info("heal(\(reason, privacy: .public)): containerY=\(containerY, privacy: .public) barHidden=\(bar.isHidden)")
                }
                // Re-home a parked container as well; harmless if the layout pass recomputes it.
                if let container, container.frame.origin.y < -(max(container.frame.height, 68) * 3) {
                    container.frame.origin.y = -max(container.frame.height, 68)
                    log.info("heal: re-homed parked container")
                }
                tabs.view.setNeedsLayout()
                tabs.view.layoutIfNeeded()
                return
            }
        }
        log.info("heal(\(reason, privacy: .public)): no tab bar controller found")
    }

    private static func firstTabBarController(under controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let tabs = firstTabBarController(under: child) { return tabs }
        }
        return firstTabBarController(under: controller.presentedViewController)
    }
}
