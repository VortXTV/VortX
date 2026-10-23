import Foundation

/// One planned For You row: what it is called, why it is there, and where its titles come from.
/// Pure data so the plan is testable without the network; `ForYouRowsModel` fetches it.
struct ForYouRowPlan: Equatable, Identifiable, Sendable {
    enum Source: Equatable, Sendable {
        /// TMDB /discover parameters per media (after `api_key`); nil skips that media.
        case discover(movie: String?, tv: String?)
        /// A followed person's best-known work.
        case person(Int)
    }
    let id: String
    let eyebrow: String
    let title: String
    let source: Source
}

/// Turns interests and smart collection rules into TMDB discover queries and row plans.
///
/// Every query is bounded to titles already released (`lte` today): TMDB lists announced titles with
/// hype ratings, and a For You row should only offer something that can be watched. Interest rows are
/// popular titles above a rating bar; ranking by rating alone surfaced obscure picks, and low vote
/// floors let little-known adult-adjacent titles into popular anime results (checked live 2026-10-13). A pipe is written
/// percent-encoded (`%7C`) like the rest of `TMDBClient`, because a raw `|` fails URL parsing on iOS 16.
enum ForYouQuery {
    static let maxRows = 6
    private static let perKind = 2

    // MARK: Interest rows

    static func plan(_ interests: ForYouInterests, now: Date = Date()) -> [ForYouRowPlan] {
        let eras = interests.eraChoices
        let genres = interests.genreChoices.prefix(perKind).map { genre in
            ForYouRowPlan(id: "forYou.genre.\(genre.rawValue)", eyebrow: String(localized: "From your interests"),
                          title: genreTitle(genre, eras: eras), source: genreSource(genre, eras: eras, now: now))
        }
        let people = interests.people.prefix(perKind).map { person in
            ForYouRowPlan(id: "forYou.person.\(person.id)", eyebrow: String(localized: "People you follow"),
                          title: person.isDirector ? String(localized: "From \(person.name)") : String(localized: "With \(person.name)"),
                          source: .person(person.id))
        }
        let extras = interests.extraChoices.prefix(perKind).map { extra in
            ForYouRowPlan(id: "forYou.extra.\(extra.rawValue)", eyebrow: String(localized: "From your interests"),
                          title: extra.label, source: extraSource(extra, eras: eras, now: now))
        }
        // Round-robin so one kind of interest never pushes the others below the fold.
        var rows: [ForYouRowPlan] = []
        for index in 0..<perKind {
            for kind in [Array(genres), Array(people), Array(extras)] where index < kind.count { rows.append(kind[index]) }
        }
        return Array(rows.prefix(maxRows))
    }

    static func genreTitle(_ genre: ForYouGenre, eras: [ForYouEra]) -> String {
        guard eras.count == 1, let era = eras.first else { return String(localized: "\(genre.rowLabel) you'd rate highly") }
        switch era {
        case .recent: return String(localized: "Recent \(genre.rowPhrase) you'd rate highly")
        case .classics: return String(localized: "Classic \(genre.rowPhrase)")
        case .eightiesNineties: return String(localized: "\(genre.rowLabel) from the 80s and 90s")
        case .twoThousands: return String(localized: "\(genre.rowLabel) from the 2000s")
        }
    }

    static func genreSource(_ genre: ForYouGenre, eras: [ForYouEra], now: Date) -> ForYouRowPlan.Source {
        let years = ForYouEra.span(eras, currentYear: year(now))
        func query(series: Bool) -> String? {
            guard let id = series ? genre.tvGenreID : genre.movieGenreID else { return nil }
            return join(["with_genres=\(id)", "sort_by=popularity.desc", "vote_average.gte=\(series ? "7.5" : "7.0")",
                         "vote_count.gte=\(series ? 200 : 300)"] + dateBounds(series: series, from: years.from, to: years.to, now: now))
        }
        return .discover(movie: query(series: false), tv: query(series: true))
    }

    static func extraSource(_ extra: ForYouExtra, eras: [ForYouEra], now: Date) -> ForYouRowPlan.Source {
        let years = ForYouEra.span(eras, currentYear: year(now))
        func query(series: Bool) -> String? {
            guard let parameters = extra.parameters(series: series) else { return nil }
            return join([parameters, "sort_by=popularity.desc", "vote_average.gte=7.0", "vote_count.gte=\(series ? 80 : 100)"]
                        + dateBounds(series: series, from: years.from, to: years.to, now: now))
        }
        return .discover(movie: query(series: false), tv: query(series: true))
    }

    // MARK: Smart collections

