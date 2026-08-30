import Foundation

/// Order-stable Continue Watching identity fold shared by engine, recovery, and profile rails.
///
/// Identity is provider-backed only. The display id and any independently-carried aliases (normally the played
/// episode id) are reduced to canonical title ids. Name and poster are deliberately absent: artwork URLs and
/// localized titles are mutable presentation, while matching on either can merge unrelated same-name releases.
/// Alias overlap is transitive, so a row carrying both TMDB and IMDb identities joins rows carrying either one.
enum ContinueWatchingDedupe {
    struct Identity: Equatable {
        let id: String
        let type: String
        let aliases: [String]
        /// Epoch-like freshness supplied by the caller. nil means the caller's source order is authoritative.
        let freshness: Double?
        /// A live row must carry a usable resume state. Explicit removals are valid without progress.
        let hasValidProgress: Bool
        let removed: Bool

        init(id: String, type: String, aliases: [String] = [], freshness: Double? = nil,
             hasValidProgress: Bool = true, removed: Bool = false) {
            self.id = id
            self.type = type
            self.aliases = aliases
            self.freshness = freshness
            self.hasValidProgress = hasValidProgress
            self.removed = removed
        }
    }

    private struct Candidate<Item> {
        let item: Item
        let identity: Identity
        let keys: Set<String>
        let sourceIndex: Int
    }

    private struct Group<Item> {
        var candidates: [Candidate<Item>]
        var keys: Set<String>
        let firstIndex: Int
    }

    static func fold<Item>(
        _ items: [Item],
        identity: (Item) -> Identity
    ) -> [Item] {
        var groups: [Group<Item>] = []
        for (sourceIndex, item) in items.enumerated() {
            let value = identity(item)
            let keys = identityKeys(value)
            guard !keys.isEmpty else { continue }
            let candidate = Candidate(item: item, identity: value, keys: keys, sourceIndex: sourceIndex)
            let matches = groups.indices.filter { !groups[$0].keys.isDisjoint(with: keys) }
            guard let target = matches.first else {
                groups.append(Group(candidates: [candidate], keys: keys, firstIndex: sourceIndex))
                continue
            }

            groups[target].candidates.append(candidate)
            groups[target].keys.formUnion(keys)
            // A bridge row can join two groups that appeared independently earlier. Merge every intersecting
            // component now so dedupe never depends on which provider alias happened to arrive first.
            for index in matches.dropFirst().reversed() {
                groups[target].candidates.append(contentsOf: groups[index].candidates)
                groups[target].keys.formUnion(groups[index].keys)
                groups.remove(at: index)
            }
        }

        return groups.sorted { $0.firstIndex < $1.firstIndex }.compactMap { group in
            let eligible = group.candidates.filter { $0.identity.removed || $0.identity.hasValidProgress }
            // Preserve the engine's existing fail-soft membership when every row is sparse. A valid row still
            // always beats that fallback as soon as one exists in the component.
            guard var winner = eligible.first ?? group.candidates.first else { return nil }
            for candidate in eligible.dropFirst() where preferred(candidate, over: winner) {
                winner = candidate
            }
            return winner.identity.removed ? nil : winner.item
        }
    }

