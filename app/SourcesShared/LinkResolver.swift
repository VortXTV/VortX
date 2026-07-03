import Foundation
import os

/// What kind of stream a pasted link points at, from pure string/URL inspection (no network).
///
/// This is the first step of the 0.3.9 link resolver (design: `vortx-yt-twitch-resolver-design.md`,
/// Phase 1 = Twitch in-app, no backend). Detection is conservative: only a recognised live Twitch
/// channel, a YouTube watch/channel host, or a plain http(s) media URL are classified; anything else
/// is `.unsupported` so the caller can fall back to its existing behaviour rather than guess wrong.
enum StreamLinkKind: Equatable {
    /// A live Twitch channel (`twitch.tv/<channel>`). Resolves to an HLS `.m3u8` via `resolveTwitch`.
    case twitch(channel: String)
    /// A YouTube watch / live / short URL, carrying the extracted 11-char video id. Played through the
    /// remote resolver (`trailer.vortx.tv/yt/{id}`), the same path the Trailer button uses.
    case youtube(videoID: String)
    /// A plain http(s) media URL the existing direct-link path already handles.
    case direct(URL)
    /// Not something we can play directly. `note` is a short, user-facing reason (e.g. a Twitch
    /// clip/VOD that Phase 1 deliberately ignores), or nil for a generic "not a playable link".
    case unsupported(note: String?)

    static func unsupported() -> StreamLinkKind { .unsupported(note: nil) }
}

/// Detects + resolves pasted stream links. Phase 1 ships only the Twitch branch (stable public HLS,
/// no backend, works on every target). YouTube detection exists but resolution is deferred to a later
/// phase. All network work is best-effort and fail-soft (returns nil), never throwing into the caller.
enum LinkResolver {
    private static let log = Logger(subsystem: "com.stremiox.app", category: "linkresolver")

    /// Twitch's public web Client-ID, the same constant VLC and streamlink use for the unauthenticated
    /// playback-access-token flow. It is a public web client id (not a secret), so it ships in the app.
    /// Best-effort: Twitch can rotate it or change the token flow, in which case resolution fails soft
    /// and an app update restores it (or, later, a Worker resolver, per the design's Phase 2).
    private static let twitchClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

    // MARK: Detection

