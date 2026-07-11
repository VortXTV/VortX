#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import AVKit
import AVFoundation
import CoreMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// AVFoundation implementation of `PlayerEngine`. It drives one `AVPlayer` and maps its KVO + a periodic
/// time observer onto the SAME `MPVProperty` event keys the chrome already listens for, so the full
/// PlayerScreen chrome can drive AVPlayer exactly as it drives the libmpv controller (the chrome holds the
/// engine as `coordinator.player`, an `any PlayerEngine`). This is the engine VortX routes Dolby Vision and
/// HTTP/HLS streams to: libmpv/MoltenVK cannot do true DV passthrough (it tone-maps to SDR), while
/// AVPlayerLayer is DV/EDR native.
///
/// iOS + macOS + tvOS (#46, #76): all three route Dolby Vision / HLS here under the full player chrome via
/// `PlayerEngineRouter`, with a fail-soft fallback to libmpv if the AVPlayer item fails to load. tvOS now hosts
/// this same engine under the existing `TVPlayerView` chrome (the control bar, scrubber, options panels, and
/// failover are plain SwiftUI over the video surface, driven only through `coordinator.player` and the
/// `MPVProperty` event bus, so they render over an `AVPlayerLayer` exactly as over libmpv). Remote input still
/// goes through `TVPlayerView`'s UIKit `RemoteCatcher`, so no focusable SwiftUI overlay competes with the
/// Siri-remote focus engine.
///
/// This conforms to `PlayerEngine` and emits events; rendering is owned by a sibling AVPlayerLayer host that
/// calls `attachLayer`, while this object owns playback + state only. Embedded track selection (audio +
/// subtitles via `AVMediaSelectionGroup`), `mediaSummary`, and `playbackStats` are real; chapters load from
/// asset metadata when present. Subtitle styling, A/V delay, external add-on subtitles, and trickplay frame
/// capture have no AVFoundation equivalent and stay no-ops, so the chrome hides those rows when this engine is
/// active. The plain `HLSPlayerView.AVPlayerModel` still serves the bare iOS HLS path that does not need the
/// full chrome.
@MainActor
final class AVPlayerEngineController: NSObject, PlayerEngine {
    let player = AVPlayer()
    /// The chrome's Coordinator. Property changes are pushed here with the same string keys the libmpv
    /// controller emits, so `handleProperty()` runs unchanged against either engine.
    weak var playDelegate: MPVPlayerDelegate?

    private var item: AVPlayerItem?
    private var isReady = false
    private var didStart = false
    /// One fatal `endFileError` per loaded item. The item's `.failed` KVO and the failed-to-play-to-end
    /// notification can BOTH fire for one failure; a duplicate event lands after the chrome has already
    /// demoted to libmpv and used to punch through into its retry/error path (the DV "error screen").
    private var fatalErrorEmitted = false
    private var pendingSeek: Double?
    private var requestedRate: Float = 1
    private var timeObserver: Any?
    /// Throttle marks for the two EXPENSIVE per-tick side effects, mirroring the libmpv path
    /// (MPVMetalViewController.swift lastTimePosEmit / lastCacheTimeEmit). The periodic observer still
    /// fires at 0.25s, but the probe write (NSLock) and the loadedTimeRanges scan are gated behind the same
    /// PerformanceMode-scaled interval so a constrained device gets the same relief the libmpv path already has.
    /// Confined to the main actor (only read/written inside the observer's MainActor.assumeIsolated block).
    private var lastProbeEmit: TimeInterval = 0
    private var lastCacheEmit: TimeInterval = 0
    private var observations: [NSKeyValueObservation] = []
    private var pipController: AVPictureInPictureController?
    private weak var playerLayer: AVPlayerLayer?
    /// On-demand video frame tap for trickplay (community scrub previews). Pull-model: AVFoundation only
    /// converts a frame when copyPixelBuffer is called (~every 10s), so it adds no steady-state cost. The MPV
    /// engine captures via a Metal blit; AVPlayer previously had NO capture path (captureFrameJPEGData was a
    /// nil stub), so AVPlayer-routed titles (Dolby Vision / HLS on Auto) generated zero trickplay frames.
    /// Requesting BGRA output makes the system tone-map HDR / Dolby Vision frames to SDR, so the JPEG is usable.
    private var videoOutput: AVPlayerItemVideoOutput?
    private lazy var captureContext = CIContext(options: nil)
    private(set) var videoSizeMode = UserDefaults.standard.string(forKey: "stremiox.videoSize") ?? "original"
    // Cached AVMediaSelection groups + their MPVTrack views (loaded async once the item is ready). The
    // MPVTrack.id is the option's index in the group; mpv's -1 = off (deselect the group).
    private var audioGroup: AVMediaSelectionGroup?
    private var subGroup: AVMediaSelectionGroup?
    private var audioTracks: [MPVTrack] = []
    private var subTracks: [MPVTrack] = []
    // External-subtitle rendering (add-on + community-pooled srt/vtt). AVFoundation has no API to side-load or
    // time-shift an external SRT, so VortX owns it: parse the file into cues and draw the active cue in
    // `subtitleOverlay` (a view above the AVPlayerLayer), synced to the player clock, with `setSubDelay` as an
    // offset. `externalSubActive` is true while an external overlay sub is showing; when it is, any AVPlayer-native
    // legible track is deselected to avoid double subtitles.
    private let subtitleRenderer = SubtitleCueRenderer()
    private weak var subtitleOverlay: SubtitleOverlayView?
    private var externalSubActive = false
    // Asset chapter markers, loaded async once the item is ready (empty when the asset carries none).
    private var loadedChapters: [MPVChapter] = []
    // DV-for-MKV streaming remux (Phase 1). When non-nil, this session is playing an MKV that was remuxed
    // in-process to fragmented MP4 and served to AVPlayer over the `vortxremux://` scheme. Held for the whole
    // session so its resource-loader delegate + remux thread stay alive; torn down in stop()/loadFile().
    // LEGACY delivery: kept compiled as the rollback path behind VortXRemuxHLSServer.deliveryEnabled.
    private var remuxLoader: VortXRemuxResourceLoader?
    // DV-for-MKV streaming remux, LOCAL HLS delivery (b166, the default). The same remux stream, indexed
    // into init + media segments and served to AVPlayer as vanilla HLS from 127.0.0.1, which is the one
    // delivery AVFoundation supports for a growing fMP4 (the progressive loader path above never framed on
    // device). Held for the whole session; torn down in stop()/loadFile().
    private var remuxHLSServer: VortXRemuxHLSServer?
    /// Whether the forward-only DV remux is mounted for the CURRENT item (either delivery). The chrome reads
    /// this to suppress its Continue-Watching resume seek: the remux produces bytes linearly, so a pre-start
    /// seek lands in bytes that do not exist yet, no frame ever arrives, and the start watchdog demotes the
    /// whole session to libmpv (killing BOTH true DV and Atmos on every replay).
    var isRemuxMounted: Bool { remuxLoader != nil || remuxHLSServer != nil }
    /// The launch site sets this from the stream's Dolby Vision flag BEFORE loadFile (same plumbing as the
    /// libmpv lane, MPVMetalViewController.contentIsDolbyVision). Used to request the Apple TV's Dolby Vision
    /// display mode BEFORE the AVPlayerItem is attached (Apple Tech Talk 503 ordering) for ALL DV routes:
    /// with only the remux-gated post-ready request, a native DV MP4/MOV/HLS routed here never switched the
    /// panel at all (a raw AVPlayerLayer gets no AVKit auto-switching).
    var contentIsDolbyVision = false
    // Dedicated serial queue for the resource-loader delegate callbacks, so the blocking buffer reads never
    // run on the main thread.
    private let remuxLoaderQueue = DispatchQueue(label: "vortx.dvremux.delegate")

