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
    /// Observed so hiding a category / whole section in Settings re-lays out the hub live.
    @ObservedObject private var prefs = CatalogPreferences.shared
    #if os(iOS)
    /// Drives the 2-up phone tile sizing (#19); regular (iPad) and macOS keep the wider rail tiles.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif
    /// Measured viewport width the tile size derives from (0 until the first layout pass lands).
    @State private var containerWidth: CGFloat = 0

    /// Category tiles sized to the viewport (#19): exactly 2 per row on a compact iPhone (the owner's
    /// "2 per row, not 3"), ~4 per row on iPad/Mac. Falls back to the legacy fixed width pre-measure.
    private var tileWidth: CGFloat {
        #if os(iOS)
        let compact = hSizeClass == .compact
        #else
        let compact = false
        #endif
        return iOSPillMetrics.hubTileWidth(container: containerWidth, compact: compact)
    }

    /// The Discover cards the user has NOT hidden (whole section off => empty).
    private var visibleDiscover: [DiscoverList] {
        guard !prefs.isCategoryHidden(HubCategoryKey.discoverSection) else { return [] }
        return model.discover.filter { !prefs.isCategoryHidden(HubCategoryKey.discover($0)) }
    }
    /// The genre tiles the user has NOT hidden (whole section off => empty).
    private var visibleGenres: [GenreSpec] {
        guard !prefs.isCategoryHidden(HubCategoryKey.genresSection) else { return [] }
        return model.genres.filter { !prefs.isCategoryHidden(HubCategoryKey.genre($0)) }
    }
    /// Whether the streaming-services section is shown (a single section switch, not per-service).
    private var showStreaming: Bool { !prefs.isCategoryHidden(HubCategoryKey.streamingSection) }
    /// The streaming tiles with TMDB's split brand entries collapsed to one per brand (H1: the owner saw
    /// TWO Apple TV+ tiles - id 2 "Apple TV" store and id 350 "Apple TV+" are separate TMDB entries; also
    /// Prime / Max / Discovery+ alias pairs). View-layer dedup so the shared model stays untouched.
    private var streamingProviders: [TMDBClient.ProviderTile] { ProviderBrandMap.dedupeProviders(model.providers) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            // Downloads is reachable ONLY via the Downloads pill inside the Library tab (owner's final
            // directive). No Downloads tile on Home/Discover, no inline mount at the top of Library.
            if !visibleDiscover.isEmpty {
                hubSection(title: "Discover") {
                    ForEach(visibleDiscover, id: \.self) { list in
                        NavigationLink(value: HubTarget.discover(list)) { iOSDiscoverCard(list: list, backdrop: model.discoverBackdrops[list], width: tileWidth) }.buttonStyle(.plain)
                    }
                }
            }
            if showStreaming, !streamingProviders.isEmpty {
                hubSection(title: "Streaming Services") {
                    ForEach(streamingProviders) { p in
                        NavigationLink(value: HubTarget.service(id: p.providerID, name: p.name)) { iOSServiceTile(provider: p, width: tileWidth) }.buttonStyle(.plain)
                    }
                }
            }
            if !visibleGenres.isEmpty {
                hubSection(title: "Browse by Genre") {
                    ForEach(visibleGenres, id: \.self) { g in
                        NavigationLink(value: HubTarget.genre(g)) { iOSGenreTile(genre: g, backdrop: model.genreBackdrops[g.title], width: tileWidth) }.buttonStyle(.plain)
                    }
                }
            }
        }
        // Measure the hub's laid-out width (== the scroll viewport width; the hub is a full-width
        // column child) so the tile size can target an exact per-row count instead of a fixed 224.
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { containerWidth = $0 }
            }
        }
    }

    @ViewBuilder private func hubSection<C: View>(title: String, @ViewBuilder _ tiles: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // The caller passes a raw English key ("Discover", "Streaming Services", "Browse by Genre");
            // localize it here so the section header follows the app language.
            Text(LocalizedStringKey(title)).sectionTitleStyle().padding(.horizontal, Theme.Space.md)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Space.sm) { tiles() }
                    .padding(.horizontal, Theme.Space.md)
            }
        }
    }
}

