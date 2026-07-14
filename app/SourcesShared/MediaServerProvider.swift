import Foundation

/// Native in-client MEDIA-SERVER resolution: turn an IMDb id (or title+year) into a DIRECT, streamable
/// HTTPS URL from a personal media server the user runs (Jellyfin / Emby / Plex), so a title the user
/// already owns plays straight from their own box with no add-on. The credentials (server URL + API key +
/// user id) are INJECTED here; there is no Keychain/Settings surface yet. This mirrors `DebridResolver`
/// exactly: a `MediaServerProviding` protocol + per-service ACTOR conformers + a `@MainActor`
/// `MediaServerCoordinator`, built the same way so it slots into the play path later without reshaping.
///
/// UNWIRED GROUNDWORK. This file is the resolver ENGINE only: it takes an IMDb id / title and returns a
/// matched item with a playable URL. NOTHING calls it yet — exactly like `DebridResolver` was built and
/// left inert before the source-list/play-path wiring. Two deferred, owner-steered pieces are out of scope
/// here on purpose:
///   1. The play/`streamGroups()` integration. `streamGroups()` is SYNCHRONOUS and has 14+ callers;
///      surfacing async media-server hits in the unified stream list means making that path async across
///      all of them — a one-way-door refactor that must be owner-approved, not slipped in under this groundwork.
///   2. A Settings + Keychain credential surface (mirroring `DebridKeys`/`DebridKeysView`). Until that
///      lands, configs are passed in by the caller; `MediaServerCoordinator.reload(configs:)` is the seam.
///
/// API focus: JELLYFIN is implemented now. Emby shares almost the same REST surface (parameterize the host
/// header / auth scheme) and Plex differs (plex.tv token auth + a different item/stream API); both are left
/// as `// TODO` stubs in the `kind` switch, not implemented.

// MARK: - Value types

/// Which media-server product a config points at. Only `.jellyfin` is implemented in this groundwork.
enum MediaServerKind: String, Sendable, CaseIterable {
    case jellyfin, emby, plex
}

/// The injectable credentials for one media server. No Keychain/Settings wiring: the caller supplies these
/// (the future Settings surface will build `[MediaServerConfig]` from stored credentials, like `DebridKeys`).
/// `baseURL` is the server root the user pastes, e.g. `https://jelly.example.com` or `http://192.168.1.10:8096`.
struct MediaServerConfig: Sendable, Equatable {
    let kind: MediaServerKind
    let baseURL: String   // server root, no trailing path; scheme required (primary = urls.first)
    let apiKey: String    // Jellyfin/Emby API key (or Plex per-server access token)
    let userId: String    // the Jellyfin user whose library to search (empty = server-wide where allowed)
    /// Stable server identity (group ids, keychain accounts, sync merge key). Stamped on every hit so the
    /// source list can badge + dedup across configs. Defaulted so the groundwork's 4-arg init still compiles.
    let id: UUID
    /// User-facing badge ("Living Room Plex"), used as the hit's `serverName` and the source group's label.
    let displayName: String
    /// Ordered connection candidates. Plex returns several (local / remote / relay); Jellyfin & Emby have one.
    /// The provider tries them in order; `baseURL` is the primary (urls.first) for the single-URL path.
    let urls: [String]

    init(kind: MediaServerKind, baseURL: String, apiKey: String, userId: String,
         id: UUID = UUID(), displayName: String = "", urls: [String] = []) {
        self.kind = kind
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.userId = userId
        self.id = id
        self.displayName = displayName.isEmpty ? (URL(string: baseURL)?.host ?? kind.rawValue) : displayName
        self.urls = urls.isEmpty ? [baseURL] : urls
    }
}

