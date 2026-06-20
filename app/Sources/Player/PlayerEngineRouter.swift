import Foundation

/// Decides which engine plays a given stream: the AVFoundation engine (`AVPlayerEngineController`) for Dolby
/// Vision and HTTP/HLS, or the libmpv engine (`MPVMetalViewController`) for torrents and everything else.
///
/// IMPORTANT: evaluate on the RAW (un-proxied) stream URL. `StremioServer.proxiedURL` rewrites the host to
/// 127.0.0.1, which would make every proxied stream look like a loopback torrent and never reach AVPlayer.
///
/// Pure logic, no platform types, so it compiles on every target. WIRED on all three Apple platforms, each
/// passing the real `isDolbyVision` from the launching stream's quality text so DV in an AVPlayer-playable
/// container (MP4/MOV/M4V) auto-routes to a DV-native AVPlayer surface for true Dolby Vision:
///   - iOS:   `PlayerScreen.useAVPlayerEngine` -> the full-chrome `AVPlayerEngineView`.
///   - tvOS:  `RootTabView` -> `TVHLSPlayer` (bare `AVPlayerViewController`).
///   - macOS: `PlayerScreen` -> `HLSPlayerView`'s `MacVideoPlayer` (SwiftUI `VideoPlayer`).
/// HLS also routes to AVPlayer on iOS/tvOS (rule 4); macOS keeps HLS on libmpv (its node server transcodes it)
/// and routes only DV. Torrents and the override are handled before the platform split.
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

        // (3) Dolby Vision -> AVPlayer for true DV passthrough (libmpv/MoltenVK only tone-maps DV to SDR),
        // but ONLY for a container AVFoundation can demux (MP4/MOV/M4V or HLS). DV in an MKV must stay on
        // libmpv: AVFoundation has no Matroska demuxer, so routing it to AVPlayer would just fail over to
        // libmpv anyway (tone-mapped). The AVPlayer->libmpv .failed fallback in the chrome is the backstop.
        if isDolbyVision, isAVPlayerContainer(url) { return .avfoundation }

        #if !os(macOS)
        // (4) Remote HLS -> AVPlayer for native adaptive bitrate, AirPlay, and PiP. macOS keeps HLS on libmpv
        // (its out-of-process node server transcodes HLS), so this rule is iOS/tvOS only; macOS routes only
        // Dolby Vision (rule 3) to AVPlayer.
        if isHLS(url) { return .avfoundation }
        #endif

        // (5) Direct / debrid non-HLS containers stay on libmpv (it demuxes arbitrary MP4/MKV/HEVC and
        // applies per-stream request headers).
        return .mpv
    }

    /// True for an adaptive HLS playlist URL. Mirrors the rule `HLSPlayerView.handles` uses today.
    static func isHLS(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8" || url.absoluteString.lowercased().contains(".m3u8")
    }

    /// Containers AVFoundation can demux for the DV path. AVPlayer has no Matroska demuxer, so DV in an
    /// `.mkv` stays on libmpv; an unknown/extensionless URL also stays on libmpv (safe default). HLS is a
    /// container AVPlayer handles natively. Used by rule (3) so the DV flip only fires when it can succeed.
    static func isAVPlayerContainer(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mp4" || ext == "m4v" || ext == "mov" || isHLS(url)
    }
}
