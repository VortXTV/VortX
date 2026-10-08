import SwiftUI

#if DEBUG
/// Offline visual smoke surface for the Cinema shell.  It deliberately renders production presentation
/// components with local, fixed values: it does not construct app state, accounts, a player, or a
/// detail/episode owner.  Open `CinemaUISmokeHarness` from a Debug-only host or Preview to inspect the
/// same shelf, search card, episode card, and source label geometry at representative window widths.
@MainActor
struct CinemaUISmokeHarness: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: Theme.Space.lg) {
                CinemaUISmokeFixtureRoot(name: "Phone", width: 390, height: 844)
                CinemaUISmokeFixtureRoot(name: "Tablet", width: 834, height: 1112)
                CinemaUISmokeFixtureRoot(name: "Mac", width: 1280, height: 800)
            }
            .padding(Theme.Space.md)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .accessibilityLabel("Cinema UI smoke harness")
    }
}

/// The reusable root also gives the command-line renderer a single, side-effect-free production-view tree.
struct CinemaUISmokeFixtureRoot: View {
    let name: String
    let width: CGFloat
    let height: CGFloat
    var surface: CinemaUISmokeSurface = .home

    var body: some View {
        VStack(spacing: 0) {
            Text("\(name) · \(surface.title)")
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.sm)
                .vortxGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous), shadow: .flat)
            CinemaUISmokeSurfaceContent(surface: surface)
        }
        .frame(width: width, height: height)
        .background(Theme.Palette.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .stroke(Theme.Palette.hairline, lineWidth: 1))
        .safeAreaInset(edge: .bottom, spacing: 0) { CinemaUISmokeTabBar() }
        .environmentObject(ThemeManager.shared)
        .environment(\.cinemaFixtureDisablesArtworkLoading, true)
        .accessibilityLabel("\(name) \(surface.title) Cinema viewport")
    }
}

enum CinemaUISmokeSurface: String, CaseIterable {
    case home, search, quickView, episodeSources

    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .quickView: "Detail"
        case .episodeSources: "Episode sources"
        }
    }

    var artifactPrefix: String {
        switch self {
        case .home: ""
        default: "\(rawValue)-"
        }
    }
}

private struct CinemaUISmokeSurfaceContent: View {
    let surface: CinemaUISmokeSurface

    var body: some View {
        switch surface {
        case .home:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                    CinemaFixturePosterRail(
                        title: "Continue Watching",
                        eyebrow: "Pick up where you left off",
                        items: CinemaUISmokeFixtures.continueWatching,
                        continueWatching: true
                    )
                    CinemaFixturePosterRail(
                        title: "Featured Movies",
                        eyebrow: "Catalog",
                        items: CinemaUISmokeFixtures.catalog,
                        includesSeeAll: true
                    )
                }
                .padding(.vertical, Theme.Space.md)
            }
        case .search:
            ScrollView {
                CinemaSearchResults(items: CinemaUISmokeFixtures.search, onOpen: { _ in })
                    .padding(.vertical, Theme.Space.md)
            }
        case .quickView:
            CinemaQuickView(item: CinemaUISmokeFixtures.search[0], onWatch: {}, onDetails: {})
        case .episodeSources:
            ScrollView {
                CinemaUISmokeDetailSection()
                    .padding(.vertical, Theme.Space.md)
            }
        }
    }
}

private struct CinemaUISmokeTabBar: View {
    @State private var selected = "Home"
    private let tabs = [
        ("Home", "house.fill"), ("Discover", "safari"), ("Library", "books.vertical"), ("Search", "magnifyingglass")
    ]

    var body: some View {
        CinemaTabBarChrome {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.0) { tab in
                    Button { selected = tab.0 } label: {
                        CinemaCompactTabLabel(title: tab.0, icon: tab.1, selected: selected == tab.0,
                                              downloadBadge: tab.0 == "Library" ? 2 : nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.0)
                    .accessibilityHint("Switches the fixture to \(tab.0)")
                }
            }
        }
    }
}

private struct CinemaUISmokeDetailSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            iOSRailHeader(eyebrow: "Episode detail", title: "The Signal")
                .padding(.horizontal, Theme.Space.md)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.md) {
                    CinemaEpisodeRailCard(
                        video: CinemaUISmokeFixtures.episode,
                        isWatched: false,
                        progress: 0.42,
                        cardWidth: 340,
                        artwork: AnyView(CinemaUISmokeArtwork()),
                        trailingStatus: AnyView(EmptyView())
                    )
                }
                .padding(.horizontal, Theme.Space.md)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                iOSRailHeader(eyebrow: "2 sources", title: "Sources")
                ForEach(CinemaUISmokeFixtures.sources, id: \.id) { source in
                    iOSStreamLabel(addon: "Fixture Add-on", stream: source, enabled: true)
                        .vortxGlassListRow(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
            }
            .padding(.horizontal, Theme.Space.md)
        }
    }
}

private struct CinemaUISmokeArtwork: View {
    var body: some View {
        LinearGradient(colors: [Theme.Palette.surface3, Theme.Palette.surface1],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "play.rectangle.fill")
                .font(.system(size: 34)).foregroundStyle(Theme.Palette.textTertiary))
            .frame(width: 300, height: 169)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .accessibilityHidden(true)
    }
}

private enum CinemaUISmokeFixtures {
    static let continueWatching = [
        rail("cw-1", "Harbor Lights", type: "series", progress: 0.62, caption: "S2 · E4", release: "2026", rating: "8.4"),
        rail("cw-2", "Northbound", type: "movie", progress: 0.31, release: "2h 04m · 2025", rating: "7.9")
    ]
    static let catalog = [
        rail("catalog-1", "The Long Winter", type: "movie", release: "1h 54m · 2026", rating: "8.1"),
        rail("catalog-2", "Arcadia", type: "series", release: "3 seasons · 24 episodes", rating: "8.6"),
        rail("catalog-3", "After the Tide", type: "movie", release: "2h 12m · 2024", rating: "7.7"),
        rail("catalog-4", "Stone & Sky", type: "series", release: "2 seasons · 16 episodes", rating: "8.0")
    ]
    static let search = [
        rail("search-1", "Silent City", type: "movie", release: "1h 48m · 2026", rating: "8.3", description: "A detective returns to a city that has forgotten how to sleep."),
        rail("search-2", "Halcyon", type: "series", release: "2 seasons · 18 episodes · 2025", rating: "8.0", description: "A stranded crew follows a signal through deep space.")
    ]
    static let episode: CoreVideo = decode("""
    {"id":"fixture:series:1:4","title":"The Long Way Home","released":"2026-09-18","overview":"A recovered transmission changes the crew's route home.","season":1,"episode":4}
    """)
    static let sources: [CoreStream] = [
        decode("{\"url\":\"https://fixture.invalid/stream-1.m3u8\",\"name\":\"1080p HDR · Fixture release\",\"description\":\"Direct · English · 4.2 GB\"}"),
        decode("{\"url\":\"https://fixture.invalid/stream-2.m3u8\",\"name\":\"4K Dolby Vision · Fixture release\",\"description\":\"Direct · English · 11.8 GB\"}")
    ]

    private static func rail(_ id: String, _ name: String, type: String, progress: Double = 0,
                             caption: String? = nil, release: String? = nil, rating: String? = nil,
                             description: String? = nil) -> RailItem {
        RailItem(id: id, type: type, name: name, poster: nil, progress: progress, background: nil,
                 description: description, releaseInfo: release, imdbRating: rating, genres: nil,
                 cwVideoId: progress > 0 ? "fixture-video-\(id)" : nil, caption: caption,
                 resumeSeconds: progress > 0 ? 1_122 : nil)
    }

    private static func decode<T: Decodable>(_ json: String) -> T {
        // Fixture literals are compile-time owned and are deliberately decoded rather than sourced from an
        // account/add-on, preserving the app models without introducing a second model surface.
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}

#Preview("Cinema UI Smoke · offline") {
    CinemaUISmokeHarness()
}
#endif
