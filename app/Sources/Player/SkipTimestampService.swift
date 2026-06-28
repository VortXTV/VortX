import Foundation
import os

/// Layer 2: crowd-sourced skip timestamps from TheIntroDB (theintrodb.org) and/or SkipDB
/// (skipdb.tv). Looked up by the IMDB id the app already has from Cinemeta (+
/// season/episode for series, nothing for movies); reads are anonymous. Results, and misses, cache
/// to disk so an episode costs one request per provider, not one per play.
enum SkipTimestampService {

    /// UserDefaults key for the chosen skip-timestamp provider.
    /// Values: "theintrodb" (default), "skipdb", "both"
    static let providerKey = "stremiox.skipProvider"

    private static let log = Logger(subsystem: "com.stremiox.app", category: "skiptimes")

    private static var provider: String {
        UserDefaults.standard.string(forKey: providerKey) ?? "both"
    }

    /// All skip candidates for a title, merging the chosen crowd source(s) with AniSkip (anime).
    static func candidates(imdbId: String, season: Int?, episode: Int?,
                           durationSeconds: Double) async -> [SegmentCandidate] {
        async let aniskip = AniSkipService.candidates(metaId: imdbId, episode: episode, durationSeconds: durationSeconds)
        let crowd: [SegmentCandidate]
        switch provider {
        case "skipdb":
            crowd = await skipDB(imdbId: imdbId, season: season, episode: episode, durationSeconds: durationSeconds)
        case "both":
            async let introdb = theIntroDB(imdbId: imdbId, season: season, episode: episode, durationSeconds: durationSeconds)
            async let skipdb  = skipDB(imdbId: imdbId, season: season, episode: episode, durationSeconds: durationSeconds)
            crowd = await introdb + skipdb
        default: // "theintrodb"
            crowd = await theIntroDB(imdbId: imdbId, season: season, episode: episode, durationSeconds: durationSeconds)
        }
        return crowd + (await aniskip)
    }