/// A matched media-server item with its resolved direct-play URL. The `streamURL` is the static
/// direct-play endpoint (`?static=true`), i.e. the original file streamed without transcoding.
struct MediaServerHit: Sendable, Equatable {
    /// Which server this hit came from (so the UI can label / dedup across configs).
    let kind: MediaServerKind
    let itemId: String
    let name: String
    /// Stremio-style coarse type for the matched item: "movie" or "episode".
    let type: String
    /// Container/extension from the chosen MediaSource (e.g. "mkv", "mp4"), when the server reports it.
    let container: String?
    /// Vertical resolution from the chosen MediaSource's video stream (e.g. 1080, 2160), when reported.
    let resolution: Int?
    /// The playable direct-play URL (static stream of the original file).
    let streamURL: URL
    /// The originating server's stable id + display name (badging + source group identity).
    let serverId: UUID
    let serverName: String
    /// File size in bytes, when the server reports it (feeds the ranking size cap + display).
    let sizeBytes: Int64?
    /// The source file name, when the server reports it (feeds the quality parser: remux / HDR / codec tags).
    let fileName: String?
}

enum MediaServerError: Error, Equatable {
    case noServer
    case invalidConfig          // missing/garbage base URL or credentials
    case authFailed             // 401/403 from the server
    case notFound               // no item matched
    case providerError(String)  // network/decode/other server-reported failure
}

// MARK: - Protocol

/// A single media server's resolver. Actor-isolated: each owns its own `URLSession` and serial work, so
/// the coordinator can fan a query out across configured servers concurrently with Sendable captures.
protocol MediaServerProviding: Sendable {
    var kind: MediaServerKind { get }

    /// Find by IMDb id. For series, pass `season`/`episode` to resolve the SxEy episode item (the series is
    /// resolved first, then its child episode). Returns nil on a clean no-match; throws `MediaServerError`
    /// on auth/network failure.
    func findByImdb(_ ttId: String, season: Int?, episode: Int?) async throws -> MediaServerHit?

    /// Title+year fallback when no IMDb id is available (or it did not match). For series, `season`/`episode`
    /// resolve the episode within the matched series.
    func findByTitle(_ title: String, year: Int?, season: Int?, episode: Int?) async throws -> MediaServerHit?
}

// MARK: - Shared helpers

enum MediaServerResolve {
    /// Normalize a user-pasted base URL: trim, drop a trailing slash, require an http(s) scheme. Returns nil
    /// when it cannot be made into a usable root (so callers fail soft as `.invalidConfig`).
    static func normalizedBase(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", u.host != nil else { return nil }
        return s
    }

    /// Score a Jellyfin Episode item against a SxEy target using its `ParentIndexNumber` (season) and
    /// `IndexNumber` (episode). Exact match = 2; episode-only match (season unknown on the item) = 1;
    /// otherwise 0. Lets us pick the right episode when a series query returns the whole season.
    static func episodeMatchScore(parentIndex: Int?, index: Int?, season: Int, episode: Int) -> Int {
        guard let index, index == episode else { return 0 }
        if let parentIndex { return parentIndex == season ? 2 : 0 }
        return 1
    }
}

// MARK: - Jellyfin provider

