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

    /// Exact private request inputs. Identical refreshes share an in-flight request, while a
    /// profile/account/key boundary retires the old personalized result immediately.
    private struct SeedIdentity: Equatable {
        let id: String
        let type: String
    }
    private struct RequestSignature: Equatable {
        let profileID: UUID?
        let ownerKey: String
        let owner: CredentialScopeRegistry.Capture
        let key: String
        let seeds: [SeedIdentity]
        let owned: Set<String>
    }
    private var lastSignature: RequestSignature?
    private var inFlightSignature: RequestSignature?
    private var requestGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?

    deinit { loadTask?.cancel() }

    /// Recompute from the active profile's recent watch/library titles. `cw` is the profile-aware
    /// Continue Watching, `library` the profile-aware library; both are passed in by the caller so this
    /// model never reaches into engine/profile state directly (it stays a pure transform + cache).
    /// No-ops when the seed signature is unchanged.
    func refresh(profileID: UUID?, cw: [CoreCWItem], library: [CoreCWItem], ownerKey: String = "") {
        // TMDB recommendations are the recommender; with no key there is nothing to surface.
        let owner = CredentialScopeRegistry.shared.capture()
        guard let key = ApiKeys.tmdbKey(), CredentialScopeRegistry.shared.isCurrent(owner) else {
            clear(); return
        }

        // Seed from Continue Watching first (most recent intent), then fill from the library, keeping
        // only IMDb ids (the recommender resolves IMDb ids) and de-duplicating.
        var seen = Set<String>()
        let seeds = (cw + library)
            .filter { $0.id.hasPrefix("tt") && $0.removed != true }
            .filter { seen.insert($0.id).inserted }
            .prefix(Self.maxSeeds)
            .map { (id: $0.id, type: $0.type) }

        guard !seeds.isEmpty else { clear(); return }

        // Exclude anything the profile already has (CW + library) so we never recommend owned titles.
        let owned = Set((cw + library).map(\.id))
        let signature = RequestSignature(profileID: profileID, ownerKey: ownerKey, owner: owner, key: key,
                                         seeds: seeds.map { SeedIdentity(id: $0.id, type: $0.type) },
                                         owned: owned)
        if let previous = inFlightSignature ?? lastSignature,
           previous.profileID != profileID || previous.ownerKey != ownerKey || previous.owner != owner || previous.key != key {
            items = []
            lastSignature = nil
        }
        if signature == lastSignature, !items.isEmpty {
            // Returning to a cached request must retire a different pending fetch; otherwise
            // its late completion could replace the cached row with now-obsolete inputs.
            if inFlightSignature != nil {
                requestGeneration &+= 1
                loadTask?.cancel()
                loadTask = nil
                inFlightSignature = nil
            }
            return
        }
        if signature == inFlightSignature { return }

        requestGeneration &+= 1
        let generation = requestGeneration
        loadTask?.cancel()
        inFlightSignature = signature
        loadTask = Task { [weak self] in
            let recommendations = await Self.fetch(seeds: Array(seeds), owned: owned)
            guard let self, !Task.isCancelled, self.requestGeneration == generation,
                  CredentialScopeRegistry.shared.isCurrent(owner), ApiKeys.tmdbKey() == key else { return }
            self.inFlightSignature = nil
            self.loadTask = nil
            // Keep the rail when results arrive; on an empty fetch (flaky network) leave whatever we
            // already had rather than blanking a populated rail, but clear the signature so the next
            // refresh retries.
            if recommendations.isEmpty {
                self.lastSignature = nil
            } else {
                self.items = recommendations
                self.lastSignature = signature
            }
        }
    }

    /// Explicit Home actions must not borrow a previous viewer's still-visible row before
    /// the Home change observer has refreshed it. This checks ownership without starting a fetch.
    func currentItems(profileID: UUID?, ownerKey: String) -> [MetaPreview] {
        guard let signature = lastSignature, signature.profileID == profileID,
              signature.ownerKey == ownerKey, CredentialScopeRegistry.shared.isCurrent(signature.owner),
              ApiKeys.tmdbKey() == signature.key else { return [] }
        return items
    }

    /// Clear when the profile signs out or switches to one with no eligible history.
    func clear() {
        requestGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        inFlightSignature = nil
        items = []
        lastSignature = nil
    }

    /// Fetch "more like this" for every seed in parallel, then merge preserving seed order (a recommend
    /// from the most-recent title outranks one from an older title), de-duplicate, drop owned titles, and
    /// cap. Network child tasks run concurrently; the bounded merge remains on this model's main actor.
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
        // Round-robin across the seed titles (one pick from each recent watch in rotation) instead of
        // draining the most-recent seed's look-alikes first. This makes Top Picks reflect the BREADTH of
        // what you have been watching rather than a wall of clones of the single latest title.
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
        return merged
    }
}
