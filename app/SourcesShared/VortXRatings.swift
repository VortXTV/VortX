import Foundation

/// One identity for the endpoint, cache and view task. A media-type correction or service setting
/// change must never reuse a score (or a failed request) from the previous route.
struct RatingRequestKey: Hashable, Sendable {
    let id: String
    let type: String
    let base: String
    let enabled: Bool

    init(id: String, type: String) {
        self.id = id
        self.type = type.lowercased() == "series" ? "series" : "movie"
        base = VortXRatingsClient.base
        enabled = VortXRatingsClient.isEnabled
    }
}

enum RatingPresentationPolicy {
    static func imdb(_ text: String?) -> Double? {
        guard let text, let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, (0...10).contains(value) else { return nil }
        return value
    }

    /// Enrichment fills individual gaps; an RT-only response cannot remove the supplied IMDb score.
    static func merged(_ primary: MDBListRatings?, secondary: MDBListRatings? = nil,
                       fallbackIMDb: String? = nil) -> MDBListRatings? {
        let result = MDBListRatings(
            imdb: primary?.imdb ?? secondary?.imdb ?? imdb(fallbackIMDb),
            rottenTomatoes: primary?.rottenTomatoes ?? secondary?.rottenTomatoes,
            metacritic: primary?.metacritic ?? secondary?.metacritic,
            tmdb: primary?.tmdb ?? secondary?.tmdb,
            rtAudience: primary?.rtAudience ?? secondary?.rtAudience,
            letterboxd: primary?.letterboxd ?? secondary?.letterboxd,
            trakt: primary?.trakt ?? secondary?.trakt,
            mal: primary?.mal ?? secondary?.mal,
            simkl: primary?.simkl ?? secondary?.simkl,
            kitsu: primary?.kitsu ?? secondary?.kitsu)
        return result.hasAny ? result : nil
    }

    /// Persisted TV hero caches predate a typed score field. Keep their one valid star token when
    /// a sparse metadata response omits IMDb, and replace it when the current preview supplies IMDb.
    static func imdbToken(in line: String) -> String? {
        line.components(separatedBy: "  ·  ").first { token in
            token.hasPrefix("★ ") && imdb(String(token.dropFirst(2))) != nil
        }
    }

    static func mergingIMDbLine(_ line: String, freshLine: String) -> String {
        guard let token = imdbToken(in: freshLine) ?? imdbToken(in: line) else { return line }
        var parts = line.components(separatedBy: "  ·  ")
        let index = parts.firstIndex { $0.hasPrefix("★ ") } ?? max(0, parts.count - 1)
        parts.removeAll { $0.hasPrefix("★ ") }
        parts.insert(token, at: min(index, parts.count))
        return parts.joined(separator: "  ·  ")
    }
}

/// One episode's scores: IMDb on its 0-10 scale, TMDB and Trakt as 0-100, the same scales the title scores use.
struct EpisodeScores: Equatable, Sendable {
    var imdb: Double?
    var tmdb: Int?
    var trakt: Int?

    var ratings: MDBListRatings {
        MDBListRatings(imdb: imdb, rottenTomatoes: nil, metacritic: nil, tmdb: tmdb, trakt: trakt)
    }

    /// The score a season's "Top rated" pick ranks by, on a 0-10 scale: IMDb, else TMDB, else Trakt.
    var headline: Double? { imdb ?? tmdb.map { Double($0) / 10 } ?? trakt.map { Double($0) / 10 } }
}

/// VortX's own ratings service (https://ratings.vortx.tv): cross-provider ratings with NO user key
/// required. IMDb is keyless (sourced from Cinemeta); Rotten Tomatoes / Metacritic / TMDB come from a
/// single VortX-owned MDBList key held server-side, so no user ever needs their own. Fails soft (returns
/// nil) like MDBListClient, and maps into the SAME MDBListRatings model so the detail ratings row renders
/// unchanged. On by default; a power user can disable it or point at their own instance via the keys below.
enum VortXRatingsClient {
    static let baseKey = "stremiox.ratings.base"       // optional override; blank = the VortX service
    static let enabledKey = "stremiox.ratings.enabled" // absent = on by default

