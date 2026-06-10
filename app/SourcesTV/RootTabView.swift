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

/// App root, two focus rules learned the hard way:
///  - The profile picker is ROOT REPLACEMENT: while it's up, the shell does not exist. On a real
///    Siri remote the focus engine would not move into an overlay above the (even disabled) UIKit
///    tab bar, leaving the picker unselectable; as the only root content it always gets focus.
///    Nothing is lost: the picker only shows at cold start or on an explicit profile switch.
///  - The player presents OVER the live but hidden + disabled shell, so closing it returns to the
///    exact page playback started from; the player's catcher window owns the remote (TVPlayerView).
struct RootView: View {
    @EnvironmentObject private var presenter: PlayerPresenter
    @EnvironmentObject private var profiles: ProfileStore

    var body: some View {
        Group {
            if profiles.needsPicker && presenter.request == nil {
                ProfilePickerView()
            } else {
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
        // The tab bar's container can get parked far offscreen during the player's lifetime;
        // re-home it the moment playback ends so the bar is summonable immediately.
        .onChange(of: presenter.request?.id) {
            guard presenter.request == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { TabBarSummoner.healTabBar() }
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

/// An invisible focus REDIRECT strip pinned to the very top of each tab page.
///
/// The tvOS tab bar auto-hides when focus dives into content, and UIKit only summons it back when
/// focus reaches the TOP EDGE of the screen (or on Menu). Our browse layouts keep every focusable
/// element in a bottom strip, so after popping back from a detail page there was nothing up top to
/// trigger the summon: Up from the rails did nothing and the bar looked gone until a Menu press.
/// This strip hosts a UIFocusGuide, which redirects focus WITHOUT ever holding it, so one Up from
/// the rails lands on the bar with no invisible stop in between (a focusable view here cost an
/// extra press in each direction).
struct TabBarSummoner: View {
    var body: some View {
        TabBarFocusGuide()
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .allowsHitTesting(false)
    }

    /// Heal a wedged tab bar without focusing it (run when the player closes).
    static func healTabBar() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                guard let bar = firstTabBar(under: window.rootViewController) else { continue }
                healIfParked(bar)
                return
            }
        }
    }

    /// Under heavy load UIKit can park the bar's container absurdly far offscreen (seen live at
    /// y = -1288 after a player close); the focus engine refuses to summon it from there and the
    /// bar looks gone forever. Re-home it to the normal just-hidden position so the next focus
    /// pass can slide it in.
    fileprivate static func healIfParked(_ bar: UITabBar) {
        guard let container = bar.superview else { return }
        let height = max(container.frame.height, 68)
        if container.frame.origin.y < -(height * 3) {
            container.frame.origin.y = -height
            container.setNeedsLayout()
        }
    }

    fileprivate static func firstTabBar(under controller: UIViewController?) -> UITabBar? {
        guard let controller else { return nil }
        if let tabs = controller as? UITabBarController { return tabs.tabBar }
        for child in controller.children {
            if let bar = firstTabBar(under: child) { return bar }
        }
        return firstTabBar(under: controller.presentedViewController)
    }
}

/// The mechanism behind TabBarSummoner: a UIFocusGuide spanning the strip. Direction-aware by
/// being DISABLED whenever focus is already inside the bar, so pressing Down from the bar falls
/// through to the content instead of bouncing straight back up.
private struct TabBarFocusGuide: UIViewRepresentable {
    func makeUIView(context: Context) -> GuideView { GuideView() }
    func updateUIView(_ uiView: GuideView, context: Context) {}

    final class GuideView: UIView {
        private let guide = UIFocusGuide()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            if guide.owningView == nil {
                addLayoutGuide(guide)
                NSLayoutConstraint.activate([
                    guide.topAnchor.constraint(equalTo: topAnchor),
                    guide.leadingAnchor.constraint(equalTo: leadingAnchor),
                    guide.widthAnchor.constraint(equalTo: widthAnchor),
                    guide.heightAnchor.constraint(equalTo: heightAnchor),
                ])
                NotificationCenter.default.addObserver(self, selector: #selector(focusDidUpdate),
                                                       name: UIFocusSystem.didUpdateNotification,
                                                       object: nil)
            }
            retarget()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            retarget()
        }

        @objc private func focusDidUpdate() { retarget() }

        private func retarget() {
            guard let window,
                  let bar = TabBarSummoner.firstTabBar(under: window.rootViewController) else {
                guide.preferredFocusEnvironments = []
                return
            }
            TabBarSummoner.healIfParked(bar)
            let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem
            let focusInBar = (focused as? UIView).map { $0.isDescendant(of: bar) } ?? false
            guide.preferredFocusEnvironments = focusInBar ? [] : [bar]
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