    /// Layer 2a: TheIntroDB crowd spans (any media, keyed by imdb/tmdb/tvdb id).
    private static func theIntroDB(imdbId: String, season: Int?, episode: Int?,
                                   durationSeconds: Double) async -> [SegmentCandidate] {
        guard let idItem = queryItem(for: imdbId) else { return [] }
        let durationBucket = Int(durationSeconds / 10) * 10
        let key = "\(imdbId):\(season ?? 0):\(episode ?? 0):\(durationBucket)"
        if let cached = await SkipTimestampStore.shared.entry(for: key) {
            log.info("cache hit \(key, privacy: .public): \(cached.spans.count, privacy: .public) spans")
            return candidates(from: cached.spans, duration: durationSeconds)
        }

        var components = URLComponents(string: "https://api.theintrodb.org/v3/media")!
        var items = [idItem]
        if let season, let episode {
            items.append(URLQueryItem(name: "season", value: String(season)))
            items.append(URLQueryItem(name: "episode", value: String(episode)))
        }
        if durationSeconds > 0 {
            // Lets the API pick the release version (theatrical/extended) closest to this rip.
            items.append(URLQueryItem(name: "duration_ms", value: String(Int(durationSeconds * 1000))))
        }
        components.queryItems = items
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return [] }
            if http.statusCode == 404 {                       // known-missing: cache so we retry daily, not per play
                log.info("\(key, privacy: .public): not in the database")
                await SkipTimestampStore.shared.store(.miss(), for: key)
                return []
            }
            guard http.statusCode == 200 else {               // rate-limit / server error: retry next play
                log.info("\(key, privacy: .public): HTTP \(http.statusCode, privacy: .public)")
                return []
            }
            let media = try JSONDecoder().decode(MediaResponse.self, from: data)
            log.info("\(key, privacy: .public): \(media.spans.count, privacy: .public) spans fetched")
            let entry = SkipTimestampStore.Entry(fetchedAt: Date(), spans: media.spans)
            await SkipTimestampStore.shared.store(entry, for: key)
            return candidates(from: media.spans, duration: durationSeconds)
        } catch {
            log.info("\(key, privacy: .public): failed, \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Layer 2b: SkipDB crowd spans (any media, keyed by IMDB id only).
    private static func skipDB(imdbId: String, season: Int?, episode: Int?,
                               durationSeconds: Double) async -> [SegmentCandidate] {
        guard imdbId.range(of: #"^tt\d{7,8}$"#, options: .regularExpression) != nil else { return [] }
        let durationBucket = Int(durationSeconds / 10) * 10
        let key = "skipdb:\(imdbId):\(season ?? 0):\(episode ?? 0):\(durationBucket)"
        if let cached = await SkipTimestampStore.shared.entry(for: key) {
            log.info("cache hit \(key, privacy: .public): \(cached.spans.count, privacy: .public) spans")
            return candidates(from: cached.spans, duration: durationSeconds)
        }

        var components = URLComponents(string: "https://api.skipdb.tv/api/segments")!
        var items: [URLQueryItem] = [URLQueryItem(name: "imdb_id", value: imdbId)]
        if let season, let episode {
            items.append(URLQueryItem(name: "season", value: String(season)))
            items.append(URLQueryItem(name: "episode", value: String(episode)))
        }
        if durationSeconds > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(durationSeconds))))
        }
        components.queryItems = items
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if let apiKey = ApiKeys.skipDBKey() {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return [] }
            if http.statusCode == 404 {
                log.info("\(key, privacy: .public): not in SkipDB")
                await SkipTimestampStore.shared.store(.miss(), for: key)
                return []
            }
            guard http.statusCode == 200 else {
                log.info("\(key, privacy: .public): SkipDB HTTP \(http.statusCode, privacy: .public)")
                return []
            }
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            log.debug("SkipDB response for \(key, privacy: .public): \(raw, privacy: .public)")
            let media = try JSONDecoder().decode(SkipDBResponse.self, from: data)
            log.info("\(key, privacy: .public): \(media.spans.count, privacy: .public) spans from SkipDB")
            let entry = SkipTimestampStore.Entry(fetchedAt: Date(), spans: media.spans,
                                                 introEstimateMs: media.intro_length_estimate_ms)
            await SkipTimestampStore.shared.store(entry, for: key)
            return candidates(from: media.spans, duration: durationSeconds)
        } catch {
            log.info("\(key, privacy: .public): SkipDB failed, \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Maps a Stremio meta id to the API's id parameter. Stremio ids are IMDB ("tt123…") from
    /// Cinemeta, or namespaced "tmdb:123" / "tvdb:123" from TMDB/TVDB-based catalog add-ons. TMDB is
    /// actually the database's canonical key, so those hit directly with no server-side resolution.
    private static func queryItem(for metaId: String) -> URLQueryItem? {
        if metaId.range(of: #"^tt\d{7,8}$"#, options: .regularExpression) != nil {
            return URLQueryItem(name: "imdb_id", value: metaId)
        }
        if metaId.hasPrefix("tmdb:"), let id = Int(metaId.dropFirst(5)) {
            return URLQueryItem(name: "tmdb_id", value: String(id))
        }
        if metaId.hasPrefix("tvdb:"), let id = Int(metaId.dropFirst(5)) {
            return URLQueryItem(name: "tvdb_id", value: String(id))
        }
        return nil
    }

    static func supports(metaId: String) -> Bool {
        queryItem(for: metaId) != nil || AniSkipService.supports(metaId: metaId)
    }

    private static func candidates(from spans: [StoredSpan], duration: Double) -> [SegmentCandidate] {
        spans.compactMap { span in
            guard let kind = SkipSegment.Kind(rawValue: span.kind) else { return nil }
            let start = span.startMs.map { Double($0) / 1000 } ?? 0          // null intro start = from 0
            let end = span.endMs.map { Double($0) / 1000 } ?? duration       // null credits end = to end of file
            return SegmentCandidate(kind: kind, start: start, end: end, source: .crowdAPI, confidence: 0.9)
        }
    }

    /// TheIntroDB `/v3/media` shape: up to four arrays of `{start_ms, end_ms}`, either side nullable.
    private struct MediaResponse: Decodable {
        struct Span: Decodable {
            let start_ms: Int?
            let end_ms: Int?
        }
        let intro: [Span]?
        let recap: [Span]?
        let credits: [Span]?
        let preview: [Span]?

        var spans: [StoredSpan] {
            func stored(_ spans: [Span]?, _ kind: String) -> [StoredSpan] {
                (spans ?? []).map { StoredSpan(kind: kind, startMs: $0.start_ms, endMs: $0.end_ms) }
            }
            return stored(intro, "intro") + stored(recap, "recap")
                + stored(credits, "credits") + stored(preview, "preview")
        }
    }

    /// SkipDB `/api/segments` shape: one object per type (or null / excluded marker).
    /// `outro` is SkipDB's name for end-credits — mapped to the `"credits"` kind.
    private struct SkipDBResponse: Decodable {
        struct Span: Decodable {
            let start_ms: Int?
            let end_ms: Int?
        }
        struct Segments: Decodable {
            let intro:   Span?
            let recap:   Span?
            let outro:   Span?   // mapped to kind "credits"
            let preview: Span?
        }
        let segments: Segments
        let intro_length_estimate_ms: Int?

        var spans: [StoredSpan] {
            func stored(_ span: Span?, kind: String) -> StoredSpan? {
                guard let s = span, s.start_ms != nil else { return nil }
                return StoredSpan(kind: kind, startMs: s.start_ms, endMs: s.end_ms)
            }
            return [
                stored(segments.intro,   kind: "intro"),
                stored(segments.recap,   kind: "recap"),
                stored(segments.outro,   kind: "credits"),
                stored(segments.preview, kind: "preview"),
            ].compactMap { $0 }
        }
    }
}

/// One raw remote span, stored unclamped (ms + nullable bounds) so a different rip's duration
/// re-derives the clamped segment on read instead of baking one file's runtime into the cache.
struct StoredSpan: Codable, Equatable {
    let kind: String
    let startMs: Int?
    let endMs: Int?
}

/// Tiny disk cache for crowd skip timestamps: hits live 14 days, misses 1 day (the database grows,
/// so a missing title is worth re-asking tomorrow but not every single play).
actor SkipTimestampStore {
    static let shared = SkipTimestampStore()

    struct Entry: Codable {
        let fetchedAt: Date
        let spans: [StoredSpan]
        var introEstimateMs: Int?               // intro_length_estimate_ms from SkipDB (nil = not set or no data)
        static func miss() -> Entry { Entry(fetchedAt: Date(), spans: [], introEstimateMs: nil) }
    }

    private var entries: [String: Entry]?

    private var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("skip-timestamps.json")
    }

    func entry(for key: String) -> Entry? {
        loadIfNeeded()
        guard let entry = entries?[key] else { return nil }
        let ttl: TimeInterval = entry.spans.isEmpty ? 86_400 : 14 * 86_400
        guard Date().timeIntervalSince(entry.fetchedAt) < ttl else { return nil }
        return entry
    }

    func store(_ entry: Entry, for key: String) {
        loadIfNeeded()
        entries?[key] = entry
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func introEstimate(for key: String) -> Int? {
        loadIfNeeded()
        return entries?[key]?.introEstimateMs
    }

    func invalidate(for key: String) {
        loadIfNeeded()
        entries?[key] = nil
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func loadIfNeeded() {
        guard entries == nil else { return }
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }
}

/// Layer 2b: AniSkip (api.aniskip.com), the anime-specialized opening/ending/recap timestamp database
/// the desktop anime players use. Keyed by MAL id + episode, which TheIntroDB is not, so it fills the
/// gap for the `kitsu:` / `mal:` ids anime add-ons hand out. Fail-soft throughout: an unmapped id, a
/// 404, or a network error just yields [], and the SegmentResolver clamps whatever comes back.
enum AniSkipService {
    /// Cheap sync check (no network) used by the player's skip gate: AniSkip can handle the anime id
    /// schemes. The actual MAL resolution + fetch happen in `candidates`, which fails soft if they miss.
    static func supports(metaId: String) -> Bool {
        ["kitsu:", "mal:", "anilist:", "anidb:"].contains { metaId.hasPrefix($0) }
    }

    static func candidates(metaId: String, episode: Int?, durationSeconds: Double) async -> [SegmentCandidate] {
        guard durationSeconds > 0, let episode, episode > 0, let mal = await malId(for: metaId) else { return [] }
        guard var components = URLComponents(string: "https://api.aniskip.com/v2/skip-times/\(mal)/\(episode)") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "types[]", value: "op"),
            URLQueryItem(name: "types[]", value: "ed"),
            URLQueryItem(name: "types[]", value: "recap"),
            URLQueryItem(name: "episodeLength", value: String(Int(durationSeconds))),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let res = try? JSONDecoder().decode(Response.self, from: data), res.found else { return [] }
        return res.results.compactMap { r in
            let kind: SkipSegment.Kind
            switch r.skipType {
            case "op": kind = .intro
            case "ed": kind = .credits
            case "recap": kind = .recap
            default: return nil
            }
            return SegmentCandidate(kind: kind, start: r.interval.startTime, end: r.interval.endTime,
                                    source: .crowdAPI, confidence: 0.92)
        }
    }

    /// Resolve a MAL id from a Stremio anime id. `mal:` is direct; `kitsu:` resolves through the Kitsu
    /// mappings API. `anilist:` / `anidb:` are not mapped yet (they need a relations index), so they
    /// fail soft to nil.
    private static func malId(for metaId: String) async -> Int? {
        if metaId.hasPrefix("mal:") {
            return (metaId.dropFirst(4).split(separator: ":").first).flatMap { Int($0) }
        }
        // Take the id token right after the prefix, NOT .last: an episode-qualified id like
        // "kitsu:123:1:2" must resolve from anime id 123, not the trailing episode number.
        if metaId.hasPrefix("kitsu:"), let kitsu = metaId.dropFirst(6).split(separator: ":").first, Int(kitsu) != nil {
            return await kitsuToMal(String(kitsu))
        }
        return nil
    }

    private static func kitsuToMal(_ kitsuId: String) async -> Int? {
        guard let url = URL(string: "https://kitsu.io/api/edge/anime/\(kitsuId)/mappings") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["data"] as? [[String: Any]] else { return nil }
        for row in rows {
            let attrs = row["attributes"] as? [String: Any]
            if (attrs?["externalSite"] as? String) == "myanimelist/anime",
               let ext = attrs?["externalId"] as? String, let id = Int(ext) {
                return id
            }
        }
        return nil
    }

    private struct Response: Decodable {
        let found: Bool
        let results: [Result]
        // AniSkip omits `results` entirely on a not-found episode ({"found": false}); decode soft so
        // that body parses to an empty list instead of throwing a swallowed keyNotFound.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            found = (try? c.decode(Bool.self, forKey: .found)) ?? false
            results = (try? c.decode([Result].self, forKey: .results)) ?? []
        }
        enum CodingKeys: String, CodingKey { case found, results }
        struct Result: Decodable {
            let interval: Interval
            let skipType: String
            enum CodingKeys: String, CodingKey { case interval; case skipType = "skip_type" }
        }
        struct Interval: Decodable {
            let startTime: Double
            let endTime: Double
            enum CodingKeys: String, CodingKey { case startTime = "start_time"; case endTime = "end_time" }
        }
    }
}
