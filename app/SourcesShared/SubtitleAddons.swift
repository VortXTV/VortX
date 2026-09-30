import Foundation

extension CoreStreamBehaviorHints {
    var subtitleMetadata: SubtitleRequestMetadata {
        SubtitleRequestMetadata(filename: filename, videoHash: videoHash, videoSize: videoSize)
    }
}

/// One external subtitle offered by a subtitles add-on (e.g. an OpenSubtitles add-on).
struct AddonSubtitle: Identifiable, Equatable {
    let id: String
    let url: String
    let lang: String
    let addonName: String
    var releaseName: String? = nil

    var displayTitle: String {
        guard let releaseName, !releaseName.isEmpty else { return addonName }
        return "\(addonName) · \(releaseName)"
    }
}

/// A minimal installed subtitle add-on: the base URL to query and a display name. Decouples the fetch from
/// any one descriptor type so it can UNION the engine's installed add-ons (`CoreDescriptor`, the source of
/// truth since VortX went account-primary) with the legacy Stremio-collection add-ons (`AddonDescriptor`),
/// which are empty on a VortX-primary device with no live Stremio session (ozdek #148).
struct SubtitleAddonSource: Equatable {
    let baseUrl: String
    let name: String
}

/// Fetches external subtitles from every installed add-on that declares the `subtitles`
/// resource, the way the official clients do. The player lists these next to the file's
/// embedded tracks; picking one hands the URL to mpv (`sub-add`).
enum SubtitleAddonService {
    private struct SubtitlesResponse: Decodable { let subtitles: [Sub]? }
    private struct Sub: Decodable {
        let id: String?
        let url: String?
        let lang: String?
        let subtitleFileName: String?

        enum CodingKeys: String, CodingKey { case id, url, lang, subtitleFileName }
        init(from decoder: Decoder) throws {
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            id = try? fields?.decode(String.self, forKey: .id)
            url = try? fields?.decode(String.self, forKey: .url)
            lang = try? fields?.decode(String.self, forKey: .lang)
            subtitleFileName = try? fields?.decode(String.self, forKey: .subtitleFileName)
        }
    }

    /// The installed subtitle add-ons to query: the ENGINE store first (`core.addons`, authoritative since
    /// installs stopped propagating to the Stremio collection on a VortX-primary device), with the
    /// Stremio-collection store (`account.addons`) unioned in as a fallback so a still-Stremio-connected
    /// device is unchanged. Deduped by normalized base URL (engine wins on a tie). Both lists are filtered to
    /// add-ons that declare the `subtitles` resource. This is the #148 fix: the old fetch read only
    /// `account.addons`, which is empty when there is no live Stremio session.
    static func installedSources(engine: [CoreDescriptor], account: [AddonDescriptor]) -> [SubtitleAddonSource] {
        var seen = Set<String>()
        var out: [SubtitleAddonSource] = []
        func add(_ base: String, _ name: String) {
            let norm = AddonTombstones.normalize(base)
            guard !norm.isEmpty, seen.insert(norm).inserted else { return }
            out.append(SubtitleAddonSource(baseUrl: base, name: name))
        }
        for d in engine where d.providesSubtitles { add(d.baseUrl, d.manifest.name) }
        for d in account where d.manifest.resources.contains(where: { $0.name == "subtitles" }) {
            add(d.baseUrl, d.manifest.name)
        }
        return out
    }

    /// All subtitles for `type/videoId` across the given subtitle add-ons, in source order,
    /// deduplicated by URL. videoId is a movie id or `id:season:episode`.
    static func fetch(sources: [SubtitleAddonSource], type: String, videoId: String,
                      metadata: SubtitleRequestMetadata = .init(),
                      session: URLSession = .shared) async -> [AddonSubtitle] {
        guard !sources.isEmpty else { return [] }
        let path = metadata.resourcePath(type: type, videoID: videoId)
        let legacyPath = SubtitleRequestMetadata().resourcePath(type: type, videoID: videoId)
        let paths = path == legacyPath ? [path] : [path, legacyPath]

        let collected: [[AddonSubtitle]] = await withTaskGroup(of: (Int, [AddonSubtitle]).self) { group in
            for (i, source) in sources.enumerated() {
                group.addTask {
                    for (attempt, resourcePath) in paths.enumerated() {
                        guard !Task.isCancelled,
                              let url = URL(string: "\(source.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(resourcePath)") else {
                            return (i, [])
                        }
                        var req = URLRequest(url: url)
                        req.timeoutInterval = 15
                        guard let (data, resp) = try? await session.data(for: req),
                              let http = resp as? HTTPURLResponse else { return (i, []) }
                        // Older routers may only implement the ID-only route. Retry it once for a route
                        // rejection, never for an empty successful result, auth failure or provider outage.
                        if attempt == 0, paths.count > 1, [404, 405].contains(http.statusCode) { continue }
                        guard (200..<300).contains(http.statusCode),
                              let decoded = try? JSONDecoder().decode(SubtitlesResponse.self, from: data) else {
                            return (i, [])
                        }
                        let subs = (decoded.subtitles ?? []).compactMap { sub -> AddonSubtitle? in
                            guard let url = sub.url, !url.isEmpty else { return nil }
                            return AddonSubtitle(id: sub.id ?? url, url: url,
                                                 lang: sub.lang ?? "und", addonName: source.name,
                                                 releaseName: sub.subtitleFileName)
                        }
                        return (i, subs)
                    }
                    return (i, [])
                }
            }
            var buckets = [[AddonSubtitle]](repeating: [], count: sources.count)
            for await (i, chunk) in group { buckets[i] = chunk }
            return buckets
        }

        var seen = Set<String>()
        return collected.flatMap { $0 }.filter { seen.insert($0.url).inserted }
    }
}
