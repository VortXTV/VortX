import SwiftUI

/// "SIMKL Watchlist": a Home/Discover rail of the titles on the connected user's SIMKL plan-to-watch
/// list, rendered as ordinary catalog cards that open the normal detail page by IMDb id.
///
/// The SIMKL analog of `TraktRailsModel`, and deliberately the same shape: client-side only, ZERO engine
/// writes, posters resolved through Cinemeta (`CinemetaPreviewResolver`) so the cards match every other
/// rail. SIMKL was WRITE-ONLY before this: the app pushed watched + plan-to-watch and read nothing back,
/// so a connected user's SIMKL data was invisible inside VortX. This is the read side of that.
///
/// DORMANT with empty creds: `refresh` is a no-op unless SIMKL is configured AND connected, so the rail is
/// empty (and hidden by the Home views) until a real SIMKL connection exists. Fully fail-soft.
@MainActor
final class SIMKLRailsModel: ObservableObject {
    /// Posted on SIMKL disconnect/sign-out so every mounted Home rail (iOS + tvOS each keep their own
    /// per-view `SIMKLRailsModel`) clears immediately instead of lingering up to the refresh interval.
    /// Mirrors `TraktRailsModel.disconnectedNote`.
    static let disconnectedNote = Notification.Name("vortx.simkl.disconnected")

    /// The plan-to-watch cards to render, resolved + capped. Empty hides the rail.
    @Published private(set) var items: [MetaPreview] = []

    /// At most this many cards in the rail (bounds the Cinemeta poster resolves). Matches the Trakt rail.
    private static let maxItems = 30
    /// Minimum gap between refreshes so routine Home re-renders don't refetch.
    private static let refreshInterval: TimeInterval = 5 * 60

    private var lastRefresh: Date?
    private var loadTask: Task<Void, Never>?

    /// Pull the plan-to-watch list and resolve posters, at most once per `refreshInterval`. No-op when
    /// SIMKL is unconfigured / not connected, leaving the rail hidden.
    func refresh() {
        guard SIMKLAuth.isConfigured else { items = []; return }
        if let last = lastRefresh, Date().timeIntervalSince(last) < Self.refreshInterval, !items.isEmpty { return }
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            defer { self?.loadTask = nil }
            guard await SIMKLAuth.shared.isSignedIn else {
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

    /// How many list entries are considered before the tt-resolve. Larger than `maxItems` because
    /// tmdb-only entries can fail to resolve and drop out, and a rail that silently shrank to 20 cards
    /// because 10 anime entries missed would be its own bug. Bounds the resolve fan-out either way.
    private static let maxCandidates = maxItems * 2

    /// Fetch plan-to-watch, order it newest-listed-first, resolve every entry to a tt id, then resolve
    /// posters via Cinemeta in parallel. Off the main actor.
    private static func fetch() async -> [MetaPreview] {
        guard let entries = try? await SIMKLService.shared.planToWatch() else { return [] }

        // Newest addition first. SIMKL returns one array PER TYPE, so the raw concatenation would read as
        // "every movie, then every show, then every anime" rather than as a list; sorting on the listed-at
        // timestamp interleaves them the way the user actually built the list. Entries SIMKL sent no
        // timestamp for sort last (rather than jumping the queue on an empty-string compare), and if the
        // field were ever absent entirely this degrades to the concatenation order, never to an error.
        let ordered = entries.enumerated().sorted { a, b in
            switch (a.element.addedAt, b.element.addedAt) {
            case let (lhs?, rhs?): return lhs == rhs ? a.offset < b.offset : lhs > rhs
            case (nil, _?):        return false
            case (_?, nil):        return true
            case (nil, nil):       return a.offset < b.offset
            }
        }.map(\.element)

        // Resolve every entry to a tt id, because Cinemeta (and the detail page the card opens) is tt-keyed.
        //
        // WHY THE tmdb FALLBACK IS NOT OPTIONAL HERE, unlike on the Trakt rail: Trakt entries essentially
        // always carry an imdb id, so dropping the id-less ones costs nothing. SIMKL is an ANIME-FIRST
        // tracker and hands back plenty of rows with a tmdb id and no imdb id, so the same "drop it" rule
        // would silently delete a large slice of a typical SIMKL user's list from their own rail. That is
        // precisely the write-only-ish "I connected it and see nothing" failure this rail exists to end.
        //
        // Reuses `CommunityTrickplay.resolveIMDbID` rather than growing a second tmdb->tt path: it is the
        // proven one (keyless signed edge, user-key fallback), and it is PERSISTENTLY CACHED, so this costs
        // a lookup once per title ever and nothing on subsequent refreshes. Fail-soft: an unresolvable entry
        // drops exactly as before, so the worst case is today's behavior.
        let candidates = Array(ordered.prefix(maxCandidates))
        let ttResolved: [(Int, imdb: String, type: String, title: String)] =
            await withTaskGroup(of: (Int, String, String, String)?.self) { group in
                for (index, entry) in candidates.enumerated() {
                    group.addTask {
                        if let imdb = entry.imdb, !imdb.isEmpty { return (index, imdb, entry.type, entry.title) }
                        guard let tmdb = entry.tmdb,
                              let tt = await CommunityTrickplay.resolveIMDbID(rawId: "tmdb:\(tmdb)",
                                                                             seriesHint: entry.type == "series")
                        else { return nil }
                        return (index, tt, entry.type, entry.title)
                    }
                }
                var out: [(Int, imdb: String, type: String, title: String)] = []
                for await row in group { if let row { out.append((row.0, row.1, row.2, row.3)) } }
                return out
            }

        // Restore list order (the group finishes out of order), then de-duplicate on the RESOLVED tt (two
        // entries can resolve to the same title) and cap.
        var seen = Set<String>()
        let seeds: [(imdb: String, type: String, title: String)] = ttResolved
            .sorted { $0.0 < $1.0 }
            .compactMap { row in
                guard seen.insert(row.imdb).inserted else { return nil }
                return (row.imdb, row.type, row.title)
            }
        let capped = Array(seeds.prefix(maxItems))
        guard !capped.isEmpty else { return [] }

        let resolved: [(Int, MetaPreview)] = await withTaskGroup(of: (Int, MetaPreview?).self) { group in
            for (index, seed) in capped.enumerated() {
                group.addTask {
                    (index, await CinemetaPreviewResolver.preview(imdb: seed.imdb, type: seed.type,
                                                                  fallbackTitle: seed.title))
                }
            }
            var out: [(Int, MetaPreview)] = []
            for await (index, preview) in group { if let preview { out.append((index, preview)) } }
            return out
        }
        // Restore the list order (task group completes out of order).
        return resolved.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