/// Jellyfin native resolver. Base is the user's server root; auth via an API key sent as the
/// `Authorization: MediaBrowser Token="..."` header (Jellyfin's documented scheme; only `Token` is required
/// for API-key auth, the other fields are advisory client metadata). The direct file URL additionally carries
/// `?api_key=` because the player fetches it without our header.
///
/// Lookup: `GET /Items?Recursive=true&IncludeItemTypes=Movie,Episode&Fields=ProviderIds,Path,MediaSources&
/// AnyProviderIdEquals=imdb.{ttId}`. IMPORTANT: `AnyProviderIdEquals` is honored by the server but has a known
/// reliability bug where it can return the WHOLE library instead of the matched item, so we ALWAYS re-filter the
/// returned items client-side on `ProviderIds.Imdb == ttId` and never trust the server-side filter alone. For
/// series we resolve the SERIES by its IMDb id, then query its episodes (`ParentId` + `IncludeItemTypes=Episode`)
/// and pick the SxEy child by `ParentIndexNumber`/`IndexNumber`.
///
/// Stream URL: `GET /Videos/{itemId}/stream?static=true&mediaSourceId={id}&container={ext}&api_key={key}` — the
/// static direct-play endpoint (original file, no transcode). Resolution/container come from the item's first
/// `MediaSources` entry. NOTE: spec-derived + compile-verified, NOT live-verified (needs a real Jellyfin server);
/// inert until the play-path wiring calls it.
actor JellyfinProvider: MediaServerProviding {
    /// Jellyfin AND Emby share this REST surface (same `/Items` query, `AnyProviderIdEquals`, `/Videos/{id}/
    /// stream?static=true`, and `X-Emby-Token` auth), so ONE actor serves both: the coordinator builds it for
    /// `.jellyfin` and `.emby` alike and `kind` is taken from the config. This is the plan's "Jellyfin-family
    /// core" without a near-empty second file.
    nonisolated let kind: MediaServerKind
    private let base: String
    private let apiKey: String
    private let userId: String
    private let serverId: UUID
    private let serverName: String
    private let session: URLSession

    /// Builds nil from an unusable config so the coordinator can skip it. (The base is pre-normalized.)
    init?(config: MediaServerConfig) {
        guard config.kind == .jellyfin || config.kind == .emby,
              let base = MediaServerResolve.normalizedBase(config.baseURL),
              !config.apiKey.isEmpty else { return nil }
        self.kind = config.kind
        self.base = base
        self.apiKey = config.apiKey
        self.userId = config.userId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serverId = config.id
        self.serverName = config.displayName
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: cfg)
    }

    // MARK: Decodable shapes (only the fields we read)

    /// `GET /Items` envelope.
    private struct ItemsResponse: Decodable { let items: [Item]?; enum CodingKeys: String, CodingKey { case items = "Items" } }

    private struct Item: Decodable {
        let id: String
        let name: String?
        let type: String?               // "Movie", "Episode", "Series", ...
        let parentIndexNumber: Int?     // season number for an Episode
        let indexNumber: Int?           // episode number for an Episode
        let providerIds: [String: String]?
        let mediaSources: [MediaSource]?
        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", type = "Type"
            case parentIndexNumber = "ParentIndexNumber", indexNumber = "IndexNumber"
            case providerIds = "ProviderIds", mediaSources = "MediaSources"
        }

        /// A provider id by key, case-insensitively ("Imdb"/"Tmdb" are canonical; be lenient).
        func providerId(_ key: String) -> String? {
            guard let ids = providerIds else { return nil }
            for (k, v) in ids where k.lowercased() == key.lowercased() { return v }
            return nil
        }
        var imdbId: String? { providerId("imdb") }
    }

    /// Parse a VortX detail id into a Jellyfin `AnyProviderIdEquals` value + a client-side verifier. Supports
    /// imdb (`tt...`) and tmdb (`tmdb:123`). The verifier re-checks the returned item client-side because the
    /// `AnyProviderIdEquals` server filter has a known whole-library bug (never trust the server filter alone).
    private static func providerQuery(for id: String) -> (equals: String, verify: @Sendable (Item) -> Bool)? {
        let s = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("tt") { return ("imdb.\(s)", { $0.providerId("imdb") == s }) }
        if s.hasPrefix("tmdb:") {
            let n = String(s.dropFirst("tmdb:".count))
            guard !n.isEmpty else { return nil }
            return ("tmdb.\(n)", { $0.providerId("tmdb") == n })
        }
        return nil
    }

    private struct MediaSource: Decodable {
        let id: String?
        let container: String?
        let path: String?
        let size: Int64?
        let mediaStreams: [MediaStream]?
        enum CodingKeys: String, CodingKey {
            case id = "Id", container = "Container", path = "Path", size = "Size", mediaStreams = "MediaStreams"
        }
    }
    private struct MediaStream: Decodable {
        let type: String?   // "Video", "Audio", "Subtitle"
        let height: Int?
        enum CodingKeys: String, CodingKey { case type = "Type", height = "Height" }
    }

    // MARK: Lookup

    /// Find by a VortX provider id (imdb `tt...` or tmdb `tmdb:123`). The name is kept for the protocol; both
    /// schemes are supported so a tmdb-only detail page still resolves against a tmdb-tagged library.
    func findByImdb(_ ttId: String, season: Int?, episode: Int?) async throws -> MediaServerHit? {
        guard let q = Self.providerQuery(for: ttId) else { return nil }

        // Movie / standalone: query Movie+Episode by the provider id and keep only the real match.
        if season == nil || episode == nil {
            let items = try await queryItems([
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode"),
                URLQueryItem(name: "Fields", value: "ProviderIds,Path,MediaSources"),
                URLQueryItem(name: "AnyProviderIdEquals", value: q.equals),
                URLQueryItem(name: "Limit", value: "50"),
            ])
            guard let match = items.first(where: q.verify) else { return nil }
            return try hit(for: match)
        }

        // Series: resolve the SERIES by its provider id, then its SxEy episode child.
        let seriesItems = try await queryItems([
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Series"),
            URLQueryItem(name: "Fields", value: "ProviderIds"),
            URLQueryItem(name: "AnyProviderIdEquals", value: q.equals),
            URLQueryItem(name: "Limit", value: "50"),
        ])
        guard let series = seriesItems.first(where: q.verify) else { return nil }
        // `self.` disambiguates the episode(inSeries:season:episode:) method from the `episode` Int? param.
        return try await self.episode(inSeries: series.id, season: season!, episode: episode!)
    }

    func findByTitle(_ title: String, year: Int?, season: Int?, episode: Int?) async throws -> MediaServerHit? {
        let term = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }

        if season == nil || episode == nil {
            var q = [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie"),
                URLQueryItem(name: "Fields", value: "ProviderIds,Path,MediaSources"),
                URLQueryItem(name: "SearchTerm", value: term),
                URLQueryItem(name: "Limit", value: "20"),
            ]
            if let year { q.append(URLQueryItem(name: "Years", value: String(year))) }
            let items = try await queryItems(q)
            guard let match = items.first else { return nil }   // SearchTerm is server-ranked; take the top
            return try hit(for: match)
        }

        // Series by title -> SxEy episode.
        var q = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Series"),
            URLQueryItem(name: "Fields", value: "ProviderIds"),
            URLQueryItem(name: "SearchTerm", value: term),
            URLQueryItem(name: "Limit", value: "20"),
        ]
        if let year { q.append(URLQueryItem(name: "Years", value: String(year))) }
        let seriesItems = try await queryItems(q)
        guard let series = seriesItems.first else { return nil }
        return try await self.episode(inSeries: series.id, season: season!, episode: episode!)
    }

    /// Find the SxEy episode inside a resolved series and build its hit.
    private func episode(inSeries seriesId: String, season: Int, episode: Int) async throws -> MediaServerHit? {
        let items = try await queryItems([
            URLQueryItem(name: "ParentId", value: seriesId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Episode"),
            URLQueryItem(name: "Fields", value: "ProviderIds,Path,MediaSources"),
            URLQueryItem(name: "Limit", value: "1000"),
        ])
        let scored = items.compactMap { item -> (Item, Int)? in
            let s = MediaServerResolve.episodeMatchScore(parentIndex: item.parentIndexNumber,
                                                         index: item.indexNumber, season: season, episode: episode)
            return s > 0 ? (item, s) : nil
        }
        guard let best = scored.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        return try hit(for: best)
    }

    // MARK: Hit assembly

    /// Build a `MediaServerHit` from a matched item: read container/resolution off the first MediaSource and
    /// build the static direct-play URL.
    private func hit(for item: Item) throws -> MediaServerHit {
        let source = item.mediaSources?.first
        let container = source?.container
        let resolution = source?.mediaStreams?.first(where: { $0.type?.lowercased() == "video" })?.height
        guard let url = streamURL(itemId: item.id, mediaSourceId: source?.id, container: container) else {
            throw MediaServerError.providerError("bad stream url")
        }
        let coarseType = (item.type?.lowercased() == "episode") ? "episode" : "movie"
        // File name from the source Path (last component), so the quality parser sees remux / HDR / codec tags.
        let fileName = source?.path.map { ($0 as NSString).lastPathComponent }
        return MediaServerHit(kind: kind, itemId: item.id, name: item.name ?? item.id, type: coarseType,
                              container: container, resolution: resolution, streamURL: url,
                              serverId: serverId, serverName: serverName, sizeBytes: source?.size, fileName: fileName)
    }

    /// `GET /Videos/{itemId}/stream?static=true[&mediaSourceId=][&container=]&api_key=` — static direct play.
    private func streamURL(itemId: String, mediaSourceId: String?, container: String?) -> URL? {
        guard var comps = URLComponents(string: "\(base)/Videos/\(itemId)/stream") else { return nil }
        var q = [URLQueryItem(name: "static", value: "true")]
        if let mediaSourceId { q.append(URLQueryItem(name: "mediaSourceId", value: mediaSourceId)) }
        if let container, !container.isEmpty { q.append(URLQueryItem(name: "container", value: container)) }
        q.append(URLQueryItem(name: "api_key", value: apiKey))
        comps.queryItems = q
        return comps.url
    }

    // MARK: HTTP

    /// Run a `GET /Items` query and return the decoded items (empty on a clean empty result).
    private func queryItems(_ extra: [URLQueryItem]) async throws -> [Item] {
        guard var comps = URLComponents(string: "\(base)/Items") else { throw MediaServerError.invalidConfig }
        var q = extra
        // Scope to the user's library when a user id is configured (required by Jellyfin unless the API key
        // grants server-wide access; harmless when present).
        if !userId.isEmpty { q.append(URLQueryItem(name: "UserId", value: userId)) }
        q.append(URLQueryItem(name: "EnableTotalRecordCount", value: "false"))
        comps.queryItems = q
        guard let url = comps.url else { throw MediaServerError.invalidConfig }
        let resp: ItemsResponse = try await get(url)
        return resp.items ?? []
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        // Jellyfin's documented API-key scheme; only Token is required, the rest is advisory client metadata.
        req.setValue("MediaBrowser Token=\"\(apiKey)\", Client=\"VortX\", Device=\"VortX\", Version=\"1\"",
                     forHTTPHeaderField: "Authorization")
        // Legacy fallback header for older servers that don't parse the scheme (harmless on modern ones).
        req.setValue(apiKey, forHTTPHeaderField: "X-Emby-Token")
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw MediaServerError.authFailed }
        guard (200...299).contains(code) else { throw MediaServerError.providerError("HTTP \(code)") }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw MediaServerError.providerError("decode: \(error.localizedDescription)") }
    }
}