// MARK: - Tiles

// One pill WIDTH everywhere (the owner's "every pill should be the same size"): the streaming + genre +
// Discover hub tiles AND the movie/show/Continue-Watching poster cards all derive their column width from
// this single value, so no tile is wider or narrower than another. Lives on a shared enum so PosterCardiOS
// (in iOSRootView) can reference the exact same number.
enum iOSPillMetrics {
    /// The shared tile/pill column width used across the hub tiles and the poster cards.
    static let cardWidth: CGFloat = 224
    /// Poster-grid card width on a COMPACT iPhone only (#104): 224 fit just one column on a phone, so the
    /// vertical poster grid + its cards use this narrower width there to show ~3 across. iPad/Mac stay at 224.
    static let gridPosterWidthCompact: CGFloat = 116

    /// The poster-card / grid-track width for the user's Poster Style preset, size-class aware. The grid and
    /// the cards both call this so they stay in lockstep and the adaptive column count recomputes from the
    /// chosen width. `.balanced` returns the shipping values (224 regular / 116 compact), so the default is
    /// unchanged. Hub/pill tiles keep the fixed `cardWidth`; only the movie/show poster cards follow the preset.
    static func gridPosterWidth(preset: PosterWidthPreset, compact: Bool) -> CGFloat {
        compact ? preset.compactWidth : preset.regularWidth
    }

    /// Hub category tile width, derived from the measured viewport so the rail shows an exact per-row
    /// count (#19): 2 tiles per row on a compact iPhone, ~4 per row on iPad/Mac (clamped so a narrow Mac
    /// window never shrinks tiles below the legacy 224 and a huge one never balloons them). Falls back to
    /// the fixed `cardWidth` before the first width measurement lands.
    static func hubTileWidth(container: CGFloat, compact: Bool) -> CGFloat {
        guard container > 0 else { return cardWidth }
        let outerPadding = 2 * Theme.Space.md   // the rail's horizontal content padding
        let spacing = Theme.Space.sm
        if compact {
            return max(150, (container - outerPadding - spacing) / 2)
        }
        let fourUp = (container - outerPadding - 3 * spacing) / 4
        return min(max(fourUp, cardWidth), 300)
    }
}

struct iOSDiscoverCard: View {
    let list: DiscoverList
    /// Representative movie backdrop for this card (resolved + daily-cached by CollectionsHubModel). The
    /// gradient is the base fallback, so a missing/slow backdrop still reads as a finished tile.
    var backdrop: String? = nil
    /// Viewport-derived tile width (#19); defaults to the legacy fixed width for callers that don't size.
    var width: CGFloat = iOSPillMetrics.cardWidth
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
                Text(LocalizedStringKey(list.title)).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Text(LocalizedStringKey(list.subtitle)).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
            }
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .padding(Theme.Space.md)
        }
        .frame(width: width, height: width * 0.5)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

struct iOSServiceTile: View {
    let provider: TMDBClient.ProviderTile
    /// Viewport-derived tile width (#19); defaults to the legacy fixed width for callers that don't size.
    var width: CGFloat = iOSPillMetrics.cardWidth

    private var tileHeight: CGFloat { width * 0.5 }
    /// The provider mark FILLS the tile (owner: "logo should fill the pill, not sit as a tiny mark on a plate").
    /// The plated art is already inset inside its own art, so the mark frame spans most of the tile with only a
    /// small breathing margin; .fit keeps a wordmark or a square icon whole and centered on the brand color.
    private var markWidth: CGFloat { width * 0.82 }
    private var markHeight: CGFloat { tileHeight * 0.72 }
    /// The warm near-white plate behind a REMOTE (unbundled) mark (#95). It now FILLS the tile too; corner +
    /// inset are derived from the same fractions the rasterized bundled/remote plate uses so both stay
    /// pixel-consistent. Kept a touch under the full tile so the brand color still frames the plate.
    private var plateWidth: CGFloat { width * 0.86 }
    private var plateHeight: CGFloat { tileHeight * 0.76 }
    private var plateCorner: CGFloat { plateWidth * BundledLogo.plateCornerFraction }
    private var plateInset: CGFloat { plateWidth * BundledLogo.plateInsetFraction }

