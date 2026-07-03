import SwiftUI

/// One series' full meta, fetched directly over the add-on protocol from the first meta add-on that
/// answers. Never touches the engine, so the open detail page's engine meta slot is untouched. nil if
/// none decode. OS-agnostic (pure URLSession + Codable) so it lives in SourcesShared and is reachable by
/// EVERY target — both the iOS new-episode notification sweep (`NewEpisodeNotifications.fetchSeriesMeta`,
/// a thin shim over this) and the shared `ReleaseCalendarModel`, including the tvOS targets that don't
/// compile the SourcesiOS notifications file. Single implementation, identical behavior on both surfaces.
enum SeriesMetaFetcher {
    static func fetch(id: String, bases: [String]) async -> CoreMetaItem? {
        struct Wrap: Decodable { let meta: CoreMetaItem? }
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        for base in bases {
            guard let url = URL(string: "\(base)/meta/series/\(escaped).json") else { continue }
            var req = URLRequest(url: url); req.timeoutInterval = 12
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let wrap = try? JSONDecoder().decode(Wrap.self, from: data), let meta = wrap.meta {
                return meta
            }
        }
        return nil
    }
}

/// One MOVIE's release date (+ name/poster), fetched the same add-on way as `SeriesMetaFetcher`, decoding only
/// the fields the Upcoming-Movies rail needs (CoreMetaItem does not surface a movie's top-level `released` /
/// `releaseInfo`). Returns the title only when it is genuinely upcoming inside the window: a full ISO `released`
/// timestamp or a `yyyy-MM-dd` `releaseInfo`. A bare year is ignored so far-future films never falsely enter the
/// 45-day horizon. nil on no meta / no parseable date / not-upcoming. Fresh formatters per call (DateFormatter +
/// ISO8601DateFormatter are not thread-safe and this runs off the main actor).
enum MovieMetaFetcher {
    static func upcoming(id: String, bases: [String], now: Date, horizon: Date) async -> (name: String, poster: String?, date: Date)? {
        struct MovieMeta: Decodable { let name: String?; let poster: String?; let released: String?; let releaseInfo: String? }
        struct Wrap: Decodable { let meta: MovieMeta? }
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        for base in bases {
            guard let url = URL(string: "\(base)/meta/movie/\(escaped).json") else { continue }
            var req = URLRequest(url: url); req.timeoutInterval = 12
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let wrap = try? JSONDecoder().decode(Wrap.self, from: data), let m = wrap.meta else { continue }
            guard let date = isoDate(m.released) ?? dayDate(m.releaseInfo), date > now, date < horizon else { return nil }
            return (m.name ?? "", m.poster, date)
        }
        return nil
    }
    private static func isoDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }
    private static func dayDate(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }   // need yyyy-MM-dd; a bare year (4 chars) is ignored
        let f = DateFormatter(); f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }
}

/// "Upcoming Episodes": a Home rail of the next-airing episode of each SERIES in the user's library that
/// drops within the next 45 days, soonest first. It reuses the SAME meta fetch the new-episode
/// notification sweep runs (`SeriesMetaFetcher.fetch`), so a show you follow surfaces its next episode
/// here whether or not you ever reopen its page — no engine call, the meta comes straight off the
/// installed meta add-ons (never `CoreBridge`, so the open detail page's meta slot is untouched).
///
/// Everything fails soft: an empty library, no meta add-ons, or a flaky network all leave `upcoming`
/// empty, and the Home views hide the rail entirely when it's empty (the default no-content path renders
/// nothing). Series-only by design: there is no movie-release source wired, so movies are out of scope.
@MainActor
final class ReleaseCalendarModel: ObservableObject {
    /// The upcoming episodes to render, sorted by air date ascending. Empty hides the rail.
    @Published private(set) var upcoming: [UpcomingEpisode] = []

    /// One soonest-not-yet-aired episode of one library series, ready for a `PosterCard`. Carries the
    /// series id (so the card's poster resolves through `PosterArtwork`, exactly like every other rail)
    /// and routes to the series' `DetailView`.
    struct UpcomingEpisode: Identifiable {
        /// Per-row id: the episode's own id from the add-on. Stable across sweeps when the add-on
        /// populates the episode `id` field (Stremio/Cinemeta always do), so SwiftUI keeps card identity.
        let id: String
        let seriesId: String
        let seriesName: String
        let video: CoreVideo
        let airDate: Date
        /// "S2E5" style label, or "E5" when the add-on omits the season.
        let episodeLabel: String
        /// Localised short air date ("Jun 30"), precomputed so the caption is a plain string.
        let airDateLabel: String
    }

