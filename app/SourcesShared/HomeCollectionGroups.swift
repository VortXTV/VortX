import SwiftUI

/// Nested collections (grouped Home rails): a SECOND tier above the flat add-on/editorial rails, where
/// related rails are gathered under a big group header. The owner's structure, in this exact order, is:
///
///   0. "For You"    — a single personalized "Because you watched <title>" rail seeded from the active
///                     profile's recent watches (see `BecauseYouWatchedModel`); FIRST so it sits near the
///                     top of the section. Read-only over watch history; dropped when there's no history.
///   1. "Streaming"  — the streaming-service rails (Netflix, Disney+, …) from `StreamingRailsModel`.
///   2. "Genres"     — a handful of top genres (Action, Comedy, Drama, …) from TMDB /discover-by-genre.
///   3. "Top New"    — the most popular movies + shows released in the last few months (TMDB popularity).
///   4. "New"        — the freshest movies + shows by release / air date (TMDB date-desc).
///
/// This is purely ADDITIVE and empty-state safe. The whole grouped section renders BELOW the existing
/// flat Home rails (Continue Watching, Top Picks, Upcoming Episodes, the engine board rows, the editorial
/// rails). Each group resolves independently; a group whose rails all came back empty is dropped entirely,
/// and a group that needs a TMDB key (Genres / Top New / New) simply doesn't appear when no key is set
/// (the Genres group additionally falls back to the keyless Cinemeta genre catalogs, so it can still fill).
/// The engine-owned flat rails are never touched, so with no key + no network the Home is byte-for-byte
/// unchanged from before.
///
/// Every card is a `MetaPreview` carrying a resolved Cinemeta `tt` id, so a tap routes to `DetailView` and
/// plays through the engine exactly like every other rail card — no new card type, no new routing.

// MARK: - Model

/// One nested collection: a big group header plus its child rails (each an ordinary `CuratedCollection`,
/// the same shape the streaming + editorial rails already render). `Identifiable` so the Home `ForEach`
/// keys on the stable group id, and a group with no child rails is never emitted.
struct CollectionGroup: Identifiable {
    let id: String
    let title: String
    /// A short kicker over the group title (e.g. "Browse by service"); optional.
    let eyebrow: String?
    let rails: [CuratedCollection]
}

/// Builds the four nested-collection groups for Home. Mirrors `CuratedCollectionsModel` /
/// `StreamingRailsModel`: idempotent `load`, fail-soft, drop-empty, keep-old-on-empty-fetch. The
/// streaming group is sourced from a shared `StreamingRailsModel` so the streaming rails are fetched
/// once (the existing flat streaming section and this group's streaming child share the same data).
@MainActor
final class HomeGroupsModel: ObservableObject {
    /// The groups to render, in display order, each already drop-empty filtered. Empty hides the whole
    /// nested section. A group itself is omitted when all its child rails resolved empty.
    @Published private(set) var groups: [CollectionGroup] = []

    /// At most this many cards per child rail, matching the editorial rails' density.
    private static let maxItemsPerRail = 30

    /// The key (region + recent-watch seed signature) the groups were built for, so a locale change OR a
    /// new watch rebuilds while a routine re-emit does not. Folding the seed signature in keeps the
    /// personalized "Because You Watched" group fresh without refetching the region-only groups needlessly.
    private var loadedKey: String?
    private var loadTask: Task<Void, Never>?

    /// Build the groups for the region (default: device region). `cw`/`library` (default empty) seed the
    /// personalized "Because You Watched" group and are READ ONLY. Idempotent: a second call for the same
    /// region + same recent watches while loaded (or in flight) is a no-op, so it is safe to call from
    /// `onAppear` and every Home re-emit. The whole section hides cleanly (stays empty) when nothing resolves.
    func load(region: String = TMDBClient.deviceRegion, cw: [CoreCWItem] = [], library: [CoreCWItem] = []) {
        let key = region + "|" + BecauseYouWatchedModel.seedSignature(cw: cw, library: library)
        guard loadTask == nil, loadedKey != key else { return }
        loadTask = Task { [weak self] in
            let built = await Self.buildAll(region: region, cw: cw, library: library)
            guard let self, !Task.isCancelled else { return }
            self.loadTask = nil
            // Keep whatever we had on a fully empty build (flaky network / no key) rather than blanking a
            // populated section; leave `loadedKey` nil so the next Home appearance retries.
            if built.isEmpty { return }
            self.groups = built
            self.loadedKey = key
        }
    }

    /// Drop the groups and allow a fresh build (sign-out / TMDB-key change / region change / profile switch).
    func clear() {
        loadTask?.cancel()
        loadTask = nil
        groups = []
        loadedKey = nil
    }

    /// Build all groups in parallel, preserving display order, dropping any group with no rails.
    private static func buildAll(region: String, cw: [CoreCWItem], library: [CoreCWItem]) async -> [CollectionGroup] {
        async let because = buildBecauseYouWatchedGroup(cw: cw, library: library)
        async let streaming = buildStreamingGroup(region: region)
        async let genres = buildGenresGroup(region: region)
        async let topNew = buildTopNewGroup(region: region)
        async let new = buildNewGroup(region: region)
        // Fixed display order: Because You Watched (personalized, FIRST so it sits near the top of the
        // section, right under the flat Continue Watching rails), then Streaming, Genres, Top New, New.
        // Drop any empty group.
        return [await because, await streaming, await genres, await topNew, await new].compactMap { $0 }
    }

    // MARK: Group 0 — Because You Watched (personalized)

