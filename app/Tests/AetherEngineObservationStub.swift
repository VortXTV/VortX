import AppKit
import AVFoundation
import Combine
import Foundation

// Test-only module named AetherEngine. It supplies actual @Published willSet behavior
// and the public 7.53.0 seek-event shape; the maintained VortXAetherPlayer is unchanged.
public enum PlaybackState: Equatable { case idle, loading, playing, paused, seeking, ended, error(String) }
public enum VideoFormat { case sdr, hdr10, hdr10Plus, hlg, dolbyVision }
public enum VideoGravity { case resizeAspect, resizeAspectFill, resize }
public enum AudioDelivery: String { case pcm }
public struct LoadOptions { public var httpHeaders: [String:String] = [:]; public var autoplay = true; public var isLive = false; public init() {} }
public struct TrackInfo: Equatable {
    public var id: Int; public var name: String; public var language: String? = nil
    public var codec = "aac"; public var channels = 2; public var isDefault = true; public var isForced = false
    public init(id: Int, name: String) { self.id = id; self.name = name }
}
public struct ChapterInfo: Equatable { public var name: String; public var startSeconds: Double }
public struct SubtitleRun { public var text: String }
public struct SubtitleImage: @unchecked Sendable {
    public let cgImage: CGImage; public let position: CGRect; public let canvasSize: CGSize
    public init(cgImage: CGImage, position: CGRect, canvasSize: CGSize = .zero) {
        self.cgImage = cgImage; self.position = position; self.canvasSize = canvasSize
    }
}
public enum SubtitleBody { case text(String), richText([SubtitleRun]), image(SubtitleImage) }
public struct SubtitleCue {
    public var id: Int; public var startTime: Double; public var endTime: Double; public var body: SubtitleBody
    public init(id: Int, startTime: Double, endTime: Double, body: SubtitleBody) {
        self.id = id; self.startTime = startTime; self.endTime = endTime; self.body = body
    }
}
public struct ExternalSubtitleTrack {
    public let url: URL
    public init(url: URL, name: String?, language: String?, httpHeaders: [String:String]) { self.url = url }
}
@MainActor public final class PreparedExternalSubtitle { public func discard() {} }
public struct SeekEvent {
    public enum Origin: Equatable { case programmatic, nativeScrub, deferred }
    public enum Rejection: Equatable { case noActiveSession, liveWithoutDVR, sourceNotSeekable }
    public enum Outcome { case began, landed(renderedTime: Double), stalled, superseded, rejected(Rejection) }
    public var id: UInt64; public var origin: Origin; public var outcome: Outcome; public var target: Double
    public init(id: UInt64, origin: Origin = .programmatic, outcome: Outcome, target: Double) {
        self.id = id; self.origin = origin; self.outcome = outcome; self.target = target
    }
}
public final class AetherPlayerView: NSView {}
@MainActor public final class PlaybackClock {
    @Published public var currentTime = 0.0
    @Published public var sourceTime = 0.0
    @Published public var bufferedPosition = 0.0
    public init() {}
}
@MainActor public final class AetherEngine {
    public static var latest: AetherEngine!
    public let clock = PlaybackClock()
    @Published public var state = PlaybackState.idle
    @Published public var duration = 0.0
    @Published public var isBuffering = false
    @Published public var hasFirstFrameReadyForDisplay = false
    @Published public var audioTracks: [TrackInfo] = []
    @Published public var subtitleTracks: [TrackInfo] = []
    @Published public var activeAudioTrackIndex: Int?
    @Published public var activeSubtitleTrackIndex: Int?
    @Published public var mediaChapters: [ChapterInfo] = []
    @Published public var subtitleCues: [SubtitleCue] = []
    @Published public var secondarySubtitleCues: [SubtitleCue] = []
    @Published public var isSecondarySubtitleActive = false
    public var isSeeking = false
    public var canSeek = true
    public var currentTime: Double { clock.currentTime }
    public var sourceTime: Double { clock.sourceTime }
    public var bufferedPosition: Double { clock.bufferedPosition }
    public var videoGravity = VideoGravity.resizeAspect
    public var volume: Float = 1
    public var softwareDisplaySize: CGSize?
    public var nativePlayerLayer: AVPlayerLayer?
    public var sourceVideoPixelAspectRatio = 1.0
    public var sourceVideoWidth: Int32 = 1920, sourceVideoHeight: Int32 = 1080
    public var sourceVideoFrameRate: Double? = 24
    public var videoFormat = VideoFormat.sdr, sourceVideoFormat = VideoFormat.sdr
    public var sourceDVProfile: Int?
    public var activeVideoDecoder: String?, activeAudioDecoder: String?
    public var audioDelivery = AudioDelivery.pcm
    public var videoRoute = "synthetic"
    private let seekSubject = PassthroughSubject<SeekEvent,Never>()
    public var seekEvents: AnyPublisher<SeekEvent,Never> { seekSubject.eraseToAnyPublisher() }
    public func send(_ event: SeekEvent) { seekSubject.send(event) }
    public init() throws { Self.latest = self }
    public func bind(view: AetherPlayerView) {}
    public func load(url: URL, startPosition: Double?, options: LoadOptions) async throws {
        state = .loading; hasFirstFrameReadyForDisplay = false; clock.currentTime = startPosition ?? 0
    }
    public func play() { state = .playing }
    public func pause() { state = .paused }
    public func stop() {
        state = .idle; hasFirstFrameReadyForDisplay = false; isSeeking = false
        clock.currentTime = 0; clock.sourceTime = 0; duration = 0
        audioTracks = []; subtitleTracks = []; activeAudioTrackIndex = nil; activeSubtitleTrackIndex = nil
        mediaChapters = []; subtitleCues = []; secondarySubtitleCues = []; isSecondarySubtitleActive = false
    }
    public func seek(to seconds: Double) async {}
    public func setRate(_ rate: Float) {}
    public func setAudioDelay(_ seconds: Double) {}
    public func selectAudioTrack(index: Int) { activeAudioTrackIndex = index }
    public func selectSubtitleTrack(index: Int) { activeSubtitleTrackIndex = index }
    public func clearSubtitle() { subtitleCues = []; activeSubtitleTrackIndex = nil }
    public func removeExternalSubtitleTrack(id: Int) {
        subtitleTracks.removeAll { $0.id == id }
        if activeSubtitleTrackIndex == id { clearSubtitle() }
    }
    public func clearSecondarySubtitle() { secondarySubtitleCues = []; isSecondarySubtitleActive = false }
    public func selectSecondarySubtitleTrack(index: Int) { isSecondarySubtitleActive = true }
    public func prepareExternalSubtitle(_ track: ExternalSubtitleTrack) async throws -> PreparedExternalSubtitle { .init() }
    public func commitExternalSubtitle(_ prepared: PreparedExternalSubtitle, secondary: Bool = false) throws -> TrackInfo { .init(id: 100000, name: "Prepared") }
    public func selectSidecarSubtitle(url: URL, httpHeaders: [String:String]?) {}
}