    /// Same 45-day horizon the notification sweep uses, so the two surfaces agree on what "upcoming" means.
    private static let horizonDays: TimeInterval = 45
    /// Same prefix cap as `NewEpisodeNotifications.sweepLibrary`, keeping the fan-out bounded on a large library.
    private static let seriesPrefix = 60

    /// The signature of the last successful build (ordered series ids + horizon day), so a routine re-emit
    /// with the same library doesn't refetch every series' meta over the network.
    private var lastSignature: String?
    private var loadTask: Task<Void, Never>?

    /// Cancel any in-flight sweep when the owning Home view is torn down, so a slow fetch can't keep the
    /// model (and its captured state) alive for up to the per-series timeout after the view disappears.
    deinit { loadTask?.cancel(); movieLoadTask?.cancel() }

    /// Build the rail from the series library + installed meta add-on bases, derived by the caller the SAME
    /// way `NewEpisodeNotifications.sweepLibrary`'s caller does (series-typed library ids + names, and the
    /// `providesMeta` add-on base URLs). `reference` is injectable for deterministic unit tests, mirroring
    /// the `EPGSchedule` injected-reference-Date pattern; production passes the default `Date()`.
    ///
    /// No-ops when the series set is unchanged. Empty inputs clear the rail.
    func refresh(seriesIDs: [String], seriesNames: [String: String], metaBases: [String], reference: Date = Date()) {
        guard !seriesIDs.isEmpty, !metaBases.isEmpty else { upcoming = []; lastSignature = nil; return }

        // Bucket by the calendar day so two refreshes within the same day (a routine re-emit) share a
        // signature and don't refetch; the air-date filter still uses the precise `reference` instant.
        let dayBucket = Int(reference.timeIntervalSinceReferenceDate / 86_400)
        let ids = Array(seriesIDs.prefix(Self.seriesPrefix))
        let signature = "\(dayBucket)|" + ids.joined(separator: ",")
        if signature == lastSignature, !upcoming.isEmpty { return }

        loadTask?.cancel()
        loadTask = Task {
            let built = await Self.build(seriesIDs: ids, seriesNames: seriesNames,
                                         metaBases: metaBases, reference: reference)
            if Task.isCancelled { return }
            // Keep whatever we had on a fully empty fetch (flaky network) rather than blanking a populated
            // rail, but clear the signature so the next refresh retries. An honest empty (library has no
            // dated upcoming episodes) still publishes empty so the rail disappears.
            if built.isEmpty, !upcoming.isEmpty {
                lastSignature = nil
            } else {
                upcoming = built
                lastSignature = signature
            }
        }
    }

    /// Clear when the library empties or the meta add-ons go away.
    func clear() {
        loadTask?.cancel(); movieLoadTask?.cancel()
        upcoming = []; upcomingMovies = []
        lastSignature = nil; lastMovieSignature = nil
    }

    /// Walk each series' meta off the main thread (reusing the shared `SeriesMetaFetcher` that also backs
    /// the notification sweep), take the SOONEST not-yet-aired episode within the horizon, and return them
    /// sorted by air date. Pure transform + network, no main-actor state — runs entirely off the caller's actor.
    private static func build(seriesIDs: [String], seriesNames: [String: String],
                              metaBases: [String], reference: Date) async -> [UpcomingEpisode] {
        let horizon = reference.addingTimeInterval(Self.horizonDays * 86_400)
        var out: [UpcomingEpisode] = []
        for id in seriesIDs {
            guard let meta = await SeriesMetaFetcher.fetch(id: id, bases: metaBases) else { continue }
            // The SOONEST not-yet-aired dated episode within the 45-day horizon — the exact filter the
            // notification sweep uses (`releasedDate > now && < now + 45d`, earliest wins).
            let next = (meta.videos ?? [])
                .compactMap { v -> (CoreVideo, Date)? in v.releasedDate.map { (v, $0) } }
                .filter { $0.1 > reference && $0.1 < horizon }
                .min { $0.1 < $1.1 }
            guard let (video, air) = next else { continue }
            let name = meta.name.isEmpty ? (seriesNames[id] ?? meta.name) : meta.name
            out.append(UpcomingEpisode(id: video.id, seriesId: id, seriesName: name, video: video,
                                       airDate: air, episodeLabel: Self.episodeLabel(for: video),
                                       airDateLabel: Self.dateLabel(for: air)))
        }
        return out.sorted { $0.airDate < $1.airDate }
    }

