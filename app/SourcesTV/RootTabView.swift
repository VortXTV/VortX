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

/// Native AVPlayer route for an adaptive-HLS stream on tvOS, presented INSTEAD of the libmpv TVPlayerView
/// so the RemoteCatcher's focus-lock never competes with AVPlayerViewController for the Siri remote. It
/// reuses the same engine plumbing TVPlayerView uses: it resolves the resume point from the engine (or the
/// account fallback) before showing the player, and reports progress back so Continue Watching stays in
/// sync. Leaving is the tvOS Menu press (HLSPlayerView's onExitCommand).
private struct TVHLSPlayer: View {
    let request: PlaybackRequest
    let onClose: () -> Void
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @State private var resumeSeconds: Double = 0
    @State private var ready = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if ready {
                HLSPlayerView(
                    url: request.url, title: request.title, headers: request.headers, resumeSeconds: resumeSeconds,
                    onProgress: { pos, dur in
                        guard let m = request.meta else { return }
                        core.reportProgress(timeSeconds: pos, durationSeconds: dur)
                        Task { [weak account] in await account?.saveProgress(for: m, positionSeconds: pos, durationSeconds: dur) }
                    },
                    onClose: onClose)
            }
        }
        .task {
            if let m = request.meta {
                if let engine = core.engineResumeSeconds(for: m) { resumeSeconds = engine }
                else { resumeSeconds = await account.resumeOffset(for: m) }
            }
            ready = true   // resume resolved (or no meta) -> mount the player so it seeks to the right spot
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
                if !req.torrent,
                   PlayerEngineRouter.engine(for: req.url, isTorrent: req.torrent,
                                             isDolbyVision: StreamRanking.isDolbyVision(req.sourceHint ?? "")) == .avfoundation {
                    // AVPlayer-routed: adaptive HLS (true ABR vs libmpv locking one rendition) OR a Dolby
                    // Vision stream in an MP4/MOV container (true DV passthrough on a DV TV; libmpv/MoltenVK
                    // only tone-maps DV to SDR). Plays in the bare AVPlayerViewController, BYPASSING
                    // TVPlayerView so the RemoteCatcher's focus-lock never fights AVKit for the Siri remote.
                    TVHLSPlayer(request: req, onClose: { presenter.request = nil })
                        .id(req.id)
                } else {
                    TVPlayerView(url: req.url, title: req.title, meta: req.meta, episodes: req.episodes,
                                 sourceHint: req.sourceHint, torrent: req.torrent, bingeGroup: req.bingeGroup,
                                 headers: req.headers,
                                 onClose: { presenter.request = nil })
                        .id(req.id)   // clean player teardown per request
                }
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

    var body: some View {
        TabView(selection: $selection) {
            HomeView().id(resetTokens[0])
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            DiscoverView().id(resetTokens[1])
                .tabItem { Label("Discover", systemImage: "safari.fill") }.tag(1)
            // Live TV sits after Discover. Tags 0–5 were already taken (Search uses 4, Add-ons 3),
            // so Live takes the next free tag 6 and reset slot 6 — the selection-reset .onChange
            // below stays in bounds against the resized 7-slot array.
            LiveView().id(resetTokens[6])
                .tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }.tag(6)
            LibraryView().id(resetTokens[2])
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }.tag(2)
            NavigationStack { SearchView() }.id(resetTokens[4])
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(4)
            AddonsView().id(resetTokens[3])
                .tabItem { Label("Add-ons", systemImage: "puzzlepiece.extension.fill") }.tag(3)
            SettingsView().id(resetTokens[5])
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(5)
        }
        .tint(theme.accent)
        // Automatic update popup on the shell (never over the player, which replaces this view). Appears once
        // per launch when a newer build exists, and again when the hourly re-check finds a still-newer one.
        .sheet(item: $updates.prompt) { release in
            UpdatePromptView(release: release) { updates.dismissPrompt() }
        }
        .onAppear {
            applyTabBarAccent()
            updates.startMonitoring()   // launch check + hourly re-check while open
        }
        // Reset the tab being LEFT to its root, so returning to it lands on the root page.
        .onChange(of: selection) { old, _ in
            if old >= 0, old < resetTokens.count { resetTokens[old] += 1 }
        }
        // The active profile owns the theme: mirror Settings changes into it so they survive a switch.
        .onChange(of: theme.accentID) { applyTabBarAccent(); ProfileStore.shared.captureTheme() }
        .onChange(of: theme.oled) { applyTabBarAccent(); ProfileStore.shared.captureTheme() }
        .onChange(of: theme.textScale) { ProfileStore.shared.captureTheme() }
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
