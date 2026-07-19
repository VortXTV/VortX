import Foundation
import AVFoundation
import CoreMedia
#if canImport(UIKit)
import UIKit
#endif

/// The `PlayerEngine` conformer for the DIRECT Dolby Vision lane (see VortXDirectDVEngine.swift for the
/// pipeline and the architecture note). Mirrors `AVPlayerEngineController`'s contract with the shared
/// chrome: same Coordinator, same MPVProperty event bus, same external-subtitle overlay flow. The chrome
/// treats a fatal error from this engine as "demote to the AVPlayer remux lane" (TVPlayerView), so every
/// fail-fast in the pipeline lands on the lane that ships today, never on a dead screen.
@MainActor
final class VortXDirectDVEngineController: NSObject, PlayerEngine {

    weak var playDelegate: MPVPlayerDelegate?

    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var pipeline: VortXDirectDVPipeline?
    private var timeObserver: Any?

    private var classified: VortXDirectDVPipeline.Classified?
    private var requestedRate: Float = 1
    private var stopped = false
    private var fatalEmitted = false
    private var eofEmitted = false
    private var producerReachedEOF = false
    private var renderersAttached = false
    private var lastObservedTime: Double = -1
    private var lastProgressWall = Date()

    // External subtitles: the same VortX-owned overlay flow as the AVPlayer engine (AVFoundation-free,
    // so it works identically over a sample-buffer layer).
    private let subtitleRenderer = SubtitleCueRenderer()
    private weak var subtitleOverlay: SubtitleOverlayView?
    private var externalSubActive = false
    private var decodeFailureObserver: NSObjectProtocol?

    var contentIsDolbyVision = false
    private(set) var videoSizeMode: String = UserDefaults.standard.string(forKey: "stremiox.videoSize") ?? "original"

    // MARK: Flag plumbing

    /// Whether the direct lane's Profile 7 -> 8.1 conversion is enabled for THIS device. Resolution
    /// order mirrors PlayerEngineRouter.dvRemuxEnabled: explicit user default, then a RemoteConfig fleet
    /// value, then the hardware-tier baked default (ON only above the 3 GB boxes; the tier gate is the
    /// NuvioTVAppleTV take, see VortXDirectDVFormat.swift).
    static var directP7ConversionEnabled: Bool {
        if UserDefaults.standard.object(forKey: "stremiox.dvDirectP7") != nil {
            return UserDefaults.standard.bool(forKey: "stremiox.dvDirectP7")
        }
        let snap = RemoteConfig.snapshot
        let onWhenAbsentTrue = snap.isFeatureOn("dvDirectP7", default: true)
        let onWhenAbsentFalse = snap.isFeatureOn("dvDirectP7", default: false)
        if onWhenAbsentTrue == onWhenAbsentFalse { return onWhenAbsentTrue }
        return VortXDirectDVDeviceTier.recommendsProfile7Conversion
    }

    // MARK: Mount

    /// Bind the on-screen sample-buffer layer. Called by the host view BEFORE loadFile (mirrors
    /// AVPlayerEngineView's engine.attachLayer ordering).
    func attachLayer(_ layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
        layer.videoGravity = Self.gravity(for: videoSizeMode)
    }

    func attachSubtitleOverlay(_ overlay: SubtitleOverlayView) {
        subtitleOverlay = overlay
        overlay.setText(nil)
    }

