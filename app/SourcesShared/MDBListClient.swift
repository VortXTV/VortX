import Foundation

/// Compact ratings from MDBList, used only when the user has set an MDBList key (see ApiKeys). It
/// enriches the detail page with cross-provider scores (IMDb, Rotten Tomatoes, TMDB, ...); it is never
/// required. Every call fails soft (returns nil), so a flaky or missing key never breaks a screen.
///
/// API shape (verified against the live endpoint, form
/// `https://api.mdblist.com/imdb/{type}/{imdbID}?apikey=...`): a top-level `ratings` array whose
/// entries are `{ source, value, score, votes, url }`. `source` is the provider key ("imdb",
/// "tomatoes" = Rotten Tomatoes, "tmdb", "trakt", "letterboxd", "metacritic", "audience"/"popcorn",
/// ...); `value` is the provider's native scale (IMDb 0-10, RT/TMDB 0-100); `score` is a 0-100
/// normalization. We decode only `source` + `value`, which is all the row needs.
struct MDBListRatings: Equatable {
    /// IMDb rating on its native 0-10 scale (e.g. 8.5), when present.
    let imdb: Double?
    /// Rotten Tomatoes critics percentage 0-100 (MDBList source "tomatoes"), when present.
    let rottenTomatoes: Int?
    /// TMDB user score percentage 0-100, when present.
    let tmdb: Int?

    /// True when at least one provider rating is present, i.e. there is something to render.
    var hasAny: Bool { imdb != nil || rottenTomatoes != nil || tmdb != nil }
}

enum MDBListClient {
    private static let host = "https://api.mdblist.com"

    /// Ratings for an IMDb id. `type` is the stremio type ("movie" or "series"); MDBList keys series
    /// under "show". Returns nil when no key is set, the id is not an imdb id, or anything goes wrong.
    static func ratings(imdbID: String, type: String) async -> MDBListRatings? {
        guard let key = ApiKeys.mdblistKey(), isImdbID(imdbID) else { return nil }
        let mediaType = (type == "series") ? "show" : "movie"
        // Build with URLComponents so the api key is percent-encoded as a query value rather than
        // spliced into a raw string. mediaType is one of two literals and imdbID is validated above,
        // so the only untrusted input (the key) never lands in the path.
        var components = URLComponents(string: "\(host)/imdb/\(mediaType)/\(imdbID)")
        components?.queryItems = [URLQueryItem(name: "apikey", value: key)]
        guard let url = components?.url else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let entries = root["ratings"] as? [[String: Any]] else { return nil }
            var bySource: [String: Double] = [:]
            for entry in entries {
                guard let source = entry["source"] as? String,
                      let value = numeric(entry["value"]) else { continue }
                bySource[source] = value
            }
            let ratings = MDBListRatings(
                imdb: bySource["imdb"],
                rottenTomatoes: bySource["tomatoes"].map { Int($0.rounded()) },
                tmdb: bySource["tmdb"].map { Int($0.rounded()) }
            )
            return ratings.hasAny ? ratings : nil
        } catch { return nil }
    }

    /// True for a well-formed IMDb id: "tt" followed by one or more digits ("tt0111161"). This keeps a
    /// value with an odd type or query-breaking characters out of the composed URL.
    private static func isImdbID(_ id: String) -> Bool {
        guard id.hasPrefix("tt") else { return false }
        let digits = id.dropFirst(2)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// MDBList sends ratings as JSON numbers (Int or Double); read either as a Double.
    private static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
