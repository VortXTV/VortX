import SwiftUI

/// The "Collections" hub: a compact band high on Home (and Discover) of category TILES that open a
/// full browse grid. Three sections, in this order (owner spec):
///   1. Discover  - four cinematic gradient cards: Trending, Popular, Latest, Upcoming.
///   2. Streaming - one logo tile per streaming service available in-region (TMDB watch providers).
///   3. Genres    - one tile per genre (incl. the special Anime / K-drama-friendly handling).
/// Tapping any tile opens `CategoryBrowse*` (per platform) which renders SUB-CATALOG pills over a grid,
/// e.g. a service opens Movies / Shows / New Movies / New Shows / Top This Week/Month/Year / Trending.
/// Every card in those grids is a Cinemeta `tt` `MetaPreview`, so it plays through the engine like any
/// other card. Needs a TMDB key (the hub hides without one); content is live, the provider list is cached
/// and refreshed on the chosen cadence.

// MARK: - Discover cards

/// The four cinematic Discover cards. Order here is the on-screen order (owner: Trending, Popular,
/// Latest, Upcoming). Each is a gradient tile with an SF Symbol + title + subtitle, not a content poster.
enum DiscoverList: String, CaseIterable, Hashable {
    case trending, popular, latest, upcoming

    var title: String {
        switch self {
        case .trending: return "Trending"
        case .popular:  return "Popular"
        case .latest:   return "Latest"
        case .upcoming: return "Upcoming"
        }
    }
    var subtitle: String {
        switch self {
        case .trending: return "What's hot right now"
        case .popular:  return "Most popular movies and shows"
        case .latest:   return "New movies and episodes"
        case .upcoming: return "Coming soon to theaters and TV"
        }
    }
    var symbol: String {
        switch self {
        case .trending: return "flame.fill"
        case .popular:  return "star.fill"
        case .latest:   return "clock.fill"
        case .upcoming: return "calendar"
        }
    }
    /// Warm-neutral surface gradient: the four cards are distinguished by their symbol + an accent STEP, not
    /// by hue, so the hub reads as VortX's own dark-ember identity rather than the rainbow-card reference.
    var gradient: [Color] { [Theme.Palette.surface2, Theme.Palette.surface1] }
    /// Accent intensity that separates the four cards without colour (trending strongest -> upcoming softest).
    var accentOpacity: Double {
        switch self {
        case .trending: return 1.0
        case .popular:  return 0.78
        case .latest:   return 0.58
        case .upcoming: return 0.42
        }
    }
    /// The primary TMDB movie list path used to resolve this card's representative backdrop. Mirrors the
    /// first (movie) sub-catalog in `discoverSubs` so the card art matches what it opens.
    var backdropListPath: String {
        switch self {
        case .trending: return "/trending/movie/week"
        case .popular:  return "/movie/popular"
        case .latest:   return "/movie/now_playing"
        case .upcoming: return "/movie/upcoming"
        }
    }
}

// MARK: - Genres

/// A genre tile. TMDB has no "Anime" genre, so Anime carries a keyword (anime, 210024) on top of the
/// Animation genre; Documentary is genre 99. A nil `tvGenreID` means movies-only for that genre's TV bucket.
struct GenreSpec: Hashable {
    let title: String
    let symbol: String
    /// Hue 0...1 for the tile's tint, kept as a value (not a `Color`) so `HubTarget` stays trivially Hashable.
    let hue: Double
    let movieGenreID: Int?
    let tvGenreID: Int?
    let keyword: Int?
    let originLang: String?

    init(_ title: String, _ symbol: String, hue: Double, movie: Int?, tv: Int?, keyword: Int? = nil, lang: String? = nil) {
        self.title = title; self.symbol = symbol; self.hue = hue
        self.movieGenreID = movie; self.tvGenreID = tv; self.keyword = keyword; self.originLang = lang
    }

    var tint: Color { Theme.Palette.accent }   // ember accent, not a per-genre rainbow hue (VortX identity)
}

// MARK: - Hub target (what a tile points at)

/// What a tapped tile opens. Hashable + self-describing so the iOS `NavigationStack(path:)` can push it and
/// rebuild the destination's sub-catalogs from the value alone (no closure-in-route, no loader registry).
enum HubTarget: Hashable {
    case discover(DiscoverList)
    case service(id: Int, name: String)
    case genre(GenreSpec)

