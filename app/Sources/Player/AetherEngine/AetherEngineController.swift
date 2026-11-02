#if VORTX_AETHER_ENGINE
import Foundation
#if os(iOS)
import UIKit
#endif

/// The AetherEngine lane behind the shared `PlayerEngine` contract. Property changes reach the chrome with
/// the same keys the libmpv controller emits, so `handleProperty()` runs unchanged against this engine.
/// AetherEngine itself lives in VortXAetherKit, loaded at runtime; this file only sees `VortXAetherBridging`.
@MainActor
final class AetherEngineController: NSObject, PlayerEngine {
    /// Nil when the engine could not start on this device; the first load then reports `startError`, which the
    /// chrome answers by handing the source to libmpv.
    let player: (any VortXAetherBridging)?
    private let startError: String?
    weak var playDelegate: MPVPlayerDelegate?
    /// Text cues drawn above the picture. Bitmap subtitles are not drawn by this lane yet.
    let subtitleOverlay = SubtitleOverlayView()

    private(set) var activeLoadToken: PlayerLoadToken?
    private var resumeOriginSeconds = 0.0
    private var speed = 1.0
    private var subtitleDelay = 0.0
    private var userVolume = 100.0
    private var isMuted = false
    private var lastPaused: Bool?
    /// Position ticks count as settled only once this load has shown a frame and no seek is running. The
    /// engine's clock can sit on a resume or seek target before any frame, and the chrome treats a settled
    /// position above zero as "playback started", which retires its no-frame watchdogs.
    private var hasFirstFrame = false
    private var lastSeekable: Bool?
    /// One-shot: the next load mounts paused (the surface was asked to start paused).
    var holdsNextLoadPaused = false
    /// The local copy of the selected add-on subtitle, and the request allowed to replace it.
    private var sidecarFile: URL?
    private var sidecarRevision = 0
    var contentIsDolbyVision = false
    var isFullPlayerPresentation = false
    private(set) var videoSizeMode = "fit"

    override init() {
        do {
            player = try AetherEngineLoader.makePlayer()
            startError = nil
        } catch {
            player = nil
            startError = error.localizedDescription
        }
        super.init()
        wire()
    }

    private func emit(_ name: String, _ data: Any?) {
        guard let token = activeLoadToken else { return }
        playDelegate?.propertyChange(propertyName: name, data: data, loadToken: token)
    }

    private func wire() {
        guard let player else { return }
        player.onState = { [weak self] (state: VortXAetherBridgeState, message: String?) in
            guard let self else { return }
            switch state {
            case .playing: emitPause(false)
            case .paused: emitPause(true)
            case .ended: emit(MPVProperty.endFileEof, nil)
            case .failed: emit(MPVProperty.endFileError, message ?? "AetherEngine stopped")
            case .idle, .loading, .seeking: break
            }
        }
        player.onFirstFrame = { [weak self] in self?.hasFirstFrame = true }
        player.onTime = { [weak self] (seconds: Double) in
            guard let self, let token = activeLoadToken, seconds.isFinite else { return }
            emitSeekability()
            playDelegate?.propertyChange(propertyName: MPVProperty.timePos,
                data: PlayerTimePositionEvent(seconds: seconds, loadToken: token,
                                              positionSettled: hasFirstFrame && self.player?.positionIsSettled == true),
                loadToken: token)
        }
        player.onDuration = { [weak self] (seconds: Double) in
            guard let self, seconds.isFinite, seconds > 0 else { return }
            emit(MPVProperty.duration, seconds)
            emitSeekability()
        }
        player.onBuffering = { [weak self] (buffering: Bool) in self?.emit(MPVProperty.pausedForCache, buffering) }
        player.onBufferedPosition = { [weak self] (seconds: Double) in
            guard seconds.isFinite else { return }
            self?.emit(MPVProperty.demuxerCacheTime, seconds)
        }
        player.onTracksChanged = { [weak self] in self?.emit(MPVProperty.trackList, nil) }
        player.onSubtitleText = { [weak self] (text: String?) in
            guard let self, activeLoadToken != nil else { return }
            subtitleOverlay.setText(text)
        }
    }

