import Foundation

/// Attribution never borrows another title's resident detail request. The native Player wire stores
/// identity only and does not fetch this meta URL; legacy dispatch still needs its matching request.
enum EpisodeEngineBindingRequest {
    static func build(libraryID: String?, native: Bool, sourceBase: String?,
                      residentMetaRequest: [String: Any]?, residentSourceBase: String?)
        -> (metaRequest: [String: Any], sourceBase: String)? {
        let title = libraryID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = residentMetaRequest?["path"] as? [String: Any]
        let residentMatches = path?["resource"] as? String == "meta"
            && path?["type"] as? String == "series"
            && (title == nil || path?["id"] as? String == title)
        if native {
            guard let title, !title.isEmpty else { return nil }
            let base = sourceBase ?? (residentMatches ? residentSourceBase ?? residentMetaRequest?["base"] as? String : nil)
                ?? "vortx://player"
            return (["base": base, "path": ["resource": "meta", "type": "series", "id": title, "extra": []]], base)
        }
        guard residentMatches, let request = residentMetaRequest,
              let base = sourceBase ?? residentSourceBase ?? request["base"] as? String else { return nil }
        return (request, base)
    }
}
