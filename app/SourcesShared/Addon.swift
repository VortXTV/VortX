import Foundation

// MARK: - Stremio addon protocol models (the subset the tvOS client needs)

/// A catalog item / meta preview (grid card).
struct MetaPreview: Identifiable, Decodable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let posterShape: String?
}

/// Full meta (detail page). `videos` is present for series (episodes).
struct MetaItem: Identifiable, Decodable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let description: String?
    let releaseInfo: String?
    let runtime: String?
    let imdbRating: String?
    let genres: [String]?
    let videos: [Video]?
}

/// An episode (series), id is `imdbId:season:episode`.
struct Video: Identifiable, Decodable, Hashable {
    let id: String
    let name: String?        // episode title, Stremio's field is `name` (`title` is a legacy alias)
    let title: String?
    let season: Int?
    let episode: Int?
    let number: Int?         // some addons number episodes via `number` instead of `episode`
    let released: String?
    let thumbnail: String?
    let overview: String?

    var episodeNumber: Int { episode ?? number ?? 0 }
    var episodeTitle: String {
        let t = (name ?? title)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? t! : "Episode \(episodeNumber)"
    }
}

/// A playable stream. Debrid/direct streams carry `url`; torrents carry `infoHash` (need a server).
struct Stream: Identifiable, Decodable, Hashable {
    let url: String?
    let infoHash: String?
    let fileIdx: Int?
    let sources: [String]?
    let name: String?
    let title: String?
    let description: String?
    var addonName: String?              // which installed addon supplied this stream (tagged post-decode)

    enum CodingKeys: String, CodingKey { case url, infoHash, fileIdx, sources, name, title, description }

    var id: String { (url ?? infoHash ?? "") + (name ?? "") + (title ?? description ?? "") }
    /// The full detail text the addon attached (resolution, codec, HDR/DV, size, seeders, …).
    /// stremio-web shows this verbatim; addons put it in `description` (newer) or `title` (older).
    var detail: String {
        let d = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty && !t.isEmpty && d != t { return d + "\n" + t }   // keep both if they differ
        return d.isEmpty ? t : d
    }
    /// Short tag the addon shows (addon name + quality), e.g. "Torrentio\n1080p".
    var heading: String { (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Direct/debrid URLs play in libmpv; torrents (infoHash) play via the embedded server.
    var isPlayable: Bool { url != nil || infoHash != nil }
    var isTorrent: Bool { url == nil && infoHash != nil }
}

/// A stream-providing addon (base URL + display name), so streams can be tagged + filtered by source.
struct StreamSource: Hashable { let base: String; let name: String }

private struct MetasResponse: Decodable { let metas: [MetaPreview] }
private struct MetaResponse: Decodable { let meta: MetaItem }
private struct StreamsResponse: Decodable { let streams: [Stream] }

/// Talks to Stremio addons over HTTP (no core/WebKit needed). Cinemeta supplies catalogs +
/// metadata; a configurable stream addon (e.g. AIOStreams) supplies playable streams.
struct AddonClient {
    /// Default metadata addon (public).
    static let cinemeta = "https://v3-cinemeta.strem.io"

    /// Stream-providing addons (base + name) from the signed-in account, e.g. AIOStreams, Torrentio.
    var streamSources: [StreamSource] = []

    private static func get<T: Decodable>(_ urlString: String, as: T.Type) async throws -> T {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        // Some addon CDNs reject non-browser User-Agents (Cinemeta 403s the default), so present
        // a Safari-like UA, same lesson as the libmpv stream fetches.
        req.setValue("Mozilla/5.0 (Apple TV; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func catalog(type: String, id: String) async throws -> [MetaPreview] {
        try await Self.get("\(Self.cinemeta)/catalog/\(type)/\(id).json", as: MetasResponse.self).metas
    }

    /// Catalog from a specific installed addon (the user's own catalogs, e.g. Debridio TMDB).
    func catalog(base: String, type: String, id: String) async throws -> [MetaPreview] {
        try await Self.get("\(base)/catalog/\(type)/\(id).json", as: MetasResponse.self).metas
    }

    /// Genre-filtered catalog. Stremio's "extra" params are encoded as a path segment before
    /// `.json` (e.g. `/catalog/movie/top/genre=Comedy.json`), NOT a `?genre=` query string.
    func catalog(base: String, type: String, id: String, genre: String) async throws -> [MetaPreview] {
        let g = genre.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? genre
        return try await Self.get("\(base)/catalog/\(type)/\(id)/genre=\(g).json", as: MetasResponse.self).metas
    }

    func search(type: String, query: String) async throws -> [MetaPreview] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        return try await Self.get("\(Self.cinemeta)/catalog/\(type)/top/search=\(q).json", as: MetasResponse.self).metas
    }

    func meta(type: String, id: String) async throws -> MetaItem {
        try await meta(base: Self.cinemeta, type: type, id: id)
    }

    /// Metadata from a specific addon base, lets us resolve titles from whichever meta addon owns
    /// the id (Cinemeta `tt…`, TMDB `tmdb:…`, Kitsu `kitsu:…`), not just Cinemeta.
    func meta(base: String, type: String, id: String) async throws -> MetaItem {
        let safeId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await Self.get("\(base)/meta/\(type)/\(safeId).json", as: MetaResponse.self).meta
    }

    /// Streams for a movie (`videoId == imdbId`) or episode (`imdbId:season:episode`), aggregated
    /// across the account's stream addons. Each stream is tagged with the addon that supplied it so
    /// the UI can show the source and offer a per-addon filter. Fetched in parallel.
    func streams(type: String, videoId: String) async -> [Stream] {
        // Fetch every addon in parallel, but REASSEMBLE in the user's addon order (by source index),
        // not in completion order, so the sources they prioritised appear first.
        let sources = streamSources
        return await withTaskGroup(of: (Int, [Stream]).self) { group in
            for (i, source) in sources.enumerated() {
                group.addTask {
                    guard let r = try? await Self.get("\(source.base)/stream/\(type)/\(videoId).json",
                                                      as: StreamsResponse.self) else { return (i, []) }
                    return (i, r.streams.map { var s = $0; s.addonName = source.name; return s })
                }
            }
            var buckets = [[Stream]](repeating: [], count: sources.count)
            for await (i, chunk) in group { buckets[i] = chunk }
            return buckets.flatMap { $0 }
        }
    }

    var hasStreamAddon: Bool { !streamSources.isEmpty }
}
