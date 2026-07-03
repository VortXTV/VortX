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

    /// The PUBLIC remote YouTube-trailer resolver (`trailer.vortx.tv/yt/{id}` -> a directly-playable MP4,
    /// streamed through the worker). It needs NO embedded server, so it is the full-trailer path on EVERY
    /// scheme including Lite.
    static let remoteTrailerResolver = "https://trailer.vortx.tv"

    /// The base to hand a YouTube trailer id to. ALWAYS the public remote resolver (`trailer.vortx.tv`), on
    /// every build: the embedded `server.js` `/yt` route proved unreliable (it 403s once YouTube rotates), and
    /// the remote worker is server-fixable (a YouTube change is a worker redeploy, not an app resubmit) and
    /// works uniformly on the Lite build too. Callers append `/yt/{id}` + an optional `?lang=` hint.
    static var trailerResolverBase: String { remoteTrailerResolver }

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

    /// (Re)prime the embedded torrent engine for a KNOWN INFO HASH (not a full Stream), injecting the
    /// swarm-reaching HTTP/HTTPS trackers (TorrentTrackers) so the server opens a peered engine instead of
    /// a DHT-only one. Used by the Continue-Watching direct-resume path, whose stored loopback URL carries
    /// NO `?tr=` trackers: without this, resuming a torrent hits a peerless engine that never sends data
    /// (the "sources didn't load" red triangle on most CW torrent resumes). `/create` is idempotent, so an
    /// already-warm engine keeps its first sources. Fire-and-forget; the player's warm-up polling then
    /// succeeds because the engine now has reachable trackers.
    static func primeTorrent(hash: String, streamSources: [String]? = nil) {
        guard !PlaybackSettings.torrentsDisabled,
              let url = URL(string: "\(base)/\(hash)/create") else { return }
        let sources = TorrentTrackers.sources(forHash: hash, streamSources: streamSources)
        let body: [String: Any] = ["torrent": ["infoHash": hash],
                                   "peerSearch": ["sources": sources, "min": 40, "max": 150]]
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
    /// reopen). The player's own read-ahead buffer and the binge preload are independent of this.
    /// POST /settings merges the value (server.js: saveSettings -> userSettings.extend). Custom
    /// (remote) servers are left alone. Best-effort; polls while the server finishes booting.
    @discardableResult
    static func applyServerConfig(maxAttempts: Int = 20) async -> Bool {
        guard !isCustom, let url = URL(string: "\(embedded)/settings") else { return false }
        // The cache counts toward the app's OWN memory on iOS/iPadOS/tvOS (the server runs in-process), so
        // on top of mpv's 4K decode buffers even a 512 MB cache trips iOS jetsam on a real device during
        // playback (the device-only "server dies" report; the Simulator never hits it because it borrows
        // the Mac's RAM). Keep it generous only on macOS, where the server is a separate child process
        // with swap; on the in-process platforms scale it to the device and stay well under the per-app limit.
        #if os(macOS)
        let cap = 512 * 1024 * 1024
        #else
        let physical = ProcessInfo.processInfo.physicalMemory
        let cap = Int(min(UInt64(192 * 1024 * 1024), max(UInt64(96 * 1024 * 1024), physical / 32)))
        #endif
        // cacheSize bounds the ON-DISK piece cache. It does NOT bound the engine's in-memory
        // piece map: the disk storage backend writes each completed 512KB piece into a native
        // Buffer (off-heap, so it never shows in the JS heap — the "heap flat at 27MB, RSS to
        // 1.5GB" signature) and only frees it once the piece's verification group is whole AND
        // the SINGLE-worker disk writer (bagpipe(1)) has drained it. With 55 default connections
        // feeding pieces out-of-order, partial verify-groups pile up faster than they drain and
        // the process gets jetsam-killed on iOS. Halving the connection count keeps far fewer
        // partial groups in flight, so pieces verify+commit+free promptly and the in-memory map
        // stays bounded. btMaxConnections flows through enginefs.getDefaults -> engine.connections.
        // (Direct/debrid streams never touch this path; this only matters for torrent playback.)
        let body: [String: Any] = ["cacheSize": cap, "btMaxConnections": 24]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return false }
        // POST the cap and VERIFY it landed (HTTP 200), retrying while the server finishes its cold boot.
        // This cap is the ONLY thing keeping the in-process torrent cache off the jetsam line, and the
        // engine reads it at engine-creation time -- so a silently-dropped POST means the server runs its
        // 2 GB default cache + 55 connections and tvOS jetsam-kills the whole app under torrent load (the
        // "server crash / nav bar dead / whole device sluggish" class). The old code fire-and-forgot the
        // POST with no 200 check and no retry, so a boot slower than its 18 s window left the cap unset for
        // the entire session. A successful POST also proves the server is reachable, so it doubles as the
        // readiness gate (no separate isOnline() round-trip). Bounded loop; ~1 s between tries.
        for attempt in 0 ..< max(1, maxAttempts) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = payload
            req.timeoutInterval = 4
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 { return true }
            if attempt < maxAttempts - 1 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        return false
    }
}
