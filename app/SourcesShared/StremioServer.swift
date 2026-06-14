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

    /// Whether the embedded server can proxy (the Lite build ships no node server, so it can't).
    static var canProxy: Bool {
        #if STREMIOX_NO_EMBEDDED_SERVER
        return false
        #else
        return true
        #endif
    }

    /// Route a header-gated HTTP(S) stream through the embedded server's `/proxy/` endpoint, the
    /// same path official Stremio uses for `notWebReady` add-on streams. The server fetches each
    /// request (and every HLS variant / segment, which it rewrites to come back through the proxy)
    /// applying the add-on's declared headers, then serves it to libmpv over plain loopback. This
    /// is what makes picky CDNs (e.g. ok.ru behind the KhmerDub add-on) play: their playlists and
    /// segments are fetched server-side with the right Referer / User-Agent and over a modern HTTP
    /// stack, which libmpv's own ffmpeg fetch cannot reproduce.
    ///
    /// Returns nil (caller falls back to the direct URL + mpv headers) when proxying isn't possible:
    /// the Lite build, a custom remote server, a torrent/local URL, or a non-HTTP URL.
    /// Server-side route format (from server.js): `/proxy/d={origin}&h={Name:Value}.../{path}{?query}`.
    static func proxiedURL(for streamURL: URL, headers: [String: String]) -> URL? {
        guard canProxy, !isCustom, !headers.isEmpty,
              let scheme = streamURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = streamURL.host else { return nil }
        // Never proxy the local torrent server back through itself.
        if host == "127.0.0.1" || host == "localhost" { return nil }

        var origin = "\(scheme)://\(host)"
        if let port = streamURL.port { origin += ":\(port)" }

        // querystring keys the server expects: d = destination origin, repeated h = "Name:Value".
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+/?:")   // encode separators so the qs parses cleanly
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }

        var qs = "d=\(enc(origin))"
        // The server splits each h= on its FIRST colon into Name:Value, so a value may contain ':'
        // (it survives, e.g. a URL value) but a NAME with a colon would mis-split. Skip malformed
        // names defensively; a valid HTTP header name never contains a colon anyway.
        for (name, value) in headers where !name.isEmpty && !name.contains(":") {
            qs += "&h=\(enc("\(name):\(value)"))"
        }

        let path = streamURL.path.isEmpty ? "/" : streamURL.path
        let search = streamURL.query.map { "?\($0)" } ?? ""
        return URL(string: "\(embedded)/proxy/\(qs)\(path)\(search)")
    }

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
        guard !PlaybackSettings.torrentsDisabled else { return nil }
        guard let ih = stream.infoHash?.lowercased() else { return nil }
        return URL(string: "\(base)/\(ih)/\(stream.fileIdx ?? 0)")
    }

    /// For torrents, tell the server to create the torrent (start fetching peers) before playback.
    /// No-op for direct/debrid streams. Fire-and-forget, the file endpoint blocks until ready.
    static func prepare(_ stream: Stream) {
        guard !PlaybackSettings.torrentsDisabled else { return }
        guard stream.url == nil, let ih = stream.infoHash?.lowercased(),
              let url = URL(string: "\(base)/\(ih)/create") else { return }
        // Inject the HTTP/HTTPS trackers (TorrentTrackers), exactly like the magnet and
        // player-warmup create paths. Without this, addon torrents were created with only
        // the addon's udp:// trackers + DHT -- all UDP, all dead in the tvOS sandbox -- so
        // the engine announced to nothing (0 peers). This create is usually FIRST, and the
        // engine ignores peerSearch on a torrent that already exists, so the first create's
        // sources are the ones that stick: they must carry the TCP/TLS trackers.
        let sources = TorrentTrackers.sources(forHash: ih, streamSources: stream.sources)
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

    /// Cap the embedded server's torrent cache once it's reachable. The server defaults to a
    /// 2 GB cache, which is too much for the Apple TV's per-app memory budget: a torrent
    /// buffering pieces into it pushes the app past the limit and tvOS jetsam-kills the whole
    /// process (the "server crash" -- nav bar dead, back drops to Home, server offline on
    /// reopen). 512 MB keeps a healthy streaming buffer without the memory pressure. The player's
    /// own read-ahead buffer and the binge preload are independent of this and unaffected.
    /// POST /settings merges the value (server.js: saveSettings -> userSettings.extend). Custom
    /// (remote) servers are left alone. Best-effort; polls while the server finishes booting.
    static func applyServerConfig() async {
        guard !isCustom, let url = URL(string: "\(embedded)/settings") else { return }
        // Device-aware cap. A flat 512 MB was still too much for the 2 GB Apple TV HD: loading one
        // torrent allocates the cache and jetsam kills the server after it succeeds once (issue #56).
        // Halve the cap on low-memory devices (≤ ~2.5 GB: Apple TV HD, older iPhones) where the per-app
        // budget is tightest; keep 512 MB on 3 GB+ devices for a fuller streaming buffer.
        let lowMemory = ProcessInfo.processInfo.physicalMemory < 2_500_000_000
        let cap = (lowMemory ? 256 : 512) * 1024 * 1024   // vs the 2 GB server default
        for _ in 0 ..< 12 {
            if await isOnline() {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["cacheSize": cap])
                _ = try? await URLSession.shared.data(for: req)
                return
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }
}
