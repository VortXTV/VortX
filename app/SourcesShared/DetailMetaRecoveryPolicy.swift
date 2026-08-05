import Foundation

/// Pure decisions used by both detail surfaces while recovering metadata for catalog IDs that the
/// installed meta add-ons cannot answer directly. Kept free of app types so the shipped policy can
/// be compiled into a small standalone regression test.
enum DetailMetaRecoveryPolicy {
    enum Resolution: String, Equatable {
        case ready
        case pending
        case unresolved
    }

    enum EntryState: Equatable {
        case ready
        case loading
        case failed
        case notStarted
    }

    static func resolution(entries: [EntryState]) -> Resolution {
        if entries.contains(.ready) { return .ready }
        if entries.isEmpty { return .unresolved }
        if entries.contains(.loading) || entries.contains(.notStarted) { return .pending }
        return .unresolved
    }

    /// A terminal result is meaningful only for the request currently selected by the engine.
    /// Returning nil for a selection mismatch prevents a stale title's empty result from triggering
    /// recovery on the page that has just replaced it.
    static func resolution(
        selectedID: String?,
        requestedID: String,
        entries: [EntryState]
    ) -> Resolution? {
        guard selectedID == requestedID else { return nil }
        return resolution(entries: entries)
    }

    enum TMDBMedia: String, Equatable {
        case movie
        case tv
    }

    enum CatalogIDShape: Equatable {
        case imdb(String)
        case tmdb(Int, media: TMDBMedia?)
        case tvdb(Int)
        /// A Kitsu anime id (`kitsu:460`). Unlike the others this carries no id TMDB understands, so it
        /// resolves in TWO hops: Kitsu's own mappings API names the title's TheTVDB / TMDB / IMDb id, and
        /// that shape then resolves exactly like a native `tvdb:` / `tmdb:` catalog id. Anime add-ons hand
        /// out these ids constantly, and without a shape for them every anime detail page opened from such a
        /// catalog had no recovery path at all and latched on "Details unavailable".
        case kitsu(Int)
        case unsupported
    }

    /// Parse only catalog ID shapes with an unambiguous lookup path. Unknown schemes remain
    /// unsupported instead of being guessed onto a possibly unrelated title.
    static func catalogIDShape(_ raw: String) -> CatalogIDShape {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .unsupported }

        if let imdb = imdbID(value) { return .imdb(imdb) }

        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if let embedded = parts.compactMap(imdbID).first { return .imdb(embedded) }

        let lowered = parts.map { $0.lowercased() }
        if lowered.count == 2, lowered[0] == "tmdb" {
            guard let id = positiveInteger(lowered[1]) else { return .unsupported }
            return .tmdb(id, media: nil)
        }
        if lowered.count == 3, lowered[0] == "tmdb" {
            guard let id = positiveInteger(lowered[2]),
                  let kind = TMDBMedia(rawValue: lowered[1]) else {
                return .unsupported
            }
            return .tmdb(id, media: kind)
        }
        if lowered.count == 2, lowered[0] == "tvdb" {
            guard let id = positiveInteger(lowered[1]) else { return .unsupported }
            return .tvdb(id)
        }
        // Strict on purpose, exactly like `tvdb:` above: the SHOW id only. An episode-qualified anime id
        // ("kitsu:460:1:2") is not a detail-page route, and accepting its trailing numbers would be the
        // guessing this parser exists to prevent.
        if lowered.count == 2, lowered[0] == "kitsu" {
            guard let id = positiveInteger(lowered[1]) else { return .unsupported }
            return .kitsu(id)
        }
        if lowered.count == 1 {
            guard let id = positiveInteger(lowered[0]) else { return .unsupported }
            return .tmdb(id, media: nil)
        }
        return .unsupported
    }

    private static func imdbID(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        guard lowered.hasPrefix("tt"), lowered.count > 2 else { return nil }
        let digits = lowered.dropFirst(2)
        guard digits.allSatisfy(asciiDigit) else { return nil }
        return lowered
    }

    private static func positiveInteger(_ raw: String) -> Int? {
        guard !raw.isEmpty, raw.allSatisfy(asciiDigit), let value = Int(raw), value > 0 else {
            return nil
        }
        return value
    }

    private static func asciiDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }
}
