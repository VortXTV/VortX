import SwiftUI

/// tvOS Collections hub + the category browse screen it opens.
///
/// `TVCollectionsHub` is the compact band placed high on Home (and Discover): three horizontal rows of
/// TILES (Discover gradient cards, Streaming-service logo tiles, Genre tiles). Each tile is a focusable
/// `NavigationLink` into `TVCategoryBrowse`, which renders SUB-CATALOG pills over an infinite-scroll grid
/// (the `DiscoverView` idiom). Cards in the grid are ordinary `PosterCard`s, so they route to `DetailView`
/// and play through the engine like every other card. The hub only appears with a TMDB key set.

// MARK: - Hub

struct TVCollectionsHub: View {
    @ObservedObject var model: CollectionsHubModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            section(title: "Discover", eyebrow: "Browse") {
                ForEach(model.discover, id: \.self) { list in
                    NavigationLink { TVCategoryBrowse(target: .discover(list)) } label: { DiscoverCardTile(list: list) }
                        .buttonStyle(CardFocusStyle())
                }
            }
            if !model.providers.isEmpty {
                section(title: "Streaming Services", eyebrow: "Browse by service") {
                    ForEach(model.providers) { p in
                        NavigationLink { TVCategoryBrowse(target: .service(id: p.providerID, name: p.name)) } label: { TVServiceTile(provider: p) }
                            .buttonStyle(CardFocusStyle())
                    }
                }
            }
            section(title: "Browse by Genre", eyebrow: "Browse by genre") {
                ForEach(model.genres, id: \.self) { g in
                    NavigationLink { TVCategoryBrowse(target: .genre(g)) } label: { TVGenreTile(genre: g, backdrop: model.genreBackdrops[g.title]) }
                        .buttonStyle(CardFocusStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func section<Content: View>(title: String, eyebrow: String, @ViewBuilder _ tiles: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            RailHeader(eyebrow: eyebrow, title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    tiles()
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)   // room for the focus halo
            }
        }
    }
}

// MARK: - Tiles

private let kHubCardWidth: CGFloat = 360
private let kHubTileWidth: CGFloat = 240

/// A cinematic Discover card (Trending / Popular / Latest / Upcoming): gradient + glyph + title + subtitle.
struct DiscoverCardTile: View {
    let list: DiscoverList
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: list.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: list.symbol)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(Theme.Space.lg)
            VStack(alignment: .leading, spacing: 4) {
                Text(list.title).font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                Text(list.subtitle).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
            }
            .padding(Theme.Space.lg)
        }
        .frame(width: kHubCardWidth, height: kHubCardWidth * 0.52)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// A streaming-service tile: the service's TMDB logo on a dark surface, name beneath (text fallback when
/// no logo URL resolves). No bundled brand assets.
struct TVServiceTile: View {
    let provider: TMDBClient.ProviderTile
    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            ZStack {
                Theme.Palette.surface2
                if provider.logoURL != nil {
                    RemoteLogo(url: provider.logoURL).padding(Theme.Space.lg)
                } else {
                    Text(provider.name).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.Palette.textPrimary)
                        .multilineTextAlignment(.center).padding(Theme.Space.sm)
                }
            }
            .frame(width: kHubTileWidth, height: kHubTileWidth * 0.6)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            Text(provider.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
        }
        .frame(width: kHubTileWidth)
    }
}

/// A genre tile: real representative artwork (resolved async) under a legibility scrim, with the genre's
/// symbol + name. The tint gradient is the base and the fallback until/unless a backdrop resolves.
struct TVGenreTile: View {
    let genre: GenreSpec
    let backdrop: String?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [genre.tint.opacity(0.9), genre.tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if backdrop != nil { RemoteCover(url: backdrop) }
            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.2), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: genre.symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                Text(genre.title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            }
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .padding(Theme.Space.md)
        }
        .frame(width: kHubTileWidth, height: kHubTileWidth * 0.6)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// A small cached remote logo, `.fit`-scaled. Uses the shared URLCache (returnCacheDataElseLoad); a cancel
/// (scrolled away) just retries on the next appear.
struct RemoteLogo: View {
    let url: String?
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { Color.clear }
        }
        .task(id: url) { await load() }
    }
    private func load() async {
        guard let url, let u = URL(string: url) else { return }
        var req = URLRequest(url: u); req.cachePolicy = .returnCacheDataElseLoad
        if let (data, _) = try? await URLSession.shared.data(for: req), let img = UIImage(data: data) { image = img }
    }
}

