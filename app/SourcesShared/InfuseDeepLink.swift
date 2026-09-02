import Foundation

/// Builds Infuse's documented x-callback play link with a stable, media-shaped filename.
///
/// The stream URL remains the authoritative playback address. The filename is metadata only: it
/// gives Infuse a title, episodic identity, and (when available) an IMDb tag it can use to match
/// metadata and Skip Intro without adding a stream to the user's Infuse library.
enum InfuseDeepLink {
    private static let fallbackExtension = "mkv"

    static func playURL(stream: URL, metadata: PlaybackMeta?) -> URL? {
        var components = URLComponents()
        components.scheme = "infuse"
        components.host = "x-callback-url"
        components.path = "/play"
        components.queryItems = [
            URLQueryItem(name: "url", value: stream.absoluteString),
            URLQueryItem(name: "filename", value: filename(for: stream, metadata: metadata))
        ]
        return components.url
    }

    static func filename(for stream: URL, metadata: PlaybackMeta?) -> String {
        let title = sanitizedComponent(metadata?.name ?? stream.deletingPathExtension().lastPathComponent)
        var components = [title.isEmpty ? "VortX" : title]

        if let metadata, let season = metadata.season, let episode = metadata.episode,
           season >= 0, episode >= 0 {
            components.append(String(format: "S%02dE%02d", season, episode))
        }
        if let identityTag = identityTag(from: metadata?.libraryId) {
            components.append(identityTag)
        }

        return components.joined(separator: " ") + ".\(fileExtension(for: stream))"
    }

    private static func sanitizedComponent(_ value: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
        let stripped = value.components(separatedBy: illegal).joined(separator: " ")
        return stripped
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func identityTag(from libraryID: String?) -> String? {
        guard let libraryID else { return nil }
        if libraryID.hasPrefix("tt"), libraryID.count > 2,
           libraryID.dropFirst(2).allSatisfy(\.isNumber) {
            return "{imdb-\(libraryID)}"
        }
        let parts = libraryID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.first == "tmdb", let numeric = parts.last,
              !numeric.isEmpty, numeric.allSatisfy(\.isNumber), let value = Int(numeric), value > 0
        else { return nil }
        return "{tmdb-\(value)}"
    }

    private static func fileExtension(for stream: URL) -> String {
        let candidate = stream.pathExtension.lowercased()
        guard !candidate.isEmpty, candidate.count <= 8,
              candidate.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
        else { return fallbackExtension }
        return candidate
    }
}
