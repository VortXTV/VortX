import SwiftUI
import UIKit

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

/// App root: the player presents OVER the shell, which stays alive hidden + disabled, so closing
/// the player returns to the exact page playback started from (episode list, detail, search…)
/// instead of a rebuilt Home. Disabled views are unfocusable and the player's catcher window owns
/// the remote (see TVPlayerView), so the TabView still can't steal a single press.
struct RootView: View {
    @EnvironmentObject private var presenter: PlayerPresenter

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
        .onChange(of: theme.accentID) { applyTabBarAccent() }
        .onChange(of: theme.oled) { applyTabBarAccent() }
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
