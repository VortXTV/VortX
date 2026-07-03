import Foundation

/// Resolves a YouTube video id to directly-playable googlevideo URLs FROM THE USER'S OWN IP, with no server
/// remux and no JS engine. This is the native Swift port of the trailer worker's proven no-nsig ladder
/// (`vortx-trailer/src/yt_resolve.ts`): POST the public InnerTube `/player` endpoint as a set of app clients
/// that return PLAIN progressive/adaptive URLs (no signatureCipher, no ciphered `n`), and only ever accept a
/// format whose `url` is present directly. On a residential IP the IOS/ANDROID clients return the full
/// streamingData: muxed itag 22/18 AND adaptive 1080p+.
///
/// Above 720p YouTube is adaptive-only (separate video+audio); libmpv plays that natively when the audio
/// stream is handed over as an `--audio-file` sidecar, which is why `Resolved` carries an optional `audioURL`.
/// Ambient/AVPlayer contexts that cannot take a sidecar pass `wantMuxedOnly: true` and get the best muxed
/// <=720 instead.
///
/// FAIL-SOFT: any network / decode / playability error is a miss for that client and the ladder moves on;
/// a fully-missed ladder returns nil. Never throws.
///
/// UPDATE-ON-BREAK: the client identity strings below (clientVersion / deviceModel / osVersion / userAgent)
/// are copied verbatim from the worker's CLIENTS table, itself refreshed from yt-dlp's INNERTUBE_CLIENTS.
/// YouTube rotates these; when trailers stop resolving, refresh BOTH here and in yt_resolve.ts together.
enum YouTubeDirectResolver {

    // MARK: - Public contract

    /// A successful resolve. `videoURL` is either a muxed (audio included) progressive mp4 OR a video-only
    /// adaptive stream; `audioURL` is non-nil ONLY in the adaptive case (feed it to mpv as `--audio-file`).
    struct Resolved {
        let videoURL: URL      // muxed (audio included) OR video-only adaptive
        let audioURL: URL?     // non-nil ONLY when videoURL is video-only (mpv --audio-file sidecar)
        let height: Int
        let isMuxed: Bool
    }

    /// Resolve `videoID` by walking the InnerTube client ladder (IOS -> ANDROID -> TVHTML5 embedded).
    /// `maxHeight` caps the adaptive pick (default 1080). `wantMuxedOnly`: ambient/AVPlayer contexts that
    /// cannot take a sidecar; the resolver then returns the best muxed <=720 (nil when no muxed url exists).
    static func resolve(videoID: String, maxHeight: Int = 1080, wantMuxedOnly: Bool = false) async -> Resolved? {
        // Hero + trailer button double-resolve the same id within seconds; serve the second from cache.
        let cacheKey = "\(videoID)|\(maxHeight)|\(wantMuxedOnly ? 1 : 0)"
        if let hit = await cache.get(cacheKey) {
            NSLog("[yt-direct] id=%@ client=%@ %@ h=%d", videoID, "cache", hit.isMuxed ? "muxed" : "adaptive", hit.height)
            return hit
        }

        for client in clients {
            guard let streaming = await fetchStreamingData(videoID: videoID, client: client) else { continue }

            if let resolved = pick(from: streaming, maxHeight: maxHeight, wantMuxedOnly: wantMuxedOnly) {
                await cache.set(cacheKey, resolved)
                NSLog("[yt-direct] id=%@ client=%@ %@ h=%d",
                      videoID, client.name, resolved.isMuxed ? "muxed" : "adaptive", resolved.height)
                return resolved
            }
        }
        NSLog("[yt-direct] id=%@ client=%@ %@ h=%d", videoID, "-", "MISS", 0)
        return nil
    }

    // MARK: - InnerTube client ladder

    /// The public "web" InnerTube API key. Long-lived, shipped in YouTube's own web client; used
    /// unauthenticated for the /player call (same constant as the worker).
    private static let innertubeKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    /// Per-client timeout. Bounds a cold-miss ladder (3 clients) so a stalled edge cannot serialize into a
    /// long wait; a timeout is treated as a miss.
    private static let clientTimeout: TimeInterval = 5

