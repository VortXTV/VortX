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

    /// The card/track width in points on a COMPACT width class (iPhone portrait). `.balanced` equals today's
    /// `iOSPillMetrics.gridPosterWidthCompact` (116) so the default phone grid is byte-for-byte unchanged.
    var compactWidth: CGFloat {
        switch self {
        case .compact:  return 92
        case .dense:    return 104
        case .standard: return 110
        case .balanced: return 116
        case .comfort:  return 140
        case .large:    return 168
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

    /// Poster width preset (default `.balanced` = today's look). Read as a plain static so card/grid views
    /// can size off the main actor.
    static func widthPreset() -> PosterWidthPreset {
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
    private init() {}

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
