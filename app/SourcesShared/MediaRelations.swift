import Foundation

enum MediaRelations {
    enum Kind: String, Hashable { case prequel, sequel, related
        var label: String { rawValue.capitalized }
    }
    struct Entry: Hashable {
        let id: String; let type: String; let name: String; let poster: String?; let kind: Kind
        var identity: String { "\(type):\(id)" }
    }
    static func parseInternalDetailURL(_ raw: String) -> (type: String, id: String)? {
        guard let c = URLComponents(string: raw) else { return nil }
        let parts: [String]
        if c.scheme?.lowercased() == "stremio", (c.host ?? "").isEmpty,
           c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil {
            parts = c.percentEncodedPath.split(separator: "/").map(String.init)
        } else if c.scheme?.lowercased() == "https", c.host?.lowercased() == "web.stremio.com",
                  c.user == nil, c.password == nil, c.port == nil, ["", "/"].contains(c.path),
                  c.query == nil, let f = c.percentEncodedFragment {
            parts = f.split(separator: "/").map(String.init)
        } else { return nil }
        guard parts.count == 3, parts[0].lowercased() == "detail", !parts[1].isEmpty, !parts[2].isEmpty,
              let type = parts[1].removingPercentEncoding, let id = parts[2].removingPercentEncoding,
              !type.isEmpty, !id.isEmpty, !id.contains("/"),
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let allowedType = type == "movie" || type == "series" || type == "anime"
            || type.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 95 || $0 == 45 }
        guard allowedType else { return nil }
        return (type, id)
    }
    static func entries(from links: [CoreLink]?, selfIDs: Set<String>) -> [Entry] {
        var result: [Entry] = []; var seen = Set<String>()
        for link in links ?? [] {
            let category = link.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let kind: Kind
            switch category { case "prequel": kind = .prequel; case "sequel": kind = .sequel; case "related": kind = .related; default: continue }
            guard let url = link.url, let route = parseInternalDetailURL(url),
                  !link.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let key = "\(route.type.lowercased()):\(route.id)"
            let selfKeys = Set(selfIDs.map { "\(route.type.lowercased()):\($0)" })
            guard !selfIDs.contains(route.id), !selfKeys.contains(key), seen.insert(key).inserted else { continue }
            result.append(Entry(id: route.id, type: route.type,
                                name: link.name.trimmingCharacters(in: .whitespacesAndNewlines), poster: nil, kind: kind))
        }
        return result
    }
    static func releaseNeighbors<Part: Identifiable>(_ parts: [Part], currentID: String, id: (Part) -> String) -> (previous: Part?, next: Part?) {
        guard let index = parts.firstIndex(where: { id($0) == currentID }) else { return (nil, nil) }
        return (index > parts.startIndex ? parts[parts.index(before: index)] : nil,
                parts.index(after: index) < parts.endIndex ? parts[parts.index(after: index)] : nil)
    }
}
