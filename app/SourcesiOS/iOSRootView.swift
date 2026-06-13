import SwiftUI

/// Native iOS root: a CUSTOM bottom-tab shell over the shared engine. A native `TabView` collapses
/// the 5th+ tabs into a system "More" tab on iPhone, burying Add-ons and Settings; instead we drive
/// the visible screen with a `@State` selection and render our own brand-styled bar so all SIX tabs
/// stay visible at once (matching the tvOS pill bar). Surfaces are filled in one at a time during the
/// 0.3.0 rebase; Home is the first real one (poster rails from CoreBridge).
struct iOSRootView: View {
    /// The six destinations, in display order: Home · Discover · Library · Search · Add-ons · Settings
    /// (Add-ons sits beside Settings, mirroring tvOS).
    private enum Tab: Int, CaseIterable {
        case home, discover, library, search, addons, settings

        var title: String {
            switch self {
            case .home: return "Home"
            case .discover: return "Discover"
            case .library: return "Library"
            case .search: return "Search"
            case .addons: return "Add-ons"
            case .settings: return "Settings"
            }
        }

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .discover: return "safari.fill"
            case .library: return "books.vertical.fill"
            case .search: return "magnifyingglass"
            case .addons: return "puzzlepiece.extension.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    @State private var tab: Tab = .home

    var body: some View {
        VStack(spacing: 0) {
            // Selected screen fills the space above the bar. We keep all six in a ZStack so each
            // screen's own state (scroll position, search query, engine subscriptions) survives a
            // tab switch instead of being torn down and rebuilt every time.
            ZStack {
                iOSHomeView().opacity(tab == .home ? 1 : 0)
                iOSDiscoverView().opacity(tab == .discover ? 1 : 0)
                iOSLibraryView().opacity(tab == .library ? 1 : 0)
                iOSSearchView().opacity(tab == .search ? 1 : 0)
                AddonsView().opacity(tab == .addons ? 1 : 0)
                iOSSettingsView().opacity(tab == .settings ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            customTabBar
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .tint(Theme.Palette.accent)
    }

    /// Brand-styled bottom bar: six equal items, each a small SF Symbol over a caption label. The
    /// selected item is tinted with the app accent; the rest read as tertiary text. A hairline +
    /// surface fill separates it from the content, and it respects the safe-area bottom inset.
    private var customTabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.rawValue) { item in
                tabButton(item)
            }
        }
        .padding(.top, Theme.Space.xs)
        .background(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.Palette.hairline)
                    .frame(height: 0.5)
                Theme.Palette.surface1
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func tabButton(_ item: Tab) -> some View {
        let selected = tab == item
        return Button {
            tab = item
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 22)
                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Home: Continue Watching + each installed catalog as a horizontal poster rail, from the shared
/// engine. Signed-out shows a sign-in prompt; the rails populate as the engine hydrates.
struct iOSHomeView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @State private var showSignIn = false

    /// The title whose artwork fills the hero backdrop: the first Continue Watching entry, falling
    /// back to the first catalog row's first item. (Touch has no focus engine, so the hero is fixed
    /// to a featured title rather than tracking a focused card, the way tvOS does.)
    private var heroBackdrop: String? {
        if let cw = core.continueWatching.first { return iOSHeroBackdrop.url(forCWId: cw.id, poster: cw.poster) }
        if let item = core.boardRows.first(where: { !$0.items.isEmpty })?.items.first {
            return item.background ?? item.poster
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                iOSHeroBackdrop(backdrop: heroBackdrop)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                        if !core.continueWatching.isEmpty {
                            PosterRail(title: "Continue Watching",
                                       items: core.continueWatching.map {
                                           RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                    poster: $0.poster, progress: $0.progress)
                                       })
                        }
                        ForEach(core.boardRows) { row in
                            if !row.items.isEmpty {
                                PosterRail(title: row.title,
                                           items: row.items.map {
                                               RailItem(id: $0.id, type: $0.type, name: $0.name,
                                                        poster: $0.poster, progress: 0)
                                           })
                            }
                        }
                        if core.boardRows.isEmpty && core.continueWatching.isEmpty {
                            emptyState
                        }
                    }
                    // Push the first rail down so it begins below the hero art and reads as content
                    // layered over the backdrop, not on top of it.
                    .padding(.top, iOSHeroBackdrop.contentInset)
                    .padding(.bottom, Theme.Space.md)
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("StremioX")
            .toolbar {
                if !account.isSignedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Sign In") { showSignIn = true }
                    }
                }
            }
            .sheet(isPresented: $showSignIn) { iOSSignInView() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: account.isSignedIn ? "popcorn" : "person.crop.circle")
                .font(.system(size: 52)).foregroundStyle(Theme.Palette.textSecondary)
            Text(account.isSignedIn ? "Loading your catalogs…" : "Sign in to load your add-ons and library.")
                .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            if !account.isSignedIn {
                Button("Sign In") { showSignIn = true }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 80).padding(.horizontal, Theme.Space.xl)
    }
}