/// A cached remote cover image, `.fill`-scaled (for genre tiles). The host frame + clipShape clip the
/// overflow. Same URLCache policy as `RemoteLogo`; a cancel just retries on the next appear.
struct RemoteCover: View {
    let url: String?
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { Color.clear }
        }
        .task(id: url) { await load() }
    }
    private func load() async {
        guard let url, let u = URL(string: url) else { return }
        var req = URLRequest(url: u); req.cachePolicy = .returnCacheDataElseLoad
        if let (data, _) = try? await URLSession.shared.data(for: req), let img = UIImage(data: data) { image = img }
    }
}

// MARK: - Category browse (sub-catalog pills + grid)

struct TVCategoryBrowse: View {
    let target: HubTarget

    @StateObject private var focusModel = FocusedItemModel()
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared

    @State private var selectedID: String = ""
    @State private var items: [MetaPreview] = []
    @State private var seen = Set<String>()
    @State private var page = 1
    @State private var loading = false
    @State private var done = false
    @State private var loadTask: Task<Void, Never>?

    private var subs: [SubCatalog] { CollectionsCatalog.subCatalogs(for: target, region: TMDBClient.deviceRegion) }
    private var columns: [GridItem] {
        catalogPrefs.landscapeCards && apiKeys.hasTMDB
            ? Array(repeating: GridItem(.fixed(kLandscapeCardWidth), spacing: Theme.Space.lg), count: 3)
            : Array(repeating: GridItem(.fixed(kPosterWidth), spacing: Theme.Space.lg), count: 6)
    }

    var body: some View {
        ZStack {
            BrowseHeroBackdrop(model: focusModel, detailsBottom: 520)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text(target.title).screenTitleStyle().padding(.horizontal, Theme.Space.screenEdge)
                    pills
                    grid
                }
                .padding(.top, Theme.Space.sm)
                .padding(.bottom, Theme.Space.xl)
            }
            .heroBottomStrip()
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear { if selectedID.isEmpty, let first = subs.first { select(first.id) } }
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
            .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs)
        }
    }

    @ViewBuilder private var grid: some View {
        if items.isEmpty {
            if done {
                Text("Nothing here yet.").font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary).padding(Theme.Space.xxl).frame(maxWidth: .infinity)
            } else {
                BigSpinner().padding(Theme.Space.xxl).frame(maxWidth: .infinity)
            }
        } else {
            LazyVGrid(columns: columns, spacing: Theme.Space.xl) {
                ForEach(items) { item in
                    PosterCard(title: item.name, poster: item.poster, type: item.type, id: item.id,
                               menu: .catalog,
                               onFocus: { focusModel.focus(hero(for: item)) })
                        .onAppear { if item.id == items.last?.id { Task { await loadNext() } } }
                }
            }
            .padding(.horizontal, Theme.Space.screenEdge)
            .padding(.top, Theme.Space.sm)
        }
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
        let next = await sub.load(page)
        guard requested == selectedID else { loading = false; return }   // a pill switched mid-fetch
        loading = false
        if next.isEmpty { done = true; return }
        page += 1
        let fresh = next.filter { seen.insert($0.id).inserted }
        items.append(contentsOf: fresh)
        if focusModel.hero == nil, let first = items.first { focusModel.seedIfEmpty(hero(for: first)) }
    }

    private func hero(for item: MetaPreview) -> FocusedHero {
        FocusedHero(id: item.id, type: item.type, title: item.name,
                    backdrop: item.poster, metaLine: item.type.capitalized, overview: nil, genreLine: nil)
    }
}

// MARK: - Reorder streaming services (Settings)

/// Settings screen to reorder the streaming-service tiles (owner: "Prime first, Netflix last"). tvOS has no
/// drag gesture, so each row carries Up / Down controls; the order persists immediately via the hub model.
struct TVReorderServicesView: View {
    @ObservedObject private var model = CollectionsHubModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Reorder Streaming Services").screenTitleStyle().padding(.horizontal, Theme.Space.screenEdge)
                Text("Set the order services appear in the Streaming row on Home and Discover.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, Theme.Space.screenEdge).padding(.bottom, Theme.Space.md)
                ForEach(Array(model.providers.enumerated()), id: \.element.id) { index, provider in
                    HStack(spacing: Theme.Space.md) {
                        Text("\(index + 1)").font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.Palette.textTertiary).frame(width: 44)
                        if provider.logoURL != nil { RemoteLogo(url: provider.logoURL).frame(width: 70, height: 40) }
                        Text(provider.name).font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.Palette.textPrimary)
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(ChipButtonStyle(selected: false)).disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(ChipButtonStyle(selected: false)).disabled(index == model.providers.count - 1)
                    }
                    .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.sm)
                }
            }
            .padding(.vertical, Theme.Space.lg)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .onAppear { model.load() }
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard target >= 0, target < model.providers.count else { return }
        var ids = model.providers.map(\.providerID)
        ids.swapAt(index, target)
        model.reorder(to: ids)
    }
}
