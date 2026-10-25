import Foundation

/// Pure, action-time selection and revocation. Callers supply the current profile's
/// visible projection and retain the real PlaybackMutationTarget beside the ticket.
enum RandomPickPolicy {
    struct Identity: Equatable, Hashable {
        let type: String
        let id: String
    }

    struct Record: Equatable {
        let identity: Identity
        let title: String
        let subtitle: String
        let metadata: [String?]
    }

    struct Ticket: Identifiable, Equatable {
        let id: UUID
        let profileID: UUID?
        let scope: String
        let record: Record
    }

    struct Session {
        private(set) var ticket: Ticket?

        mutating func select<R: RandomNumberGenerator>(
            _ records: [Record], profileID: UUID?, scope: String,
            using generator: inout R
        ) -> Ticket? {
            guard !records.isEmpty else { clear(); return nil }
            let alternatives: [Record]
            if let previous = ticket, previous.profileID == profileID, previous.scope == scope {
                alternatives = records.filter { $0.identity != previous.record.identity }
            } else {
                alternatives = []
            }
            let pool = alternatives.isEmpty ? records : alternatives
            let record = pool[Int.random(in: 0..<pool.count, using: &generator)]
            let selection = Ticket(id: UUID(), profileID: profileID, scope: scope, record: record)
            ticket = selection
            return selection
        }

        func accepts(_ origin: Ticket, profileID: UUID?, scope: String,
                     ownerIsCurrent: Bool, currentRecord: Record?) -> Bool {
            ticket == origin && origin.profileID == profileID && origin.scope == scope
                && ownerIsCurrent && currentRecord == origin.record
        }

        mutating func clear() { ticket = nil }
    }

    /// Captured metadata is also the invalidation receipt. Compare only while a
    /// preview/route exists, from the metadata publisher, never hash history in body.
    struct EpisodeSource: Equatable {
        let identity: Identity
        let name: String
        let poster: String?
        let background: String?
        let videos: [CoreVideo]

    }

    /// Home supplies only currently visible, profile-owned shelves. Prefer its recommendations;
    /// fall back to already-loaded catalogs without another fetch or a hidden catalog traversal.
    struct HomeRecord: Equatable {
        let record: Record
        let releaseInfo: String?
    }

    static func homeRecords(recommendations: [HomeRecord], catalogs: [HomeRecord],
                            watchedIDs: Set<String>, now: Date) -> [Record] {
        let parser = ReleaseParser()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: now)
        func eligible(_ source: [HomeRecord]) -> [Record] {
            var seen = Set<Identity>()
            return source.compactMap { candidate in
                let record = candidate.record
                guard ["movie", "series"].contains(record.identity.type),
                      !record.identity.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !watchedIDs.contains(record.identity.id) else { return nil }
                if let release = candidate.releaseInfo?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    if let date = parser.date(release), date > now { return nil }
                    // Catalog previews often expose a year or year range, not an exact release date.
                    let prefix = release.prefix(4)
                    let boundary = release.dropFirst(4).first
                    if prefix.utf8.count == 4, prefix.utf8.allSatisfy({ (48...57).contains($0) }),
                       boundary.map({ "-–— /".contains($0) }) ?? true,
                       let start = Int(prefix), start > year { return nil }
                }
                return seen.insert(record.identity).inserted ? record : nil
            }
        }
        let preferred = eligible(recommendations)
        return preferred.isEmpty ? eligible(catalogs) : preferred
    }

    static func libraryRecord(_ item: CoreCWItem) -> Record {
        Record(identity: Identity(type: item.type, id: item.id), title: item.name,
               subtitle: item.type.capitalized,
               metadata: [item.poster])
    }

    static func episodeRecord(_ video: CoreVideo, type: String) -> Record {
        Record(identity: Identity(type: type, id: video.id), title: video.episodeTitle,
               subtitle: "S\(video.season ?? 0) · E\(video.episode ?? 0)",
               metadata: [video.title, video.released, video.overview, video.thumbnail,
                          video.season.map(String.init), video.episode.map(String.init)])
    }

    static func eligibleLibraryItems(_ items: [CoreCWItem]) -> [CoreCWItem] {
        var seen = Set<Identity>()
        return items.filter { item in
            guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ["movie", "series"].contains(item.type),
                  !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.removed != true, item.temp != true, item.previouslyWatched != true else { return false }
            return seen.insert(Identity(type: item.type, id: item.id)).inserted
        }
    }

    static func eligibleEpisodes(_ videos: [CoreVideo], now: Date,
                                 knownUnavailableIDs: Set<String> = []) -> [CoreVideo] {
        // One opaque ID with conflicting coordinates cannot identify an exact route.
        // Reject all of its variants rather than make arrival order authoritative.
        var records: [String: CoreVideo] = [:]
        var ambiguous = Set<String>()
        for video in videos {
            if let old = records[video.id], old.season != video.season || old.episode != video.episode {
                ambiguous.insert(video.id)
            }
            records[video.id] = video
        }
        var seen = Set<String>()
        let parser = ReleaseParser()
        return videos.filter { video in
            guard !video.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let season = video.season, let episode = video.episode,
                  season >= 0, episode >= 0, !ambiguous.contains(video.id),
                  !knownUnavailableIDs.contains(video.id) else { return false }
            if let date = parser.date(video.released), date > now { return false }
            return seen.insert(video.id).inserted
        }
    }

    /// CoreVideo's EPG parser accepts timestamps, but community metadata also uses
    /// date-only releases. Strict UTC dates avoid locale/time-zone-dependent picks.
    /// Unknown and malformed values remain unknown; source admission is still final.
    static func releaseDate(_ video: CoreVideo) -> Date? {
        ReleaseParser().date(video.released)
    }

    private struct ReleaseParser {
        let timestamp = ISO8601DateFormatter()
        let fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        func date(_ released: String?) -> Date? {
        guard let released else { return nil }
        let raw = released.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = timestamp.date(from: raw) ?? fractional.date(from: raw) { return date }
        guard raw.utf8.count == 10 else { return nil }
        let pieces = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              raw.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }),
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
              year > 0, (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts),
              calendar.dateComponents([.year, .month, .day], from: date) == parts else { return nil }
        return date
        }
    }
}