    private static func preferred<Item>(_ candidate: Candidate<Item>, over incumbent: Candidate<Item>) -> Bool {
        let candidateFreshness = candidate.identity.freshness.flatMap { $0.isFinite ? $0 : nil }
        let incumbentFreshness = incumbent.identity.freshness.flatMap { $0.isFinite ? $0 : nil }
        switch (candidateFreshness, incumbentFreshness) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs > rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            // With no clock, the caller's newest-first source order is the freshness signal.
            return candidate.sourceIndex < incumbent.sourceIndex
        default:
            break
        }
        // A same-clock removal is the conservative LWW result: an explicit dismissal must not resurrect merely
        // because serialization placed the stale live row first. Otherwise the original order is the tie-break.
        if candidate.identity.removed != incumbent.identity.removed {
            return candidate.identity.removed
        }
        return candidate.sourceIndex < incumbent.sourceIndex
    }

    static func identityKeys(_ identity: Identity) -> Set<String> {
        let type = normalizeType(identity.type)
        guard !type.isEmpty else { return [] }
        return Set(([identity.id] + identity.aliases).compactMap {
            canonicalProviderID($0, type: type).map { "\(type)\u{1f}\($0)" }
        })
    }

    private static func normalizeType(_ value: String) -> String {
        let type = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch type {
        case "show", "tv", "series": return "series"
        case "film", "movie": return "movie"
        default: return type
        }
    }

    /// Canonicalize provider spelling and, for series, reduce a concrete `:season:episode` id to its title.
    /// Unknown provider ids retain their normalized opaque base. Nothing here consults name or artwork.
    private static func canonicalProviderID(_ value: String, type: String) -> String? {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }
        if type == "series", !raw.contains("://"),
           let match = raw.range(of: #":[0-9]{1,4}:[0-9]{1,4}$"#, options: .regularExpression) {
            raw.removeSubrange(match)
        }

        if let match = raw.range(of: #"^(?:imdb:)?tt[0-9]{1,10}$"#, options: .regularExpression),
           match == raw.startIndex..<raw.endIndex {
            let imdb = raw.hasPrefix("imdb:") ? String(raw.dropFirst(5)) : raw
            return "imdb:\(imdb)"
        }

        if let match = raw.range(
            of: #"^tmdb:(?:(movie|tv|series|show):)?[0-9]{1,10}$"#,
            options: .regularExpression
        ), match == raw.startIndex..<raw.endIndex {
            let parts = raw.split(separator: ":").map(String.init)
            let numeric = parts.last ?? ""
            let explicit = parts.count == 3 ? parts[1] : nil
            let namespace: String
            switch explicit {
            case "tv", "series", "show": namespace = "series"
            case "movie": namespace = "movie"
            default: namespace = type
            }
            return "tmdb:\(namespace):\(numeric)"
        }

        return raw
    }
}

/// Timestamped overlay removal carried beside a profile's live library rows. Keys are the canonical,
/// transitive identity component known at dismissal time; milliseconds keep the JSON readable on every client.
struct OverlayWatchRemoval: Codable, Equatable {
    var keys: [String]
    var removedAt: Double
}

/// Resolves durable overlay removals against live rows without collapsing the library dictionary itself.
/// A tombstone suppresses its whole alias component. Only a strictly newer row with valid progress is an
/// explicit rewatch and clears that component's tombstone; missing/malformed clocks never beat a removal.
enum OverlayWatchRemovalPolicy {
    private struct Group {
        var liveIDs: Set<String>
        var liveFreshness: [Double]
        var keys: Set<String>
        var removals: [OverlayWatchRemoval]
    }

