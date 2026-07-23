import Foundation

/// Pure, Foundation-only fold that merges the user's SIMKL plan-to-watch titles into the seed id lists the
/// `ReleaseCalendarModel` builds the Upcoming rails from.
///
/// This is the SIMKL half of the "calendar / upcoming" ask. Trakt surfaces no upcoming rail, and the existing
/// Upcoming surface already derives air / release dates for FOLLOWED titles (library + the local watchlist,
/// folded by `ReleaseCalendarModel.refreshUpcoming`) straight off the installed meta add-ons. So the smallest
/// honest version of "show air dates for the shows a SIMKL user follows" is to feed the SIMKL plan-to-watch
/// titles into that SAME machinery as additional seeds - no new SIMKL calendar endpoint, no new rail, the same
/// 45-day horizon and the same fail-soft behaviour. It follows `SIMKLRailsModel`'s gating (whenever SIMKL is
/// CONNECTED, no separate toggle), because the plan-to-watch rail itself is un-toggled.
///
/// Extracted as a pure helper (the impure fetch + tmdb->tt resolve live in `ReleaseCalendarModel`) so the union
/// rule - append only ids the library / local watchlist did not already carry, base wins on order and name - is
/// exercised by a standalone test.
enum SIMKLUpcomingSeeds {
    /// One SIMKL plan-to-watch title already resolved to a catalog tt id, tagged with the app media type.
    struct Seed: Equatable, Sendable {
        /// Resolved catalog id (a "tt…" imdb id; meta add-ons and the detail page are tt-keyed).
        let id: String
        /// "series" | "movie" (anime is "series"), straight from `SIMKLListEntry.type`.
        let type: String
        /// Best-known display name, used only as a fallback if the meta fetch has none.
        let name: String
    }

    /// The augmented seed lists after folding the SIMKL seeds into the base library + local-watchlist ones.
    struct Folded: Equatable {
        var seriesIDs: [String]
        var seriesNames: [String: String]
        var movieIDs: [String]
        var movieNames: [String: String]
    }

    /// Merge `simkl` into the base seeds. A SIMKL title whose id the base lists ALREADY carry is dropped (the
    /// base entry wins on order and on name, since a library title has the fresher engine meta). A SIMKL title
    /// the base lacks is APPENDED after the base ids, and its name filled only when the base had none. Order is
    /// deterministic (base first, then SIMKL in its given order) so a routine re-emit produces a stable
    /// signature and never refetches. Empty `simkl` returns the base lists unchanged.
    static func fold(baseSeriesIDs: [String], baseSeriesNames: [String: String],
                     baseMovieIDs: [String], baseMovieNames: [String: String],
                     simkl: [Seed]) -> Folded {
        var seriesIDs = baseSeriesIDs
        var seriesNames = baseSeriesNames
        var movieIDs = baseMovieIDs
        var movieNames = baseMovieNames
        var seriesSet = Set(baseSeriesIDs)
        var movieSet = Set(baseMovieIDs)

        for seed in simkl {
            guard !seed.id.isEmpty else { continue }
            if seed.type == "movie" {
                guard movieSet.insert(seed.id).inserted else { continue }
                movieIDs.append(seed.id)
                if movieNames[seed.id] == nil, !seed.name.isEmpty { movieNames[seed.id] = seed.name }
            } else {
                guard seriesSet.insert(seed.id).inserted else { continue }
                seriesIDs.append(seed.id)
                if seriesNames[seed.id] == nil, !seed.name.isEmpty { seriesNames[seed.id] = seed.name }
            }
        }
        return Folded(seriesIDs: seriesIDs, seriesNames: seriesNames, movieIDs: movieIDs, movieNames: movieNames)
    }
}
