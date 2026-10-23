import Foundation

/// User-specific progress evidence from the documented per-show watched-progress read.
/// This value is not paused playback, local history or permission to publish an external CW row.
enum TraktNextEpisodeProgress {
    static let maximumResponseBytes = 2 * 1024 * 1024
    static let maximumEpisodeRows = 20_000

    enum Failure: Error, Equatable { case invalidShow, invalidResponse, responseTooLarge }
    enum Unavailable: Equatable, Sendable { case rewatchPolicyRequired, incompleteEpisodeEvidence }
    enum Result: Equatable, Sendable {
        case caughtUp
        case unavailable(Unavailable)
        case next(Candidate)
    }
    struct Candidate: Equatable, Sendable {
        let showTraktID: Int
        let episodeTraktID: Int
        let id: String
        let aliases: [String]
        let name: String
        let season: Int
        let episode: Int
        /// The original service activity, including nil when no watch timestamp was supplied.
        let lastWatchedAt: String?
    }

    private struct Wire: Decodable {
        let aired: Int
        let completed: Int
        let lastWatchedAt: String?
        let resetAt: String?
        let nextEpisode: Episode?
        let seasons: [Season]
        let hiddenSeasons: [HiddenSeason]
        enum CodingKeys: String, CodingKey {
            case aired, completed, seasons
            case lastWatchedAt = "last_watched_at", resetAt = "reset_at"
            case nextEpisode = "next_episode", hiddenSeasons = "hidden_seasons"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            aired = try values.decode(Int.self, forKey: .aired)
            completed = try values.decode(Int.self, forKey: .completed)
            lastWatchedAt = try values.decodeIfPresent(String.self, forKey: .lastWatchedAt)
            // Missing required null-bearing fields are not a truthful caught-up response.
            guard values.contains(.resetAt), values.contains(.nextEpisode) else { throw Failure.invalidResponse }
            resetAt = try values.decodeIfPresent(String.self, forKey: .resetAt)
            nextEpisode = try values.decodeIfPresent(Episode.self, forKey: .nextEpisode)
            seasons = try values.decode([Season].self, forKey: .seasons)
            hiddenSeasons = try values.decode([HiddenSeason].self, forKey: .hiddenSeasons)
        }
    }
    private struct Episode: Decodable {
        let season: Int
        let number: Int
        let ids: TraktIDs
        let firstAired: String?
        enum CodingKeys: String, CodingKey { case season, number, ids; case firstAired = "first_aired" }
    }
    private struct Season: Decodable {
        let number: Int
        let aired: Int
        let completed: Int
        let episodes: [EpisodeState]
    }
    private struct EpisodeState: Decodable { let number: Int; let completed: Bool }
    private struct HiddenSeason: Decodable { let number: Int }

    /// The service endpoint, not absence from a partial watched-key set, selects next_episode.
    /// A matching explicit completed:false row is also required before a candidate is returned.
    nonisolated static func decode(_ data: Data, show: TraktShow, now: Date) async throws -> Result {
        try Task.checkCancellation()
        guard let showTraktID = show.ids.trakt, showTraktID > 0,
              let name = show.title, !name.isEmpty,
              now.timeIntervalSince1970.isFinite else { throw Failure.invalidShow }
        guard data.count <= maximumResponseBytes else { throw Failure.responseTooLarge }
        let wire: Wire
        do {
            try VortxNativeBootstrapArchive.requireUnambiguousJSON(data)
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch { throw Failure.invalidResponse }
        guard wire.aired >= 0, wire.completed >= 0, wire.completed <= wire.aired else { throw Failure.invalidResponse }
        if let raw = wire.lastWatchedAt, date(raw) == nil { throw Failure.invalidResponse }
        if let raw = wire.resetAt {
            guard date(raw) != nil else { throw Failure.invalidResponse }
            return .unavailable(.rewatchPolicyRequired)
        }
        var seasonNumbers = Set<Int>(), hiddenNumbers = Set<Int>(), count = 0
        var states: [Int: [Int: Bool]] = [:]
        for hidden in wire.hiddenSeasons {
            guard hidden.number >= 0, hiddenNumbers.insert(hidden.number).inserted else { throw Failure.invalidResponse }
        }
        for season in wire.seasons {
            guard season.number >= 0, seasonNumbers.insert(season.number).inserted,
                  season.aired >= 0, season.completed >= 0, season.completed <= season.aired else { throw Failure.invalidResponse }
            var episodes: [Int: Bool] = [:]
            for episode in season.episodes {
                count += 1
                guard count <= maximumEpisodeRows, episode.number > 0, episodes[episode.number] == nil else { throw Failure.invalidResponse }
                episodes[episode.number] = episode.completed
            }
            states[season.number] = episodes
        }
        try Task.checkCancellation()
        guard let next = wire.nextEpisode else { return .caughtUp }
        guard next.season > 0, next.number > 0, let episodeTraktID = next.ids.trakt, episodeTraktID > 0,
              !hiddenNumbers.contains(next.season) else { throw Failure.invalidResponse }
        if let raw = next.firstAired {
            guard let aired = date(raw), aired <= now else { throw Failure.invalidResponse }
        }
        guard states[next.season]?[next.number] == false else { return .unavailable(.incompleteEpisodeEvidence) }
        var identities: [String] = []
        if let imdb = show.ids.imdb, imdb.hasPrefix("tt"), imdb.count > 2, imdb.dropFirst(2).allSatisfy(\.isNumber) {
            identities.append(imdb)
        }
        if let tmdb = show.ids.tmdb, tmdb > 0 { identities += ["tmdb:tv:\(tmdb)", "tmdb:\(tmdb)"] }
        guard let id = identities.first else { throw Failure.invalidShow }
        return .next(Candidate(showTraktID: showTraktID, episodeTraktID: episodeTraktID, id: id,
            aliases: Array(identities.dropFirst()), name: name, season: next.season, episode: next.number,
            lastWatchedAt: wire.lastWatchedAt))
    }
    private static func date(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
