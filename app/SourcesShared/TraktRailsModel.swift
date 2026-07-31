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
    /// Posted on Trakt disconnect/sign-out so every mounted Home rail (iOS + tvOS keep their own
    /// per-view `TraktRailsModel`) clears immediately instead of lingering up to the refresh interval.
    static let disconnectedNote = Notification.Name("vortx.trakt.disconnected")

    /// Stored cards. Public reads below fail closed unless their exact auth session is still current.
    @Published private var storedItems: [MetaPreview] = []
    private var stateSessionID: TraktSessionID?

    var items: [MetaPreview] {
        guard let stateSessionID,
              TraktAuth.storedSessionID == stateSessionID else { return [] }
        return storedItems
    }

    /// At most this many cards in the rail (bounds the Cinemeta poster resolves).
    private static let maxItems = 30
    /// Minimum gap between refreshes so routine Home re-renders don't refetch.
    private static let refreshInterval: TimeInterval = 5 * 60

    private var lastRefresh: Date?
    private var loadTask: Task<Void, Never>?
    private let boundaryObserverKey = "trakt-rails-\(UUID().uuidString)"

    init() {
        stateSessionID = TraktAuth.storedSessionID
        TraktAuthBoundary.observe(key: boundaryObserverKey) { [weak self] sessionID in
            Task { @MainActor [weak self] in
                self?.handleBoundary(sessionID)
            }
        }
        let currentSession = TraktAuth.storedSessionID
        if currentSession != stateSessionID { handleBoundary(currentSession) }
    }

    deinit {
        loadTask?.cancel()
        TraktAuthBoundary.removeObserver(key: boundaryObserverKey)
    }

    /// Pull the watchlist and resolve posters, at most once per `refreshInterval`. No-op when Trakt is
    /// unconfigured / not connected, leaving the rail hidden.
    func refresh() {
        guard TraktAuth.isConfigured,
              let sessionID = TraktAuth.storedSessionID else {
            clear()
            stateSessionID = nil
            return
        }
        if stateSessionID != sessionID { handleBoundary(sessionID) }
        // Sign-in and exact-session gates precede the throttle. An account switch can never inherit the
        // previous account's fresh timestamp and skip its first fetch.
        if let last = lastRefresh,
           Date().timeIntervalSince(last) < Self.refreshInterval,
           !storedItems.isEmpty { return }
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            let outcome = await Self.fetch(expectedSession: sessionID)
            guard let self, !Task.isCancelled,
                  self.stateSessionID == sessionID,
                  TraktAuth.storedSessionID == sessionID else { return }
            switch outcome {
            case .success:
                self.storedItems = ExternalRailSnapshotPolicy.resolved(
                    current: self.storedItems,
                    outcome: outcome
                )
                self.lastRefresh = Date()
            case .failure:
                break
            }
        }
    }

    /// Clear on sign-out / disconnect.
    func clear() {
        loadTask?.cancel(); loadTask = nil
        storedItems = []; lastRefresh = nil
    }

    private func handleBoundary(_ sessionID: TraktSessionID?) {
        clear()
        stateSessionID = sessionID
    }

    /// Fetch the watchlist, map each entry to its IMDb id + type + title, then resolve posters via
    /// Cinemeta in parallel. Entries without an IMDb id are dropped (Cinemeta keys on tt ids). Off-main.
    private static func fetch(
        expectedSession: TraktSessionID
    ) async -> ExternalRailFetchOutcome<MetaPreview> {
        guard let entries = try? await TraktService.shared.watchlist(
            expectedSession: expectedSession
        ) else { return .failure }
        guard !entries.isEmpty else { return .success([]) }
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
        guard !capped.isEmpty else { return .failure }

        let resolved: [(Int, MetaPreview)] = await withTaskGroup(of: (Int, MetaPreview?).self) { group in
            for (index, seed) in capped.enumerated() {
                group.addTask { (index, await cinemetaPreview(imdb: seed.imdb, type: seed.type, fallbackTitle: seed.title)) }
            }
            var out: [(Int, MetaPreview)] = []
            for await (index, preview) in group { if let preview { out.append((index, preview)) } }
            return out
        }
        // Restore the watchlist order (task group completes out of order).
        guard TraktAuth.storedSessionID == expectedSession else { return .failure }
        return .success(resolved.sorted { $0.0 < $1.0 }.map(\.1))
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
