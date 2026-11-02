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
    private var secondaryCues: [SubtitleCue] = []
    private var secondarySelectionID: Int?
    private let subtitleCanvas = VortXAetherSubtitleCanvas(frame: .zero)
    private var sizeMode = "fit"
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
        // A stable container keeps subtitle overlays above every native/software video-layer swap.
        let container = VortXAetherBridgeView(frame: .zero)
        #if os(macOS)
        container.wantsLayer = true
        playerView.autoresizingMask = [.width, .height]
        subtitleCanvas.autoresizingMask = [.width, .height]
        #else
        playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        subtitleCanvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
        container.addSubview(playerView)
        container.addSubview(subtitleCanvas)
        view = container
        subtitleCanvas.nativeVideoRectProvider = { [weak self] in self?.nativeSubtitleVideoRect() }
        engine.bind(view: playerView)
        observe()
    }

    // MARK: Loading and transport

    /// `autoplay` false holds the new session paused at mount; `play()` starts it later.
    public func load(url: URL, headers: [String: String]?, live: Bool, startPosition: Double?, autoplay: Bool = true) async throws {
        observationGeneration &+= 1
        resetPositionObservation()
        cues = []; secondaryCues = []; secondarySelectionID = nil
        subtitleCanvas.present(images: [], ids: [], secondaryText: nil, videoSize: .zero, mode: sizeMode)
        publishSubtitle(nil)
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
        cues = []; secondaryCues = []; secondarySelectionID = nil
        subtitleCanvas.present(images: [], ids: [], secondaryText: nil, videoSize: .zero, mode: sizeMode)
        publishSubtitle(nil)
    }
    public func seek(to seconds: Double) async { await engine.seek(to: seconds) }
    public func setRate(_ rate: Double) { engine.setRate(Float(rate)) }
    public func setVideoSize(_ mode: String) {
        sizeMode = mode
        switch mode {
        case "zoom", "fill": engine.videoGravity = .resizeAspectFill
        case "stretch": engine.videoGravity = .resize
        default: engine.videoGravity = .resizeAspect
        }
        updateSubtitle(at: engine.sourceTime)
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
    public func selectSubtitleTrack(id: Int) {
        if secondarySelectionID == id { clearSecondarySubtitle() }
        engine.selectSubtitleTrack(index: id)
    }
    public var activeSecondarySubtitleTrackID: Int? {
        engine.isSecondarySubtitleActive ? secondarySelectionID : nil
    }
    public func selectSecondarySubtitleTrack(id: Int) {
        guard id != engine.activeSubtitleTrackIndex,
              engine.subtitleTracks.contains(where: { $0.id == id }) else { return }
        secondarySelectionID = id
        engine.selectSecondarySubtitleTrack(index: id)
        onTracksChanged?()
    }
    public func removeExternalSubtitleTrack(id: Int) {
        engine.removeExternalSubtitleTrack(id: id)
        if secondarySelectionID == id { secondarySelectionID = nil }
        updateSubtitle(at: engine.sourceTime)
        onTracksChanged?()
    }
    public func clearSecondarySubtitle() {
        secondarySelectionID = nil
        secondaryCues = []
        engine.clearSecondarySubtitle()
        updateSubtitle(at: engine.sourceTime)
        onTracksChanged?()
    }
    public func selectLocalSubtitle(url: URL, title: String, lang: String, secondary: Bool,
        permitsPreparation: @MainActor () -> Bool, permitsCommit: @MainActor () -> Bool, committedTrack: @MainActor (Int) -> Void, finishedCommit: @MainActor () -> Void) async throws {
        guard !Task.isCancelled, url.isFileURL, permitsPreparation() else { throw CancellationError() }
        let prepared = try await engine.prepareExternalSubtitle(
            ExternalSubtitleTrack(url: url, name: title, language: lang, httpHeaders: [:]))
        // Native commit performs no I/O or suspension. Off, embedded selection, retirement and
        // caller credential/presentation revocation are checked immediately before mutation.
        guard !Task.isCancelled, permitsCommit() else { prepared.discard(); throw CancellationError() }
        defer { finishedCommit() }
        let track = try engine.commitExternalSubtitle(prepared, secondary: secondary)
        if secondary { secondarySelectionID = track.id }
        committedTrack(track.id)
        onTracksChanged?()
    }
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
        engine.$isSecondarySubtitleActive.sink { [weak self] _ in
            self?.scheduleTracksChanged()
        }.store(in: &subscriptions)
        engine.$secondarySubtitleCues.sink { [weak self] cues in
            guard let self else { return }
            secondaryCues = cues
            updateSubtitle(at: engine.sourceTime)
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

    private var subtitleDisplaySize: CGSize {
        func valid(_ size: CGSize) -> Bool {
            size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
        }
        if let measured = engine.softwareDisplaySize, valid(measured) { return measured }
        if let presented = engine.nativePlayerLayer?.player?.currentItem?.presentationSize,
           valid(presented) { return presented }
        let coded = CGSize(width: Int(engine.sourceVideoWidth), height: Int(engine.sourceVideoHeight))
        let sar = engine.sourceVideoPixelAspectRatio
        let fallback = CGSize(width: coded.width * CGFloat(sar), height: coded.height)
        return valid(fallback) ? fallback : coded
    }

    private func nativeSubtitleVideoRect() -> CGRect? {
        guard let native = engine.nativePlayerLayer else { return nil }
        let rect = native.videoRect
        guard [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0 else { return nil }
        #if os(macOS)
        guard let canvasLayer = subtitleCanvas.layer else { return nil }
        #else
        let canvasLayer = subtitleCanvas.layer
        #endif
        // The native layer and subtitle canvas are siblings under the stable host container.
        // Convert its actual measured picture rectangle, including current layer layout/gravity.
        let converted = canvasLayer.convert(rect, from: native)
        guard [converted.minX, converted.minY, converted.width, converted.height,
               converted.maxX, converted.maxY].allSatisfy(\.isFinite) else { return nil }
        return converted
    }

    private func updateSubtitle(at sourceTime: Double) {
        let time = sourceTime - subtitleDelaySeconds
        guard time.isFinite else { return }
        let primary = cues.filter { $0.startTime <= time && time < $0.endTime }
        let secondary = secondaryCues.filter { $0.startTime <= time && time < $0.endTime }
        func text(_ active: [SubtitleCue]) -> String? {
            let lines = active.compactMap { cue -> String? in
                switch cue.body {
                case .text(let text): return text
                case .richText(let runs): return runs.map(\.text).joined()
                case .image: return nil
                }
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        let bitmap = (primary + secondary).filter { if case .image = $0.body { return true }; return false }
        let images = bitmap.compactMap { cue -> SubtitleImage? in
            if case .image(let image) = cue.body { return image }; return nil
        }
        subtitleCanvas.present(images: images, ids: bitmap.map(\.id), secondaryText: text(secondary),
            videoSize: CGSize(width: Int(engine.sourceVideoWidth), height: Int(engine.sourceVideoHeight)),
            displaySize: subtitleDisplaySize, mode: sizeMode)
        publishSubtitle(text(primary))
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

/// Maps authored bitmap canvases onto the actual displayed video rectangle. Input and returned
/// rectangles use top-left coordinates; a cropped rip keeps the subtitle canvas width-aligned,
/// vertically centered, matching AetherEngine7.53 SubtitleImage's documented contract.
@MainActor
final class VortXAetherSubtitleCanvas: VortXAetherBridgeView {
    private var images: [SubtitleImage] = []
    private var ids: [Int] = []
    private var videoSize = CGSize.zero
    private var displaySize = CGSize.zero
    var nativeVideoRectProvider: (@MainActor () -> CGRect?)?
    private var mode = "fit"
    private(set) var imageLayers: [CALayer] = []
    #if os(macOS)
    private let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); configure() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); layoutContent() }
    #else
    private let label = UILabel()
    override init(frame: CGRect) { super.init(frame: frame); configure() }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    override func layoutSubviews() { super.layoutSubviews(); layoutContent() }
    #endif
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    private func configure() {
        #if os(macOS)
        wantsLayer = true
        layer?.masksToBounds = true
        label.alignment = .center; label.textColor = .white
        label.font = .systemFont(ofSize: 28, weight: .semibold)
        label.maximumNumberOfLines = 0
        #else
        isUserInteractionEnabled = false
        clipsToBounds = true
        label.textAlignment = .center; label.textColor = .white
        label.font = .systemFont(ofSize: 28, weight: .semibold); label.numberOfLines = 0
        label.shadowColor = .black; label.shadowOffset = CGSize(width: 1, height: 1)
        #endif
        addSubview(label)
    }
    func present(images: [SubtitleImage], ids: [Int], secondaryText: String?, videoSize: CGSize,
                 displaySize: CGSize = .zero, mode: String) {
        self.ids = ids; self.images = images
        if images.count != imageLayers.count {
            imageLayers.forEach { $0.removeFromSuperlayer() }
            imageLayers = images.map { image in
                let item = CALayer(); item.contents = image.cgImage; item.contentsGravity = .resize
                #if os(macOS)
                layer?.insertSublayer(item, at: 0)
                #else
                layer.insertSublayer(item, at: 0)
                #endif
                return item
            }
        }
        for (image, item) in zip(images, imageLayers) { item.contents = image.cgImage }
        self.videoSize = videoSize; self.displaySize = displaySize; self.mode = mode
        #if os(macOS)
        label.stringValue = secondaryText ?? ""
        #else
        label.text = secondaryText
        #endif
        label.isHidden = secondaryText?.isEmpty != false
        layoutContent()
    }
    nonisolated static func imageRect(position: CGRect, canvas: CGSize, video: CGSize,
                                      bounds: CGRect, mode: String, displayVideo: CGSize? = nil,
                                      measuredVideoRect: CGRect? = nil) -> CGRect {
        let values = [position.minX, position.minY, position.width, position.height, canvas.width,
            canvas.height, video.width, video.height, bounds.minX, bounds.minY, bounds.width, bounds.height]
        guard values.allSatisfy(\.isFinite), position.width > 0, position.height > 0,
              video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let display: CGSize
        if let displayVideo, displayVideo.width.isFinite, displayVideo.height.isFinite,
           displayVideo.width > 0, displayVideo.height > 0 { display = displayVideo }
        else { display = video }
        let videoRect: CGRect
        if let measuredVideoRect,
           [measuredVideoRect.minX, measuredVideoRect.minY, measuredVideoRect.width,
            measuredVideoRect.height, measuredVideoRect.maxX, measuredVideoRect.maxY].allSatisfy(\.isFinite),
           measuredVideoRect.width > 0, measuredVideoRect.height > 0 { videoRect = measuredVideoRect }
        else if mode == "stretch" { videoRect = bounds }
        else {
            let x = bounds.width / display.width, y = bounds.height / display.height
            let scale = ["fill", "zoom"].contains(mode) ? max(x, y) : min(x, y)
            let size = CGSize(width: display.width * scale, height: display.height * scale)
            videoRect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                               width: size.width, height: size.height)
        }
        let canvas = canvas.width > 0 && canvas.height > 0 ? canvas : video
        // First map the authored canvas width-aligned/center-anchored into coded pixels,
        // then apply the actual picture's independent display X/Y scales. Square-pixel
        // fit/fill retains the upstream formula; stretch and anamorphic DVD stay aligned.
        let authoredScale = video.width / canvas.width
        let xScale = authoredScale * videoRect.width / video.width
        let yScale = authoredScale * videoRect.height / video.height
        let rect = CGRect(x: videoRect.minX + position.minX * canvas.width * xScale,
            y: videoRect.midY + (position.minY * canvas.height - canvas.height / 2) * yScale,
            width: position.width * canvas.width * xScale, height: position.height * canvas.height * yScale)
        return [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY,
                rect.midX, rect.midY].allSatisfy(\.isFinite) ? rect : .zero
    }
    private func layoutContent() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (image, item) in zip(images, imageLayers) {
            item.frame = Self.imageRect(position: image.position, canvas: image.canvasSize,
                video: videoSize, bounds: bounds, mode: mode, displayVideo: displaySize,
                measuredVideoRect: nativeVideoRectProvider?())
        }
        label.frame = CGRect(x: 24, y: 24, width: max(0, bounds.width - 48), height: 100)
        CATransaction.commit()
    }
}
