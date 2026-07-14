import SwiftUI

/// "Recently added on <server>": Home/Discover rails of the newest movies and shows on the user's connected
/// media servers (Plex / Jellyfin / Emby), rendered as ordinary catalog cards that open the normal detail page
/// by IMDb id. The media-server analog of `TraktRailsModel`: client-side only, ZERO engine writes, poster and
/// name resolved through Cinemeta (so the art matches the rest of the app and no server token rides in an image
/// URL), items without an IMDb-resolvable id skipped in v1 (the detail page is provider-id keyed).
///
/// DORMANT with no server (ledger-18): `refresh` returns before any network when the store is empty, and the
/// heavy fetch + JSON decode run in a `nonisolated static` off the main actor (the PR #128 flowOn discipline:
/// never parse library-sized responses on the main thread). Throttled to a 30 min TTL plus manual refresh.
@MainActor
final class MediaServerCatalogsModel: ObservableObject {
    /// One rail per (server, kind). `id` is stable so SwiftUI diffing is cheap.
    struct Rail: Identifiable, Equatable {
        let id: String
        let title: String
        let items: [MetaPreview]
    }

    /// The rails to render, newest-server-first. Empty hides them.
    @Published private(set) var rails: [Rail] = []

    private static let maxItems = 25
    private static let refreshInterval: TimeInterval = 30 * 60
    private var lastRefresh: Date?
    private var loadTask: Task<Void, Never>?

    /// The per-server auth snapshot the off-main fetch needs, captured on the main actor (Keychain read here).
    private struct ServerAuth: Sendable {
        let id: UUID
        let kind: MediaServerKind
        let name: String
        let base: String
        let token: String
        let userId: String
    }