/// Library: the user's saved titles from the engine, as a poster grid. Refreshes as the library
/// changes; reloads while empty since it syncs asynchronously after sign-in.
struct iOSLibraryView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    /// The hero backdrop tracks the first saved title. Library entries carry no backdrop field, so
    /// (like tvOS) we derive 16:9 art from metahub for IMDB ids and fall back to the poster.
    private var heroBackdrop: String? {
        guard let first = core.library?.catalog.first else { return nil }
        return iOSHeroBackdrop.url(forCWId: first.id, poster: first.poster)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                iOSHeroBackdrop(backdrop: heroBackdrop)
                ScrollView {
                    if let lib = core.library, !lib.catalog.isEmpty {
                        PosterGrid(items: lib.catalog.map {
                            RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: $0.progress)
                        })
                        .padding(.top, iOSHeroBackdrop.contentInset)
                        .padding(.bottom, Theme.Space.md)
                    } else {
                        ContentUnavailableViewCompat(title: "Library", systemImage: "books.vertical",
                            message: "Titles you add to your library in Stremio show up here.")
                            .frame(minHeight: 420)
                    }
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("Library")
            .onAppear { if core.library?.catalog.isEmpty != false { core.loadLibrary() } }
        }
    }
}

/// Search across every installed add-on, on the engine (debounced), as a poster grid.
struct iOSSearchView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            ScrollView {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableViewCompat(title: "Search", systemImage: "magnifyingglass",
                        message: "Search across everything your add-ons cover.").frame(minHeight: 420)
                } else if core.searchResults.isEmpty {
                    ContentUnavailableViewCompat(title: core.searchIsLoading ? "Searching…" : "No results",
                        systemImage: "magnifyingglass",
                        message: core.searchIsLoading ? "" : "Nothing matched what you typed.").frame(minHeight: 420)
                } else {
                    PosterGrid(items: core.searchResults.map {
                        RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0)
                    })
                    .padding(.vertical, Theme.Space.md)
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Movies or series")
            .onChange(of: query) { value in scheduleSearch(value) }   // iOS 16 single-param onChange
            .onDisappear { searchTask?.cancel() }
        }
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        let q = value.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { core.search(""); return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            core.search(q)
        }
    }
}

/// Discover, driven by the stremio-core engine (CatalogWithFilters): type, catalog, and genre
/// chips carrying the engine's own request, dispatched back on tap, over a poster grid.
struct iOSDiscoverView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    /// The hero backdrop tracks the first item of the currently selected catalog. Catalog metas
    /// carry their own `background`, with the poster as a fallback.
    private var heroBackdrop: String? {
        guard let item = core.discover?.items.first else { return nil }
        return item.background ?? item.poster
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // The backdrop rides under the chips + grid only once a catalog has loaded; the
                // loading / signed-out states keep their centered full-height composition.
                if core.discover != nil { iOSHeroBackdrop(backdrop: heroBackdrop) }
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        if let discover = core.discover {
                            chipScroll { ForEach(discover.selectable.types) { t in
                                chip(t.type.capitalized, t.selected) { core.selectDiscover(t.request) } } }
                            chipScroll { ForEach(discover.selectable.catalogs) { c in
                                chip(c.catalog, c.selected) { core.selectDiscover(c.request) } } }
                            if let genre = discover.selectable.extra.first(where: { $0.name.caseInsensitiveCompare("genre") == .orderedSame }),
                               !genre.options.isEmpty {
                                chipScroll { ForEach(genre.options) { o in
                                    chip(o.label, o.selected) { core.selectDiscover(o.request) } } }
                            }
                            PosterGrid(items: discover.items.map {
                                RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0)
                            })
                            .padding(.top, Theme.Space.sm)
                        } else if account.isSignedIn {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 100)
                        } else {
                            ContentUnavailableViewCompat(title: "Discover", systemImage: "safari",
                                message: "Sign in to browse your add-ons' catalogs.").frame(minHeight: 420)
                        }
                    }
                    // Chips begin below the hero art once a catalog is loaded; otherwise the
                    // centered states own the screen with their usual padding.
                    .padding(.top, core.discover != nil ? iOSHeroBackdrop.contentInset : Theme.Space.md)
                    .padding(.bottom, Theme.Space.md)
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("Discover")
            .onAppear { if core.discover == nil { core.loadDiscover() } }
        }
    }

    private func chipScroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) { content() }
                .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.xs)
        }
    }

    private func chip(_ label: String, _ selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).lineLimit(1).font(Theme.Typography.label)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, 8)
                .background(selected ? Theme.Palette.accent : Theme.Palette.surface2, in: Capsule())
                .foregroundStyle(selected ? .white : Theme.Palette.textSecondary)
        }
        .buttonStyle(.plain)
    }
}

