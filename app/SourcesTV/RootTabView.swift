import SwiftUI

/// A request to play something full-screen.
struct PlaybackRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var meta: PlaybackMeta? = nil
    var episodes: [Video] = []
}

/// Holds the active playback request. Set it to present the player; clear it to dismiss.
final class PlayerPresenter: ObservableObject {
    @Published var request: PlaybackRequest?
}

/// App root: shows EITHER the player OR the shell, never both. The shell is removed from the view
/// hierarchy entirely while playing, and the player's catcher locks focus on itself (see TVPlayerView),
/// so the TabView's focus map cannot steal the remote from the player.
struct RootView: View {
    @EnvironmentObject private var presenter: PlayerPresenter

    var body: some View {
        Group {
            if let req = presenter.request {
                TVPlayerView(url: req.url, title: req.title, meta: req.meta, episodes: req.episodes,
                             onClose: { presenter.request = nil })
            } else {
                RootTabView()
            }
        }
        .id(presenter.request == nil ? "shell" : "player")   // force a clean teardown on switch
    }
}

/// The app shell: Home · Discover · Library · Add-ons · Search · Settings.
///
/// Uses the native tvOS `TabView` so the top tab bar gets correct focus behaviour for free: tabs switch
/// as focus crosses them, and focus moves cleanly between the tab bar and the page content (up/down). The
/// player no longer depends on the shell being a custom bar — it locks focus on its own catcher while up,
/// so the native tab bar can't steal the remote.
struct RootTabView: View {
    @EnvironmentObject private var account: StremioAccount

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
        .tint(Theme.Palette.accent)
    }
}