    /// Classify a pasted string. Pure parsing, no network. Unknown input falls to `.unsupported`.
    static func detect(_ raw: String) -> StreamLinkKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unsupported() }

        // Add a scheme to a bare host/path ("twitch.tv/foo") so URLComponents can read the host.
        let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let comps = URLComponents(string: normalized),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host?.lowercased() else {
            return .unsupported()
        }
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        if bareHost == "twitch.tv" || bareHost == "m.twitch.tv" {
            return detectTwitch(comps)
        }
        if bareHost == "clips.twitch.tv" {
            return .unsupported(note: "Twitch clips aren't supported yet, only live channels.")
        }
        if bareHost == "youtube.com" || bareHost == "m.youtube.com" || bareHost == "youtu.be" {
            if let id = youTubeVideoID(from: comps, bareHost: bareHost) { return .youtube(videoID: id) }
            return .unsupported(note: "That YouTube link has no playable video id.")
        }
        // A plain http(s) URL the existing direct-link path already plays.
        if let url = comps.url { return .direct(url) }
        return .unsupported()
    }

    /// Extract the 11-char YouTube video id from any common URL shape: `youtu.be/<id>`,
    /// `watch?v=<id>`, or `/embed|live|shorts|v/<id>`. Returns nil for a channel/playlist/other link.
    private static func youTubeVideoID(from comps: URLComponents, bareHost: String) -> String? {
        func valid(_ s: String?) -> String? {
            guard let s, s.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { return nil }
            return s
        }
        let segments = comps.path.split(separator: "/").map(String.init)
        if bareHost == "youtu.be" { return valid(segments.first) }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, let id = valid(v) { return id }
        if segments.count >= 2, ["embed", "live", "shorts", "v"].contains(segments[0].lowercased()) {
            return valid(segments[1])
        }
        return nil
    }

    /// A `twitch.tv` URL is a live channel only when the path is a single segment that is a valid
    /// channel login (`twitch.tv/<channel>`). Clips, VODs (`/videos/...`), and other sub-pages are
    /// `.unsupported` in Phase 1.
    private static func detectTwitch(_ comps: URLComponents) -> StreamLinkKind {
        let segments = comps.path.split(separator: "/").map(String.init)
        guard segments.count == 1, let channel = segments.first else {
            return .unsupported(note: "Only live Twitch channel links work for now (not clips or VODs).")
        }
        // Reserved sub-pages that look like a single segment but aren't channels.
        let reserved: Set<String> = ["videos", "directory", "settings", "subscriptions", "wallet", "downloads", "p", "u"]
        let login = channel.lowercased()
        guard !reserved.contains(login), isValidTwitchLogin(login) else {
            return .unsupported(note: "That doesn't look like a live Twitch channel link.")
        }
        return .twitch(channel: login)
    }

    /// Twitch logins are 3-25 chars of `[a-z0-9_]` (case-insensitive). Conservative so a random path
    /// segment isn't mistaken for a channel.
    private static func isValidTwitchLogin(_ login: String) -> Bool {
        guard (3...25).contains(login.count) else { return false }
        return login.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "_" }
    }

    // MARK: Twitch resolution

    /// Resolve a live Twitch channel to its HLS master playlist URL, streamlink-style: fetch a signed
    /// playback access token from Twitch's public GraphQL endpoint, then build the `usher.ttvnw.net`
    /// `.m3u8` URL from the token + signature. AVPlayer (iOS/tvOS) / libmpv (macOS) follow the master
    /// playlist from there, so the result drops straight onto the existing adaptive-HLS player path.
    ///
    /// Uses Twitch's public web Client-ID (the same approach as VLC / streamlink); it is best-effort
    /// and Twitch-dependent, so any error returns nil rather than throwing.
    static func resolveTwitch(channel: String) async -> URL? {
        guard let token = await fetchTwitchAccessToken(channel: channel) else {
            log.error("twitch resolve: no access token for \(channel, privacy: .public)")
            return nil
        }
        return buildUsherURL(channel: channel, token: token)
    }

    private struct TwitchAccessToken { let value: String; let signature: String }

    /// POST the `PlaybackAccessToken` persisted query to `gql.twitch.tv/gql` for a live channel.
    private static func fetchTwitchAccessToken(channel: String) async -> TwitchAccessToken? {
        guard let gqlURL = URL(string: "https://gql.twitch.tv/gql") else { return nil }

        // The well-known public persisted query for the stream/VOD playback access token. `isLive: true`
        // asks for the live channel token (Phase 1 ignores VODs). `playerType: "embed"` mirrors the
        // unauthenticated web embed flow streamlink uses.
        let body: [String: Any] = [
            "operationName": "PlaybackAccessToken",
            "extensions": [
                "persistedQuery": [
                    "version": 1,
                    "sha256Hash": "0828119ded1c13477966434e15800ff57ddacf13ba1911c129dc2200705b0712",
                ],
            ],
            "variables": [
                "isLive": true,
                "login": channel,
                "isVod": false,
                "vodID": "",
                "playerType": "embed",
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: gqlURL)
        request.httpMethod = "POST"
        request.setValue(twitchClientID, forHTTPHeaderField: "Client-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = data

        guard let (respData, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        // { data: { streamPlaybackAccessToken: { value, signature } } }
        struct Envelope: Decodable {
            struct DataField: Decodable {
                struct AccessToken: Decodable { let value: String; let signature: String }
                let streamPlaybackAccessToken: AccessToken?
            }
            let data: DataField?
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: respData),
              let tok = env.data?.streamPlaybackAccessToken,
              !tok.value.isEmpty, !tok.signature.isEmpty else {
            return nil
        }
        return TwitchAccessToken(value: tok.value, signature: tok.signature)
    }

    /// Build the `usher.ttvnw.net` HLS master playlist URL from a channel + access token. The query
    /// params mirror the standard streamlink/web set so Twitch returns the source + transcode renditions.
    private static func buildUsherURL(channel: String, token: TwitchAccessToken) -> URL? {
        var comps = URLComponents(string: "https://usher.ttvnw.net/api/channel/hls/\(channel).m3u8")
        comps?.queryItems = [
            URLQueryItem(name: "allow_source", value: "true"),
            URLQueryItem(name: "allow_audio_only", value: "true"),
            URLQueryItem(name: "fast_bread", value: "true"),
            URLQueryItem(name: "p", value: String(Int.random(in: 1_000_000...9_999_999))),
            URLQueryItem(name: "player", value: "twitchweb"),
            URLQueryItem(name: "playlist_include_framerate", value: "true"),
            URLQueryItem(name: "reassignments_supported", value: "true"),
            URLQueryItem(name: "sig", value: token.signature),
            URLQueryItem(name: "token", value: token.value),
            URLQueryItem(name: "supported_codecs", value: "avc1"),
            URLQueryItem(name: "cdm", value: "wv"),
        ]
        return comps?.url
    }
}