/// One catalog row of tappable posters that push the detail page.
private struct RailItem: Identifiable { let id: String; let type: String; let name: String; let poster: String?; let progress: Double }

/// A poster grid (Library, Search) reusing the same card + detail navigation as the rails.
private struct PosterGrid: View {
    let items: [RailItem]
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    private let columns = [GridItem(.adaptive(minimum: 116), spacing: Theme.Space.sm)]
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.md) {
            ForEach(items) { item in
                NavigationLink {
                    iOSDetailView(id: item.id, type: item.type, title: item.name)
                } label: {
                    PosterCardiOS(name: item.name, poster: item.poster, progress: item.progress)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.md)
    }
}

private struct PosterRail: View {
    let title: String
    let items: [RailItem]
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Space.md)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.Space.sm) {
                    ForEach(items) { item in
                        NavigationLink {
                            iOSDetailView(id: item.id, type: item.type, title: item.name)
                        } label: {
                            PosterCardiOS(name: item.name, poster: item.poster, progress: item.progress)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Space.md)
            }
        }
    }
}

/// The browse pages' cinematic backdrop. Touch has no focus engine, so instead of tracking a focused
/// card (as tvOS does), each screen pins this to a FEATURED title's artwork: a large full-bleed image
/// at the top, fading into `Theme.Palette.canvas` so the rails / grid scroll cleanly over it. Mirrors
/// the dual scrim of `iOSDetailView.backdrop` (vertical canvas fade + leading fade) for one look across
/// the app. Compiles on iOS 16 and macOS — no platform-specific API.
struct iOSHeroBackdrop: View {
    /// A background-art URL (prefer the item's `background`, fall back to its poster).
    let backdrop: String?
    @EnvironmentObject private var theme: ThemeManager   // observe so a theme change repaints the scrim

    /// How far the page content is pushed down so its first row sits over the lower, faded band of the
    /// hero rather than on top of the art. Matches `heroHeight` minus an overlap so content tucks under.
    static let contentInset: CGFloat = heroHeight - 96

    /// Hero band height: a touch shorter on phones, taller on the Mac, like the detail page.
    private static var heroHeight: CGFloat {
        #if os(macOS)
        return 460
        #else
        return 300
        #endif
    }

    /// Standard Stremio 16:9 background art for an IMDB-identified title (library / Continue Watching
    /// entries carry no `background` of their own). Mirrors the tvOS helper.
    private static func metahubBackground(forId id: String) -> String? {
        guard id.hasPrefix("tt") else { return nil }
        return "https://images.metahub.space/background/big/\(id)/img"
    }

    /// Backdrop URL for a Continue Watching / library entry, which has only a poster: real backdrop
    /// art from metahub when the id is IMDB, otherwise the poster.
    static func url(forCWId id: String, poster: String?) -> String? {
        metahubBackground(forId: id) ?? poster
    }

    var body: some View {
        AsyncImage(url: URL(string: backdrop ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
            default: Theme.Palette.canvas
            }
        }
        .frame(height: Self.heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(
            // Vertical fade to canvas so the rails below read cleanly and the band dissolves into
            // the page instead of ending in a hard edge.
            LinearGradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: Theme.Palette.canvas.opacity(0.35), location: 0.5),
                .init(color: Theme.Palette.canvas.opacity(0.85), location: 0.82),
                .init(color: Theme.Palette.canvas, location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        )
        .overlay(
            // Leading fade, the same editorial touch the detail hero uses.
            LinearGradient(colors: [Theme.Palette.canvas.opacity(0.6), .clear],
                           startPoint: .leading, endPoint: .center)
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)   // pure presentation: never intercept taps meant for the rails
        .ignoresSafeArea(edges: .top)
        .animation(.easeOut(duration: 0.35), value: backdrop)
    }
}

private struct PosterCardiOS: View {
    let name: String
    let poster: String?
    let progress: Double
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                AsyncImage(url: URL(string: poster ?? "")) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(2/3, contentMode: .fill)
                    default: Theme.Palette.surface1
                    }
                }
                .frame(width: 120, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                if progress > 0.01 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.4))
                            Rectangle().fill(Theme.Palette.accent).frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                }
            }
            .frame(width: 120, height: 180)
            Text(name).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1).frame(width: 120, alignment: .leading)
        }
    }
}

/// Cross-version empty state (ContentUnavailableView is iOS 17+; the deployment target is 16).
private struct ContentUnavailableViewCompat: View {
    let title: String; let systemImage: String; let message: String
    @EnvironmentObject private var theme: ThemeManager   // observe textScale so Theme.Typography repaints live
    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: systemImage).font(.system(size: 48)).foregroundStyle(Theme.Palette.textTertiary)
            Text(title).font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
            Text(message).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }
}