    var body: some View {
        // Full-bleed brand tile (the Apple TV look the owner asked for): the brand's OWN color fills the whole
        // pill edge to edge, with the bundled logo centered on top - Netflix full white + red wordmark, Disney+
        // full blue + white logo, Apple TV+ full black + white logo, Hulu full black + green logo. No inset
        // white plate, no letters. The flat color lives in ProviderBrandLogo.brandStyle; the logo image is our
        // bundled first-party mark (SwiftUI-tinted white on dark fills, natural color on light fills).
        ZStack {
            if let style = ProviderBrandMap.brandStyle(for: provider.providerID),
               let slug = ProviderBrandMap.bundledLogoName(for: provider.providerID),
               let bundled = BundledLogo.rawImage(named: slug) {
                // The brand fill covers the ENTIRE tile (a top->bottom gradient; top == bottom reads as a flat
                // solid), so the tile itself is the brand-colored pill.
                LinearGradient(colors: [style.top, style.bottom], startPoint: .top, endPoint: .bottom)
                // The bundled mark centered on top, tinted white on dark/saturated fills (a clean single-color
                // wordmark) or kept its natural color on light fills (Netflix red on white). .fit keeps a
                // wordmark or a square icon whole and large, filling ~62% of the tile width.
                bundled
                    .renderingMode(style.tintWhite ? .template : .original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white)
                    .frame(maxWidth: width * 0.62, maxHeight: tileHeight * 0.62)
            } else if let slug = ProviderBrandMap.bundledLogoName(for: provider.providerID),
                      let bundled = BundledLogo.image(named: slug) {
                // No curated brand style but we still bundle the mark: keep the plated look on the flat brand
                // color so the tile is never a blank box (long-tail bundled marks: Plex, YouTube, SonyLIV, Zee5).
                ProviderBrandMap.brandColor(for: provider.providerID)
                LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.28)],
                               startPoint: .top, endPoint: .bottom)
                bundled
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: markWidth, maxHeight: markHeight)
            } else if let logo = provider.logoURL, let url = URL(string: logo) {
                // The flat brand color + sheen frames the remote plate below for the unbundled long tail.
                ProviderBrandMap.brandColor(for: provider.providerID)
                LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.28)],
                               startPoint: .top, endPoint: .bottom)
                // Fallback for the long tail we don't bundle: the TMDB mark, on the SAME warm near-white plate
                // the bundled majors use (#95: the bare mark drawn straight onto the dark brand tile read as
                // "very dark"; a cropped w300 raster read as "incomplete"). The mark is aspect-fit and centered
                // inside the plate, never cropped; the light plate makes even a dark square app-icon legible.
                // The provider FULL NAME stays as the load/failure fallback so the tile is never a blank box.
                RoundedRectangle(cornerRadius: plateCorner, style: .continuous)
                    .fill(BundledLogo.plateFill)
                    .frame(width: plateWidth, height: plateHeight)
                    .overlay(
                        AsyncImage(url: url) { img in
                            img.resizable().aspectRatio(contentMode: .fit)
                        } placeholder: {
                            // While the logo streams in (or on failure), show the provider FULL NAME so the tile
                            // is never a blank box and NEVER a bare single letter (owner: "show the provider full
                            // name, e.g. Hulu / Peacock, when there is no logo"). Dark ink on the warm near-white
                            // plate (>= 4.5:1); wraps to 2 lines so a longer name stays legible.
                            Text(provider.name)
                                .font(.system(size: markHeight * 0.24, weight: .heavy))
                                .foregroundStyle(Color.black.opacity(0.62))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.6)
                        }
                        .padding(plateInset)
                    )
                    // Hairline edge so even a light mark keeps a visible plate boundary (matches the raster plate).
                    .overlay(
                        RoundedRectangle(cornerRadius: plateCorner, style: .continuous)
                            .stroke(.black.opacity(0.10), lineWidth: 1)
                    )
            } else {
                // No brand style, no bundled mark, no logoURL: the flat brand color (neutral fallback) with the
                // provider FULL NAME, never a bare single letter.
                ProviderBrandMap.brandColor(for: provider.providerID)
                Text(provider.name)
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineLimit(2).padding(10)
            }
        }
        .frame(width: width, height: tileHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        // A hairline lifts the tile off the canvas the way a real brand card sits on a shelf.
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .accessibilityElement()
        .accessibilityLabel(provider.name)
    }
}

