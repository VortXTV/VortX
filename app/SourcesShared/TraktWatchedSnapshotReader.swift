import Foundation
import CoreFoundation

/// Known projections plus the exact original provider row. Encoding only the raw carrier makes a
/// reload revalidate the projection instead of trusting independently mutable duplicate fields.
struct TraktWatchedShowInventoryEntry: Codable, Sendable, Equatable {
    let traktID: Int
    let show: TraktShow
    let lastWatchedAt: String?
    let rawRowJSON: Data

    init(rawRowJSON: Data) throws {
        let fields = try VortxNativeBootstrapArchive.rawJSONObjectMembers(
            rawRowJSON, maximumBytes: 8 * 1024 * 1024
        )
        guard let showField = fields.first(where: { $0.key == "show" }) else {
            throw TraktWatchedSnapshotReader.Failure.invalidPage
        }
        let show = try JSONDecoder().decode(TraktShow.self, from: showField.valueJSON)
        guard let id = show.ids.trakt, id > 0 else { throw TraktWatchedSnapshotReader.Failure.invalidPage }
        let stamp: String?
        if let field = fields.first(where: { $0.key == "last_watched_at" }) {
            stamp = try JSONDecoder().decode(String?.self, from: field.valueJSON)
        } else { stamp = nil }
        self.traktID = id; self.show = show; self.lastWatchedAt = stamp; self.rawRowJSON = rawRowJSON
    }
    init(from decoder: Decoder) throws {
        try self.init(rawRowJSON: decoder.singleValueContainer().decode(Data.self))
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawRowJSON)
    }
}

struct TraktWatchedShowInventory: Sendable, Equatable {
    let sessionID: TraktSessionID
    /// Transaction identity, not a watch event or timestamp. Recheck it after every consumer await.
    let revision: UUID
    let readVersion: Int
    let activityFingerprint: String?
    let entries: [TraktWatchedShowInventoryEntry]
}

/// A selected Home Continue Watching lane may read the account inventory without enabling badge
/// import. Its captured intent predicate must be cheap, synchronous and side-effect-free.
enum TraktWatchedReadPurpose: Sendable {
    case badgeImport
    case selectedContinueWatching(isCurrent: @Sendable () -> Bool)
}

/// A complete, positive-only watched-badge snapshot. No absence in these sets is unwatched or
/// next-episode authority. The caller owns the account/generation fence and the atomic cache commit.
enum TraktWatchedSnapshotReader {
    /// Old cached cursors may describe only the first default page. Keep their old badge sets visible,
    /// but do not use their cursor to skip the first successful read with this contract.
    static let readVersion = 1

    struct Snapshot: Sendable, Equatable {
        let watchedIDs: Set<String>
        let episodeKeys: Set<String>
        let activityFingerprint: String?
        let shows: [TraktWatchedShowInventoryEntry]
    }

    struct Limits: Sendable {
        var pageSize = 250
        var pagesPerType = 1_000
        var rows = 100_000
        var pageBytes = 8 * 1024 * 1024
        var aggregateBytes = 64 * 1024 * 1024
        var episodeKeys = 300_000
    }

    enum Failure: Error, Equatable {
        case staleSession
        case invalidPage
        case duplicateTitle
        case exceededLimit
    }

