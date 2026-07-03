#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import AVKit
import AVFoundation
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
    private var remuxLoader: VortXRemuxResourceLoader?
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
        // MKV -> fMP4 remux, mount an AVURLAsset over the `vortxremux://` scheme backed by our resource-loader
        // delegate instead of loading the MKV directly (AVFoundation has no Matroska demuxer). Everything below
        // (KVO, track selection, trickplay tap) is identical; only the asset's source differs.
        let newAsset: AVURLAsset
        if PlayerEngineRouter.shouldDVRemux(url: url),
           let built = VortXRemuxResourceLoader.make(input: url, headers: headers) {
            remuxLoader = built.loader
            let asset = AVURLAsset(url: built.assetURL)
            asset.resourceLoader.setDelegate(built.loader, queue: remuxLoaderQueue)
            built.loader.start()
            newAsset = asset
            DiagnosticsLog.log("avplayer", "dv-remux mount host=\(url.host ?? "?") -> \(built.assetURL.scheme ?? "?")")
        } else {
            let options = (headers?.isEmpty ?? true) ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers!]
            newAsset = AVURLAsset(url: url, options: options)
        }
        let newItem = AVPlayerItem(asset: newAsset)
        item = newItem
        // Attach a pull-model frame tap so trickplay can grab the displayed frame on demand (see videoOutput).
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        newItem.add(output)
        videoOutput = output
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
        disableExternalSubtitle()
        player.pause()
        player.replaceCurrentItem(with: nil)
        pipController?.delegate = nil
        pipController = nil
        videoOutput = nil
        item = nil
    }

    /// Tear down the DV-for-MKV remux session (stop the remux thread + unblock any waiting loader request).
    /// Called before loading a new file and on stop(), so the remux never straddles two titles.
    private func teardownRemux() {
        remuxLoader?.invalidate()
        remuxLoader = nil
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
                self.emit(MPVProperty.timePos, time.seconds)
                self.updateSubtitleOverlay(atClock: time.seconds)   // sync external-sub overlay to the clock
                // YouTube-style buffered-ahead edge: the end of the loaded range that CONTAINS the playhead
                // (AVPlayer reports one or more loaded ranges). Emitting the same key libmpv uses lets the
                // scrubber render the grey band identically on both engines. Fail-soft: no matching range → 0.
                if let item = self.item {
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
    }

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
                player.seek(to: CMTime(seconds: max(target, 0), preferredTimescale: 600))
            }
            if !didStart {
                didStart = true
                // Explicit play() then pin the rate. With automaticallyWaitsToMinimizeStalling = false this
                // begins at the first samples instead of waiting on a buffer heuristic that never settles.
                player.play()
                player.rate = requestedRate
                DiagnosticsLog.log("avplayer", "readyToPlay -> play() rate=\(requestedRate) tcs=\(player.timeControlStatus.rawValue) waitReason=\(player.reasonForWaitingToPlay?.rawValue ?? "none")")
            }
        case .failed:
            let ns = item.error as NSError?
            let underlying = (ns?.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain)#\($0.code)" } ?? "none"
            DiagnosticsLog.log("avplayer", "item FAILED: \(ns?.localizedDescription ?? "?") domain=\(ns?.domain ?? "?") code=\(ns?.code ?? 0) underlying=\(underlying)")
            guard !fatalErrorEmitted else { break }
            fatalErrorEmitted = true
            emit(MPVProperty.endFileError, item.error?.localizedDescription ?? "Playback failed")
        default:
            break
        }
    }

    @objc private func didPlayToEnd() { emit(MPVProperty.endFileEof, nil) }
    @objc private func failedToEnd(_ note: Notification) {
        guard !fatalErrorEmitted else { return }
        fatalErrorEmitted = true
        let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
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
                     lang: opt.extendedLanguageTag ?? "", selected: opt == selected)
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
        remuxLoader?.invalidate()
    }
}

extension AVPlayerEngineController: AVPictureInPictureControllerDelegate {}
#endif
