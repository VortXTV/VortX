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

    private static func identityKeys(_ identity: Identity) -> Set<String> {
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