// MARK: - Coordinator

/// Builds providers from the user's media-server configs and drives the find-by-imdb/title query. Mirrors
/// `DebridCoordinator`: configs in, providers built per `MediaServerKind`, queried CONCURRENTLY (providers are
/// actors, so the captures are Sendable). With no configs it returns `[]`. This is the seam the future play
/// layer will call to surface "play from my server" sources; NOTHING calls it yet.
@MainActor
final class MediaServerCoordinator {
    static let shared = MediaServerCoordinator()

    private var providers: [any MediaServerProviding] = []

    /// (Re)build providers from the given configs. Call after a config changes (the future Settings surface
    /// will own the config list, like `DebridKeys` owns debrid keys). Unusable configs are skipped.
    func reload(configs: [MediaServerConfig]) {
        providers = configs.compactMap { config in
            switch config.kind {
            // Jellyfin AND Emby share the same REST surface + X-Emby-Token auth, so one actor serves both.
            case .jellyfin, .emby: return JellyfinProvider(config: config)
            case .plex: return PlexProvider(config: config)
            }
        }
    }

    var hasAnyProvider: Bool { !providers.isEmpty }

    /// Query every configured server concurrently for a title and collect the hits. Tries the IMDb id first
    /// per provider, then falls back to title+year on a clean no-match. Returns `[]` with no providers. Each
    /// provider fails soft: a thrown error from one server is dropped, not propagated, so one bad server can't
    /// sink the others.
    func find(imdb: String?, season: Int?, episode: Int?, title: String?, year: Int?) async -> [MediaServerHit] {
        guard !providers.isEmpty else { return [] }
        let snapshot = providers
        return await withTaskGroup(of: MediaServerHit?.self) { group in
            for provider in snapshot {
                group.addTask {
                    do {
                        if let imdb, !imdb.isEmpty,
                           let hit = try await provider.findByImdb(imdb, season: season, episode: episode) {
                            return hit
                        }
                        if let title, !title.isEmpty {
                            return try await provider.findByTitle(title, year: year, season: season, episode: episode)
                        }
                        return nil
                    } catch {
                        return nil   // fail soft: a flaky/unreachable server never breaks the others
                    }
                }
            }
            var hits: [MediaServerHit] = []
            for await hit in group { if let hit { hits.append(hit) } }
            return hits
        }
    }
}
