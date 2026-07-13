import SwiftUI

/// "Trakt Watchlist": a Home/Discover rail of the titles on the connected user's Trakt watchlist,
/// rendered as ordinary catalog cards that open the normal detail page by IMDb id. Client-side only and
/// ZERO engine writes: it reads the Trakt HTTP API and resolves each entry's poster through Cinemeta,
/// exactly like `TopPicksModel` builds its rail from `MetaPreview`s, so the existing Home row components
/// render it unchanged.
///
/// DORMANT with empty creds: `refresh` is a no-op unless Trakt is configured AND connected, so the rail
/// is empty (and hidden by the Home views) until a real Trakt connection exists. Fully fail-soft.
@MainActor
final class TraktRailsModel: ObservableObject {
    /// The watchlist cards to render, resolved + capped. Empty hides the rail.
    @Published private(set) var items: [MetaPreview] = []

    /// At most this many cards in the rail (bounds the Cinemeta poster resolves).
    private static let maxItems = 30
    /// Minimum gap between refreshes so routine Home re-renders don't refetch.
    private static let refreshInterval: TimeInterval = 5 * 60

    private var lastRefresh: Date?
    private var loadTask: Task<Void, Never>?

    /// Pull the watchlist and resolve posters, at most once per `refreshInterval`. No-op when Trakt is
    /// unconfigured / not connected, leaving the rail hidden.
    func refresh() {
        guard TraktAuth.isConfigured else { items = []; return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.refreshInterval, !items.isEmpty { return }
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            guard await TraktAuth.shared.isSignedIn else {
                self?.items = []; return
            }
            let resolved = await Self.fetch()
            guard let self, !Task.isCancelled else { return }
            self.lastRefresh = Date()
            // Keep the prior rail on an empty fetch (flaky network) rather than blanking a populated rail.
            if !resolved.isEmpty { self.items = resolved }
        }
    }

    /// Clear on sign-out / disconnect.
    func clear() {
        loadTask?.cancel(); loadTask = nil
        items = []; lastRefresh = nil
    }

    /// Fetch the watchlist, map each entry to its IMDb id + type + title, then resolve posters via
    /// Cinemeta in parallel. Entries without an IMDb id are dropped (Cinemeta keys on tt ids). Off-main.
    private static func fetch() async -> [MetaPreview] {
        guard let entries = try? await TraktService.shared.watchlist() else { return [] }
        // Map to (imdb, appType, title), keeping order, dropping non-tt entries, de-duplicating, capped.
        var seen = Set<String>()
        let seeds: [(imdb: String, type: String, title: String)] = entries.compactMap { entry in
            let isShow = entry.type == "show"
            let container = isShow ? entry.show?.ids : entry.movie?.ids
            let title = (isShow ? entry.show?.title : entry.movie?.title) ?? ""
            guard let imdb = container?.imdb, !imdb.isEmpty, seen.insert(imdb).inserted else { return nil }
            return (imdb, isShow ? "series" : "movie", title)
        }
        let capped = Array(seeds.prefix(maxItems))
        guard !capped.isEmpty else { return [] }

        let resolved: [(Int, MetaPreview)] = await withTaskGroup(of: (Int, MetaPreview?).self) { group in
            for (index, seed) in capped.enumerated() {
                group.addTask { (index, await cinemetaPreview(imdb: seed.imdb, type: seed.type, fallbackTitle: seed.title)) }
            }
            var out: [(Int, MetaPreview)] = []
            for await (index, preview) in group { if let preview { out.append((index, preview)) } }
            return out
        }
        // Restore the watchlist order (task group completes out of order).
        return resolved.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Resolve one title to a `MetaPreview` (poster + name) via Cinemeta's meta endpoint, the same host
    /// the rest of the app uses. Falls back to a poster-less preview (the card shows its gradient) so a
    /// Cinemeta miss still lists the title.
    private static func cinemetaPreview(imdb: String, type: String, fallbackTitle: String) async -> MetaPreview? {
        let safeType = (type == "series") ? "series" : "movie"
        guard let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(safeType)/\(imdb).json"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = obj["meta"] as? [String: Any] else {
            guard !fallbackTitle.isEmpty else { return nil }
            return MetaPreview(id: imdb, type: safeType, name: fallbackTitle, poster: nil, posterShape: nil, popularity: nil)
        }
        let name = (meta["name"] as? String) ?? fallbackTitle
        guard !name.isEmpty else { return nil }
        return MetaPreview(id: imdb, type: safeType, name: name,
                           poster: meta["poster"] as? String, posterShape: nil, popularity: nil)
    }
}
