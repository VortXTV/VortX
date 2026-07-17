import SwiftUI

/// Per-device catalog customization (#0.3.8 add-on manager): which catalog rows show on Home and in
/// what order. Keyed by the same `base|type|id` string CoreBridge.catalogKey builds. The read helpers
/// are plain static UserDefaults reads so `buildBoardRows` can call them off the main actor; the
/// ObservableObject drives the editor UI and asks CoreBridge to rebuild the board on a change.
/// Poster-card WIDTH presets for the iOS/iPad/Mac catalog grids. Each maps to a point width; `.balanced`
/// is the shipping default so nothing changes unless the user opts in. Wider presets show larger, fewer
/// cards; narrower presets pack more per row. The grid recomputes its adaptive column count from the same
/// width, so the responsive layout stays correct at every size class.
enum PosterWidthPreset: String, CaseIterable, Identifiable {
    case compact, dense, standard, balanced, comfort, large
    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact:  return "Compact"
        case .dense:    return "Dense"
        case .standard: return "Standard"
        case .balanced: return "Balanced"
        case .comfort:  return "Comfort"
        case .large:    return "Large"
        }
    }

    /// The card/track width in points on a REGULAR width class (iPad / Mac), tuned so `.balanced` equals
    /// today's `iOSPillMetrics.cardWidth` (224) — the shipping look. The compact-iPhone widths are derived
    /// separately (`compactWidth`) so a phone still fits ~3 across at the default.
    var regularWidth: CGFloat {
        switch self {
        case .compact:  return 150
        case .dense:    return 180
        case .standard: return 204
        case .balanced: return 224
        case .comfort:  return 260
        case .large:    return 320
        }
    }

    /// The card/track width in points on tvOS. The `regularWidth` ladder is tuned for iPad/Mac (`.balanced`
    /// = 224); tvOS posters sit on the `kPosterWidth` = 200 baseline, so each preset scales `regularWidth` by
    /// 200/224. This keeps the SAME relative ladder while landing the 10-foot grid at its shipping proportions.
    var tvWidth: CGFloat {
        (regularWidth * 200.0 / 224.0).rounded()
    }

    /// The card/track width in points on a COMPACT width class (iPhone portrait). The default `.balanced`
    /// lands at 168 so the movie/show poster grid shows ~2 across, matching the size of the Streaming Services
    /// and Discover category tiles (which are viewport-2-up on a phone). The old 3-across default (116) made the
    /// poster cards read smaller than those tiles; the whole compact ladder is shifted up so `.balanced` is the
    /// big 2-up default while `.compact`/`.dense`/`.standard` still offer the tighter 3-across look. Regular
    /// (iPad/Mac `regularWidth`) and tvOS (`tvWidth`) are unchanged, so only the phone default grows.
    var compactWidth: CGFloat {
        switch self {
        case .compact:  return 110
        case .dense:    return 130
        case .standard: return 148
        case .balanced: return 168
        case .comfort:  return 186
        case .large:    return 200
        }
    }
}

/// Poster-card CORNER RADIUS presets. `.rounded` is the shipping default (matches `Theme.Radius.card`, 16pt)
/// so nothing changes unless the user opts in. Applied to the poster image clip in `PosterCardiOS`.
enum PosterRadiusPreset: String, CaseIterable, Identifiable {
    case sharp, subtle, classic, rounded, pill
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sharp:   return "Sharp"
        case .subtle:  return "Subtle"
        case .classic: return "Classic"
        case .rounded: return "Rounded"
        case .pill:    return "Pill"
        }
    }

    /// The corner radius in points. `.rounded` (16) equals `Theme.Radius.card`, the shipping value. `.pill`
    /// uses a large radius that reads as a fully rounded end on the poster's short edge.
    var radius: CGFloat {
        switch self {
        case .sharp:   return 0
        case .subtle:  return 6
        case .classic: return 10
        case .rounded: return 16
        case .pill:    return 28
        }
    }
}

/// How the tvOS Home renders its add-on catalog sections (#105). `.rails` is the shipping default
/// (horizontal rows); `.wall` stacks each catalog as a vertical-scrolling poster grid under the same
/// section header, so browsing a catalog reads like a full poster wall instead of a sideways rail.
/// Continue Watching always stays a rail (it is a queue, not a browse surface), whichever mode is on.
enum HomeLayoutPreset: String, CaseIterable, Identifiable {
    case rails, wall
    var id: String { rawValue }

    var label: String {
        switch self {
        case .rails: return "Rails"
        case .wall:  return "Poster wall"
        }
    }
}

/// A Discover HUB category the user can permanently hide (Discover cards, streaming services as a group, or
/// a single genre). Distinct from `CatalogPrefsStore.hidden`, which hides an ADD-ON catalog row on Home. The
/// hub filters these out when it lays out its tiles, and the region-ordering leaves the rest untouched.
/// Persisted as an opaque string key per tile so the set survives a genre-list change without stale ids.
enum HubCategoryKey {
    /// One of the four Discover cards, e.g. `discover:trending`.
    static func discover(_ list: DiscoverList) -> String { "discover:\(list.rawValue)" }
    /// A single genre tile, keyed by its stable title, e.g. `genre:Anime`.
    static func genre(_ g: GenreSpec) -> String { "genre:\(g.title)" }
    /// The whole Streaming-Services section (one switch to hide every service tile).
    static let streamingSection = "section:streaming"
    /// The whole Discover-cards section.
    static let discoverSection = "section:discover"
    /// The whole Genres section.
    static let genresSection = "section:genres"
    /// A single decade tile, keyed by its start year, e.g. `decade:1990`.
    static func decade(_ d: DecadeSpec) -> String { "decade:\(d.startYear)" }
    /// The whole Decades section.
    static let decadesSection = "section:decades"
}

