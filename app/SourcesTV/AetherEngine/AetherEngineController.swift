#if VORTX_AETHER_ENGINE
import AVFoundation
import UIKit
import VortXAetherKit

/// The AetherEngine lane behind the shared `PlayerEngine` contract. Property changes reach the chrome with
/// the same keys the libmpv controller emits, so `handleProperty()` runs unchanged against this engine.
/// AetherEngine itself lives in VortXAetherKit; this file only sees its plain-typed wrapper.
@MainActor
final class AetherEngineController: NSObject, PlayerEngine {
    let player: VortXAetherPlayer
    weak var playDelegate: MPVPlayerDelegate?
    /// Text cues drawn above the picture. Bitmap subtitles are not drawn by this lane yet.
    let subtitleOverlay = SubtitleOverlayView()

    private(set) var activeLoadToken: PlayerLoadToken?
    private var loadTask: Task<Void, Never>?
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
    private var isSeeking = false
    /// One-shot: the next load mounts paused (the surface was asked to start paused).
    var holdsNextLoadPaused = false
    /// The local copy of the selected add-on subtitle, and the request allowed to replace it.
    private var sidecarFile: URL?
    private var sidecarRevision = 0
    var contentIsDolbyVision = false
    var isFullPlayerPresentation = false
    private(set) var videoSizeMode = "fit"

    init(player: VortXAetherPlayer) {
        self.player = player
        super.init()
        wire()
    }

    private func emit(_ name: String, _ data: Any?) {
        guard let token = activeLoadToken else { return }
        playDelegate?.propertyChange(propertyName: name, data: data, loadToken: token)
    }

