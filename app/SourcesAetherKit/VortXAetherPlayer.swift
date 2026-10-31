import AVFoundation
import Combine
import Foundation
import UIKit
// Internal: apps importing VortXAetherKit must not load AetherEngine or its AetherLib* FFmpeg headers,
// which would collide with MPVKit's FFmpeg headers in the same compile.
internal import AetherEngine

// The only file that imports AetherEngine. This framework is where the engine is linked, so its FFmpeg
// references resolve to the AetherLib* frameworks here instead of the app's static MPVKit FFmpeg. The app
// sees plain types only and never imports AetherEngine itself.

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
    public let view: UIView

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

    public init() throws {
        engine = try AetherEngine()
        let playerView = AetherPlayerView(frame: .zero)
        view = playerView
        engine.bind(view: playerView)
        observe()
    }

    // MARK: Loading and transport

    /// `autoplay` false holds the new session paused at mount; `play()` starts it later.
    public func load(url: URL, headers: [String: String]?, startPosition: Double?, autoplay: Bool = true) async throws {
        var options = LoadOptions()
        options.httpHeaders = headers ?? [:]
        options.autoplay = autoplay
        _ = try await engine.load(url: url, startPosition: startPosition, options: options)
    }

    public func play() { engine.play() }
    public func pause() { engine.pause() }
    public func stop() {
        engine.stop()
        cues = []
        publishSubtitle(nil)
    }
    public func seek(to seconds: Double) async { await engine.seek(to: seconds) }
    public func setRate(_ rate: Double) { engine.setRate(Float(rate)) }
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
            self?.onState?(Self.state(state))
        }.store(in: &subscriptions)
        engine.clock.$currentTime.sink { [weak self] seconds in
            self?.onTime?(seconds)
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
        engine.$hasFirstFrameReadyForDisplay.removeDuplicates().filter { $0 }.sink { [weak self] _ in
            self?.onFirstFrame?()
        }.store(in: &subscriptions)
        Publishers.Merge4(engine.$audioTracks.map { _ in () }, engine.$subtitleTracks.map { _ in () },
                          engine.$activeAudioTrackIndex.map { _ in () }, engine.$activeSubtitleTrackIndex.map { _ in () })
            .sink { [weak self] in self?.onTracksChanged?() }
            .store(in: &subscriptions)
        engine.$subtitleCues.sink { [weak self] cues in
            guard let self else { return }
            self.cues = cues
            self.updateSubtitle(at: self.engine.sourceTime)
        }.store(in: &subscriptions)
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
