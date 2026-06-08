import SwiftUI

/// A request to play something full-screen. Presented as a root-level overlay (NOT `.fullScreenCover`,
/// which does not isolate the focus environment on tvOS, so the focus engine walks focus out to the tab
/// bar behind it and the player stops receiving the remote).
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

/// The app shell: Home · Discover · Library · Add-ons · Search · Settings. The player is a root-level
/// overlay above the tab bar; while it is up the tab bar is `.disabled`, which removes it from the tvOS
/// focus map so it cannot steal the remote from the player.
struct RootTabView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var presenter: PlayerPresenter

    var body: some View {
        ZStack {
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
            .disabled(presenter.request != nil)   // take the shell out of the focus map while playing

            if let req = presenter.request {
                TVPlayerView(url: req.url, title: req.title, meta: req.meta, episodes: req.episodes)
                    .id(req.id)
                    .ignoresSafeArea()
                    .zIndex(1)
                    .transition(.opacity)
            }
        }
    }
}
