import SwiftUI

/// The user's Home-screen row layout: which of the "special" Home sections show, and in what order.
///
/// The Home is composed live from several sources (the Collections hub, Top Picks, Because-you-watched,
/// Trakt, media-server rails, imported-list rails, the engine catalog board, and on iOS the editorial
/// collections). Each of those is a stable *section* with a fixed identity key here, so the user can drag
/// them into a preferred order and hide the ones they never use. The order + hidden-set persist in
/// `UserDefaults` (global, like `CatalogPrefsStore`).
///
/// Deliberately OUT of scope:
///   - **Continue Watching** is pinned first and is not part of this set: it is a resume queue the user
///     steps through in recency order, not a browse surface, and the existing focus/hero seeding assumes
///     it leads. (Noted as a product choice; it can be folded in later if the owner wants.)
///   - Reordering / hiding an *individual* add-on catalog row is owned by `CatalogPreferences`
///     (`stremiox.catalog.order` / `.hidden`). This type moves the whole **Add-on Catalogs** block as one
///     section; the per-catalog order inside it stays with `CatalogPreferences`.
enum HomeRail: String, CaseIterable, Identifiable, Hashable {
    case collectionsHub
    case topPicks
    case becauseYouWatched
    case traktWatchlist
    case simklWatchlist
    case mediaServers
    case upcomingEpisodes
    case upcomingMovies
    case addonCatalogs
    case editorialCollections   // iOS/iPad/Mac only; never in the tvOS default set, so it never renders there
    case importedLists

    var id: String { rawValue }

    /// Editor label. Generic + stable (the live rail titles are dynamic: "Because you watched X",
    /// per-server / per-catalog names), so the editor shows one representative name per section.
    var title: LocalizedStringKey {
        switch self {
        case .collectionsHub:       return "Collections"
        case .topPicks:             return "Top Picks for you"
        case .becauseYouWatched:    return "Because You Watched"
        case .traktWatchlist:       return "Trakt Watchlist"
        case .simklWatchlist:       return "SIMKL Watchlist"
        case .mediaServers:         return "Media Servers"
        case .upcomingEpisodes:     return "Upcoming Episodes"
        case .upcomingMovies:       return "Upcoming Movies"
        case .addonCatalogs:        return "Add-on Catalogs"
        case .editorialCollections: return "Editorial Collections"
        case .importedLists:        return "Imported Lists"
        }
    }

    /// SF Symbol for the editor row.
    var systemImage: String {
        switch self {
        case .collectionsHub:       return "square.grid.2x2"
        case .topPicks:             return "sparkles"
        case .becauseYouWatched:    return "arrow.triangle.branch"
        case .traktWatchlist:       return "bookmark"
        case .simklWatchlist:       return "bookmark.square"
        case .mediaServers:         return "server.rack"
        case .upcomingEpisodes:     return "calendar.badge.clock"
        case .upcomingMovies:       return "film.stack"
        case .addonCatalogs:        return "rectangle.stack"
        case .editorialCollections: return "text.book.closed"
        case .importedLists:        return "list.bullet.rectangle"
        }
    }

    /// Default Home section order on touch/desktop (iPhone / iPad / Mac). Continue Watching is pinned
    /// above these. This MUST match `iOSHomeView`'s render order so an un-customized Home is byte-identical.
    static let iOSDefaultOrder: [HomeRail] = [
        .collectionsHub, .topPicks, .becauseYouWatched, .traktWatchlist, .simklWatchlist, .mediaServers,
        .upcomingEpisodes, .upcomingMovies, .addonCatalogs, .editorialCollections, .importedLists,
    ]

    /// Default Home section order on tvOS. Continue Watching is pinned above these; tvOS has no editorial
    /// rails and lists Imported before Upcoming. MUST match `HomeView`'s render order (zero default change).
    static let tvDefaultOrder: [HomeRail] = [
        .collectionsHub, .topPicks, .becauseYouWatched, .traktWatchlist, .simklWatchlist, .mediaServers,
        .importedLists, .upcomingEpisodes, .upcomingMovies, .addonCatalogs,
    ]
}

