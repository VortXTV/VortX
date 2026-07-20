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

    // MARK: - Combined watchlist + library entry point

    /// One call that populates BOTH rails from the user's library AND their local watchlist
    /// (`LibraryAutoAdd.watchlist`), so the Upcoming surface shows the next air / release date of a followed
    /// title whether it is in the account library or only bookmarked to watch later. Library ids come first and
    /// win on name / poster (they carry the fresher engine meta); a watchlisted title not already in the library
    /// is appended, using its stored name / poster snapshot as the only fallback. Pure fan-in over the existing
    /// `refresh` / `refreshMovies`: no new network path, same 45-day horizon, same fail-soft behaviour, and each
    /// rail keeps its own signature so a routine re-emit still never refetches. A host calls this instead of the
    /// two library-only methods when it wants the watchlist folded in; the watchlist-only ids drop back out the
    /// moment the user un-bookmarks (the id set changes, the signature changes, the rail rebuilds).
    func refreshUpcoming(librarySeriesIDs: [String], librarySeriesNames: [String: String],
                         libraryMovieIDs: [String], libraryMovieNames: [String: String] = [:],
                         libraryMoviePosters: [String: String] = [:],
                         metaBases: [String], reference: Date = Date()) {
        let watch = LibraryAutoAdd.watchlist()

        var seriesIDs = librarySeriesIDs
        var seriesNames = librarySeriesNames
        let librarySeriesSet = Set(librarySeriesIDs)
        for entry in watch where entry.type == "series" && !librarySeriesSet.contains(entry.id) {
            seriesIDs.append(entry.id)
            if seriesNames[entry.id] == nil, let n = entry.name, !n.isEmpty { seriesNames[entry.id] = n }
        }

        var movieIDs = libraryMovieIDs
        var movieNames = libraryMovieNames
        var moviePosters = libraryMoviePosters
        let libraryMovieSet = Set(libraryMovieIDs)
        for entry in watch where entry.type == "movie" && !libraryMovieSet.contains(entry.id) {
            movieIDs.append(entry.id)
            if movieNames[entry.id] == nil, let n = entry.name, !n.isEmpty { movieNames[entry.id] = n }
            if moviePosters[entry.id] == nil, let p = entry.poster, !p.isEmpty { moviePosters[entry.id] = p }
        }

        refresh(seriesIDs: seriesIDs, seriesNames: seriesNames, metaBases: metaBases, reference: reference)
        refreshMovies(movieIDs: movieIDs, movieNames: movieNames, moviePosters: moviePosters,
                      metaBases: metaBases, reference: reference)
    }
}

// MARK: - UpcomingView (self-contained calendar-style list)

/// A self-contained "Upcoming" screen: the model's upcoming EPISODES and MOVIES merged into one chronological
/// list, grouped by calendar day, soonest first: the calendar/agenda shape the feature calls for, rather than
/// the two horizontal home rails. Pure presentation over the same published `upcoming` / `upcomingMovies`, so a
/// host just hands it the model (already refreshed via `refreshUpcoming(...)` or the two library-only methods)
/// and an `onSelect` that routes to the title's `DetailView`. The `onSelect` closure keeps this view free of any
/// per-platform navigation, so the ONE view compiles and renders on tvOS, iPhone, iPad, and Mac unchanged;
/// wiring passes decide where it is presented and how the row routes.
///
/// Fail-soft and honest: an empty model renders a friendly empty state (the host can present it unconditionally),
/// and every poster resolves through the shared `PosterArtwork` / `PosterImageLoader` path so it matches every
/// other surface's art and cache.
struct UpcomingView: View {
    @ObservedObject var model: ReleaseCalendarModel
    /// Routes a tapped row to its detail page: (catalog id, "series" | "movie"). Default no-op so the view can be
    /// previewed / dropped in before a host wires navigation.
    var onSelect: (String, String) -> Void = { _, _ in }

    var body: some View {
        Group {
            if sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.sm, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.rows) { row in
                                    UpcomingCalendarRowView(row: row, onSelect: onSelect)
                                }
                            } header: {
                                Text(section.label)
                                    .eyebrowStyle(Theme.Palette.textSecondary)
                                    .padding(.vertical, Theme.Space.xs)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.Palette.canvas)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.screenInset)
                    .padding(.vertical, Theme.Space.md)
                }
            }
        }
    }

    // MARK: derived calendar model (presentation only)

    /// Both rails flattened into one chronological list. Episode rows carry the SERIES id (so tapping opens the
    /// show); movie rows carry the movie id. Cheap to recompute (<=120 items) on a publish.
    private var rows: [UpcomingCalendarRow] {
        let eps = model.upcoming.map(UpcomingCalendarRow.init(episode:))
        let movies = model.upcomingMovies.map(UpcomingCalendarRow.init(movie:))
        return (eps + movies).sorted { $0.date < $1.date }
    }

    /// The list grouped by calendar day, each section headed by a friendly day label ("Today", "Tomorrow", a
    /// weekday within a week, else "Wed, Jul 30"), days ascending. A struct (not a tuple) so `ForEach` can key
    /// on the day directly (Swift has no key path to a tuple element).
    private var sections: [UpcomingDaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted().map { day in
            UpcomingDaySection(id: day, label: Self.dayHeader(day, calendar: calendar),
                               rows: (grouped[day] ?? []).sorted { $0.date < $1.date })
        }
    }

    /// A short, locale-aware section header for a day. Fresh `DateFormatter` per section (<=~105 days spanned,
    /// negligible) keeps this free of shared mutable formatter state.
    private static func dayHeader(_ day: Date, calendar: Calendar, now: Date = Date()) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        let formatter = DateFormatter()
        let daysAway = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: day).day ?? 99
        formatter.setLocalizedDateFormatFromTemplate(daysAway < 7 ? "EEEE" : "EEEMMMd")
        return formatter.string(from: day)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "calendar").font(.system(size: 40)).foregroundStyle(Theme.Palette.textTertiary)
            Text("Nothing upcoming")
                .font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
            Text("Add series and movies to your watchlist or library to see their next air and release dates here.")
                .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xl)
    }
}