    // MARK: Loading + transport

    func loadFile(_ url: URL, headers: [String: String]?, live: Bool) {
        teardownObservers()
        teardownRemux()
        isReady = false; didStart = false; pendingSeek = nil; fatalErrorEmitted = false
        audioGroup = nil; subGroup = nil; audioTracks = []; subTracks = []; loadedChapters = []
        disableExternalSubtitle()   // a new title starts with no external overlay sub
        // Claim .playback before play so PiP and locked-screen audio work, and advertise multichannel so the
        // system passes through Atmos (#78) and applies AirPods Spatial Audio (#88). Idempotent with the
        // libmpv path since only one engine is live at a time. macOS has no AVAudioSession (the system routes
        // audio automatically), so this is iOS/tvOS only.
        #if os(iOS) || os(tvOS)
        AVPlayerAudioSession.activateForMovie()
        #endif
        // DV-for-MKV streaming remux path (Phase 1, opt-in): if the router flagged this URL for the in-process
        // MKV -> fMP4 remux, mount the remux instead of loading the MKV directly (AVFoundation has no Matroska
        // demuxer). DEFAULT delivery (b166) is LOCAL HLS: the remux output is indexed into init + media
        // segments and served from 127.0.0.1 as vanilla HLS, the one way AVFoundation consumes a growing fMP4
        // (and the lane Apple documents for Dolby Vision 8.1). The legacy `vortxremux://` progressive loader
        // stays compiled behind VortXRemuxHLSServer.deliveryEnabled for instant rollback. Everything below
        // (KVO, track selection, trickplay tap) is identical; only the asset's source differs.
        let newAsset: AVURLAsset
        let wantsRemux = PlayerEngineRouter.shouldDVRemux(url: url)
        if wantsRemux, VortXRemuxHLSServer.deliveryEnabled,
           let mounted = VortXRemuxHLSServer.make(input: url, headers: headers) {
            remuxHLSServer = mounted.server
            mounted.server.start()
            newAsset = AVURLAsset(url: mounted.playlistURL)
            DiagnosticsLog.log("avplayer", "dv-remux mount (local HLS) host=\(url.host ?? "?") -> 127.0.0.1:\(mounted.server.port)")
            // [dv] the true-DV remux lane mounted: AVPlayer is now fed the remux as local HLS. If a classify
            // fail-soft fires next (see VortXMKVRemuxStream), the item .failed demotion below ties the reason
            // to the observed engine flip, giving one greppable [dv] trail.
            VXProbe.log("dv", "remux mounted (local HLS) host=\(url.host ?? "?") -> 127.0.0.1:\(mounted.server.port)")
        } else if wantsRemux, !VortXRemuxHLSServer.deliveryEnabled,
                  let built = VortXRemuxResourceLoader.make(input: url, headers: headers) {
            remuxLoader = built.loader
            let asset = AVURLAsset(url: built.assetURL)
            asset.resourceLoader.setDelegate(built.loader, queue: remuxLoaderQueue)
            built.loader.start()
            newAsset = asset
            DiagnosticsLog.log("avplayer", "dv-remux mount host=\(url.host ?? "?") -> \(built.assetURL.scheme ?? "?")")
            VXProbe.log("dv", "remux mounted host=\(url.host ?? "?") -> \(built.assetURL.scheme ?? "?")")
        } else if wantsRemux {
            // The router demanded the DV-for-MKV remux lane but the mount could not be built (the local HLS
            // server failed to bind, or the legacy loader could not be assembled). AVFoundation has no
            // Matroska demuxer, so loading the raw MKV here would mount an item AVPlayer can never produce a
            // frame from. Fail-soft immediately so the chrome demotes to libmpv HDR10 instead of stalling on
            // an un-demuxable asset. This ties into the [dv] demotion trail below.
            DiagnosticsLog.log("avplayer", "dv-remux mount build failed host=\(url.host ?? "?") -> demoting to libmpv")
            VXProbe.log("dv", "remux mount build failed -> endFileError demote host=\(url.host ?? "?")")
            fatalErrorEmitted = true
            emit(MPVProperty.endFileError, "DV remux unavailable")
            return
        } else {
            let options = (headers?.isEmpty ?? true) ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers!]
            newAsset = AVURLAsset(url: url, options: options)
        }
        let newItem = AVPlayerItem(asset: newAsset)
        item = newItem
        if remuxHLSServer != nil {
            // The remux window bounds OUR buffer, but AVPlayer keeps its OWN forward buffer of the served HLS
            // and, left unset, sizes it at its discretion (hundreds of MB at 4K DV bitrates, in the SAME
            // jetsam-bound process as node + mpv - a major contributor to the ~900MB that gets the app killed
            // on backgrounding). 30s is ample against a local loopback origin the producer already leads.
            newItem.preferredForwardBufferDuration = 30
        }
        // Attach a pull-model frame tap so trickplay can grab the displayed frame on demand (see videoOutput).
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        newItem.add(output)
        videoOutput = output
        #if os(tvOS)
        // TRUE DOLBY VISION: switch the panel into DV mode BEFORE the item is attached (Apple Tech Talk 503:
        // "perform this switch before assigning the AVPlayerItem"; current tvOS can even reject mismatched
        // VIDEO-RANGE HLS variants with -11868 when the panel is not switched first). Fires when the DV remux
        // mounted (it only mounts for DV) OR the routed stream is DV-flagged (a native DV MP4/MOV/HLS, which
        // previously never set preferredDisplayCriteria at all). fps/size are unknown pre-attach; the
        // readyToPlay request below re-asserts with the real values. Fail-soft: a refused/ignored request
        // changes nothing about playback, and reset() on stop() restores the default mode.
        if isRemuxMounted || contentIsDolbyVision {
            HDRDisplayMode.request(.dolbyVision, fps: 0, width: 0, height: 0, in: nil)
            DiagnosticsLog.log("dv", "requested Dolby Vision display mode pre-attach (remux=\(isRemuxMounted) dvFlag=\(contentIsDolbyVision))")
        } else {
            // A non-DV stream loading into this SAME engine (an in-player source/episode switch) must not
            // inherit a previous title's DV criteria. Idempotent: reset only clears when criteria are set.
            HDRDisplayMode.reset(in: nil)
        }
        #endif
        // START PROMPTLY. With the default (true), AVPlayer waits to build a stall-proof buffer before it
        // begins; for a large 4K / Dolby Vision debrid stream that wait can outlast any reasonable start
        // deadline, so the player mounts, shows the chrome, and never produces a frame (no item .failed, no
        // timePos) -> on tvOS that read as "AVPlayer plays nothing" and tripped the libmpv fallback for every
        // stream. We drive our own start watchdog + stall handling, so let playback begin at the first samples.
        player.automaticallyWaitsToMinimizeStalling = false
        player.replaceCurrentItem(with: newItem)
        player.allowsExternalPlayback = true   // AirPlay
        DiagnosticsLog.log("avplayer", "load host=\(url.host ?? "?") scheme=\(url.scheme ?? "?") ext=\(url.pathExtension) headers=\(headers?.count ?? 0) live=\(live)")
        observe(newItem)
        // Drive the current status now: the KVO below uses [.initial, .new], but an item that is already
        // readyToPlay at attach time still benefits from an explicit kick so play() is never skipped.
        if newItem.status != .unknown { handleStatus(newItem) }
    }

    func play() { player.rate = requestedRate }   // rate > 0 starts playback at the chosen speed
    func pause() { player.pause() }
    func togglePause() { player.timeControlStatus == .paused ? play() : pause() }

    func seek(to seconds: Double) {
        // Before the item is playable, remember the target and apply it on ready (covers the chrome's
        // resume seek issued right after loadFile, which AVPlayer would otherwise drop).
        guard isReady else { pendingSeek = seconds; return }
        let dur = item?.duration.seconds ?? 0
        let clamped = (dur.isFinite && dur > 1) ? min(max(seconds, 0), max(dur - 1, 0)) : max(seconds, 0)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        emit(MPVProperty.timePos, clamped)
        updateSubtitleOverlay(atClock: clamped)   // re-check the cue now; the observer is only ~4 Hz
    }
    func seek(by seconds: Double) { seek(to: player.currentTime().seconds + seconds) }

    func setSpeed(_ speed: Double) {
        requestedRate = Float(speed)
        if player.timeControlStatus != .paused { player.rate = requestedRate }
    }

    /// Live playback position (AVPlayer currentTime), for the wall-clock trickplay capture driver. 0 / NaN
    /// before the first sample is normalised to 0.
    var playbackPositionSeconds: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    /// Live audio volume. AVPlayer.volume is a 0...1 gain; map the chrome's 0...100 scale onto it. Muting is
    /// separate (setMuted), so setting a level never un-mutes on its own.
    func setVolume(_ volume0to100: Double) {
        player.volume = Float(max(0, min(100, volume0to100)) / 100)
    }
    func setMuted(_ muted: Bool) { player.isMuted = muted }

    func stop() {
        teardownObservers()
        teardownRemux()
        #if os(tvOS)
        // Return the TV from any Dolby Vision display mode this session requested (idempotent no-op when it
        // was not DV; only this lane sets DV criteria, and one engine is live at a time).
        HDRDisplayMode.reset(in: nil)
        #endif
        disableExternalSubtitle()
        player.pause()
        player.replaceCurrentItem(with: nil)
        pipController?.delegate = nil
        pipController = nil
        videoOutput = nil
        item = nil
    }

    /// Tear down the DV-for-MKV remux session (stop the remux thread + the local HLS server / unblock any
    /// waiting loader request). Called before loading a new file and on stop(), so the remux never straddles
    /// two titles.
    private func teardownRemux() {
        remuxLoader?.invalidate()
        remuxLoader = nil
        remuxHLSServer?.invalidate()
        remuxHLSServer = nil
    }

    // MARK: Video sizing

    func setVideoSize(_ mode: String) {
        videoSizeMode = mode
        UserDefaults.standard.set(mode, forKey: "stremiox.videoSize")
        playerLayer?.videoGravity = Self.gravity(for: mode)
        syncSubtitleVideoInset()   // gravity change moves the picture: re-seat the external-cue overlay over it
    }

    /// Re-seat the external-subtitle overlay above the bottom of the actual picture. `videoRect` reflects the
    /// current gravity synchronously, so the letterbox bar height (host-bottom to picture-bottom) is exact here.
    /// The host view also calls this on layout; this call catches a gravity change that does not trigger a layout.
    private func syncSubtitleVideoInset() {
        guard let layer = playerLayer, let overlay = subtitleOverlay else { return }
        let video = layer.videoRect
        guard video.height > 0, layer.bounds.height > 0 else { return }
        overlay.setVideoBottomInset(max(0, layer.bounds.maxY - video.maxY))
    }
    private static func gravity(for mode: String) -> AVLayerVideoGravity {
        switch mode {
        case "zoom", "fill": return .resizeAspectFill
        case "stretch":      return .resize
        default:             return .resizeAspect   // original: whole frame, keep aspect
        }
    }

    // MARK: Tracks / subtitles (embedded tracks via AVMediaSelection; external subs are a later step)

    func tracks(ofType type: String) -> [MPVTrack] {
        switch type {
        case "audio": return audioTracks
        case "sub":   return subTracks
        default:      return []
        }
    }
    func setAudioTrack(_ id: Int) { select(id, in: audioGroup) }
    /// Selecting an embedded/HLS legible track (or turning subtitles Off) also turns OFF any external overlay
    /// sub, so the two never fight or double up. `id < 0` = Off, which the caller uses for the "Off" row.
    func setSubtitleTrack(_ id: Int) {
        if externalSubActive { disableExternalSubtitle() }
        select(id, in: subGroup)
    }

    /// Select option `id` (its index in the group) on the current item, or deselect for mpv's -1 = off.
    private func select(_ id: Int, in group: AVMediaSelectionGroup?) {
        guard let group, let item = player.currentItem else { return }
        if id < 0 { item.select(nil, in: group) }
        else if id < group.options.count { item.select(group.options[id], in: group) }
    }

    /// The overlay host (in `AVPlayerEngineView`) installs its subtitle overlay here so the engine can push the
    /// active cue into it from the periodic time observer. Weak: the host view owns the overlay's lifetime.
    func attachSubtitleOverlay(_ overlay: SubtitleOverlayView) {
        subtitleOverlay = overlay
        overlay.setText(nil)
    }

    /// Load an EXTERNAL srt/vtt subtitle (add-on or community-pooled) and render it ourselves over the
    /// AVPlayerLayer. AVFoundation cannot side-load or time-shift an external SRT, so we: download the file
    /// (reusing the shared subtitle cache/session + 12s timeout + one retry), parse it into timed cues, load
    /// them into the renderer, and drive the overlay from the player clock. Turning this on hides any
    /// AVPlayer-native legible track so subtitles never double up. `completion(true)` once cues are loaded.
    func addExternalSubtitle(url: String, title: String, lang: String,
                             timeout: TimeInterval, completion: ((Bool) -> Void)?) {
        guard let remote = URL(string: url) else { completion?(false); return }
        let finish: (Bool) -> Void = { ok in DispatchQueue.main.async { completion?(ok) } }
        SubtitleFileFetcher.fetch(remote, timeout: timeout) { [weak self] data in
            guard let data else { finish(false); return }
            let cues = SubtitleCueRenderer.parse(data: data)
            guard !cues.isEmpty else { finish(false); return }
            Task { @MainActor in
                guard let self else { finish(false); return }
                self.subtitleRenderer.load(cues: cues)
                self.externalSubActive = true
                // Turn off any embedded/HLS legible track so we don't render two subtitle streams at once.
                if let group = self.subGroup { self.player.currentItem?.select(nil, in: group) }
                self.subtitleOverlay?.applyStyle()
                self.updateSubtitleOverlay(atClock: self.player.currentTime().seconds)
                finish(true)
            }
        }
    }

    /// Turn off the external overlay subtitle (clear cues + hide the overlay). Native track selection is
    /// untouched, so the caller can then select an embedded track or leave subtitles Off.
    private func disableExternalSubtitle() {
        externalSubActive = false
        subtitleRenderer.clear()
        subtitleOverlay?.setText(nil)
    }

    /// Manual subtitle sync in seconds (positive = subtitles appear LATER, matching libmpv `sub-delay`). Applied
    /// as the renderer's offset, so the change is live: the next overlay update uses the new offset immediately.
    func setSubDelay(_ seconds: Double) {
        subtitleRenderer.offset = seconds
        if externalSubActive { updateSubtitleOverlay(atClock: player.currentTime().seconds) }
    }
    func setAudioDelay(_ seconds: Double) {}
    /// Re-apply the user's subtitle appearance (size / colour / background) to the live overlay.
    func applySubtitleStyle() { subtitleOverlay?.applyStyle() }
    /// The current external-subtitle delay in seconds, so the sync-capture path can pool the learned offset.
    func currentSubDelaySeconds() -> Double { subtitleRenderer.offset }

    /// Push the cue that should be visible at player clock time `clock` into the overlay (nil hides it). No-op
    /// when no external sub is loaded, so native/embedded subtitle selection is never disturbed.
    private func updateSubtitleOverlay(atClock clock: Double) {
        guard externalSubActive else { return }
        subtitleOverlay?.setText(subtitleRenderer.activeText(atClock: clock))
    }

    // MARK: Chapters / media info

    /// Asset chapter markers, populated async once the item is ready (see `loadChapters`). Empty until then
    /// and for assets that carry none, so the Chapters panel simply shows nothing.
    func chapters() -> [MPVChapter] { loadedChapters }

    /// Encoded video height (so the chrome's metadata line can label "4K" / "1080p") and the active audio
    /// codec name. Height comes from the item's presentation size (its decoded frame dimensions); the codec
    /// from the selected audible option's media format. Both are best-effort and empty before the item loads.
    func mediaSummary() -> (width: Int, height: Int, audioCodec: String) {
        let size = item?.presentationSize ?? .zero
        return (Int(size.width), Int(size.height), selectedAudioCodec())
    }

    /// Live playback stats from AVFoundation's access log (the only per-stream telemetry AVPlayer exposes):
    /// the negotiated + observed bitrates and the indicated resolution. Empty before playback or when the log
    /// has no events yet.
    func playbackStats() -> [(String, String)] {
        guard let event = item?.accessLog()?.events.last else { return [] }
        var rows: [(String, String)] = []
        let h = Int(item?.presentationSize.height ?? 0)
        if h > 0 { rows.append(("Resolution", "\(Int(item?.presentationSize.width ?? 0))×\(h)")) }
        if event.indicatedBitrate > 0 { rows.append(("Stream bitrate", bitrateString(event.indicatedBitrate))) }
        if event.observedBitrate > 0 { rows.append(("Observed bitrate", bitrateString(event.observedBitrate))) }
        if event.numberOfStalls > 0 { rows.append(("Stalls", "\(event.numberOfStalls)")) }
        return rows
    }

    private func bitrateString(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
            : String(format: "%.0f kbps", bitsPerSecond / 1_000)
    }

    /// The codec four-char-code of the selected audible option, lowercased to read like the libmpv codec
    /// names the metadata line already shows (e.g. "ec-3", "aac"). Empty when nothing is resolvable yet.
    private func selectedAudioCodec() -> String {
        guard let item = player.currentItem, let group = audioGroup,
              let option = item.currentMediaSelection.selectedMediaOption(in: group),
              let format = option.mediaSubTypes.first else { return "" }
        // mediaSubTypes is [NSNumber] of FourCharCodes; a FourCharCode is four ASCII bytes (high byte first).
        let code = format.uint32Value
        var chars = ""
        for shift in [24, 16, 8, 0] {
            let byte = UInt8(truncatingIfNeeded: code >> UInt32(shift))
            if byte > 32 { chars.append(Character(UnicodeScalar(byte))) }
        }
        return chars.lowercased()
    }

    /// Load asset chapter markers off the main thread, then cache them and re-emit track-list so the chrome
    /// re-pulls `chapters()`. Cheap (a metadata read), and a no-chapter asset just yields []. Mirrors the
    /// async pattern of `loadSelectionGroups`.
    private func loadChapters() {
        guard let item = player.currentItem else { return }
        let asset = item.asset
        Task { @MainActor in
            let locale = Locale.current
            let groups = (try? await asset.loadChapterMetadataGroups(
                bestMatchingPreferredLanguages: locale.language.languageCode.map { [$0.identifier] } ?? [])) ?? []
            guard player.currentItem === item else { return }   // a newer file loaded meanwhile
            var chapters: [MPVChapter] = []
            for group in groups {
                let start = group.timeRange.start.seconds
                guard start.isFinite else { continue }
                let titleItem = group.items.first { $0.commonKey == .commonKeyTitle }
                let title = (try? await titleItem?.load(.stringValue)) ?? nil
                chapters.append(MPVChapter(title: title ?? "", start: start))
            }
            guard player.currentItem === item else { return }
            loadedChapters = chapters.sorted { $0.start < $1.start }
            if !loadedChapters.isEmpty { emit(MPVProperty.trackList, nil) }
        }
    }

    // MARK: Decode / audio routing (AVFoundation-managed; no-ops on this engine)

    func setHardwareDecoding(_ on: Bool) {}
    var hardwareDecoding: Bool { true }
    func setAudioOutputMode(_ mode: AudioOutputMode) {}

    // MARK: Trickplay / HDR

    func captureFrameJPEGData(maxWidth: CGFloat, completion: @escaping (Data?) -> Void) {
        guard let output = videoOutput else { completion(nil); return }
        let time = player.currentTime()
        // Protected (FairPlay) or not-yet-rendered frames return nil here; fail soft (skip this capture tick).
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            completion(nil); return
        }
        let ctx = captureContext
        // Downscale + JPEG-encode off the main thread; CVPixelBuffer and CIContext are safe to hand off.
        DispatchQueue.global(qos: .utility).async {
            let data = Self.encodeJPEG(from: pixelBuffer, maxWidth: maxWidth, context: ctx)
            DispatchQueue.main.async { completion(data) }
        }
    }

    /// CVPixelBuffer (BGRA) -> downscaled JPEG via ImageIO (cross-platform; no UIKit/AppKit dependency).
    private static func encodeJPEG(from pixelBuffer: CVPixelBuffer, maxWidth: CGFloat, context: CIContext) -> Data? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let width = ci.extent.width
        guard width > 0, ci.extent.height > 0 else { return nil }
        let scale = min(1, maxWidth / width)
        let image = scale < 1 ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality as String: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
    /// AVPlayerLayer negotiates HDR/DV with the display itself, so there is no app-driven HDR toggle here.
    var hdrAvailable: Bool { false }

    func setOrientation(landscape: Bool) {}   // the hosting view controller drives device orientation

    // MARK: Rendering hand-off + PiP

    /// The AVPlayerLayer host calls this once its layer exists, so video gravity + PiP bind to the live layer.
    func attachLayer(_ layer: AVPlayerLayer) {
        playerLayer = layer
        layer.videoGravity = Self.gravity(for: videoSizeMode)
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let pip = AVPictureInPictureController(playerLayer: layer)
        pip?.delegate = self
        pipController = pip
    }

    // MARK: Observation -> MPVProperty events

    private func observe(_ item: AVPlayerItem) {
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in self?.handleStatus(item) }
        })
        observations.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.emit(MPVProperty.pausedForCache, item.isPlaybackBufferEmpty) }
        })
        observations.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in if item.isPlaybackLikelyToKeepUp { self?.emit(MPVProperty.pausedForCache, false) } }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                // Diagnostic: a player stuck at .waitingToPlayAtSpecifiedRate (2) with a buffering wait-reason
                // is the "mounts but never plays" signature; logging the reason pinpoints it in one test.
                DiagnosticsLog.log("avplayer", "timeControlStatus=\(player.timeControlStatus.rawValue) waitReason=\(player.reasonForWaitingToPlay?.rawValue ?? "none")")
                // Mirror the transport state + buffering wait into the probe so the heartbeat is meaningful
                // on the AVPlayer path (DV / HLS). waitingToPlayAtSpecifiedRate is AVPlayer's "buffering".
                let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                let stateText = player.timeControlStatus == .paused ? "paused"
                    : (waiting ? "buffering" : "playing")
                VXProbeState.shared.setPlayer(state: stateText, engine: "avplayer", buffering: waiting)
                VXProbe.event("player", "stall \(waiting ? "start" : "end")")
                self?.emit(MPVProperty.pause, player.timeControlStatus == .paused)
            }
        })
        // ~4 Hz, matching the libmpv controller's coalesced time-pos cadence. Delivered on .main, so it runs
        // synchronously on the main actor (no extra Task hop that could fire after teardown nils the observer).
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.timeObserver != nil else { return }
                // Cheap, every tick: the play head (scrubber smoothness) and the subtitle overlay clock. These
                // must stay at the full 0.25s cadence or the progress bar and external subs visibly lag.
                self.emit(MPVProperty.timePos, time.seconds)
                self.updateSubtitleOverlay(atClock: time.seconds)   // sync external-sub overlay to the clock
                // Gate the two EXPENSIVE side effects (the NSLock probe write and the loadedTimeRanges scan)
                // behind the same PerformanceMode-scaled interval the libmpv path uses (0.5s reduced, else
                // 0.25s), so a constrained device is not doing an unconditional lock + O(ranges) loop 4x/sec.
                let clock = ProcessInfo.processInfo.systemUptime
                let minInterval = PerformanceMode.reduced ? 0.5 : 0.25
                // Push the play head (and duration when known) into the probe, throttled.
                if clock - self.lastProbeEmit >= minInterval {
                    self.lastProbeEmit = clock
                    let dur = self.item?.duration.seconds ?? 0
                    VXProbeState.shared.setPlayer(pos: time.seconds.isFinite ? Int(time.seconds) : 0,
                                                  dur: dur.isFinite && dur > 0 ? Int(dur) : nil,
                                                  engine: "avplayer")
                }
                // YouTube-style buffered-ahead edge: the end of the loaded range that CONTAINS the playhead
                // (AVPlayer reports one or more loaded ranges). Emitting the same key libmpv uses lets the
                // scrubber render the grey band identically on both engines. Fail-soft: no matching range -> 0.
                // Throttled to match libmpv, which already caps demuxerCacheTime at 0.5s.
                if clock - self.lastCacheEmit >= minInterval, let item = self.item {
                    self.lastCacheEmit = clock
                    let now = time.seconds
                    var aheadEdge = 0.0
                    for value in item.loadedTimeRanges {
                        let r = value.timeRangeValue
                        let start = r.start.seconds, end = (r.start + r.duration).seconds
                        guard start.isFinite, end.isFinite else { continue }
                        if now >= start - 1 && now <= end { aheadEdge = max(aheadEdge, end) }
                    }
                    if aheadEdge > 0 { self.emit(MPVProperty.demuxerCacheTime, aheadEdge) }
                }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didPlayToEnd),
                                               name: .AVPlayerItemDidPlayToEndTime, object: item)
        NotificationCenter.default.addObserver(self, selector: #selector(failedToEnd(_:)),
                                               name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        #if canImport(UIKit)
        // Jetsam relief (mirrors MPVMetalViewController.shedForMemoryPressure): a paused AVPlayer keeps
        // filling its forward buffer at its own discretion, and a 4K / DV-remux HLS stream buffers
        // hundreds of MB — on tvOS the pause also lets the screensaver (its own 4K pipeline) start on
        // top, and jetsam reaps this app. The memory warning is the system's last call before that;
        // respond by capping the item's forward buffer so AVFoundation trims instead of being killed.
        // Registered per-load because teardownObservers() drops every observer on this object.
        NotificationCenter.default.addObserver(self, selector: #selector(handleMemoryWarningNote),
                                               name: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil)
        #endif
    }

    #if canImport(UIKit)
    /// System memory warning: cap the current item's forward buffer (default 0 = "system decides", which
    /// on a high-bitrate stream is far too generous for a jetsam-bound app). 30s at even remux bitrates
    /// is a modest, survivable footprint, and AVFoundation releases already-buffered media beyond the new
    /// preference. Sticky for the rest of this item; the next loadFile mints a fresh item with defaults.
    @objc private func handleMemoryWarningNote() {
        guard let item, item.preferredForwardBufferDuration != 30 else { return }
        item.preferredForwardBufferDuration = 30
        DiagnosticsLog.log("avplayer", "memory warning: preferredForwardBufferDuration capped to 30s")
    }
    #endif

    private func handleStatus(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            isReady = true
            let dur = item.duration.seconds
            let seekable = dur.isFinite && dur > 0   // an indefinite duration is a live stream
            if seekable { emit(MPVProperty.duration, dur) }
            emit(MPVProperty.seekable, seekable)
            emit(MPVProperty.trackList, nil)   // chrome re-pulls via tracks()
            loadSelectionGroups()              // async; re-emits track-list once the groups resolve
            loadChapters()                     // async; re-emits track-list if the asset has chapter markers
            if let target = pendingSeek, seekable {
                pendingSeek = nil
                // FORWARD-ONLY REMUX: never apply a pre-start (resume) seek while the DV remux is mounted.
                // The remux produces bytes linearly and advertises no byte-range access, so seeking into
                // not-yet-produced bytes yields no frame and the chrome's start watchdog then demotes to
                // libmpv (HDR10 + no Atmos) on EVERY resume of a DV title. Start at 0 instead; the chrome
                // keeps its resume offset for progress-save continuity. Belt-and-braces with the chrome's
                // own remux-aware resume suppression (TVPlayerView.maybeResume).
                if isRemuxMounted {
                    DiagnosticsLog.log("dv", "dropped pre-start resume seek to \(Int(target))s: DV remux is forward-only, starting from 0")
                } else {
                    player.seek(to: CMTime(seconds: max(target, 0), preferredTimescale: 600))
                }
            }
            if !didStart {
                didStart = true
                // Explicit play() then pin the rate. With automaticallyWaitsToMinimizeStalling = false this
                // begins at the first samples instead of waiting on a buffer heuristic that never settles.
                player.play()
                player.rate = requestedRate
                DiagnosticsLog.log("avplayer", "readyToPlay -> play() rate=\(requestedRate) tcs=\(player.timeControlStatus.rawValue) waitReason=\(player.reasonForWaitingToPlay?.rawValue ?? "none")")
                // Variant-pick observability: whether the output pipeline is HDR-eligible, plus which master
                // variant latched. The DV variant and the range-unlabeled lifeboat differ by 100 kbps of
                // BANDWIDTH, so the access log's indicatedBitrate names the pick; it is -1 until the first
                // access-log event, which is logged as-is (fail-soft, not an error).
                let indicatedBitrate = item.accessLog()?.events.last?.indicatedBitrate ?? -1
                DiagnosticsLog.log("avplayer", "readyToPlay variant: eligibleForHDRPlayback=\(AVPlayer.eligibleForHDRPlayback) indicatedBitrate=\(Int(indicatedBitrate))")
                let host = (item.asset as? AVURLAsset)?.url.host ?? "?"
                VXProbeState.shared.setPlayer(state: "playing", source: host, engine: "avplayer")
                VXProbe.event("player", "ready \(host)")
                #if os(tvOS)
                // TRUE DOLBY VISION: re-assert the DV display mode with the REAL fps/size now that the item
                // is ready (the authoritative request already fired pre-attach in loadFile, per Tech Talk 503
                // ordering). Covers the remux lane (it only mounts for DV) AND any DV-flagged native route
                // (DV MP4/MOV/HLS); window:nil uses HDRDisplayMode's fallback window. reset() on stop()
                // returns the TV to its default mode.
                if isRemuxMounted || contentIsDolbyVision {
                    let size = item.presentationSize
                    let fps = item.tracks.first { $0.assetTrack?.mediaType == .video }?.assetTrack?.nominalFrameRate ?? 0
                    HDRDisplayMode.request(.dolbyVision, fps: Double(fps),
                                           width: Int(size.width), height: Int(size.height), in: nil)
                    VXProbe.log("dv", "AVPlayer ready -> re-asserted Dolby Vision display mode fps=\(fps) \(Int(size.width))x\(Int(size.height)) remux=\(isRemuxMounted)")
                }
                #endif
                // Case-C visibility (#76 b166): a NATIVE DV mp4 reached readyToPlay on ozdek's device, played
                // its Atmos audio, but produced NO video and misreported 3840x2160 as 1280x720. Dump every
                // video track's format description once per DV-flagged load so the next diagnostics export
                // names WHAT VideoToolbox refused (fourcc / coded dimensions / dvcC-dvvC presence / enabled).
                if isRemuxMounted || contentIsDolbyVision { logDVVideoTrackDiagnostics(item) }
            }
        case .failed:
            let ns = item.error as NSError?
            let underlying = (ns?.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain)#\($0.code)" } ?? "none"
            DiagnosticsLog.log("avplayer", "item FAILED: \(ns?.localizedDescription ?? "?") domain=\(ns?.domain ?? "?") code=\(ns?.code ?? 0) underlying=\(underlying)")
            VXProbe.event("player", "failed \(ns?.localizedDescription ?? "?")")
            // [dv] the demotion edge: the AVPlayer item failed and the chrome will fall back to libmpv HDR10.
            // For a DV source this is the tail of the [dv] trail (a remux fail-soft usually preceded it), so
            // grepping [dv] shows route -> mount -> classify/fallback-reason -> this demotion in order.
            VXProbe.log("dv", "AVPlayer item .failed -> demoting to libmpv HDR10: \(ns?.localizedDescription ?? "?")")
            guard !fatalErrorEmitted else { break }
            fatalErrorEmitted = true
            emit(MPVProperty.endFileError, item.error?.localizedDescription ?? "Playback failed")
        default:
            break
        }
    }

    /// Case-C diagnostics (#76 b166): once per DV-flagged load that reaches readyToPlay, log every video
    /// track's sample-entry fourcc, coded dimensions, natural size, enabled flag, and which sample
    /// description extension atoms (dvcC/dvvC/hvcC/...) are present. This is the data that separates "the
    /// file's DV carriage is one tvOS cannot decode" (audio over black, wrong presentationSize) from any
    /// app-side cause, without changing playback behavior in any way. Fail-soft: any load error just logs.
    private func logDVVideoTrackDiagnostics(_ item: AVPlayerItem) {
        let asset = item.asset
        Task { @MainActor in
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            if tracks.isEmpty {
                DiagnosticsLog.log("dv", "readyToPlay with ZERO video tracks (audio-only mount)")
                return
            }
            for track in tracks {
                let descs = (try? await track.load(.formatDescriptions)) ?? []
                let natural = (try? await track.load(.naturalSize)) ?? .zero
                let enabled = (try? await track.load(.isEnabled)) ?? true
                if descs.isEmpty {
                    DiagnosticsLog.log("dv", "video track id=\(track.trackID) has NO format description natural=\(Int(natural.width))x\(Int(natural.height)) enabled=\(enabled)")
                    continue
                }
                for desc in descs {
                    let sub = CMFormatDescriptionGetMediaSubType(desc)
                    var fourcc = ""
                    for shift in [24, 16, 8, 0] {
                        let byte = UInt8(truncatingIfNeeded: sub >> UInt32(shift))
                        fourcc.append(byte >= 32 && byte < 127 ? Character(UnicodeScalar(byte)) : "?")
                    }
                    let dims = CMVideoFormatDescriptionGetDimensions(desc)
                    var atoms = "none"
                    if let ext = CMFormatDescriptionGetExtension(
                        desc, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms),
                       let dict = ext as? [String: Any] {
                        atoms = dict.keys.sorted().joined(separator: ",")
                    }
                    DiagnosticsLog.log("dv", "video track id=\(track.trackID) fourcc=\(fourcc) coded=\(dims.width)x\(dims.height) natural=\(Int(natural.width))x\(Int(natural.height)) enabled=\(enabled) atoms=[\(atoms)]")
                }
            }
        }
    }

    @objc private func didPlayToEnd() {
        VXProbe.event("player", "endfile eof")
        emit(MPVProperty.endFileEof, nil)
    }
    @objc private func failedToEnd(_ note: Notification) {
        guard !fatalErrorEmitted else { return }
        fatalErrorEmitted = true
        let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        VXProbe.event("player", "endfile error \(err?.localizedDescription ?? "?")")
        emit(MPVProperty.endFileError, err?.localizedDescription ?? "Playback failed")
    }

    private func emit(_ name: String, _ data: Any?) {
        playDelegate?.propertyChange(propertyName: name, data: data)
    }

    /// Load the audio + subtitle selection groups off the asset (async, non-deprecated), cache them as
    /// [MPVTrack] (option index = id; mpv's -1 = off), then re-emit track-list so the chrome re-pulls.
    private func loadSelectionGroups() {
        guard let item = player.currentItem else { return }
        let asset = item.asset
        Task { @MainActor in
            let ag = try? await asset.loadMediaSelectionGroup(for: .audible)
            let sg = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard player.currentItem === item else { return }   // a newer file loaded meanwhile
            audioGroup = ag
            subGroup = sg
            audioTracks = ag.map { Self.mpvTracks(from: $0, type: "audio", item: item) } ?? []
            subTracks = sg.map { Self.mpvTracks(from: $0, type: "sub", item: item) } ?? []
            emit(MPVProperty.trackList, nil)
        }
    }

    private static func mpvTracks(from group: AVMediaSelectionGroup, type: String, item: AVPlayerItem) -> [MPVTrack] {
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { idx, opt in
            MPVTrack(id: idx, type: type, title: opt.displayName,
                     lang: opt.extendedLanguageTag ?? "", selected: opt == selected,
                     forced: opt.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
        }
    }

    private func teardownObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        // stop() is the normal teardown; this is a safety net if the engine is released without it.
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        observations.forEach { $0.invalidate() }
        NotificationCenter.default.removeObserver(self)   // matches teardownObservers(): drop AVPlayerItem note observers before dealloc
        remuxLoader?.invalidate()
        remuxHLSServer?.invalidate()
    }
}

extension AVPlayerEngineController: AVPictureInPictureControllerDelegate {}
#endif
