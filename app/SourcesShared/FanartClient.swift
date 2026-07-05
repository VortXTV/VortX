import Foundation

/// Resolves and caches fanart.tv artwork (clearlogo, clearart, poster, background) by id, INDEPENDENT of
/// ERDB. fanart.tv is the community art database add-on authors asked for; this calls its public v3 API
/// directly with the user's fanart.tv key (`ApiKeys.fanartKey`), so users get fanart art WITHOUT enabling
/// ERDB (which replaces every poster with a rating-baked render). Fail-soft: any miss / parse / network
/// error or a missing key returns empty art and the caller keeps its existing artwork. One lookup per id
/// (cached + in-flight deduped), mirroring `LandscapeBackdropCache`.
///
/// id mapping: fanart.tv movies accept an IMDb `tt` id OR a TMDB numeric id; fanart.tv TV is keyed by TVDB
/// id only, so a `tt`/`tmdb` series is mapped to its TVDB id via TMDB (needs a TMDB key, else TV fails soft).
actor FanartClient {
    static let shared = FanartClient()

    struct Art: Sendable {
        var logo: String?
        var clearart: String?
        var poster: String?
        var background: String?
        var isEmpty: Bool { logo == nil && clearart == nil && poster == nil && background == nil }
    }

    private var cache: [String: Art] = [:]
    private var inflight: [String: Task<Art, Never>] = [:]

    /// The resolved fanart.tv art bundle for a title, or empty art when fanart has none / no key.
    static func art(id: String, type: String) async -> Art {
        await shared.resolve(id: id, type: type)
    }

    private func resolve(id: String, type: String) async -> Art {
        if let hit = cache[id] { return hit }
        if let task = inflight[id] { return await task.value }
        let task = Task { await Self.fetch(id: id, type: type) }
        inflight[id] = task
        let result = await task.value
        if !result.isEmpty { cache[id] = result }   // don't latch a transient fetch failure into a session-long empty Art
        inflight[id] = nil
        return result
    }

    // MARK: fetch

    private static func fetch(id: String, type: String) async -> Art {
        guard let key = ApiKeys.fanartKey(), !key.isEmpty else { return Art() }
        let isTV = (type == "series" || type == "tv")
        if isTV {
            guard let tvdb = await tvdbID(for: id) else { return Art() }
            return await fetchObject(path: "tv", id: tvdb, key: key, tv: true)
        }
        guard let movie = movieID(for: id) else { return Art() }
        return await fetchObject(path: "movies", id: movie, key: key, tv: false)
    }

    /// fanart.tv movies accept an IMDb `tt` id OR a TMDB numeric id; map the engine id to one of those.
    private static func movieID(for id: String) -> String? {
        if id.hasPrefix("tt") { return id }
        if id.hasPrefix("tmdb:") { return id.components(separatedBy: ":").last }   // tmdb:movie:603 -> 603
        return nil
    }

    /// fanart.tv TV is keyed by TVDB id only. A `tvdb:` id maps directly; `tt`/`tmdb` series are resolved to
    /// a TVDB id via TMDB external_ids (needs a TMDB key, else nil so TV fails soft).
    private static func tvdbID(for id: String) async -> String? {
        if id.hasPrefix("tvdb:") { return id.components(separatedBy: ":").last }
        guard let tmdbKey = ApiKeys.tmdbKey(), !tmdbKey.isEmpty else { return nil }
        // Resolve the TMDB tv id first (a tt id via /find, a tmdb: id directly), then its external_ids.tvdb_id.
        var tmdbTVID: String?
        if id.hasPrefix("tt") {
            if let obj = await getJSON("https://api.themoviedb.org/3/find/\(id)?api_key=\(tmdbKey)&external_source=imdb_id"),
               let tv = (obj["tv_results"] as? [[String: Any]])?.first, let tid = tv["id"] as? Int {
                tmdbTVID = String(tid)
            }
        } else if id.hasPrefix("tmdb:") {
            tmdbTVID = id.components(separatedBy: ":").last
        }
        guard let tmdbTVID,
              let ext = await getJSON("https://api.themoviedb.org/3/tv/\(tmdbTVID)/external_ids?api_key=\(tmdbKey)"),
              let tvdb = ext["tvdb_id"] as? Int else { return nil }
        return String(tvdb)
    }

    private static func fetchObject(path: String, id: String, key: String, tv: Bool) async -> Art {
        guard let obj = await getJSON("https://webservice.fanart.tv/v3/\(path)/\(id)?api_key=\(key)") else { return Art() }
        if tv {
            return Art(logo: best(obj["hdtvlogo"] ?? obj["clearlogo"]),
                       clearart: best(obj["hdclearart"] ?? obj["clearart"]),
                       poster: best(obj["tvposter"]),
                       background: best(obj["showbackground"]))
        }
        return Art(logo: best(obj["hdmovielogo"] ?? obj["movielogo"]),
                   clearart: best(obj["hdmovieclearart"] ?? obj["movieart"]),
                   poster: best(obj["movieposter"]),
                   background: best(obj["moviebackground"]))
    }

    /// fanart.tv art arrays are `[{url, lang, likes}]`; prefer English, then the most-liked.
    private static func best(_ raw: Any?) -> String? {
        guard let arr = raw as? [[String: Any]], !arr.isEmpty else { return nil }
        let ranked = arr.sorted { a, b in
            let ea = (a["lang"] as? String) == "en", eb = (b["lang"] as? String) == "en"
            if ea != eb { return ea }
            return (Int(a["likes"] as? String ?? "0") ?? 0) > (Int(b["likes"] as? String ?? "0") ?? 0)
        }
        return ranked.first?["url"] as? String
    }

    private static func getJSON(_ urlString: String) async -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .returnCacheDataElseLoad   // art mappings are immutable: prefer the shared disk cache
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}
