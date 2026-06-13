import SwiftUI

/// Native iOS root: bottom-tab shell over the shared engine. Surfaces are filled in one at a time
/// during the 0.3.0 rebase; Home is the first real one (poster rails from CoreBridge). The rest
/// stay placeholders until ported.
struct iOSRootView: View {
    var body: some View {
        TabView {
            iOSHomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            placeholder("Discover", "safari.fill")
                .tabItem { Label("Discover", systemImage: "safari.fill") }
            iOSLibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
            iOSSearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            iOSSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Theme.Palette.accent)
    }

    private func placeholder(_ title: String, _ icon: String) -> some View {
        NavigationStack {
            ContentUnavailableViewCompat(title: title, systemImage: icon,
                                         message: "Coming in the 0.3.0 native build.")
                .navigationTitle(title)
        }
    }
}

/// Home: Continue Watching + each installed catalog as a horizontal poster rail, from the shared
/// engine. Signed-out shows a sign-in prompt; the rails populate as the engine hydrates.
struct iOSHomeView: View {
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
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
                .padding(.vertical, Theme.Space.md)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("StremioX")
            .toolbar {
                if !account.isSignedIn {
                    ToolbarItem(placement: .topBarTrailing) {
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
    var body: some View {
        NavigationStack {
            ScrollView {
                if let lib = core.library, !lib.catalog.isEmpty {
                    PosterGrid(items: lib.catalog.map {
                        RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: $0.progress)
                    })
                    .padding(.vertical, Theme.Space.md)
                } else {
                    ContentUnavailableViewCompat(title: "Library", systemImage: "books.vertical",
                        message: "Titles you add to your library in Stremio show up here.")
                        .frame(minHeight: 420)
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

/// One catalog row of tappable posters that push the detail page.
private struct RailItem: Identifiable { let id: String; let type: String; let name: String; let poster: String?; let progress: Double }

/// A poster grid (Library, Search) reusing the same card + detail navigation as the rails.
private struct PosterGrid: View {
    let items: [RailItem]
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

private struct PosterCardiOS: View {
    let name: String
    let poster: String?
    let progress: Double
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
