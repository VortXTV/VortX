import SwiftUI

/// "Top Picks for you": a Home rail of titles similar to what the ACTIVE profile has recently watched,
/// built only from local data (Continue Watching + library) plus the configured TMDB key. It reuses the
/// existing "more like this" recommender (`AddonClient.tmdbSimilar`, which resolves TMDB recommendations
/// to Cinemeta metas so results play through the engine) seeded from the profile's recent titles.
///
/// Everything fails soft: no TMDB key, no seeds, or a flaky network all leave `items` empty, and the
/// Home views hide the rail entirely when it's empty. Results are cached in memory and recomputed when
/// the seed set changes (a new watch) or the profile switches.
@MainActor
final class TopPicksModel: ObservableObject {
    /// The recommendations to render, already de-duplicated and capped. Empty hides the rail.
    @Published private(set) var items: [MetaPreview] = []

    /// At most this many recent titles seed the recommender (newest first), keeping the fan-out small.
    private static let maxSeeds = 5
    /// At most this many cards in the rail.
    private static let maxItems = 20

    /// The signature of the last successful build (profile id + ordered seed ids), so a routine engine
    /// re-emit with the same recent titles doesn't refetch.
    private var lastSignature: String?
    private var loadTask: Task<Void, Never>?

    /// Recompute from the active profile's recent watch/library titles. `cw` is the profile-aware
    /// Continue Watching, `library` the profile-aware library; both are passed in by the caller so this
    /// model never reaches into engine/profile state directly (it stays a pure transform + cache).
    /// No-ops when the seed signature is unchanged.
    func refresh(profileID: UUID?, cw: [CoreCWItem], library: [CoreCWItem]) {
        // TMDB recommendations are the recommender; with no key there is nothing to surface.
        guard ApiKeys.tmdbKey() != nil else { items = []; lastSignature = nil; return }

        // Seed from Continue Watching first (most recent intent), then fill from the library, keeping
        // only IMDb ids (the recommender resolves IMDb ids) and de-duplicating.
        var seen = Set<String>()
        let seeds = (cw + library)
            .filter { $0.id.hasPrefix("tt") && $0.removed != true }
            .filter { seen.insert($0.id).inserted }
            .prefix(Self.maxSeeds)
            .map { (id: $0.id, type: $0.type) }

        guard !seeds.isEmpty else { items = []; lastSignature = nil; return }

        // Exclude anything the profile already has (CW + library) so we never recommend owned titles.
        let owned = Set((cw + library).map(\.id))
        let signature = (profileID?.uuidString ?? "main") + "|" + seeds.map(\.id).joined(separator: ",")
        if signature == lastSignature, !items.isEmpty { return }

        loadTask?.cancel()
        loadTask = Task {
            let recommendations = await Self.fetch(seeds: Array(seeds), owned: owned)
            if Task.isCancelled { return }
            // Keep the rail when results arrive; on an empty fetch (flaky network) leave whatever we
            // already had rather than blanking a populated rail, but clear the signature so the next
            // refresh retries.
            if recommendations.isEmpty {
                lastSignature = nil
            } else {
                items = recommendations
                lastSignature = signature
            }
        }
    }

    /// Clear when the profile signs out or switches to one with no eligible history.
    func clear() {
        loadTask?.cancel()
        items = []
        lastSignature = nil
    }

    /// Fetch "more like this" for every seed in parallel, then merge preserving seed order (a recommend
    /// from the most-recent title outranks one from an older title), de-duplicate, drop owned titles, and
    /// cap. Runs off the main actor.
    private static func fetch(seeds: [(id: String, type: String)], owned: Set<String>) async -> [MetaPreview] {
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
        for bucket in perSeed {
            for preview in bucket where !owned.contains(preview.id)
                && !seedIDs.contains(preview.id)
                && added.insert(preview.id).inserted {
                merged.append(preview)
                if merged.count >= maxItems { return merged }
            }
        }
        return merged
    }
}