    /// Group 0 "Because You Watched": a single personalized rail of TMDB recommendations seeded from the
    /// active profile's most recent watches (see `BecauseYouWatchedModel`). READ ONLY over the CW +
    /// library passed in; no engine writes. Dropped when there's no TMDB key, no eligible history, or
    /// nothing resolves, so it simply does not appear for a fresh / keyless profile. The child rail carries
    /// the specific "Because you watched <title>" header; the group header stays a stable "For You".
    private static func buildBecauseYouWatchedGroup(cw: [CoreCWItem], library: [CoreCWItem]) async -> CollectionGroup? {
        guard let rail = await BecauseYouWatchedModel.build(cw: cw, library: library) else { return nil }
        return CollectionGroup(id: "group.becauseYouWatched", title: String(localized: "For You"),
                               eyebrow: String(localized: "Because you keep watching"), rails: [rail])
    }

    // MARK: Group 1 — Streaming

    /// Group 1 "Streaming": the streaming-service rails (Netflix, Disney+, …), reusing the exact same
    /// `StreamingRailsModel` fetch path as the flat streaming section so the data + drop-empty behaviour
    /// match. Needs a TMDB key; with none it resolves to no rails and the group is dropped.
    private static func buildStreamingGroup(region: String) async -> CollectionGroup? {
        let rails = await StreamingRailsModel.streamingCollections(region: region)
        guard !rails.isEmpty else { return nil }
        return CollectionGroup(id: "group.streaming", title: String(localized: "Streaming"),
                               eyebrow: String(localized: "Browse by service"), rails: rails)
    }

    // MARK: Group 2 — Genres

    /// Group 2 "Genres": one rail per top genre. Prefers TMDB /discover-by-genre (movie + TV merged);
    /// when there's no TMDB key (or a genre came back empty), it FALLS BACK to the keyless Cinemeta genre
    /// catalogs so the group still fills without a key. Each rail is dropped if both paths return nothing.
    private static func buildGenresGroup(region: String) async -> CollectionGroup? {
        let genres = TMDBClient.homeGenres
        let resolved: [(Int, CuratedCollection?)] = await withTaskGroup(of: (Int, CuratedCollection?).self) { group in
            for (index, genre) in genres.enumerated() {
                group.addTask {
                    var items = await TMDBClient.genreTitles(genre, region: region)
                    if items.isEmpty { items = await cinemetaGenreFallback(named: genre.name) }
                    guard !items.isEmpty else { return (index, nil) }
                    let capped = Array(items.prefix(maxItemsPerRail))
                    return (index, CuratedCollection(id: "group.genres.\(genre.movieGenreID)", title: genre.name, items: capped))
                }
            }
            var buckets = [(Int, CuratedCollection?)]()
            for await r in group { buckets.append(r) }
            return buckets
        }
        let rails = resolved.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
        guard !rails.isEmpty else { return nil }
        return CollectionGroup(id: "group.genres", title: String(localized: "Genres"),
                               eyebrow: String(localized: "Browse by genre"), rails: rails)
    }

    /// Keyless fallback for a genre rail: blend Cinemeta's public `top` movie + series catalogs filtered to
    /// the genre (the same source the editorial rails use), so the Genres group fills even with no TMDB key.
    /// Fails soft to []; keeps only poster-bearing cards and de-duplicates by id.
    private static func cinemetaGenreFallback(named genre: String) async -> [MetaPreview] {
        let client = AddonClient()
        async let movies = client.tryCatalog(type: "movie", id: "top", genre: genre)
        async let series = client.tryCatalog(type: "series", id: "top", genre: genre)
        var merged: [MetaPreview] = []
        var seen = Set<String>()
        let movieList = await movies
        let seriesList = await series
        for preview in (movieList + seriesList)
            where preview.poster?.isEmpty == false && seen.insert(preview.id).inserted {
            merged.append(preview)
            if merged.count >= maxItemsPerRail { break }
        }
        return merged
    }

    // MARK: Group 3 — Top New

    /// Group 3 "Top New": one rail of the most popular recent movies + shows. TMDB-only (no keyless
    /// fallback), so the group is dropped when there's no key / nothing resolves.
    private static func buildTopNewGroup(region: String) async -> CollectionGroup? {
        let items = await TMDBClient.topNewTitles(region: region)
        guard !items.isEmpty else { return nil }
        let rail = CuratedCollection(id: "group.topnew.all", title: String(localized: "Popular This Season"),
                                     items: Array(items.prefix(maxItemsPerRail)))
        return CollectionGroup(id: "group.topnew", title: String(localized: "Top New"),
                               eyebrow: String(localized: "Hot right now"), rails: [rail])
    }

    // MARK: Group 4 — New

    /// Group 4 "New": one rail of the freshest releases by date. TMDB-only, dropped when nothing resolves.
    private static func buildNewGroup(region: String) async -> CollectionGroup? {
        let items = await TMDBClient.justNewTitles(region: region)
        guard !items.isEmpty else { return nil }
        let rail = CuratedCollection(id: "group.new.all", title: String(localized: "Just Released"),
                                     items: Array(items.prefix(maxItemsPerRail)))
        return CollectionGroup(id: "group.new", title: String(localized: "New"),
                               eyebrow: String(localized: "Just landed"), rails: [rail])
    }
}

// MARK: - Small reuse seams

private extension AddonClient {
    /// `catalog(base:type:id:genre:)` against Cinemeta, failing soft to [] (so one bad query never throws
    /// out of the group build). Used by the Genres group's keyless fallback.
    func tryCatalog(type: String, id: String, genre: String) async -> [MetaPreview] {
        (try? await catalog(base: AddonClient.cinemeta, type: type, id: id, genre: genre)) ?? []
    }
}