    func loadFile(_ url: URL, headers: [String: String]?, live: Bool) {
        guard let layer = displayLayer else {
            emitFatal("direct DV lane: no display layer attached")
            return
        }
        // In-place source/episode switch: tear the previous pipeline down FIRST so its demux thread and
        // feeders never race the fresh mount into the shared renderers.
        if let old = pipeline {
            old.cancel()
            pipeline = nil
            synchronizer.rate = 0
            layer.flush()
            audioRenderer.flush()
        }
        stopped = false; fatalEmitted = false; eofEmitted = false; producerReachedEOF = false
        classified = nil; lastObservedTime = -1; lastProgressWall = Date()
        #if os(iOS) || os(tvOS)
        AVPlayerAudioSession.activateForMovie()
        #endif
        if !renderersAttached {
            synchronizer.addRenderer(layer)
            synchronizer.addRenderer(audioRenderer)
            renderersAttached = true
        }
        // A stream the pipeline classified fine can still be REJECTED by the decoder at first enqueue
        // (a malformed access unit, an hvcC/bitstream mismatch). That surfaces asynchronously as the
        // layer's failed-to-decode notification / .failed status, NOT as a pipeline error, so observe it
        // and demote through the same ladder instead of sitting on black until the chrome's 30s timeout.
        if decodeFailureObserver == nil {
            decodeFailureObserver = NotificationCenter.default.addObserver(
                forName: .AVSampleBufferDisplayLayerFailedToDecode, object: layer, queue: .main
            ) { [weak self] note in
                let err = note.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? Error
                Task { @MainActor [weak self] in
                    self?.emitFatal("video decode failed: \(err?.localizedDescription ?? "unknown decoder error")")
                }
            }
        }
        DiagnosticsLog.log("dv", "direct lane loadFile \(url.lastPathComponent) p7conv=\(Self.directP7ConversionEnabled)")
        let p = VortXDirectDVPipeline(input: url.absoluteString, headers: headers,
                                      convertP7Enabled: Self.directP7ConversionEnabled,
                                      displayLayer: layer, audioRenderer: audioRenderer)
        pipeline = p
        p.onClassified = { [weak self] c in self?.handleClassified(c) }
        p.onFatal = { [weak self] reason in self?.emitFatal(reason) }
        p.onEndOfStream = { [weak self] in self?.producerReachedEOF = true }
        p.onBuffering = { [weak self] buffering in
            guard let self, !self.stopped else { return }
            self.emit(MPVProperty.pausedForCache, buffering)
        }
        p.start()
    }

    private func handleClassified(_ c: VortXDirectDVPipeline.Classified) {
        guard !stopped, let pipeline else { return }
        classified = c
        #if os(tvOS)
        // Flip the panel into Dolby Vision BEFORE frames flow, exactly like the remux lane. The direct
        // lane always carries DV (the pipeline fails fast otherwise), so the range is unconditional.
        HDRDisplayMode.request(.dolbyVision, fps: c.fps, width: c.width, height: c.height, in: nil)
        #endif
        if c.durationSeconds > 0 { emit(MPVProperty.duration, c.durationSeconds) }
        emit(MPVProperty.seekable, true)
        emit(MPVProperty.trackList, nil)   // chrome re-pulls via tracks(), same as the AVPlayer engine
        // Roll the clock from the stream's own start; samples enqueue relative to source timestamps.
        synchronizer.setRate(requestedRate, time: CMTime(seconds: c.startSeconds, preferredTimescale: 90000))
        emit(MPVProperty.pause, requestedRate == 0)
        pipeline.beginFeeding()
        installTimeObserverIfNeeded()
    }

