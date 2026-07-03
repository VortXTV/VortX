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
///   - tvOS:  `TVPlayerView.playerSurface` -> the full-chrome `AVPlayerEngineView` (same chrome as libmpv).
///   - macOS: `PlayerScreen` -> the full-chrome `AVPlayerEngineView`.
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

    /// Opt-in flag for the DV-for-MKV in-process streaming remux (Phase 1). OFF by default: when disabled, DV
    /// in an MKV stays on libmpv (tone-mapped HDR10) exactly as before. When enabled, a Dolby Vision MKV from
    /// a non-torrent (debrid/direct) source is remuxed MKV -> fragmented-MP4 in-process and fed to AVPlayer for
    /// TRUE Dolby Vision. Torrents, loopback, HLS, and mp4/mov/m4v are unaffected (they route as they did).
    static let dvRemuxKey = "stremiox.dvRemux"
    /// Whether the DV-for-MKV remux lane is enabled for THIS session's display.
    ///
    /// Owner DV mandate (2026-07-02, HARD): "if there is Dolby Vision, play Dolby Vision" on every platform
    /// whose hardware/display can do it. So the resolution order is now:
    ///   1. If the user EXPLICITLY set `stremiox.dvRemux` (the Settings toggle), that value ALWAYS wins
    ///      (off = force libmpv tone-map even on a DV display; on = force the remux lane).
    ///   2. Else the RemoteConfig fleet default `features.dvRemux` when the owner has set it (a hard remote
    ///      false is a fleet kill-switch that still wins over the display default).
    ///   3. Else the BAKED default is ON when the display can actually present DV (`dvDisplayCapable`), so a
    ///      DV MKV takes the true-DV AVPlayer lane on DV-capable hardware and only tone-maps on hardware that
    ///      genuinely can't. The AVPlayer -> libmpv `.failed` demotion is always the backstop.
    /// - Parameter dvDisplayCapable: the caller's play-start display-capability read (`DVDisplaySupport`).
    static func dvRemuxEnabled(dvDisplayCapable: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: dvRemuxKey) != nil {
            return UserDefaults.standard.bool(forKey: dvRemuxKey)   // explicit user toggle always wins
        }
        // A remote value (true OR false) still overrides the display default so the owner keeps a fleet
        // kill-switch; only an ABSENT remote value falls through to the display-capability baked default.
        // RemoteConfig exposes only isFeatureOn(default:); probe both defaults to tell "set" from "absent":
        // if the two probes disagree the key is ABSENT (each returned its own fallback), so use the display
        // default; if they agree the key is PRESENT with that value, which wins as the fleet kill-switch.
        let snap = RemoteConfig.snapshot
        let onWhenAbsentTrue = snap.isFeatureOn("dvRemux", default: true)
        let onWhenAbsentFalse = snap.isFeatureOn("dvRemux", default: false)
        if onWhenAbsentTrue == onWhenAbsentFalse { return onWhenAbsentTrue }   // remote set explicitly
        return dvDisplayCapable   // remote absent -> baked default: on where DV can actually be shown (mandate)
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
    ///   - dvDisplayCapable: whether THIS display can present DV (`DVDisplaySupport.isCapable`). Gates the
    ///     DV-remux baked default so the owner mandate holds on every DV-capable Apple platform, macOS
    ///     included, and DV MKVs on a genuinely non-DV display still stay on libmpv (tone-mapped).
    static func engine(for url: URL,
                       isTorrent: Bool,
                       isDolbyVision: Bool,
                       override: Override = currentOverride,
                       dvDisplayCapable: Bool = false) -> Engine {
        // (1) Torrents always play on libmpv: AVPlayer cannot replay the loopback server URL or run the
        // torrent warm-up. Belt and suspenders: trust the flag AND the loopback host.
        let host = (url.host ?? "").lowercased()
        if isTorrent || host == "127.0.0.1" || host == "localhost" { return .mpv }

        // (1b) A COMPLETED offline HLS download is a local `.movpkg` bundle that ONLY AVPlayer can open
        // (libmpv has no reader for it), so it must route to AVPlayer even under an `.mpv` override. It is a
        // local file, so it can never be a torrent/loopback (already handled above). A `.movpkg` only exists on
        // iOS only (AVAssetDownloadURLSession is unavailable on tvOS and native macOS), so it never fires there.
        if url.isFileURL, url.pathExtension.lowercased() == "movpkg" { return .avfoundation }

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

        // (3b) Dolby Vision in a container AVFoundation CANNOT demux (chiefly MKV, or an extensionless debrid
        // link with no mp4/mov/m4v hint) from a non-torrent source, WITH the DV-remux lane enabled for this
        // display: route to AVPlayer anyway. The engine's loadFile detects the same condition (`shouldDVRemux`)
        // and mounts an in-process MKV -> fMP4 streaming remux behind a `vortxremux://` resource loader, so
        // AVPlayer gets a container it can demux and emits true DV. Per the owner DV mandate the lane's baked
        // default is ON wherever the display can show DV (dvDisplayCapable), macOS included. The remux stream
        // fails fast (before any video mounts) for a Profile-7/no-DOVI/undecodable-audio source, and the
        // AVPlayer -> libmpv .failed fallback in the chrome is the backstop, so a false widen never dead-ends.
        if isDolbyVision, dvRemuxEnabled(dvDisplayCapable: dvDisplayCapable), isDVRemuxCandidate(url) {
            return .avfoundation
        }

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
        if ext == "mp4" || ext == "m4v" || ext == "mov" || isHLS(url) { return true }
        // Debrid/CDN links carry the filename in a query param or an extensionless /download/<id> path
        // (e.g. TorBox "...?file=Movie.DV.mp4"), so pathExtension is empty and a genuinely-playable DV mp4
        // wrongly went to libmpv. Only widen when the path has NO usable extension, so a real .mkv path
        // still returns false and stays on libmpv.
        if ext.isEmpty {
            let s = url.absoluteString.lowercased()
            if s.contains(".mp4") || s.contains(".m4v") || s.contains(".mov") { return true }
        }
        return false
    }

    /// True for a source the DV-for-MKV remux path can attempt: an MKV (or a link with no mp4/mov/m4v token
    /// and a Matroska hint), served over http(s) from a non-loopback host. It must NOT already be an
    /// AVPlayer-native container (those take rule 3 directly) and NOT be a loopback/torrent URL. This is the
    /// container-side gate; the caller has already checked `isDolbyVision` and the loopback/override rules.
    static func isDVRemuxCandidate(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let host = (url.host ?? "").lowercased()
        if host == "127.0.0.1" || host == "localhost" || host.isEmpty { return false }
        if isAVPlayerContainer(url) { return false }   // a real mp4/mov/m4v/HLS never needs remux
        let s = url.absoluteString.lowercased()
        let ext = url.pathExtension.lowercased()
        if ext == "mkv" { return true }
        // Debrid links often hide the filename in a query param with no path extension: treat a Matroska
        // token as a candidate. A path that is a plain mp4/mov/m4v was already excluded above.
        if s.contains(".mkv") || s.contains("matroska") { return true }
        // Fully extensionless debrid link with NO container hint at all (e.g. TorBox "/download/<id>" with
        // no filename token): a DV stream that reached here (rule 3b) is one whose text label said DV but the
        // URL gives no container. The remux stream probes the real container and FAILS FAST (no video mounted)
        // if it isn't a remuxable DV MKV, so attempting is safe and lets a genuinely-DV-MKV extensionless link
        // play true DV instead of silently tone-mapping. Only widen for the truly hint-less case, so a link
        // that DOES carry a non-mkv container token above is unaffected.
        if ext.isEmpty, !s.contains(".mp4"), !s.contains(".m4v"), !s.contains(".mov"),
           !s.contains(".webm"), !s.contains(".avi"), !s.contains(".ts") {
            return true
        }
        return false
    }

    /// The engine's loadFile asks this to decide whether to mount the in-process MKV -> fMP4 streaming remux
    /// for a URL it is about to play. Mirrors rule (3b): the DV-remux lane must be enabled for this display and
    /// the URL must be a remux candidate. (isDolbyVision is implied here: only DV sources are routed to AVPlayer
    /// via the remux lane under Auto, so any candidate that reached this engine is one we chose to remux.)
    /// `dvDisplayCapable` defaults to the live `DVDisplaySupport` read so the caller need not pass it; the same
    /// value the router used at play-start routing time.
    @MainActor
    static func shouldDVRemux(url: URL, dvDisplayCapable: Bool) -> Bool {
        dvRemuxEnabled(dvDisplayCapable: dvDisplayCapable) && isDVRemuxCandidate(url)
    }

    /// Convenience overload that reads the live display capability on the main actor for callers that don't
    /// track it themselves (the engine's `loadFile`). Kept separate so the default isn't a nonisolated
    /// default-argument expression.
    @MainActor
    static func shouldDVRemux(url: URL) -> Bool {
        shouldDVRemux(url: url, dvDisplayCapable: DVDisplaySupport.isCapable)
    }
}
