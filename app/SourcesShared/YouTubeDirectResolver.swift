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

    // MARK: - V2 feature flag

    /// Feature flag for the V2 resolver hardening (ANDROID_VR rung 0, per-URL UA lockstep, watch-page config,
    /// mn= CDN probe, HLS-master fallback). Default OFF: with the flag off every code path below behaves
    /// exactly like the pre-V2 resolver (same ladder, same requests, same picks, same UA constant).
    static let v2FlagKey = "trailerClientResolverV2"
    static var isV2Enabled: Bool { UserDefaults.standard.bool(forKey: v2FlagKey) }

    // MARK: - Public contract

    /// A successful resolve. `videoURL` is either a muxed (audio included) progressive mp4 OR a video-only
    /// adaptive stream; `audioURL` is non-nil ONLY in the adaptive case (feed it to mpv as `--audio-file`).
    ///
    /// `requiredUserAgent` is the UA of the InnerTube client that MINTED these URLs: googlevideo binds each
    /// issued URL to that client, so BOTH legs must be replayed with exactly this UA (a mismatched UA 403s on
    /// either leg). Defaults to the IOS-ladder constant so every pre-V2 construction/caller compiles and
    /// behaves unchanged; the V2 path sets it per successful rung.
    ///
    /// `isManifest` marks the V2 HLS-master fallback: `videoURL` is then an adaptive manifest (not a bare
    /// media URL), `audioURL` is nil, and the player must open it DIRECTLY in libmpv (never the range-proxy,
    /// never AVPlayer). Always false on the pre-V2 paths.
    struct Resolved {
        let videoURL: URL      // muxed (audio included) OR video-only adaptive OR (V2) an HLS master manifest
        let audioURL: URL?     // non-nil ONLY when videoURL is video-only (mpv --audio-file sidecar)
        let height: Int
        let isMuxed: Bool
        let requiredUserAgent: String
        let isManifest: Bool

        init(videoURL: URL, audioURL: URL?, height: Int, isMuxed: Bool,
             requiredUserAgent: String = YouTubeDirectResolver.googlevideoUserAgent,
             isManifest: Bool = false) {
            self.videoURL = videoURL
            self.audioURL = audioURL
            self.height = height
            self.isMuxed = isMuxed
            self.requiredUserAgent = requiredUserAgent
            self.isManifest = isManifest
        }
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

    /// The UA a returned googlevideo URL must be replayed with. On the pre-V2 paths this is always the IOS
    /// constant above (byte-identical behavior); the V2 path RECORDS the minting client's UA per returned URL
    /// (video and audio leg alike) so an ANDROID_VR-minted URL is never replayed with the IOS UA (googlevideo
    /// 403s the mismatch on BOTH legs). Consumers: MPVMetalViewController's googlevideo UA force-set and
    /// VXTrailerProxy's upstream window fetches. Unknown URL -> the IOS constant (exactly today's behavior).
    static func requiredUserAgent(for url: URL) -> String {
        uaRegistry.lookup(url) ?? googlevideoUserAgent
    }

    /// True for an adaptive-manifest URL (HLS master `.m3u8` / DASH `.mpd`, or googlevideo's
    /// /api/manifest/hls_variant form). The V2 HLS-master fallback is the only resolver path that returns one;
    /// the player uses this to open the manifest directly in libmpv instead of the range-proxy (which can only
    /// serve bare `clen`/`&range=` media URLs).
    static func isManifestURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || ext == "mpd" { return true }
        let s = url.absoluteString.lowercased()
        return s.contains(".m3u8") || s.contains("/hls_variant/") || s.contains("/hls_playlist/")
    }

    /// URL -> minting-client UA map behind a lock (sync-readable from the proxy's DispatchQueue and the player
    /// thread; the async resolver writes it). Only the V2 path records entries, so with the flag off every
    /// lookup falls back to the IOS constant. Entries are pruned on the googlevideo URL lifetime (~6h, longer
    /// than the 2h resolve cache) so a cache hit always still has its UA; a small cap bounds the map.
    private final class UARegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (ua: String, stored: Date)] = [:]
        private let ttl: TimeInterval = 6 * 60 * 60
        private let cap = 128

        func record(_ ua: String, for urls: [URL?]) {
            lock.lock(); defer { lock.unlock() }
            let now = Date()
            entries = entries.filter { now.timeIntervalSince($0.value.stored) < ttl }
            if entries.count >= cap { entries.removeAll() }   // tiny map in practice; a hard reset is fine
            for url in urls {
                guard let url else { continue }
                entries[url.absoluteString] = (ua, now)
            }
        }

        func lookup(_ url: URL) -> String? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entries[url.absoluteString], Date().timeIntervalSince(e.stored) < ttl else { return nil }
            return e.ua
        }
    }

    private static let uaRegistry = UARegistry()

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
        // NOT get served a stale wrong-language pick from the cache. The V2 path suffixes the key so toggling
        // the flag mid-session can never serve a V2 manifest entry to the V1 path (or vice versa); with the
        // flag off the key is byte-identical to the pre-V2 one.
        let v2 = isV2Enabled
        let cacheKey = "\(videoID)|\(maxHeight)|\(wantMuxedOnly ? 1 : 0)|\(prefLangs.joined(separator: "-"))"
            + (v2 ? "|v2" : "")
        if let hit = await cache.get(cacheKey) {
            NSLog("[yt-direct] id=%@ client=%@ %@ h=%d", videoID, "cache", hit.isMuxed ? "muxed" : "adaptive", hit.height)
            return hit
        }

        if v2 {
            return await resolveV2(videoID: videoID, maxHeight: maxHeight, wantMuxedOnly: wantMuxedOnly,
                                   prefLangs: prefLangs, cacheKey: cacheKey)
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

    // MARK: - V2 rung 0: ANDROID_VR client identity
    // The most durable PO-token-free InnerTube client today (Quest headsets have no PO-token pipeline, so
    // YouTube keeps serving it plain URLs incl. free 1080p adaptive). Identity copied from yt-dlp
    // INNERTUBE_CLIENTS. TODO: move to remote config blob (identities rot)
    private static let androidVRClientVersion = "1.56.21"
    private static let androidVRClientNameNum = 28
    private static let androidVRDeviceModel = "Quest 3"
    private static let androidVRUserAgent =
        "com.google.android.apps.youtube.vr.oculus/1.56.21 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"

    private static let androidVRClient = Client(
        name: "ANDROID_VR",
        ua: androidVRUserAgent,
        clientNameNum: androidVRClientNameNum,
        clientVersion: androidVRClientVersion,
        context: [
            "clientName": "ANDROID_VR",
            "clientVersion": androidVRClientVersion,
            "deviceMake": "Oculus",
            "deviceModel": androidVRDeviceModel,
            "androidSdkVersion": 32,
            "osName": "Android",
            "osVersion": "12L",
            "userAgent": androidVRUserAgent,
            "hl": "en",
            "gl": "US",
        ]
    )

    /// The V2 ladder: ANDROID_VR prepended as rung 0, then the EXACT existing ladder untouched (rungs 1-3).
    /// Only `resolveV2` walks this; the flag-off path keeps walking `clients`.
    private static var v2Clients: [Client] { [androidVRClient] + clients }

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
            /// The HLS master manifest, when the client exposes one (the V2 fallback lane). Ignored by the
            /// pre-V2 picks, so decoding it changes nothing with the flag off.
            let hlsManifestUrl: String?
        }
        let playabilityStatus: PlayabilityStatus?
        let streamingData: StreamingData?
    }

    /// The outcome of one /player call, distinguished so the V2 path can react to LOGIN_REQUIRED (invalidate
    /// the watch-page config and retry once). The pre-V2 wrapper collapses everything but `.playable` to nil,
    /// exactly the old behavior.
    private enum PlayerFetchOutcome {
        case playable(PlayerResponse.StreamingData?)
        case loginRequired
        case miss
    }

    /// POST the InnerTube /player call for one client. Returns the streamingData on a playable answer, nil on
    /// any error, non-OK playability, or an empty response. Never throws. (Pre-V2 signature, kept verbatim:
    /// same key, no visitor header, LOGIN_REQUIRED treated as a plain miss.)
    private static func fetchStreamingData(videoID: String, client: Client) async -> PlayerResponse.StreamingData? {
        if case .playable(let streaming) = await fetchPlayer(videoID: videoID, client: client,
                                                            apiKey: innertubeKey, visitorData: nil) {
            return streaming
        }
        return nil
    }

    /// The one /player request builder + sender both ladders share. `apiKey` defaults to the hardcoded web key
    /// (the pre-V2 request, byte for byte); the V2 path substitutes the watch-page-scraped key and adds the
    /// `x-goog-visitor-id` header when a VISITOR_DATA was scraped (soft best-effort; nil sends no header).
    private static func fetchPlayer(videoID: String, client: Client,
                                    apiKey: String, visitorData: String?) async -> PlayerFetchOutcome {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(apiKey)&prettyPrint=false") else {
            return .miss
        }
        var req = URLRequest(url: url, timeoutInterval: clientTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(client.ua, forHTTPHeaderField: "user-agent")
        // The numeric client name header some InnerTube edges expect; harmless when ignored.
        req.setValue(String(client.clientNameNum), forHTTPHeaderField: "x-youtube-client-name")
        req.setValue(client.clientVersion, forHTTPHeaderField: "x-youtube-client-version")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "origin")
        if let visitorData, !visitorData.isEmpty {
            req.setValue(visitorData, forHTTPHeaderField: "x-goog-visitor-id")
        }

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
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .miss }
        req.httpBody = data

        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return .miss }
            guard let decoded = try? JSONDecoder().decode(PlayerResponse.self, from: respData) else { return .miss }
            let status = decoded.playabilityStatus?.status
            if status == "LOGIN_REQUIRED" { return .loginRequired }
            guard status == "OK" else { return .miss }
            return .playable(decoded.streamingData)
        } catch {
            return .miss
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

    // MARK: - V2 resolve (trailerClientResolverV2)

    /// The hardened ladder walk. Differences from the flag-off path, in order of application:
    ///   1. ANDROID_VR as rung 0 (then the exact existing IOS/ANDROID/TVHTML5 rungs untouched).
    ///   2. Watch-page config: the scraped INNERTUBE_API_KEY + VISITOR_DATA ride every /player call
    ///      (soft best-effort; the hardcoded key is the fallback). An all-rungs LOGIN_REQUIRED pass
    ///      invalidates the config and retries the ladder ONCE with a fresh scrape.
    ///   3. UA lockstep: the winning rung's UA is carried in `Resolved.requiredUserAgent` AND recorded in the
    ///      URL->UA registry the player/proxy consult, so URL and minting UA always travel together.
    ///   4. mn= CDN probe: each returned googlevideo leg is raced across its mirror hosts and the first
    ///      reachable (200/206) host wins; a leg with NO reachable node falls to the HLS master.
    ///   5. HLS-master fallback: when format selection fails (or the probe kills every node), the client's
    ///      `hlsManifestUrl` is returned as an `isManifest` Resolved (audioURL nil, plays directly in libmpv).
    /// Selection itself (pickMuxed / pickAdaptiveVideo / pickAudio incl. the preferred-language audio fix) is
    /// THE SAME `pick` the flag-off path uses; V2 only changes which clients feed it and what happens after.
    private static func resolveV2(videoID: String, maxHeight: Int, wantMuxedOnly: Bool,
                                  prefLangs: [String], cacheKey: String) async -> Resolved? {
        var config = await watchConfigStore.config(videoID: videoID, forceRefresh: false)

        for pass in 0..<2 {
            var sawLoginRequired = false
            // The first usable manifest seen while walking the ladder, kept as the post-ladder fallback when
            // no rung yields a direct pick. A muxed-only caller cannot take a manifest (no mpv path), so the
            // lane is gated off for it.
            var manifestFallback: Resolved?

            for client in v2Clients {
                let outcome = await fetchPlayer(videoID: videoID, client: client,
                                                apiKey: config?.apiKey ?? innertubeKey,
                                                visitorData: config?.visitorData)
                let streaming: PlayerResponse.StreamingData?
                switch outcome {
                case .loginRequired:
                    sawLoginRequired = true
                    continue
                case .miss:
                    continue
                case .playable(let s):
                    streaming = s
                }
                guard let streaming else { continue }

                let manifest = manifestURL(streaming.hlsManifestUrl)

                guard let picked = pick(from: streaming, maxHeight: maxHeight, wantMuxedOnly: wantMuxedOnly,
                                        preferredLanguages: prefLangs) else {
                    // Adaptive/muxed selection failed for this rung: remember its manifest and keep walking.
                    if manifestFallback == nil, !wantMuxedOnly, let manifest {
                        manifestFallback = Resolved(videoURL: manifest, audioURL: nil, height: 0, isMuxed: false,
                                                    requiredUserAgent: client.ua, isManifest: true)
                    }
                    continue
                }

                // mn= CDN reachability probe: swap each leg to its first reachable mirror. A leg with no
                // reachable node at all -> this rung's manifest (per-node 403s defeat the direct pair).
                if let legs = await probeLegs(video: picked.videoURL, audio: picked.audioURL, userAgent: client.ua) {
                    let resolved = Resolved(videoURL: legs.video, audioURL: legs.audio, height: picked.height,
                                            isMuxed: picked.isMuxed, requiredUserAgent: client.ua, isManifest: false)
                    return await finishV2(resolved, cacheKey: cacheKey, videoID: videoID, clientName: client.name)
                }
                if !wantMuxedOnly, let manifest {
                    let resolved = Resolved(videoURL: manifest, audioURL: nil, height: 0, isMuxed: false,
                                            requiredUserAgent: client.ua, isManifest: true)
                    return await finishV2(resolved, cacheKey: cacheKey, videoID: videoID, clientName: client.name)
                }
            }

            if let manifestFallback {
                return await finishV2(manifestFallback, cacheKey: cacheKey, videoID: videoID, clientName: "manifest")
            }
            if sawLoginRequired, pass == 0 {
                // Every playable answer was LOGIN_REQUIRED: the visitor/config went stale. Invalidate, force a
                // fresh watch-page scrape, and retry the ladder exactly once.
                await watchConfigStore.invalidate()
                config = await watchConfigStore.config(videoID: videoID, forceRefresh: true)
                continue
            }
            break
        }

        NSLog("[yt-direct] id=%@ client=%@ %@ h=%d", videoID, "-", "MISS(v2)", 0)
        return nil
    }

    /// Cache + register + log one V2 win. The registry entry is what keeps URL and minting UA in lockstep for
    /// the player/proxy (including cache hits: the registry TTL outlives the resolve cache TTL).
    private static func finishV2(_ resolved: Resolved, cacheKey: String, videoID: String,
                                 clientName: String) async -> Resolved {
        uaRegistry.record(resolved.requiredUserAgent, for: [resolved.videoURL, resolved.audioURL])
        await cache.set(cacheKey, resolved)
        let kind = resolved.isManifest ? "manifest" : (resolved.isMuxed ? "muxed" : "adaptive")
        NSLog("[yt-direct] id=%@ client=%@ %@ h=%d", videoID, clientName, kind, resolved.height)
        NSLog("[yt-probe] videoHost=%@ sidecar=%@ requiredUA=%@",
              resolved.videoURL.host ?? "?",
              resolved.audioURL == nil ? "none" : (resolved.audioURL!.host ?? "?"),
              resolved.requiredUserAgent)
        return resolved
    }

    /// Parse + sanity-gate a client's `hlsManifestUrl` (same googlevideo host gate as `plainURL`).
    private static func manifestURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw),
              let host = url.host, host.contains("googlevideo") else { return nil }
        return url
    }

    // MARK: - V2 watch-page config (INNERTUBE_API_KEY + VISITOR_DATA)

    /// Watch-page config cache TTL. The scraped key/visitor pair is stable for hours; ~3h keeps the scrape to
    /// a handful per session while staying comfortably fresh.
    private static let watchConfigTTL: TimeInterval = 3 * 60 * 60

    /// A desktop browser UA for the watch-page GET (the page serves its config to any browser UA).
    /// TODO: move to remote config blob (identities rot)
    private static let watchPageUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private struct WatchConfig {
        let apiKey: String?        // scraped INNERTUBE_API_KEY (nil -> caller falls back to the hardcoded key)
        let visitorData: String?   // scraped VISITOR_DATA for the x-goog-visitor-id header (nil -> no header)
        let fetched: Date
    }

    /// Actor-guarded single-slot cache for the scraped watch-page config. Soft best-effort throughout: any
    /// scrape failure returns the stale value (or nil), and the resolver then just uses the hardcoded key with
    /// no visitor header, i.e. degrades to the plain V2 request rather than failing the resolve.
    private actor WatchConfigStore {
        private var cached: WatchConfig?

        func invalidate() { cached = nil }

        func config(videoID: String, forceRefresh: Bool) async -> WatchConfig? {
            if !forceRefresh, let cached,
               Date().timeIntervalSince(cached.fetched) < YouTubeDirectResolver.watchConfigTTL {
                return cached
            }
            // The id is interpolated into a URL, so gate it to the YouTube id alphabet (defense in depth; every
            // caller already passes a real video id). An off-alphabet id just skips the scrape.
            guard videoID.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil,
                  let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)&bpctr=9999999999&has_verified=1")
            else { return cached }

            var req = URLRequest(url: url, timeoutInterval: YouTubeDirectResolver.clientTimeout)
            req.setValue(YouTubeDirectResolver.watchPageUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return cached }

            // The scraped key rides a URL query; clamp it to the key alphabet so a mangled scrape can never
            // break the /player URL (fall back to the hardcoded key instead).
            var key = Self.firstMatch(#""INNERTUBE_API_KEY":"([^"]+)""#, in: html)
            if let k = key, k.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil { key = nil }
            let visitor = Self.firstMatch(#""VISITOR_DATA":"([^"]+)""#, in: html)

            guard key != nil || visitor != nil else { return cached }
            let fresh = WatchConfig(apiKey: key, visitorData: visitor, fetched: Date())
            cached = fresh
            NSLog("[yt-direct] watch-config refreshed key=%@ visitor=%@",
                  key == nil ? "fallback" : "scraped", visitor == nil ? "none" : "scraped")
            return fresh
        }

        private static func firstMatch(_ pattern: String, in text: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            let value = String(text[r])
            return value.isEmpty ? nil : value
        }
    }

    private static let watchConfigStore = WatchConfigStore()

    // MARK: - V2 mn= CDN reachability probe

    /// Per-candidate probe timeout, and the cap on how many mirror hosts one leg races.
    private static let probeTimeout: TimeInterval = 2
    private static let maxProbeCandidates = 6

    /// Dedicated probe session: a hard resource cap reaps the connection of a node that ignores the 1-byte
    /// Range and answers 200 with a full body (the response header alone decides the probe; the body is
    /// abandoned), so no probe can leak a long-lived transfer.
    private static let probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = probeTimeout
        cfg.timeoutIntervalForResource = probeTimeout * 2
        return URLSession(configuration: cfg)
    }()

    /// Probe both legs of a pick in parallel. Returns the (possibly host-swapped) legs, or nil when any leg
    /// has NO reachable node (the caller then falls to the HLS master).
    private static func probeLegs(video: URL, audio: URL?,
                                  userAgent: String) async -> (video: URL, audio: URL?)? {
        if let audio {
            async let v = reachableHost(for: video, userAgent: userAgent)
            async let a = reachableHost(for: audio, userAgent: userAgent)
            guard let vWin = await v, let aWin = await a else { return nil }
            return (vWin, aWin)
        }
        guard let vWin = await reachableHost(for: video, userAgent: userAgent) else { return nil }
        return (vWin, nil)
    }

    /// Race `Range: bytes=0-0` GETs across the leg's mirror hosts (the URL's own host first, then the
    /// `mn=`/`fvip` synthesized `rrN---snXXXX` alternates) inside a structured task group. The FIRST 200/206
    /// wins and `cancelAll()` tears the losing probes down (the async URLSession calls honor task
    /// cancellation), so no loser connection outlives the race. nil = every node refused or timed out.
    private static func reachableHost(for url: URL, userAgent: String) async -> URL? {
        let candidates = alternateHostURLs(for: url)
        return await withTaskGroup(of: URL?.self) { group in
            for candidate in candidates {
                group.addTask {
                    var req = URLRequest(url: candidate, timeoutInterval: probeTimeout)
                    req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                    do {
                        // bytes(for:) returns at the response HEADER, so the status decides immediately even
                        // when a node ships a full 200 body; the abandoned body is reaped by the session's
                        // resource timeout.
                        let (_, resp) = try await probeSession.bytes(for: req)
                        if let http = resp as? HTTPURLResponse,
                           http.statusCode == 200 || http.statusCode == 206 {
                            return candidate
                        }
                    } catch {}
                    return nil
                }
            }
            var winner: URL?
            for await result in group {
                if let result {
                    winner = result
                    group.cancelAll()   // first win cancels the losers; the group then drains structured
                    break
                }
            }
            if winner == nil {
                NSLog("[yt-probe] no reachable node for host=%@ (%d candidates)", url.host ?? "?", candidates.count)
            }
            return winner
        }
    }

    /// The original URL plus its mirror-host alternates. googlevideo hosts read `rrN---snXXXX.googlevideo.com`
    /// and every issued URL carries `mn=` (a comma list of mirror `snXXXX` names) and usually `fvip` (an
    /// alternate `rrN` ordinal); a mirror host serves the SAME signed URL, which is what defeats a per-node
    /// 403. Fail-soft: any unexpected shape returns just the original URL.
    private static func alternateHostURLs(for url: URL) -> [URL] {
        guard let host = url.host, host.contains("googlevideo"),
              let sep = host.range(of: "---"),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [url] }
        let origPrefix = String(host[host.startIndex..<sep.lowerBound])      // "rr4"
        let tail = String(host[sep.upperBound...])                           // "sn-xxxx.googlevideo.com"
        guard let dot = tail.firstIndex(of: ".") else { return [url] }
        let domainRest = String(tail[dot...])                                // ".googlevideo.com"

        let items = comps.queryItems ?? []
        let mnList = (items.first(where: { $0.name == "mn" })?.value ?? "")
            .split(separator: ",").map(String.init).filter { !$0.isEmpty }
        var prefixes = [origPrefix]
        if let fvip = items.first(where: { $0.name == "fvip" })?.value, !fvip.isEmpty,
           fvip.range(of: "^[0-9]+$", options: .regularExpression) != nil, "rr\(fvip)" != origPrefix {
            prefixes.append("rr\(fvip)")
        }

        var out = [url]
        var seen: Set<String> = [host]
        for prefix in prefixes {
            for mn in mnList {
                let candidateHost = "\(prefix)---\(mn)\(domainRest)"
                guard seen.insert(candidateHost).inserted else { continue }
                var c = comps
                c.host = candidateHost
                if let u = c.url { out.append(u) }
            }
        }
        return Array(out.prefix(maxProbeCandidates))
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
