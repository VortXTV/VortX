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
    /// Metacritic metascore 0-100 (MDBList source "metacritic"), when present.
    let metacritic: Int?
    /// TMDB user score percentage 0-100, when present.
    let tmdb: Int?

    /// True when at least one provider rating is present, i.e. there is something to render.
    var hasAny: Bool { imdb != nil || rottenTomatoes != nil || metacritic != nil || tmdb != nil }
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
                metacritic: bySource["metacritic"].map { Int($0.rounded()) },
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

// MARK: - Public list import (browse an MDBList list as a native catalog row)

extension MDBListClient {
    /// Fetch a public MDBList list as raw entries (in list order) for `ListImport`. MDBList exposes a keyless
    /// JSON export at `mdblist.com/lists/<user>/<slug>/json` for PUBLIC lists; when the user has set an
    /// MDBList key we additionally try the authenticated API, which also covers their private lists. Each
    /// item already carries `imdb_id` and a TMDB `id`, so little resolution is needed downstream. Fail-soft:
    /// returns an empty list on any error so the coordinator surfaces a clean "list is empty/private" message.
    static func fetchRawList(user: String, slug: String) async -> RawList {
        let u = ListImport.encodePath(user), s = ListImport.encodePath(slug)

        // 1) Keyless public JSON export.
        if let json = await fetchJSON("https://mdblist.com/lists/\(u)/\(s)/json") {
            let entries = collectItems(json).compactMap(entry(from:))
            if !entries.isEmpty { return RawList(title: nil, entries: entries) }
        }
        // 2) Authenticated API when a key is present (covers private lists too).
        if let key = ApiKeys.mdblistKey(), !key.isEmpty {
            var comps = URLComponents(string: "\(host)/lists/\(u)/\(s)/items")
            comps?.queryItems = [URLQueryItem(name: "apikey", value: key)]
            if let url = comps?.url, let json = await fetchJSON(url.absoluteString) {
                let entries = collectItems(json).compactMap(entry(from:))
                if !entries.isEmpty { return RawList(title: nil, entries: entries) }
            }
        }
        return RawList(title: nil, entries: [])
    }

    /// GET a URL and parse it as loose JSON (any of an array, `{movies,shows}`, or `{items:[...]}`). Browser
    /// UA because MDBList, like several add-on CDNs, rejects the default agent. Fail-soft to nil.
    private static func fetchJSON(_ urlString: String) async -> Any? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(ListImport.browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Flatten MDBList's several list shapes into a flat array of item dictionaries: a bare array, an object
    /// with `movies`/`shows` arrays, or an object with an `items` array.
    private static func collectItems(_ json: Any) -> [[String: Any]] {
        if let array = json as? [[String: Any]] { return array }
        guard let obj = json as? [String: Any] else { return [] }
        var out: [[String: Any]] = []
        for key in ["movies", "shows", "items", "results"] {
            if let arr = obj[key] as? [[String: Any]] { out += arr }
        }
        return out
    }

    /// One MDBList item dict to a raw entry, tolerant of key-name variance across the export and the API
    /// (`id`/`tmdb_id` for the TMDB id, `imdb_id`/`imdbid`, `mediatype`/`type`).
    private static func entry(from obj: [String: Any]) -> RawListEntry? {
        let imdb = (obj["imdb_id"] as? String) ?? (obj["imdbid"] as? String)
        let tmdb = intVal(obj["id"]) ?? intVal(obj["tmdb_id"]) ?? intVal(obj["tmdbid"])
        let media = ((obj["mediatype"] as? String) ?? (obj["media_type"] as? String) ?? (obj["type"] as? String) ?? "").lowercased()
        let title = (obj["title"] as? String) ?? (obj["name"] as? String)
        let year = intVal(obj["release_year"]) ?? intVal(obj["year"])
        guard imdb != nil || tmdb != nil || (title?.isEmpty == false) else { return nil }
        let isShow = media == "show" || media == "series" || media == "tv"
        return RawListEntry(imdbID: imdb, tmdbID: tmdb, tmdbType: isShow ? "tv" : "movie",
                            title: title, year: year, typeHint: isShow ? "series" : "movie")
    }

    /// Read a JSON number that may arrive as Int, Double, NSNumber, or a numeric string.
    private static func intVal(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
