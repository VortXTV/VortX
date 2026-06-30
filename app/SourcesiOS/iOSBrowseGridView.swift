import SwiftUI

/// iOS / Mac Collections hub + the category browse screen it opens (the touch/Mac twin of the tvOS
/// `TVCollectionsHub` / `TVCategoryBrowse`). The hub is a band of TILES placed high on Home (and Discover):
/// Discover gradient cards, Streaming-service logo tiles, and Genre tiles. Each tile is a value-based
/// `NavigationLink` that pushes `iOSCategoryBrowse`, which renders SUB-CATALOG pills over the shared
/// paginated `PosterGrid`. Grid cards push `iOSDetailView` through the screen's `NavigationPath`, so they
/// play through the engine like every other card. The hub only appears with a TMDB key set.

// MARK: - Hub

struct iOSCollectionsHub: View {
    @ObservedObject var model: CollectionsHubModel
    @ObservedObject private var downloads = DownloadStore.shared   // surface a Downloads tile only when there are any

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            // Downloads tile: shown ONLY when there is at least one download, so Home stays clean by default.
            // A second entry point alongside the inline Library downloads section (no new bottom-bar tab).
            if !downloads.records.isEmpty {
                hubSection(title: "Downloads") {
                    NavigationLink { iOSDownloadsScreen() } label: { iOSDownloadsTile(count: downloads.records.count) }.buttonStyle(.plain)
                }
            }
            hubSection(title: "Discover") {
                ForEach(model.discover, id: \.self) { list in
                    NavigationLink(value: HubTarget.discover(list)) { iOSDiscoverCard(list: list, backdrop: model.discoverBackdrops[list]) }.buttonStyle(.plain)
                }
            }
            if !model.providers.isEmpty {
                hubSection(title: "Streaming Services") {
                    ForEach(model.providers) { p in
                        NavigationLink(value: HubTarget.service(id: p.providerID, name: p.name)) { iOSServiceTile(provider: p) }.buttonStyle(.plain)
                    }
                }
            }
            hubSection(title: "Browse by Genre") {
                ForEach(model.genres, id: \.self) { g in
                    NavigationLink(value: HubTarget.genre(g)) { iOSGenreTile(genre: g, backdrop: model.genreBackdrops[g.title]) }.buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func hubSection<C: View>(title: String, @ViewBuilder _ tiles: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).sectionTitleStyle().padding(.horizontal, Theme.Space.md)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Space.sm) { tiles() }
                    .padding(.horizontal, Theme.Space.md)
            }
        }
    }
}

// MARK: - Tiles

// One pill size everywhere: the streaming + genre tiles match the Discover card (the owner's reference size),
// instead of the old half-width tiles that read as tiny icons.
private let kiOSCardWidth: CGFloat = 224

