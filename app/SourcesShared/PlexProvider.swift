import Foundation

/// Plex Media Server native resolver: turn a VortX detail id (imdb `tt...` or tmdb `tmdb:123`) into a direct
/// file URL from the user's own PMS. Conforms to `MediaServerProviding` alongside the Jellyfin-family core.
///
/// Auth: the per-server access token (from plex.tv resource discovery) is sent as `X-Plex-Token`. Matching:
/// the primary path is the GUID filter `GET {server}/library/all?includeGuids=1&guid=imdb://{tt}` (or
/// `tmdb://{n}`), and, exactly like the Jellyfin `AnyProviderIdEquals` discipline, every returned item is
/// re-verified client-side on its own `Guid[]` (legacy-agent libraries and loose filters can return
/// non-matches). Episodes resolve the show, then `/library/metadata/{ratingKey}/allLeaves` scored on
/// `parentIndex == season && index == episode`. A title+year `/search` is the fallback for libraries where the
/// GUID filter misses. Direct play: `{serverUrl}{Media.Part.key}?X-Plex-Token=<token>` (original file).
///
/// URLs are tried in the discovered order (local -> remote -> relay); the first that answers is remembered for
/// the actor's lifetime. Spec-derived + compile-verified, NOT live-verified; inert until the source path calls it.
actor PlexProvider: MediaServerProviding {
    nonisolated let kind: MediaServerKind = .plex
    private let token: String
    private let serverId: UUID
    private let serverName: String
    private let urls: [String]
    private let session: URLSession
    /// The connection URL that last answered, tried first next time (avoids re-probing local/remote/relay).
    private var workingBase: String?

    init?(config: MediaServerConfig) {
        guard config.kind == .plex, !config.apiKey.isEmpty else { return nil }
        let candidates = (config.urls.isEmpty ? [config.baseURL] : config.urls)
            .compactMap { MediaServerResolve.normalizedBase($0) }
        guard !candidates.isEmpty else { return nil }
        self.token = config.apiKey
        self.serverId = config.id
        self.serverName = config.displayName
        self.urls = candidates
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: cfg)
    }

    // MARK: Decodable shapes (only the fields we read)

    private struct Container: Decodable { let mediaContainer: MC?
        enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" } }
    private struct MC: Decodable { let metadata: [Metadatum]?
        enum CodingKeys: String, CodingKey { case metadata = "Metadata" } }
    private struct Metadatum: Decodable {
        let ratingKey: String?
        let title: String?
        let type: String?           // "movie", "episode", "show", "season"
        let year: Int?
        let index: Int?             // episode number for an episode
        let parentIndex: Int?       // season number for an episode
        let guid: [GuidEntry]?
        let media: [Media]?
        enum CodingKeys: String, CodingKey {
            case ratingKey, title, type, year, index, parentIndex
            case guid = "Guid", media = "Media"
        }
        var guids: [String] { (guid ?? []).compactMap { $0.id } }
    }
    private struct GuidEntry: Decodable { let id: String? }
    private struct Media: Decodable {
        let videoResolution: String?
        let container: String?
        let part: [Part]?
        enum CodingKeys: String, CodingKey { case videoResolution, container, part = "Part" }
    }
    private struct Part: Decodable {
        let key: String?
        let file: String?
        let size: Int64?
        let container: String?
    }

    // MARK: Lookup

    func findByImdb(_ id: String, season: Int?, episode: Int?) async throws -> MediaServerHit? {
        guard let guid = Self.plexGuid(for: id) else { return nil }

        if season == nil || episode == nil {
            let items = try await libraryAll(guid: guid)
            guard let match = items.first(where: { $0.guids.contains(guid) && $0.media?.first?.part?.first?.key != nil }) else { return nil }
            return hit(for: match)
        }
        // Series: resolve the show by guid, then its SxEy leaf.
        let shows = try await libraryAll(guid: guid)
        guard let show = shows.first(where: { $0.guids.contains(guid) }), let ratingKey = show.ratingKey else { return nil }
        return try await self.episode(showRatingKey: ratingKey, season: season!, episode: episode!)
    }

    func findByTitle(_ title: String, year: Int?, season: Int?, episode: Int?) async throws -> MediaServerHit? {
        let term = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        let results = try await search(query: term)
        func yearOK(_ m: Metadatum) -> Bool { year == nil || m.year == nil || m.year == year }

        if season == nil || episode == nil {
            guard let match = results.first(where: { ($0.type == "movie") && yearOK($0) && $0.media?.first?.part?.first?.key != nil }) else { return nil }
            return hit(for: match)
        }
        guard let show = results.first(where: { $0.type == "show" && yearOK($0) }), let ratingKey = show.ratingKey else { return nil }
        return try await self.episode(showRatingKey: ratingKey, season: season!, episode: episode!)
    }

    /// Resolve the SxEy leaf inside a show and build its hit.
    private func episode(showRatingKey: String, season: Int, episode: Int) async throws -> MediaServerHit? {
        let leaves = try await allLeaves(showRatingKey: showRatingKey)
        let scored = leaves.compactMap { m -> (Metadatum, Int)? in
            let s = MediaServerResolve.episodeMatchScore(parentIndex: m.parentIndex, index: m.index, season: season, episode: episode)
            return s > 0 ? (m, s) : nil
        }
        guard let best = scored.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        return hit(for: best)
    }

    // MARK: Hit assembly

    private func hit(for m: Metadatum) -> MediaServerHit? {
        guard let base = workingBase, let media = m.media?.first, let part = media.part?.first, let key = part.key,
              let url = streamURL(base: base, partKey: key) else { return nil }
        let container = part.container ?? media.container
        let resolution = Self.plexHeight(media.videoResolution)
        let coarseType = (m.type == "episode") ? "episode" : "movie"
        let fileName = part.file.map { ($0 as NSString).lastPathComponent }
        return MediaServerHit(kind: kind, itemId: m.ratingKey ?? key, name: m.title ?? "Plex", type: coarseType,
                              container: container, resolution: resolution, streamURL: url,
                              serverId: serverId, serverName: serverName, sizeBytes: part.size, fileName: fileName)
    }

    private func streamURL(base: String, partKey: String) -> URL? {
        guard var comps = URLComponents(string: "\(base)\(partKey)") else { return nil }
        var q = comps.queryItems ?? []
        q.append(URLQueryItem(name: "X-Plex-Token", value: token))
        comps.queryItems = q
        return comps.url
    }

    // MARK: HTTP

    private func libraryAll(guid: String) async throws -> [Metadatum] {
        try await getMetadata(path: "/library/all", query: [
            URLQueryItem(name: "includeGuids", value: "1"),
            URLQueryItem(name: "guid", value: guid),
        ])
    }

    private func search(query: String) async throws -> [Metadatum] {
        try await getMetadata(path: "/search", query: [
            URLQueryItem(name: "includeGuids", value: "1"),
            URLQueryItem(name: "query", value: query),
        ])
    }

    private func allLeaves(showRatingKey: String) async throws -> [Metadatum] {
        try await getMetadata(path: "/library/metadata/\(showRatingKey)/allLeaves", query: [])
    }

    /// Run a Plex GET across the ordered URLs (first success wins, remembered as `workingBase`) and decode the
    /// `MediaContainer.Metadata` array. Auth via `X-Plex-Token`, JSON via `Accept`.
    private func getMetadata(path: String, query: [URLQueryItem]) async throws -> [Metadatum] {
        let ordered = workingBase.map { wb in [wb] + urls.filter { $0 != wb } } ?? urls
        var lastError: MediaServerError = .notFound
        for base in ordered {
            guard var comps = URLComponents(string: "\(base)\(path)") else { continue }
            var q = query
            q.append(URLQueryItem(name: "X-Plex-Token", value: token))
            comps.queryItems = q
            guard let url = comps.url else { continue }
            var req = URLRequest(url: url)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("VortX", forHTTPHeaderField: "X-Plex-Product")
            req.setValue(MediaServerStore.plexClientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
            guard let (data, response) = try? await session.data(for: req),
                  let code = (response as? HTTPURLResponse)?.statusCode else { lastError = .providerError("network"); continue }
            if code == 401 || code == 403 { throw MediaServerError.authFailed }
            guard (200...299).contains(code) else { lastError = .providerError("HTTP \(code)"); continue }
            workingBase = base
            guard let decoded = try? JSONDecoder().decode(Container.self, from: data) else { return [] }
            return decoded.mediaContainer?.metadata ?? []
        }
        throw lastError
    }

    // MARK: Helpers

    /// The Plex GUID string for a VortX detail id: `imdb://tt...` or `tmdb://123`.
    private static func plexGuid(for id: String) -> String? {
        let s = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("tt") { return "imdb://\(s)" }
        if s.hasPrefix("tmdb:") {
            let n = String(s.dropFirst("tmdb:".count))
            return n.isEmpty ? nil : "tmdb://\(n)"
        }
        return nil
    }

    /// Map Plex's `videoResolution` string ("4k", "1080", "720", "sd", ...) to a vertical pixel height.
    private static func plexHeight(_ s: String?) -> Int? {
        guard let s = s?.lowercased(), !s.isEmpty else { return nil }
        switch s {
        case "4k":   return 2160
        case "1080": return 1080
        case "720":  return 720
        case "480":  return 480
        case "sd":   return 480
        default:     return Int(s)
        }
    }
}
