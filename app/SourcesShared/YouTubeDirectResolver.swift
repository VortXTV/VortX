import Foundation

/// Resolves a YouTube video id to directly-playable googlevideo URLs FROM THE USER'S OWN IP, with no server
/// remux and no JS engine. This is the native Swift port of the trailer worker's proven no-nsig ladder
/// (`vortx-trailer/src/yt_resolve.ts`): POST the public InnerTube `/player` endpoint as a set of app clients
/// that return PLAIN progressive/adaptive URLs (no signatureCipher, no ciphered `n`), and only ever accept a
/// format whose `url` is present directly. On a residential IP the IOS/ANDROID clients return the full
/// streamingData: muxed itag 22/18 AND adaptive 1080p+.
///
/// Modern trailers are ADAPTIVE-ONLY at EVERY height on the residential IOS client: the `/player` answer is
/// playable OK with ZERO muxed formats (no itag 18/22) and a split video-only + audio-only set up to 1080p
/// (verified live). libmpv plays that natively when the audio-only stream is handed over as an `--audio-file`
/// sidecar, which is why `Resolved` carries an optional `audioURL`. So the resolver prefers a muxed format
/// only WHEN the client actually exposes one, and otherwise returns the adaptive pair at whatever height is
/// offered (it does NOT require the pair to be > 720). A pure-AVPlayer context that cannot take a sidecar can
/// still pass `wantMuxedOnly: true` to get muxed-or-nil, but no shipping trailer/ambient caller does: they all
/// play through mpv (the button mounts the audio sidecar, the muted ambient just renders the video-only leg).
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

    /// The User-Agent googlevideo REQUIRES for the URLs this resolver returns. googlevideo binds an issued
    /// URL to the InnerTube client that minted it: replay it with a DIFFERENT UA (mpv's stock "Lavf/*", or
    /// even the app's Safari-like default) and googlevideo answers 403, which surfaces in libmpv as
    /// `endFileError reason=loading failed` and the "Trailer unavailable" overlay. Because the IOS client is
    /// first in the ladder and answers on residential IPs, its UA is the one that matches the returned host;
    /// the player MUST send this exact UA for both the video URL and the `--audio-file` sidecar. This is the
    /// same string as `clients[0].ua` (the IOS entry), hoisted to a public constant the player can apply
    /// without re-deriving the ladder. Keep it in lockstep with the IOS `Client.ua` below.
    static let googlevideoUserAgent = "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"

    /// Resolve `videoID` by walking the InnerTube client ladder (IOS -> ANDROID -> TVHTML5 embedded), returning
    /// on the first client that yields a usable format. `maxHeight` caps the adaptive pick (default 1080).
    /// `wantMuxedOnly`: a pure-AVPlayer context that cannot take an audio sidecar; the resolver then returns a
    /// muxed format only (nil when the client exposed none). Default (false) returns muxed-when-present, else
    /// the adaptive video+audio pair at any height.
    ///
    /// `preferredAudioLanguages`: ISO-639-1 codes in priority order used to pick the AUDIO track when a modern
    /// YouTube trailer ships MULTIPLE audio languages (the "trailer played in the wrong language" bug). nil (the
    /// default) resolves to `TMDBClient.preferredTrailerLanguages`, the exact same priority the app used to pick
    /// this trailer's id (explicit picker -> UI language -> audio langs -> device langs), so the audio track
    /// matches the trailer's intended language. Never empty in practice (device languages default to ["en"]).
    static func resolve(videoID: String,
                        maxHeight: Int = 1080,
                        wantMuxedOnly: Bool = false,
                        preferredAudioLanguages: [String]? = nil) async -> Resolved? {
        let prefLangs = preferredAudioLanguages ?? TMDBClient.preferredTrailerLanguages
        // Hero + trailer button double-resolve the same id within seconds; serve the second from cache. The
        // preferred-language head is part of the key so a later resolve with a different audio preference does
        // NOT get served a stale wrong-language pick from the cache.
        let cacheKey = "\(videoID)|\(maxHeight)|\(wantMuxedOnly ? 1 : 0)|\(prefLangs.joined(separator: "-"))"
        if let hit = await cache.get(cacheKey) {
            NSLog("[yt-direct] id=%@ client=%@ %@ h=%d", videoID, "cache", hit.isMuxed ? "muxed" : "adaptive", hit.height)
            return hit
        }

        for client in clients {
            guard let streaming = await fetchStreamingData(videoID: videoID, client: client) else { continue }

            if let resolved = pick(from: streaming, maxHeight: maxHeight, wantMuxedOnly: wantMuxedOnly,
                                   preferredLanguages: prefLangs) {
                await cache.set(cacheKey, resolved)
                NSLog("[yt-direct] id=%@ client=%@ %@ h=%d",
                      videoID, client.name, resolved.isMuxed ? "muxed" : "adaptive", resolved.height)
                // Verbose probe: the exact video host, whether an audio sidecar rides along, and the UA the
                // player MUST replay both legs with. If a reproduce shows this UA but libmpv still 403s, the
                // failure is a stale client identity (refresh the ladder), not a header-wiring bug.
                NSLog("[yt-probe] videoHost=%@ sidecar=%@ requiredUA=%@",
                      resolved.videoURL.host ?? "?", resolved.audioURL == nil ? "none" : (resolved.audioURL!.host ?? "?"),
                      googlevideoUserAgent)
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
            ua: googlevideoUserAgent,   // the exact UA googlevideo binds the returned URLs to; see the constant above
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
        /// A YouTube multi-language audio track descriptor, present on each audio adaptiveFormat when the video
        /// ships more than one audio language. `id` is like "en.4" / "en-US.4" / "hi.3" (base ISO code before the
        /// first '.'/'-'); `displayName` is human-readable ("English original", "Hindi"); `audioIsDefault` marks
        /// the track YouTube would auto-select. Absent on single-audio videos.
        struct AudioTrack: Decodable {
            let displayName: String?
            let id: String?
            let audioIsDefault: Bool?
        }
        struct Format: Decodable {
            let itag: Int?
            let url: String?
            let mimeType: String?
            let signatureCipher: String?
            let cipher: String?
            let height: Int?
            let bitrate: Int?
            let audioTrack: AudioTrack?
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

    /// Apply the resolution policy to one client's streamingData, honoring the user's preferred AUDIO language.
    ///
    ///   * wantMuxedOnly -> best muxed only (nil when none). A caller that literally cannot take a sidecar
    ///     (a pure AVPlayer context) sets this; NO shipping trailer/ambient caller does, they all play
    ///     through mpv, which mounts the audio leg as `--audio-file`.
    ///   * otherwise -> best muxed (itag 22 then 18) if one exists, ELSE the adaptive video+audio pair.
    ///
    /// WRONG-LANGUAGE FIX: modern YouTube trailers increasingly ship MULTIPLE audio languages as separate
    /// audio adaptiveFormats (each tagged with an `audioTrack`). The old audio pick took the single highest
    /// BITRATE audio/mp4 across ALL languages, so a foreign dub could win over English even with the app set to
    /// English. `pickAudio` now selects the track whose `audioTrack` language matches `preferredLanguages`
    /// (in priority order), falling back to YouTube's default/original track, then to highest bitrate for a
    /// genuinely single-audio video (unchanged behavior there, so single-audio trailers are untouched).
    ///
    /// A muxed progressive stream (itag 22/18) carries ONE embedded audio track whose language we cannot
    /// re-select. So when the client exposes MORE THAN ONE audio language AND one of them matches the user's
    /// preference, the adaptive pair (which lets us pick that exact language) is taken IN PLACE OF the muxed
    /// default. When there is only a single audio language, the muxed-first policy is kept exactly as before.
    private static func pick(from streaming: PlayerResponse.StreamingData,
                             maxHeight: Int,
                             wantMuxedOnly: Bool,
                             preferredLanguages: [String]) -> Resolved? {
        let adaptive = streaming.adaptiveFormats ?? []
        let audioChoice = pickAudio(adaptive, preferredLanguages: preferredLanguages)
        let audioLangs = distinctAudioLanguages(adaptive)

        // Only override the muxed-first policy for a genuine MULTI-language trailer whose preferred language is
        // actually available adaptively: single-audio trailers keep the exact muxed-first path (no regression).
        let preferAdaptiveForLanguage = !wantMuxedOnly
            && (audioChoice?.matchedPreferred ?? false)
            && audioLangs.count > 1

        if !preferAdaptiveForLanguage, let muxed = pickMuxed(streaming.formats ?? []) {
            NSLog("[trailer] audio=muxed single-embedded-track h=%d availLangs=[%@] prefLangs=[%@]",
                  muxed.height, audioLangs.joined(separator: ","), preferredLanguages.joined(separator: ","))
            return Resolved(videoURL: muxed.url, audioURL: nil, height: muxed.height, isMuxed: true)
        }

        // Adaptive path (the modern-trailer norm on the IOS client): a video-only leg + the language-selected
        // audio leg, unless the caller cannot take a sidecar (wantMuxedOnly).
        if !wantMuxedOnly, let videoLeg = pickAdaptiveVideo(adaptive, maxHeight: maxHeight), let audio = audioChoice {
            NSLog("[trailer] audio=adaptive lang=%@ display=%@ matchedPref=%@ ytDefault=%@ availLangs=[%@] prefLangs=[%@] h=%d",
                  audio.lang ?? "und", audio.display ?? "?",
                  audio.matchedPreferred ? "Y" : "N", audio.isDefault ? "Y" : "N",
                  audioLangs.joined(separator: ","), preferredLanguages.joined(separator: ","), videoLeg.height)
            return Resolved(videoURL: videoLeg.url, audioURL: audio.url, height: videoLeg.height, isMuxed: false)
        }

        // Fallback: a muxed default we skipped above for a language override that then had no adaptive video leg.
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

    /// Base ISO-639-1 language code of an audio format's `audioTrack`, e.g. "en.4"/"en-US.4"/"hi.3" -> "en"/"hi".
    /// nil when the format has no `audioTrack` (a single-audio video) or an unusable id.
    private static func audioLanguageCode(_ f: PlayerResponse.Format) -> String? {
        guard let id = f.audioTrack?.id, !id.isEmpty else { return nil }
        let head = id.split(whereSeparator: { $0 == "." || $0 == "-" }).first.map(String.init) ?? id
        return head.isEmpty ? nil : head.lowercased()
    }

    /// Distinct audio-track languages exposed by the adaptive set (base ISO codes), used to detect a genuine
    /// multi-language trailer. Empty / single-element for the ordinary single-audio trailer.
    private static func distinctAudioLanguages(_ adaptive: [PlayerResponse.Format]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for f in adaptive where (f.mimeType?.hasPrefix("audio/mp4") ?? false) && plainURL(f) != nil {
            if let code = audioLanguageCode(f), seen.insert(code).inserted { out.append(code) }
        }
        return out
    }

    /// Best adaptive VIDEO leg under `maxHeight`. mp4/avc1 (H.264 for hardware decode) by highest height then
    /// highest bitrate; vp9 allowed only when no avc1 stream carries a plain url. Plain url required.
    private static func pickAdaptiveVideo(_ adaptive: [PlayerResponse.Format],
                                          maxHeight: Int) -> (url: URL, height: Int)? {
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
        return bestVideo(where: { $0.hasPrefix("video/mp4") && $0.contains("avc1") })
            ?? bestVideo(where: { $0.contains("vp9") || $0.contains("vp09") })
    }

    /// The chosen adaptive AUDIO leg plus what it is (for diagnostics + the muxed-override decision).
    private struct AudioChoice {
        let url: URL
        let lang: String?          // base ISO code of the picked track, nil for a single-audio video
        let display: String?       // YouTube's human-readable track name
        let matchedPreferred: Bool // the pick matched one of preferredLanguages (a genuine localized hit)
        let isDefault: Bool        // YouTube's own default/original track
    }

    /// Pick the audio/mp4 leg honoring `preferredLanguages`. Priority:
    ///   1. First preferred language (in order) that any audio track matches -> highest bitrate among that language.
    ///   2. Else YouTube's `audioIsDefault` track (the original) -> highest bitrate among it.
    ///   3. Else highest bitrate overall (the single-audio path: identical to the previous behavior).
    /// Only audio/mp4 formats with a plain url are considered; nil when none exist.
    private static func pickAudio(_ adaptive: [PlayerResponse.Format],
                                  preferredLanguages: [String]) -> AudioChoice? {
        // (format, url) audio candidates with a plain url.
        let candidates: [(f: PlayerResponse.Format, url: URL)] = adaptive.compactMap { f in
            guard (f.mimeType?.hasPrefix("audio/mp4") ?? false), let url = plainURL(f) else { return nil }
            return (f, url)
        }
        guard !candidates.isEmpty else { return nil }

        func highestBitrate(_ list: [(f: PlayerResponse.Format, url: URL)]) -> (f: PlayerResponse.Format, url: URL)? {
            list.max { ($0.f.bitrate ?? 0) < ($1.f.bitrate ?? 0) }
        }

        // 1. Preferred-language match, in priority order.
        for code in preferredLanguages where !code.isEmpty {
            let want = code.lowercased()
            let matches = candidates.filter { audioLanguageCode($0.f) == want }
            if let pick = highestBitrate(matches) {
                return AudioChoice(url: pick.url, lang: audioLanguageCode(pick.f),
                                   display: pick.f.audioTrack?.displayName, matchedPreferred: true,
                                   isDefault: pick.f.audioTrack?.audioIsDefault ?? false)
            }
        }

        // 2. YouTube's default/original track.
        let defaults = candidates.filter { $0.f.audioTrack?.audioIsDefault == true }
        if let pick = highestBitrate(defaults) {
            return AudioChoice(url: pick.url, lang: audioLanguageCode(pick.f),
                               display: pick.f.audioTrack?.displayName, matchedPreferred: false, isDefault: true)
        }

        // 3. Highest bitrate overall (single-audio video, or a multi-audio video with no default flag).
        guard let pick = highestBitrate(candidates) else { return nil }
        return AudioChoice(url: pick.url, lang: audioLanguageCode(pick.f),
                           display: pick.f.audioTrack?.displayName, matchedPreferred: false,
                           isDefault: pick.f.audioTrack?.audioIsDefault ?? false)
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