    /// One InnerTube client identity: `context` is the exact `client` object sent in the request body; `ua`
    /// is the matching User-Agent header; `clientNameNum` is the numeric id for the x-youtube-client-name
    /// header (yt-dlp INNERTUBE_CONTEXT_CLIENT_NAME).
    private struct Client {
        let name: String
        let ua: String
        let clientNameNum: Int
        let clientVersion: String
        let context: [String: Any]
    }

    /// Ladder order: IOS first (best formats on residential IPs), then ANDROID, then the embedded-TV client
    /// as a last resort (nsig-free for embeddable videos). Identity strings copied from yt_resolve.ts.
    private static let clients: [Client] = [
        Client(
            name: "IOS",
            ua: "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            clientNameNum: 5,
            clientVersion: "21.02.3",
            context: [
                "clientName": "IOS",
                "clientVersion": "21.02.3",
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "18.3.2.22D82",
                "userAgent": "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
                "hl": "en",
                "gl": "US",
            ]
        ),
        Client(
            name: "ANDROID",
            ua: "com.google.android.youtube/21.02.35 (Linux; U; Android 11) gzip",
            clientNameNum: 3,
            clientVersion: "21.02.35",
            context: [
                "clientName": "ANDROID",
                "clientVersion": "21.02.35",
                "androidSdkVersion": 30,
                "osName": "Android",
                "osVersion": "11",
                "userAgent": "com.google.android.youtube/21.02.35 (Linux; U; Android 11) gzip",
                "hl": "en",
                "gl": "US",
            ]
        ),
        Client(
            name: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            ua: "Mozilla/5.0 (PlayStation; PlayStation 4/12.00) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15",
            clientNameNum: 85,
            clientVersion: "2.0",
            context: [
                "clientName": "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
                "clientVersion": "2.0",
                "clientScreen": "EMBED",
                "userAgent": "Mozilla/5.0 (PlayStation; PlayStation 4/12.00) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15",
                "hl": "en",
                "gl": "US",
            ]
        ),
    ]

    // MARK: - InnerTube /player call

    /// The slice of the /player response we read. Any format that only exposes `signatureCipher`/`cipher`
    /// (a JS-required client) is rejected by the pickers below -- the whole point is no nsig, no JS engine.
    private struct PlayerResponse: Decodable {
        struct PlayabilityStatus: Decodable { let status: String? }
        struct Format: Decodable {
            let itag: Int?
            let url: String?
            let mimeType: String?
            let signatureCipher: String?
            let cipher: String?
            let height: Int?
            let bitrate: Int?
        }
        struct StreamingData: Decodable {
            let formats: [Format]?
            let adaptiveFormats: [Format]?
        }
        let playabilityStatus: PlayabilityStatus?
        let streamingData: StreamingData?
    }

