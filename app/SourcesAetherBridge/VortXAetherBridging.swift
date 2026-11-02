import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The boundary between the apps and VortXAetherKit. This one file compiles into BOTH the framework and every
// app that offers AetherEngine, so the two copies always declare the same Objective-C selectors. The apps never
// link or import VortXAetherKit: they load it at runtime (AetherEngineLoader), only on a system the engine
// supports (iOS 18, tvOS 18, macOS 15), so the iOS 16 and macOS 14 floors keep working. The Objective-C runtime
// matches a protocol by name, so the framework's player class casts to the app's copy of this protocol.
// Only Foundation and platform view types cross: no AetherEngine type, and no class declared on both sides.

/// The engine's transport state.
@objc(VortXAetherBridgeState)
public enum VortXAetherBridgeState: Int {
    case idle, loading, playing, paused, seeking, ended, failed
}

/// Error codes the framework reports in `VortXAetherBridgeErrorDomain`.
@objc(VortXAetherBridgeErrorCode)
public enum VortXAetherBridgeErrorCode: Int {
    /// A newer load, `cancelLoad()` or `stop()` replaced this load.
    case cancelled = 1
    /// The engine rejected or failed the load; the error's description says why.
    case loadFailed = 2
}

public let VortXAetherBridgeErrorDomain = "VortXAetherBridge"

#if os(macOS)
public typealias VortXAetherBridgeView = NSView
#else
public typealias VortXAetherBridgeView = UIView
#endif

/// Track dictionary keys for `audioTracks` / `subtitleTracks`.
public enum VortXAetherBridgeTrackKey {
    public static let id = "id"               // Int
    public static let title = "title"         // String
    public static let language = "language"   // String, empty when unknown
    public static let codec = "codec"         // String
    public static let channels = "channels"   // Int
    public static let isDefault = "isDefault" // Bool
    public static let isForced = "isForced"   // Bool
}

@MainActor
@objc(VortXAetherBridging)
public protocol VortXAetherBridging: NSObjectProtocol {
    /// A new player with its own engine, or the reason the engine could not start.
    static func makePlayer() throws -> VortXAetherBridging

    /// The view the engine presents into. Host it full screen; the engine swaps its layer per session.
    var view: VortXAetherBridgeView { get }

    /// State changes; the message is set for `.failed`.
    var onState: ((VortXAetherBridgeState, String?) -> Void)? { get set }
    /// Playback clock, the scrubber axis.
    var onTime: ((Double) -> Void)? { get set }
    var onDuration: ((Double) -> Void)? { get set }
    var onBuffering: ((Bool) -> Void)? { get set }
    /// Position buffered ahead on the same axis as `onTime`.
    var onBufferedPosition: ((Double) -> Void)? { get set }
    var onTracksChanged: (() -> Void)? { get set }
    var onFirstFrame: (() -> Void)? { get set }
    /// The text of the active subtitle cue at the displayed frame, or nil when none is showing.
    var onSubtitleText: ((String?) -> Void)? { get set }

    /// Opens a source. `startPosition` nil starts at the beginning; `autoplay` false holds the session paused
    /// until `play()`. The completion runs once, with nil on success, or an error in
    /// `VortXAetherBridgeErrorDomain` (`cancelled` when a newer load, `cancelLoad()` or `stop()` replaced it).
    func load(url: URL, headers: [String: String]?, live: Bool, startPosition: NSNumber?, autoplay: Bool,
              completion: @escaping (NSError?) -> Void)
    func cancelLoad()
    func play()
    func pause()
    func stop()
    func seek(to seconds: Double, completion: (() -> Void)?)
    func setRate(_ rate: Double)
    func setVideoSize(_ mode: String)
    /// Seconds; positive presents audio later than video. The engine clamps to +/-2 s.
    func setAudioDelay(_ seconds: Double)
    /// 0...1.
    var volume: Double { get set }

    var currentTime: Double { get }
    var duration: Double { get }
    var canSeek: Bool { get }
    /// Physical seek lifetime, which can outlast the optimistic transport state.
    var isSeeking: Bool { get }
    /// Settlement of the last onTime snapshot. False for an optimistic, stalled or
    /// superseded seek even after isSeeking falls; true only with display evidence.
    var positionIsSettled: Bool { get }
    var bufferedPosition: Double { get }

    /// Tracks as dictionaries keyed by `VortXAetherBridgeTrackKey`.
    var audioTracks: [[String: Any]] { get }
    var subtitleTracks: [[String: Any]] { get }
    var activeAudioTrackID: NSNumber? { get }
    var activeSubtitleTrackID: NSNumber? { get }
    func selectAudioTrack(id: Int)
    func selectSubtitleTrack(id: Int)
    func clearSubtitle()
    func selectSidecarSubtitle(url: URL, headers: [String: String]?)
    /// Seconds; positive shows cues later.
    func setSubtitleDelay(_ seconds: Double)

    /// Observed stream dimensions and nominal frame rate; zero/nil when unmeasured.
    var videoWidth: Int { get }
    var videoHeight: Int { get }
    var videoFrameRate: NSNumber? { get }
    /// Stable presentation value: sdr, pq, hlg, dolbyVision or unknown.
    var videoDynamicRange: String { get }
    /// Container chapter dictionaries: title (String), start (Double), on the seek axis.
    var mediaChapters: [[String: Any]] { get }
    var videoFormat: String { get }
    var sourceVideoFormat: String { get }
    var sourceDolbyVisionProfile: NSNumber? { get }
    var videoDecoder: String? { get }
    var audioDecoder: String? { get }
    var audioDelivery: String { get }
    var videoRoute: String { get }
    var isDolbyVisionPresented: Bool { get }
}
