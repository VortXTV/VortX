import AVFoundation
import Combine
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
// Internal: AetherEngine and its AetherLib* FFmpeg headers stay inside this framework, apart from the apps'
// MPVKit FFmpeg headers.
internal import AetherEngine

// The only file that imports AetherEngine. This framework is where the engine is linked, so its FFmpeg
// references resolve to the AetherLib* frameworks here instead of the app's static MPVKit FFmpeg. The apps
// reach it only through `VortXAetherBridgePlayer` (VortXAetherBridging.swift), loaded at runtime.

/// One audio or subtitle track, in plain values.
public struct VortXAetherTrack: Sendable, Equatable {
    public let id: Int
    public let title: String
    public let language: String
    public let codec: String
    public let channels: Int
    public let isDefault: Bool
    public let isForced: Bool
}

/// The engine's transport state.
public enum VortXAetherState: Sendable, Equatable {
    case idle, loading, playing, paused, seeking, ended
    case failed(String)
}

@MainActor
public final class VortXAetherPlayer {
    /// The view the engine presents into. Host it full screen; the engine swaps its layer per session.
    public let view: VortXAetherBridgeView

    public var onState: ((VortXAetherState) -> Void)?
    /// Playback clock, the scrubber axis.
    public var onTime: ((Double) -> Void)?
    public var onDuration: ((Double) -> Void)?
    public var onBuffering: ((Bool) -> Void)?
    /// Position buffered ahead on the same axis as `onTime`.
    public var onBufferedPosition: ((Double) -> Void)?
    public var onTracksChanged: (() -> Void)?
    public var onFirstFrame: (() -> Void)?
    /// The text of the active subtitle cue at the displayed frame, or nil when none is showing.
    public var onSubtitleText: ((String?) -> Void)?

    private let engine: AetherEngine
    private var subscriptions: Set<AnyCancellable> = []
    private var cues: [SubtitleCue] = []
    private var lastSubtitleText: String?
    private var subtitleDelaySeconds = 0.0
    /// Invalidates next-turn inventory notifications when their session retires.
    private var observationGeneration = 0
    private var isStopping = false
    /// A snapshot paired with onTime, never inferred from a falling seek level.
    public private(set) var positionIsSettled = false
    private var timePublicationTask: Task<Void, Never>?
    private var latestSeekID: UInt64?
    private var seekNeedsLanding = false
    private var landedPosition: Double?
    private var clockPublicationRevision = 0
    private var deferredSupersessionRevision: Int?

    public init() throws {
        engine = try AetherEngine()
        let playerView = AetherPlayerView(frame: .zero)
        view = playerView
        engine.bind(view: playerView)
        observe()
    }

    // MARK: Loading and transport

    /// `autoplay` false holds the new session paused at mount; `play()` starts it later.
    public func load(url: URL, headers: [String: String]?, live: Bool, startPosition: Double?, autoplay: Bool = true) async throws {
        observationGeneration &+= 1
        resetPositionObservation()
        var options = LoadOptions()
        options.httpHeaders = headers ?? [:]
        options.autoplay = autoplay
        options.isLive = live
        _ = try await engine.load(url: url, startPosition: startPosition, options: options)
    }

    public func play() { engine.play() }
    public func pause() { engine.pause() }
    public func stop() {
        observationGeneration &+= 1
        isStopping = true
        resetPositionObservation()
        defer { isStopping = false }
        engine.stop()
        cues = []
        publishSubtitle(nil)
    }
    public func seek(to seconds: Double) async { await engine.seek(to: seconds) }
    public func setRate(_ rate: Double) { engine.setRate(Float(rate)) }
    public func setVideoSize(_ mode: String) {
        switch mode {
        case "zoom", "fill": engine.videoGravity = .resizeAspectFill
        case "stretch": engine.videoGravity = .resize
        default: engine.videoGravity = .resizeAspect
        }
    }
    /// Seconds; positive presents audio later than video. The engine clamps to +/-2 s.
    public func setAudioDelay(_ seconds: Double) { engine.setAudioDelay(seconds) }
    /// 0...1.
    public var volume: Double {
        get { Double(engine.volume) }
        set { engine.volume = Float(min(max(newValue, 0), 1)) }
    }

    public var currentTime: Double { engine.currentTime }
    public var duration: Double { engine.duration }
    public var canSeek: Bool { engine.canSeek }
    public var isSeeking: Bool { engine.isSeeking }
    public var bufferedPosition: Double { engine.bufferedPosition }

    // MARK: Tracks

