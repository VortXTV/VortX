import Foundation
import CoreFoundation

struct SIMKLContinueWatchingSeed: Equatable, Sendable {
    let key: String
    let id: String
    var aliases: [String]
    let type: String
    let name: String
    let activity: String?
    let progress: Double?
    let videoID: String?
    let caption: String?
}

/// Foundation-only wire fold. A next episode is not a partially played episode.
enum SIMKLContinueWatchingFold {
    struct Change: Sendable {
        let type: String
        let identities: Set<String>
        let seed: SIMKLContinueWatchingSeed?
    }
    static func entries(_ data: Data) throws -> [String: Change] {
        guard !data.isEmpty else { return [:] }
        let root = try JSONSerialization.jsonObject(with: data)
        if root is NSNull { return [:] }
        guard let envelope = root as? [String: Any] else { throw SIMKLError.decoding }
        var result: [String: Change] = [:]
        for bucket in ["movies", "shows", "anime"] {
            guard let raw = envelope[bucket] else { continue }
            guard let rows = raw as? [[String: Any]] else { throw SIMKLError.decoding }
            for row in rows {
                let type = bucket == "movies" || row["anime_type"] as? String == "movie" ? "movie" : "series"
                guard let media = row[bucket == "movies" ? "movie" : "show"] as? [String: Any],
                      let identity = identity(media, series: type == "series") else { continue }
                let key = bucket + "|" + identity.key
                let identities = Set([identity.id] + identity.aliases)
                guard row["status"] as? String == "watching",
                      bucket != "movies", row["anime_type"] as? String != "movie",
                      let next = row["next_to_watch"] as? String, !next.isEmpty else {
                    result[key] = Change(type: type, identities: identities, seed: nil); continue
                }
                let info = row["next_to_watch_info"] as? [String: Any]
                let coordinates = coordinates(next, info: info, anime: bucket == "anime")
                result[key] = Change(type: type, identities: identities, seed: SIMKLContinueWatchingSeed(
                    key: key, id: identity.id, aliases: identity.aliases, type: "series",
                    name: media["title"] as? String ?? identity.id,
                    activity: row["last_watched_at"] as? String ?? (row["last_watched"] as? [String: Any])?["watched_at"] as? String,
                    progress: nil, videoID: coordinates.map { "\(identity.id):\($0.0):\($0.1)" },
                    caption: "Up next · " + next))
            }
        }
        return result
    }
    static func playback(_ data: Data) throws -> [SIMKLContinueWatchingSeed] {
        guard !data.isEmpty else { return [] }
        let root = try JSONSerialization.jsonObject(with: data)
        if root is NSNull { return [] }
        guard let rows = root as? [[String: Any]] else { throw SIMKLError.decoding }
        // A full-limit response may be truncated; it is not a certified complete snapshot.
        guard rows.count < 10_000 else { throw SIMKLError.decoding }
        return rows.compactMap { row in
            let movie = row["movie"] as? [String: Any]
            let media = movie ?? row["show"] as? [String: Any] ?? row["anime"] as? [String: Any]
            guard let media else { return nil }
            let anime = row["anime"] != nil || row["type"] as? String == "anime"
            let series = movie == nil && row["anime_type"] as? String != "movie" && media["anime_type"] as? String != "movie"
            guard let identity = identity(media, series: series),
                  let value = number(row["progress"]) else { return nil }
            let progress = value.doubleValue
            guard progress.isFinite, progress > 0, progress < 95 else { return nil }
            let episode = row["episode"] as? [String: Any]
            // A mapping is one complete pair, never half TVDB + half AniDB. Anime's absolute
            // numbering is not an engine season; retain the card if its TVDB map is unavailable.
            let mapped = episodePair(season: episode?["tvdb_season"], episode: episode?["tvdb_number"])
            let ordinary = anime ? nil : episodePair(season: episode?["season"], episode: episode?["number"] ?? episode?["episode"])
            let video = (mapped ?? ordinary).map { "\(identity.id):\($0.0):\($0.1)" }
            return SIMKLContinueWatchingSeed(key: "playback|" + identity.key,
                id: identity.id, aliases: identity.aliases, type: series ? "series" : "movie",
                name: media["title"] as? String ?? identity.id,
                activity: row["watched_at"] as? String ?? row["paused_at"] as? String,
                progress: progress / 100, videoID: video,
                caption: "Paused · \(Int(progress.rounded()))%")
        }
    }
    /// Paused playback wins over up-next for the same typed identity, regardless of list activity.
    static func merge(watching: [SIMKLContinueWatchingSeed], playback: [SIMKLContinueWatchingSeed]) -> [SIMKLContinueWatchingSeed] {
        var kept: [SIMKLContinueWatchingSeed] = []
        let pauses = playback.sorted {
            let a = ContinueWatchingPreferences.activity($0.activity) ?? .distantPast
            let b = ContinueWatchingPreferences.activity($1.activity) ?? .distantPast
            return a == b ? $0.key < $1.key : a > b
        }
        for seed in pauses + watching.sorted(by: { $0.key < $1.key }) {
            let identities = Set([seed.id] + seed.aliases)
            let duplicates = kept.indices.filter { kept[$0].type == seed.type && !identities.isDisjoint(with: Set([kept[$0].id] + kept[$0].aliases)) }
            guard let first = duplicates.first else { kept.append(seed); continue }
            var union = identities
            for index in duplicates { union.formUnion([kept[index].id] + kept[index].aliases) }
            kept[first].aliases = union.filter { $0 != kept[first].id }.sorted()
            for index in duplicates.dropFirst().reversed() { kept.remove(at: index) }
        }
        return kept
    }
    private static func identity(_ media: [String: Any], series: Bool) -> (key: String, id: String, aliases: [String])? {
        guard let ids = media["ids"] as? [String: Any] else { return nil }
        let imdb = (ids["imdb"] as? String).flatMap { $0.hasPrefix("tt") && $0.dropFirst(2).allSatisfy(\.isNumber) && $0.count > 2 ? $0 : nil }
        let tmdb = integer(ids["tmdb"]).flatMap { $0 > 0 ? $0 : nil }
        let typed = tmdb.map { "tmdb:\(series ? "tv" : "movie"):\($0)" }
        let simkl = integer(ids["simkl"]).flatMap { $0 > 0 ? $0 : nil }
        let native = simkl.map { "simkl:\(series ? "series" : "movie"):\($0)" }
        guard let id = imdb ?? typed ?? native else { return nil }
        let aliases = [imdb, typed, tmdb.map { "tmdb:\($0)" }, native, simkl.map { "simkl:\($0)" }]
            .compactMap { $0 }.filter { $0 != id }
        return (simkl.map { "simkl:\($0)" } ?? id, id, aliases)
    }
    /// Source-only identities remain visible, but must never enter a generic metadata/stream
    /// resolver. Likewise, an unmapped episode is not permission to guess season one.
    static func unavailableReason(id: String, type: String, videoID: String?) -> String? {
        if id.hasPrefix("simkl:") { return "This SIMKL title has no supported IMDB or TMDB playback identity. Its service activity is read-only." }
        if type == "series", videoID == nil { return "SIMKL has not supplied a complete mapped season and episode for this title. Its service activity is read-only." }
        return nil
    }
    private static func episodePair(season: Any?, episode: Any?) -> (Int, Int)? {
        guard let season = integer(season), let episode = integer(episode), episode > 0 else { return nil }
        return (season, episode)
    }
    private static func integer(_ value: Any?) -> Int? {
        if let text = value as? String {
            guard let value = Int(text), value >= 0 else { return nil }
            return value
        }
        guard let n = number(value),
              n.doubleValue.rounded() == n.doubleValue, n.doubleValue < Double(Int.max), n.doubleValue >= 0 else { return nil }
        return n.intValue
    }
    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number
    }
    private static func coordinates(_ raw: String, info: [String: Any]?, anime: Bool) -> (Int, Int)? {
        var marker: (Int, Int)?
        if let regex = try? NSRegularExpression(pattern: "^S([0-9]+)E([0-9]+)$", options: .caseInsensitive),
           let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let sr = Range(match.range(at: 1), in: raw), let er = Range(match.range(at: 2), in: raw),
           let s = Int(raw[sr]), let e = Int(raw[er]), e > 0 { marker = (s, e) }
        if let rawSeason = info?["season"] {
            guard let season = integer(rawSeason), marker.map({ $0.0 == season }) ?? true else { return nil }
        }
        if let rawEpisode = info?["episode"] {
            guard let episode = integer(rawEpisode), episode > 0, marker.map({ $0.1 == episode }) ?? true else { return nil }
        }
        if let pair = episodePair(season: info?["season"], episode: info?["episode"]) { return pair }
        // Anime markers are AniDB numbering, not evidence of a mapped engine season.
        return anime ? nil : marker
    }
}

