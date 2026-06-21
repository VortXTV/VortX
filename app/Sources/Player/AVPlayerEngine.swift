#if os(iOS) || os(macOS)
import Foundation
import AVKit
import AVFoundation
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
/// iOS + macOS (#46): both route Dolby Vision / HLS here under the full PlayerScreen chrome via
/// `PlayerEngineRouter`, with a fail-soft fallback to libmpv if the AVPlayer item fails to load. tvOS keeps a
/// bare AVPlayerViewController (a focusable custom overlay fights the Siri-remote focus engine) and adds its
/// own in-player Episodes + Sources panels through `customInfoViewControllers`.
///
/// This conforms to `PlayerEngine` and emits events; rendering is owned by a sibling AVPlayerLayer host that
/// calls `attachLayer`, while this object owns playback + state only. Track selection, chapters, subtitle
/// styling, A/V delay, and trickplay are deliberately STUBBED here: AVFoundation has no 1:1 for several of
/// them, and the adversarial review said not to build them until a DV stream with multiple tracks is a
/// proven need, so they are filled in as that need lands. The plain `HLSPlayerView.AVPlayerModel` still
/// serves the bare iOS/tvOS HLS path that does not need the full chrome.
@MainActor
final class AVPlayerEngineController: NSObject, PlayerEngine {
    let player = AVPlayer()
    /// The chrome's Coordinator. Property changes are pushed here with the same string keys the libmpv
    /// controller emits, so `handleProperty()` runs unchanged against either engine.
    weak var playDelegate: MPVPlayerDelegate?

    private var item: AVPlayerItem?
    private var isReady = false
    private var didStart = false
    private var pendingSeek: Double?
    private var requestedRate: Float = 1
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var pipController: AVPictureInPictureController?
    private weak var playerLayer: AVPlayerLayer?
    private(set) var videoSizeMode = UserDefaults.standard.string(forKey: "stremiox.videoSize") ?? "original"
    // Cached AVMediaSelection groups + their MPVTrack views (loaded async once the item is ready). The
    // MPVTrack.id is the option's index in the group; mpv's -1 = off (deselect the group).
    private var audioGroup: AVMediaSelectionGroup?
    private var subGroup: AVMediaSelectionGroup?
    private var audioTracks: [MPVTrack] = []
    private var subTracks: [MPVTrack] = []

    // MARK: Loading + transport

    func loadFile(_ url: URL, headers: [String: String]?, live: Bool) {
        teardownObservers()
        isReady = false; didStart = false; pendingSeek = nil
        audioGroup = nil; subGroup = nil; audioTracks = []; subTracks = []
        // Claim .playback before play so PiP and locked-screen audio work, and advertise multichannel so the
        // system passes through Atmos (#78) and applies AirPods Spatial Audio (#88). Idempotent with the
        // libmpv path since only one engine is live at a time. macOS has no AVAudioSession (the system routes
        // audio automatically), so this is iOS/tvOS only.
        #if os(iOS) || os(tvOS)
        AVPlayerAudioSession.activateForMovie()
        #endif
        let options = (headers?.isEmpty ?? true) ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers!]
        let newItem = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        item = newItem
        player.replaceCurrentItem(with: newItem)
        player.allowsExternalPlayback = true   // AirPlay
        observe(newItem)
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
    }
    func seek(by seconds: Double) { seek(to: player.currentTime().seconds + seconds) }

    func setSpeed(_ speed: Double) {
        requestedRate = Float(speed)
        if player.timeControlStatus != .paused { player.rate = requestedRate }
    }

    func stop() {
        teardownObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        pipController?.delegate = nil
        pipController = nil
        item = nil
    }

    // MARK: Video sizing

    func setVideoSize(_ mode: String) {
        videoSizeMode = mode
        UserDefaults.standard.set(mode, forKey: "stremiox.videoSize")
        playerLayer?.videoGravity = Self.gravity(for: mode)
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
    func setSubtitleTrack(_ id: Int) { select(id, in: subGroup) }

    /// Select option `id` (its index in the group) on the current item, or deselect for mpv's -1 = off.
    private func select(_ id: Int, in group: AVMediaSelectionGroup?) {
        guard let group, let item = player.currentItem else { return }
        if id < 0 { item.select(nil, in: group) }
        else if id < group.options.count { item.select(group.options[id], in: group) }
    }

    /// External add-on subtitles need an AVAssetResourceLoaderDelegate to splice a remote WebVTT into the
    /// asset; not built yet (a later step), so report failure rather than silently doing nothing.
    func addExternalSubtitle(url: String, title: String, lang: String,
                             timeout: TimeInterval, completion: ((Bool) -> Void)?) { completion?(false) }
    func setSubDelay(_ seconds: Double) {}
    func setAudioDelay(_ seconds: Double) {}
    func applySubtitleStyle() {}

    // MARK: Chapters / media info (STUBBED this step)

    func chapters() -> [MPVChapter] { [] }
    func mediaSummary() -> (height: Int, audioCodec: String) { (0, "") }
    func playbackStats() -> [(String, String)] { [] }

    // MARK: Decode / audio routing (AVFoundation-managed; no-ops on this engine)

    func setHardwareDecoding(_ on: Bool) {}
    var hardwareDecoding: Bool { true }
    func setAudioOutputMode(_ mode: AudioOutputMode) {}

    // MARK: Trickplay / HDR

    func captureFrameJPEGData(maxWidth: CGFloat, completion: @escaping (Data?) -> Void) { completion(nil) }
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
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.handleStatus(item) }
        })
        observations.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.emit(MPVProperty.pausedForCache, item.isPlaybackBufferEmpty) }
        })
        observations.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in if item.isPlaybackLikelyToKeepUp { self?.emit(MPVProperty.pausedForCache, false) } }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in self?.emit(MPVProperty.pause, player.timeControlStatus == .paused) }
        })
        // ~4 Hz, matching the libmpv controller's coalesced time-pos cadence. Delivered on .main, so it runs
        // synchronously on the main actor (no extra Task hop that could fire after teardown nils the observer).
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.timeObserver != nil else { return }
                self.emit(MPVProperty.timePos, time.seconds)
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
            if let target = pendingSeek, seekable {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: max(target, 0), preferredTimescale: 600))
            }
            if !didStart { didStart = true; player.rate = requestedRate }
        case .failed:
            emit(MPVProperty.endFileError, item.error?.localizedDescription ?? "Playback failed")
        default:
            break
        }
    }

    @objc private func didPlayToEnd() { emit(MPVProperty.endFileEof, nil) }
    @objc private func failedToEnd(_ note: Notification) {
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
    }
}

extension AVPlayerEngineController: AVPictureInPictureControllerDelegate {}
#endif
