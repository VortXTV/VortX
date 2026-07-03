import AVFoundation
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
    /// yt-direct adaptive pair: load `url` (a video-only adaptive stream) with an EXTERNAL AUDIO SIDECAR
    /// merged in at load (mpv `--audio-files`). nil = no sidecar (identical to the 3-arg form). The libmpv
    /// engine mounts it; the AVPlayer engine takes the extension default below, which DROPS the sidecar
    /// (AVFoundation can't merge a second remote file), so AVPlayer callers must hand it a muxed URL.
    func loadFile(_ url: URL, headers: [String: String]?, live: Bool, audioSidecar: URL?)
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

    // Community-subtitle fingerprint + learned-offset inputs (P3/P4). Read off the engine's own state; the
    // libmpv engine implements these against mpv properties, the AVPlayer engine takes the 0 defaults below
    // (its path can't apply sub-delay or extract embedded text, so a 0/absent value is correct there).
    func containerFrameRate() -> Double
    func mediaDurationSeconds() -> Double
    func currentSubDelaySeconds() -> Double

    // Chapters + media info
    func chapters() -> [MPVChapter]
    func mediaSummary() -> (width: Int, height: Int, audioCodec: String)
    func playbackStats() -> [(String, String)]

    // Decode + audio routing
    func setHardwareDecoding(_ on: Bool)
    var hardwareDecoding: Bool { get }
    func setAudioOutputMode(_ mode: AudioOutputMode)

    // Trickplay + HDR availability
    func captureFrameJPEGData(maxWidth: CGFloat, completion: @escaping (Data?) -> Void)
    var hdrAvailable: Bool { get }

    /// The LIVE playback position in seconds, read straight off the engine (mpv `time-pos` / AVPlayer
    /// currentTime). Used by the wall-clock trickplay capture driver so it can grab a frame at the true
    /// position even when the engine's timePos event stream is sparse/coalesced. 0 before playback.
    var playbackPositionSeconds: Double { get }

    /// Live audio volume, 0...100 (mpv `volume` scale; the AVPlayer engine maps 0...1 <-> 0...100). Set-only
    /// via setVolume; the getter reflects the last applied value so the chrome slider stays in sync.
    func setVolume(_ volume0to100: Double)
    /// Mute / unmute the live audio output without losing the volume level.
    func setMuted(_ muted: Bool)

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

    /// The form the chrome actually uses: 3 named args plus a trailing `completion` closure (timeout
    /// defaulted). A trailing-closure call binds to this overload, not the no-completion one above.
    func addExternalSubtitle(url: String, title: String, lang: String, completion: ((Bool) -> Void)?) {
        addExternalSubtitle(url: url, title: title, lang: lang, timeout: 20, completion: completion)
    }

    // The two loadFile requirements default into each other so each engine only implements ONE concrete
    // form: MPVMetalViewController implements the 4-arg (its defaulted `audioSidecar:` parameter matches
    // the full signature) and gets the 3-arg here; AVPlayerEngineController implements the 3-arg and gets
    // the sidecar-DROPPING 4-arg here (AVFoundation cannot merge a second remote file; trailers on the
    // AVPlayer lane must be handed a muxed URL instead). NOTE: a new engine must implement at least one
    // of the two or these defaults recurse.
    func loadFile(_ url: URL, headers: [String: String]?, live: Bool) {
        loadFile(url, headers: headers, live: live, audioSidecar: nil)
    }

    func loadFile(_ url: URL, headers: [String: String]?, live: Bool, audioSidecar: URL?) {
        loadFile(url, headers: headers, live: live)
    }

    // Default no-op fingerprint/offset inputs for engines that don't surface them (the AVPlayer engine).
    // `MPVMetalViewController`'s concrete implementations override these.
    func containerFrameRate() -> Double { 0 }
    func mediaDurationSeconds() -> Double { 0 }
    func currentSubDelaySeconds() -> Double { 0 }

    /// Default 0 for any engine that doesn't override (the wall-clock capture driver falls back to the
    /// chrome's own `currentTime` when this is 0). Both concrete engines override with the real position.
    var playbackPositionSeconds: Double { 0 }
}

/// `MPVMetalViewController` already implements every `PlayerEngine` member, so this is a pure conformance
/// declaration with zero behavior change. If it ever fails to compile, the protocol drifted from the engine.
extension MPVMetalViewController: PlayerEngine {}

#if os(iOS) || os(tvOS)
/// Shared audio-session setup for the AVPlayer engine path (iOS + tvOS). AVPlayer / AVPlayerViewController
/// negotiate the hardware output format themselves, so this path does NOT need the route-aware channel /
/// sample-rate policy that libmpv's audiounit AO requires (`MPVMetalViewController.configureAudioSession`).
/// It only has to:
///   1. Claim `.playback` + `.moviePlayback` so PiP, background, and locked-screen audio work (PiP refuses
///      to start without an active `.playback` session), and
///   2. Advertise multichannel content so the system can pass through Dolby Atmos / multichannel PCM (#78)
///      AND apply AirPods head-tracked Spatial Audio (#88).
/// `setSupportsMultichannelContent(true)` is a capability HINT, not a re-route: it is benign on HDMI / eARC /
/// built-in-speaker routes (the system already negotiates those) and never downmixes a real receiver. It just
/// unlocks the spatial / multichannel layout on routes that can take it (chiefly AirPods). Idempotent across
/// engines because only one player is live at a time, so a libmpv -> AVPlayer hand-off is safe.
enum AVPlayerAudioSession {
    static func activateForMovie() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            // iOS min is 16.0 and tvOS min is 26.x, both above the 15.0 floor of this API, so no #available
            // guard is needed. #78 Atmos passthrough + #88 AirPods Spatial.
            try? session.setSupportsMultichannelContent(true)
        } catch {
            // Fail-soft: inline playback still works; only PiP / background audio / spatial negotiation degrade.
        }
    }
}
#endif