    private func installTimeObserverIfNeeded() {
        guard timeObserver == nil else { return }
        timeObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 90000),
            queue: .main
        ) { [weak self] time in
            guard let self, !self.stopped else { return }
            let t = time.seconds
            guard t.isFinite else { return }
            self.emit(MPVProperty.timePos, t)
            if self.externalSubActive { self.updateSubtitleOverlay(atClock: t) }
            if t != self.lastObservedTime { self.lastObservedTime = t; self.lastProgressWall = Date() }
            // Belt for the decode-failure notification: the renderers' own status flips cover OS versions
            // or paths where the notification does not post (and the audio renderer has no notification at
            // all). Either failure demotes through the ladder instead of sitting on black/silence.
            if let layer = self.displayLayer, layer.status == .failed {
                self.emitFatal("video pipeline failed: \(layer.error?.localizedDescription ?? "layer status .failed")")
            }
            if self.audioRenderer.status == .failed {
                self.emitFatal("audio renderer failed: \(self.audioRenderer.error?.localizedDescription ?? "status .failed")")
            }
            self.maybeEmitEOF(at: t)
        }
    }

    /// End-of-file: the producer hit EOF, both queues drained, and either the clock passed the known
    /// duration or it stalled at the tail (unknown/short duration). One-shot.
    private func maybeEmitEOF(at t: Double) {
        guard !eofEmitted, producerReachedEOF, let pipeline, pipeline.isDrained else { return }
        let dur = classified?.durationSeconds ?? 0
        let pastDuration = dur > 0 && t >= dur - 0.75
        let stalledAtTail = Date().timeIntervalSince(lastProgressWall) > 2.0
        guard pastDuration || stalledAtTail else { return }
        eofEmitted = true
        emit(MPVProperty.endFileEof, nil)
    }

    // MARK: Transport

    func play() {
        requestedRate = max(requestedRate, 1)
        synchronizer.rate = requestedRate
        emit(MPVProperty.pause, false)
    }

    func pause() {
        synchronizer.rate = 0
        emit(MPVProperty.pause, true)
    }

    func togglePause() { synchronizer.rate == 0 ? play() : pause() }

    func seek(to seconds: Double) {
        guard let pipeline else { return }
        var target = max(0, seconds)
        if let dur = classified?.durationSeconds, dur > 0 { target = min(target, max(0, dur - 1)) }
        eofEmitted = false
        pipeline.requestSeek(to: target)
        displayLayer?.flush()
        audioRenderer.flush()
        let wasRate = synchronizer.rate
        synchronizer.setRate(wasRate == 0 ? 0 : requestedRate, time: CMTime(seconds: target, preferredTimescale: 90000))
        emit(MPVProperty.timePos, target)
        if externalSubActive { updateSubtitleOverlay(atClock: target) }
    }

    func seek(by seconds: Double) { seek(to: synchronizer.currentTime().seconds + seconds) }

    func setSpeed(_ speed: Double) {
        requestedRate = Float(max(0.25, min(speed, 4)))
        if synchronizer.rate != 0 {
            synchronizer.setRate(requestedRate, time: synchronizer.currentTime())
        }
        emit(MPVProperty.speed, Double(requestedRate))
    }

    var playbackPositionSeconds: Double {
        let t = synchronizer.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let obs = decodeFailureObserver { NotificationCenter.default.removeObserver(obs); decodeFailureObserver = nil }
        pipeline?.cancel()
        pipeline = nil
        if let obs = timeObserver { synchronizer.removeTimeObserver(obs); timeObserver = nil }
        synchronizer.rate = 0
        displayLayer?.flushAndRemoveImage()
        audioRenderer.flush()
        subtitleRenderer.clear()
        subtitleOverlay?.setText(nil)
        DiagnosticsLog.log("dv", "direct lane stopped")
    }

    // MARK: Video sizing

    func setVideoSize(_ mode: String) {
        videoSizeMode = mode
        UserDefaults.standard.set(mode, forKey: "stremiox.videoSize")
        displayLayer?.videoGravity = Self.gravity(for: mode)
    }

    private static func gravity(for mode: String) -> AVLayerVideoGravity {
        switch mode {
        case "zoom", "fill": return .resizeAspectFill
        case "stretch":      return .resize
        default:             return .resizeAspect
        }
    }

    // MARK: Tracks + subtitles

    func tracks(ofType type: String) -> [MPVTrack] {
        guard let c = classified else { return [] }
        if type == "audio" {
            return [MPVTrack(id: 1, type: "audio", title: c.audioTitle, lang: c.audioLang, selected: true)]
        }
        return []   // no embedded subtitle extraction on the direct lane (external subs work, below)
    }

    /// Single stream-copied audio track; there is nothing to switch to (the chrome's row shows one entry).
    func setAudioTrack(_ id: Int) {}

    /// Only "off" is meaningful: the direct lane exposes no embedded text tracks.
    func setSubtitleTrack(_ id: Int) {
        if id < 0 { disableExternalSubtitle() }
    }

    func addExternalSubtitle(url: String, title: String, lang: String,
                             timeout: TimeInterval, completion: ((Bool) -> Void)?) {
        guard let remote = URL(string: url) else { completion?(false); return }
        let finish: (Bool) -> Void = { ok in DispatchQueue.main.async { completion?(ok) } }
        SubtitleFileFetcher.fetch(remote, timeout: timeout) { [weak self] data in
            guard let data else { finish(false); return }
            let cues = SubtitleCueRenderer.parse(data: data)
            guard !cues.isEmpty else { finish(false); return }
            Task { @MainActor in
                guard let self, !self.stopped else { finish(false); return }
                self.subtitleRenderer.load(cues: cues)
                self.externalSubActive = true
                self.subtitleOverlay?.applyStyle()
                self.updateSubtitleOverlay(atClock: self.playbackPositionSeconds)
                finish(true)
            }
        }
    }

    private func disableExternalSubtitle() {
        externalSubActive = false
        subtitleRenderer.clear()
        subtitleOverlay?.setText(nil)
    }

    func setSubDelay(_ seconds: Double) {
        subtitleRenderer.offset = seconds
        if externalSubActive { updateSubtitleOverlay(atClock: playbackPositionSeconds) }
    }

    func setAudioDelay(_ seconds: Double) {}   // no audio-offset control on the sample-buffer pipeline

    func applySubtitleStyle() { subtitleOverlay?.applyStyle() }

    func currentSubDelaySeconds() -> Double { subtitleRenderer.offset }

    private func updateSubtitleOverlay(atClock clock: Double) {
        guard externalSubActive else { return }
        subtitleOverlay?.setText(subtitleRenderer.activeText(atClock: clock))
    }

    // MARK: Info surfaces

    func chapters() -> [MPVChapter] { [] }

    func mediaSummary() -> (width: Int, height: Int, audioCodec: String) {
        guard let c = classified else { return (0, 0, "?") }
        return (c.width, c.height, "\(c.audioCodec)/\(c.audioChannels)ch")
    }

    func containerFrameRate() -> Double { classified?.fps ?? 0 }

    func mediaDurationSeconds() -> Double { classified?.durationSeconds ?? 0 }

    func playbackStats() -> [(String, String)] {
        var rows: [(String, String)] = []
        if let c = classified {
            rows.append(("Engine", "Direct DV (sample buffer)"))
            let profile = c.convertingP7 ? "7 -> 8.1 (converted)" : String(c.dvProfileSource)
            rows.append(("Dolby Vision", "Profile \(profile)"))
            rows.append(("Video", "\(c.width)x\(c.height) HEVC @ \(String(format: "%.3f", c.fps))"))
            rows.append(("Audio", "\(c.audioCodec) \(c.audioChannels)ch (passthrough)"))
        }
        if let p = pipeline {
            let d = p.queueDepth
            rows.append(("Queue", "v:\(d.video) a:\(d.audio) \(d.bytes >> 20) MiB"))
        }
        if let layer = displayLayer, layer.status == .failed, let err = layer.error {
            rows.append(("Layer error", err.localizedDescription))
        }
        return rows
    }

    // MARK: Decode + audio routing

    func setHardwareDecoding(_ on: Bool) {}   // VideoToolbox inside the sample-buffer pipeline; always hardware
    var hardwareDecoding: Bool { true }
    func setAudioOutputMode(_ mode: AudioOutputMode) {}   // the system negotiates the route for compressed enqueue

    // MARK: Trickplay + HDR

    /// No decoded-pixel tap exists on the compressed enqueue path, so trickplay capture is unavailable on
    /// this lane (the remux and libmpv lanes keep capturing; this lane is flag-gated and DV-only).
    func captureFrameJPEGData(maxWidth: CGFloat, completion: @escaping (Data?) -> Void) {
        completion(nil)
    }

    var hdrAvailable: Bool { true }

    // MARK: Volume

    func setVolume(_ volume0to100: Double) {
        audioRenderer.volume = Float(max(0, min(volume0to100, 100)) / 100)
    }

    func setMuted(_ muted: Bool) { audioRenderer.isMuted = muted }

    #if os(iOS)
    func setOrientation(landscape: Bool) {}   // the hosting view controller drives device orientation
    #endif

    // MARK: Failure + event plumbing

    private func emitFatal(_ reason: String) {
        guard !stopped, !fatalEmitted else { return }
        fatalEmitted = true
        VXProbe.log("dv", "direct lane fatal: \(reason)")
        emit(MPVProperty.endFileError, reason)
    }

    private func emit(_ name: String, _ data: Any?) {
        guard !stopped else { return }
        playDelegate?.propertyChange(propertyName: name, data: data)
    }
}