    public var audioTracks: [VortXAetherTrack] { engine.audioTracks.map(Self.track) }
    public var subtitleTracks: [VortXAetherTrack] { engine.subtitleTracks.map(Self.track) }
    public var activeAudioTrackID: Int? { engine.activeAudioTrackIndex }
    public var activeSubtitleTrackID: Int? { engine.activeSubtitleTrackIndex }

    public func selectAudioTrack(id: Int) { engine.selectAudioTrack(index: id) }
    public func selectSubtitleTrack(id: Int) { engine.selectSubtitleTrack(index: id) }
    public func clearSubtitle() {
        engine.clearSubtitle()
        publishSubtitle(nil)
    }
    public func selectSidecarSubtitle(url: URL, headers: [String: String]?) {
        engine.selectSidecarSubtitle(url: url, httpHeaders: headers)
    }
    /// Seconds; positive shows cues later.
    public func setSubtitleDelay(_ seconds: Double) {
        guard seconds.isFinite else { return }
        subtitleDelaySeconds = seconds
        updateSubtitle(at: engine.sourceTime)
    }

    // MARK: Diagnostics

    public var videoWidth: Int { Int(engine.sourceVideoWidth) }
    public var videoHeight: Int { Int(engine.sourceVideoHeight) }
    public var videoFrameRate: Double? { engine.sourceVideoFrameRate }
    public var videoDynamicRange: String {
        switch engine.videoFormat {
        case .sdr: return "sdr"
        case .hdr10, .hdr10Plus: return "pq"
        case .hlg: return "hlg"
        case .dolbyVision: return "dolbyVision"
        @unknown default: return "unknown"
        }
    }
    public var mediaChapters: [[String: Any]] {
        engine.mediaChapters.map { ["title": $0.name, "start": $0.startSeconds] }
    }
    public var videoFormat: String { String(describing: engine.videoFormat) }
    public var sourceVideoFormat: String { String(describing: engine.sourceVideoFormat) }
    public var sourceDolbyVisionProfile: Int? { engine.sourceDVProfile }
    public var videoDecoder: String? { engine.activeVideoDecoder }
    public var audioDecoder: String? { engine.activeAudioDecoder }
    public var audioDelivery: String { engine.audioDelivery.rawValue }
    public var videoRoute: String { String(describing: engine.videoRoute) }
    public var isDolbyVisionPresented: Bool {
        if case .dolbyVision = engine.videoFormat { return true }
        return false
    }

    // MARK: Observation

    private func observe() {
        engine.$state.removeDuplicates().sink { [weak self] state in
            guard let self else { return }
            // A same-source audio/background rebuild also has a new readiness phase.
            if case .loading = state { resetPositionObservation() }
            onState?(Self.state(state))
        }.store(in: &subscriptions)
        engine.clock.$currentTime.sink { [weak self] _ in
            // Deferred seeks publish their target before their seek flag/event.
            // Read the completed mutation on the next actor turn, not in willSet.
            guard let self else { return }
            clockPublicationRevision &+= 1
            scheduleTimePublication()
        }.store(in: &subscriptions)
        engine.seekEvents.sink { [weak self] event in
            self?.observeSeek(event)
        }.store(in: &subscriptions)
        engine.clock.$sourceTime.sink { [weak self] seconds in
            self?.updateSubtitle(at: seconds)
        }.store(in: &subscriptions)
        engine.clock.$bufferedPosition.removeDuplicates().sink { [weak self] seconds in
            self?.onBufferedPosition?(seconds)
        }.store(in: &subscriptions)
        engine.$duration.removeDuplicates().sink { [weak self] seconds in
            self?.onDuration?(seconds)
        }.store(in: &subscriptions)
        engine.$isBuffering.removeDuplicates().sink { [weak self] buffering in
            self?.onBuffering?(buffering)
        }.store(in: &subscriptions)
        engine.$hasFirstFrameReadyForDisplay.removeDuplicates().sink { [weak self] ready in
            guard let self else { return }
            if ready { onFirstFrame?() } else { positionIsSettled = false }
            scheduleTimePublication()
        }.store(in: &subscriptions)
        Publishers.Merge4(engine.$audioTracks.map { _ in () }, engine.$subtitleTracks.map { _ in () },
                          engine.$activeAudioTrackIndex.map { _ in () }, engine.$activeSubtitleTrackIndex.map { _ in () })
            .sink { [weak self] in self?.scheduleTracksChanged() }
            .store(in: &subscriptions)
        engine.$mediaChapters.removeDuplicates().sink { [weak self] _ in
            self?.scheduleTracksChanged()
        }.store(in: &subscriptions)
        engine.$subtitleCues.sink { [weak self] cues in
            guard let self else { return }
            self.cues = cues
            self.updateSubtitle(at: self.engine.sourceTime)
        }.store(in: &subscriptions)
    }

