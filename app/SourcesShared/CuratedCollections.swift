import SwiftUI

/// Editorial Home rails (B3, Nuvio-style): a handful of hand-curated collections like "Critically
/// Acclaimed" or "Hidden Gems", each backed by one or more public Cinemeta catalog queries. These
/// render BELOW the add-on catalog rows on Home and give the landing page an opinionated, magazine-like
/// shape even when the user has installed no extra catalog add-ons (Cinemeta alone fills them).
///
/// Everything fails soft. Each collection fetches independently, a collection that returns nothing is
/// dropped from `collections`, and a fully empty result leaves the previous rails in place rather than
/// blanking the section. The Home views hide the whole block when `collections` is empty, so a flaky
/// network simply shows no editorial rails, never an error or a spinner stuck on screen.
///
/// The catalogs come from Cinemeta's public `top` / `imdbRating` catalogs (optionally genre-filtered),
/// resolved through the existing `AddonClient`, so every card carries a real Cinemeta id and taps
/// straight into Detail / playback through the engine, exactly like an add-on catalog card.
@MainActor
final class CuratedCollectionsModel: ObservableObject {
    /// The editorial rails to render, in display order, each already de-duplicated and capped. A
    /// collection that resolved to no items is omitted entirely. Empty hides the whole section.
    @Published private(set) var collections: [CuratedCollection] = []

    /// At most this many cards per rail; keeps each row a quick horizontal browse, not an endless scroll.
    private static let maxItemsPerCollection = 30

    /// Set once the first successful build lands, so routine Home re-emits (a new watch, a profile
    /// switch) don't refetch the editorial rails; they're global, not profile-specific.
    private var didLoad = false
    private var loadTask: Task<Void, Never>?

    /// The editorial collections, defined as Cinemeta catalog queries. Order here is the on-screen
    /// order. Each collection merges its queries (preserving order, de-duplicating by id) so a rail can
    /// blend, e.g., top movies and top series, and still degrades gracefully if one query fails.
    private static let definitions: [CuratedDefinition] = [
        CuratedDefinition(
            id: "curated.acclaimed",
            title: "Critically Acclaimed",
            queries: [
                .init(type: "movie", catalogID: "imdbRating"),
                .init(type: "series", catalogID: "imdbRating"),
            ]
        ),
        CuratedDefinition(
            id: "curated.hidden-gems",
            title: "Hidden Gems",
            queries: [
                .init(type: "movie", catalogID: "imdbRating", genre: "Mystery"),
                .init(type: "series", catalogID: "imdbRating", genre: "Crime"),
            ]
        ),
        CuratedDefinition(
            id: "curated.modern-classics",
            title: "Modern Classics",
            queries: [
                .init(type: "movie", catalogID: "top", genre: "Drama"),
                .init(type: "movie", catalogID: "top", genre: "Adventure"),
            ]
        ),
        CuratedDefinition(
            id: "curated.award-winners",
            title: "Award Winners",
            queries: [
                .init(type: "movie", catalogID: "imdbRating", genre: "Drama"),
                .init(type: "movie", catalogID: "imdbRating", genre: "Biography"),
            ]
        ),
    ]