struct iOSGenreTile: View {
    let genre: GenreSpec
    let backdrop: String?
    /// Viewport-derived tile width (#19); defaults to the legacy fixed width for callers that don't size.
    var width: CGFloat = iOSPillMetrics.cardWidth
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [genre.tint.opacity(0.9), genre.tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let backdrop, let url = URL(string: backdrop) {
                AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.clear }
            }
            LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.2), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            HStack(spacing: 6) {
                Image(systemName: genre.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(LocalizedStringKey(genre.title)).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            }
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .padding(10)
        }
        .frame(width: width, height: width * 0.5)
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
    /// Push debounce: a sticky Bool reset in onAppear died when pop-back did not re-fire onAppear in
    /// the 7-tab opacity-ZStack architecture, eating every tap after the first (owner report). Time-based
    /// so it can never wedge shut.
    @State private var lastPush = Date.distantPast
    /// In-flight guard for the async tmdb:->tt resolve so a slow (>0.6s) resolve cannot be pushed twice.
    @State private var resolving = false

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
        // navigationTitle on a pushed view bridges into the shared window NSToolbar on macOS and crashes
        // (_insertNewItemWithItemIdentifier). iOS-only; on macOS the title shows in-content.
        #if os(iOS)
        .navigationTitle(Text(LocalizedStringKey(target.title)))
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .macBackAffordance()   // macOS in-content Back + Esc / Cmd-[ (no toolbar back exists)
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
            .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.xs)
        }
    }

    private func open(_ item: RailItem) {
        guard Date().timeIntervalSince(lastPush) > 0.6 else { return }   // rapid double-tap guard only
        lastPush = Date()
        pushResolvingHubID(FeaturedHeroItem.from(rail: item))
    }

    /// Hero Play button - same double-push guard as a poster tap, but the hero already hands us a FeaturedHeroItem.
    private func openHero(_ item: FeaturedHeroItem) {
        guard Date().timeIntervalSince(lastPush) > 0.6 else { return }
        lastPush = Date()
        pushResolvingHubID(item)
    }

    /// Hub catalogs (Discover/Trending/genres/streaming tiles) deliver `tmdb:` ids, which Cinemeta meta,
    /// stream add-ons and the ratings service cannot key on - so on iOS/Mac the detail hero art, ratings and
    /// the Play button all stayed dark for hub items (tvOS already works because its stream path never gated on
    /// meta). Resolve tmdb:->tt BEFORE pushing so the pushed item carries a tt id. A non-tmdb id pushes
    /// immediately; the resolve is fail-soft (push the unresolved item so detail still opens with seed art +
    /// the de-gated Play button). external_ids is edge-cached, so a warm title resolves in a few ms.
    private func pushResolvingHubID(_ item: FeaturedHeroItem) {
        guard item.id.hasPrefix("tmdb:") else { path.append(item); return }
        // The 0.6s lastPush window can reopen before a cold-cache external_ids resolve returns (>0.6s),
        // letting a second tap push the same detail twice. Gate the async path on a dedicated in-flight flag.
        guard !resolving else { return }
        resolving = true
        Task { @MainActor in
            let tt = await TMDBClient.imdbID(forCatalogID: item.id, type: item.type)
            resolving = false
            path.append(tt.map { item.withResolvedIMDbID($0) } ?? item)
        }
    }

    private func select(_ id: String) {
        guard id != selectedID || items.isEmpty else { return }
        selectedID = id
        // Reset `loading` too: cancellation is cooperative, so the outgoing load task may still be suspended at
        // `await sub.load(page)` with loading==true when the new task starts. Without this reset the new task
        // hits `guard !loading` and bails, and when the old task finally resumes it only sets loading=false and
        // returns (id mismatch) - leaving items empty, no task running, and a PERMANENT spinner on the new pill.
        items = []; seen = []; page = 1; done = false; loading = false
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
                        // The warm near-white plate (#95) so a dark provider mark is legible in the reorder
                        // list too, matching the plated tiles on Home/Discover rather than a dark-on-dark chip.
                        BundledLogo.plateFill
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
        // iOS-only: a macOS navigationTitle on this pushed reorder list crashes the shared NSToolbar.
        #if os(iOS)
        .navigationTitle("Reorder Services")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        #endif
        .macBackAffordance()   // macOS in-content Back + Esc / Cmd-[ (no toolbar back exists)
        .onAppear { model.load() }
    }

    private func move(from: IndexSet, to: Int) {
        var tiles = model.providers
        tiles.move(fromOffsets: from, toOffset: to)
        model.reorder(to: tiles.map(\.providerID))
    }
}