struct iOSDiscoverCard: View {
    let list: DiscoverList
    /// Representative movie backdrop for this card (resolved + daily-cached by CollectionsHubModel). The
    /// gradient is the base fallback, so a missing/slow backdrop still reads as a finished tile.
    var backdrop: String? = nil
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: list.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            if let backdrop, let url = URL(string: backdrop) {
                AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.clear }
            }
            // Bottom-up scrim like iOSGenreTile so the title/subtitle stay legible over real artwork.
            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.25), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            Image(systemName: list.symbol)
                .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.Palette.accent.opacity(list.accentOpacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(Theme.Space.md)
            VStack(alignment: .leading, spacing: 2) {
                Text(list.title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Text(list.subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
            }
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .padding(Theme.Space.md)
        }
        .frame(width: kiOSCardWidth, height: kiOSCardWidth * 0.5)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

struct iOSServiceTile: View {
    let provider: TMDBClient.ProviderTile
    var body: some View {
        // A FULL pill at Discover-card size, with NO caption underneath: the logo fills the pill so it reads as
        // a branded tile (Nuvio-style), not a tiny centered icon stranded in a grey box.
        ZStack {
            Theme.Palette.surface2
            if let logo = provider.logoURL, let url = URL(string: logo) {
                AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: { Color.clear }
                    // Fill the pill: the logo expands to the tile bounds with only a small breathing
                    // margin, so a square mark reads as a branded tile instead of a tiny centered icon
                    // stranded in grey. Keep .fit (not .fill) so wordmark logos aren't cropped.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .clipped()
            } else {
                Text(provider.name).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.center).padding(10)
            }
        }
        .frame(width: kiOSCardWidth, height: kiOSCardWidth * 0.5)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// The Downloads hub tile: a gradient card with the offline glyph and a count, matching the Discover-card
/// size. Pushes the standalone `iOSDownloadsScreen`.
struct iOSDownloadsTile: View {
    let count: Int
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Theme.Palette.surface2, Theme.Palette.surface1], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.Palette.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(Theme.Space.md)
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloads").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Text(count == 1 ? "1 item saved offline" : "\(count) items saved offline")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
            }
            .padding(Theme.Space.md)
        }
        .frame(width: kiOSCardWidth, height: kiOSCardWidth * 0.5)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

struct iOSGenreTile: View {
    let genre: GenreSpec
    let backdrop: String?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [genre.tint.opacity(0.9), genre.tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let backdrop, let url = URL(string: backdrop) {
                AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.clear }
            }
            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.2), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            HStack(spacing: 6) {
                Image(systemName: genre.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(genre.title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            }
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .padding(10)
        }
        .frame(width: kiOSCardWidth, height: kiOSCardWidth * 0.5)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

// MARK: - Category browse (sub-catalog pills + grid)

struct iOSCategoryBrowse: View {
    let target: HubTarget
    @Binding var path: NavigationPath

    @State private var selectedID: String = ""
    @State private var items: [RailItem] = []
    @State private var seen = Set<String>()
    @State private var page = 1
    @State private var loading = false
    @State private var done = false
    @State private var loadTask: Task<Void, Never>?
    @State private var pushing = false

    /// The persistent cinematic hero at the top of the browse screen - the same ambient billboard Home /
    /// Discover use, seeded from the selected pill's top items. tvOS's TVCategoryBrowse already has a hero
    /// (BrowseHeroBackdrop); this brings the iOS/Mac twin to parity.
    @StateObject private var hero = FeaturedHeroModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var subs: [SubCatalog] { CollectionsCatalog.subCatalogs(for: target, region: TMDBClient.deviceRegion) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.md) {
                if hero.hero != nil {
                    FeaturedHeroView(model: hero, onOpen: openHero)
                }
                pills
                if items.isEmpty {
                    if done {
                        Text("Nothing here yet.").font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textSecondary).frame(maxWidth: .infinity).padding(Theme.Space.xxl)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(Theme.Space.xxl)
                    }
                } else {
                    PosterGrid(items: items, onTap: open, menu: .catalog, onReachEnd: { Task { await loadNext() } })
                }
            }
            .padding(.bottom, Theme.Space.md)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle(target.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { pushing = false; if selectedID.isEmpty, let first = subs.first { select(first.id) } }
        .onDisappear { loadTask?.cancel() }
    }

    private var pills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.sm) {
                ForEach(subs) { sub in
                    Button { select(sub.id) } label: { Text(sub.title).lineLimit(1) }
                        .buttonStyle(ChipButtonStyle(selected: sub.id == selectedID))
                }
            }
            .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.xs)
        }
    }

    private func open(_ item: RailItem) {
        guard !pushing else { return }   // ignore a rapid second tap before the push settles (avoids double-push)
        pushing = true
        path.append(FeaturedHeroItem.from(rail: item))
    }

    /// Hero Play button - same double-push guard as a poster tap, but the hero already hands us a FeaturedHeroItem.
    private func openHero(_ item: FeaturedHeroItem) {
        guard !pushing else { return }
        pushing = true
        path.append(item)
    }

    private func select(_ id: String) {
        guard id != selectedID || items.isEmpty else { return }
        selectedID = id
        items = []; seen = []; page = 1; done = false
        loadTask?.cancel()
        loadTask = Task { await loadNext() }
    }

    private func loadNext() async {
        guard !loading, !done, let sub = subs.first(where: { $0.id == selectedID }) else { return }
        loading = true
        let requested = selectedID
        let metas = await sub.load(page)
        guard requested == selectedID else { loading = false; return }
        loading = false
        if metas.isEmpty { done = true; return }
        page += 1
        let firstPage = (page == 2)   // page was 1 before this increment -> these are the pill's top items
        let fresh = metas.filter { seen.insert($0.id).inserted }
            .map { RailItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, progress: 0) }
        items.append(contentsOf: fresh)
        // Seed (and on a pill switch, re-seed) the hero from the top of the freshly loaded catalog so the
        // billboard reflects what's on screen. The model rotates + enriches from here; later pages don't reseed.
        if firstPage {
            hero.seed(Array(items.prefix(6)).map(FeaturedHeroItem.from(rail:)), reduceMotion: reduceMotion)
        }
    }
}

// MARK: - Reorder streaming services (Settings)

/// Settings screen to reorder the streaming-service tiles (owner: "Prime first, Netflix last"). A standard
/// drag-to-reorder List; iOS forces edit mode on, macOS reorders by native row drag. Persists immediately.
struct iOSReorderServicesView: View {
    @ObservedObject private var model = CollectionsHubModel.shared

    var body: some View {
        List {
            ForEach(model.providers) { provider in
                HStack(spacing: Theme.Space.md) {
                    ZStack {
                        Theme.Palette.surface2
                        if let logo = provider.logoURL, let url = URL(string: logo) {
                            AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fit) } placeholder: { Color.clear }
                                .padding(7)
                        }
                    }
                    .frame(width: 52, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(provider.name).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    Image(systemName: "line.3.horizontal").foregroundStyle(Theme.Palette.textTertiary)
                }
                .padding(.vertical, 6)
                .listRowBackground(Theme.Palette.surface1)
                .listRowSeparator(.hidden)
            }
            .onMove(perform: move)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("Reorder Services")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        #endif
        .onAppear { model.load() }
    }

    private func move(from: IndexSet, to: Int) {
        var tiles = model.providers
        tiles.move(fromOffsets: from, toOffset: to)
        model.reorder(to: tiles.map(\.providerID))
    }
}