    var title: String {
        switch self {
        case .discover(let l): return l.title
        case .service(_, let name): return name
        case .genre(let g): return g.title
        }
    }
}

// MARK: - Sub-catalogs

/// One sub-catalog pill in a browse screen: a title and a paginated, engine-resolved loader. The loader is
/// a closure (not data) so nothing fetches until the pill is selected, and each page is live.
struct SubCatalog: Identifiable {
    let id: String
    let title: String
    let load: (_ page: Int) async -> [MetaPreview]
}

/// Builds the sub-catalog pills for a hub target. All loaders resolve to engine-playable `tt` previews via
/// TMDBClient and fail soft to []. The Movies/Shows/New/Top/Trending vocabulary is shared across services
/// and genres; the Discover cards use the native trending/popular/now-playing/upcoming list endpoints.
enum CollectionsCatalog {
    static func subCatalogs(for target: HubTarget, region: String) -> [SubCatalog] {
        switch target {
        case .discover(let list): return discoverSubs(list, region: region)
        case .service(let id, _): return scopedSubs(movieScope: providerScope(id), tvScope: providerScope(id), region: region)
        case .genre(let g):       return scopedSubs(movieScope: genreScope(g, media: "movie"), tvScope: genreScope(g, media: "tv"), region: region)
        }
    }

    // MARK: scope fragments

    private static func providerScope(_ id: Int) -> String? {
        "with_watch_providers=\(id)&with_watch_monetization_types=flatrate"
    }

    /// nil when the genre has nothing to filter that media on (e.g. a movies-only genre's TV bucket), so the
    /// merged loader simply skips that media instead of returning the whole unfiltered catalog.
    private static func genreScope(_ g: GenreSpec, media: String) -> String? {
        var parts: [String] = []
        if let kw = g.keyword { parts.append("with_keywords=\(kw)") }
        if let gid = (media == "tv" ? g.tvGenreID : g.movieGenreID) { parts.append("with_genres=\(gid)") }
        if let lang = g.originLang { parts.append("with_original_language=\(lang)") }
        return parts.isEmpty ? nil : parts.joined(separator: "&")
    }

    // MARK: the shared Movies/Shows/New/Top/Trending set (services + genres)

    private static func scopedSubs(movieScope: String?, tvScope: String?, region: String) -> [SubCatalog] {
        let today = TMDBClient.isoDate(daysAgo: 0)
        func sub(_ id: String, _ title: String, movieExtra: ((String) -> String)?, tvExtra: ((String) -> String)?) -> SubCatalog {
            SubCatalog(id: id, title: title, load: { page in
                await mergedDiscover(
                    movie: movieScope.flatMap { s in movieExtra.map { $0(s) } },
                    tv:    tvScope.flatMap   { s in tvExtra.map   { $0(s) } },
                    region: region, page: page)
            })
        }
        // vote_count thresholds scale with the window: TMDB votes accrue slowly, so a 7-day window with a
        // high floor returns almost nothing (esp. intersected with a provider). Lower floor for shorter windows.
        func top(_ id: String, _ title: String, days: Int, minVotes: Int) -> SubCatalog {
            let from = TMDBClient.isoDate(daysAgo: days)
            return sub(id, title,
                       movieExtra: { "\($0)&sort_by=popularity.desc&primary_release_date.gte=\(from)&primary_release_date.lte=\(today)&vote_count.gte=\(minVotes)" },
                       tvExtra:    { "\($0)&sort_by=popularity.desc&first_air_date.gte=\(from)&first_air_date.lte=\(today)&vote_count.gte=\(minVotes)" })
        }
        return [
            sub("movies", "Movies", movieExtra: { "\($0)&sort_by=popularity.desc" }, tvExtra: nil),
            sub("shows", "Shows", movieExtra: nil, tvExtra: { "\($0)&sort_by=popularity.desc" }),
            sub("newmovies", "New Movies",
                movieExtra: { "\($0)&sort_by=primary_release_date.desc&primary_release_date.lte=\(today)&vote_count.gte=5" }, tvExtra: nil),
            sub("newshows", "New Shows",
                movieExtra: nil, tvExtra: { "\($0)&sort_by=first_air_date.desc&first_air_date.lte=\(today)&vote_count.gte=5" }),
            top("topweek", "Top This Week", days: 7, minVotes: 3),
            top("topmonth", "Top This Month", days: 30, minVotes: 8),
            top("topyear", "Top This Year", days: 365, minVotes: 10),
            sub("trending", "Trending",
                movieExtra: { "\($0)&sort_by=popularity.desc" }, tvExtra: { "\($0)&sort_by=popularity.desc" }),
        ]
    }