enum CatalogPrefsStore {
    static let hiddenKey = "stremiox.catalog.hidden"
    static let orderKey = "stremiox.catalog.order"
    static let landscapeKey = "stremiox.catalog.landscapeCards"
    static let widthKey = "stremiox.catalog.posterWidthPreset"
    static let radiusKey = "stremiox.catalog.posterRadiusPreset"
    static let hideLabelsKey = "stremiox.catalog.hidePosterLabels"
    static let hiddenCategoriesKey = "vortx.discover.hiddenCategories"
    static let regionKey = "vortx.discover.regionPreference"   // "" / absent = follow the device region
    static let homeLayoutKey = "vortx.home.layout"   // tvOS Home: "rails" (default) | "wall" (#105)
    static let filtersKey = "vortx.discover.filters"   // advanced Discover filter set (JSON, absent = none)

    static func hidden() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
    static func order() -> [String] { UserDefaults.standard.stringArray(forKey: orderKey) ?? [] }

    /// Discover-hub categories the user has permanently hidden (see `HubCategoryKey`). Read as a plain static
    /// so the hub can filter off the main actor. Empty by default => every tile shows (today's behavior).
    static func hiddenCategories() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: hiddenCategoriesKey) ?? []) }
    static func isCategoryHidden(_ key: String) -> Bool { hiddenCategories().contains(key) }
    static func setCategoryHidden(_ key: String, _ value: Bool) {
        var h = hiddenCategories()
        if value { h.insert(key) } else { h.remove(key) }
        UserDefaults.standard.set(Array(h), forKey: hiddenCategoriesKey)
    }

    /// The user's explicit region override (ISO 3166-1 alpha-2, e.g. "GB"), or nil to follow the device
    /// region. Uppercased on read so a stored lowercase value still matches TMDB's region form.
    static func regionOverride() -> String? {
        let v = (UserDefaults.standard.string(forKey: regionKey) ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v.uppercased()
    }
    static func setRegionOverride(_ code: String?) {
        if let code, !code.isEmpty { UserDefaults.standard.set(code.uppercased(), forKey: regionKey) }
        else { UserDefaults.standard.removeObject(forKey: regionKey) }
    }

    /// The user's advanced Discover filter set (genre include/exclude, year window, age rating, runtime,
    /// season count, upcoming-only), decoded from JSON. Absent / undecodable => `.empty`, so a default
    /// install filters nothing. Plain static so the Discover view can read it without touching the actor.
    static func discoverFilters() -> DiscoverFilters {
        guard let data = UserDefaults.standard.data(forKey: filtersKey),
              let decoded = try? JSONDecoder().decode(DiscoverFilters.self, from: data) else { return .empty }
        return decoded
    }
    /// Persist the filter set. An inactive (empty) set removes the key so a default install stores nothing.
    static func setDiscoverFilters(_ filters: DiscoverFilters) {
        guard filters.isActive, let data = try? JSONEncoder().encode(filters) else {
            UserDefaults.standard.removeObject(forKey: filtersKey); return
        }
        UserDefaults.standard.set(data, forKey: filtersKey)
    }

    /// Poster width preset (default `.balanced` = today's look). Read as a plain static so card/grid views
    /// can size off the main actor.
    static func widthPreset() -> PosterWidthPreset {
        // No stored key => `.balanced`, the shipping default the doc comments + iOS describe. This is the ONE
        // shared source for both iOS and tvOS, so the fallback fixes both defaults at once. `.balanced.tvWidth`
        // == 200 == kPosterWidth (the historical tvOS proportion); the old `.large` fell back to 286pt/320pt.
        (UserDefaults.standard.string(forKey: widthKey)).flatMap(PosterWidthPreset.init(rawValue:)) ?? .balanced
    }
    static func setWidthPreset(_ p: PosterWidthPreset) { UserDefaults.standard.set(p.rawValue, forKey: widthKey) }

    /// Poster corner-radius preset (default `.rounded` = today's look).
    static func radiusPreset() -> PosterRadiusPreset {
        (UserDefaults.standard.string(forKey: radiusKey)).flatMap(PosterRadiusPreset.init(rawValue:)) ?? .rounded
    }
    static func setRadiusPreset(_ p: PosterRadiusPreset) { UserDefaults.standard.set(p.rawValue, forKey: radiusKey) }

    /// Hide the title label under each poster (default false = labels shown, today's look).
    static func hideLabels() -> Bool { UserDefaults.standard.bool(forKey: hideLabelsKey) }
    static func setHideLabels(_ value: Bool) { UserDefaults.standard.set(value, forKey: hideLabelsKey) }

    /// tvOS Home catalog layout (#105). No stored key => `.rails`, the shipping horizontal rows, so
    /// nothing changes unless the user opts into the poster wall.
    static func homeLayout() -> HomeLayoutPreset {
        (UserDefaults.standard.string(forKey: homeLayoutKey)).flatMap(HomeLayoutPreset.init(rawValue:)) ?? .rails
    }
    static func setHomeLayout(_ p: HomeLayoutPreset) { UserDefaults.standard.set(p.rawValue, forKey: homeLayoutKey) }
    /// Cinematic landscape (16:9) catalog cards vs the legacy portrait (2:3) posters. Defaults to ON
    /// (the key unset reads true), so a fresh install gets the cinematic look; the Appearance toggle
    /// lets anyone fall back to portrait. Read as a plain static so card views can size off-main.
    static func landscapeCards() -> Bool {
        UserDefaults.standard.object(forKey: landscapeKey) == nil ? true : UserDefaults.standard.bool(forKey: landscapeKey)
    }
    static func setLandscapeCards(_ value: Bool) { UserDefaults.standard.set(value, forKey: landscapeKey) }
    static func isHidden(_ key: String) -> Bool { hidden().contains(key) }
    /// Position in the user's order, or `.max` so unlisted catalogs keep the engine's relative order after the listed ones.
    static func rank(_ key: String) -> Int { order().firstIndex(of: key) ?? Int.max }

    static func setHidden(_ key: String, _ value: Bool) {
        var h = hidden()
        if value { h.insert(key) } else { h.remove(key) }
        UserDefaults.standard.set(Array(h), forKey: hiddenKey)
    }
    static func setOrder(_ keys: [String]) { UserDefaults.standard.set(keys, forKey: orderKey) }
}

