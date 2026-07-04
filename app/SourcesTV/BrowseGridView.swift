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
    /// Observed so hiding a category / whole section in Settings re-lays out the hub live.
    @ObservedObject private var prefs = CatalogPreferences.shared

    private var visibleDiscover: [DiscoverList] {
        guard !prefs.isCategoryHidden(HubCategoryKey.discoverSection) else { return [] }
        return model.discover.filter { !prefs.isCategoryHidden(HubCategoryKey.discover($0)) }
    }
    private var visibleGenres: [GenreSpec] {
        guard !prefs.isCategoryHidden(HubCategoryKey.genresSection) else { return [] }
        return model.genres.filter { !prefs.isCategoryHidden(HubCategoryKey.genre($0)) }
    }
    private var showStreaming: Bool { !prefs.isCategoryHidden(HubCategoryKey.streamingSection) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            if !visibleDiscover.isEmpty {
                section(title: "Discover", eyebrow: "Browse") {
                    ForEach(visibleDiscover, id: \.self) { list in
                        NavigationLink { TVCategoryBrowse(target: .discover(list)) } label: { DiscoverCardTile(list: list, backdrop: model.discoverBackdrops[list]) }
                            .buttonStyle(CardFocusStyle())
                    }
                }
            }
            if showStreaming, !model.providers.isEmpty {
                section(title: "Streaming Services", eyebrow: "Browse by service") {
                    ForEach(model.providers) { p in
                        NavigationLink { TVCategoryBrowse(target: .service(id: p.providerID, name: p.name)) } label: { TVServiceTile(provider: p) }
                            .buttonStyle(CardFocusStyle())
                    }
                }
            }
            if !visibleGenres.isEmpty {
                section(title: "Browse by Genre", eyebrow: "Browse by genre") {
                    ForEach(visibleGenres, id: \.self) { g in
                        NavigationLink { TVCategoryBrowse(target: .genre(g)) } label: { TVGenreTile(genre: g, backdrop: model.genreBackdrops[g.title]) }
                            .buttonStyle(CardFocusStyle())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func section<Content: View>(title: String, eyebrow: String, @ViewBuilder _ tiles: () -> Content) -> some View {
        // A hub row is a plain stacked VStack, IDENTICAL in shape to the ordinary Home catalog rows
        // (CoreCatalogRowView / TopPicksRow): a RailHeader over a horizontal ScrollView, greedy full width.
        //
        // FOCUS-JUMP ROOT CAUSE (fixed here): each hub row used to carry its own `.focusSection()`. Stacking
        // several sibling focus sections vertically makes tvOS move focus by REGION heuristics, not tile-to-
        // tile nearest-neighbour: a D-pad DOWN from a row-1 tile then jumped straight to a row-3 tile,
        // skipping row 2 (Streaming Services), and you had to press UP from row 3 to reach row 2. The
        // ordinary Home rows never do this precisely because they are NOT focus sections - plain geometric
        // nearest-overlap steps row1 -> row2 -> row3 in order. Dropping the per-row focus section restores
        // that same correct top-to-bottom traversal for the hub. (Mirrors the iOSRootView PosterRail note,
        // where a per-rail focusSection was likewise removed for consuming/mis-routing directional moves.)
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            // `title` / `eyebrow` arrive as raw English keys; resolve them through the catalog so the hub
            // row headers follow the app language (RailHeader renders plain String, which does not localize).
            RailHeader(eyebrow: String(localized: LocalizedStringResource(stringLiteral: eyebrow)),
                       title: String(localized: LocalizedStringResource(stringLiteral: title)))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    tiles()
                }
                .padding(.horizontal, Theme.Space.screenEdge)
                .padding(.vertical, Theme.Space.lg)   // room for the focus halo
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tiles

private let kHubCardWidth: CGFloat = 360
private let kHubTileWidth: CGFloat = 240

/// A cinematic Discover card (Trending / Popular / Latest / Upcoming): gradient + glyph + title + subtitle.
struct DiscoverCardTile: View {
    let list: DiscoverList
    /// Representative movie backdrop (resolved + daily-cached by CollectionsHubModel). The gradient is the
    /// base fallback, so a missing/slow backdrop still reads as a finished tile.
    var backdrop: String? = nil
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: list.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            if backdrop != nil { RemoteCover(url: backdrop) }
            // Bottom-up scrim like TVGenreTile so the title/subtitle stay legible over real artwork.
            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.25), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            Image(systemName: list.symbol)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.Palette.accent.opacity(list.accentOpacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(Theme.Space.lg)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(list.title)).font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                Text(LocalizedStringKey(list.subtitle)).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
            }
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .padding(Theme.Space.lg)
        }
        .frame(width: kHubCardWidth, height: kHubCardWidth * 0.52)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// H1/H14 curated brand-color map for the major streaming services, so a service tile reads as a clean,
/// first-party brand card (the provider mark on the brand's flat color) rather than a zoomed-crop of the
/// TMDB logo (the rejected fill-crop) or a tiny icon in a grey box. Keyed by TMDB `providerID` first (stable)
/// with a name-substring fallback for regional duplicates. Anything unmapped falls back to a neutral obsidian
/// surface, so the tile still reads cleanly. Colors are the brands' recognizable flat backgrounds.
/// NOTE: the identical map + tile treatment should live in SourcesShared so iOS/Mac (H1) share it; that
/// refactor is written up as a cross-agent patch. This tvOS-local copy keeps H14 self-contained + compiling.
enum ProviderBrand {
    /// The flat brand background for a provider, or nil when it isn't one of the curated majors.
    static func color(for provider: TMDBClient.ProviderTile) -> Color? {
        if let byID = byProviderID[provider.providerID] { return byID }
        let n = provider.name.lowercased()
        for (needle, color) in bySubstring where n.contains(needle) { return color }
        return nil
    }

    // TMDB watch-provider ids for the well-known majors.
    private static let byProviderID: [Int: Color] = [
        8: netflix,      // Netflix
        337: disney,     // Disney Plus
        2: appleBlack, 350: appleBlack,   // Apple TV + Apple TV Plus (both map to Apple black; H1 dedupe keeps one)
        9: prime, 10: prime, 119: prime,  // Amazon / Prime Video variants
        15: hulu,        // Hulu
        1899: hboMax, 384: hboMax, 1825: hboMax,   // Max / HBO Max
        531: paramount,  // Paramount Plus
        386: peacock,    // Peacock
    ]

    private static let bySubstring: [(String, Color)] = [
        ("netflix", netflix), ("disney", disney), ("apple", appleBlack),
        ("prime", prime), ("amazon", prime), ("hulu", hulu),
        ("hbo", hboMax), ("max", hboMax), ("paramount", paramount), ("peacock", peacock),
    ]

    // Recognizable flat brand backgrounds (sRGB).
    private static let netflix   = Color(red: 0.08, green: 0.08, blue: 0.09)   // near-black
    private static let disney    = Color(red: 0.04, green: 0.09, blue: 0.30)   // deep navy
    private static let appleBlack = Color(red: 0.07, green: 0.07, blue: 0.08)
    private static let prime     = Color(red: 0.00, green: 0.66, blue: 0.86)   // Prime blue
    private static let hulu      = Color(red: 0.11, green: 0.13, blue: 0.16)
    private static let hboMax    = Color(red: 0.09, green: 0.05, blue: 0.24)   // Max deep purple/navy
    private static let paramount = Color(red: 0.00, green: 0.40, blue: 0.98)
    private static let peacock   = Color(red: 0.10, green: 0.10, blue: 0.12)
}

/// A streaming-service tile (H14 / H1): a CLEAN dedicated brand card. The provider mark is rendered at a
/// modest size (`.fit`, never cropped) CENTERED on the brand's flat color (curated map for the majors, a
/// neutral obsidian surface otherwise), so it reads like a first-party app tile rather than a zoomed-crop
/// (rejected) or a tiny icon in a grey box. No bundled brand assets: the mark is the TMDB logo, the color
/// is what makes it a branded card. Matches the intended one-shared-treatment iOS/Mac design.
struct TVServiceTile: View {
    let provider: TMDBClient.ProviderTile
    var body: some View {
        ZStack {
            if let style = ProviderBrandLogo.brandStyle(for: provider.providerID),
               let slug = ProviderBrandLogo.bundledLogoName(for: provider.providerID),
               let bundled = BundledLogo.rawImage(named: slug) {
                // Full-bleed brand tile (the Apple TV look): the brand's OWN color fills the whole pill edge to
                // edge (a top->bottom gradient; top == bottom reads as a flat solid), with the bundled logo
                // centered on top - tinted white on dark/saturated fills, natural color on light fills (Netflix
                // red on white). No inset plate, no letters.
                LinearGradient(colors: [style.top, style.bottom], startPoint: .top, endPoint: .bottom)
                bundled
                    .renderingMode(style.tintWhite ? .template : .original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white)
                    .frame(width: kHubCardWidth * 0.62, height: kHubCardWidth * 0.52 * 0.62)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let slug = ProviderBrandLogo.bundledLogoName(for: provider.providerID),
                      let bundled = BundledLogo.image(named: slug) {
                // No curated brand style but we still bundle the mark: keep the plated look on the flat brand
                // color so a long-tail bundled mark (Plex, YouTube, SonyLIV, Zee5) is never a blank box.
                (ProviderBrand.color(for: provider) ?? Theme.Palette.surface2)
                bundled
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: kHubCardWidth * 0.82, height: kHubCardWidth * 0.52 * 0.72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if provider.logoURL != nil {
                (ProviderBrand.color(for: provider) ?? Theme.Palette.surface2)
                // Fallback for the long tail we don't bundle: the TMDB mark, filling the tile too, .fit so a
                // wordmark logo is never cropped. `brandName` gives RemoteLogo the provider FULL NAME to show
                // while loading / on failure, so a long-tail tile is never an empty box and never a bare letter.
                RemoteLogo(url: provider.logoURL, brandName: provider.name)
                    .frame(width: kHubCardWidth * 0.86, height: kHubCardWidth * 0.52 * 0.76)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No brand style, no bundled mark, no logoURL: the flat brand color (neutral fallback) with the
                // provider FULL NAME, never a bare single letter.
                (ProviderBrand.color(for: provider) ?? Theme.Palette.surface2)
                Text(provider.name).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).padding(Theme.Space.md)
            }
        }
        .frame(width: kHubCardWidth, height: kHubCardWidth * 0.52)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
                Text(LocalizedStringKey(genre.title)).font(.system(size: 20, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            }
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .padding(Theme.Space.md)
        }
        .frame(width: kHubCardWidth, height: kHubCardWidth * 0.52)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// A small cached remote logo, `.fit`-scaled, composited onto the SAME warm near-white plate the bundled
/// majors use (#95): the bare TMDB mark drawn straight onto the dark brand tile read as "very dark", and a
/// cropped w300 raster read as "incomplete"; plating the decoded mark makes it legible and keeps it whole,
/// pixel-consistent with the iOS/Mac tiles. Uses the shared URLCache (returnCacheDataElseLoad); a cancel
/// (scrolled away) just retries on the next appear.
struct RemoteLogo: View {
    let url: String?
    /// The provider's FULL NAME, shown on the shared plate while the mark loads or on failure so a long-tail
    /// tile is never an empty box and NEVER a bare single letter (owner: show the provider full name, e.g.
    /// Hulu / Peacock, when there is no logo). Empty hides the fallback (parity with iOS iOSServiceTile).
    var brandName: String = ""
    @State private var plated: Image?
    // The rasterized plate is 300x190 (see BundledLogo.Plate), so the SwiftUI fallback plate fits that same
    // aspect inside the caller's frame and stays pixel-consistent with a decoded+plated mark.
    private let plateAspect: CGFloat = 300.0 / 190.0
    var body: some View {
        Group {
            if let plated {
                plated.resizable().aspectRatio(contentMode: .fit)
            } else if !brandName.isEmpty {
                // Same warm near-white plate + dark ink the iOS tile uses; the full name reads on the plate
                // (>= 4.5:1). Fit the plate aspect inside the frame so it lands where the decoded mark would.
                GeometryReader { geo in
                    let plateW = min(geo.size.width, geo.size.height * plateAspect)
                    let plateH = plateW / plateAspect
                    RoundedRectangle(cornerRadius: plateW * BundledLogo.plateCornerFraction, style: .continuous)
                        .fill(BundledLogo.plateFill)
                        .overlay(
                            Text(brandName)
                                .font(.system(size: plateH * 0.20, weight: .heavy))
                                .foregroundStyle(Color.black.opacity(0.62))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.6)
                                .padding(.horizontal, plateW * 0.10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: plateW * BundledLogo.plateCornerFraction, style: .continuous)
                                .stroke(.black.opacity(0.10), lineWidth: 1)
                        )
                        .frame(width: plateW, height: plateH)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                Color.clear
            }
        }
        .task(id: url) { await load() }
    }
    private func load() async {
        guard let url, let u = URL(string: url) else { return }
        var req = URLRequest(url: u); req.cachePolicy = .returnCacheDataElseLoad
        // Composite the decoded mark onto the shared plate so the long tail matches the bundled majors. The
        // plate is a rounded rect a touch wider than tall, so the caller's `.fit` sees a mark already padded
        // and centered; a wide wordmark aspect-fits inside the plate instead of shrinking to nothing.
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let img = UIImage(data: data) { plated = BundledLogo.plated(img) }
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

    /// #104: the owner wants more per row (was 3 landscape / 6 poster). Fit 4 landscape cards into the SAME
    /// footprint 3 used (width * 3/4) so there is zero safe-area clipping risk on the TV, and 7 posters.
    /// The CARDS must render at exactly these cell widths too (passed into PosterCard below): the 145
    /// regression shrank only the GridItem cells while the cards stayed full-size, so 4 tiles overlapped.
    private static let landscapeCellWidth: CGFloat = kLandscapeCardWidth * 3.0 / 4.0
    private static let posterCellWidth: CGFloat = kPosterWidth * 6.0 / 7.0
    private var columns: [GridItem] {
        catalogPrefs.landscapeCards && apiKeys.hasTMDB
            ? Array(repeating: GridItem(.fixed(Self.landscapeCellWidth), spacing: Theme.Space.lg), count: 4)
            : Array(repeating: GridItem(.fixed(Self.posterCellWidth), spacing: Theme.Space.lg), count: 7)
    }

    var body: some View {
        ZStack {
            BrowseHeroBackdrop(model: focusModel, detailsBottom: 520)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text(LocalizedStringKey(target.title)).screenTitleStyle().padding(.horizontal, Theme.Space.screenEdge)
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
                    Button { select(sub.id) } label: { Text(LocalizedStringKey(sub.title)).lineLimit(1) }
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
                               width: Self.posterCellWidth, landscapeWidth: Self.landscapeCellWidth,
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

// MARK: - Discover personalization (region + category on/off) — tvOS

/// tvOS Settings screen for the Discover pack: a REGION picker (device region default, overridable) plus
/// per-category / per-section show-hide rows for the Discover cards, the Streaming-Services section, and each
/// genre tile. Binds to the shared `CatalogPreferences`, persists per-profile, and republishes so the live
/// hub re-lays out. Defaults reproduce today's behavior (device region, nothing hidden).
struct TVDiscoverSettingsView: View {
    @ObservedObject private var prefs = CatalogPreferences.shared

    /// (tag, label) region rows: "auto" = follow device region (nil override), then the common list.
    private var regionOptions: [(id: String, label: String)] {
        [("auto", String(localized: "Device region"))] + DiscoverRegions.common.map { ($0.code, $0.label) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Discover & Region").screenTitleStyle().padding(.horizontal, Theme.Space.screenEdge)

                choiceRow(String(localized: "Region"), regionOptions, selection: Binding(
                    get: { prefs.regionOverride ?? "auto" },
                    set: { prefs.regionOverride = ($0 == "auto") ? nil : $0 }))
                Text("Orders streaming services and scopes catalogs to this region. Device region follows your Apple TV setting.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, Theme.Space.screenEdge)

                categoryRow(String(localized: "Discover cards"), key: HubCategoryKey.discoverSection)
                categoryRow(String(localized: "Streaming services"), key: HubCategoryKey.streamingSection)
                categoryRow(String(localized: "Genres"), key: HubCategoryKey.genresSection)
                Text("Hide a whole section from Home and Discover.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, Theme.Space.screenEdge)

                if !prefs.isCategoryHidden(HubCategoryKey.discoverSection) {
                    Text("Discover Cards").font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.Palette.textPrimary).padding(.horizontal, Theme.Space.screenEdge).padding(.top, Theme.Space.md)
                    ForEach(DiscoverList.allCases, id: \.self) { list in
                        categoryRow(list.title, key: HubCategoryKey.discover(list))
                    }
                }

                if !prefs.isCategoryHidden(HubCategoryKey.genresSection) {
                    Text("Genres").font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.Palette.textPrimary).padding(.horizontal, Theme.Space.screenEdge).padding(.top, Theme.Space.md)
                    ForEach(CollectionsHubModel.genreList, id: \.self) { g in
                        categoryRow(g.title, key: HubCategoryKey.genre(g))
                    }
                }
            }
            .padding(.vertical, Theme.Space.lg)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    /// A Show/Hide choice row for one hub category (stored set holds HIDDEN keys).
    private func categoryRow(_ label: String, key: String) -> some View {
        choiceRow(label, [("1", String(localized: "Show")), ("0", String(localized: "Hide"))], selection: Binding(
            get: { prefs.isCategoryHidden(key) ? "0" : "1" },
            set: { prefs.setCategoryHidden(key, $0 == "0") }))
    }

    /// A segmented choice row (mirrors SettingsView.choiceRow so this screen matches the settings look).
    private func choiceRow(_ label: String, _ options: [(id: String, label: String)], selection: Binding<String>) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            Text(LocalizedStringKey(label)).font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.Palette.textPrimary).frame(width: 320, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(options, id: \.id) { opt in
                        Button { selection.wrappedValue = opt.id } label: { Text(LocalizedStringKey(opt.label)) }
                            .buttonStyle(ChipButtonStyle(selected: selection.wrappedValue == opt.id))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.screenEdge).padding(.vertical, Theme.Space.xs)
        .focusSection()
    }
}
