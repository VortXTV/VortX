import SwiftUI

/// "Because you watched X": a Home rail of titles TMDB recommends from the ACTIVE profile's most recent
/// watches. It mirrors `TopPicksModel` exactly (same seed source, same "more like this" recommender via
/// `AddonClient.tmdbSimilar`, same fail-soft + signature-cache discipline), but it NAMES the rail after
/// the seed that drove it, so Home surfaces a personal "Because you watched <that title>" row instead of a
/// generic recommendations rail.
///
/// Everything fails soft: no TMDB key, no eligible history, or a flaky network all leave `rail` nil, and
/// the Home views hide a nil rail. Results are cached in memory and only recomputed when the seed set
/// changes (a new watch) or the profile switches; a routine engine re-emit with the same recent titles
/// does not refetch.
///
/// READ ONLY over watch history: `cw` (profile-aware Continue Watching) and `library` are passed in by the
/// caller, exactly like `TopPicksModel`, so this model never reaches into engine/profile state and never
/// writes a `libraryItem` or any account data. It is a pure transform + in-memory cache.
@MainActor
final class BecauseYouWatchedModel: ObservableObject {
    /// The single rail to render (title + cards), or nil to hide. The title embeds the primary (most
    /// recent) seed's name; the cards round-robin the recommendations of a few recent seeds so the rail
    /// reflects the BREADTH of recent viewing, not a wall of clones of the single latest title.
    @Published private(set) var rail: CuratedCollection?

    /// At most this many recent titles seed the recommender (newest first), keeping the fan-out small.
    private static let maxSeeds = 4
    /// At most this many cards in the rail.
    private static let maxItems = 20

    /// The signature of the last successful build (profile id + ordered seed ids), so a routine engine
    /// re-emit with the same recent titles doesn't refetch.
    private var lastSignature: String?
    private var loadTask: Task<Void, Never>?

    /// Recompute from the active profile's recent watch/library titles. No-ops when the seed signature is
    /// unchanged. Mirrors `TopPicksModel.refresh`.
    func refresh(profileID: UUID?, cw: [CoreCWItem], library: [CoreCWItem]) {
        // TMDB recommendations are the recommender; with no key there is nothing to surface (same gate as
        // Top Picks / the streaming rails, so this rail hides unless the user configured a key).
        guard ApiKeys.tmdbKey() != nil else { rail = nil; lastSignature = nil; return }

        let seeds = Self.eligibleSeeds(cw: cw, library: library)
        guard !seeds.isEmpty else { rail = nil; lastSignature = nil; return }

        let signature = (profileID?.uuidString ?? "main") + "|" + seeds.map(\.id).joined(separator: ",")
        if signature == lastSignature, rail != nil { return }

        // Exclude anything the profile already has (CW + library) so we never recommend owned titles.
        let owned = Set((cw + library).map(\.id))
        loadTask?.cancel()
        loadTask = Task {
            let built = await Self.build(seeds: seeds, owned: owned)
            if Task.isCancelled { return }
            // On a non-empty build keep the rail + signature. On an empty build (flaky network) leave
            // whatever we already had rather than blanking a populated rail, but clear the signature so
            // the next refresh retries.
            if let built {
                rail = built
                lastSignature = signature
            } else {
                lastSignature = nil
            }
        }
    }

    /// Clear when the profile signs out or switches to one with no eligible history.
    func clear() {
        loadTask?.cancel()
        rail = nil
        lastSignature = nil
    }

    // MARK: - Shared build (also used by HomeGroupsModel's nested-group path)

    /// A recent-watch seed: its IMDb id, stremio type, and display name (the name drives the rail title).
    struct Seed { let id: String; let type: String; let name: String }

    /// Pick up to `maxSeeds` eligible seeds newest-first: Continue Watching first (freshest intent), then
    /// the library, keeping only IMDb ids (the recommender resolves IMDb ids), non-removed, de-duplicated.
    static func eligibleSeeds(cw: [CoreCWItem], library: [CoreCWItem]) -> [Seed] {
        var seen = Set<String>()
        return (cw + library)
            .filter { $0.id.hasPrefix("tt") && $0.removed != true }
            .filter { seen.insert($0.id).inserted }
            .prefix(maxSeeds)
            .map { Seed(id: $0.id, type: $0.type, name: $0.name) }
    }

    /// A stable signature of the current seed set, so a cache keyed on it (this model's `lastSignature`,
    /// or `HomeGroupsModel`'s region+seed key) only rebuilds when the recent watches actually change.
    static func seedSignature(cw: [CoreCWItem], library: [CoreCWItem]) -> String {
        eligibleSeeds(cw: cw, library: library).map(\.id).joined(separator: ",")
    }

    /// Build the rail straight from the raw CW + library (used by `HomeGroupsModel`'s nested-group path).
    /// Returns nil with no TMDB key, no eligible history, or nothing resolved. Runs off the main actor.
    static func build(cw: [CoreCWItem], library: [CoreCWItem]) async -> CuratedCollection? {
        guard ApiKeys.tmdbKey() != nil else { return nil }
        let seeds = eligibleSeeds(cw: cw, library: library)
        guard !seeds.isEmpty else { return nil }
        return await build(seeds: seeds, owned: Set((cw + library).map(\.id)))
    }

    /// Fetch "more like this" for every seed in parallel, then round-robin merge (one pick from each recent
    /// watch in rotation), dropping owned + seed titles, de-duplicating, and capping. The title is the
    /// primary (most recent) seed's name: "Because you watched <name>". Returns nil when nothing resolves.
    /// Runs off the main actor. The merge mirrors `TopPicksModel.fetch`.
    static func build(seeds: [Seed], owned: Set<String>) async -> CuratedCollection? {
        guard let primary = seeds.first else { return nil }
        let perSeed: [[MetaPreview]] = await withTaskGroup(of: (Int, [MetaPreview]).self) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask {
                    (index, await AddonClient.tmdbSimilar(type: seed.type, imdbID: seed.id))
                }
            }
            var buckets = [[MetaPreview]](repeating: [], count: seeds.count)
            for await (index, recs) in group { buckets[index] = recs }
            return buckets
        }

        let seedIDs = Set(seeds.map(\.id))
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
        guard !merged.isEmpty else { return nil }

        let title = String(localized: "Because you watched \(primary.name)")
        return CuratedCollection(id: "becauseYouWatched.\(primary.id)", title: title, items: merged)
    }
}