@MainActor
final class CatalogPreferences: ObservableObject {
    static let shared = CatalogPreferences()
    @Published private(set) var hidden: Set<String> = CatalogPrefsStore.hidden()
    @Published private(set) var order: [String] = CatalogPrefsStore.order()
    /// Drives whether catalog cards render as cinematic 16:9 landscape pills (TMDB backdrop) or
    /// legacy portrait posters. Two-way bound by the Appearance toggle; persists on change.
    @Published var landscapeCards: Bool = CatalogPrefsStore.landscapeCards() {
        didSet { CatalogPrefsStore.setLandscapeCards(landscapeCards) }
    }
    /// Poster-card width preset for the iOS/iPad/Mac catalog grids + rails. Default `.balanced` = today's
    /// look. Two-way bound by the Poster Style settings; the grid + cards read it so a change re-lays out live.
    @Published var posterWidth: PosterWidthPreset = CatalogPrefsStore.widthPreset() {
        didSet { CatalogPrefsStore.setWidthPreset(posterWidth) }
    }
    /// Poster-card corner-radius preset. Default `.rounded` = today's look (Theme.Radius.card).
    @Published var posterRadius: PosterRadiusPreset = CatalogPrefsStore.radiusPreset() {
        didSet { CatalogPrefsStore.setRadiusPreset(posterRadius) }
    }
    /// Hide the title label under each poster. Default false = labels shown (today's look).
    @Published var hidePosterLabels: Bool = CatalogPrefsStore.hideLabels() {
        didSet { CatalogPrefsStore.setHideLabels(hidePosterLabels) }
    }
    /// tvOS Home catalog layout (#105): horizontal rails (default) or a vertical poster wall per catalog.
    /// Two-way bound by the tvOS Poster Style screen; HomeView reads it so a change re-lays out live.
    @Published var homeLayout: HomeLayoutPreset = CatalogPrefsStore.homeLayout() {
        didSet { CatalogPrefsStore.setHomeLayout(homeLayout) }
    }
    /// Discover-hub categories the user has permanently hidden (see `HubCategoryKey`). The hub filters these
    /// off its tiles. Not `didSet`-persisted; mutated through `setCategoryHidden` so the write + republish + a
    /// hub refresh stay together. Empty by default => every tile shows.
    @Published private(set) var hiddenCategories: Set<String> = CatalogPrefsStore.hiddenCategories()
    /// The user's Discover region override (ISO 3166-1 alpha-2), or nil to follow the device region. Drives
    /// `TMDBClient.deviceRegion` so every hub content path (services, sub-catalogs, region ordering) follows
    /// it. Persisted + republished so the hub re-loads for the new region on change.
    @Published var regionOverride: String? = CatalogPrefsStore.regionOverride() {
        didSet {
            guard oldValue != regionOverride else { return }
            CatalogPrefsStore.setRegionOverride(regionOverride)
            // Region changed: reload the hub (providers/backdrops are region-keyed) so tiles reflect it.
            CollectionsHubModel.shared.load()
        }
    }
    /// The user's advanced Discover filters, applied client-side over the loaded Discover previews. Empty by
    /// default so Discover is unchanged until a filter is set. Two-way bound by the Discover filter panel;
    /// persists on change (an empty set clears the stored key).
    @Published var discoverFilters: DiscoverFilters = CatalogPrefsStore.discoverFilters() {
        didSet {
            guard oldValue != discoverFilters else { return }
            CatalogPrefsStore.setDiscoverFilters(discoverFilters)
        }
    }
    private init() {}