/// One day's worth of calendar rows under a friendly header. `id` is the day's start (unique per section), so
/// `ForEach` keys on it without a key path to a tuple element (which Swift does not allow).
private struct UpcomingDaySection: Identifiable {
    let id: Date
    let label: String
    let rows: [UpcomingCalendarRow]
}

/// One flattened calendar row (an episode air date or a movie release date), carrying everything a row needs
/// pre-derived so the list body stays a pure render. `posterFallback` is the add-on art (episode still / movie
/// poster) the `PosterArtwork`-by-id resolution falls back to.
private struct UpcomingCalendarRow: Identifiable {
    let id: String
    let metaId: String
    let type: String        // "series" | "movie", passed straight to onSelect / DetailView routing
    let title: String
    let subtitle: String
    let date: Date
    let dateLabel: String
    let posterFallback: String?

    init(episode e: ReleaseCalendarModel.UpcomingEpisode) {
        id = "ep:" + e.id
        metaId = e.seriesId
        type = "series"
        title = e.seriesName.isEmpty ? "Untitled" : e.seriesName
        subtitle = e.episodeLabel
        date = e.airDate
        dateLabel = e.airDateLabel
        posterFallback = e.video.thumbnail
    }

    init(movie m: ReleaseCalendarModel.UpcomingMovie) {
        id = "mv:" + m.id
        metaId = m.id
        type = "movie"
        title = m.name.isEmpty ? "Untitled" : m.name
        subtitle = "Movie"
        date = m.releaseDate
        dateLabel = m.releaseDateLabel
        posterFallback = m.poster
    }
}

/// One calendar row: a small poster, the title + what/when caption, and the date. The whole row is a button
/// that hands (id, type) back to the host so it can push the right `DetailView`. `.plain` so the shared row
/// keeps no per-platform focus/press chrome; a wiring pass adds any tvOS focus polish where it places the view.
private struct UpcomingCalendarRowView: View {
    let row: UpcomingCalendarRow
    let onSelect: (String, String) -> Void

    var body: some View {
        Button { onSelect(row.metaId, row.type) } label: {
            HStack(spacing: Theme.Space.md) {
                UpcomingPosterThumb(id: row.metaId, fallback: row.posterFallback)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(row.subtitle)
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.dateLabel)
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.accent).lineLimit(1)
            }
            .padding(.vertical, Theme.Space.xs)
            .contentShape(Rectangle())
        }
        // tvOS: `.plain` left the system focus platter on over this calendar row.
        .vortxCardButton()
    }
}

/// A small 2:3 poster for a calendar row, resolved by id through the shared `PosterArtwork` / `PosterImageLoader`
/// path (same art source + cache as every rail), with a warm-cache peek and a `.task(id:)` load so a revisit
/// never flashes blank, and a film-glyph placeholder while it loads / when no art resolves. Cross-platform image
/// bridge mirrors `AddonLogoIcon`.
private struct UpcomingPosterThumb: View {
    let id: String
    let fallback: String?
    @State private var image: VXPosterImage?

    private static let width: CGFloat = 44
    private static let height: CGFloat = 66

    private var url: String? { PosterArtwork.poster(id: id, fallback: fallback) }
    private var warmCache: VXPosterImage? {
        guard let url, let parsed = URL(string: url) else { return nil }
        return PosterImageLoader.cached(parsed)
    }

    var body: some View {
        Group {
            if let img = image ?? warmCache {
                imageView(img).resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.Palette.surface2)
                    .overlay(Image(systemName: "film").foregroundStyle(Theme.Palette.textTertiary))
            }
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .task(id: url) {
            guard image == nil, let url, !url.isEmpty else { return }
            // 132px = 44pt @3x: only the on-card size ever sits in memory, never a full-res poster.
            if let img = await PosterImageLoader.load(url, maxPixel: 132) { image = img }
        }
    }

    private func imageView(_ img: VXPosterImage) -> Image {
        #if canImport(UIKit)
        Image(uiImage: img)
        #else
        Image(nsImage: img)
        #endif
    }
}