    private func resetPositionObservation() {
        timePublicationTask?.cancel()
        timePublicationTask = nil
        positionIsSettled = false
        latestSeekID = nil
        seekNeedsLanding = false
        landedPosition = nil
        deferredSupersessionRevision = nil
    }

    private func observeSeek(_ event: SeekEvent) {
        guard !isStopping else { return }
        switch event.outcome {
        case .began:
            deferredSupersessionRevision = nil
            latestSeekID = event.id
            seekNeedsLanding = true
            landedPosition = nil
        case .landed(let renderedTime):
            // A late landing from a superseded seek cannot settle a newer target.
            guard latestSeekID == event.id, renderedTime.isFinite else { return }
            deferredSupersessionRevision = nil
            seekNeedsLanding = false
            landedPosition = renderedTime
        case .stalled:
            guard latestSeekID == event.id else { return }
            deferredSupersessionRevision = nil
            seekNeedsLanding = true
            landedPosition = nil
        case .superseded:
            guard latestSeekID == event.id else { return }
            latestSeekID = nil
            seekNeedsLanding = true
            landedPosition = nil
            deferredSupersessionRevision = event.origin == .deferred ? clockPublicationRevision : nil
        case .rejected(let reason):
            // 7.53.0 restores a refused forward-only deferred seek's clock from
            // nativeHost.currentTime/sourceTime AFTER superseding its ticket and
            // BEFORE this rejection. Require that exact sequence; a generic
            // rejection cannot turn a stalled/superseded target into a landing.
            if reason == .sourceNotSeekable, event.origin == .programmatic, latestSeekID == nil,
               let revision = deferredSupersessionRevision,
               clockPublicationRevision == (revision &+ 1), !engine.isSeeking {
                seekNeedsLanding = false
                landedPosition = nil
            }
            deferredSupersessionRevision = nil
        }
        scheduleTimePublication()
    }

    private func scheduleTimePublication() {
        guard !isStopping else { return }
        let generation = observationGeneration
        timePublicationTask?.cancel()
        timePublicationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, generation == observationGeneration, !isStopping else { return }
            timePublicationTask = nil
            // The refused-deferred restoration is one synchronous upstream chain.
            // A later unrelated clock/rejection must not inherit its exception.
            deferredSupersessionRevision = nil
            let seconds = landedPosition ?? engine.currentTime
            landedPosition = nil
            guard seconds.isFinite else { return }
            let sessionCanPresent: Bool
            switch engine.state {
            case .idle, .loading, .error: sessionCanPresent = false
            default: sessionCanPresent = true
            }
            positionIsSettled = sessionCanPresent && engine.hasFirstFrameReadyForDisplay
                && !engine.isSeeking && !seekNeedsLanding
            onTime?(seconds)
        }
    }

    private func scheduleTracksChanged() {
        // @Published emits in willSet. Read after storage changes, but only for
        // the session that scheduled the read; stop's reset publishes no inventory.
        guard !isStopping else { return }
        let generation = observationGeneration
        Task { @MainActor [weak self] in
            guard let self, generation == observationGeneration, !isStopping else { return }
            onTracksChanged?()
        }
    }

    private func updateSubtitle(at sourceTime: Double) {
        let time = sourceTime - subtitleDelaySeconds
        let lines = cues.filter { $0.startTime <= time && time < $0.endTime }.compactMap { cue -> String? in
            switch cue.body {
            case .text(let text): return text
            case .richText(let runs): return runs.map(\.text).joined()
            case .image: return nil   // Bitmap subtitles are not drawn by this lane yet.
            }
        }
        publishSubtitle(lines.isEmpty ? nil : lines.joined(separator: "\n"))
    }

    private func publishSubtitle(_ text: String?) {
        guard text != lastSubtitleText else { return }
        lastSubtitleText = text
        onSubtitleText?(text)
    }

    private static func track(_ info: TrackInfo) -> VortXAetherTrack {
        VortXAetherTrack(id: info.id, title: info.name, language: info.language ?? "", codec: info.codec,
                         channels: info.channels, isDefault: info.isDefault, isForced: info.isForced)
    }

    private static func state(_ state: PlaybackState) -> VortXAetherState {
        switch state {
        case .idle: return .idle
        case .loading: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .seeking: return .seeking
        case .ended: return .ended
        case .error(let message): return .failed(message)
        @unknown default: return .failed("Unknown player state")
        }
    }
}
