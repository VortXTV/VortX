import Foundation

/// Client for the embedded Stremio streaming server (nodejs-mobile on :11470). Direct/debrid
/// streams play straight from their URL; torrents are created on the local server, which fetches
/// pieces and exposes the selected file over HTTP for libmpv to play.
enum StremioServer {
    /// The on-device server. Used unless the user points at a remote/dedicated server.
    static let embedded = "http://127.0.0.1:11470"
    private static let urlKey = "stremiox.serverURL"

    /// The active streaming-server base, the user's custom URL if set, else the embedded one.
    static var base: String {
        let v = UserDefaults.standard.string(forKey: urlKey) ?? ""
        return v.isEmpty ? embedded : v
    }
    static var isCustom: Bool { base != embedded }

    /// Persist a custom server URL (nil/empty → revert to the embedded server). Normalizes the
    /// input (adds http:// if missing, trims a trailing slash). Returns the stored value.
    @discardableResult
    static func setBase(_ raw: String?) -> String {
        UserDefaults.standard.setValue(normalize(raw), forKey: urlKey)
        return base
    }
    static func useEmbedded() { UserDefaults.standard.removeObject(forKey: urlKey) }

    static func normalize(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s) != nil ? s : nil
    }

    /// Reachability of an arbitrary server URL (for the "Test" button before saving).
    static func reachable(_ raw: String?) async -> Bool {
        guard let b = normalize(raw), let url = URL(string: "\(b)/settings") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Is the active streaming server reachable? (Settings shows this.)
    static func isOnline() async -> Bool {
        guard let url = URL(string: "\(base)/settings") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// The playable URL for a stream, its direct URL, or the local server's file endpoint for a
    /// torrent. Pure (no side effects); call `prepare(_:)` to actually create the torrent.
    static func resolveURL(for stream: Stream) -> URL? {
        if let u = stream.url, let url = URL(string: u) { return url }
        guard let ih = stream.infoHash?.lowercased() else { return nil }
        return URL(string: "\(base)/\(ih)/\(stream.fileIdx ?? 0)")
    }

    /// For torrents, tell the server to create the torrent (start fetching peers) before playback.
    /// No-op for direct/debrid streams. Fire-and-forget, the file endpoint blocks until ready.
    static func prepare(_ stream: Stream) {
        guard stream.url == nil, let ih = stream.infoHash?.lowercased(),
              let url = URL(string: "\(base)/\(ih)/create") else { return }
        var sources = stream.sources ?? []
        sources.append("dht:\(ih)")
        let body: [String: Any] = [
            "torrent": ["infoHash": ih],
            "peerSearch": ["sources": sources, "min": 40, "max": 150],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }
}
