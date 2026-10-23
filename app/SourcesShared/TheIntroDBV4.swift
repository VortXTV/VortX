import Foundation

/// The public v4 read contract. Pure request/response decisions are shared with the regression harness.
enum TheIntroDBV4 {
    struct Lookup: Equatable, Sendable {
        let url: URL
        let cacheKey: String
    }

    struct Span: Equatable, Sendable {
        let kind: String
        let startMs: Int?
        let endMs: Int?
    }

    enum ReadResult: Equatable, Sendable {
        case media([Span])
        case notFound
        case episodeList
        case versions
        case httpFailure(Int)
    }

    static func supports(metaId: String) -> Bool { identity(for: metaId) != nil }

    static func lookup(metaId: String, season: Int?, episode: Int?, durationSeconds: Double) -> Lookup? {
        guard let identity = identity(for: metaId),
              var components = URLComponents(string: "https://api.theintrodb.org/v4/media") else { return nil }
        var items = [URLQueryItem(name: identity.name, value: identity.value)]
        let coordinates: String
        switch (season, episode) {
        case (nil, nil):
            coordinates = "movie"
        case let (.some(season), .some(episode)):
            guard (0...1000).contains(season), (0...10000).contains(episode) else { return nil }
            items.append(URLQueryItem(name: "season", value: String(season)))
            items.append(URLQueryItem(name: "episode", value: String(episode)))
            coordinates = "tv:\(season):\(episode)"
        default:
            return nil // Never turn an incomplete episode into a movie request.
        }
        // PlaybackMeta carries catalogue coordinates, not a media-server display order. Do not invent mapping.
        let durationMs = durationSeconds.isFinite && durationSeconds > 0
            ? Int(exactly: (durationSeconds * 1000).rounded(.towardZero)) : nil
        let durationKey: String
        if let durationMs, durationMs > 0 {
            let value = String(durationMs)
            items.append(URLQueryItem(name: "duration_ms", value: value))
            durationKey = value
        } else {
            durationKey = "unknown"
        }
        components.queryItems = items
        guard let url = components.url else { return nil }
        // Exact milliseconds select the release; nil coordinates must not collide with specials 0:0.
        return Lookup(url: url, cacheKey: "introdb:v4:\(identity.name)=\(identity.value):\(coordinates):\(durationKey)")
    }

    static func read(statusCode: Int, data: Data) throws -> ReadResult {
        if statusCode == 404 { return .notFound }
        guard statusCode == 200 else { return .httpFailure(statusCode) }
        return try JSONDecoder().decode(Payload.self, from: data).result
    }

    private static func identity(for metaId: String) -> (name: String, value: String)? {
        let bytes = metaId.utf8
        if bytes.starts(with: [0x74, 0x74]) {
            let digits = bytes.dropFirst(2)
            guard (7...8).contains(digits.count), digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            return ("imdb_id", metaId)
        }
        for (prefix, name, maximum) in [("tvdb:", "tvdb_id", 100_000_000), ("tmdb:", "tmdb_id", 10_000_000)] {
            guard metaId.hasPrefix(prefix) else { continue }
            let suffix = metaId.dropFirst(prefix.count)
            guard !suffix.isEmpty, suffix.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let id = Int(suffix), (1...maximum).contains(id) else { return nil }
            return (name, String(id))
        }
        return nil
    }

    private struct Payload: Decodable {
        enum CodingKeys: String, CodingKey { case tvdb_id, type, intro, recap, credits, preview, episodes, versions }
        enum MediaType: String, Decodable { case movie, tv }
        let result: ReadResult

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = try container.decode(Int.self, forKey: .tvdb_id)
            guard (1...100_000_000).contains(id) else {
                throw DecodingError.dataCorruptedError(forKey: .tvdb_id, in: container, debugDescription: "Invalid TVDB identity")
            }
            _ = try container.decode(MediaType.self, forKey: .type)
            let segments: [(CodingKeys, String)] = [(.intro, "intro"), (.recap, "recap"), (.credits, "credits"), (.preview, "preview")]
            let episodes = container.contains(.episodes)
            let versions = container.contains(.versions)
            if episodes || versions {
                guard !(episodes && versions), !segments.contains(where: { container.contains($0.0) }) else {
                    throw DecodingError.dataCorruptedError(forKey: episodes ? .episodes : .versions, in: container,
                                                          debugDescription: "Mixed v4 response variants")
                }
                _ = try container.nestedUnkeyedContainer(forKey: episodes ? .episodes : .versions)
                result = episodes ? .episodeList : .versions
                return
            }
            var spans: [Span] = []
            for (key, kind) in segments {
                guard container.contains(key) else { continue }
                // Present segment properties are arrays; omitted properties mean no data for that kind.
                let raw = try container.decode([RawSpan].self, forKey: key)
                spans += raw.map { Span(kind: kind, startMs: $0.startMs, endMs: $0.endMs) }
            }
            result = .media(spans)
        }
    }

    private struct RawSpan: Decodable {
        enum CodingKeys: String, CodingKey { case start_ms, end_ms }
        let startMs: Int?
        let endMs: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Required nullable keys: a missing key is malformed, not an implicit whole-file span.
            startMs = try container.decode(Int?.self, forKey: .start_ms)
            endMs = try container.decode(Int?.self, forKey: .end_ms)
            guard startMs.map({ $0 >= 0 }) ?? true, endMs.map({ $0 >= 0 }) ?? true else {
                throw DecodingError.dataCorruptedError(forKey: .start_ms, in: container, debugDescription: "Negative timestamp")
            }
        }
    }
}
