import Foundation
import os

/// Layer 2: crowd-sourced skip timestamps from TheIntroDB (theintrodb.org), the community database
/// behind several media-server skip plugins. Looked up by the IMDB id the app already has from
/// Cinemeta (+ season/episode for series, nothing for movies); reads are anonymous. Results, and
/// misses, cache to disk so an episode costs one request, not one per play, which also keeps us far
/// inside the API's 30-requests-per-10s budget.
enum SkipTimestampService {

    /// Crowd spans for one title, as resolver candidates. Returns [] quietly on any failure: no
    /// network, unknown title, or a non-IMDB id (some add-ons use their own id schemes) just means
    /// the player falls back to the other layers, never an error surfaced mid-playback.
    private static let log = Logger(subsystem: "com.stremiox.app", category: "skiptimes")

    static func candidates(imdbId: String, season: Int?, episode: Int?,
                           durationSeconds: Double) async -> [SegmentCandidate] {
        guard let idItem = queryItem(for: imdbId) else { return [] }
        let key = "\(imdbId):\(season ?? 0):\(episode ?? 0)"
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
        queryItem(for: metaId) != nil
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
        static func miss() -> Entry { Entry(fetchedAt: Date(), spans: []) }
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