    private func wire() {
        player.onState = { [weak self] state in
            guard let self else { return }
            isSeeking = state == .seeking
            switch state {
            case .playing: emitPause(false)
            case .paused: emitPause(true)
            case .ended: emit(MPVProperty.endFileEof, nil)
            case .failed(let message): emit(MPVProperty.endFileError, message)
            case .idle, .loading, .seeking: break
            @unknown default: break
            }
        }
        player.onFirstFrame = { [weak self] in self?.hasFirstFrame = true }
        player.onTime = { [weak self] seconds in
            guard let self, let token = activeLoadToken, seconds.isFinite else { return }
            playDelegate?.propertyChange(propertyName: MPVProperty.timePos,
                data: PlayerTimePositionEvent(seconds: seconds, loadToken: token,
                                              positionSettled: hasFirstFrame && !isSeeking),
                loadToken: token)
        }
        player.onDuration = { [weak self] seconds in
            guard let self, seconds.isFinite, seconds > 0 else { return }
            emit(MPVProperty.duration, seconds)
            emit(MPVProperty.seekable, player.canSeek)
        }
        player.onBuffering = { [weak self] buffering in self?.emit(MPVProperty.pausedForCache, buffering) }
        player.onBufferedPosition = { [weak self] seconds in
            guard seconds.isFinite else { return }
            self?.emit(MPVProperty.demuxerCacheTime, seconds)
        }
        player.onTracksChanged = { [weak self] in self?.emit(MPVProperty.trackList, nil) }
        player.onSubtitleText = { [weak self] text in self?.subtitleOverlay.setText(text) }
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
        loadTask?.cancel()
        activeLoadToken = token
        lastPaused = nil
        hasFirstFrame = false
        isSeeking = false
        subtitleOverlay.setText(nil)
        guard audioSidecar == nil else {
            // A separate audio URL needs libmpv; report it so the chrome's failure handling can move on.
            emit(MPVProperty.endFileError, String(localized: "AetherEngine can't play a source with separate audio. Choose VortX Player for this source."))
            return token
        }
        let start = resumeOriginSeconds > 0 ? resumeOriginSeconds : nil
        let autoplay = !holdsNextLoadPaused
        holdsNextLoadPaused = false
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await player.load(url: url, headers: headers, startPosition: start, autoplay: autoplay)
                guard activeLoadToken == token, !Task.isCancelled else { return }
                player.setRate(speed)
            } catch is CancellationError {
            } catch {
                guard activeLoadToken == token else { return }
                emit(MPVProperty.endFileError, error.localizedDescription)
            }
        }
        return token
    }

    func invalidateLoadToken() {
        loadTask?.cancel()
        activeLoadToken = nil
    }

    func configureResumeOrigin(seconds: Double) {
        resumeOriginSeconds = seconds.isFinite ? max(0, seconds) : 0
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func togglePause() { lastPaused == true ? player.play() : player.pause() }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        Task { await player.seek(to: max(0, seconds)) }
    }
    func seek(by seconds: Double) { seek(to: player.currentTime + seconds) }
    func setSpeed(_ speed: Double) {
        self.speed = speed
        player.setRate(speed)
        emit(MPVProperty.speed, speed)
    }
    func stop() {
        loadTask?.cancel()
        player.stop()
        activeLoadToken = nil
        hasFirstFrame = false
        sidecarRevision &+= 1
        replaceSidecarFile(with: nil)
        subtitleOverlay.setText(nil)
    }

    func setVideoSize(_ mode: String) { videoSizeMode = mode }

    // MARK: Tracks and subtitles

    func tracks(ofType type: String) -> [MPVTrack] {
        switch type {
        case "audio":
            let active = player.activeAudioTrackID
            return player.audioTracks.map { track in
                MPVTrack(id: track.id, type: "audio", title: Self.title(track), lang: track.language,
                         selected: track.id == active, forced: track.isForced)
            }
        case "sub":
            let active = player.activeSubtitleTrackID
            return player.subtitleTracks.map { track in
                MPVTrack(id: track.id, type: "sub", title: Self.title(track), lang: track.language,
                         selected: track.id == active, forced: track.isForced)
            }
        default:
            return []
        }
    }

    private static func title(_ track: VortXAetherTrack) -> String {
        if !track.title.isEmpty { return track.title }
        if !track.language.isEmpty { return track.language }
        return track.codec.uppercased()
    }

    func setAudioTrack(_ id: Int) { player.selectAudioTrack(id: id) }
    func setSubtitleTrack(_ id: Int) {
        if id < 0 { player.clearSubtitle() } else { player.selectSubtitleTrack(id: id) }
    }
    /// Add-on subtitles download through the shared pinned transport, like the other lanes: HTTPS only, the
    /// connected address vetted, no redirects, size-capped. The engine opens only the local copy, never the
    /// add-on's URL, so its own fetcher never reaches an address the policy refused.
    func addExternalSubtitle(url: String, title: String, lang: String,
                             timeout: TimeInterval, completion: ((Bool) -> Void)?) {
        sidecarRevision &+= 1
        let revision = sidecarRevision
        guard let remote = URL(string: url), let token = activeLoadToken else { completion?(false); return }
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
                self.player.selectSidecarSubtitle(url: file, headers: nil)
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
        player.setSubtitleDelay(seconds)
    }
    func setAudioDelay(_ seconds: Double) { player.setAudioDelay(seconds) }
    func applySubtitleStyle() { subtitleOverlay.applyStyle() }
    func currentSubDelaySeconds() -> Double { subtitleDelay }

    // MARK: Facts and diagnostics

    func mediaDurationSeconds() -> Double { player.duration }
    func chapters() -> [MPVChapter] { [] }
    func mediaSummary() -> (width: Int, height: Int, audioCodec: String, audioChannels: Int) {
        let audio = player.audioTracks.first { $0.id == player.activeAudioTrackID }
        return (0, 0, audio?.codec ?? "", audio?.channels ?? 0)
    }
    func playbackStats() -> [(String, String)] {
        var rows: [(String, String)] = [("Engine", "AetherEngine"), ("Route", player.videoRoute),
                                        ("Video", player.videoFormat), ("Source video", player.sourceVideoFormat),
                                        ("Audio delivery", player.audioDelivery)]
        if let profile = player.sourceDolbyVisionProfile { rows.append(("Dolby Vision profile", String(profile))) }
        if let decoder = player.videoDecoder { rows.append(("Video decoder", decoder)) }
        if let decoder = player.audioDecoder { rows.append(("Audio decoder", decoder)) }
        return rows
    }

    func setHardwareDecoding(_ on: Bool) {}
    var hardwareDecoding: Bool { true }
    func setAudioOutputMode(_ mode: AudioOutputMode) {}

    func captureFrameJPEGData(maxWidth: CGFloat, completion: @escaping (Data?) -> Void) { completion(nil) }
    var hdrAvailable: Bool { player.videoFormat != "sdr" }
    var playbackPositionSeconds: Double { player.currentTime }

    func setVolume(_ volume0to100: Double) {
        userVolume = min(max(volume0to100, 0), 100)
        player.volume = isMuted ? 0 : userVolume / 100
    }
    func setMuted(_ muted: Bool) {
        isMuted = muted
        player.volume = muted ? 0 : userVolume / 100
    }
}
#endif
