import Foundation

/// How well a stream's release name matches the title being opened, for the optional title-match source
/// filter (#172). Pure and stateless so it compiles on every target and in standalone tests; the Android twin
/// (`engine/SourceTitleMatch.kt`) follows the same rules and the same fixtures.
///
/// Only a release-style name can be judged: a filename or a description line with separated words and a
/// release marker (year, episode tag, resolution or video extension). A stream that names no release, such as
/// "Debridio 1080p", scores nil and is always kept.
enum SourceTitleMatch {
    struct Target: Hashable, Sendable {
        let title: String
        let year: Int?
        let season: Int?
        let episode: Int?

        init(title: String, year: Int? = nil, season: Int? = nil, episode: Int? = nil) {
            self.title = title
            self.year = year
            self.season = season
            self.episode = episode
        }
    }

    /// Thresholds the setting offers, in percent; 0 is off.
    static let thresholds = [0, 50, 70, 90]

    /// The first plausible release year in catalog text such as "2021" or "2019-2023", for a movie target.
    static func year(from releaseInfo: String?) -> Int? {
        guard let releaseInfo else { return nil }
        var digits = ""
        for character in releaseInfo + " " {
            if character.isASCII, character.isNumber {
                digits.append(character)
                continue
            }
            if digits.count == 4, let year = Int(digits), (1900...2099).contains(year) { return year }
            digits = ""
        }
        return nil
    }

    /// A synced or stored threshold the setting offers, else nil (an unknown value never filters).
    static func admittedThreshold(_ value: Int?) -> Int? {
        value.flatMap { thresholds.contains($0) ? $0 : nil }
    }

    /// 0...100, or nil when none of the texts names a release to compare. The best-scoring release wins.
    static func score(texts: [String?], target: Target) -> Int? {
        let titleTokens = tokens(normalized(target.title)).filter { !stopWords.contains($0) }
        let wanted = titleTokens.isEmpty ? tokens(normalized(target.title)) : titleTokens
        guard !wanted.isEmpty else { return nil }
        return texts.compactMap { $0 }
            .flatMap { $0.split(whereSeparator: \.isNewline).map(String.init) }
            .compactMap { releaseScore($0, wanted: wanted, target: target) }
            .max()
    }

    /// True when the stream should stay listed at `threshold` percent.
    static func passes(texts: [String?], target: Target, threshold: Int) -> Bool {
        guard threshold > 0, let score = score(texts: texts, target: target) else { return true }
        return score >= threshold
    }

    // MARK: Release parsing

    private static let stopWords: Set<String> = ["the", "a", "an", "and", "of"]
    private static let videoExtensions: Set<String> = ["mkv", "mp4", "avi", "m4v", "mov", "ts", "webm", "wmv"]
    private static let resolutionTokens: Set<String> = ["480p", "576p", "720p", "1080p", "1080i", "2160p", "4k", "uhd"]

    private enum Marker {
        case year(Int)
        case episode(season: Int, episodes: ClosedRange<Int>)
        case season(Int)
        case resolution
        case videoExtension
    }

    private static func releaseScore(_ line: String, wanted: [String], target: Target) -> Int? {
        let words = tokens(normalized(line))
        guard words.count >= 2 else { return nil }
        let markers = words.indices.compactMap { index in
            marker(words[index], next: index + 1 < words.count ? words[index + 1] : nil).map { (index, $0) }
        }
        guard let firstMarker = markers.first?.0, firstMarker > 0, isRelease(line, markers.map(\.1)) else { return nil }
        let releaseTitle = words[..<firstMarker].filter { !stopWords.contains($0) }
        let titleWords = releaseTitle.isEmpty ? Array(words[..<firstMarker]) : releaseTitle
        var score = dice(wanted, titleWords)

        for (_, found) in markers {
            switch found {
            case .episode(let season, let episodes):
                if let wantedSeason = target.season, let wantedEpisode = target.episode,
                   season != wantedSeason || !episodes.contains(wantedEpisode) { return 0 }
            case .season(let season):
                if let wantedSeason = target.season, season != wantedSeason { return 0 }
            case .year(let year):
                if target.season == nil, let wantedYear = target.year, abs(year - wantedYear) > 1 { score = min(score, 30) }
            case .resolution, .videoExtension:
                break
            }
        }
        return score
    }

    /// A line names a release only with release evidence: a video file extension, an episode or season tag, a
    /// year next to a resolution, or a dotted scene name. A bare label such as "Debridio 1080p" does not.
    private static func isRelease(_ line: String, _ markers: [Marker]) -> Bool {
        var hasYear = false, hasResolution = false
        for marker in markers {
            switch marker {
            case .videoExtension, .episode, .season: return true
            case .year: hasYear = true
            case .resolution: hasResolution = true
            }
        }
        if hasYear && hasResolution { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.contains(" ") && trimmed.split(separator: ".").count >= 4
    }

    private static func marker(_ word: String, next: String?) -> Marker? {
        if resolutionTokens.contains(word) { return .resolution }
        if videoExtensions.contains(word) { return .videoExtension }
        if word.count == 4, let year = Int(word), (1900...2099).contains(year) { return .year(year) }
        if let episode = episodeTag(word) { return episode }
        if word == "season", let next, let season = Int(next) { return .season(season) }
        return nil
    }

    /// `s01e02`, `s01e02e03`, `s01e02-e04` (the hyphen is a separator, so `s01e02` then `e04`), `1x02`, `s01`.
    private static func episodeTag(_ word: String) -> Marker? {
        let scalars = Array(word)
        if scalars.first == "s", let eIndex = scalars.firstIndex(of: "e"), eIndex > 1,
           let season = Int(String(scalars[1..<eIndex])) {
            let parts = String(scalars[(eIndex + 1)...]).split(separator: "e")
            let episodes = parts.compactMap { Int($0) }
            guard episodes.count == parts.count, let low = episodes.min(), let high = episodes.max() else { return nil }
            return .episode(season: season, episodes: low...high)
        }
        if scalars.first == "s", scalars.count > 1, scalars.count <= 3, let season = Int(String(scalars[1...])) {
            return .season(season)
        }
        let parts = word.split(separator: "x")
        if parts.count == 2, parts[0].count <= 2, parts[1].count >= 2, let season = Int(parts[0]), let episode = Int(parts[1]) {
            return .episode(season: season, episodes: episode...episode)
        }
        return nil
    }

    /// Sørensen-Dice over word sets, in percent: "Dune" against "Dune Part Two" is 50, not a full match.
    private static func dice(_ a: [String], _ b: [String]) -> Int {
        let left = Set(a), right = Set(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Int((200.0 * Double(left.intersection(right).count) / Double(left.count + right.count)).rounded())
    }

    // MARK: Normalisation

    /// Lower-cased, accents folded, "&" read as "and", and every non-alphanumeric run turned into one space.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        var output = ""
        var lastWasSpace = true
        for character in folded {
            if character.isLetter || character.isNumber {
                output.append(character)
                lastWasSpace = false
            } else if !lastWasSpace {
                output.append(" ")
                lastWasSpace = true
            }
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    private static func tokens(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
    }
}
