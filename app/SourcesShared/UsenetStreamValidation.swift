import Foundation

/// Pure validation for untrusted add-on NZB metadata.  It intentionally keeps NNTP credentials local-only
/// while refusing credential-bearing HTTP NZB descriptors before they can reach the bundled Node server.
enum UsenetStreamValidation {
    static func isUsenet(url: String?, singular: String?, plural: [String]?) -> Bool {
        url == nil && !nzbURLs(singular: singular, plural: plural).isEmpty
    }

    static func isTorrent(url: String?, infoHash: String?, singular: String?, plural: [String]?) -> Bool {
        url == nil && infoHash != nil && nzbURLs(singular: singular, plural: plural).isEmpty
    }

    static func streamIdentity(url: String?, externalURL: String?, infoHash: String?, singular: String?, plural: [String]?) -> String {
        url ?? externalURL ?? nzbURLs(singular: singular, plural: plural).first ?? infoHash ?? "?"
    }

    static func nzbURLs(singular: String?, plural: [String]?) -> [String] {
        ([singular].compactMap { $0 } + (plural ?? [])).reduce(into: [String]()) { result, candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: trimmed),
                  let scheme = parsed.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  parsed.host?.isEmpty == false,
                  parsed.user == nil, parsed.password == nil,
                  !result.contains(trimmed) else { return }
            result.append(trimmed)
        }
    }

    static func nntpServers(_ candidates: [String]?) -> [String] {
        (candidates ?? []).reduce(into: [String]()) { result, candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: trimmed),
                  let scheme = parsed.scheme?.lowercased(),
                  (scheme == "nntp" || scheme == "nntps"),
                  parsed.host?.isEmpty == false,
                  let user = parsed.user, !user.isEmpty,
                  let password = parsed.password, !password.isEmpty,
                  let port = parsed.port, (1...65535).contains(port),
                  parsed.query == nil, parsed.fragment == nil,
                  let connections = Int(parsed.path.dropFirst()), (1...100).contains(connections),
                  parsed.path == "/\(connections)",
                  !result.contains(trimmed) else { return }
            result.append(trimmed)
        }
    }
}