// MARK: - Discover personalization (region + category on/off)

/// Settings screen (iOS / iPad / Mac) for the Discover pack: a REGION picker (device region by default,
/// overridable — orders + scopes hub content to a chosen country) plus per-category / per-section show/hide
/// toggles for the Discover cards, the Streaming-Services section, and each genre tile. Everything binds to
/// the shared `CatalogPreferences`, persists per-profile via UserDefaults, and republishes so the live hub
/// re-lays out immediately. Defaults reproduce today's behavior (device region, nothing hidden).
struct iOSDiscoverSettingsView: View {
    @ObservedObject private var prefs = CatalogPreferences.shared

    /// The region rows: a "Device region" default (nil override) plus a curated list of common regions.
    private var regionRows: [(code: String?, label: String)] {
        [(nil, String(localized: "Device region"))]
            + DiscoverRegions.common.map { ($0.code as String?, $0.label) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Region", selection: Binding(
                    get: { prefs.regionOverride },
                    set: { prefs.regionOverride = $0 })) {
                    ForEach(regionRows, id: \.code) { row in
                        Text(row.label).tag(row.code)
                    }
                }
            } header: {
                Text("Region")
            } footer: {
                Text("Orders streaming services and scopes catalogs to this region. Device region follows your system setting.")
            }

            Section {
                categoryToggle("Discover cards", key: HubCategoryKey.discoverSection)
                categoryToggle("Streaming services", key: HubCategoryKey.streamingSection)
                categoryToggle("Genres", key: HubCategoryKey.genresSection)
            } header: {
                Text("Sections")
            } footer: {
                Text("Hide a whole section from Home and Discover.")
            }

            if !prefs.isCategoryHidden(HubCategoryKey.discoverSection) {
                Section("Discover cards") {
                    ForEach(DiscoverList.allCases, id: \.self) { list in
                        categoryToggle(list.title, key: HubCategoryKey.discover(list))
                    }
                }
            }

            if !prefs.isCategoryHidden(HubCategoryKey.genresSection) {
                Section("Genres") {
                    ForEach(CollectionsHubModel.genreList, id: \.self) { g in
                        categoryToggle(g.title, key: HubCategoryKey.genre(g))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle("Discover & Region")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .macBackAffordance()
    }

    /// One show/hide toggle for a hub category. The stored set holds HIDDEN keys, so the toggle is "shown" =
    /// the key is NOT in the set; flipping it off inserts the key.
    private func categoryToggle(_ title: String, key: String) -> some View {
        Toggle(LocalizedStringKey(title), isOn: Binding(
            get: { !prefs.isCategoryHidden(key) },
            set: { prefs.setCategoryHidden(key, !$0) }))
    }
}

// MARK: - Poster style (width / radius / landscape / labels) with a live preview

/// Settings screen that tunes how catalog poster cards look: WIDTH preset, corner RADIUS preset, a
/// portrait-vs-landscape art toggle, and a hide-labels toggle. A LIVE PREVIEW poster at the top redraws
/// as each control changes so the effect is visible before leaving the screen. Every control is two-way
/// bound to the shared `CatalogPreferences`, which persists to UserDefaults and republishes so the real
/// Home / Discover / Library grids re-lay out immediately. Defaults reproduce today's look, so nothing
/// changes unless the user opts in.
struct iOSPosterStyleView: View {
    @ObservedObject private var prefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared

    var body: some View {
        Form {
            Section {
                PosterStylePreview()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } header: {
                Text("Preview")
            }

            Section {
                Picker("Width", selection: $prefs.posterWidth) {
                    ForEach(PosterWidthPreset.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                }
                Picker("Corner radius", selection: $prefs.posterRadius) {
                    ForEach(PosterRadiusPreset.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                }
            } header: {
                Text("Poster Cards")
            } footer: {
                Text("Width sets how large posters are and how many fit per row. Balanced and Rounded match the default look.")
            }

            Section {
                // Landscape 16:9 art needs a TMDB key (a clean backdrop); without one the toggle is disabled
                // and posters stay portrait, so keyless users never get a degraded composite.
                Toggle("Landscape (16:9) art", isOn: $prefs.landscapeCards)
                    .disabled(!apiKeys.hasTMDB)
                Toggle("Hide poster labels", isOn: $prefs.hidePosterLabels)
            } header: {
                Text("Layout")
            } footer: {
                Text(apiKeys.hasTMDB
                     ? "Landscape shows cinematic 16:9 backdrops instead of portrait posters where art is available. Hide labels for a cleaner, poster-only grid."
                     : "Landscape 16:9 art needs a TMDB key (add one under Streams). Hide labels for a cleaner, poster-only grid.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle("Poster Style")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .macBackAffordance()   // macOS in-content Back + Esc / Cmd-[ (no toolbar back exists)
    }
}

/// The live sample poster shown at the top of `iOSPosterStyleView`. It mirrors the real `PosterCardiOS`
/// geometry (preset width, aspect from the landscape toggle, preset corner radius, optional label) using a
/// gradient placeholder so it needs no network / metadata. Reads the shared `CatalogPreferences`, so it
/// redraws the instant any control changes.
private struct PosterStylePreview: View {
    @ObservedObject private var prefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared

    /// Preview at the REGULAR width so the sample is comfortably large on every device (the grid itself
    /// uses the size-class-aware width). Capped so the widest preset still fits the settings row.
    private var width: CGFloat { min(prefs.posterWidth.regularWidth, 220) }
    private var landscape: Bool { prefs.landscapeCards && apiKeys.hasTMDB }
    private var height: CGFloat { landscape ? width * 9.0 / 16.0 : width * 3.0 / 2.0 }

    /// "Balanced · Rounded" (+ " · Landscape" when on), each piece localized. Built as a String so the
    /// width/radius preset names resolve through the catalog rather than being interpolated raw.
    private var previewCaption: String {
        let width = String(localized: LocalizedStringResource(stringLiteral: prefs.posterWidth.label))
        let radius = String(localized: LocalizedStringResource(stringLiteral: prefs.posterRadius.label))
        let base = "\(width) · \(radius)"
        return landscape ? "\(base) · \(String(localized: "Landscape"))" : base
    }

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [Theme.Palette.accent.opacity(0.85), Theme.Palette.surface2],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(alignment: .center) {
                            Image(systemName: "film")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: prefs.posterRadius.radius, style: .continuous))
                    // A sample progress stripe, matching a Continue-Watching card, so the radius/width
                    // preview reads as a real poster rather than a bare rectangle.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.4))
                            Rectangle().fill(Theme.Palette.accent).frame(width: geo.size.width * 0.4)
                        }
                    }
                    .frame(width: width, height: 4)
                }
                .frame(width: width, height: height)
                if !prefs.hidePosterLabels {
                    Text("Sample Title")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1).frame(width: width, alignment: .leading)
                }
            }
            Text(previewCaption)
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.vertical, Theme.Space.md)
        .animation(.easeOut(duration: 0.2), value: prefs.posterWidth)
        .animation(.easeOut(duration: 0.2), value: prefs.posterRadius)
        .animation(.easeOut(duration: 0.2), value: prefs.landscapeCards)
        .animation(.easeOut(duration: 0.2), value: prefs.hidePosterLabels)
    }
}
