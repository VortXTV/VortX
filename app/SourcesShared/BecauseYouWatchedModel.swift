import SwiftUI

/// A profile-local "Because you watched" rail.
///
/// The inputs are deliberately passed in by Home rather than read from the engine here. That keeps the
/// rail on the same privacy boundary as Top Picks: an overlay profile only ever contributes its own local
/// history/library, and an engine-backed profile only contributes the engine snapshot selected by Home.
/// Every identifier is resolved through the existing TMDB/Cinemeta path before recommendations are fetched;
/// an unknown catalog id is ignored instead of being guessed onto an unrelated title.
@MainActor
final class BecauseYouWatchedModel: ObservableObject {
    @Published private(set) var rail: CuratedCollection?

    private static let maxSeeds = 4
    private static let maxItems = 20

    /// `lastSignature` describes the rail currently on screen. `inFlightSignature` prevents repeated Home
    /// body emissions from starting another bounded fetch while the same request is still resolving.
    private var lastSignature: String?
    private var inFlightSignature: String?
    private var loadTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private var activeProfileID: UUID?

    /// Recompute from the active profile's recent watch/library titles. Calls are cheap when the exact
    /// relevant inputs are unchanged, but a watch-progress or watched-count mutation changes the signature.
    func refresh(
        profileID: UUID?,
        cw: [CoreCWItem],
        library: [CoreCWItem],
        ownerKey: String = "",
    ) {
        let seeds = Self.eligibleSeeds(cw: cw, library: library)
        let signature = ownerKey + "|" + (profileID?.uuidString ?? "main") + "|" +
            Self.seedSignature(cw: cw, library: library)

        if signature == lastSignature, rail != nil {
            activeProfileID = profileID
            return
        }
        if signature == inFlightSignature { return }

        requestGeneration &+= 1
        let generation = requestGeneration
        loadTask?.cancel()
        inFlightSignature = signature

        // Never display the previous owner's personalized row during a profile/account boundary. A
        // same-profile retry may retain an existing rail until a non-empty replacement is ready.
        if activeProfileID != profileID {
            rail = nil
            lastSignature = nil
        }
        activeProfileID = profileID

        guard !seeds.isEmpty else {
            inFlightSignature = nil
            rail = nil
            lastSignature = nil
            return
        }

        // Exclude everything the active profile already owns. Temporary and removed engine entries are not
        // valid ownership evidence and are ignored on both the seed and exclusion paths.
        let owned = Set((cw + library)
            .filter { !$0.id.isEmpty && $0.removed != true && $0.temp != true }
            .map(\.id))
        loadTask = Task { [seeds, owned, signature, generation, profileID] in
            let built = await Self.build(seeds: seeds, owned: owned)
            guard !Task.isCancelled, self.requestGeneration == generation else { return }

            self.inFlightSignature = nil
            guard let built else {
                // A transient network/provider failure must not replace a valid rail with an error/empty
                // result. The next input mutation retries because the successful signature was not saved.
                self.lastSignature = nil
                return
            }

            // If the response has the same card ids but a provider omitted artwork this time, preserve an
            // already-valid poster from the previous rail. A newer, non-empty response still wins by id and
            // order; this only prevents a late sparse artwork response from blanking a useful card.
            self.rail = Self.preservingArtwork(in: built, from: self.rail)
            self.lastSignature = signature
            self.activeProfileID = profileID
        }
    }

    /// Clear when the profile signs out or switches to one with no eligible history.
    func clear() {
        requestGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        inFlightSignature = nil
        activeProfileID = nil
        rail = nil
        lastSignature = nil
    }

    // MARK: - Shared build (also used by HomeCollectionGroups' nested-group path)

    /// A recent-watch seed: the original catalog id/type/name. The id is resolved immediately before the
    /// recommendation request, so callers do not need to fabricate replacement identifiers.
    struct Seed {
        let id: String
        let type: String
        let name: String
    }

    /// Pick up to `maxSeeds` eligible seeds newest-first: Continue Watching first (freshest intent), then
    /// library. A seed needs actual watch evidence (resume progress, watched count, or watched flag), cannot
    /// be temporary/removed, and must use one of the identifier shapes the existing resolver understands.
    static func eligibleSeeds(cw: [CoreCWItem], library: [CoreCWItem]) -> [Seed] {
        var seen = Set<String>()
        return (cw + library)
            .filter { item in
                !item.id.isEmpty && item.removed != true && item.temp != true &&
                    hasWatchEvidence(item) && supportsResolution(item.id)
            }
            .filter { seen.insert($0.id).inserted }
            .prefix(maxSeeds)
            .map { Seed(id: $0.id, type: $0.type, name: $0.name) }
    }

