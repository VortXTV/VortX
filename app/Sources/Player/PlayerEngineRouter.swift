import Foundation

/// Decides which engine plays a given stream: the AVFoundation engine (`AVPlayerEngineController`) for Dolby
/// Vision and HTTP/HLS, or the libmpv engine (`MPVMetalViewController`) for torrents and everything else.
///
/// IMPORTANT: evaluate on the RAW (un-proxied) stream URL. `StremioServer.proxiedURL` rewrites the host to
/// 127.0.0.1, which would make every proxied stream look like a loopback torrent and never reach AVPlayer.
///
/// Pure logic, no platform types, so it compiles on every target. Not yet wired into the player branch
/// points (PlayerScreen / RootTabView) -- that is the next step; in `auto` with no DV hint it returns the
/// same decision `HLSPlayerView.handles()` makes today, so wiring it is behavior-preserving.
enum PlayerEngineRouter {
    enum Engine: String { case mpv, avfoundation }

    /// User override, persisted in Settings. `auto` applies the rules below; `mpv` forces libmpv for every
    /// non-torrent (an escape hatch for a stream AVPlayer mishandles); `avfoundation` forces AVPlayer for any
    /// remote URL (advanced / testing).
    enum Override: String, CaseIterable {
        case auto, mpv, avfoundation
        var label: String {
            switch self {
            case .auto:         return "Auto"
            case .mpv:          return "Always libmpv"
            case .avfoundation: return "Prefer AVPlayer (HLS / DV)"
            }
        }
    }

    static let overrideKey = "stremiox.playerEngine"
    static var currentOverride: Override {
        Override(rawValue: UserDefaults.standard.string(forKey: overrideKey) ?? "") ?? .auto
    }

    /// Pick the engine for a stream.
    /// - Parameters:
    ///   - url: the RAW stream URL (before any StremioServer proxy rewrite).
    ///   - isTorrent: the stream comes from the in-process streaming server (a loopback URL).
    ///   - isDolbyVision: StreamRanking flagged the stream Dolby Vision at selection time. This is a
    ///     heuristic text parse (the only DV signal available pre-play) and cannot tell Profile 5/8 from the
    ///     dual-layer Profile 7 that AVPlayer cannot decode; routing all DV to AVPlayer is safe because the
    ///     wiring step adds an AVPlayer -> libmpv fallback on a load failure.
    ///   - override: the user setting (defaults to the persisted value).
    static func engine(for url: URL,
                       isTorrent: Bool,
                       isDolbyVision: Bool,
                       override: Override = currentOverride) -> Engine {
        #if os(macOS)
        // macOS stays on libmpv in auto: its out-of-process node server transcodes HLS, and MPVKit cannot
        // link Catalyst, so there is no AVKit player surface yet. The override still lets an advanced user
        // force AVPlayer once that surface exists.
        if override == .auto { return .mpv }
        #endif

        // (1) Torrents always play on libmpv: AVPlayer cannot replay the loopback server URL or run the
        // torrent warm-up. Belt and suspenders: trust the flag AND the loopback host.
        let host = (url.host ?? "").lowercased()
        if isTorrent || host == "127.0.0.1" || host == "localhost" { return .mpv }

        // (2) Explicit user override wins for non-torrents.
        switch override {
        case .mpv:          return .mpv
        case .avfoundation: return .avfoundation
        case .auto:         break
        }

        // (3) Dolby Vision -> AVPlayer for true DV passthrough (libmpv/MoltenVK only tone-maps DV to SDR).
        if isDolbyVision { return .avfoundation }

        // (4) Remote HLS -> AVPlayer for native adaptive bitrate, AirPlay, and PiP.
        if isHLS(url) { return .avfoundation }

        // (5) Direct / debrid non-HLS containers stay on libmpv (it demuxes arbitrary MP4/MKV/HEVC and
        // applies per-stream request headers).
        return .mpv
    }

    /// True for an adaptive HLS playlist URL. Mirrors the rule `HLSPlayerView.handles` uses today.
    static func isHLS(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8" || url.absoluteString.lowercased().contains(".m3u8")
    }
}