    // MARK: Discover-card sub-catalogs (native list endpoints + recent/upcoming discover)

    private static func discoverSubs(_ list: DiscoverList, region: String) -> [SubCatalog] {
        let today = TMDBClient.isoDate(daysAgo: 0)
        func listSub(_ id: String, _ title: String, _ path: String) -> SubCatalog {
            SubCatalog(id: id, title: title, load: { page in await TMDBClient.listTitles(path: path, region: region, page: page) })
        }
        func discoverSub(_ id: String, _ title: String, media: String, extra: String) -> SubCatalog {
            SubCatalog(id: id, title: title, load: { page in await TMDBClient.discoverTitles(media: media, extra: extra, region: region, page: page) })
        }
        switch list {
        case .trending:
            return [listSub("movies", "Movies", "/trending/movie/week"), listSub("shows", "Shows", "/trending/tv/week")]
        case .popular:
            return [listSub("movies", "Movies", "/movie/popular"), listSub("shows", "Shows", "/tv/popular")]
        case .latest:
            return [listSub("movies", "Movies", "/movie/now_playing"),
                    discoverSub("shows", "Shows", media: "tv", extra: "sort_by=first_air_date.desc&first_air_date.lte=\(today)&vote_count.gte=5")]
        case .upcoming:
            return [listSub("movies", "Movies", "/movie/upcoming"),
                    discoverSub("shows", "Shows", media: "tv", extra: "sort_by=first_air_date.asc&first_air_date.gte=\(today)")]
        }
    }

    // MARK: merge helper

    /// Fetch the movie + TV buckets (skipping a nil bucket) and interleave, de-duplicating by id.
    private static func mergedDiscover(movie: String?, tv: String?, region: String, page: Int) async -> [MetaPreview] {
        async let m: [MetaPreview] = { if let e = movie { return await TMDBClient.discoverTitles(media: "movie", extra: e, region: region, page: page) } else { return [] } }()
        async let t: [MetaPreview] = { if let e = tv { return await TMDBClient.discoverTitles(media: "tv", extra: e, region: region, page: page) } else { return [] } }()
        let movies = await m, shows = await t
        var out: [MetaPreview] = []
        var seen = Set<String>()
        for i in 0..<max(movies.count, shows.count) {
            if i < movies.count, seen.insert(movies[i].id).inserted { out.append(movies[i]) }
            if i < shows.count, seen.insert(shows[i].id).inserted { out.append(shows[i]) }
        }
        return out
    }
}

// MARK: - Refresh cadence

/// How often the cached pieces of the hub (the region provider list) refresh. Content grids are always
/// live; this throttles the slow-changing provider list. Default: daily.
enum HubRefreshCadence: String, CaseIterable, Identifiable {
    case daily, twiceDaily, fourTimesDaily
    var id: String { rawValue }
    var title: String {
        switch self {
        case .daily: return "Daily"
        case .twiceDaily: return "Twice daily"
        case .fourTimesDaily: return "4x daily"
        }
    }
    var interval: TimeInterval {
        switch self {
        case .daily: return 86_400
        case .twiceDaily: return 43_200
        case .fourTimesDaily: return 21_600
        }
    }
    static var current: HubRefreshCadence {
        HubRefreshCadence(rawValue: UserDefaults.standard.string(forKey: "vortx.collections.refreshCadence") ?? "daily") ?? .daily
    }
}

// MARK: - Model

/// Drives the hub: the static Discover + Genre tiles, plus the region-aware streaming-service tiles
/// (TMDB watch providers, cached + refreshed on the chosen cadence). Idempotent `load`, fail-soft.
@MainActor
final class CollectionsHubModel: ObservableObject {
    /// Shared instance so the Settings reorder screen and the live Home/Discover hubs all observe the SAME
    /// providers - reordering in Settings reflects immediately everywhere instead of only after relaunch.
    static let shared = CollectionsHubModel()