    /// A stable, profile-independent signature for recommendation-relevant local state. Include ownership
    /// ids so a library mutation removes a newly-owned recommendation, and include watch state so a resume or
    /// watched mutation can promote/reseed without relying on a coarse first-id observer.
    static func seedSignature(cw: [CoreCWItem], library: [CoreCWItem]) -> String {
        let history = cw + library
        let seeds = eligibleSeeds(cw: cw, library: library)
            .map { "\($0.type):\($0.id):\($0.name)" }
            .joined(separator: ",")
        let owned = history
            .filter { !$0.id.isEmpty && $0.removed != true && $0.temp != true }
            .map(\.id)
            .sorted()
            .joined(separator: ",")
        let watchState = history
            .filter { !$0.id.isEmpty && $0.removed != true && $0.temp != true }
            .map(watchFingerprint)
            .sorted()
            .joined(separator: ",")
        return "seeds=\(seeds)|owned=\(owned)|watch=\(watchState)"
    }

    /// Bounded Home observer key for overlay history (the profile store caps this collection at 30). It
    /// includes progress and watched counters, not just ids, so an interior watch mutation refreshes the rail.
    static func observationSignature(items: [CoreCWItem]) -> String {
        items.map(watchFingerprint).joined(separator: "\u{1}")
    }

    /// Build the rail straight from raw CW + library (used by HomeCollectionGroups' nested-group path).
    /// Resolver/recommendation failures remain fail-soft and return nil.
    static func build(cw: [CoreCWItem], library: [CoreCWItem]) async -> CuratedCollection? {
        let seeds = eligibleSeeds(cw: cw, library: library)
        guard !seeds.isEmpty else { return nil }
        let owned = Set((cw + library)
            .filter { !$0.id.isEmpty && $0.removed != true && $0.temp != true }
            .map(\.id))
        return await build(seeds: seeds, owned: owned)
    }

    /// Resolve the bounded seed set, fetch each supported seed in parallel, then round-robin merge the
    /// recommendation buckets. Results are stable by seed order, deduplicated, owned/self-filtered, and capped.
    static func build(seeds: [Seed], owned: Set<String>) async -> CuratedCollection? {
        let resolved: [(seed: Seed, imdbID: String)] = await withTaskGroup(
            of: (Int, (Seed, String)?).self
        ) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask {
                    guard let imdbID = await TMDBClient.imdbID(forCatalogID: seed.id, type: seed.type) else {
                        return (index, nil)
                    }
                    return (index, (seed, imdbID))
                }
            }
            var ordered = [(Seed, String)?](repeating: nil, count: seeds.count)
            for await (index, item) in group { ordered[index] = item }
            return ordered.compactMap { $0 }.map { (seed: $0.0, imdbID: $0.1) }
        }
        guard !resolved.isEmpty else { return nil }

        let perSeed: [[MetaPreview]] = await withTaskGroup(of: (Int, [MetaPreview]).self) { group in
            for (index, entry) in resolved.enumerated() {
                group.addTask {
                    (index, await AddonClient.tmdbSimilar(type: entry.seed.type, imdbID: entry.imdbID))
                }
            }
            var buckets = [[MetaPreview]](repeating: [], count: resolved.count)
            for await (index, recs) in group { buckets[index] = recs }
            return buckets
        }

        let seedIDs = Set(seeds.map(\.id) + resolved.map(\.imdbID))
        var merged: [MetaPreview] = []
        var added = Set<String>()
        let maxDepth = perSeed.map(\.count).max() ?? 0
        outer: for depth in 0..<maxDepth {
            for bucket in perSeed where depth < bucket.count {
                let preview = bucket[depth]
                guard !owned.contains(preview.id), !seedIDs.contains(preview.id),
                      added.insert(preview.id).inserted else { continue }
                merged.append(preview)
                if merged.count >= maxItems { break outer }
            }
        }
        guard !merged.isEmpty, let primary = resolved.first?.seed else { return nil }

        let title = String(localized: "Because you watched \(primary.name)")
        return CuratedCollection(
            id: "becauseYouWatched.\(primary.id)",
            title: title,
            items: merged,
        )
    }

    private static func hasWatchEvidence(_ item: CoreCWItem) -> Bool {
        item.progress > 0 || item.isWatched || item.state.flaggedWatched > 0
    }

    private static func supportsResolution(_ id: String) -> Bool {
        switch DetailMetaRecoveryPolicy.catalogIDShape(id) {
        case .imdb, .tmdb, .tvdb, .kitsu:
            return true
        case .unsupported:
            return false
        }
    }

    private static func watchFingerprint(_ item: CoreCWItem) -> String {
        "\(item.type):\(item.id):\(item.progress):\(item.state.lastWatched ?? ""):\(item.state.flaggedWatched):\(item.state.timesWatched)"
    }

    private static func preservingArtwork(
        in newRail: CuratedCollection,
        from previous: CuratedCollection?
    ) -> CuratedCollection {
        guard let previous else { return newRail }
        let oldByID = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.id, $0) })
        let items = newRail.items.map { item -> MetaPreview in
            guard item.poster == nil, let old = oldByID[item.id], old.poster != nil else { return item }
            return MetaPreview(
                id: item.id,
                type: item.type,
                name: item.name,
                poster: old.poster,
                posterShape: item.posterShape ?? old.posterShape,
                popularity: item.popularity ?? old.popularity,
            )
        }
        return CuratedCollection(id: newRail.id, title: newRail.title, items: items)
    }
}
