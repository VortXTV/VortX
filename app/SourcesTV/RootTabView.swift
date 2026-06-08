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

/// App root: shows EITHER the player OR the shell, never both. This is the only thing that reliably
/// isolates focus on tvOS — the shell is removed from the view hierarchy entirely while playing, so the
/// focus engine cannot traverse to it and steal directional presses from the player.
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
/// IMPORTANT: this is a CUSTOM tab bar (focusable buttons), NOT SwiftUI's `TabView`. SwiftUI's `TabView`
/// is backed by a `UITabBarController` that it does not deallocate on conditional removal, so it lingers
/// in the tvOS focus map and steals the remote from the player (confirmed: covers, overlays, `.disabled`,
/// hidden windows, conditional render, and `.id()` teardown all failed; only never creating it works).
/// Plain SwiftUI buttons tear down cleanly, so `RootView`'s root-replacement genuinely removes the shell
/// from focus while the player is up.
struct RootTabView: View {
    @EnvironmentObject private var account: StremioAccount
    @State private var tab = 0

    private static let tabs: [(title: String, icon: String)] = [
        ("Home", "house.fill"),
        ("Discover", "safari.fill"),
        ("Library", "books.vertical.fill"),
        ("Add-ons", "puzzlepiece.extension.fill"),
        ("Search", "magnifyingglass"),
        ("Settings", "gearshape.fill"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(Array(Self.tabs.enumerated()), id: \.offset) { index, item in
                    Button { tab = index } label: {
                        Label(item.title, systemImage: item.icon)
                            .labelStyle(.titleAndIcon)
                            .font(Theme.Typography.label)
                    }
                    .buttonStyle(TabBarButtonStyle(selected: tab == index))
                }
            }
            .focusSection()
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.md)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case 0: HomeView()
        case 1: DiscoverView()
        case 2: LibraryView()
        case 3: AddonsView()
        case 4: NavigationStack { SearchView() }
        default: SettingsView()
        }
    }
}

/// Tab-bar chip: ember fill when selected, brighter + lifted when focused.
private struct TabBarButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isFocused) private var focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm)
            .foregroundStyle(selected || focused ? Theme.Palette.canvas : Theme.Palette.textSecondary)
            .background(
                Capsule().fill(focused ? Theme.Palette.accent
                                       : (selected ? Theme.Palette.accent.opacity(0.85) : Color.clear))
            )
            .scaleEffect(focused ? 1.06 : 1.0)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