    static func resolve<Entry>(
        entries: [String: Entry],
        removals: [OverlayWatchRemoval],
        identity: (String, Entry) -> ContinueWatchingDedupe.Identity
    ) -> (entries: [String: Entry], removals: [OverlayWatchRemoval]) {
        let boundedRemovals = removals
            .filter { $0.removedAt.isFinite && !$0.keys.isEmpty }
            .sorted { $0.removedAt > $1.removedAt }
            .prefix(120)
        guard !boundedRemovals.isEmpty else { return (entries, []) }

        // Most libraries have no row related to a removal. Expand only the removal-connected closure before
        // the component fold: a bridge row can still pull in another alias transitively, while unrelated
        // library rows never enter the O(n²) grouping pass.
        var relevantKeys = Set(boundedRemovals.flatMap(\.keys))
        var relevantLiveIDs = Set<String>()
        var expanded = true
        while expanded {
            expanded = false
            for (id, entry) in entries where !relevantLiveIDs.contains(id) {
                let keys = ContinueWatchingDedupe.identityKeys(identity(id, entry))
                guard !relevantKeys.isDisjoint(with: keys) else { continue }
                relevantLiveIDs.insert(id)
                let oldCount = relevantKeys.count
                relevantKeys.formUnion(keys)
                if relevantKeys.count != oldCount { expanded = true }
            }
        }

        var groups: [Group] = []

        func append(liveID: String?, freshness: Double?, keys: Set<String>, removal: OverlayWatchRemoval?) {
            guard !keys.isEmpty else { return }
            let matches = groups.indices.filter { !groups[$0].keys.isDisjoint(with: keys) }
            guard let target = matches.first else {
                groups.append(Group(
                    liveIDs: liveID.map { Set([$0]) } ?? [],
                    liveFreshness: freshness.map { [$0] } ?? [],
                    keys: keys,
                    removals: removal.map { [$0] } ?? []
                ))
                return
            }
            if let liveID { groups[target].liveIDs.insert(liveID) }
            if let freshness { groups[target].liveFreshness.append(freshness) }
            groups[target].keys.formUnion(keys)
            if let removal { groups[target].removals.append(removal) }
            for index in matches.dropFirst().reversed() {
                groups[target].liveIDs.formUnion(groups[index].liveIDs)
                groups[target].liveFreshness.append(contentsOf: groups[index].liveFreshness)
                groups[target].keys.formUnion(groups[index].keys)
                groups[target].removals.append(contentsOf: groups[index].removals)
                groups.remove(at: index)
            }
        }

        for removal in boundedRemovals {
            append(liveID: nil, freshness: nil, keys: Set(removal.keys), removal: removal)
        }
        for (id, entry) in entries where relevantLiveIDs.contains(id) {
            let value = identity(id, entry)
            let freshness = value.hasValidProgress ? value.freshness.flatMap { $0.isFinite ? $0 : nil } : nil
            append(liveID: id, freshness: freshness,
                   keys: ContinueWatchingDedupe.identityKeys(value), removal: nil)
        }

        var live = entries
        var retained: [OverlayWatchRemoval] = []
        for group in groups where !group.removals.isEmpty {
            let removedAt = group.removals.map(\.removedAt).max() ?? 0
            if let replayedAt = group.liveFreshness.max(), replayedAt > removedAt {
                continue
            }
            group.liveIDs.forEach { live.removeValue(forKey: $0) }
            retained.append(OverlayWatchRemoval(keys: group.keys.sorted(), removedAt: removedAt))
        }
        return (
            live,
            retained.sorted { $0.removedAt > $1.removedAt }.prefix(120).map { $0 }
        )
    }

    static func componentKeys<Entry>(
        seedID: String,
        seed: Entry,
        entries: [String: Entry],
        identity: (String, Entry) -> ContinueWatchingDedupe.Identity
    ) -> Set<String> {
        var keys = ContinueWatchingDedupe.identityKeys(identity(seedID, seed))
        var expanded = true
        while expanded {
            expanded = false
            for (id, entry) in entries {
                let candidate = ContinueWatchingDedupe.identityKeys(identity(id, entry))
                guard !keys.isDisjoint(with: candidate) else { continue }
                let oldCount = keys.count
                keys.formUnion(candidate)
                if keys.count != oldCount { expanded = true }
            }
        }
        return keys
    }
}

/// Pure membership comparison used by the CoreBridge meta-details no-op suppressor. Array order is not state;
/// episode membership is, including the same-count replacement that previously left detail markers stale.
enum WatchedMembershipPolicy {
    static func changed(_ current: [String]?, _ next: [String]?) -> Bool {
        Set(current ?? []) != Set(next ?? [])
    }
}

/// Select the freshest overlay snapshot for account sync. Only the active profile has a live dictionary;
/// inactive profiles continue to use their persisted caches.
enum OverlayWatchSyncPolicy {
    static func snapshot<ID: Equatable, Entry>(
        requestedID: ID,
        activeID: ID?,
        live: [String: Entry],
        persisted: [String: Entry]
    ) -> [String: Entry] {
        requestedID == activeID ? live : persisted
    }
}