    @Published private(set) var providers: [TMDBClient.ProviderTile] = []
    /// Genre title -> representative backdrop URL, resolved + cached on the same cadence as the providers.
    /// Empty until resolved; the genre tiles fall back to their tint gradient for any title not yet present.
    @Published private(set) var genreBackdrops: [String: String] = [:]
    /// Discover card -> representative backdrop URL, resolved + cached on the same cadence as the genre tiles.
    /// Empty until resolved; the Discover cards fall back to their gradient for any card not yet present.
    @Published private(set) var discoverBackdrops: [DiscoverList: String] = [:]

    let discover = DiscoverList.allCases
    let genres = CollectionsHubModel.genreList

    private var loadedRegion: String?
    private var loadTask: Task<Void, Never>?
    private var genreTask: Task<Void, Never>?
    private var discoverTask: Task<Void, Never>?

    /// Available now: the keyless catalogs.vortx.tv edge serves the hub (Discover/services/genres) even with
    /// no user TMDB key, so the hub shows for everyone. A user key just routes straight to TMDB.
    /// Gated by the RemoteConfig fleet kill-switch `features.collectionsHub`: a remote `false` hides the hub
    /// fleet-wide (e.g. if the catalogs edge is down). Baked default true => absent/null remote is identical
    /// to shipping.
    static var isAvailable: Bool { RemoteConfig.snapshot.isFeatureOn("collectionsHub", default: true) }

    /// Load the provider tiles for the region. Uses the cadence-throttled cache: if a fresh cached list
    /// exists it is shown immediately and no network call is made; otherwise it fetches and re-caches.
    /// Idempotent for a region per app run.
    func load(region: String = TMDBClient.deviceRegion) {
        guard Self.isAvailable else { providers = []; genreBackdrops = [:]; discoverBackdrops = [:]; loadedRegion = nil; return }
        loadGenreBackdrops(region: region)      // independent cadence-cached resolve (runs even when providers are cache-fresh)
        loadDiscoverBackdrops(region: region)   // same independent cadence-cached resolve for the Discover cards
        guard loadTask == nil else { return }   // never run two fetches at once
        // Already loaded for this region AND the cache is still fresh -> nothing to do. (A stale cache for the
        // same region falls through so the cadence refresh actually fires; the old `loadedRegion != region`
        // guard blocked every refresh for the session after the first load.)
        if loadedRegion == region, Self.cacheIsFresh(region: region) { return }
        if let cached = Self.cachedProviders(region: region) {
            providers = Self.applyOrder(cached)
            loadedRegion = region
            if Self.cacheIsFresh(region: region) { return }   // fresh enough; skip the refetch
        }
        loadTask = Task { [weak self] in
            let fetched = await TMDBClient.regionProviders(region: region)
            guard let self, !Task.isCancelled else { return }
            self.loadTask = nil
            guard !fetched.isEmpty else { return }   // keep cache/old on an empty fetch
            self.providers = Self.applyOrder(fetched)
            self.loadedRegion = region
            Self.cacheProviders(fetched, region: region)
        }
    }

    func clear() {
        loadTask?.cancel(); loadTask = nil
        genreTask?.cancel(); genreTask = nil
        discoverTask?.cancel(); discoverTask = nil
        providers = []; genreBackdrops = [:]; discoverBackdrops = [:]; loadedRegion = nil
    }

    // MARK: genre backdrops (cadence-cached representative artwork per genre)

    /// Resolve a representative backdrop for each genre. Paints instantly from the region cache, then (if the
    /// cache is stale) refetches all genres in small 429-safe batches and re-caches. Independent of the
    /// provider load so a fresh provider cache never blocks the artwork refresh.
    private func loadGenreBackdrops(region: String) {
        if let cached = Self.cachedGenreBackdrops(region: region) { genreBackdrops = cached }
        if Self.genreCacheIsFresh(region: region) { return }
        guard genreTask == nil else { return }
        genreTask = Task { [weak self] in
            var out: [String: String] = [:]
            let genres = CollectionsHubModel.genreList
            let batchSize = 4   // cap concurrency: a once-daily op, kept gentle on TMDB to avoid 429s
            var i = 0
            while i < genres.count {
                let slice = Array(genres[i..<min(i + batchSize, genres.count)])
                await withTaskGroup(of: (String, String?).self) { group in
                    for g in slice {
                        group.addTask {
                            (g.title, await TMDBClient.genreBackdrop(movieGenre: g.movieGenreID, tvGenre: g.tvGenreID,
                                                                     keyword: g.keyword, lang: g.originLang, region: region))
                        }
                    }
                    for await (title, url) in group { if let url { out[title] = url } }
                }
                if Task.isCancelled { break }
                i += batchSize
            }
            guard let self, !Task.isCancelled, !out.isEmpty else { self?.genreTask = nil; return }
            self.genreBackdrops = out          // keep the prior cache on an all-empty fetch (don't blank the tiles)
            self.genreTask = nil
            Self.cacheGenreBackdrops(out, region: region)
        }
    }

