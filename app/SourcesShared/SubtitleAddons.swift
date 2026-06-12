import Foundation

/// One external subtitle offered by a subtitles add-on (e.g. an OpenSubtitles add-on).
struct AddonSubtitle: Identifiable, Equatable {
    let id: String
    let url: String
    let lang: String
    let addonName: String
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

    /// All subtitles for `type/videoId` across the account's subtitle add-ons, in addon
    /// order, deduplicated by URL. videoId is a movie id or `id:season:episode`.
    static func fetch(addons: [AddonDescriptor], type: String, videoId: String) async -> [AddonSubtitle] {
        let sources = addons.filter { d in d.manifest.resources.contains { $0.name == "subtitles" } }
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
                                      lang: $0.lang ?? "und", addonName: source.manifest.name)
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
