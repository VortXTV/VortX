import Foundation

/// Minimal TMDB v3 client, used only when the user has set a TMDB key (see ApiKeys). It enriches the
/// engine's data; it is never required. Recommendations are returned as IMDb ids so they map straight
/// onto the engine's Cinemeta metas. Every call fails soft (returns nil / []), so a flaky or missing
/// key never breaks a screen.
enum TMDBClient {
    private static let host = "https://api.themoviedb.org/3"

    /// IMDb ids recommended for the given IMDb id. `type` is the stremio type ("movie" or "series").
    /// Recommendations whose ORIGIN/language matches the source are surfaced first, so a Korean drama
    /// suggests Korean, a Bollywood film suggests Bollywood, not just same-genre Hollywood.
    static func recommendations(imdbID: String, type: String) async -> [String] {
        guard let key = ApiKeys.tmdbKey(), imdbID.hasPrefix("tt") else { return [] }
        let media = (type == "series") ? "tv" : "movie"
        guard let found = await get("/find/\(imdbID)?external_source=imdb_id&api_key=\(key)"),
              let first = (found[media == "tv" ? "tv_results" : "movie_results"] as? [[String: Any]])?.first,
              let tmdbID = first["id"] as? Int else { return [] }
        let srcLang = first["original_language"] as? String
        guard let recs = await get("/\(media)/\(tmdbID)/recommendations?api_key=\(key)"),
              let results = recs["results"] as? [[String: Any]] else { return [] }
        // Stable sort: same-original-language first, otherwise keep TMDB's popularity order.
        let ranked = results.enumerated().sorted { a, b in
            let am = ((a.element["original_language"] as? String) == srcLang) ? 0 : 1
            let bm = ((b.element["original_language"] as? String) == srcLang) ? 0 : 1
            return am != bm ? am < bm : a.offset < b.offset
        }.map { $0.element }
        let ids = ranked.compactMap { $0["id"] as? Int }.prefix(12)
        // Map each TMDB id back to an IMDb id (concurrently, capped) so results play through the engine.
        return await withTaskGroup(of: (Int, String)?.self) { group in
            for (i, id) in ids.enumerated() {
                group.addTask {
                    guard let ext = await get("/\(media)/\(id)/external_ids?api_key=\(key)"),
                          let imdb = ext["imdb_id"] as? String, imdb.hasPrefix("tt") else { return nil }
                    return (i, imdb)
                }
            }
            var out: [(Int, String)] = []
            for await r in group { if let r { out.append(r) } }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }   // preserve the language-boosted order
        }
    }

    private static func get(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: host + path) else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } catch { return nil }
    }
}
