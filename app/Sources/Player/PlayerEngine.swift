import Foundation

/// The finite surface the player chrome drives playback through. Today the chrome (`PlayerScreen` on
/// iOS/Mac, `TVPlayerView` on tvOS) talks to the engine exclusively via `coordinator.player?.<method>`
/// plus an inbound string-keyed property-event bus (`MPVPlayerDelegate`). Every member below is something
/// the chrome already calls — this protocol just names that contract so a SECOND engine can satisfy it.
///
/// Why this exists: libmpv (`MPVMetalViewController`, vo=gpu-next/MoltenVK) cannot do true Dolby Vision
/// passthrough — it only tone-maps DV to SDR, and mpv's `target-colorspace-hint` double-frees MoltenVK
/// (see `MPVMetalViewController.syncDisplayDynamicRange`). AVFoundation (`AVPlayer`/`AVPlayerLayer`) does
/// native DV (Profile 5 / 8.x) and HDR EDR. So an AVPlayer-backed conformer plays DV + HTTP/HLS streams
/// through the SAME chrome, while libmpv stays the engine for torrents and everything AVFoundation can't
/// demux. `MPVMetalViewController` already implements every requirement here; the AVPlayer conformer maps
/// `AVPlayerItem` KVO + a periodic time observer onto the same `MPVProperty` event keys.
///
/// `@MainActor` + `AnyObject`: the chrome runs on the main actor and holds the engine as a `weak` reference,
/// exactly as `MPVMetalViewController` (a `UIViewController`/`NSViewController`) is held today.
@MainActor
protocol PlayerEngine: AnyObject {
    // Loading + transport
    func loadFile(_ url: URL, headers: [String: String]?, live: Bool)
    func play()
    func pause()
    func togglePause()
    func seek(to seconds: Double)
    func seek(by seconds: Double)
    func setSpeed(_ speed: Double)
    func stop()

    // Video sizing
    func setVideoSize(_ mode: String)
    var videoSizeMode: String { get }

    // Tracks + subtitles
    func tracks(ofType type: String) -> [MPVTrack]
    func setAudioTrack(_ id: Int)
    func setSubtitleTrack(_ id: Int)
    func addExternalSubtitle(url: String, title: String, lang: String,
                             timeout: TimeInterval, completion: ((Bool) -> Void)?)
    func setSubDelay(_ seconds: Double)
    func setAudioDelay(_ seconds: Double)
    func applySubtitleStyle()

    // Chapters + media info
    func chapters() -> [MPVChapter]
    func mediaSummary() -> (height: Int, audioCodec: String)
    func playbackStats() -> [(String, String)]

    // Decode + audio routing
    func setHardwareDecoding(_ on: Bool)
    var hardwareDecoding: Bool { get }
    func setAudioOutputMode(_ mode: AudioOutputMode)

    // Trickplay + HDR availability
    func captureFrameJPEGData(completion: @escaping (Data?) -> Void)
    var hdrAvailable: Bool { get }

    #if os(iOS)
    /// iOS-only: force the player into landscape (or back). tvOS is always landscape; macOS has no rotation.
    func setOrientation(landscape: Bool)
    #endif
}

extension PlayerEngine {
    /// The chrome calls `addExternalSubtitle(url:title:lang:)` (the rest defaulted). Protocol requirements
    /// can't carry default values, so this convenience forwards to the full requirement — needed once the
    /// chrome holds the engine as `any PlayerEngine`. `MPVMetalViewController`'s own defaulted overload still
    /// wins when the engine is referenced as the concrete type.
    func addExternalSubtitle(url: String, title: String, lang: String) {
        addExternalSubtitle(url: url, title: title, lang: lang, timeout: 20, completion: nil)
    }
}

/// `MPVMetalViewController` already implements every `PlayerEngine` member, so this is a pure conformance
/// declaration with zero behavior change. If it ever fails to compile, the protocol drifted from the engine.
extension MPVMetalViewController: PlayerEngine {}