    private func emitSeekability() {
        guard activeLoadToken != nil else { return }
        let seekable = player?.canSeek ?? false
        guard seekable != lastSeekable else { return }
        lastSeekable = seekable
        emit(MPVProperty.seekable, seekable)
    }

    private func emitPause(_ paused: Bool) {
        guard paused != lastPaused else { return }
        lastPaused = paused
        emit(MPVProperty.pause, paused)
    }

    // MARK: Loading and transport

    @discardableResult
    func loadFile(_ url: URL, headers: [String: String]?, live: Bool, audioSidecar: URL?,
                  reusing loadToken: PlayerLoadToken?) -> PlayerLoadToken {
        let token = loadToken ?? PlayerLoadToken()
        // Configuration belongs to this issue, including an issue that cannot start.
        let start = resumeOriginSeconds > 0 ? NSNumber(value: resumeOriginSeconds) : nil
        resumeOriginSeconds = 0
        let autoplay = !holdsNextLoadPaused
        holdsNextLoadPaused = false
        // A retry may retain its logical token, but never an older subtitle request.
        activeLoadToken = nil
        sidecarRevision &+= 1
        player?.cancelLoad()
        activeLoadToken = token
        lastPaused = nil
        hasFirstFrame = false
        lastSeekable = nil
        subtitleOverlay.setText(nil)
        guard let player else {
            // Reported on the next turn, after the surface finishes mounting, like any engine's own failure.
            let reason = startError ?? "AetherEngine could not start"
            Task { @MainActor [weak self] in
                guard let self, activeLoadToken == token else { return }
                emit(MPVProperty.endFileError, reason)
            }
            return token
        }
        guard audioSidecar == nil else {
            // A separate audio URL needs libmpv; report it so the chrome's failure handling can move on.
            emit(MPVProperty.endFileError, String(localized: "AetherEngine can't play a source with separate audio. Choose VortX Player for this source."))
            return token
        }
        player.load(url: url, headers: headers, live: live, startPosition: start, autoplay: autoplay) { [weak self] (error: NSError?) in
            guard let self, activeLoadToken == token else { return }
            guard let error else {
                emitSeekability()
                self.player?.setRate(speed)
                return
            }
            if error.domain == VortXAetherBridgeErrorDomain, error.code == VortXAetherBridgeErrorCode.cancelled.rawValue {
                return
            }
            emit(MPVProperty.endFileError, error.localizedDescription)
        }
        return token
    }

    func invalidateLoadToken() {
        activeLoadToken = nil
        sidecarRevision &+= 1
        player?.cancelLoad()
        subtitleOverlay.setText(nil)
    }

    func configureResumeOrigin(seconds: Double) {
        resumeOriginSeconds = seconds.isFinite ? max(0, seconds) : 0
    }

