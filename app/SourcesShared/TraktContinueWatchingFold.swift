import Foundation

/// A provider-neutral value produced from one Trakt `/sync/playback` row.
///
/// This file stays Foundation-only so its identity and ordering contract can be tested with the system
/// Swift toolchain, without linking an app target or making a network request.
struct TraktContinueWatchingSeed: Codable, Equatable, Sendable {
    let id: String
    let type: String
    let name: String
    let progress: Double
    let pausedAt: String
    let runtimeMinutes: Double?
    let videoID: String?
    /// Artwork already held by the app for the same title. Trakt rows do not provide artwork, and folding
    /// one must not trigger a new metadata request.
    var poster: String?

    var durationSeconds: Double? {
        guard let runtimeMinutes, runtimeMinutes.isFinite, runtimeMinutes > 0 else { return nil }
        return runtimeMinutes * 60
    }

    /// The exact offset represented by the percentage shown on the card.
    var resumeSeconds: Double? {
        guard let durationSeconds, progress.isFinite, progress > 0 else { return nil }
        return durationSeconds * progress / 100
    }
}

/// Movie and episode pause activity are independent Trakt cursors. Collapsing them with `max()` loses a
/// change on the older side whenever the newer side's timestamp stays unchanged.
struct TraktPlaybackActivityStamps: Codable, Equatable, Sendable {
    let movies: String?
    let episodes: String?

    /// Kept in the cache as a downgrade-compatible copy for app versions that only know one cursor.
    var legacyMaximum: String? {
        [movies, episodes].compactMap { $0 }.max()
    }
}

enum TraktContinueWatchingFold {
    /// Convert Trakt's mixed movie and episode playback rows into one ordered title row per movie/show.
    ///
    /// The newest paused episode wins when a show has more than one paused episode. Rows at or beyond
    /// 95 percent are excluded because VortX treats that region as completion/credits rather than a useful
    /// resume point.
    static func fold(_ rows: [[String: Any]]) -> [TraktContinueWatchingSeed] {
        let candidates = rows.compactMap(seed)
            .sorted {
                if $0.pausedAt != $1.pausedAt { return $0.pausedAt > $1.pausedAt }
                return $0.id < $1.id
            }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }

    private static func seed(_ row: [String: Any]) -> TraktContinueWatchingSeed? {
        guard let progress = number(row["progress"]),
              progress > 0, progress < 95 else { return nil }
        let pausedAt = row["paused_at"] as? String ?? ""

        switch row["type"] as? String {
        case "movie":
            guard let movie = row["movie"] as? [String: Any],
                  let ids = movie["ids"] as? [String: Any],
                  let id = identity(ids, isSeries: false) else { return nil }
            let name = movie["title"] as? String ?? ""
            guard !name.isEmpty else { return nil }
            return TraktContinueWatchingSeed(
                id: id,
                type: "movie",
                name: name,
                progress: progress,
                pausedAt: pausedAt,
                runtimeMinutes: positiveNumber(movie["runtime"]),
                videoID: nil,
                poster: nil
            )

        case "episode":
            guard let episode = row["episode"] as? [String: Any],
                  let show = row["show"] as? [String: Any],
                  let ids = show["ids"] as? [String: Any],
                  let id = identity(ids, isSeries: true),
                  let season = nonNegativeInt(episode["season"]),
                  let number = nonNegativeInt(episode["number"]) else { return nil }
            let name = show["title"] as? String ?? ""
            guard !name.isEmpty else { return nil }
            return TraktContinueWatchingSeed(
                id: id,
                type: "series",
                name: name,
                progress: progress,
                pausedAt: pausedAt,
                runtimeMinutes: positiveNumber(episode["runtime"]),
                videoID: "\(id):\(season):\(number)",
                poster: nil
            )

        default:
            return nil
        }
    }

    private static func identity(_ ids: [String: Any], isSeries: Bool) -> String? {
        if let imdb = ids["imdb"] as? String, !imdb.isEmpty { return imdb }
        guard let tmdb = positiveInt(ids["tmdb"]) else { return nil }
        return isSeries ? "tmdb:tv:\(tmdb)" : "tmdb:movie:\(tmdb)"
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let n = number(value), n.isFinite else { return nil }
        let i = Int(n)
        return i > 0 ? i : nil
    }

    private static func nonNegativeInt(_ value: Any?) -> Int? {
        guard let n = number(value), n.isFinite else { return nil }
        let i = Int(n)
        return i >= 0 ? i : nil
    }

    private static func positiveNumber(_ value: Any?) -> Double? {
        guard let n = number(value), n > 0 else { return nil }
        return n
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? Double, n.isFinite { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let value = value as? String, let n = Double(value), n.isFinite { return n }
        return nil
    }
}
