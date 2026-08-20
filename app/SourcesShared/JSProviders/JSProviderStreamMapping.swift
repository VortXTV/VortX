import Foundation

/// Maps a community JS provider's output objects into VortX `CoreStream`s so they land in the SAME source list,
/// ranking, filtering, and playback-header path as every other source.
///
/// A provider returns `{ name, title, url, quality, size?, headers?, subtitles? }` (see design section 1.4).
/// The mapping (design section 5):
///  - `url`      -> `CoreStream.url` (a direct/HLS URL, played as-is like any direct source);
///  - `headers`  -> `behaviorHints.proxyHeaders.request`, i.e. the EXACT existing `CoreStream.requestHeaders`
///                  playback path, so a header-gated CDN works with no new plumbing;
///  - `quality` + `title` + `name` + `size` fold into `name` / `description` TEXT so `StreamRanking` scores the
///                  stream (it parses resolution/source/HDR/audio/size out of that text);
///  - `vortxProvider` is stamped `"jsplugin:<id>"` so the stream is attributable to its provider, mirroring the
///                  media-server provenance marker;
///  - each provider's streams are one `CoreStreamSourceGroup(id: "jsplugin:<id>", addon: <providerName>)`.
///
/// The `CoreStream` is built by the JSON round-trip technique already used by `MediaServerSource.synthetic`
/// and `TorBoxSearch.make` (assemble a `[String: Any]`, `JSONDecoder().decode(CoreStream.self, ...)`), so the
/// provider's JSON output maps with almost no translation and needs no new model.
enum JSProviderStreamMapping {

    static let maximumStreamsPerProvider = 80

    /// Stable group id prefix, also the `vortxProvider` marker prefix, so a JS-provider stream is attributable
    /// and can get its own tier/label later.
    static func groupID(for providerID: String) -> String { "jsplugin:\(providerID)" }

    /// Build one `CoreStreamSourceGroup` from a provider's raw output. Returns nil when nothing mapped.
    static func group(from rawStreams: [[String: Any]], provider: JSInstalledProvider) -> CoreStreamSourceGroup? {
        let streams = rawStreams.prefix(maximumStreamsPerProvider).compactMap {
            coreStream(from: $0, providerID: provider.id, providerName: provider.name)
        }
        guard !streams.isEmpty else { return nil }
        return CoreStreamSourceGroup(id: groupID(for: provider.id), addon: provider.name, streams: streams)
    }

    /// Map one provider stream object to a `CoreStream`. Requires a playable http(s) `url`; drops anything else
    /// (M1 targets direct/HLS providers, per design 6.1).
    static func coreStream(from dict: [String: Any], providerID: String, providerName: String) -> CoreStream? {
        guard let url = (dict["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty, url.count <= 2_048, let parsedURL = URL(string: url),
              JSProviderURLPolicy.default.isAllowed(parsedURL) else { return nil }

        let quality = (dict["quality"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerLabel = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sizeText = formattedSize(dict["size"])

        // name: the provider label + the resolution tier, so the source row is self-identifying and the ranker
        // sees the tier. description: the release title (usually carrying WEB-DL/BluRay/HDR/codec tokens) + the
        // size, so StreamRanking scores resolution/source/HDR/audio/size from the text.
        let nameParts = [providerLabel?.isEmpty == false ? providerLabel : providerName, quality].compactMap { $0 }.filter { !$0.isEmpty }
        let name = clipped(nameParts.isEmpty ? providerName : nameParts.joined(separator: " · "), maximum: 240)
        var descParts: [String] = []
        if let title, !title.isEmpty { descParts.append(title) }
        // Ensure the quality token is present in the ranked text even when the title omits it.
        if let quality, !quality.isEmpty, !(title?.localizedCaseInsensitiveContains(quality) ?? false) {
            descParts.append(quality)
        }
        if let sizeText { descParts.append(sizeText) }
        let description = clipped(descParts.isEmpty ? name : descParts.joined(separator: " · "), maximum: 600)

        var json: [String: Any] = [
            "url": url,
            "name": name,
            "description": description,
            "vortxProvider": groupID(for: providerID),
        ]

        // headers -> behaviorHints.proxyHeaders.request (the existing playback header path).
        if let headers = stringHeaders(dict["headers"]), !headers.isEmpty {
            json["behaviorHints"] = ["proxyHeaders": ["request": headers]]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(CoreStream.self, from: data)
    }

    /// Coerce a provider `headers` object into `[String: String]` (values stringified defensively).
    private static func stringHeaders(_ raw: Any?) -> [String: String]? {
        guard let dict = raw as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (k, v) in dict.prefix(32) {
            guard k.count <= 128, !k.contains("\r"), !k.contains("\n") else { continue }
            if let s = v as? String, s.count <= 2_048, !s.contains("\r"), !s.contains("\n") { out[k] = s }
            else if let n = v as? NSNumber { out[k] = n.stringValue }
        }
        return out.isEmpty ? nil : out
    }

    /// Format `size` (bytes) into a human string for the ranked description. Accepts a JSON number or a numeric
    /// string; a non-numeric string is passed through as-is (some providers put "1.2 GB" straight in `size`).
    private static func formattedSize(_ raw: Any?) -> String? {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .binary
        switch raw {
        case let n as NSNumber:
            let bytes = n.int64Value
            return bytes > 0 ? fmt.string(fromByteCount: bytes) : nil
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let bytes = Int64(trimmed), bytes > 0 { return fmt.string(fromByteCount: bytes) }
            return trimmed   // already a display string like "1.2 GB"
        default:
            return nil
        }
    }

    private static func clipped(_ text: String, maximum: Int) -> String {
        text.count <= maximum ? text : String(text.prefix(maximum))
    }
}