protocol SIMKLContinueWatchingTransport: Sendable {
    func continueWatchingRead(path: String, query: [String: String], session: SIMKLSessionID) async throws -> Data
    func continueWatchingSessionIsCurrent(_ session: SIMKLSessionID) -> Bool
}

/// Exact-session in-memory replica. Delta rows are changes, never a complete replacement.
actor SIMKLContinueWatchingReader {
    struct Snapshot: Sendable {
        var items: [SIMKLContinueWatchingSeed] = []
        var hasSnapshot = false
        var failed = false
    }
    private var session: SIMKLSessionID?
    private var generation = 0
    private var activity: [String: String] = [:]
    private var watching: [String: SIMKLContinueWatchingSeed] = [:]
    private var playback: [SIMKLContinueWatchingSeed] = []
    private var state = Snapshot()

    func refresh(session expected: SIMKLSessionID, transport: any SIMKLContinueWatchingTransport) async -> Snapshot {
        if session != expected {
            generation &+= 1; session = expected; activity = [:]; watching = [:]; playback = []; state = Snapshot()
        }
        // Actor methods can re-enter while a transport leg suspends. A later refresh retires an
        // older response even for the same account, so it cannot roll the cursor/snapshot back.
        generation &+= 1
        let captured = generation
        do {
            let data = try await transport.continueWatchingRead(path: "/sync/activities", query: [:], session: expected)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawAll = root["all"] else { throw SIMKLError.decoding }
            // Explicit null means no recorded activity, not a fabricated timestamp/cursor.
            let all = rawAll as? String
            guard rawAll is NSNull || all.flatMap(ContinueWatchingPreferences.activity) != nil else { throw SIMKLError.decoding }
            var nextActivity: [String: String] = [:]
            if let all { nextActivity["all"] = all }
            for bucket in ["movies", "tv_shows", "anime"] {
                let values = root[bucket] as? [String: Any] ?? [:]
                for field in ["all", "watching", "playback", "removed_from_list"] {
                    if let value = values[field] as? String { nextActivity[bucket + "." + field] = value }
                }
            }
            let full = !state.hasSnapshot || all == nil || ["movies", "tv_shows", "anime"].contains {
                nextActivity[$0 + ".removed_from_list"] != activity[$0 + ".removed_from_list"]
            }
            var nextWatching = full ? [:] : watching
            var nextPlayback = playback
            if full || nextActivity["all"] != activity["all"] {
                // Complete every type before committing. Status transitions remove previous watching rows.
                for type in ["movies", "shows", "anime"] {
                    var query = ["next_watch_info": "yes"]
                    if !full, all != nil, let cursor = activity["all"] { query["date_from"] = cursor }
                    let changes = try SIMKLContinueWatchingFold.entries(await transport.continueWatchingRead(
                        path: "/sync/all-items/\(type)", query: query, session: expected))
                    for key in changes.keys.sorted() {
                        guard let change = changes[key] else { continue }
                        let matching = nextWatching.filter {
                            $0.key == key || ($0.value.type == change.type && !change.identities.isDisjoint(with: Set([$0.value.id] + $0.value.aliases)))
                        }
                        for old in matching.keys { nextWatching.removeValue(forKey: old) }
                        if var seed = change.seed {
                            var identities = change.identities
                            for old in matching.values { identities.formUnion([old.id] + old.aliases) }
                            seed.aliases = identities.filter { $0 != seed.id }.sorted()
                            nextWatching[key] = seed
                        }
                    }
                }
            }
            // Paused records can expire without an activities/tombstone change. Reconcile the
            // complete paused set on each throttled refresh before advancing any list cursor.
            nextPlayback = try SIMKLContinueWatchingFold.playback(await transport.continueWatchingRead(
                path: "/sync/playback", query: ["limit": "10000"], session: expected))
            guard generation == captured, session == expected, transport.continueWatchingSessionIsCurrent(expected) else { return Snapshot() }
            watching = nextWatching; playback = nextPlayback; activity = nextActivity
            state = Snapshot(items: SIMKLContinueWatchingFold.merge(watching: Array(watching.values), playback: playback), hasSnapshot: true)
        } catch {
            guard generation == captured, session == expected, transport.continueWatchingSessionIsCurrent(expected) else { return Snapshot() }
            state.failed = true // Keep the prior complete snapshot AND cursor for retry.
        }
        return state
    }
}