    /// POST the InnerTube /player call for one client. Returns the streamingData on a playable answer, nil on
    /// any error, non-OK playability, or an empty response. Never throws.
    private static func fetchStreamingData(videoID: String, client: Client) async -> PlayerResponse.StreamingData? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(innertubeKey)&prettyPrint=false") else {
            return nil
        }
        var req = URLRequest(url: url, timeoutInterval: clientTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(client.ua, forHTTPHeaderField: "user-agent")
        // The numeric client name header some InnerTube edges expect; harmless when ignored.
        req.setValue(String(client.clientNameNum), forHTTPHeaderField: "x-youtube-client-name")
        req.setValue(client.clientVersion, forHTTPHeaderField: "x-youtube-client-version")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "origin")

        let body: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": client.context,
                // A minimal user-info block; InnerTube tolerates it and it mirrors real clients.
                "user": ["lockedSafetyMode": false],
                "request": ["useSsl": true],
            ],
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": [
                "contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data

        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let decoded = try? JSONDecoder().decode(PlayerResponse.self, from: respData) else { return nil }
            guard decoded.playabilityStatus?.status == "OK" else { return nil }
            return decoded.streamingData
        } catch {
            return nil
        }
    }

    // MARK: - Format picking

    /// A format is usable only when it carries a bare `url` (no signatureCipher/cipher = no decipher needed)
    /// AND that url points at googlevideo (a sanity gate against a poisoned/odd response).
    private static func plainURL(_ f: PlayerResponse.Format) -> URL? {
        guard f.signatureCipher == nil, f.cipher == nil,
              let raw = f.url, !raw.isEmpty,
              let url = URL(string: raw),
              let host = url.host, host.contains("googlevideo") else { return nil }
        return url
    }

    /// Apply the resolution policy to one client's streamingData:
    ///   * !wantMuxedOnly and an adaptive avc1 pair exists with height > 720 -> the pair (isMuxed false).
    ///   * otherwise the best muxed (itag 22 then 18).
    ///   * wantMuxedOnly -> muxed only (nil when none).
    private static func pick(from streaming: PlayerResponse.StreamingData,
                             maxHeight: Int,
                             wantMuxedOnly: Bool) -> Resolved? {
        if !wantMuxedOnly,
           let pair = pickAdaptivePair(streaming.adaptiveFormats ?? [], maxHeight: maxHeight),
           pair.height > 720 {
            return Resolved(videoURL: pair.video, audioURL: pair.audio, height: pair.height, isMuxed: false)
        }
        if let muxed = pickMuxed(streaming.formats ?? []) {
            return Resolved(videoURL: muxed.url, audioURL: nil, height: muxed.height, isMuxed: true)
        }
        return nil
    }

    /// Best muxed progressive format: itag 22 (720p mp4) then 18 (360p mp4), plain url only. InnerTube
    /// `formats` is the muxed set; `adaptiveFormats` is the split set, deliberately never read here.
    private static func pickMuxed(_ formats: [PlayerResponse.Format]) -> (url: URL, height: Int)? {
        for itag in [22, 18] {
            if let f = formats.first(where: { $0.itag == itag }), let url = plainURL(f) {
                return (url, f.height ?? (itag == 22 ? 720 : 360))
            }
        }
        return nil
    }

    /// Best adaptive video+audio pair under `maxHeight`. Video: mp4/avc1 (H.264 for AVPlayer/mpv hardware
    /// decode) picked by highest height then highest bitrate; vp9 is allowed only when no avc1 stream carries
    /// a plain url. Audio: audio/mp4 (m4a) highest bitrate. Both legs must have plain urls or there is no pair.
    private static func pickAdaptivePair(_ adaptive: [PlayerResponse.Format],
                                         maxHeight: Int) -> (video: URL, audio: URL, height: Int)? {
        func bestVideo(where codecMatch: (String) -> Bool) -> (URL, Int)? {
            var best: (url: URL, height: Int, bitrate: Int)?
            for f in adaptive {
                guard let mime = f.mimeType, mime.hasPrefix("video/"), codecMatch(mime),
                      let h = f.height, h <= maxHeight,
                      let url = plainURL(f) else { continue }
                let br = f.bitrate ?? 0
                if let b = best, (h, br) <= (b.height, b.bitrate) { continue }
                best = (url, h, br)
            }
            guard let b = best else { return nil }
            return (b.url, b.height)
        }

        let video = bestVideo(where: { $0.hasPrefix("video/mp4") && $0.contains("avc1") })
            ?? bestVideo(where: { $0.contains("vp9") || $0.contains("vp09") })
        guard let (videoURL, height) = video else { return nil }

        var bestAudio: (url: URL, bitrate: Int)?
        for f in adaptive {
            guard let mime = f.mimeType, mime.hasPrefix("audio/mp4"),
                  let url = plainURL(f) else { continue }
            let br = f.bitrate ?? 0
            if let b = bestAudio, br <= b.bitrate { continue }
            bestAudio = (url, br)
        }
        guard let audio = bestAudio else { return nil }

        return (videoURL, audio.url, height)
    }

    // MARK: - In-memory cache

    /// googlevideo urls expire ~6h after issue; a 2h TTL keeps cached entries comfortably inside that window
    /// while letting hero + trailer button share one resolve.
    private static let cacheTTL: TimeInterval = 2 * 60 * 60

    /// Tiny actor-guarded cache: key = videoID|maxHeight|muxedOnly -> Resolved. Expired entries are dropped
    /// on read; the map stays small (a handful of trailers per browsing session).
    private actor ResolveCache {
        private var entries: [String: (value: Resolved, stored: Date)] = [:]

        func get(_ key: String) -> Resolved? {
            guard let e = entries[key] else { return nil }
            guard Date().timeIntervalSince(e.stored) < YouTubeDirectResolver.cacheTTL else {
                entries[key] = nil
                return nil
            }
            return e.value
        }

        func set(_ key: String, _ value: Resolved) {
            entries[key] = (value, Date())
        }
    }

    private static let cache = ResolveCache()
}
