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

    /// Opt-in flag for the DIRECT Dolby Vision lane (the sample-buffer shim: FFmpeg demux -> compressed
    /// CMSampleBuffers -> AVSampleBufferDisplayLayer, no HLS and no playlist declarations, so the -12927
    /// declaration/content cross-check cannot exist on it). OFF by default everywhere: this is an
    /// EXPERIMENTAL additional lane; when disabled nothing anywhere changes. Resolution order mirrors
    /// `dvRemuxEnabled`: explicit user default first, then the RemoteConfig fleet value, then a baked
    /// default of FALSE (unlike the remux lane there is no display-capability widening: the lane must be
    /// deliberately turned on, per-device or fleet-wide, while it earns trust).
    /// No Settings UI exists for this yet ON PURPOSE: the settings-parity rule requires any user-facing
    /// toggle to land on ALL platforms at once, so until the lane graduates the switch is RemoteConfig
    /// (`features.dvDirect`) or a defaults write, not a visible setting.
    static let dvDirectKey = "stremiox.dvDirect"
    static func dvDirectEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: dvDirectKey) != nil {
            return UserDefaults.standard.bool(forKey: dvDirectKey)   // explicit user value always wins
        }
        // Same present-vs-absent probe as dvRemuxEnabled: agreeing probes mean the remote key is SET.
        let snap = RemoteConfig.snapshot
        let onWhenAbsentTrue = snap.isFeatureOn("dvDirect", default: true)
        let onWhenAbsentFalse = snap.isFeatureOn("dvDirect", default: false)
        if onWhenAbsentTrue == onWhenAbsentFalse { return onWhenAbsentTrue }
        return false   // remote absent -> baked default OFF (experimental lane)
    }

    /// Whether the chrome should mount the DIRECT DV lane for a stream it has already routed to the
    /// AVPlayer side under the DV rules. This deliberately sits UNDER the existing routing (rule 3b) as a
    /// surface-level sub-branch rather than a new Engine case: the direct lane's failure demotes to the
    /// remux lane, whose failure demotes to libmpv, so every ladder rung that ships today is preserved.
    /// tvOS-only for now: that is the platform of the -12927 report and the DV mandate's primary target;
    /// the engine itself compiles on all platforms for when iOS/macOS chromes gain the mount.
    @MainActor
    static func shouldUseDirectDV(url: URL, isDolbyVision: Bool) -> Bool {
        #if os(tvOS)
        guard isDolbyVision, dvDirectEnabled(), DVDisplaySupport.isCapable else { return false }
        // The direct lane demuxes with FFmpeg, so its candidacy is the remux lane's: an MKV or an
        // extensionless/mislabeled debrid link. Native mp4/mov and HLS stay on AVPlayer itself.
        return isDVRemuxCandidate(url)
        #else
        return false
        #endif
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

        // (2) Explicit user override wins for non-torrents. NOTE: an `.mpv` override short-circuits BEFORE
        // the DV rules below, silently disabling the true-DV remux lane for Dolby Vision streams. This
        // function runs per render, so the guardrail message for that case (DiagnosticsLog + one-shot
        // in-player notice) lives in the chrome at play start (TVPlayerView.onAppear), not here.
        switch override {
        case .mpv:          return .mpv
        case .avfoundation: return .avfoundation
        case .auto:         break
        }

        // (3) Dolby Vision -> AVPlayer for true DV passthrough (libmpv/MoltenVK only tone-maps DV to SDR),
        // but ONLY for a container AVFoundation can demux (MP4/MOV/M4V or HLS). DV in an MKV must stay on
        // libmpv: AVFoundation has no Matroska demuxer, so routing it to AVPlayer would just fail over to
        // libmpv anyway (tone-mapped). The AVPlayer->libmpv .failed fallback in the chrome is the backstop.
        // The container is known here but the HEVC SAMPLE ENTRY is not (that needs the bytes), so an MP4 whose
        // entry is the AVPlayer-incompatible hev1/dvhe form still routes here; AVPlayerEngineController's
        // post-attach repair (#76) then re-mounts it through the remux lane (hvc1/dvh1) instead of black.
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
        if ext == "mp4" || ext == "m4v" || ext == "mov" { return true }
        if isHLS(url) { return true }
        // Debrid/CDN links carry the filename in a query param or an extensionless /download/<id> path
        // (e.g. TorBox "...?file=Movie.DV.mp4"), so pathExtension is empty. Scan ONLY the filename + query,
        // NOT the whole URL: a stray ".mp4" token in the host or path (a CDN id, a "trailer.mp4" query) used to
        // mislabel a real MKV as AVPlayer-native, which then routed the DV MKV to raw AVPlayer (no Matroska
        // demuxer -> item .failed -> "can't play this file"). A Matroska hint in the filename/query VETOES, so a
        // DV MKV is never called native; only a genuine mp4/m4v/mov filename token widens.
        if ext.isEmpty {
            let hint = (url.lastPathComponent + " " + (url.query ?? "")).lowercased()
            if hint.contains(".mkv") || hint.contains("matroska") { return false }
            if hint.contains(".mp4") || hint.contains(".m4v") || hint.contains(".mov") { return true }
        }
        return false
    }

    /// True iff `hint` (a lowercased filename + query string) carries one of `exts` as a REAL container
    /// extension: the token appears with its leading dot AND is followed by a delimiter or end-of-string, so a
    /// stray in-path fragment (a ".ts" buried in a CDN id, a ".mov" inside a longer token) never counts. The
    /// boundary-aware form of a plain substring scan; `exts` are given without the leading dot.
    private static func hasContainerExtension(_ hint: String, _ exts: [String]) -> Bool {
        let pattern = "\\.(" + exts.joined(separator: "|") + ")(?![a-z0-9])"
        return hint.range(of: pattern, options: .regularExpression) != nil
    }

    /// True for a source the DV-for-MKV remux path can attempt: an MKV (or a link with no mp4/mov/m4v token
    /// and a Matroska hint), served over http(s) from a non-loopback host. It must NOT already be an
    /// AVPlayer-native container (those take rule 3 directly) and NOT be a loopback/torrent URL. This is the
    /// container-side gate; the caller has already checked `isDolbyVision` and the loopback/override rules.
    static func isDVRemuxCandidate(_ url: URL) -> Bool { dvRemuxCandidacy(url).candidate }

    /// Extensions that name a REAL media container / manifest. Anything else that `URL.pathExtension` returns
    /// from a release-name path (the group tail ".H265-AOC", a numeric CDN id, a ".php" endpoint) is noise,
    /// NOT a container signal. Treating that noise as a container is exactly what pre-rejected a true DV
    /// WEB-DL from the remux lane (candidate=false -> forced HDR10 tone-map + PCM audio on a DV display).
    private static let knownContainerExts: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "ts", "m2ts", "mts",
        "mpg", "mpeg", "vob", "flv", "wmv", "asf", "ogv", "ogm", "3gp", "3g2",
        "rm", "rmvb", "divx", "movpkg", "m3u8", "m3u", "mpd", "ism", "ismc",
    ]

    /// `isDVRemuxCandidate` with the WHY: which signal qualified or disqualified the URL. The chromes log the
    /// reason on the [dv] route line so a `candidate=false` in a device log is unambiguous (which gate fired)
    /// instead of needing this file open next to the log.
    static func dvRemuxCandidacy(_ url: URL) -> (candidate: Bool, reason: String) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return (false, "scheme=\(url.scheme ?? "nil") not http(s)")
        }
        let host = (url.host ?? "").lowercased()
        if host == "127.0.0.1" || host == "localhost" || host.isEmpty { return (false, "loopback/empty host") }
        // A genuine path-level mp4/m4v/mov (or HLS/DASH manifest) is AVPlayer-native (or an adaptive stream
        // the remux must never touch) and never needs the remux. Do NOT gate on isAVPlayerContainer here: its
        // extensionless mp4-token heuristic wrongly disqualified DV MKVs delivered as extensionless debrid
        // links carrying a stray ".mp4" token, so they routed to raw AVPlayer AND could not remux -> dead end.
        // Only a real native path extension vetoes; the Matroska checks below then decide.
        let pathExt = url.pathExtension.lowercased()
        if pathExt == "mp4" || pathExt == "m4v" || pathExt == "mov" { return (false, "native container .\(pathExt)") }
        if isHLS(url) { return (false, "HLS manifest") }
        if pathExt == "mkv" { return (true, "path extension .mkv") }
        // Scan ONLY the filename + query, not the whole URL, and match container tokens on an extension
        // BOUNDARY (the leading dot plus a trailing delimiter / end-of-string). A bare
        // absoluteString.contains(".ts") used to veto on a stray ".ts" buried in a CDN path id or host, wrongly
        // sending a true DV MKV to the tone-map lane; a boundary match over the filename/query never does.
        // Debrid links often hide the filename in a query param with no path extension: a Matroska token there
        // is a candidate. A path that is a plain mp4/mov/m4v was already excluded above.
        let hint = (url.lastPathComponent + " " + (url.query ?? "")).lowercased()
        if hasContainerExtension(hint, ["mkv"]) || hint.contains("matroska") {
            return (true, "matroska token in filename/query")
        }
        // A RECOGNIZED non-Matroska container extension on the path is a trusted signal and vetoes: those
        // sources demux fine on libmpv and the remux lane was never validated against them.
        if knownContainerExts.contains(pathExt) { return (false, "non-remux container .\(pathExt)") }
        // No trustworthy container signal left: the path is extensionless (TorBox "/download/<id>") OR its
        // "extension" is release-name noise ("Movie.2026.WEB-DL.DV.Atmos.H265-AOC" -> pathExtension
        // "h265-aoc", the 0.3.14 field case that pre-rejected a true DV WEB-DL into the tone-map lane). A DV
        // stream that reached here (rule 3b) is one whose text label said DV but whose URL cannot prove a
        // container either way. The remux stream probes the REAL container bytes and fails fast (before any
        // video mounts) when it isn't a remuxable DV source, and the chrome's progress-aware start watchdog +
        // AVPlayer .failed path demote cleanly, so ATTEMPTING is safe; pre-rejecting silently tone-maps a
        // title the display could have shown in true DV. A real non-mkv container token in the filename/query
        // still vetoes, so labeled mp4/webm/avi/ts sources are unaffected.
        if !hasContainerExtension(hint, ["mp4", "m4v", "mov", "webm", "avi", "ts", "m3u8", "mpd"]) {
            return (true, pathExt.isEmpty ? "extensionless, no container hint (probe-and-fail-fast)"
                                          : "pseudo-extension .\(pathExt) is not a container, no container hint (probe-and-fail-fast)")
        }
        return (false, "non-mkv container token in filename/query")
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