    /// Rules to one discover query per media. TMDB's TV discover has no people filter, so a rule
    /// naming people searches movies only; only the first scene applies (scenes set conflicting
    /// language/keyword parameters); a scene that sets its own genre replaces the genre rule.
    static func collectionSource(_ rules: SmartCollectionRules, now: Date = Date()) -> ForYouRowPlan.Source {
        func query(series: Bool) -> String? {
            if (rules.type == .movie && series) || (rules.type == .series && !series) { return nil }
            if series && !rules.people.isEmpty { return nil }
            var parts: [String] = []
            var sceneSetsGenre = false
            if let extra = rules.extraChoices.first {
                guard let parameters = extra.parameters(series: series) else { return nil }   // no equivalent for this media
                parts.append(parameters)
                sceneSetsGenre = parameters.contains("with_genres=")
            }
            if !rules.genreChoices.isEmpty, !sceneSetsGenre {
                let ids = rules.genreChoices.compactMap { series ? $0.tvGenreID : $0.movieGenreID }
                guard !ids.isEmpty else { return nil }   // none of the chosen genres exist for this media
                parts.append("with_genres=" + unique(ids).map(String.init).joined(separator: "%7C"))
            }
            if !rules.people.isEmpty { parts.append("with_people=" + rules.people.map { String($0.id) }.joined(separator: "%7C")) }
            var minimumVotes: Int
            switch rules.sort {
            case .popular:
                parts.append("sort_by=popularity.desc"); minimumVotes = series ? 50 : 100
            case .rating:
                parts.append("sort_by=vote_average.desc"); minimumVotes = series ? 150 : 300
            case .newest:
                parts.append("sort_by=\(series ? "first_air_date" : "primary_release_date").desc"); minimumVotes = series ? 10 : 20
            }
            if let rating = rules.minRating, rating > 0 {
                parts.append("vote_average.gte=\(formatted(rating))"); minimumVotes = max(minimumVotes, 50)
            }
            parts.append("vote_count.gte=\(minimumVotes)")
            return join(parts + dateBounds(series: series, from: rules.yearFrom, to: rules.yearTo, now: now))
        }
        return .discover(movie: query(series: false), tv: query(series: true))
    }

    // MARK: Helpers

    /// Release window: inclusive years, never past today.
    static func dateBounds(series: Bool, from: Int?, to: Int?, now: Date) -> [String] {
        let field = series ? "first_air_date" : "primary_release_date"
        let today = day(now)
        var bounds: [String] = []
        if let from { bounds.append("\(field).gte=\(String(format: "%04d", from))-01-01") }
        let end = to.map { "\(String(format: "%04d", $0))-12-31" }
        bounds.append("\(field).lte=\(end.map { min($0, today) } ?? today)")
        return bounds
    }

    static func year(_ date: Date) -> Int { calendar.component(.year, from: date) }

    static func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private static func join(_ parts: [String]) -> String { parts.joined(separator: "&") }
    private static func formatted(_ rating: Double) -> String { String(format: "%.1f", min(max(rating, 0), 10)) }
    private static func unique(_ ids: [Int]) -> [Int] { var seen = Set<Int>(); return ids.filter { seen.insert($0).inserted } }
}

extension ForYouGenre {
    /// Row heading form ("Thrillers you'd rate highly").
    var rowLabel: String {
        switch self {
        case .scifi: return String(localized: "Sci-fi")
        case .thriller: return String(localized: "Thrillers")
        case .action: return String(localized: "Action")
        case .comedy: return String(localized: "Comedies")
        case .drama: return String(localized: "Dramas")
        case .horror: return String(localized: "Horror")
        case .mystery: return String(localized: "Mysteries")
        case .animation: return String(localized: "Animation")
        case .crime: return String(localized: "Crime")
        case .fantasy: return String(localized: "Fantasy")
        case .romance: return String(localized: "Romance")
        case .documentary: return String(localized: "Documentaries")
        case .adventure: return String(localized: "Adventures")
        case .family: return String(localized: "Family films")
        case .war: return String(localized: "War films")
        case .western: return String(localized: "Westerns")
        case .history: return String(localized: "Historical films")
        case .music: return String(localized: "Music films")
        }
    }

    /// Mid-sentence form ("Recent sci-fi you'd rate highly").
    var rowPhrase: String {
        switch self {
        case .scifi: return String(localized: "sci-fi")
        case .thriller: return String(localized: "thrillers")
        case .action: return String(localized: "action")
        case .comedy: return String(localized: "comedies")
        case .drama: return String(localized: "dramas")
        case .horror: return String(localized: "horror")
        case .mystery: return String(localized: "mysteries")
        case .animation: return String(localized: "animation")
        case .crime: return String(localized: "crime")
        case .fantasy: return String(localized: "fantasy")
        case .romance: return String(localized: "romance")
        case .documentary: return String(localized: "documentaries")
        case .adventure: return String(localized: "adventures")
        case .family: return String(localized: "family films")
        case .war: return String(localized: "war films")
        case .western: return String(localized: "westerns")
        case .history: return String(localized: "historical films")
        case .music: return String(localized: "music films")
        }
    }
}