    /// Service base URL, http(s) only, trailing slash trimmed; defaults to the VortX service.
    static var base: String {
        var s = (UserDefaults.standard.string(forKey: baseKey) ?? "").trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return "https://ratings.vortx.tv" }
        return s.isEmpty ? "https://ratings.vortx.tv" : s
    }

    /// On unless the user explicitly turned it off.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Ratings for an IMDb id, no key needed. `type` is the stremio type ("movie"/"series"). Returns nil
    /// when disabled, the id is not an imdb id, or anything goes wrong (fail-soft, like MDBListClient).
    static func ratings(imdbID: String, type: String) async -> MDBListRatings? {
        guard isEnabled, imdbID.hasPrefix("tt"), !imdbID.dropFirst(2).isEmpty,
              imdbID.dropFirst(2).allSatisfy(\.isNumber), !Task.isCancelled else { return nil }
        let mediaType = (type.lowercased() == "series") ? "series" : "movie"
        guard let url = URL(string: "\(base)/v1/ratings/\(mediaType)/\(imdbID)") else { return nil }
        do {
            // Sign for the gated ratings.vortx.tv host (no-op when the user pointed at a custom base).
            var request = URLRequest(url: url)
            VortXEdgeAuth.sign(&request)
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            // The VortX service returns IMDb, MyAnimeList (0-10) and Letterboxd (0-5) on their native scales
            // and the rest as 0-100, matching the MDBListRatings model every rating surface renders.
            let r = MDBListRatings(
                imdb: numeric(root["imdb"]),
                rottenTomatoes: numeric(root["rt"]).map { Int($0.rounded()) },
                metacritic: numeric(root["metacritic"]).map { Int($0.rounded()) },
                tmdb: numeric(root["tmdb"]).map { Int($0.rounded()) },
                rtAudience: numeric(root["rtAudience"]).map { Int($0.rounded()) },
                letterboxd: numeric(root["letterboxd"]).flatMap { RatingsFormat.scaled($0, max: 5) },
                trakt: numeric(root["trakt"]).map { Int($0.rounded()) },
                mal: numeric(root["mal"]).flatMap { RatingsFormat.scaled($0, max: 10) },
                simkl: numeric(root["simkl"]).flatMap { RatingsFormat.scaled($0, max: 10) },
                kitsu: numeric(root["kitsu"]).map { Int($0.rounded()) }
            )
            return r.hasAny ? r : nil
        } catch { return nil }
    }

    /// Per-episode scores for one season of a series (`/v1/episodes/{tt}/{season}`): IMDb, TMDB and Trakt for
    /// every episode the service has scored. nil when disabled, the id is not an IMDb id, or the request fails,
    /// so the caller can fall back to TMDB directly.
    static func episodes(seriesID: String, season: Int) async -> [Int: EpisodeScores]? {
        guard isEnabled, seriesID.hasPrefix("tt"), !seriesID.dropFirst(2).isEmpty,
              seriesID.dropFirst(2).allSatisfy(\.isNumber), (0...999).contains(season), !Task.isCancelled,
              let url = URL(string: "\(base)/v1/episodes/\(seriesID)/\(season)") else { return nil }
        do {
            var request = URLRequest(url: url)
            VortXEdgeAuth.sign(&request)
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rows = root["episodes"] as? [String: Any] else { return nil }
            var out: [Int: EpisodeScores] = [:]
            for (key, value) in rows {
                guard let number = Int(key), let row = value as? [String: Any] else { continue }
                let scores = EpisodeScores(
                    imdb: numeric(row["imdb"]).flatMap { $0 > 0 && $0 <= 10 ? $0 : nil },
                    tmdb: numeric(row["tmdb"]).map { Int($0.rounded()) },
                    trakt: numeric(row["trakt"]).map { Int($0.rounded()) })
                if scores.ratings.hasAny { out[number] = scores }
            }
            return out
        } catch { return nil }
    }

    private static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
