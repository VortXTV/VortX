import SwiftUI

/// "Browse by streaming service" Home rails (Nuvio-style): one rail per major streaming service (Netflix,
/// Disney+, Prime Video, Max, …) filled with what is actually available on that service in the viewer's
/// region, from TMDB's watch-provider (JustWatch) data. This is DISCOVERY/categorization: a card on the
/// "Netflix" rail is a title that streams on Netflix, but tapping it plays through the engine (add-ons /
/// debrid) like every other card - VortX never plays Netflix's own streams.
///
/// Built entirely client-side from the configured TMDB key, mirroring `CuratedCollectionsModel`: each rail
/// resolves independently, an empty rail is dropped, and a fully empty build leaves the previous rails in
/// place. With no TMDB key the whole section stays empty (the Home views hide it), exactly like Top Picks.
/// Every TMDB id is resolved to a Cinemeta `tt` id so cards play through the engine (the `tmdb:`-id trap:
/// a raw tmdb id only resolves with a TMDB meta add-on installed, so we drop titles with no IMDb id).
@MainActor
final class StreamingRailsModel: ObservableObject {
    /// The streaming-service rails to render, in `majorStreamingServices` order, each de-duplicated and
    /// capped. A service that resolved to nothing in-region is omitted. Empty hides the whole section.
    @Published private(set) var collections: [CuratedCollection] = []

    /// The region the current rails were built for, so a locale change rebuilds and a routine re-emit does not.
    private var loadedRegion: String?
    private var loadTask: Task<Void, Never>?

    /// Build the streaming-service rails for the region (default: device region). Idempotent: a second call
    /// for the same region while loaded (or in flight) is a no-op, so it is safe to call from `onAppear` and
    /// every Home re-emit. Hides cleanly (stays empty) when no TMDB key is set.
    func load(region: String = TMDBClient.deviceRegion) {
        guard ApiKeys.tmdbKey() != nil else { collections = []; loadedRegion = nil; return }
        guard loadTask == nil, loadedRegion != region else { return }
        loadTask = Task { [weak self] in
            let built = await Self.fetchAll(region: region)
            guard let self, !Task.isCancelled else { return }
            self.loadTask = nil
            // Keep whatever we had on a fully empty fetch (flaky network) rather than blanking a populated
            // section; leave `loadedRegion` nil so the next Home appearance retries.
            if built.isEmpty { return }
            self.collections = built
            self.loadedRegion = region
        }
    }

    /// Drop the rails and allow a fresh build (sign-out / TMDB-key change / region change).
    func clear() {
        loadTask?.cancel()
        loadTask = nil
        collections = []
        loadedRegion = nil
    }

    /// Fetch every streaming-service rail in parallel, preserving `majorStreamingServices` order, dropping
    /// any service with nothing available in-region. Runs off the main actor.
    private static func fetchAll(region: String) async -> [CuratedCollection] {
        let services = TMDBClient.majorStreamingServices
        // Resolve services in small concurrent batches (3 at a time), so the rails don't all fan out their
        // TMDB requests at once on first Home load (each service itself caps its in-flight external_ids).
        var resolved: [(Int, CuratedCollection?)] = []
        for start in stride(from: 0, to: services.count, by: 3) {
            let batch = Array(services[start..<min(start + 3, services.count)])
            let part: [(Int, CuratedCollection?)] = await withTaskGroup(of: (Int, CuratedCollection?).self) { group in
                for (offset, service) in batch.enumerated() {
                    let index = start + offset
                    group.addTask {
                        let items = await TMDBClient.streamingProviderTitles(providerID: service.providerID, region: region)
                        guard !items.isEmpty else { return (index, nil) }
                        return (index, CuratedCollection(id: "streaming.\(service.providerID)", title: service.name, items: items))
                    }
                }
                var buckets = [(Int, CuratedCollection?)]()
                for await result in group { buckets.append(result) }
                return buckets
            }
            resolved.append(contentsOf: part)
        }
        return resolved.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
    }
}