    /// nil means a positively matching, versioned activity cursor; it is not an empty account.
    /// A thrown error or cancellation produces no snapshot, even if earlier pages/legs succeeded.
    ///
    /// Trakt can return fewer rows than `limit` for `extended=progress`. Only an actual empty page
    /// proves completion here; a short nonempty page never does. The same per-page transport cap is
    /// also checked at this boundary, with aggregate row/byte/page/key bounds across the whole pull.
    static func read(
        previousFingerprint: String?,
        previousReadVersion: Int?,
        limits: Limits = Limits(),
        isCurrent: () -> Bool,
        parsingIsCurrent: () -> Bool,
        request: (String) async throws -> Data
    ) async throws -> Snapshot? {
        guard (1...250).contains(limits.pageSize), limits.pagesPerType > 0,
              limits.rows >= 0, limits.pageBytes >= 0, limits.aggregateBytes >= 0,
              limits.episodeKeys >= 0 else { throw Failure.exceededLimit }
        try checkCurrent(isCurrent)
        var totalBytes = 0
        var fingerprint: String?
        // The cheap gate still fails open on a provider error, but never on cancellation or a retired
        // account. Its body counts toward the aggregate budget if a full pull follows.
        do {
            let data = try await request("/sync/last_activities")
            try checkCurrent(isCurrent)
            try consume(data, total: &totalBytes, limits: limits)
            _ = try VortxNativeBootstrapArchive.rawJSONObjectMembers(data, maximumBytes: limits.pageBytes)
            guard let root = try json(data) as? [String: Any] else { throw Failure.invalidPage }
            let movies = (root["movies"] as? [String: Any])?["watched_at"] as? String
            let episodes = (root["episodes"] as? [String: Any])?["watched_at"] as? String
            if movies != nil || episodes != nil {
                fingerprint = "\(movies ?? "-")|\(episodes ?? "-")"
            }
        } catch {
            try checkCurrent(isCurrent)
            if error is CancellationError { throw error }
            // A successfully received over-budget control response must not evade the pull's cap.
            if let failure = error as? Failure, failure == .exceededLimit { throw failure }
        }
        try checkCurrent(isCurrent)
        if previousReadVersion == readVersion, let fingerprint,
           fingerprint == previousFingerprint { return nil }

        var watched = Set<String>()
        var episodes = Set<String>()
        var shows: [TraktWatchedShowInventoryEntry] = []
        var totalRows = 0
        for type in ["movies", "shows"] {
            let isSeries = type == "shows"
            var seenTitles = Set<Int>()
            var completed = false
            for page in 1...limits.pagesPerType {
                try checkCurrent(isCurrent)
                let path = "/sync/watched/\(type)?page=\(page)&limit=\(limits.pageSize)"
                    + (isSeries ? "&extended=progress" : "")
                let data = try await request(path)
                try checkCurrent(isCurrent)
                try consume(data, total: &totalBytes, limits: limits)
                guard let rows = try json(data) as? [[String: Any]] else {
                    throw Failure.invalidPage
                }
                guard rows.count <= limits.pageSize, rows.count <= limits.rows - totalRows else {
                    throw Failure.exceededLimit
                }
                let rawRows: [Data]
                do {
                    rawRows = try VortxNativeBootstrapArchive.rawJSONArrayValues(
                        data, maximumBytes: limits.pageBytes, maximumValues: limits.pageSize
                    )
                } catch { throw Failure.invalidPage }
                guard rawRows.count == rows.count else { throw Failure.invalidPage }
                if rows.isEmpty {
                    completed = true
                    break
                }
                totalRows += rows.count
                for (rowIndex, row) in rows.enumerated() {
                    // In-memory generation/cancellation only. Credential storage must not be
                    // accessed once per provider-controlled row/season/episode.
                    try checkCurrent(parsingIsCurrent)
                    guard let title = row[isSeries ? "show" : "movie"] as? [String: Any],
                          let ids = title["ids"] as? [String: Any],
                          let traktID = integer(ids["trakt"]), traktID > 0 else {
                        throw Failure.invalidPage
                    }
                    // A repeated title within/across pages cannot establish a complete traversal.
                    // Fail closed even when its timestamps/metadata changed or row order was shuffled.
                    guard seenTitles.insert(traktID).inserted else { throw Failure.duplicateTitle }
                    // Prevent a large provider-controlled string being multiplied by every episode.
                    // Only the existing catalog identity forms are folded; no title/slug is guessed.
                    if let imdb = ids["imdb"], !(imdb is NSNull) {
                        guard let value = imdb as? String, value.utf8.count <= 32,
                              value.isEmpty || (value.hasPrefix("tt") && value.utf8.count > 2
                                && value.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) })) else {
                            throw Failure.invalidPage
                        }
                    }
                    if let tmdb = ids["tmdb"], !(tmdb is NSNull) {
                        guard let value = integer(tmdb), value > 0 else { throw Failure.invalidPage }
                    }
                    let identities = TraktWatchedFold.titleIdentities(ids, isSeries: isSeries)
                    watched.formUnion(identities)
                    if isSeries {
                        let entry: TraktWatchedShowInventoryEntry
                        do { entry = try TraktWatchedShowInventoryEntry(rawRowJSON: rawRows[rowIndex]) }
                        catch { throw Failure.invalidPage }
                        guard entry.traktID == traktID else { throw Failure.invalidPage }
                        shows.append(entry)
                        // Missing progress is not a truthful empty episode history. In particular, a
                        // response with the new default shape must not erase the old episode badges.
                        guard let seasons = row["seasons"] as? [[String: Any]] else {
                            throw Failure.invalidPage
                        }
                        for season in seasons {
                            try checkCurrent(parsingIsCurrent)
                            guard let seasonNumber = integer(season["number"]),
                                  let items = season["episodes"] as? [[String: Any]] else {
                                throw Failure.invalidPage
                            }
                            for item in items {
                                try checkCurrent(parsingIsCurrent)
                                guard let episodeNumber = integer(item["number"]) else {
                                    throw Failure.invalidPage
                                }
                                for identity in identities {
                                    episodes.insert(TraktWatchedFold.episodeKey(
                                        identity, seasonNumber, episodeNumber
                                    ))
                                    guard episodes.count <= limits.episodeKeys else {
                                        throw Failure.exceededLimit
                                    }
                                }
                            }
                        }
                    }
                }
            }
            guard completed else { throw Failure.exceededLimit }
        }
        try checkCurrent(isCurrent)
        return Snapshot(watchedIDs: watched, episodeKeys: episodes, activityFingerprint: fingerprint, shows: shows)
    }

    private static func checkCurrent(_ isCurrent: () -> Bool) throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw Failure.staleSession }
    }

    private static func consume(_ data: Data, total: inout Int, limits: Limits) throws {
        guard data.count <= limits.pageBytes, data.count <= limits.aggregateBytes - total else {
            throw Failure.exceededLimit
        }
        total += data.count
    }

    private static func json(_ data: Data) throws -> Any {
        guard String(data: data, encoding: .utf8) != nil else { throw Failure.invalidPage }
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw Failure.invalidPage }
    }

    /// Preserve the existing numeric-string tolerance, but never treat a JSON boolean/fraction as
    /// a Trakt title id or an episode coordinate. Season zero remains the specials season.
    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           let parsed = value as? Int, parsed >= 0 { return parsed }
        if let string = value as? String, let parsed = Int(string), parsed >= 0 { return parsed }
        return nil
    }
}