    /// Pull "recently added" for each connected server and resolve cards, at most once per `refreshInterval`.
    /// No-op (and clears) when no server is connected, leaving the rails hidden.
    func refresh() {
        let servers = MediaServerStore.shared.servers
        guard !servers.isEmpty else { if !rails.isEmpty { rails = [] }; return }   // DORMANCY: no server -> no network
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.refreshInterval, !rails.isEmpty { return }
        guard loadTask == nil else { return }
        // Capture auth on the main actor (Keychain reads here), then hand value types to the off-main fetch.
        let auth: [ServerAuth] = servers.compactMap { r in
            guard let base = r.urls.first, let token = MediaServerStore.shared.token(for: r.id), !token.isEmpty else { return nil }
            return ServerAuth(id: r.id, kind: r.kind, name: r.name, base: base, token: token, userId: r.userId)
        }
        guard !auth.isEmpty else { if !rails.isEmpty { rails = [] }; return }
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            let built = await Self.fetchAll(auth)
            guard let self, !Task.isCancelled else { return }
            self.lastRefresh = Date()
            if !built.isEmpty { self.rails = built }   // keep the prior rails on an empty/flaky fetch
        }
    }

    func clear() {
        loadTask?.cancel(); loadTask = nil
        rails = []; lastRefresh = nil
    }

    // MARK: Off-main fetch (nonisolated: JSON decode never touches the main thread)

    private nonisolated static func fetchAll(_ auth: [ServerAuth]) async -> [Rail] {
        var out: [Rail] = []
        for a in auth {
            let (movieSeeds, showSeeds) = await recentlyAdded(a)
            if let rail = await rail(server: a, kind: "movie", seeds: movieSeeds, suffix: "Movies") { out.append(rail) }
            if let rail = await rail(server: a, kind: "series", seeds: showSeeds, suffix: "Shows") { out.append(rail) }
        }
        return out
    }

    /// Resolve one rail's seeds to Cinemeta cards; nil when nothing resolved (so the rail is hidden).
    private nonisolated static func rail(server a: ServerAuth, kind: String,
                                         seeds: [(imdb: String, title: String)], suffix: String) async -> Rail? {
        guard !seeds.isEmpty else { return nil }
        let capped = Array(seeds.prefix(maxItems))
        let resolved: [(Int, MetaPreview)] = await withTaskGroup(of: (Int, MetaPreview?).self) { group in
            for (i, seed) in capped.enumerated() {
                group.addTask { (i, await cinemetaPreview(imdb: seed.imdb, type: kind, fallbackTitle: seed.title)) }
            }
            var acc: [(Int, MetaPreview)] = []
            for await (i, p) in group { if let p { acc.append((i, p)) } }
            return acc
        }
        let items = resolved.sorted { $0.0 < $1.0 }.map(\.1)
        guard !items.isEmpty else { return nil }
        return Rail(id: "mediaserver:\(a.id.uuidString):\(kind)",
                    title: "Recently added on \(a.name) · \(suffix)", items: items)
    }

    /// Fetch (movies, shows) recently-added seeds for one server. Fail-soft: any error yields empty lists.
    private nonisolated static func recentlyAdded(_ a: ServerAuth) async -> (movies: [(imdb: String, title: String)], shows: [(imdb: String, title: String)]) {
        switch a.kind {
        case .plex:            return await plexRecentlyAdded(a)
        case .jellyfin, .emby: return await jellyfinRecentlyAdded(a)
        }
    }

    // MARK: Jellyfin / Emby

    private nonisolated static func jellyfinRecentlyAdded(_ a: ServerAuth) async -> (movies: [(imdb: String, title: String)], shows: [(imdb: String, title: String)]) {
        async let movies = jellyfinLatest(a, includeType: "Movie")
        async let shows = jellyfinLatest(a, includeType: "Series")
        return await (movies, shows)
    }

    private nonisolated static func jellyfinLatest(_ a: ServerAuth, includeType: String) async -> [(imdb: String, title: String)] {
        guard !a.userId.isEmpty, var comps = URLComponents(string: "\(a.base)/Users/\(a.userId)/Items/Latest") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: includeType),
            URLQueryItem(name: "Fields", value: "ProviderIds"),
            URLQueryItem(name: "Limit", value: String(maxItems)),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue(a.token, forHTTPHeaderField: "X-Emby-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Latest returns a bare array of items.
        struct Item: Decodable {
            let name: String?; let providerIds: [String: String]?
            enum CodingKeys: String, CodingKey { case name = "Name", providerIds = "ProviderIds" }
            var imdb: String? { providerIds?.first(where: { $0.key.lowercased() == "imdb" })?.value }
        }
        guard let (data, response) = try? await session().data(for: req),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true,
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items.compactMap { item in item.imdb.map { ($0, item.name ?? "") } }
    }

    // MARK: Plex

    private nonisolated static func plexRecentlyAdded(_ a: ServerAuth) async -> (movies: [(imdb: String, title: String)], shows: [(imdb: String, title: String)]) {
        guard var comps = URLComponents(string: "\(a.base)/library/recentlyAdded") else { return ([], []) }
        comps.queryItems = [URLQueryItem(name: "includeGuids", value: "1"),
                            URLQueryItem(name: "X-Plex-Token", value: a.token)]
        guard let url = comps.url else { return ([], []) }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        struct Container: Decodable { let mediaContainer: MC?
            enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" } }
        struct MC: Decodable { let metadata: [M]?
            enum CodingKeys: String, CodingKey { case metadata = "Metadata" } }
        struct M: Decodable { let title: String?; let type: String?; let guid: [G]?
            enum CodingKeys: String, CodingKey { case title, type, guid = "Guid" } }
        struct G: Decodable { let id: String? }
        guard let (data, response) = try? await session().data(for: req),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true,
              let decoded = try? JSONDecoder().decode(Container.self, from: data) else { return ([], []) }
        var movies: [(String, String)] = []
        var shows: [(String, String)] = []
        for m in decoded.mediaContainer?.metadata ?? [] {
            guard let imdb = (m.guid ?? []).compactMap({ $0.id }).first(where: { $0.hasPrefix("imdb://") })?
                .replacingOccurrences(of: "imdb://", with: "") else { continue }
            let entry = (imdb, m.title ?? "")
            if m.type == "movie" { movies.append(entry) }
            else if m.type == "show" || m.type == "season" || m.type == "episode" { shows.append(entry) }
        }
        return (movies, shows)
    }

    // MARK: Shared helpers

    private nonisolated static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        return URLSession(configuration: cfg)
    }

    /// Resolve one title to a `MetaPreview` (poster + name) via Cinemeta, mirroring `TraktRailsModel`. A miss
    /// falls back to a poster-less preview so the title still lists (the card shows its gradient).
    private nonisolated static func cinemetaPreview(imdb: String, type: String, fallbackTitle: String) async -> MetaPreview? {
        let safeType = (type == "series") ? "series" : "movie"
        guard imdb.hasPrefix("tt"), let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(safeType)/\(imdb).json"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = obj["meta"] as? [String: Any] else {
            guard imdb.hasPrefix("tt"), !fallbackTitle.isEmpty else { return nil }
            return MetaPreview(id: imdb, type: safeType, name: fallbackTitle, poster: nil, posterShape: nil, popularity: nil)
        }
        let name = (meta["name"] as? String) ?? fallbackTitle
        guard !name.isEmpty else { return nil }
        return MetaPreview(id: imdb, type: safeType, name: name,
                           poster: meta["poster"] as? String, posterShape: nil, popularity: nil)
    }
}
