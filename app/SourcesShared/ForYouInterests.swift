import Foundation

/// A profile's stated taste: the interests picker's answers, used for the For You rows on Home.
///
/// Synced as one host profile field (`forYou.interests`) beside the watchlist, so every app shows the
/// same choices for the same profile and an older app keeps the field untouched (unknown host fields
/// stay opaque there). The wire shape is shared with Android: plain string keys, no UI types.
struct ForYouInterests: Codable, Equatable, Sendable {
    static let field = "forYou.interests"

    var genres: [String] = []
    var extras: [String] = []
    var eras: [String] = []
    var people: [ForYouPerson] = []
    /// True once the profile pressed Done or Skip, on any device: the picker is never offered again.
    var decided: Bool = false

    var genreChoices: [ForYouGenre] { genres.compactMap(ForYouGenre.init(rawValue:)) }
    var extraChoices: [ForYouExtra] { extras.compactMap(ForYouExtra.init(rawValue:)) }
    var eraChoices: [ForYouEra] { eras.compactMap(ForYouEra.init(rawValue:)) }
    var isEmpty: Bool { genreChoices.isEmpty && extraChoices.isEmpty && people.isEmpty }

    init(genres: [String] = [], extras: [String] = [], eras: [String] = [], people: [ForYouPerson] = [], decided: Bool = false) {
        self.genres = genres; self.extras = extras; self.eras = eras; self.people = people; self.decided = decided
    }

    /// Every key is optional on the wire so another app may omit an empty list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        extras = try c.decodeIfPresent([String].self, forKey: .extras) ?? []
        eras = try c.decodeIfPresent([String].self, forKey: .eras) ?? []
        people = try c.decodeIfPresent([ForYouPerson].self, forKey: .people) ?? []
        decided = try c.decodeIfPresent(Bool.self, forKey: .decided) ?? false
    }
}

/// A followed person (TMDB person id). `department` decides "With X" versus "From X" row titles.
struct ForYouPerson: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    var department: String? = nil
    var isDirector: Bool { department == "Directing" || department == "Writing" }
}

/// Picker genres, keyed by a stable string shared with Android. TV ids follow TMDB's merged TV genres
/// (Sci-Fi & Fantasy, Action & Adventure); a genre TMDB has no TV equivalent for searches movies only.
enum ForYouGenre: String, CaseIterable, Codable, Sendable, Identifiable {
    case scifi, thriller, action, comedy, drama, horror, mystery, animation, crime, fantasy, romance, documentary
    case adventure, family, war, western, history, music

    var id: String { rawValue }
    /// The twelve offered in the first-run picker; the rest appear in the smart collection builder.
    static let picker: [ForYouGenre] = [.scifi, .thriller, .action, .comedy, .drama, .horror, .mystery,
                                        .animation, .crime, .fantasy, .romance, .documentary]

    var label: String {
        switch self {
        case .scifi: return String(localized: "Sci-fi")
        case .thriller: return String(localized: "Thriller")
        case .action: return String(localized: "Action")
        case .comedy: return String(localized: "Comedy")
        case .drama: return String(localized: "Drama")
        case .horror: return String(localized: "Horror")
        case .mystery: return String(localized: "Mystery")
        case .animation: return String(localized: "Animation")
        case .crime: return String(localized: "Crime")
        case .fantasy: return String(localized: "Fantasy")
        case .romance: return String(localized: "Romance")
        case .documentary: return String(localized: "Documentary")
        case .adventure: return String(localized: "Adventure")
        case .family: return String(localized: "Family")
        case .war: return String(localized: "War")
        case .western: return String(localized: "Western")
        case .history: return String(localized: "History")
        case .music: return String(localized: "Music")
        }
    }

    var movieGenreID: Int {
        switch self {
        case .scifi: return 878
        case .thriller: return 53
        case .action: return 28
        case .comedy: return 35
        case .drama: return 18
        case .horror: return 27
        case .mystery: return 9648
        case .animation: return 16
        case .crime: return 80
        case .fantasy: return 14
        case .romance: return 10749
        case .documentary: return 99
        case .adventure: return 12
        case .family: return 10751
        case .war: return 10752
        case .western: return 37
        case .history: return 36
        case .music: return 10402
        }
    }