/// Plain `UserDefaults` accessors for the Home rail layout (mirrors `CatalogPrefsStore`). Global, not
/// per-profile: the Home layout is a device/personal chrome preference, like the poster-width / hub prefs.
enum HomeRailStore {
    static let orderKey = "vortx.home.railOrder"     // [String] rawValues, the user's explicit order
    static let hiddenKey = "vortx.home.railHidden"   // [String] rawValues the user has hidden

    static func order() -> [String] { UserDefaults.standard.stringArray(forKey: orderKey) ?? [] }
    static func hidden() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
    static func setOrder(_ keys: [String]) { UserDefaults.standard.set(keys, forKey: orderKey) }
    static func setHidden(_ keys: Set<String>) { UserDefaults.standard.set(Array(keys), forKey: hiddenKey) }
}

/// Observable Home rail layout, shared across every Home surface so a change in the editor republishes the
/// live Home immediately. Defaults (empty order, empty hidden) reproduce today's Home exactly, so there is
/// zero behavior change until the user customizes.
@MainActor
final class HomeRailPreferences: ObservableObject {
    static let shared = HomeRailPreferences()

    @Published private(set) var order: [String] = HomeRailStore.order()
    @Published private(set) var hidden: Set<String> = HomeRailStore.hidden()

    private init() {}

    /// Merge the saved order with the platform's default set: honor the saved positions for rails the
    /// platform knows about, then append any default rail not yet in the saved order at its default spot.
    /// This keeps an un-customized Home identical to the hard-coded order AND stays forward-compatible when
    /// a new rail ships (it slots into its default position) or when the saved order came from another
    /// surface with a different set (unknown rails are dropped, missing ones appended).
    func arrange(_ defaults: [HomeRail]) -> [HomeRail] {
        guard !order.isEmpty else { return defaults }
        let allowed = Set(defaults)
        var result = order.compactMap(HomeRail.init(rawValue:)).filter { allowed.contains($0) }
        var seen = Set(result)
        for rail in defaults where !seen.contains(rail) {
            result.append(rail)
            seen.insert(rail)
        }
        return result
    }

    func isHidden(_ rail: HomeRail) -> Bool { hidden.contains(rail.rawValue) }

    func setHidden(_ rail: HomeRail, _ value: Bool) {
        if value { hidden.insert(rail.rawValue) } else { hidden.remove(rail.rawValue) }
        HomeRailStore.setHidden(hidden)
    }

    /// Persist an explicit full order (the editors pass the whole arranged list).
    func setOrder(_ rails: [HomeRail]) {
        order = rails.map(\.rawValue)
        HomeRailStore.setOrder(order)
    }

    /// iOS/Mac `List.onMove`: reorder the arranged list and persist.
    func moveRails(fromOffsets: IndexSet, toOffset: Int, defaults: [HomeRail]) {
        var arranged = arrange(defaults)
        arranged.move(fromOffsets: fromOffsets, toOffset: toOffset)
        setOrder(arranged)
    }

    /// tvOS up/down: swap a rail with its neighbour and persist.
    func moveUp(_ rail: HomeRail, defaults: [HomeRail]) {
        var arranged = arrange(defaults)
        guard let i = arranged.firstIndex(of: rail), i > 0 else { return }
        arranged.swapAt(i, i - 1)
        setOrder(arranged)
    }

    func moveDown(_ rail: HomeRail, defaults: [HomeRail]) {
        var arranged = arrange(defaults)
        guard let i = arranged.firstIndex(of: rail), i < arranged.count - 1 else { return }
        arranged.swapAt(i, i + 1)
        setOrder(arranged)
    }

    /// Back to the shipped order with nothing hidden.
    func reset() {
        order = []
        hidden = []
        HomeRailStore.setOrder(order)
        HomeRailStore.setHidden(hidden)
    }
}