    func play() { player?.play() }
    func pause() { player?.pause() }
    func togglePause() { lastPaused == true ? player?.play() : player?.pause() }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        player?.seek(to: max(0, seconds), completion: nil)
    }
    func seek(by seconds: Double) { seek(to: (player?.currentTime ?? 0) + seconds) }
    func setSpeed(_ speed: Double) {
        self.speed = speed
        player?.setRate(speed)
        emit(MPVProperty.speed, speed)
    }
    func stop() {
        // Retire callback authority before synchronous engine teardown can publish.
        activeLoadToken = nil
        sidecarRevision &+= 1
        player?.stop()
        hasFirstFrame = false
        resumeOriginSeconds = 0
        holdsNextLoadPaused = false
        replaceSidecarFile(with: nil)
        subtitleOverlay.setText(nil)
    }

    func setVideoSize(_ mode: String) {
        videoSizeMode = mode
        UserDefaults.standard.set(mode, forKey: "stremiox.videoSize")
        player?.setVideoSize(mode)
    }

    // MARK: Tracks and subtitles

    /// One engine track, read from the bridge's plain dictionary.
    private struct Track {
        let id: Int
        let title: String
        let language: String
        let codec: String
        let channels: Int
        let isForced: Bool

        init?(_ values: [String: Any]) {
            guard let id = values[VortXAetherBridgeTrackKey.id] as? Int else { return nil }
            self.id = id
            title = values[VortXAetherBridgeTrackKey.title] as? String ?? ""
            language = values[VortXAetherBridgeTrackKey.language] as? String ?? ""
            codec = values[VortXAetherBridgeTrackKey.codec] as? String ?? ""
            channels = values[VortXAetherBridgeTrackKey.channels] as? Int ?? 0
            isForced = values[VortXAetherBridgeTrackKey.isForced] as? Bool ?? false
        }

        var displayTitle: String {
            if !title.isEmpty { return title }
            if !language.isEmpty { return language }
            return codec.uppercased()
        }
    }

    private var audioTracks: [Track] { (player?.audioTracks ?? []).compactMap(Track.init) }
    private var subtitleTracks: [Track] { (player?.subtitleTracks ?? []).compactMap(Track.init) }

    func tracks(ofType type: String) -> [MPVTrack] {
        switch type {
        case "audio":
            let active = player?.activeAudioTrackID?.intValue
            return audioTracks.map { track in
                MPVTrack(id: track.id, type: "audio", title: track.displayTitle, lang: track.language,
                         selected: track.id == active, forced: track.isForced)
            }
        case "sub":
            let active = player?.activeSubtitleTrackID?.intValue
            return subtitleTracks.map { track in
                MPVTrack(id: track.id, type: "sub", title: track.displayTitle, lang: track.language,
                         selected: track.id == active, forced: track.isForced)
            }
        default:
            return []
        }
    }

    func setAudioTrack(_ id: Int) { player?.selectAudioTrack(id: id) }
    func setSubtitleTrack(_ id: Int) {
        // A manual Off/embedded pick supersedes any still-downloading add-on file.
        sidecarRevision &+= 1
        if id < 0 { player?.clearSubtitle() } else { player?.selectSubtitleTrack(id: id) }
    }
    /// Add-on subtitles download through the shared pinned transport, like the other lanes: HTTPS only, the
    /// connected address vetted, no redirects, size-capped. The engine opens only the local copy, never the
    /// add-on's URL, so its own fetcher never reaches an address the policy refused.
    func addExternalSubtitle(url: String, title: String, lang: String,
                             timeout: TimeInterval, completion: ((Bool) -> Void)?) {
        sidecarRevision &+= 1
        let revision = sidecarRevision
        guard let remote = URL(string: url), let token = activeLoadToken, player != nil else { completion?(false); return }
        let finish: @MainActor @Sendable (Bool) -> Void = { ok in completion?(ok) }
        SubtitleFileFetcher.fetch(remote, timeout: timeout) { [weak self] data in
            let file = data.flatMap { Self.writeSidecar($0, remote: remote) }
            Task { @MainActor in
                guard let self, let file, self.activeLoadToken == token, self.sidecarRevision == revision else {
                    if let file { try? FileManager.default.removeItem(at: file) }
                    finish(false)
                    return
                }
                self.replaceSidecarFile(with: file)
                self.player?.selectSidecarSubtitle(url: file, headers: nil)
                finish(true)
            }
        }
    }

    private func replaceSidecarFile(with file: URL?) {
        if let sidecarFile, sidecarFile != file { try? FileManager.default.removeItem(at: sidecarFile) }
        sidecarFile = file
    }

    /// The fetched bytes as a temporary file the engine can open, keeping the add-on's extension when it
    /// names a subtitle format (the engine also probes the content).
    nonisolated private static func writeSidecar(_ data: Data, remote: URL) -> URL? {
        let known: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "sup"]
        let pathExtension = remote.pathExtension.lowercased()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aether-subtitles", isDirectory: true)
        let file = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(known.contains(pathExtension) ? pathExtension : "srt")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
    func setSubDelay(_ seconds: Double) {
        subtitleDelay = seconds
        player?.setSubtitleDelay(seconds)
    }
    func setAudioDelay(_ seconds: Double) { player?.setAudioDelay(seconds) }
    func applySubtitleStyle() { subtitleOverlay.applyStyle() }
    func currentSubDelaySeconds() -> Double { subtitleDelay }

    // MARK: Facts and diagnostics

    func mediaDurationSeconds() -> Double { activeLoadToken == nil ? 0 : (player?.duration ?? 0) }
    func chapters() -> [MPVChapter] {
        guard activeLoadToken != nil else { return [] }
        return (player?.mediaChapters ?? []).compactMap { values in
            guard let start = values["start"] as? Double, start.isFinite, start >= 0 else { return nil }
            return MPVChapter(title: values["title"] as? String ?? "", start: start)
        }
    }
    func containerFrameRate() -> Double {
        guard activeLoadToken != nil, let fps = player?.videoFrameRate?.doubleValue,
              fps.isFinite, fps > 0 else { return 0 }
        return fps
    }
    func mediaSummary() -> (width: Int, height: Int, audioCodec: String, audioChannels: Int) {
        guard activeLoadToken != nil else { return (0, 0, "", 0) }
        let active = player?.activeAudioTrackID?.intValue
        let audio = audioTracks.first { $0.id == active }
        return (player?.videoWidth ?? 0, player?.videoHeight ?? 0, audio?.codec ?? "", audio?.channels ?? 0)
    }
    func playbackMetadataFacts() -> PlaybackMetadataFacts {
        guard activeLoadToken != nil, let player else { return PlaybackMetadataFacts() }
        var facts = PlaybackMetadataFacts()
        facts.width = max(0, player.videoWidth)
        facts.height = max(0, player.videoHeight)
        facts.dynamicRange = PlaybackMetadataFacts.DynamicRange(rawValue: player.videoDynamicRange) ?? .unknown
        let selectedBefore = player.activeAudioTrackID?.intValue
        let audio = audioTracks.first { $0.id == selectedBefore }
        if let audio, PlaybackMetadataFacts.audioSelectionMatches(selectedRowID: audio.id,
            beforeID: selectedBefore, afterID: player.activeAudioTrackID?.intValue) {
            facts.audioSelected = true
            facts.audioLanguage = audio.language
            facts.audioCodec = audio.codec
            facts.audioChannels = audio.channels
        }
        return facts
    }
    func playbackStats() -> [(String, String)] {
        guard let player else { return [("Engine", "AetherEngine (not started)")] }
        var rows: [(String, String)] = [("Engine", "AetherEngine"), ("Route", player.videoRoute),
                                        ("Video", player.videoFormat), ("Source video", player.sourceVideoFormat),
                                        ("Audio delivery", player.audioDelivery)]
        if let profile = player.sourceDolbyVisionProfile { rows.append(("Dolby Vision profile", profile.stringValue)) }
        if let decoder = player.videoDecoder { rows.append(("Video decoder", decoder)) }
        if let decoder = player.audioDecoder { rows.append(("Audio decoder", decoder)) }
        return rows
    }

    func setHardwareDecoding(_ on: Bool) {}
    var hardwareDecoding: Bool { true }
    func setAudioOutputMode(_ mode: AudioOutputMode) {}

    func captureFrameJPEGData(maxWidth: CGFloat, completion: @escaping (Data?) -> Void) { completion(nil) }
    var hdrAvailable: Bool {
        guard activeLoadToken != nil, let player else { return false }
        return ["pq", "hlg", "dolbyVision"].contains(player.videoDynamicRange)
    }
    var playbackPositionSeconds: Double { player?.currentTime ?? 0 }

    func setVolume(_ volume0to100: Double) {
        userVolume = min(max(volume0to100, 0), 100)
        player?.volume = isMuted ? 0 : userVolume / 100
    }
    func setMuted(_ muted: Bool) {
        isMuted = muted
        player?.volume = muted ? 0 : userVolume / 100
    }

    #if os(iOS)
    /// Force the player into landscape (or back to portrait) for viewers who keep auto-rotation off, the same
    /// scene geometry request the libmpv lane makes.
    func setOrientation(landscape: Bool) {
        guard let window = subtitleOverlay.window, let scene = window.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
    #endif
}
#endif