    var tvGenreID: Int? {
        switch self {
        case .scifi, .fantasy: return 10765
        case .action, .adventure: return 10759
        case .comedy: return 35
        case .drama: return 18
        case .mystery: return 9648
        case .animation: return 16
        case .crime: return 80
        case .documentary: return 99
        case .family: return 10751
        case .war: return 10768
        case .western: return 37
        case .thriller, .horror, .romance, .history, .music: return nil
        }
    }
}

/// "Also into" scenes. Each maps to TMDB discover parameters per media; nil means that media has no
/// meaningful equivalent (K-drama is series, Bollywood is film) and is not queried.
enum ForYouExtra: String, CaseIterable, Codable, Sendable, Identifiable {
    case anime, kdrama, bollywood, british, standup, truecrime

    var id: String { rawValue }
    var label: String {
        switch self {
        case .anime: return String(localized: "Anime")
        case .kdrama: return String(localized: "Korean drama")
        case .bollywood: return String(localized: "Bollywood")
        case .british: return String(localized: "British TV")
        case .standup: return String(localized: "Stand-up")
        case .truecrime: return String(localized: "True crime")
        }
    }

    /// TMDB keyword ids verified against /search/keyword: 9716 "stand-up comedy", 33722 "true crime".
    func parameters(series: Bool) -> String? {
        switch self {
        case .anime: return "with_genres=16&with_original_language=ja"
        case .kdrama: return series ? "with_original_language=ko" : nil
        case .bollywood: return series ? nil : "with_original_language=hi"
        case .british: return series ? "with_origin_country=GB" : nil
        case .standup: return "with_keywords=9716"
        case .truecrime: return "with_keywords=33722"
        }
    }
}

/// Era preference. Several eras widen to the span covering all of them; one era bounds the rows.
enum ForYouEra: String, CaseIterable, Codable, Sendable, Identifiable {
    case classics, eightiesNineties = "80s90s", twoThousands = "2000s", recent

    var id: String { rawValue }
    var label: String {
        switch self {
        case .classics: return String(localized: "Classics")
        case .eightiesNineties: return String(localized: "80s and 90s")
        case .twoThousands: return String(localized: "2000s")
        case .recent: return String(localized: "Recent")
        }
    }

    /// Inclusive release-year bounds; nil is open. "Recent" is the last five years.
    func years(currentYear: Int) -> (from: Int?, to: Int?) {
        switch self {
        case .classics: return (nil, 1979)
        case .eightiesNineties: return (1980, 1999)
        case .twoThousands: return (2000, 2009)
        case .recent: return (currentYear - 4, nil)
        }
    }

    static func span(_ eras: [ForYouEra], currentYear: Int) -> (from: Int?, to: Int?) {
        guard !eras.isEmpty else { return (nil, nil) }
        let bounds = eras.map { $0.years(currentYear: currentYear) }
        let from: Int? = bounds.contains { $0.from == nil } ? nil : bounds.compactMap(\.from).min()
        let to: Int? = bounds.contains { $0.to == nil } ? nil : bounds.compactMap(\.to).max()
        return (from, to)
    }
}

/// A user-built rule row. Synced per collection (`forYou.collection.<id>`) so two devices editing
/// different collections never overwrite each other; null is a retained deletion.
struct SmartCollection: Codable, Equatable, Identifiable, Sendable {
    static let fieldPrefix = "forYou.collection."

    let id: String
    var name: String
    var rules: SmartCollectionRules
    /// Shown as a row on Home (true) or only in Library (false).
    var home: Bool
    let createdAt: Double

    var field: String { Self.fieldPrefix + id }

    static func make(name: String, rules: SmartCollectionRules, home: Bool) -> SmartCollection {
        SmartCollection(id: UUID().uuidString.lowercased(), name: name, rules: rules, home: home,
                        createdAt: Date().timeIntervalSince1970)
    }
}

