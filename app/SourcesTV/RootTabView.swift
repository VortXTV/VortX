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
}

/// Holds the active playback request. Set it to present the player; clear it to dismiss.
final class PlayerPresenter: ObservableObject {
    @Published var request: PlaybackRequest?
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

    var body: some View {
        ZStack {
            RootTabView()
                .opacity(presenter.request == nil ? 1 : 0)
                .disabled(presenter.request != nil)
            if let req = presenter.request {
                TVPlayerView(url: req.url, title: req.title, meta: req.meta, episodes: req.episodes,
                             onClose: { presenter.request = nil })
                    .id(req.id)   // clean player teardown per request
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
    }

    /// Cold start with a real choice, or Settings' "Switch Profile". Dismissing with Menu counts
    /// as picking the current profile, so the binding's setter just marks the launch as picked.
    private var pickerPresented: Binding<Bool> {
        Binding(
            get: { profiles.needsPicker && presenter.request == nil },
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

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "safari.fill") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            AddonsView()
                .tabItem { Label("Add-ons", systemImage: "puzzlepiece.extension.fill") }
            NavigationStack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(theme.accent)
        .onAppear { applyTabBarAccent() }
        // The active profile owns the theme: mirror Settings changes into it so they survive a switch.
        .onChange(of: theme.accentID) { applyTabBarAccent(); ProfileStore.shared.captureTheme() }
        .onChange(of: theme.oled) { applyTabBarAccent(); ProfileStore.shared.captureTheme() }
    }

    /// The focused tab's pill is system white by default; recolor it to the active accent (with the
    /// dark on-accent ink for the focused label) via UITabBarAppearance, and push the appearance onto
    /// any live tab bars so an accent change repaints without a relaunch.
    private func applyTabBarAccent() {
        let item = UITabBarItemAppearance()
        item.focused.titleTextAttributes = [.foregroundColor: UIColor(Theme.Palette.onAccent)]
        item.focused.iconColor = UIColor(Theme.Palette.onAccent)
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.selectionIndicatorTintColor = UIColor(Theme.Palette.accent)
        appearance.inlineLayoutAppearance = item
        appearance.stackedLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = appearance
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { retintTabBars(under: window.rootViewController, with: appearance) }
        }
    }

    private func retintTabBars(under controller: UIViewController?, with appearance: UITabBarAppearance) {
        guard let controller else { return }
        if let tabs = controller as? UITabBarController {
            tabs.tabBar.standardAppearance = appearance
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
