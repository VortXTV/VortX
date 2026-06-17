import Foundation

/// Minimal TMDB v3 client, used only when the user has set a TMDB key (see ApiKeys). It enriches the
/// engine's data; it is never required. Recommendations are returned as IMDb ids so they map straight
/// onto the engine's Cinemeta metas. Every call fails soft (returns nil / []), so a flaky or missing
/// key never breaks a screen.
enum TMDBClient {
    private static let host = "https://api.themoviedb.org/3"

    /// IMDb ids recommended for the given IMDb id. `type` is the stremio type ("movie" or "series").
    static func recommendations(imdbID: String, type: String) async -> [String] {
        guard let key = ApiKeys.tmdbKey(), imdbID.hasPrefix("tt") else { return [] }
        let media = (type == "series") ? "tv" : "movie"
        guard let found = await get("/find/\(imdbID)?external_source=imdb_id&api_key=\(key)"),
              let first = (found[media == "tv" ? "tv_results" : "movie_results"] as? [[String: Any]])?.first,
              let tmdbID = first["id"] as? Int else { return [] }
        guard let recs = await get("/\(media)/\(tmdbID)/recommendations?api_key=\(key)"),
              let results = recs["results"] as? [[String: Any]] else { return [] }
        let ids = results.compactMap { $0["id"] as? Int }.prefix(10)
        // Map each TMDB id back to an IMDb id (concurrently, capped) so results play through the engine.
        return await withTaskGroup(of: String?.self) { group in
            for id in ids {
                group.addTask {
                    guard let ext = await get("/\(media)/\(id)/external_ids?api_key=\(key)"),
                          let imdb = ext["imdb_id"] as? String, imdb.hasPrefix("tt") else { return nil }
                    return imdb
                }
            }
            var out: [String] = []
            for await r in group { if let r { out.append(r) } }
            return out
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
