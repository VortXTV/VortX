import Foundation

/// A vertical TV list gets one initial placement per title/profile and season. Reuse the phone's
/// one-shot ownership, but select a resumable/aired row before asking the TV lazy list to seat focus.
struct TVEpisodeInitialPositionPolicy {
    private var position = EpisodeRailInitialPositionPolicy()

    /// Add-ons may use either ISO timestamps or calendar days. Missing/unparseable dates remain
    /// eligible for older inventories, while a known future release never becomes the initial row.
    static func isEligible(releasedDate: Date?, released: String?, asOf now: Date) -> Bool {
        if let releasedDate { return releasedDate <= now }
        guard let released, released.count >= 10 else { return true }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: String(released.prefix(10))) else { return true }
        return day <= now
    }

    static func preferredIndex(ids: [String], eligibleIDs: Set<String>, watched: Set<String>,
                               currentID: String?, currentInProgress: Bool) -> Int? {
        let eligible = ids.indices.filter { eligibleIDs.contains(ids[$0]) }
        guard let first = eligible.first else { return nil }
        if let currentID, let current = eligible.first(where: { ids[$0] == currentID }) {
            if currentInProgress, !watched.contains(currentID) { return current }
            if watched.contains(currentID),
               let next = eligible.first(where: { $0 > current && !watched.contains(ids[$0]) }) { return next }
        }
        return eligible.first { !watched.contains(ids[$0]) } ?? first
    }

    mutating func claim(scope: String, season: Int, ids: [String], eligibleIDs: Set<String>,
                        watched: Set<String>, currentID: String?, currentInProgress: Bool,
                        ready: Bool) -> Int? {
        guard let index = Self.preferredIndex(ids: ids, eligibleIDs: eligibleIDs, watched: watched,
                                             currentID: currentID, currentInProgress: currentInProgress),
              position.claim(scope: scope, season: season, ids: ids, watched: watched, ready: ready) != nil
        else { return nil }
        return index
    }

    mutating func userInteracted(scope: String, season: Int) {
        position.userInteracted(scope: scope, season: season)
    }
}