    /// Re-read every persisted catalog/appearance preference. These properties are seeded ONLY at init, so an
    /// account settings pull or a backup restore (direct `UserDefaults` writes, and `UserDefaults` KVO does
    /// not fire for the dotted keys behind `CatalogPrefsStore`) leaves the singleton on the pre-restore values.
    ///
    /// `landscapeCards` ... `discoverFilters` each re-persist themselves in `didSet`, so leaving them stale
    /// means the next Appearance/Poster-Style/Discover-filter change flushes the whole stale set back over the
    /// restored one. Re-read first so a later write can only build on the restored value. `hidden` / `order` /
    /// `hiddenCategories` are mutated through the store (read-modify-write against `UserDefaults`), so those
    /// carry only the stale-display half of the bug; they are re-read here for the same live-repaint reason.
    ///
    /// Guarded per property so an unchanged value never churns `objectWillChange` (and, for `regionOverride`,
    /// never fires a redundant hub reload). Call on the main thread.
    func reloadFromDefaults() {
        let savedHidden = CatalogPrefsStore.hidden()
        if hidden != savedHidden { hidden = savedHidden }
        let savedOrder = CatalogPrefsStore.order()
        if order != savedOrder { order = savedOrder }
        let savedCategories = CatalogPrefsStore.hiddenCategories()
        if hiddenCategories != savedCategories { hiddenCategories = savedCategories }
        let savedLandscape = CatalogPrefsStore.landscapeCards()
        if landscapeCards != savedLandscape { landscapeCards = savedLandscape }
        let savedWidth = CatalogPrefsStore.widthPreset()
        if posterWidth != savedWidth { posterWidth = savedWidth }
        let savedRadius = CatalogPrefsStore.radiusPreset()
        if posterRadius != savedRadius { posterRadius = savedRadius }
        let savedHideLabels = CatalogPrefsStore.hideLabels()
        if hidePosterLabels != savedHideLabels { hidePosterLabels = savedHideLabels }
        let savedLayout = CatalogPrefsStore.homeLayout()
        if homeLayout != savedLayout { homeLayout = savedLayout }
        let savedRegion = CatalogPrefsStore.regionOverride()
        if regionOverride != savedRegion { regionOverride = savedRegion }
        let savedFilters = CatalogPrefsStore.discoverFilters()
        if discoverFilters != savedFilters { discoverFilters = savedFilters }
    }

    func isHidden(_ key: String) -> Bool { hidden.contains(key) }

    /// Whether a Discover-hub category (a card, a genre, or a whole section) is hidden.
    func isCategoryHidden(_ key: String) -> Bool { hiddenCategories.contains(key) }

    /// Show/hide a Discover-hub category and republish so the live hub re-lays out immediately.
    func setCategoryHidden(_ key: String, _ value: Bool) {
        CatalogPrefsStore.setCategoryHidden(key, value)
        hiddenCategories = CatalogPrefsStore.hiddenCategories()
    }

    func setHidden(_ key: String, _ value: Bool) {
        CatalogPrefsStore.setHidden(key, value)
        hidden = CatalogPrefsStore.hidden()
        CoreBridge.shared.rebuildBoardRows()
    }

    /// Move a catalog up/down within the full ordered list (rebuilds the persisted order from `keys`).
    func reorder(_ keys: [String]) {
        order = keys
        CatalogPrefsStore.setOrder(keys)
        CoreBridge.shared.rebuildBoardRows()
    }
}

/// Editor: every catalog the installed add-ons provide, with a show/hide toggle and move up/down
/// (cross-platform; tvOS has no drag-to-reorder, so explicit buttons work on every target).
struct CatalogManagerView: View {
    @EnvironmentObject private var core: CoreBridge
    @ObservedObject private var prefs = CatalogPreferences.shared

