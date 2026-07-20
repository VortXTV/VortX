import Foundation

/// One external subtitle offered by a subtitles add-on (e.g. an OpenSubtitles add-on).
struct AddonSubtitle: Identifiable, Equatable {
    let id: String
    let url: String
    let lang: String
    let addonName: String
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
        let url: String
        let lang: String?
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
    static func fetch(sources: [SubtitleAddonSource], type: String, videoId: String) async -> [AddonSubtitle] {
        guard !sources.isEmpty else { return [] }
        let safeId = videoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? videoId

        let collected: [[AddonSubtitle]] = await withTaskGroup(of: (Int, [AddonSubtitle]).self) { group in
            for (i, source) in sources.enumerated() {
                group.addTask {
                    guard let url = URL(string: "\(source.baseUrl)/subtitles/\(type)/\(safeId).json") else {
                        return (i, [])
                    }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 15
                    guard let (data, resp) = try? await URLSession.shared.data(for: req),
                          let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let decoded = try? JSONDecoder().decode(SubtitlesResponse.self, from: data) else {
                        return (i, [])
                    }
                    let subs = (decoded.subtitles ?? []).map {
                        AddonSubtitle(id: $0.id ?? $0.url, url: $0.url,
                                      lang: $0.lang ?? "und", addonName: source.name)
                    }
                    return (i, subs)
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