extension SmartCollection {
    /// In an extension so the memberwise initializer stays available to `make`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        rules = try c.decodeIfPresent(SmartCollectionRules.self, forKey: .rules) ?? SmartCollectionRules()
        home = try c.decodeIfPresent(Bool.self, forKey: .home) ?? false
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
    }
}

struct SmartCollectionRules: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case all, movie, series }
    enum Sort: String, Codable, CaseIterable, Sendable { case popular, rating, newest }

    var genres: [String] = []
    var extras: [String] = []
    var people: [ForYouPerson] = []
    var yearFrom: Int? = nil
    var yearTo: Int? = nil
    var minRating: Double? = nil
    var type: Kind = .all
    var hideWatched: Bool = false
    var sort: Sort = .popular

    var genreChoices: [ForYouGenre] { genres.compactMap(ForYouGenre.init(rawValue:)) }
    var extraChoices: [ForYouExtra] { extras.compactMap(ForYouExtra.init(rawValue:)) }
    var isEmpty: Bool { genreChoices.isEmpty && extraChoices.isEmpty && people.isEmpty }

    init() {}

    /// Tolerant like `ForYouInterests`: an unknown `type` or `sort` from a newer app falls back to the
    /// default instead of making the whole collection unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        extras = try c.decodeIfPresent([String].self, forKey: .extras) ?? []
        people = try c.decodeIfPresent([ForYouPerson].self, forKey: .people) ?? []
        yearFrom = try c.decodeIfPresent(Int.self, forKey: .yearFrom)
        yearTo = try c.decodeIfPresent(Int.self, forKey: .yearTo)
        minRating = try c.decodeIfPresent(Double.self, forKey: .minRating)
        type = (try c.decodeIfPresent(String.self, forKey: .type)).flatMap(Kind.init(rawValue:)) ?? .all
        hideWatched = try c.decodeIfPresent(Bool.self, forKey: .hideWatched) ?? false
        sort = (try c.decodeIfPresent(String.self, forKey: .sort)).flatMap(Sort.init(rawValue:)) ?? .popular
    }
}

/// Host-field validation for the `forYou.` namespace. Every received host document is validated
/// register by register and one failure rejects the whole document, so this checks structure only
/// (known field name, object or null, bounded size). Content is read with `try?`: a value this version
/// cannot decode just shows nothing, it never stops the account from syncing.
enum ForYouSync {
    static let prefix = VortxNativeHostPreferences.forYouPrefix
    static let maxBytes = VortxNativeHostPreferences.forYouMaxBytes

    /// The host preference validator itself, so a local write is held to exactly what a peer accepts.
    static func validate(_ field: String, value: VortxJSON) throws {
        try VortxNativeHostPreferences.validateForYouField(field, value: value)
    }

    /// `forYou.collection.<lowercase uuid>`.
    static func isCollectionField(_ field: String) -> Bool {
        guard field.hasPrefix(SmartCollection.fieldPrefix) else { return false }
        let id = String(field.dropFirst(SmartCollection.fieldPrefix.count))
        return UUID(uuidString: id)?.uuidString.lowercased() == id
    }

    static func value<T: Encodable>(_ model: T) throws -> VortxJSON {
        try JSONDecoder().decode(VortxJSON.self, from: JSONEncoder().encode(model))
    }

    /// The active profile's interests and live collections from a host preferences document.
    static func read(host: VortxJSON, profileID: UUID) -> (interests: ForYouInterests?, collections: [SmartCollection]) {
        guard case .object(let fields) = host["profiles"]?[profileID.uuidString]?["fields"] else { return (nil, []) }
        var interests: ForYouInterests?
        if let value = fields[ForYouInterests.field]?["value"] { interests = try? value.decode(ForYouInterests.self) }
        var collections: [SmartCollection] = []
        for (field, register) in fields where isCollectionField(field) {
            guard let value = register["value"], let collection = try? value.decode(SmartCollection.self),
                  collection.field == field, !collection.name.isEmpty else { continue }
            collections.append(collection)
        }
        collections.sort { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        return (interests, collections)
    }
}