    /// Build the editorial rails once. Idempotent: a second call while loaded (or in flight) is a no-op,
    /// so it's safe to call from `onAppear` and every Home re-emit. Pass `force: true` to rebuild after a
    /// failed first attempt.
    func load(force: Bool = false) {
        if force { didLoad = false }
        guard !didLoad, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            let built = await Self.fetchAll()
            guard let self else { return }
            self.loadTask = nil
            if Task.isCancelled { return }
            // Keep whatever we already had on a fully empty fetch (flaky network) rather than blanking a
            // populated section; leave `didLoad` false so the next Home appearance retries.
            if built.isEmpty { return }
            self.collections = built
            self.didLoad = true
        }
    }

    /// Drop the rails and allow a fresh build (e.g. on a hard sign-out / reset). The editorial set is
    /// global, so this is rarely needed, but it keeps the model symmetric with the other Home models.
    func clear() {
        loadTask?.cancel()
        loadTask = nil
        collections = []
        didLoad = false
    }

    /// Fetch every collection in parallel, preserving the declared display order, dropping any that
    /// resolved empty. Runs off the main actor.
    private static func fetchAll() async -> [CuratedCollection] {
        let resolved: [(Int, CuratedCollection?)] = await withTaskGroup(
            of: (Int, CuratedCollection?).self
        ) { group in
            for (index, definition) in definitions.enumerated() {
                group.addTask {
                    let items = await fetch(definition: definition)
                    guard !items.isEmpty else { return (index, nil) }
                    return (index, CuratedCollection(id: definition.id, title: definition.title, items: items))
                }
            }
            var buckets = [(Int, CuratedCollection?)]()
            for await result in group { buckets.append(result) }
            return buckets
        }
        return resolved.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
    }

    /// Resolve one collection: run its queries in parallel, merge in declared order, de-duplicate by id,
    /// keep only items with a poster (a poster-less card is a blank tile), and cap. A failed query
    /// contributes nothing, so the collection still surfaces as long as one query returns.
    private static func fetch(definition: CuratedDefinition) async -> [MetaPreview] {
        let client = AddonClient()
        let perQuery: [[MetaPreview]] = await withTaskGroup(of: (Int, [MetaPreview]).self) { group in
            for (index, query) in definition.queries.enumerated() {
                group.addTask {
                    (index, await query.fetch(using: client))
                }
            }
            var buckets = [[MetaPreview]](repeating: [], count: definition.queries.count)
            for await (index, items) in group { buckets[index] = items }
            return buckets
        }

        var merged: [MetaPreview] = []
        var seen = Set<String>()
        for bucket in perQuery {
            for preview in bucket
                where preview.poster?.isEmpty == false && seen.insert(preview.id).inserted {
                merged.append(preview)
            }
        }
        guard !merged.isEmpty else { return [] }
        // Freshness (CuratedFreshness): build the FULL merged pool (the old early cap stopped inside the
        // first query's bucket, so the second query never surfaced and the rail was the identical first-30
        // every open), then start the 30-card window at a seeded per-app-open rotation. Each open shows a
        // different slice of the same editorial pool; the model builds once per run (didLoad), so the rail
        // is stable for the whole session.
        let start = CuratedFreshness.rotation(key: definition.id, count: merged.count)
        let rotated = Array(merged[start...]) + Array(merged[..<start])
        return Array(rotated.prefix(maxItemsPerCollection))
    }
}

/// One resolved editorial rail: a title plus the meta previews to render. `Identifiable` so the Home
/// `ForEach` keys on the stable collection id.
struct CuratedCollection: Identifiable {
    let id: String
    let title: String
    let items: [MetaPreview]
}

/// A static editorial collection definition: a stable id, an on-screen title, and the Cinemeta catalog
/// queries that fill it. Merged in `queries` order.
private struct CuratedDefinition {
    let id: String
    let title: String
    let queries: [CuratedQuery]
}

/// One Cinemeta catalog query backing a collection. `genre` is the optional genre extra (e.g. "Drama").
/// Resolves through `AddonClient`, which targets Cinemeta and follows its catalog redirect transparently.
private struct CuratedQuery {
    let type: String
    let catalogID: String
    var genre: String? = nil

    /// Fetch this query's previews, failing soft to an empty list so one bad query never sinks a rail.
    func fetch(using client: AddonClient) async -> [MetaPreview] {
        if let genre {
            return (try? await client.catalog(base: AddonClient.cinemeta, type: type, id: catalogID, genre: genre)) ?? []
        }
        return (try? await client.catalog(base: AddonClient.cinemeta, type: type, id: catalogID)) ?? []
    }
}