    /// "S{season}E{episode}" when the season is known, else "E{episode}"; when the add-on omits the episode
    /// number entirely (some calendar/EPG add-ons), fall back to the episode title rather than a bare "E0".
    private static func episodeLabel(for video: CoreVideo) -> String {
        guard let episode = video.episode else { return video.title ?? "New episode" }
        if let season = video.season { return "S\(season)E\(episode)" }
        return "E\(episode)"
    }

    /// Short, locale-aware air date for the card caption ("Jun 30"). A fresh DateFormatter per call
    /// (<=60 per sweep, negligible) keeps `build` free of shared mutable state: it runs OFF the main actor,
    /// and DateFormatter is not thread-safe, so a shared static instance would be a latent data race.
    private static func dateLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }

    // MARK: - Upcoming movies (library movies with a future release date inside the same 45-day window)

    /// The upcoming library movies to render, soonest first. Empty hides the rail.
    @Published private(set) var upcomingMovies: [UpcomingMovie] = []

    /// One soon-to-release library MOVIE, ready for a `PosterCard` that routes to the movie `DetailView`.
    struct UpcomingMovie: Identifiable {
        let id: String
        let name: String
        let poster: String?
        let releaseDate: Date
        let releaseDateLabel: String
    }

    private var lastMovieSignature: String?
    private var movieLoadTask: Task<Void, Never>?

    /// Build the Upcoming-Movies rail from the library's MOVIE ids (+ names/posters as fallbacks) and the same
    /// meta add-on bases. Mirrors `refresh(...)`: its OWN signature + task, so a routine re-emit never refetches
    /// and tearing down one rail never cancels the other. Empty inputs clear the movie rail; fail-soft like the
    /// episode rail (a flaky empty fetch keeps a populated rail, an honest empty publishes empty so it disappears).
    func refreshMovies(movieIDs: [String], movieNames: [String: String] = [:], moviePosters: [String: String] = [:], metaBases: [String], reference: Date = Date()) {
        guard !movieIDs.isEmpty, !metaBases.isEmpty else { upcomingMovies = []; lastMovieSignature = nil; return }
        let dayBucket = Int(reference.timeIntervalSinceReferenceDate / 86_400)
        let ids = Array(movieIDs.prefix(Self.seriesPrefix))
        let signature = "\(dayBucket)|" + ids.joined(separator: ",")
        if signature == lastMovieSignature, !upcomingMovies.isEmpty { return }
        movieLoadTask?.cancel()
        movieLoadTask = Task {
            let built = await Self.buildMovies(movieIDs: ids, movieNames: movieNames, moviePosters: moviePosters, metaBases: metaBases, reference: reference)
            if Task.isCancelled { return }
            if built.isEmpty, !upcomingMovies.isEmpty { lastMovieSignature = nil }
            else { upcomingMovies = built; lastMovieSignature = signature }
        }
    }

    private static func buildMovies(movieIDs: [String], movieNames: [String: String], moviePosters: [String: String], metaBases: [String], reference: Date) async -> [UpcomingMovie] {
        let horizon = reference.addingTimeInterval(Self.horizonDays * 86_400)
        var out: [UpcomingMovie] = []
        for id in movieIDs {
            guard let found = await MovieMetaFetcher.upcoming(id: id, bases: metaBases, now: reference, horizon: horizon) else { continue }
            let name = found.name.isEmpty ? (movieNames[id] ?? "") : found.name
            out.append(UpcomingMovie(id: id, name: name, poster: found.poster ?? moviePosters[id],
                                     releaseDate: found.date, releaseDateLabel: Self.dateLabel(for: found.date)))
        }
        return out.sorted { $0.releaseDate < $1.releaseDate }
    }
}