    private var ordered: [CoreBridge.CatalogInfo] {
        // Fall back to the LIVE Home order (boardRows) when the user hasn't set an explicit order, so the
        // editor reflects how catalogs currently appear instead of an arbitrary alphabetical list (Bug 10).
        var boardIndex: [String: Int] = [:]
        for (i, row) in core.boardRows.enumerated() where boardIndex[row.id] == nil { boardIndex[row.id] = i }
        return core.allCatalogs.sorted { a, b in
            let ra = CatalogPrefsStore.rank(a.key), rb = CatalogPrefsStore.rank(b.key)
            if ra != rb { return ra < rb }
            let ba = boardIndex[a.key] ?? Int.max, bb = boardIndex[b.key] ?? Int.max
            if ba != bb { return ba < bb }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    var body: some View {
        #if os(tvOS)
        scrollBody   // focus-driven; reorder via the buttons (no drag gesture on tvOS)
        #else
        listBody     // iPhone / iPad / Mac: drag-to-reorder + the buttons
        #endif
    }

    /// Header shared by both layouts: title, blurb, and the group-by-add-on shortcut.
    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Customize catalogs")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Choose which rows appear on Home and the order they show in.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            if !ordered.isEmpty {
                // One-tap: group every add-on's catalogs together, in add-on (priority) order.
                Button { groupByAddonOrder() } label: {
                    Label("Group by add-on order", systemImage: "rectangle.3.group")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                .fixedSize()
            }
        }
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header
                let items = ordered
                if items.isEmpty {
                    Text("No catalogs yet. Install an add-on that provides catalogs first.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                ForEach(Array(items.enumerated()), id: \.element.key) { index, info in
                    row(info, index: index, total: items.count, keys: items.map(\.key))
                }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    #if !os(tvOS)
    /// A List so rows can be DRAG-reordered (macOS drags directly; iPhone/iPad use the Edit button). The
    /// per-row move buttons stay as a fallback and for move-to-top/bottom. `.onMove` rewrites the order.
    private var listBody: some View {
        let items = ordered
        return List {
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            if items.isEmpty {
                Text("No catalogs yet. Install an add-on that provides catalogs first.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.key) { index, info in
                    row(info, index: index, total: items.count, keys: items.map(\.key))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: Theme.Space.screenInset, bottom: 4, trailing: Theme.Space.screenInset))
                }
                .onMove { source, dest in
                    var keys = items.map(\.key)
                    keys.move(fromOffsets: source, toOffset: dest)
                    prefs.reorder(keys)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }
    #endif

    @ViewBuilder
    private func row(_ info: CoreBridge.CatalogInfo, index: Int, total: Int, keys: [String]) -> some View {
        let isHidden = prefs.isHidden(info.key)
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(isHidden ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(info.addonName)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.sm)
            // Move to top -> up -> down -> bottom, then the show/hide eye. Send-to-top / send-to-bottom
            // are the fast path on a long catalog list (and the only practical reorder on Apple TV).
            Button { move(keys, from: index, to: 0) } label: { Image(systemName: "arrow.up.to.line") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .disabled(index == 0)
            Button { move(keys, from: index, to: index - 1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .disabled(index == 0)
            Button { move(keys, from: index, to: index + 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .disabled(index == total - 1)
            Button { move(keys, from: index, to: total - 1) } label: { Image(systemName: "arrow.down.to.line") }
                .buttonStyle(ChipButtonStyle(selected: false))
                .disabled(index == total - 1)
            Button { prefs.setHidden(info.key, !isHidden) } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
            }
            .buttonStyle(ChipButtonStyle(selected: !isHidden))
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func move(_ keys: [String], from: Int, to: Int) {
        guard to >= 0, to < keys.count else { return }
        var next = keys
        let item = next.remove(at: from)
        next.insert(item, at: to)
        prefs.reorder(next)
    }

    /// Reorder every catalog grouped by its add-on, in the add-on (priority) order, so each add-on's
    /// catalogs sit together. Catalogs of an add-on not currently installed keep their relative order at
    /// the end. (Owner request: rearrange catalogs based on add-on order.)
    private func groupByAddonOrder() {
        var addonIndex: [String: Int] = [:]
        for (i, addon) in core.addons.enumerated() { addonIndex[addon.transportUrl] = i }
        let sorted = ordered.enumerated().sorted { a, b in
            let ia = addonIndex[Self.base(of: a.element.key)] ?? Int.max
            let ib = addonIndex[Self.base(of: b.element.key)] ?? Int.max
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map(\.element.key)
        prefs.reorder(sorted)
    }

    /// The add-on transport URL embedded in a catalog key (`base|type|id`).
    private static func base(of key: String) -> String {
        key.components(separatedBy: "|").first ?? key
    }
}

/// A small curated set of common regions for the Discover region picker (ISO 3166-1 alpha-2 + a display
/// label). Not exhaustive: the device-region default already covers everyone; this is a convenience for the
/// most common overrides. The label is localized by the OS region name where possible, else the fixed name.
/// Shared (SourcesShared) so both the iOS and tvOS Discover settings screens use the same list.
enum DiscoverRegions {
    struct Region: Hashable { let code: String; let label: String }

    static let common: [Region] = codes.map { code, fallback in
        Region(code: code, label: Locale.current.localizedString(forRegionCode: code) ?? fallback)
    }

    private static let codes: [(String, String)] = [
        ("US", "United States"), ("GB", "United Kingdom"), ("CA", "Canada"), ("AU", "Australia"),
        ("IE", "Ireland"), ("IN", "India"), ("DE", "Germany"), ("FR", "France"), ("ES", "Spain"),
        ("IT", "Italy"), ("PT", "Portugal"), ("BR", "Brazil"), ("MX", "Mexico"), ("AR", "Argentina"),
        ("NL", "Netherlands"), ("BE", "Belgium"), ("SE", "Sweden"), ("NO", "Norway"), ("DK", "Denmark"),
        ("FI", "Finland"), ("PL", "Poland"), ("RU", "Russia"), ("UA", "Ukraine"), ("TR", "Turkey"),
        ("JP", "Japan"), ("KR", "South Korea"), ("CN", "China"), ("TW", "Taiwan"), ("HK", "Hong Kong"),
        ("ID", "Indonesia"), ("PH", "Philippines"), ("TH", "Thailand"), ("VN", "Vietnam"), ("MY", "Malaysia"),
        ("SA", "Saudi Arabia"), ("AE", "United Arab Emirates"), ("EG", "Egypt"), ("ZA", "South Africa"),
        ("NG", "Nigeria"), ("KE", "Kenya"), ("IL", "Israel"), ("GR", "Greece"), ("CZ", "Czechia"),
        ("RO", "Romania"), ("HU", "Hungary"), ("CH", "Switzerland"), ("AT", "Austria"), ("NZ", "New Zealand"),
    ]
}

// MARK: - Discover advanced filters

/// The user's advanced Discover filter set, applied client-side over the loaded catalog previews and
/// persisted so it survives relaunch: genre include/exclude, a release-year window, age ratings, a runtime
/// window, a season-count window (series), and an upcoming-only switch. Every field is optional / empty by
/// default, so a fresh install filters nothing and Discover looks exactly as before.
///
/// Matching is intentionally FIELD-PRESENT only (see `matches`): a filter narrows the items that actually
/// carry its field and leaves items missing that field untouched, because catalog previews are sparse
/// (Cinemeta carries genres + year in `links`; runtime / certification / season count usually arrive only on
/// the detail meta). This keeps the filters honest instead of hiding everything a preview cannot describe.
/// Genres are matched case-insensitively; the stored keys are the canonical option labels the panel shows.
struct DiscoverFilters: Codable, Equatable {
    var includedGenres: Set<String> = []
    var excludedGenres: Set<String> = []
    var minYear: Int? = nil
    var maxYear: Int? = nil
    var ageRatings: Set<String> = []
    var minMinutes: Int? = nil
    var maxMinutes: Int? = nil
    var minSeasons: Int? = nil
    var maxSeasons: Int? = nil
    var upcomingOnly: Bool = false

    static let empty = DiscoverFilters()

    var isActive: Bool { activeCount > 0 }

    /// Count of the distinct active filter groups, for the toolbar badge and the summary line.
    var activeCount: Int {
        var n = 0
        if !includedGenres.isEmpty { n += 1 }
        if !excludedGenres.isEmpty { n += 1 }
        if minYear != nil || maxYear != nil { n += 1 }
        if !ageRatings.isEmpty { n += 1 }
        if minMinutes != nil || maxMinutes != nil { n += 1 }
        if minSeasons != nil || maxSeasons != nil { n += 1 }
        if upcomingOnly { n += 1 }
        return n
    }

    /// Tri-state genre helpers: a chip cycles Off -> Include -> Exclude -> Off.
    enum GenreState: Equatable { case off, include, exclude }
    func genreState(_ g: String) -> GenreState {
        if includedGenres.contains(g) { return .include }
        if excludedGenres.contains(g) { return .exclude }
        return .off
    }
    mutating func cycleGenre(_ g: String) {
        switch genreState(g) {
        case .off:     includedGenres.insert(g)
        case .include: includedGenres.remove(g); excludedGenres.insert(g)
        case .exclude: excludedGenres.remove(g)
        }
    }
}

/// Static option catalogs for the Discover filter panel: age ratings, decade windows, runtime + season
/// buckets, and a curated anime-genre supplement. Shared (SourcesShared) so tvOS and the later iOS pass render
/// the same set from one source.
enum DiscoverFilterOptions {
    /// Common movie + TV certifications. Matching is best-effort: previews rarely carry a certification, so
    /// this narrows only the items that do (see `DiscoverFilters`).
    static let ageRatings: [String] = ["G", "PG", "PG-13", "R", "NC-17", "TV-Y", "TV-G", "TV-PG", "TV-14", "TV-MA"]

    /// A release-year window presented as a decade chip. Selecting several spans their union (min start ..
    /// max end), which is what the panel writes into `minYear` / `maxYear`.
    struct Decade: Identifiable, Hashable { let label: String; let start: Int; let end: Int; var id: Int { start } }
    static let decades: [Decade] = [
        Decade(label: "2020s", start: 2020, end: 2029),
        Decade(label: "2010s", start: 2010, end: 2019),
        Decade(label: "2000s", start: 2000, end: 2009),
        Decade(label: "1990s", start: 1990, end: 1999),
        Decade(label: "1980s", start: 1980, end: 1989),
        Decade(label: "1970s", start: 1970, end: 1979),
        Decade(label: "Older", start: 1900, end: 1969),
    ]

    /// A single-select min/max window. `nil` bound = open on that side.
    struct Bucket: Identifiable, Hashable { let label: String; let min: Int?; let max: Int?; var id: String { label } }
    /// Runtime windows in MINUTES.
    static let durationBuckets: [Bucket] = [
        Bucket(label: "Under 30m", min: nil, max: 29),
        Bucket(label: "30-60m", min: 30, max: 60),
        Bucket(label: "60-90m", min: 60, max: 90),
        Bucket(label: "90-120m", min: 90, max: 120),
        Bucket(label: "Over 2h", min: 121, max: nil),
    ]
    /// Season-count windows (series).
    static let seasonBuckets: [Bucket] = [
        Bucket(label: "1 season", min: 1, max: 1),
        Bucket(label: "2-3", min: 2, max: 3),
        Bucket(label: "4-6", min: 4, max: 6),
        Bucket(label: "7+", min: 7, max: nil),
    ]

    /// A curated anime-genre supplement surfaced when the current Discover catalog is anime, on TOP of the
    /// genres present in the loaded items and the engine's own genre extra.
    static let animeGenres: [String] = [
        "Shounen", "Shoujo", "Seinen", "Josei", "Isekai", "Mecha",
        "Slice of Life", "Iyashikei", "Ecchi", "Sports", "Supernatural", "Psychological",
    ]
}

// MARK: - Client-side filtering (shared by every Discover surface)

/// Preview-level fields the Discover filters read. Catalog previews are sparse, so year + genres are the
/// reliable ones (Cinemeta puts them in `links`); certification / runtime / season count are best-effort and
/// usually nil, which the field-present matching in `DiscoverFilters.matches` treats as "leave the item
/// alone." Lives in SourcesShared so tvOS Discover and the iOS Discover screen filter identically.
extension CoreMeta {
    /// The leading 4-digit year parsed from `releaseInfo` ("2021", "2019-2023", "2020-"), or nil.
    var releaseYear: Int? {
        guard let s = releaseInfo else { return nil }
        var digits = ""
        for ch in s {
            if ch.isNumber { digits.append(ch); if digits.count == 4 { break } }
            else if !digits.isEmpty { break }
        }
        guard digits.count == 4, let y = Int(digits), y > 1800, y < 2200 else { return nil }
        return y
    }
    /// Best-effort certification from a `links` rating category (some add-ons attach one); nil for most previews.
    var certificationLabel: String? {
        let cats: Set<String> = ["certification", "mpaa", "mpaa rating", "rated", "content rating", "age rating"]
        guard let name = (links ?? []).first(where: { cats.contains($0.category.lowercased()) })?.name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
    /// Best-effort runtime in minutes from a `links` runtime/duration category ("92 min", "1h 32m"); nil when absent.
    var previewRuntimeMinutes: Int? {
        guard let raw = (links ?? []).first(where: { ["runtime", "duration"].contains($0.category.lowercased()) })?.name else { return nil }
        var total = 0, matched = false
        let scanner = Scanner(string: raw.lowercased())
        scanner.charactersToBeSkipped = CharacterSet.alphanumerics.inverted
        while !scanner.isAtEnd {
            guard let n = scanner.scanInt(), n >= 0 else { break }
            let unit = scanner.scanCharacters(from: CharacterSet.lowercaseLetters) ?? ""
            total += unit.hasPrefix("h") ? n * 60 : n   // bare number or "min" -> minutes
            matched = true
        }
        return matched && total > 0 ? total : nil
    }
    /// Best-effort season count from a `links` "seasons" category; nil for previews (which carry no episodes).
    var previewSeasonCount: Int? {
        guard let raw = (links ?? []).first(where: { ["season", "seasons"].contains($0.category.lowercased()) })?.name else { return nil }
        let scanner = Scanner(string: raw)
        scanner.charactersToBeSkipped = CharacterSet.decimalDigits.inverted
        if let n = scanner.scanInt(), n > 0 { return n }
        return nil
    }
}

extension DiscoverFilters {
    /// Whether a catalog preview passes every active filter. FIELD-PRESENT semantics: a filter only narrows
    /// items that carry its field, so a sparse preview is never hidden by a field it does not describe.
    func matches(_ item: CoreMeta, currentYear: Int) -> Bool {
        // Genre include / exclude (case-insensitive), applied only to items that carry genres.
        let genres = (item.genres ?? []).map { $0.lowercased() }
        if !genres.isEmpty {
            if !includedGenres.isEmpty {
                let inc = Set(includedGenres.map { $0.lowercased() })
                if !genres.contains(where: inc.contains) { return false }   // none of the included genres present
            }
            if !excludedGenres.isEmpty {
                let exc = Set(excludedGenres.map { $0.lowercased() })
                if genres.contains(where: exc.contains) { return false }
            }
        }
        // Release-year window + upcoming-only, applied only to items with a parseable year.
        if let y = item.releaseYear {
            if let lo = minYear, y < lo { return false }
            if let hi = maxYear, y > hi { return false }
            if upcomingOnly, y < currentYear { return false }   // known-past titles drop; this year / future stay
        }
        // Age rating: narrows only items that carry a certification.
        if !ageRatings.isEmpty, let cert = item.certificationLabel,
           !ageRatings.contains(where: { $0.caseInsensitiveCompare(cert) == .orderedSame }) { return false }
        // Runtime window: narrows only items that carry a runtime.
        if let m = item.previewRuntimeMinutes {
            if let lo = minMinutes, m < lo { return false }
            if let hi = maxMinutes, m > hi { return false }
        }
        // Season-count window (series): narrows only items that carry a season count.
        if let s = item.previewSeasonCount {
            if let lo = minSeasons, s < lo { return false }
            if let hi = maxSeasons, s > hi { return false }
        }
        return true
    }
}

// MARK: - Imported list catalogs (paste a public list URL, browse it as a native row)

/// Which public list service a catalog came from. Drives the row's provider label and the re-fetch path
/// (see `ListImport` / `LetterboxdImportClient` / `MDBListClient`).
enum ImportedListProvider: String, Codable, Hashable {
    case letterboxd, mdblist, trakt

    var label: String {
        switch self {
        case .letterboxd: return "Letterboxd"
        case .mdblist:    return "MDBList"
        case .trakt:      return "Trakt"
        }
    }
}

/// One resolved title inside an imported list. The `id` is ALWAYS an engine-safe Stremio id (an IMDb `tt…`
/// id, or a `tmdb:…` id), never an app-private key, so tapping a card routes through the engine exactly like
/// an add-on catalog card. Persisted with its catalog so the row paints instantly on launch without
/// re-fetching the source list.
struct ImportedListItem: Codable, Hashable, Identifiable {
    let id: String        // engine-safe: "tt…" or "tmdb:…"
    let type: String      // "movie" | "series"
    let name: String
    let poster: String?   // metahub-by-tt or the source poster; nil is tolerated (card shows a labeled tile)

    /// Adapt to the same `MetaPreview` the add-on and curated Home rails render, so an imported row plugs into
    /// the identical poster-rail path with no new card view.
    var preview: MetaPreview {
        MetaPreview(id: id, type: type, name: name, poster: poster, posterShape: nil, popularity: nil)
    }
}

/// A named list a user imported from a public URL, stored on-device and rendered as a native Home row. It is
/// self-contained: `items` are already resolved to engine-safe ids, so a render never touches the account
/// library or writes a `libraryItem` document (invariant). `sourceURL` is kept only so the same list can be
/// refreshed or de-duplicated; it is never pushed into engine or account state.
struct ImportedListCatalog: Codable, Hashable, Identifiable {
    let id: String                    // "imported:<provider>:<user>:<slug>"
    var title: String
    let provider: ImportedListProvider
    let sourceURL: String
    var items: [ImportedListItem]
    var addedAt: Date
    /// True when these titles were only readable through a signed-in session with `provider` (a private or
    /// friends-only Trakt list). Such a row is scoped to the connection that produced it: disconnecting the
    /// service drops it (`ImportedCatalogs.removeConnectionScoped`), so one account's private list can never
    /// linger on-device into the next account that connects here, the same cross-account contamination rule
    /// `TraktSyncEngine.reset()` already enforces for the watched shadow set.
    ///
    /// Optional on purpose: blobs written before this field existed decode to nil, which reads as "public,
    /// never purge" and leaves every already-imported public row exactly as it was.
    var requiresConnection: Bool? = nil

    /// The row's cards, ready for the same poster-rail path the curated/add-on rows use.
    var previews: [MetaPreview] { items.map(\.preview) }
    var isEmpty: Bool { items.isEmpty }
}

/// On-device persistence for imported list catalogs (JSON in UserDefaults). Plain statics so a launch-time
/// read can build the rows off the main actor, mirroring `CatalogPrefsStore`.
enum ImportedCatalogsStore {
    static let key = "vortx.catalog.importedLists"
    /// Ceiling on stored lists, so the persisted blob (each list up to `ListImport.maxItems` small records)
    /// stays a bounded UserDefaults value.
    static let maxCatalogs = 50

    static func load() -> [ImportedListCatalog] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ImportedListCatalog].self, from: data) else { return [] }
        return decoded
    }

    static func save(_ catalogs: [ImportedListCatalog]) {
        let capped = Array(catalogs.prefix(maxCatalogs))
        guard let data = try? JSONEncoder().encode(capped) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// The registry the paste-URL screen and Home read. `register` adds or replaces a resolved catalog (built by
/// `ListImport.importList`); the Home render (a later pass) iterates `catalogs` and renders each
/// `catalog.previews` as one poster rail, the same shape `CuratedCollectionsModel.collections` uses.
@MainActor
final class ImportedCatalogs: ObservableObject {
    static let shared = ImportedCatalogs()
    @Published private(set) var catalogs: [ImportedListCatalog] = ImportedCatalogsStore.load()
    private init() {}

    /// Whether a list from this exact source URL is already imported (drives the paste screen's "already
    /// added" hint and lets it offer refresh instead of a duplicate).
    func contains(sourceURL: String) -> Bool { catalogs.contains { $0.sourceURL == sourceURL } }
    func catalog(withID id: String) -> ImportedListCatalog? { catalogs.first { $0.id == id } }

    /// Add or replace a resolved catalog, newest first. A re-import of the same list (same id or same source
    /// URL) replaces the existing row in place rather than duplicating it. Empty catalogs are rejected so a
    /// failed resolve never registers a blank row. Returns false when nothing was stored.
    @discardableResult
    func register(_ catalog: ImportedListCatalog) -> Bool {
        guard !catalog.isEmpty else { return false }
        var next = catalogs.filter { $0.id != catalog.id && $0.sourceURL != catalog.sourceURL }
        next.insert(catalog, at: 0)
        persist(next)
        return true
    }

    func remove(id: String) { persist(catalogs.filter { $0.id != id }) }

    /// Drop every row from `provider` whose titles were only readable while signed in to it (a private or
    /// friends-only list). Called on disconnect. Public rows from the same provider survive: they were
    /// readable without the connection and stay readable without it, so purging them would delete a browse
    /// row the user built for themselves. Returns the number of rows dropped (0 is the common case).
    @discardableResult
    func removeConnectionScoped(provider: ImportedListProvider) -> Int {
        let next = catalogs.filter { !($0.provider == provider && $0.requiresConnection == true) }
        let dropped = catalogs.count - next.count
        if dropped > 0 { persist(next) }
        return dropped
    }

    /// Rename an imported row (user-editable title). No-op when the id is unknown or the title is blank.
    func rename(id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        persist(catalogs.map { entry in
            guard entry.id == id else { return entry }
            var updated = entry
            updated.title = trimmed
            return updated
        })
    }

    /// Persist an explicit order (drag-to-reorder on the manager screen).
    func reorder(_ ordered: [ImportedListCatalog]) { persist(ordered) }

    private func persist(_ next: [ImportedListCatalog]) {
        catalogs = next
        ImportedCatalogsStore.save(next)
    }
}