    private static func genreCacheKey(_ region: String) -> String { "vortx.collections.genreBackdrops.\(region)" }
    private static func genreCacheAtKey(_ region: String) -> String { "vortx.collections.genreBackdropsAt.\(region)" }

    private static func cacheGenreBackdrops(_ map: [String: String], region: String) {
        UserDefaults.standard.set(map, forKey: genreCacheKey(region))
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: genreCacheAtKey(region))
    }
    private static func cachedGenreBackdrops(region: String) -> [String: String]? {
        let map = UserDefaults.standard.dictionary(forKey: genreCacheKey(region)) as? [String: String]
        return (map?.isEmpty == false) ? map : nil
    }
    private static func genreCacheIsFresh(region: String) -> Bool {
        let at = UserDefaults.standard.double(forKey: genreCacheAtKey(region))
        guard at > 0 else { return false }
        return Date().timeIntervalSince1970 - at < HubRefreshCadence.current.interval
    }

    // MARK: discover-card backdrops (cadence-cached representative artwork per Discover card)

    /// Resolve a representative backdrop for each Discover card. Paints instantly from the region cache, then
    /// (if stale) refetches all four cards in one 429-safe batch and re-caches. Independent of the provider /
    /// genre loads so a fresh cache for those never blocks the Discover artwork refresh. Direct mirror of
    /// `loadGenreBackdrops`.
    private func loadDiscoverBackdrops(region: String) {
        if let cached = Self.cachedDiscoverBackdrops(region: region) { discoverBackdrops = cached }
        if Self.discoverCacheIsFresh(region: region) { return }
        guard discoverTask == nil else { return }
        discoverTask = Task { [weak self] in
            var out: [DiscoverList: String] = [:]
            // Only four cards, so a single gentle task group is enough (no batching needed); kept 429-safe.
            await withTaskGroup(of: (DiscoverList, String?).self) { group in
                for card in DiscoverList.allCases {
                    group.addTask {
                        (card, await TMDBClient.listBackdrop(path: card.backdropListPath, region: region))
                    }
                }
                for await (card, url) in group { if let url { out[card] = url } }
            }
            guard let self, !Task.isCancelled, !out.isEmpty else { self?.discoverTask = nil; return }
            self.discoverBackdrops = out       // keep the prior cache on an all-empty fetch (don't blank the tiles)
            self.discoverTask = nil
            Self.cacheDiscoverBackdrops(out, region: region)
        }
    }

    private static func discoverCacheKey(_ region: String) -> String { "vortx.collections.discoverBackdrops.\(region)" }
    private static func discoverCacheAtKey(_ region: String) -> String { "vortx.collections.discoverBackdropsAt.\(region)" }

    private static func cacheDiscoverBackdrops(_ map: [DiscoverList: String], region: String) {
        // Persist with the raw-value string keys (UserDefaults can't hold enum keys).
        let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(raw, forKey: discoverCacheKey(region))
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: discoverCacheAtKey(region))
    }
    private static func cachedDiscoverBackdrops(region: String) -> [DiscoverList: String]? {
        guard let raw = UserDefaults.standard.dictionary(forKey: discoverCacheKey(region)) as? [String: String],
              !raw.isEmpty else { return nil }
        let map = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value -> (DiscoverList, String)? in
            guard let card = DiscoverList(rawValue: key) else { return nil }
            return (card, value)
        })
        return map.isEmpty ? nil : map
    }
    private static func discoverCacheIsFresh(region: String) -> Bool {
        let at = UserDefaults.standard.double(forKey: discoverCacheAtKey(region))
        guard at > 0 else { return false }
        return Date().timeIntervalSince1970 - at < HubRefreshCadence.current.interval
    }

    // MARK: provider cache (UserDefaults, region-keyed, cadence-throttled)

    private static func cacheKey(_ region: String) -> String { "vortx.collections.providers.\(region)" }
    private static func cacheAtKey(_ region: String) -> String { "vortx.collections.providersAt.\(region)" }

    private static func cacheProviders(_ tiles: [TMDBClient.ProviderTile], region: String) {
        let rows = tiles.map { ["id": $0.providerID, "name": $0.name, "logo": $0.logoPath ?? ""] as [String: Any] }
        UserDefaults.standard.set(rows, forKey: cacheKey(region))
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheAtKey(region))
    }
    private static func cachedProviders(region: String) -> [TMDBClient.ProviderTile]? {
        guard let rows = UserDefaults.standard.array(forKey: cacheKey(region)) as? [[String: Any]], !rows.isEmpty else { return nil }
        return rows.compactMap { r in
            guard let id = r["id"] as? Int, let name = r["name"] as? String else { return nil }
            let logo = (r["logo"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return TMDBClient.ProviderTile(providerID: id, name: name, logoPath: logo)
        }
    }
    private static func cacheIsFresh(region: String) -> Bool {
        let at = UserDefaults.standard.double(forKey: cacheAtKey(region))
        guard at > 0 else { return false }
        return Date().timeIntervalSince1970 - at < HubRefreshCadence.current.interval
    }

    // MARK: user reorder (the owner's "Prime first, Netflix last")

    private static let orderKey = "vortx.collections.providerOrder"

    static func customOrder() -> [Int] { (UserDefaults.standard.array(forKey: orderKey) as? [Int]) ?? [] }

    /// Re-sort the region/featured tiles by the user's explicit order: pinned ids first in their saved order,
    /// any provider the user hasn't placed yet keeps its incoming (region/featured) position after them.
    static func applyOrder(_ tiles: [TMDBClient.ProviderTile]) -> [TMDBClient.ProviderTile] {
        let order = customOrder()
        guard !order.isEmpty else { return tiles }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return tiles.enumerated().sorted { a, b in
            let ra = rank[a.element.providerID] ?? (100_000 + a.offset)
            let rb = rank[b.element.providerID] ?? (100_000 + b.offset)
            return ra < rb
        }.map(\.element)
    }

    /// Persist a new explicit order (the reorder screen passes the full id list) and re-sort the live tiles.
    func reorder(to ids: [Int]) {
        UserDefaults.standard.set(ids, forKey: Self.orderKey)
        providers = Self.applyOrder(providers)
    }

    // MARK: genre tiles (incl. Anime keyword + Documentary)

    static let genreList: [GenreSpec] = [
        GenreSpec("Action", "flame.fill", hue: 0.02, movie: 28, tv: 10759),
        GenreSpec("Comedy", "face.smiling.fill", hue: 0.12, movie: 35, tv: 35),
        GenreSpec("Drama", "theatermasks.fill", hue: 0.58, movie: 18, tv: 18),
        GenreSpec("Thriller", "bolt.fill", hue: 0.72, movie: 53, tv: nil),
        GenreSpec("Sci-Fi", "sparkles", hue: 0.55, movie: 878, tv: 10765),
        GenreSpec("Horror", "moon.stars.fill", hue: 0.0, movie: 27, tv: nil),
        GenreSpec("Animation", "scribble.variable", hue: 0.33, movie: 16, tv: 16),
        GenreSpec("Anime", "star.circle.fill", hue: 0.85, movie: 16, tv: 16, keyword: 210024),
        GenreSpec("K-Drama", "quote.bubble.fill", hue: 0.93, movie: 18, tv: 18, lang: "ko"),
        GenreSpec("Documentary", "film.fill", hue: 0.48, movie: 99, tv: 99),
        GenreSpec("Romance", "heart.fill", hue: 0.95, movie: 10749, tv: nil),
        GenreSpec("Adventure", "map.fill", hue: 0.09, movie: 12, tv: 10759),
        GenreSpec("Family", "person.3.fill", hue: 0.41, movie: 10751, tv: 10751),
        GenreSpec("Fantasy", "wand.and.stars", hue: 0.78, movie: 14, tv: 10765),
        GenreSpec("Mystery", "magnifyingglass", hue: 0.64, movie: 9648, tv: 9648),
        GenreSpec("Crime", "exclamationmark.triangle.fill", hue: 0.06, movie: 80, tv: 80),
    ]
}
