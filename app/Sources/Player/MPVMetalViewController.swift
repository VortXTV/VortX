import Foundation
import CryptoKit
import Metal
import ImageIO
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import Libmpv
import AVFoundation
import os

// The player view controller is UIViewController on iOS/tvOS and NSViewController on macOS. iOS/tvOS
// resolve PlatformViewController to UIViewController, so their compiled code is unchanged.
#if canImport(UIKit)
typealias PlatformViewController = UIViewController
#elseif canImport(AppKit)
typealias PlatformViewController = NSViewController
#endif

// warning: metal API validation has been disabled to ignore crash when playing HDR videos.
// Edit Scheme -> Run -> Diagnostics -> Metal API Validation -> Turn it off
// https://github.com/KhronosGroup/MoltenVK/issues/2226

/// The context object mpv's wakeup callback receives. mpv holds it retained (+1); the weak
/// controller reference inside means a callback racing teardown resolves to nil instead of
/// dereferencing a freed controller. Released only after `mpv_terminate_destroy` returns,
/// at which point mpv guarantees no further callbacks.
private final class WakeupRelay {
    weak var controller: MPVMetalViewController?
    init(_ controller: MPVMetalViewController) { self.controller = controller }
}

final class MPVMetalViewController: PlatformViewController {
    var metalLayer = MetalLayer()
    var mpv: OpaquePointer!
    /// The +1 relay currently registered with mpv; balanced with release() after terminate.
    private var wakeupRelay: Unmanaged<WakeupRelay>?
    var playDelegate: MPVPlayerDelegate?
    lazy var queue = DispatchQueue(label: "mpv", qos: .userInitiated)
    private lazy var captureQueue = DispatchQueue(label: "com.stremiox.trickplay.capture", qos: .utility)
    // Initialized on first capture using the same MTLDevice mpv renders into. Always accessed from
    // captureQueue (serial), so no lock is needed.
    private var ciContext: CIContext?
    // Tracks the last drawable size and format for which captureTexture was created, so that
    // updateCapturePipeline() is a no-op when called from captureFrameJPEGData every 10 s.
    private var capturePipelineSize: CGSize = .zero
    private var capturePipelineFormat: MTLPixelFormat = .invalid
    var playUrl: URL?
    var playHeaders: [String: String]?
    var playUrlLive = false
    /// yt-direct adaptive pair: an EXTERNAL AUDIO stream mounted alongside `playUrl` at load (mpv
    /// `--audio-files`). Set BEFORE viewDidLoad by MPVMetalPlayerView when a trailer resolved to a
    /// video-only adaptive stream + separate audio; nil (the normal case) changes nothing.
    var playAudioSidecarURL: URL?
    var onSingleTap: (() -> Void)?
    var hdrAvailable : Bool = false
    /// Hero-preview only (#44): start muted with no audio output and loop the file forever. Set BEFORE
    /// viewDidLoad / setupMpv so the options apply at init time. The in-hero trailer layer (tvOS
    /// `TVInHeroTrailerView`) uses this for an ambient, soundless background clip; the main player never
    /// sets it, so its audio + transport behaviour is unchanged. When muted, the route-aware audio-session
    /// machinery is skipped entirely so this lightweight preview instance never claims `.playback` or
    /// disturbs the main player's audio session.
    var startMuted = false
    var loopPlayback = false
    private let mpvLog = Logger(subsystem: "com.stremiox.app", category: "mpv")
    private var configuredLiveMode = false
    /// The dynamic range currently applied to the output chain (mpv transfer curve, Metal layer
    /// colorspace, and on tvOS the display mode), or nil = "unknown, force a fresh apply". Reset to nil on
    /// every file load and teardown so the FIRST re-evaluation of a new file always applies (the guard
    /// `range != appliedDynamicRange` can never be swallowed by a stale value): an in-place HDR episode
    /// switch reliably re-enters HDR, and an HDR-to-SDR switch correctly drops it.
    /// NOTE: mpv's own target-colorspace-hint must stay OFF. It is unsupported on the Metal/MoltenVK
    /// backend and known to crash it (double free); the app does the HDR signalling itself in
    /// syncDisplayDynamicRange.
    private var appliedDynamicRange: ContentDynamicRange? = nil
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        metalLayer.frame = view.bounds
        metalLayer.framebufferOnly = false  // must be false for MoltenVK internal blits (e.g. format resolve)
        // Insurance against render-thread/main-thread deadlocks: the drawable present must never wait
        // on the main run loop's CATransaction commit (presentsWithTransaction = false, the default —
        // made explicit), and nextDrawable() must be able to time out instead of blocking the vo thread
        // forever if drawables can't be recycled while the main thread is busy.
        metalLayer.presentsWithTransaction = false
        metalLayer.allowsNextDrawableTimeout = true
        #if canImport(UIKit)
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        #elseif canImport(AppKit)
        // NSView is not layer-backed by default and its `layer` is optional, so opt in first.
        metalLayer.contentsScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.backgroundColor = NSColor.black.cgColor
        view.wantsLayer = true
        view.layer?.addSublayer(metalLayer)
        #endif

        // iOS only: a tap toggles the touch controls. On tvOS this UIKit recognizer would swallow
        // the Siri-remote Select press before SwiftUI's player controls see it, so don't add it,         // the tvOS player drives everything through SwiftUI focus + command modifiers.
        #if os(iOS)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        view.addGestureRecognizer(tap)
        #endif

        setupMpv()
        
        if let url = playUrl {
            loadFile(url, headers: playHeaders, live: playUrlLive, audioSidecar: playAudioSidecarURL)
        }
    }
    
    private var lastLaidOutSize: CGSize = .zero

    #if canImport(UIKit)
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutDrawable()
    }
    #elseif canImport(AppKit)
    override func viewDidLayout() {
        super.viewDidLayout()
        layoutDrawable()
    }
    #endif

    /// Pin the Metal drawable to the current bounds on every layout (the platform layout callbacks
    /// above forward here). Shared across UIKit and AppKit.
    private func layoutDrawable() {
        let size = view.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let didResize = lastLaidOutSize != .zero && size != lastLaidOutSize

        // Always size the drawable to the current bounds, not only on resize. If the first layout
        // leaves a stale/auto drawable, the video renders against the wrong surface and the size
        // mode (fill/fit) looks different per clip. Pinning it every layout makes every video fill
        // identically. (MetalLayer ignores <=1px sizes, so this is safe during transitions.)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = view.bounds
        metalLayer.drawableSize = CGSize(width: size.width * metalLayer.contentsScale,
                                         height: size.height * metalLayer.contentsScale)
        CATransaction.commit()

        lastLaidOutSize = size

        // libmpv sets the video output up for whatever size it STARTS at but doesn't refill the
        // surface after a live resize (the video ends up tiny in a corner after rotating). Rebuild
        // the video output (vid no → auto) at the new size.
        if didResize { reconfigureVideoOutput() }
    }

    private func reconfigureVideoOutput() {
        guard mpv != nil else { return }
        checkError(mpv_set_option_string(mpv, "vid", "no"))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            self.checkError(mpv_set_option_string(self.mpv, "vid", "auto"))
            self.applyVideoSize { self.setString($0, $1) }   // re-apply size after the rebuild
        }
    }

    @objc private func handleSingleTap() { onSingleTap?() }

    #if os(iOS)
    /// Force the player into landscape (or back to portrait), for users who keep
    /// device auto-rotation off. Uses the iOS 16+ scene geometry request. (tvOS has no
    /// rotation, it's always landscape, so this is iOS-only.)
    func setOrientation(landscape: Bool) {
        guard let scene = view.window?.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    #endif

    /// tvOS and iOS default the audio session to `soloAmbient`, which does not reliably route to
    /// an external receiver or soundbar over HDMI eARC: some setups get NO audio at all while the
    /// system and other apps play fine (reported on Apple TV 4K + eARC soundbar, while the same
    /// hardware has sound in other players). A video player must claim `.playback`; `.moviePlayback`
    /// mode also lets multichannel PCM (decoded TrueHD / DTS-HD / Atmos) reach the receiver. Set
    /// before mpv's audio output is created.
    /// Output channels the active audio route can take. Read after the session is active so the
    /// mpv channel-layout policy can be chosen: a stereo endpoint must get a DOWNMIX or a
    /// multichannel (5.1/Atmos) stream renders into a 2-channel sink as SILENCE (the "UI sounds
    /// play but the movie is silent" report). A real receiver advertising >2 still gets native
    /// multichannel PCM, preserving the 0.2.43 eARC fix.
    private var outputChannels = 2

    /// The mpv `audio-channels` policy for the current AudioOutputMode and route. Stereo forces a
    /// 2.0 downmix every endpoint can play; Surround forces the full layout for an under-reporting
    /// receiver; Auto downmixes a stereo route but keeps native multichannel for a real receiver.
    private var channelPolicy: String {
        #if canImport(UIKit)
        // AirPods: prefer a multichannel layout the system can spatialize (#88), never a forced stereo
        // downmix, unless the viewer explicitly chose Stereo. `auto-safe` stays safe here too: it falls
        // back to stereo when the route truly cannot take more, so this never silences AirPods.
        if routeIsAirPods, AudioOutputMode.current != .stereo { return "auto-safe" }
        // A route that can only render stereo (TV built-in speakers, AirPlay) silently fails to open
        // a decoded multichannel layout: force a 2.0 downmix regardless of the chosen mode so the AO
        // always has something it can play (#78). The viewer can still pick a different route's mode
        // when a real receiver is attached; this only overrides the stereo-only endpoints.
        if routeIsStereoOnly { return "stereo" }
        #endif
        switch AudioOutputMode.current {
        case .stereo: return "stereo"
        case .surround, .passthrough: return "auto"   // passthrough bitstreams the native layout untouched
        case .auto: return outputChannels > 2 ? "auto-safe" : "stereo"
        }
    }

    /// The active route's hardware output sample rate (e.g. 48000 over HDMI-ARC), read after the
    /// session is active. 0 = unknown, do not force a rate.
    private var outputSampleRate: Double = 0

    #if canImport(UIKit)
    /// The active output route's first port type (e.g. `.HDMI`, `.builtInSpeaker`, `.airPlay`),
    /// read after the session is active. Used to keep the hard-won soundbar/eARC path on real
    /// external audio (`.HDMI` / `.usbAudio` / `.lineOut`) while giving routes that cannot drive a
    /// decoded multichannel / Atmos / passthrough config (TV built-in speakers, AirPlay) a plain,
    /// route-openable stereo config so the audiounit AO opens instead of producing silence (#78).
    private var outputPortType: AVAudioSession.Port?

    /// True when the active route can only render plain stereo PCM and must NOT be handed a native
    /// multichannel / spdif / inflated-rate config. tvOS reports the TV's own speakers as built-in
    /// when the system audio format is set to Atmos / Best-Available, and the audiounit AO then
    /// silently fails to open the negotiated multichannel layout (#78: "no sound on built-in TV
    /// speakers under Atmos/Best-Available; Passthrough freezes"). A real AVR / soundbar reaches the
    /// Apple TV over `.HDMI` (ARC/eARC), so it stays on the existing path and the 0.2.43 fix holds.
    private var routeIsStereoOnly: Bool {
        switch outputPortType {
        case .some(.builtInSpeaker), .some(.airPlay): return true
        default: return false
        }
    }

    /// True when the active route is AirPods (or another A2DP / LE Bluetooth audio sink). They can take a
    /// system-spatialized multichannel layout (#88 Spatial Audio) but can NEVER take a raw spdif
    /// bitstream, so passthrough is never armed on this route.
    private var routeIsAirPods: Bool {
        switch outputPortType {
        case .some(.bluetoothA2DP), .some(.bluetoothLE): return true
        default: return false
        }
    }
    #endif

    private func configureAudioSession() {
        // AVAudioSession is iOS/tvOS only; on macOS mpv's coreaudio AO owns audio routing, so this
        // is a no-op there.
        #if canImport(UIKit)
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback + setActive is the issue-20 eARC fix (audio routes to the receiver instead
            // of soloAmbient). The MODE here is only best-effort: mpv's ao_audiounit re-issues
            // setCategory(.playback)+setMode(.moviePlayback)+setActive on every AO open (verified in
            // libmpv 0.41.0 source), so it governs only the brief pre-init window. The REAL
            // soundbar fix is the sample rate below, not the mode.
            let mode: AVAudioSession.Mode = AudioOutputMode.current == .stereo ? .default : .moviePlayback
            try session.setCategory(.playback, mode: mode, options: [])
            // Request 48 kHz BEFORE setActive: HDMI/eARC links run at 48 kHz, so a 48 kHz source
            // (TrueHD/DD+/most movies) passes through un-resampled instead of the session sitting at 44.1 kHz
            // and forcing a downsample. The OS clamps to a true 44.1k-only sink (no-op there). The tvOS
            // sampleRatePolicy below still pins mpv's resampler to whatever rate the route opens at (#78).
            try? session.setPreferredSampleRate(48_000)
            try session.setActive(true)
            // Read the route FIRST: the multichannel decision below depends on it.
            outputPortType = session.currentRoute.outputs.first?.portType
            // #78 DIAGNOSTIC: the reporter's Apple TV is silent under Dolby Atmos but plays fine under Dolby
            // Digital 5.1, and there is no Atmos hardware here to reproduce against. Log the route's port
            // type, intrinsic max channels, and rate in BOTH states so the discriminator (what the session
            // reports differently under Atmos vs working 5.1) is visible in the device log. Read the
            // intrinsic max BEFORE opting into multichannel content, so it reflects the route itself.
            let intrinsicMaxChannels = session.maximumOutputNumberOfChannels
            NSLog("[#78 audio] route=\(outputPortType?.rawValue ?? "nil") maxOutChannels=\(intrinsicMaxChannels) sampleRate=\(session.sampleRate)")
            // #78: re-assert the route's OWN realized rate as the preferred rate so the AudioUnit opens at a
            // rate the locked Atmos/eARC route actually accepts. This backstops the pre-activation 48 kHz hint
            // above: if the route opened at its native rate (already 48k on eARC, or a different fixed rate),
            // this pins to that realized rate; on every other route the session already reports its native rate
            // so this is a no-op. Keep it (do NOT remove): it is part of the #78 eARC-silence fix.
            if session.sampleRate >= 8000 { try? session.setPreferredSampleRate(session.sampleRate) }
            // #88 / #78: advertise multichannel content ONLY on routes that can actually OPEN a multichannel
            // layout. AirPods take a system head-tracked Spatial Audio layout. For wired/receiver routes we
            // now drive this off the route's OWN reported capability (intrinsic max > 2) instead of trusting
            // the port type alone: an Apple TV outputs over HDMI and reports `.HDMI` even when its system
            // audio format is plain stereo or an Atmos layout the audiounit AO cannot open, which advertised
            // multichannel and left the movie SILENT (#78). A route reporting only 2 intrinsic channels now
            // stays stereo so the AO opens. Forced stereo routes (TV built-in speakers / AirPlay) stay stereo
            // exactly as before, preserving the working path.
            let routeIsMultichannelCapable = !routeIsStereoOnly && (routeIsAirPods || intrinsicMaxChannels > 2)
            if #available(iOS 15.0, tvOS 15.0, *) {
                try? session.setSupportsMultichannelContent(routeIsMultichannelCapable)
            }
            outputChannels = max(session.maximumOutputNumberOfChannels, 2)
            outputSampleRate = session.sampleRate
        } catch {
            mpvLog.error("AVAudioSession .playback setup failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    /// mpv `audio-samplerate` for the current route, or nil to leave mpv on the content rate.
    /// THE soundbar fix: mpv's audiounit AO sets its RemoteIO input to the CONTENT rate and never
    /// resamples to the route, so 44.1k (or hi-res) content over a fixed ~48k HDMI-ARC link is
    /// silently dropped (no audio on the soundbar, fine on a bare TV, plays in official Stremio
    /// which resamples). Forcing mpv's own resampler to the route's actual rate before the AO
    /// hand-off fixes it. Gated to stereo routes (<=2ch) so a true multichannel receiver keeps its
    /// native-rate PCM path untouched.
    private var sampleRatePolicy: Int? {
        guard outputSampleRate >= 8000 else { return nil }
        #if canImport(UIKit)
        // Force the route's own rate on a stereo-only endpoint too: under Atmos / Best-Available the
        // TV's built-in speakers can advertise >2 channels yet still need mpv to resample to the
        // route, or the AO opens onto a layout/rate it can't drive and goes silent (#78).
        if routeIsStereoOnly { return Int(outputSampleRate.rounded()) }
        #endif
        #if os(tvOS)
        // #78: ALWAYS force the route's native rate on tvOS HDMI. ao_audiounit does NOT resample to the route,
        // so on a >2ch Atmos / Best-Available route, leaving mpv on the decoded content rate makes the AudioUnit
        // open at a rate the locked eARC link rejects -> the AO never opens -> tvOS swaps in the null AO ->
        // dead silence (silent EVEN at Stereo, because the old `outputChannels <= 2` gate keyed on the ROUTE's
        // channel count, not the user's mode). Pinning mpv's resampler to the route rate makes the AO open; the
        // decoded channel LAYOUT is untouched (only the clock is pinned), so a working receiver is unaffected.
        return Int(outputSampleRate.rounded())
        #else
        guard outputChannels <= 2 else { return nil }
        return Int(outputSampleRate.rounded())
        #endif
    }

    func setupMpv() {
        // The in-hero trailer preview (#44) is silent, so it must NOT claim the `.playback` audio
        // session: doing so would interrupt other audio and fight the main player's session. Only the
        // real player configures the route-aware audio policy.
        if !startMuted { configureAudioSession() }
        mpv = mpv_create()
        if mpv == nil {
            print("failed creating context\n")
            exit(1)
        }

        // Hero-preview options (#44), set before mpv_initialize so they take at init time. `mute=yes`
        // gives a soundless ambient clip (no audio output is ever opened); `loop-file=inf` makes mpv
        // re-play the trailer forever with no app-side EOF handling. The main player sets neither.
        if startMuted { checkError(mpv_set_option_string(mpv, "mute", "yes")) }
        if loopPlayback { checkError(mpv_set_option_string(mpv, "loop-file", "inf")) }

        // Do NOT apply mpv's "fast" profile by default. It overrides gpu-next/libplacebo's sharp default
        // upscaler (lanczos) with bilinear and disables debanding/dither, which made upscaled video look
        // soft/blurry — the "player size/quality is pathetic vs the 0.1.6 IPA" report. v0.1.6 left this
        // OFF and looked sharp. Apple-Silicon's gpu-next + VideoToolbox defaults are already performant;
        // re-enable per-device ONLY if a constrained GPU stutters on 4K (the original reason it was added).
        // checkError(mpv_set_option_string(mpv, "profile", "fast"))

        // https://mpv.io/manual/stable/#options
#if DEBUG
        checkError(mpv_request_log_messages(mpv, "v"))
#else
        checkError(mpv_request_log_messages(mpv, "no"))
#endif
#if os(macOS)
        checkError(mpv_set_option_string(mpv, "input-media-keys", "yes"))
#endif
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayer))
        checkError(mpv_set_option_string(mpv, "subs-match-os-language", "yes"))
        checkError(mpv_set_option_string(mpv, "subs-fallback", "yes"))
        // Point libass at the bundled fonts for non-Latin subtitle rendering. Every target ships
        // the same set in a "fonts" folder reference today; the bundle-root fallback stays in
        // case a build ever lays the optional font resources out flat.
        if let res = Bundle.main.resourcePath {
            let fontsSubdir = res + "/fonts"
            let fontsDir = FileManager.default.fileExists(atPath: fontsSubdir) ? fontsSubdir : res
            checkError(mpv_set_option_string(mpv, "sub-fonts-dir", fontsDir))
        }
        checkError(mpv_set_option_string(mpv, "embeddedfonts", "yes"))
        // User-configured subtitle appearance (font / size / colour / background), see SubtitleStyle.
        // sub-font is part of mpvOptions; the bundled Noto fonts above stay the non-Latin fallback.
        for (name, value) in SubtitleStyle.mpvOptions {
            checkError(mpv_set_option_string(mpv, name, value))
        }
        checkError(mpv_set_option_string(mpv, "vo", "gpu-next"))
        checkError(mpv_set_option_string(mpv, "gpu-api", "vulkan"))
        checkError(mpv_set_option_string(mpv, "gpu-context", "moltenvk"))
        // Hardware-decode via VideoToolbox on both device and the (Apple-Silicon) simulator.
        // This keeps decoded frames as GPU textures, which matters for more than speed: software
        // decode puts frames in CPU memory, forcing libplacebo to upload them via a PBO, and
        // that path (vkAllocateMemory → MTLSimDevice) crashes the simulator's Metal driver on
        // large 4K frames. GPU-resident frames skip the upload entirely. A launch arg overrides
        // for diagnostics: -stremiox-hwdec <videotoolbox|no|auto-safe>.
        let hwdec: String = {
            let a = ProcessInfo.processInfo.arguments
            if let i = a.firstIndex(of: "-stremiox-hwdec"), i + 1 < a.count { return a[i + 1] }
            return "videotoolbox"
        }()
        checkError(mpv_set_option_string(mpv, "hwdec", hwdec))
        mpvLog.log("hwdec = \(hwdec, privacy: .public)")
        checkError(mpv_set_option_string(mpv, "video-rotate", "no"))
        // Quality tone curve for any HDR -> SDR mapping (used when the Dolby Vision /
        // HDR compatibility toggle forces SDR output for displays that show DV P7
        // remuxes as green/purple garbage). Harmless for native SDR content.
        checkError(mpv_set_option_string(mpv, "tone-mapping", "bt.2446a"))
        // Apply the saved video-size mode up front so the first frame is sized correctly + uniformly.
        applyVideoSize { self.checkError(mpv_set_option_string(self.mpv, $0, $1)) }

        // Debrid/addon stream URLs (e.g. debridio) are web-ready links meant for a browser
        // <video>; their resolvers often 500/504 on ffmpeg's default "Lavf/*" User-Agent. The
        // web player fetched them with the browser UA, so present a Safari-like UA here. Also
        // follow HTTP redirects to the final CDN file (debrid resolvers 30x to it).
        checkError(mpv_set_option_string(mpv, "user-agent",
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"))
        checkError(mpv_set_option_string(mpv, "network-timeout", "30"))
        // Reconnect on dropped/stalled HTTP (debrid CDNs sometimes reset mid-stream); without this
        // a hiccup looks like an infinite buffer. Followed by hard failure → MPV_EVENT_END_FILE.
        checkError(mpv_set_option_string(mpv, "stream-lavf-o",
            "reconnect=1,reconnect_streamed=1,reconnect_delay_max=7"))

        // Read-ahead cache: buffer past the play head so transient network dips on big 4K streams
        // don't stall playback. These are the exact values proven on-device for weeks (0.2.5 to
        // 0.2.10). The deeper disk-backed cache experiment (2 GiB via cache-on-disk, 0.2.11) was
        // reverted: real Apple TVs crashed at a constant ~21 seconds into heavy 4K remuxes, the
        // signature of a fixed-rate fill hitting a hard ceiling, while the simulator (with the
        // Mac's RAM and disk underneath) played the same file untouched. Do not re-raise these
        // without on-device soak testing of the same DV remuxes.
        checkError(mpv_set_option_string(mpv, "cache", "yes"))
        checkError(mpv_set_option_string(mpv, "demuxer-readahead-secs", "300"))
#if os(macOS)
        checkError(mpv_set_option_string(mpv, "demuxer-max-back-bytes", "64MiB"))
        checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", "256MiB"))
#else
        // iOS/tvOS: the server is in-process and jetsam-bound and its RSS includes these mpv buffers, so
        // keep the back-buffer (already-played, for seek-back) small. The per-file demuxer-max-bytes below
        // overrides the forward cache; this init is just the pre-load default.
        checkError(mpv_set_option_string(mpv, "demuxer-max-back-bytes", "24MiB"))
        checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", "128MiB"))
#endif

        // Configurable ON-DISK streaming/seek cache (Settings → "Streaming cache"). When enabled, the
        // big forward buffer is backed by a Caches subdirectory instead of RAM, so a viewer can pick a
        // large cache (seek minutes ahead with no re-buffer, pre-cache) WITHOUT spending the jetsam-bound
        // in-process RAM budget. The actual byte budget is the clamped `demuxer-max-bytes` applied per
        // file in loadFile (DiskCacheSetting.resolvedMaxBytes — always bounded by free disk, never
        // unlimited). The hero-preview (#44) is a tiny silent loop, so it stays on the in-memory cache.
        //
        // `cache-on-disk` is a stable libmpv option (mpv 0.30+, present in MPVKit 0.41); if a future
        // build ever drops it, these lines no-op and mpv falls back to the in-memory cache that the same
        // clamped `demuxer-max-bytes` already bounds — so the safety guarantee holds either way.
        if !startMuted, DiskCacheSetting.diskCacheEnabled, let cacheDir = DiskCacheSetting.ensureCacheDirectory() {
            checkError(mpv_set_option_string(mpv, "cache-on-disk", "yes"))
            checkError(mpv_set_option_string(mpv, "cache-dir", cacheDir))
            mpvLog.log("disk cache armed at \(cacheDir, privacy: .public), budget \(DiskCacheSetting.resolvedMaxBytes(), privacy: .public) bytes")
        }

        // HLS: pick the HIGHEST-bandwidth variant of an adaptive master playlist. mpv's documented
        // default is already `max`, but add-ons that serve a single adaptive master (e.g. KhmerHub's
        // OK.ru streams) were starting at the lowest rendition — the "144p instead of 720p" report —
        // so set it explicitly and unambiguously before init. (If a stream is proxied through the
        // embedded server, the playlist rewrite must preserve all variants for this to take effect.)
        checkError(mpv_set_option_string(mpv, "hls-bitrate", "max"))

//        checkError(mpv_set_option_string(mpv, "target-colorspace-hint", "yes")) // HDR passthrough
//        checkError(mpv_set_option_string(mpv, "tone-mapping-visualize", "yes"))  // only for debugging purposes
//        checkError(mpv_set_option_string(mpv, "profile", "fast"))   // can fix frame drop in poor device when play 4k

        // Audio channel policy. A 5.1/EAC3/Atmos stream rendered into a 2-channel sink with no
        // downmix is SILENT (the "movie has no sound but the app's own UI sounds play, and the
        // same stream has audio in official Stremio" report). UI sounds are already stereo, so
        // they survive; a multichannel movie does not. mpv's default `auto-safe` negotiates a
        // layout against what the route reports, which on built-in / ARC / stereo-soundbar paths
        // can advertise multichannel yet deliver nothing. So: gate on the route's real output
        // channel count (captured in configureAudioSession after the session went active). A true
        // receiver advertising >2 keeps native multichannel PCM, preserving the 0.2.43 eARC fix;
        // anything <=2 is forced to a stereo DOWNMIX so the endpoint always gets sound. The viewer
        // can override the whole policy with the Audio Output setting (Auto / Stereo / Surround).
        // Audio output policy is iOS/tvOS only: mpv there uses the low-level audiounit AO that does
        // not resample or downmix to the route on its own, so we drive it (the soundbar fixes). On
        // macOS mpv uses the coreaudio AO, which negotiates rate, channels, and routing natively
        // like desktop mpv, so we leave audio at mpv's defaults.
        #if canImport(UIKit)
        #if os(tvOS)
        // #78/#101: prefer the avfoundation AO (AVSampleBufferAudioRenderer) over audiounit on tvOS. The
        // low-level audiounit AO cannot OPEN an Apple TV HDMI route that "continuous audio playback" (a 2nd-gen+
        // feature) expands to many channels -> dead silence; avfoundation negotiates that route the way AVPlayer
        // does, and falls back to audiounit if unavailable. Requires MPVKit >= 0.41.0-n8.1.2 (PR #73 builds the
        // avfoundation AO for tvOS). THIS is the actual fix; the rate/channel tweaks below are belt-and-suspenders.
        checkError(mpv_set_option_string(mpv, "ao", "avfoundation,audiounit"))
        #endif
        checkError(mpv_set_option_string(mpv, "audio-channels", channelPolicy))
        // Passthrough mode bitstreams Dolby/DTS to a capable AV receiver instead of decoding to PCM. On tvOS
        // raw spdif WEDGES the AO open and freezes the WHOLE player (#78/#101 "passthrough freezes the video"),
        // even on a real receiver - and with the avfoundation AO now decoding while the system negotiates the
        // HDMI/eARC format (incl Atmos) to the receiver, app-side bitstream is both unnecessary and unsafe. So
        // never arm spdif on tvOS. iOS keeps it, gated off stereo-only / AirPods routes that can't take it.
        #if !os(tvOS)
        if !routeIsStereoOnly, !routeIsAirPods, let spdif = AudioOutputMode.current.spdifCodecs {
            checkError(mpv_set_option_string(mpv, "audio-spdif", spdif))
        }
        #endif
        // AO-open failure handling, route-aware. On a stereo-only route (TV built-in / AirPlay) the
        // failure mode is the user being stranded silent or the file freezing, so allow the null AO:
        // playback keeps running (video continues) instead of wedging, the graceful fallback for #78.
        // #78 SAFETY NET: tvOS always outputs over HDMI to a TV / AVR, and the reported Atmos failure is
        // the audiounit AO failing to open the negotiated layout -> silent + frozen. Allow the null AO on
        // every tvOS route too, so a failed open degrades to no-audio-but-video-keeps-playing instead of a
        // dead player. This is the lowest-risk mitigation; it does not change a route where the AO opens
        // fine (working 5.1 / stereo keep their audio). iOS/macOS keep `no` on a real external route so a
        // soundbar mis-negotiation still surfaces as a diagnosable log rather than silently dropping audio.
        // #78: do NOT blanket-null on tvOS. With the route rate now FORCED (sampleRatePolicy), the AO opens on
        // the Atmos/eARC route; the null AO is reserved for routes that genuinely can't open (built-in speakers
        // / AirPlay, caught by routeIsStereoOnly). Keeping "no" on the HDMI path lets a residual open failure
        // surface in the log instead of silently dropping to no-audio (the exact #78 failure mode).
        let fallbackToNull = routeIsStereoOnly ? "yes" : "no"
        checkError(mpv_set_option_string(mpv, "audio-fallback-to-null", fallbackToNull))
        // THE soundbar fix: resample to the route's actual rate so a rate mismatch over a fixed-rate
        // HDMI-ARC link can't drop to silence (mpv's audiounit AO does not resample to the route).
        if let rate = sampleRatePolicy {
            checkError(mpv_set_option_string(mpv, "audio-samplerate", String(rate)))
        }
        appliedAudioPolicy = (channelPolicy, sampleRatePolicy ?? 0)   // baseline so reapply only fires on a real change
        mpvLog.log("audio-channels = \(self.channelPolicy, privacy: .public), audio-samplerate = \(self.sampleRatePolicy.map(String.init) ?? "content", privacy: .public) (route \(self.outputChannels) ch @ \(Int(self.outputSampleRate)) Hz)")
        #endif

        // Video upscaling / quality preset (Performance / Standard / High Quality / Anime4K). Applied as a
        // baseline BEFORE the power-user customMpvOptions below, so a custom snippet still wins. Standard is
        // a no-op (keeps libplacebo's sharp defaults). Takes effect on the next played file, like customMpvOptions.
        let upscaling = PlaybackSettings.videoUpscaling
        for (key, value) in upscaling.mpvOptions {
            let err = mpv_set_option_string(mpv, key, value)
            if err < 0 {
                mpvLog.error("upscaling option rejected: \(key, privacy: .public)=\(value, privacy: .public) (\(String(cString: mpv_error_string(err)), privacy: .public))")
            }
        }
        // Anime4K preset: the scaler prerequisites above came from mpvOptions; the glsl-shaders chain
        // itself is a list of bundle paths only knowable at runtime, so set it here. Resolved + joined
        // by anime4kShaderPaths; an empty result (preset not anime4k, or a missing/incomplete bundle)
        // leaves glsl-shaders untouched so the player still runs with the baseline scalers.
        if let shaderList = anime4kShaderPaths(for: upscaling) {
            let err = mpv_set_option_string(mpv, "glsl-shaders", shaderList)
            if err < 0 {
                mpvLog.error("glsl-shaders rejected: \(String(cString: mpv_error_string(err)), privacy: .public)")
            } else {
                mpvLog.log("glsl-shaders set for Anime4K preset")
            }
        }
        mpvLog.log("video upscaling preset = \(upscaling.rawValue, privacy: .public)")

        // Power-user custom mpv options. Applied LAST, after every VortX baseline option above, so an
        // advanced viewer can override the defaults (the "mpv conf" setting). Each option is set with
        // its own fail-safe: a bad key/value logs and is skipped, it must never abort the baseline
        // config or crash playback. Set here (before mpv_initialize) so options that are pre-init-only
        // also take effect; properties that only apply at runtime would need the property API instead,
        // a known limitation documented in the setting hint.
        for (key, value) in PlaybackSettings.parsedCustomMpvOptions {
            let err = mpv_set_option_string(mpv, key, value)
            if err < 0 {
                mpvLog.error("custom mpv option rejected: \(key, privacy: .public)=\(value, privacy: .public) (\(String(cString: mpv_error_string(err)), privacy: .public))")
            } else {
                mpvLog.log("custom mpv option applied: \(key, privacy: .public)=\(value, privacy: .public)")
            }
        }

        checkError(mpv_initialize(mpv))

        mpv_observe_property(mpv, 0, MPVProperty.videoParamsSigPeak, MPV_FORMAT_DOUBLE)
        // Also observe the transfer characteristic (gamma): HLG content can sit at sig-peak ~1.0, so the
        // sig-peak observer alone never flips it to HDR. A late gamma settle (pq/hlg arriving after the
        // first sig-peak event on an in-place switch) re-drives the dynamic-range apply.
        mpv_observe_property(mpv, 0, MPVProperty.videoParamsGamma, MPV_FORMAT_STRING)
        mpv_observe_property(mpv, 0, MPVProperty.pausedForCache, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.timePos, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.duration, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.seekable, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.demuxerCacheTime, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.pause, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.trackList, MPV_FORMAT_NONE)
        // mpv gets a retained relay holding a WEAK controller reference, never the controller
        // itself: an unretained `self` was a use-after-free if the wakeup fired (on mpv's
        // internal thread) while the controller was mid-dealloc.
        let relay = Unmanaged.passRetained(WakeupRelay(self))
        wakeupRelay = relay
        mpv_set_wakeup_callback(self.mpv, { ctx in
            guard let ctx else { return }
            Unmanaged<WakeupRelay>.fromOpaque(ctx).takeUnretainedValue().controller?.readEvents()
        }, relay.toOpaque())

        setupNotification()
    }

    /// The mpv `glsl-shaders` value for an Anime4K preset: the bundled shader chain resolved to absolute
    /// bundle paths, in the order Anime4K's Mode A requires, joined with mpv's list separator (`:`).
    /// Returns nil for any non-Anime4K preset (so the caller leaves glsl-shaders alone), and also nil if
    /// NONE of the shaders resolve from the bundle, so a build that somehow shipped without the resource
    /// folder degrades to the baseline scalers instead of half-applying a broken chain. Any individual
    /// shader that can't be found is logged and skipped; a partial chain still upscales.
    private func anime4kShaderPaths(for preset: VideoUpscaling) -> String? {
        let names = preset.glslShaderFileNames
        guard !names.isEmpty else { return nil }
        let paths: [String] = names.compactMap { name in
            // The folder reference lands the files under a `shaders/` subdirectory of the bundle; fall
            // back to the bundle root in case a future build lays them out flat (mirrors the fonts dir
            // handling above).
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            if let url = Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "shaders") {
                return url.path
            }
            if let url = Bundle.main.url(forResource: stem, withExtension: ext) {
                return url.path
            }
            mpvLog.error("Anime4K shader missing from bundle: \(name, privacy: .public)")
            return nil
        }
        guard !paths.isEmpty else { return nil }
        // mpv parses glsl-shaders as a `:`-separated list and treats `\` as the escape char, so a bundle
        // path containing either (e.g. an app folder with a literal ':' is rare but legal) must be escaped
        // or mpv would split the path. Escape '\' first, then ':'.
        let escaped = paths.map { $0.replacingOccurrences(of: "\\", with: "\\\\")
                                     .replacingOccurrences(of: ":", with: "\\:") }
        return escaped.joined(separator: ":")
    }

    public func setupNotification() {
        // App-lifecycle + audio-route observers are iOS/tvOS only (UIApplication notifications and
        // AVAudioSession both exist there). On macOS mpv's coreaudio AO handles routing and the app
        // is a window, so there is nothing to observe here.
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(self, selector: #selector(enterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        // The output route can change AFTER the channel policy was chosen: a receiver powers on,
        // an eARC handshake finishes, the user swaps to a different output. mpv's AO stays
        // negotiated against the old route, which can strand audio on a layout the new endpoint
        // can't play. Re-evaluate the channel count and reapply the policy on any route change.
        NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChanged), name: AVAudioSession.routeChangeNotification, object: nil)
        #endif
    }

    #if canImport(UIKit)
    @objc public func enterBackground() {
        // Always drop video decode (fixes the black screen on return and saves GPU). On iOS, whether
        // AUDIO keeps going is the keep-alive choice (#74): continuing audio holds the AVAudioSession
        // active so iOS won't suspend the app and freeze the embedded streaming server mid-stream; opting
        // out pauses so the app can suspend and save battery/data. On tvOS, leaving the app should always
        // stop playback (there is no screen-lock-keep-listening case).
        #if os(iOS)
        if !PlaybackSettings.keepPlayingInBackground { pause() }
        #else
        pause()
        #endif
        checkError(mpv_set_option_string(mpv, "vid", "no"))
    }

    @objc public func enterForeground() {
        // Reclaim the session in case another app deactivated it while we were backgrounded,
        // then re-evaluate the audio route (it may have changed off-screen).
        do { try AVAudioSession.sharedInstance().setActive(true) } catch {
            mpvLog.error("AVAudioSession reactivate on foreground failed: \(error.localizedDescription, privacy: .public)")
        }
        applyChannelPolicy()
        checkError(mpv_set_option_string(mpv, "vid", "auto"))
        applyVideoSize { self.setString($0, $1) }   // re-apply size after the rebuild
        play()
    }

    /// The (channels, sampleRate) last pushed to mpv, so a route-change storm does not reinit the
    /// AO repeatedly. An eARC handshake emits several routeChange events in a row; reinitialising on
    /// each (and mpv's own setActive can itself emit one) risks dropouts or a feedback loop, so we
    /// only reapply when the resolved policy actually changes.
    private var appliedAudioPolicy: (String, Int)?

    /// Re-read the active route and reapply mpv's downmix + sample-rate policy when it changed. Safe
    /// mid-playback: setting these as PROPERTIES (via setString, mpv_set_property_string) reinits the
    /// AO against the new route. `mpv_set_option_string` is only valid before `mpv_initialize` (a
    /// silent no-op after), which is why the reapply path uses setString. Handles a receiver
    /// powering on or an HDMI-ARC/eARC handshake settling after the AO was first opened.
    private func applyChannelPolicy() {
        guard mpv != nil else { return }
        let session = AVAudioSession.sharedInstance()
        outputChannels = max(session.maximumOutputNumberOfChannels, 2)
        outputSampleRate = session.sampleRate
        outputPortType = session.currentRoute.outputs.first?.portType
        let next = (channelPolicy, sampleRatePolicy ?? 0)
        if let applied = appliedAudioPolicy, applied == next { return }   // no real change: don't churn the AO
        appliedAudioPolicy = next
        setString("audio-channels", next.0)
        if next.1 > 0 { setString("audio-samplerate", String(next.1)) }
        mpvLog.log("audio reapplied: channels=\(next.0, privacy: .public) samplerate=\(next.1 > 0 ? String(next.1) : "content", privacy: .public) (route \(self.outputChannels) ch @ \(Int(self.outputSampleRate)) Hz)")
    }

    @objc private func audioRouteChanged(_ note: Notification) {
        // Hop to the main actor: the notification can arrive on an arbitrary thread and we touch
        // the mpv handle. (mpv option-set is thread-safe, but keep the AVAudioSession read + log
        // ordering deterministic.)
        DispatchQueue.main.async { [weak self] in self?.applyChannelPolicy() }
    }
    #endif   // canImport(UIKit): audio-session + lifecycle observers are iOS/tvOS only

    /// Tear mpv down safely when the player closes. Clearing the wakeup callback first
    /// prevents it from firing into a deallocated controller (the crash on close), and
    /// destruction is serialized onto the event queue so it can't race `readEvents`.
    func stop() {
        NotificationCenter.default.removeObserver(self)
#if os(tvOS)
        // Hand the TV back its default display mode; the view can already be
        // detached here, so HDRDisplayMode falls back to the app's window.
        HDRDisplayMode.reset(in: viewIfLoaded?.window)
#endif
        appliedDynamicRange = nil
        guard let handle = mpv else { return }
        // Nil the handle SYNCHRONOUSLY so exactly one owner destroys it: deinit's safety net
        // sees nil (no double terminate when dealloc beats the queued block), the event drain
        // stops picking it up, and every property accessor becomes a guarded no-op.
        mpv = nil
        mpv_set_wakeup_callback(handle, nil, nil)
        // Tell the core to wind down NOW (mpv_command_string is thread-safe): decode and network
        // stop immediately. Without this, destruction waited its turn on the event queue, and a
        // stalled network read kept a ZOMBIE core decoding 4K invisibly for over a minute after
        // close (seen live), starving the UI hard enough to wedge the tab bar.
        mpv_command_string(handle, "quit")
        let relay = wakeupRelay
        wakeupRelay = nil
        queue.async {
            mpv_terminate_destroy(handle)
            relay?.release()   // no callbacks after terminate_destroy; safe to drop the relay
        }
    }

    deinit {
        // Safety net: if the view controller is torn down without stop() (e.g. an
        // unexpected dealloc), make sure mpv can't call back into freed memory.
        if let handle = mpv {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv = nil
            mpv_terminate_destroy(handle)
        }
        wakeupRelay?.release()
    }

    /// mpv's stock User-Agent, captured once so a stream with custom headers can never leak
    /// its UA into the next stream.
    private lazy var defaultUserAgent = getString("user-agent") ?? ""

    func loadFile(
        _ url: URL,
        headers: [String: String]? = nil,
        live: Bool = false,
        audioSidecar: URL? = nil
    ) {
        // Re-arm HDR detection for THIS file. appliedDynamicRange otherwise persists from the previous
        // file, so an in-place episode / source switch left it stale and the guard SKIPPED re-applying the
        // colorspace — the new (HDR) episode then kept rendering in the previous SDR output (dull) until a
        // full replay rebuilt the player. Resetting to the nil SENTINEL (not .sdr) means the next
        // re-evaluation ALWAYS applies the new file's true range (nil != any real range), so an HDR->HDR,
        // HDR->SDR, or SDR->HDR switch all re-tag correctly. The re-evaluation no longer depends on the
        // value-coalesced sig-peak property event firing (two same-mastering-peak HDR episodes fire none):
        // MPV_EVENT_VIDEO_RECONFIG drives reapplyDynamicRange() on every new file. This was the "~2 of 3
        // auto-advanced / skipped episodes are washed out" report. (HDR is only verifiable on a real HDR
        // display, not the Simulator.)
        appliedDynamicRange = nil
        // The URL / audio sidecar mpv actually opens. `url` and `audioSidecar` are `let` params; a googlevideo
        // trailer swaps these to their local VXTrailerProxy (127.0.0.1) equivalents below, BEFORE they are handed
        // to mpv via `args` and the `audio-files` append. Everything downstream (args, isLocalStream, the audio
        // sidecar append, the redacted log) reads these, so the swap flows through the rest of loadFile untouched.
        var playURL = url
        var sidecar = audioSidecar
        var args = [playURL.absoluteString]
        var options = [String]()

        args.append("replace")

        // Per-stream HTTP headers (behaviorHints.proxyHeaders): some add-ons front CDNs that
        // require a specific Referer or a browser User-Agent; without them the server rejects
        // the stream ("loading failed" on sources that play fine in clients that apply them).
        // ALWAYS set all three so the previous file's headers never bleed into this one.
        var fields: [String] = []
        var userAgent = ""
        var referrer = ""
        for (name, value) in headers ?? [:] {
            switch name.lowercased() {
            case "user-agent":         userAgent = value
            case "referer", "referrer": referrer = value
            default:                    fields.append("\(name): \(value)")
            }
        }
        setString("user-agent", userAgent.isEmpty ? defaultUserAgent : userAgent)
        setString("referrer", referrer)
        setString("http-header-fields", fields.joined(separator: ","))

        // yt-direct googlevideo streams no longer play when handed to mpv directly: googlevideo now 403s every
        // Range shape FFmpeg can send (open-ended `bytes=0-` and no-Range alike), so libmpv reports
        // `endFileError reason=loading failed` (the "Trailer unavailable" overlay) even with the correct UA.
        // The proven fix is VXTrailerProxy: a local 127.0.0.1 HTTP range-proxy that answers mpv with a clean 206
        // and fetches googlevideo in bounded <=1 MiB `&range=` windows (each a plain HTTP 200), sending the
        // InnerTube IOS-client UA upstream. So DETECT the googlevideo host here and SWAP both the video URL and
        // the audio sidecar to their proxy (127.0.0.1) equivalents BEFORE mpv opens them; the proxy falls back to
        // the raw URL (nil) if it cannot start, so playback degrades to the old direct path rather than breaking.
        // After the swap mpv talks to 127.0.0.1, which the isLocalStream read-ahead branch below already handles.
        // The UA-force is kept as a harmless fallback: it targets the raw googlevideo host and simply will not
        // match 127.0.0.1 once proxied. mpv's `user-agent` option applies to EVERY stream this load opens,
        // including the `--audio-files` sidecar. Non-googlevideo streams are untouched, so debrid/direct/torrent
        // playback keeps its own UA.
        let isGoogleVideo = { (u: URL?) in u?.host?.contains("googlevideo") ?? false }
        if isGoogleVideo(url) || isGoogleVideo(audioSidecar) {
            if isGoogleVideo(url) {
                playURL = VXTrailerProxy.shared.proxied(url, mime: "video/mp4") ?? url
            }
            if let audioSidecar, isGoogleVideo(audioSidecar) {
                sidecar = VXTrailerProxy.shared.proxied(audioSidecar, mime: "audio/mp4") ?? audioSidecar
            }
            args[0] = playURL.absoluteString
            setString("user-agent", YouTubeDirectResolver.googlevideoUserAgent)
            // Referer/extra headers from a browser context would only confuse googlevideo's UA binding.
            setString("referrer", "")
            setString("http-header-fields", "")
            NSLog("[yt-probe] loadFile googlevideo: proxying via 127.0.0.1 playHost=%@ sidecar=%@ applyingUA=%@",
                  playURL.host ?? "?", sidecar == nil ? "none" : (sidecar!.host ?? "?"),
                  YouTubeDirectResolver.googlevideoUserAgent)
        }

        // yt-direct adaptive pair: mount the external audio stream so mpv merges it with the video-only
        // file at load (`--audio-files`, applied per file at load time). ALWAYS clear first so a previous
        // trailer's sidecar never bleeds into the next stream (same hygiene as the headers above).
        // `change-list append` hands the URL to mpv as ONE argument: setting the property as a string
        // would re-parse it against the path-list separator (":"), which every https URL contains.
        command("change-list", args: ["audio-files", "clr", ""])
        if let sidecar {
            command("change-list", args: ["audio-files", "append", sidecar.absoluteString])
        }

        // Size the read-ahead by where the bytes come from. A torrent plays from the embedded server
        // on 127.0.0.1, which already buffers the file into its OWN disk cache, so a 512 MiB mpv
        // read-ahead just double-buffers it in RAM. Stacked on the embedded server's own memory, that
        // drove the whole process RSS up without bound during a torrent (the heartbeat caught it climb
        // 161 -> 499 MB and still rising) until tvOS jetsam-killed the app -- the "server died" with the
        // torrent still playing. So a LOCAL (torrent) stream gets a small read-ahead; a remote debrid or
        // direct CDN keeps the full buffer for network resilience. Set per file at runtime.
        let isLocalStream = playURL.host == "127.0.0.1" || playURL.host == "localhost"
            || (playURL.host?.hasSuffix("strem.io") ?? false)
        configureLiveMode(live)
        let readAhead: String
        if live {
            readAhead = "64MiB"
        } else if PerformanceMode.reduced {
            readAhead = isLocalStream ? "64MiB" : "96MiB"   // 2 GB Apple TV HD: keep buffers tightest
        } else {
            #if os(macOS)
            readAhead = isLocalStream ? "128MiB" : "512MiB"
            #else
            // iOS/tvOS run the streaming server IN-PROCESS and are jetsam-bound. Crucially, on iOS the node
            // server's reported RSS INCLUDES this mpv demuxer cache (same process), so a big read-ahead is
            // counted twice toward the jetsam ceiling AND grows even on DEBRID (direct CDN) playback — which
            // is why the server "dies" on debrid, not just torrents. A 128 MiB read-ahead (down from 256)
            // is still ample for a fast debrid link and shaves ~128 MiB off the peak; the Mac (out-of-process
            // server + swap) keeps the larger buffer for slow-CDN resilience.
            readAhead = isLocalStream ? "96MiB" : "128MiB"
            #endif
        }
        // With the on-disk cache armed (Settings → Streaming cache) we lift `demuxer-max-bytes` for a
        // REMOTE (debrid/direct CDN) VOD stream so the viewer gets a bigger seek-ahead buffer. CRITICAL:
        // `demuxer-max-bytes` is mpv's HARD in-memory forward-buffer cap, and `cache-on-disk` does NOT
        // reliably move it to the Caches dir on this MPVKit build, so the budget is held in RAM. Setting
        // it to the full disk budget (hundreds of MB to GBs) jetsam-killed the Apple TV ~47s in, with the
        // buffer ~800s / ~700MB ahead, even on the 3 GB ATV 4K. So clamp the APPLIED value to a device-safe
        // RAM ceiling: the chosen cache size can lift the buffer above the proven default, but never past
        // what the device survives. demuxer-max-bytes is a hard byte cap, so it bounds RAM regardless of
        // bitrate or whether cache-on-disk offloads. (A LOCAL torrent buffers into the embedded server's
        // own disk cache, and live owns its tight buffers, so those keep the RAM-safe read-ahead above.)
        if DiskCacheSetting.diskCacheEnabled, !live, !isLocalStream {
            // DEVICE-SOAK ITEM: the prior flat 256 MiB ceiling masked the Settings slider and starved the
            // read-ahead to ~25-30s on debrid (the owner had 120-200s before). The ATV 4K (4 GB + memory
            // entitlement) holds ~75-90s at 4K within 768 MiB, ~3x runway, which also resolves the lag and
            // ~7 dropped frames (the buffer was draining on CDN dips). 768 MiB is deliberately BELOW the
            // ~700 MB+ unclamped level that jetsam-killed the device; keep ATV HD (reduced) tight at 128 MiB;
            // the Mac (out-of-process server + swap) gets the generous 1 GiB ceiling.
            // The player-teardown straddle that caused the earlier whole-device hang is fixed separately, so
            // this is the buffer's first real restore. If it jetsams on soak, step 768 -> 512 MiB.
            //
            // THE RECURRING JETSAM KNOB: these ceilings are now the RemoteConfig `player.readAhead.*` dials
            // (debrid 64..900, reduced 64..192, mac 128..1536, floor fixed 64). Baked fallbacks (768/128/1024)
            // equal the shipping literals, so a null / absent remote config is behaviorally identical to today;
            // a bad value clamps to the baked default and can never breach the jetsam-safe range.
            #if os(macOS)
            let isMac = true
            #else
            let isMac = false
            #endif
            let ramCeiling = Int64(RemoteConfig.snapshot.readAheadDebridCeilingBytes(reduced: PerformanceMode.reduced, isMac: isMac))
            let applied = min(DiskCacheSetting.resolvedMaxBytes(), ramCeiling)
            mpv_set_property_string(mpv, "demuxer-max-bytes", String(applied))
        } else {
            mpv_set_property_string(mpv, "demuxer-max-bytes", readAhead)
        }

        if !options.isEmpty {
            args.append(options.joined(separator: ","))
        }

        // Log only scheme://host/path: debrid and direct-CDN URLs carry API tokens / signed queries in the
        // userinfo and query string, which must not land in the device's persistent unified log.
        let redactedURL = "\(playURL.scheme ?? "?")://\(playURL.host ?? "?")\(playURL.path)"
        mpvLog.log("loadFile → \(redactedURL, privacy: .public)\(sidecar != nil ? " (+audio sidecar)" : "", privacy: .public)")
        command("loadfile", args: args)
    }

    private func configureLiveMode(_ live: Bool) {
        guard configuredLiveMode != live else { return }
        configuredLiveMode = live
        if live {
            mpv_set_property_string(mpv, "demuxer-readahead-secs", "18")
            mpv_set_property_string(mpv, "demuxer-max-back-bytes", "8MiB")
            mpv_set_property_string(mpv, "demuxer-lavf-o", "live_start_index=-3")
            // The VOD/debrid reconnect settings are hostile to HLS live: normal
            // playlist/segment EOFs trigger ffmpeg's exponential "reconnect at 0"
            // delay (1s, 3s, 7s), which is exactly the recurring live stall.
            mpv_set_property_string(mpv, "stream-lavf-o",
                                    "reconnect=1,reconnect_streamed=0,reconnect_delay_max=1")
        } else {
            mpv_set_property_string(mpv, "demuxer-readahead-secs", "300")
            mpv_set_property_string(mpv, "demuxer-max-back-bytes", "64MiB")
            mpv_set_property_string(mpv, "demuxer-lavf-o", "")
            mpv_set_property_string(mpv, "stream-lavf-o",
                                    "reconnect=1,reconnect_streamed=1,reconnect_delay_max=7")
        }
    }
    
    func togglePause() {
        getFlag(MPVProperty.pause) ? play() : pause()
    }

    private func updateCapturePipeline() {
        guard let device = metalLayer.device else { return }
        let size = metalLayer.drawableSize
        let fmt = metalLayer.pixelFormat
        guard size.width > 1, size.height > 1 else { return }
        guard size != capturePipelineSize || fmt != capturePipelineFormat else { return }

        guard let queue = device.makeCommandQueue() else { return }
        metalLayer.setupCaptureQueue(queue)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: fmt, width: Int(size.width), height: Int(size.height), mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        metalLayer.updateCaptureTexture(tex)
        capturePipelineSize = size
        capturePipelineFormat = fmt
    }

    /// Re-derive the dynamic range from the CURRENTLY decoded video params and apply it. Used by the
    /// gamma observer and MPV_EVENT_VIDEO_RECONFIG, neither of which carries a sig-peak value, so it
    /// reads sig-peak fresh. Unlike the sig-peak property-change observer this does NOT depend on a value
    /// delta, so it re-applies HDR on an in-place episode switch even when the new file's mastering peak
    /// equals the previous one's (mpv coalesces equal property values and fires no change event).
    private func reapplyDynamicRange() {
        guard mpv != nil else { return }
        syncDisplayDynamicRange(sigPeak: getDouble(MPVProperty.videoParamsSigPeak))
    }

    /// Whether the current display can actually present HDR. Drives the Auto tone-map mode. On tvOS the
    /// Apple TV switches the connected display into HDR for HDR content itself (HDRDisplayMode below), so
    /// Auto leaves HDR alone there and only the manual On mode forces SDR.
    private func displaySupportsHDR() -> Bool {
        #if os(iOS)
        return (view.window?.screen.potentialEDRHeadroom ?? 1.0) > 1.0
        #elseif os(macOS)
        return (view.window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0
        #else
        return true
        #endif
    }

    private func syncDisplayDynamicRange(sigPeak: Double) {
        guard let handle = mpv else { return }
        let gamma = getString(MPVProperty.videoParamsGamma) ?? ""
        var range: ContentDynamicRange
        if gamma == "hlg" {
            range = .hlg
        } else if gamma == "pq" || sigPeak > 1.0 {
            range = .hdr10
        } else {
            range = .sdr
        }
        // Dolby Vision / HDR handling. Auto (default) tone-maps HDR/DV to SDR only when the display can't
        // actually show HDR (so a non-HDR screen no longer renders HDR washed-out, and a capable screen
        // still gets real HDR). On always tone-maps (the manual DV Profile 7 green/purple fix); Off never
        // does. Migrates the old forceSDRTonemap bool: on -> "on", off -> "auto".
        if range != .sdr {
            let mode = UserDefaults.standard.string(forKey: "stremiox.hdrToneMapMode")
                ?? (UserDefaults.standard.bool(forKey: "stremiox.forceSDRTonemap") ? "on" : "auto")
            let forceSDR: Bool
            switch mode {
            case "on":  forceSDR = true
            case "off": forceSDR = false
            default:    forceSDR = !displaySupportsHDR()   // auto
            }
            if forceSDR {
                DiagnosticsLog.log("mpv", "HDR tone-map (mode=\(mode)) -> \(range.rawValue) to SDR")
                range = .sdr
            }
        }
        guard range != appliedDynamicRange else { return }
        appliedDynamicRange = range

        // Synchronous breadcrumbs: if any of these statements kills the process
        // (MoltenVK owns the layer's drawables and mid-stream colorspace changes
        // are crash-suspect territory), the last line in diagnostics.log names it.
        let trc = range == .hdr10 ? "pq" : (range == .hlg ? "hlg" : "auto")
        let prim = range == .sdr ? "auto" : "bt.2020"
        DiagnosticsLog.logSync("mpv", "applying target-trc=\(trc)")
        checkError(mpv_set_property_string(handle, "target-trc", trc))
        DiagnosticsLog.logSync("mpv", "applying target-prim=\(prim)")
        checkError(mpv_set_property_string(handle, "target-prim", prim))
        DiagnosticsLog.logSync("mpv", "tagging layer colorspace for \(range.rawValue)")
        switch range {
        case .hdr10: metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case .hlg:   metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        case .sdr:   metalLayer.colorspace = nil
        }
        DiagnosticsLog.logSync("mpv", "layer colorspace tagged")
        mpvLog.log("output range → \(range.rawValue, privacy: .public) (gamma=\(gamma, privacy: .public) sigPeak=\(sigPeak, privacy: .public))")
        DiagnosticsLog.log("mpv", "output range → \(range.rawValue) (gamma=\(gamma) sigPeak=\(sigPeak))")

#if os(tvOS)
        HDRDisplayMode.request(range,
                               fps: getDouble("container-fps"),
                               width: getInt("video-params/w"),
                               height: getInt("video-params/h"),
                               in: view.window)
#endif
    }
    
    func play() {
        setFlag(MPVProperty.pause, false)
    }
    
    func pause() {
        setFlag(MPVProperty.pause, true)
    }

    func seek(to seconds: Double) {
        command("seek", args: [String(seconds), "absolute"])
    }

    /// Relative seek (e.g. -10 / +10), used by the tvOS remote's left/right.
    func seek(by seconds: Double) {
        command("seek", args: [String(format: "%.1f", seconds), "relative"])
    }

    private func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0.0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }
    
    private func getString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        let cstr = mpv_get_property_string(mpv, name)
        let str: String? = cstr == nil ? nil : String(cString: cstr!)
        mpv_free(cstr)
        return str
    }
    
    private func getFlag(_ name: String) -> Bool {
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }
    
    private func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: Int = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    private func getInt(_ name: String) -> Int {
        guard mpv != nil else { return 0 }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        return Int(data)
    }

    private func setString(_ name: String, _ value: String) {
        guard mpv != nil else { return }
        mpv_set_property_string(mpv, name, value)
    }

    /// Read the current audio/subtitle/video tracks from mpv's `track-list`.
    func tracks(ofType type: String) -> [MPVTrack] {
        guard mpv != nil else { return [] }
        let count = getInt("track-list/count")
        guard count > 0 else { return [] }
        var result: [MPVTrack] = []
        for i in 0..<count where (getString("track-list/\(i)/type") ?? "") == type {
            result.append(MPVTrack(
                id: getInt("track-list/\(i)/id"),
                type: type,
                title: getString("track-list/\(i)/title") ?? "",
                lang: getString("track-list/\(i)/lang") ?? "",
                selected: getFlag("track-list/\(i)/selected")
            ))
        }
        return result
    }

    /// Named chapters from mpv's `chapter-list` (title + start time). Empty for files without chapters.
    /// Read via the same scalar getters as `tracks(ofType:)`, no `MPV_FORMAT_NODE` parsing needed.
    func chapters() -> [MPVChapter] {
        guard mpv != nil else { return [] }
        let count = getInt("chapter-list/count")
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            MPVChapter(title: getString("chapter-list/\(i)/title") ?? "",
                       start: getDouble("chapter-list/\(i)/time"))
        }
    }

    func setAudioTrack(_ id: Int) { setString(MPVProperty.aid, id < 0 ? "no" : String(id)) }
    func setSubtitleTrack(_ id: Int) { setString(MPVProperty.sid, id < 0 ? "no" : String(id)) }

    /// Session-lived map of add-on subtitle URL -> already-downloaded LOCAL file. Once a subtitle has been
    /// fetched, re-selecting that track or re-opening the same episode hands the on-disk file straight to mpv
    /// with NO network (see below), so it loads instantly instead of re-downloading from scratch every time.
    /// Guarded by `subtitleCacheLock`; keyed by the remote URL. Static so it survives player teardown within a
    /// session (re-opening an episode makes a fresh controller).
    private static var subtitleFileCache: [URL: URL] = [:]
    /// Insertion order for `subtitleFileCache`, so a long binge that samples many distinct subtitle URLs evicts
    /// the oldest entry past the cap instead of growing the map unbounded for the whole process lifetime.
    private static var subtitleCacheOrder: [URL] = []
    private static let subtitleCacheCap = 256
    private static let subtitleCacheLock = NSLock()

    /// Record `remote -> local` under the cap, evicting the oldest entry (FIFO) when full. Caller must NOT hold
    /// `subtitleCacheLock`; this takes it.
    private static func rememberSubtitleFile(_ remote: URL, _ local: URL) {
        subtitleCacheLock.lock(); defer { subtitleCacheLock.unlock() }
        if subtitleFileCache[remote] == nil {
            subtitleCacheOrder.append(remote)
            while subtitleCacheOrder.count > subtitleCacheCap {
                let oldest = subtitleCacheOrder.removeFirst()
                subtitleFileCache[oldest] = nil
            }
        }
        subtitleFileCache[remote] = local
    }

    /// Shared URLSession with a small on-disk/in-memory URLCache so cacheable provider responses are reused
    /// across picks even before our own file cache is populated. A few MB is plenty for text subtitles.
    private static let subtitleSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 8 * 1024 * 1024, diskPath: "stremiox-subs")
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// Per-pick network timeout and retry count for subtitle downloads. Hardcoded constants for now (a later
    /// pass may move these to RemoteConfig); 12s is snappy without giving up on a slow-but-alive provider, and
    /// ONE retry rescues a transient timeout / flaky first connection.
    private static let subtitleDownloadTimeout: TimeInterval = 12
    private static let subtitleDownloadRetries = 1

    /// Load an external subtitle from a (possibly slow) add-on URL WITHOUT blocking the caller, then
    /// select it. The old form ran `sub-add <remoteURL>` straight through `mpv_command`, which downloads
    /// the file INLINE on the calling thread; called from the subtitles panel on the main thread, a slow
    /// or hanging subtitle endpoint (an on-demand generator like Submaker, or a laggy provider) froze the
    /// whole app for the entire fetch. Instead we download the file ourselves on a background queue with a
    /// timeout, then `sub-add` the LOCAL file on the mpv queue (no network, instant). `completion` runs on
    /// the main thread with whether the subtitle loaded, so the UI can show progress and surface failures.
    ///
    /// Fast path: if we already downloaded this URL this session and the file is still on disk, we `sub-add`
    /// it immediately with NO network, so re-selecting a track / re-opening an episode is instant.
    func addExternalSubtitle(url: String, title: String, lang: String,
                             timeout: TimeInterval = MPVMetalViewController.subtitleDownloadTimeout,
                             completion: ((Bool) -> Void)? = nil) {
        guard let remote = URL(string: url) else { completion?(false); return }
        let finish: (Bool) -> Void = { ok in DispatchQueue.main.async { completion?(ok) } }

        // Fast path: reuse a previously downloaded file if it's still on disk (no network).
        if let cached = Self.cachedSubtitleFile(for: remote) {
            self.queue.async {
                self.command("sub-add", args: [cached.path, "select", title, lang])
                finish(true)
            }
            return
        }

        Self.downloadSubtitle(remote, timeout: timeout, retriesLeft: Self.subtitleDownloadRetries) { [weak self] localFile in
            guard let self, let localFile else { finish(false); return }
            self.queue.async {
                self.command("sub-add", args: [localFile.path, "select", title, lang])   // local file: no network, off-main
                finish(true)
            }
        }
    }

    /// Return the cached local file for `remote` only if it was recorded this session AND still exists on
    /// disk; otherwise drop the stale entry and return nil so the caller re-downloads. Thread-safe.
    private static func cachedSubtitleFile(for remote: URL) -> URL? {
        subtitleCacheLock.lock(); defer { subtitleCacheLock.unlock() }
        guard let file = subtitleFileCache[remote] else { return nil }
        if FileManager.default.fileExists(atPath: file.path) { return file }
        subtitleFileCache[remote] = nil   // file was purged (e.g. temp cleanup); force a re-download
        subtitleCacheOrder.removeAll { $0 == remote }
        return nil
    }

    /// Download `remote` on the shared cached session, write it to a DETERMINISTIC temp file (hashed from the
    /// URL, so it survives and is reused across the session), record it in the cache, and hand the local file
    /// to `done` on failure/success. Retries ONCE on a failed/empty/timed-out response before giving up.
    private static func downloadSubtitle(_ remote: URL, timeout: TimeInterval, retriesLeft: Int,
                                         done: @escaping (URL?) -> Void) {
        var request = URLRequest(url: remote)
        request.timeoutInterval = timeout
        request.cachePolicy = .returnCacheDataElseLoad
        subtitleSession.dataTask(with: request) { data, response, _ in
            let statusOK = (response as? HTTPURLResponse).map { (200 ..< 400).contains($0.statusCode) } ?? true
            guard statusOK, let data, !data.isEmpty else {
                if retriesLeft > 0 {
                    downloadSubtitle(remote, timeout: timeout, retriesLeft: retriesLeft - 1, done: done)
                } else { done(nil) }
                return
            }
            let ext = subtitleExtension(for: remote,
                                        contentType: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"))
            // Deterministic, content-addressed filename so the same subtitle reuses one on-disk file all session
            // AND two distinct URLs never collide onto the same file (a 64-bit `hashValue` gives no such
            // guarantee, which would let one track's file serve the other's cached entry).
            let digest = SHA256.hash(data: Data(remote.absoluteString.utf8))
            let name = "stremiox-sub-\(digest.map { String(format: "%02x", $0) }.joined()).\(ext)"
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            guard (try? data.write(to: tmp)) != nil else { done(nil); return }
            rememberSubtitleFile(remote, tmp)
            done(tmp)
        }.resume()
    }

    /// Best-effort subtitle file extension so mpv parses the downloaded bytes (it sniffs format too, but a
    /// correct extension is the reliable hint). Prefer the URL's own extension, then the content type, else srt.
    private static func subtitleExtension(for url: URL, contentType: String?) -> String {
        let known = ["srt", "vtt", "ass", "ssa", "sub", "smi"]
        let ext = url.pathExtension.lowercased()
        if known.contains(ext) { return ext }
        if let ct = contentType?.lowercased() {
            if ct.contains("vtt") { return "vtt" }
            if ct.contains("ass") || ct.contains("ssa") { return "ass" }
        }
        return "srt"
    }

    /// Manual subtitle sync, in seconds (positive = subtitles appear later). Maps to mpv `sub-delay`.
    func setSubDelay(_ seconds: Double) { setString("sub-delay", String(format: "%.2f", seconds)) }

    /// Video frame-rate for the community-subtitle release fingerprint. Prefers the container-declared fps,
    /// falling back to the estimated video-filter fps; 0 when unknown (the fingerprint tolerates a 0/absent
    /// value). Read off the player state exactly like the HDR path already reads `container-fps`.
    func containerFrameRate() -> Double {
        let container = getDouble("container-fps")
        if container > 0 { return container }
        return getDouble("estimated-vf-fps")
    }

    /// Media runtime in seconds for the community-subtitle release fingerprint (the same `duration` property
    /// the scrubber/trickplay read). 0 before the file is open.
    func mediaDurationSeconds() -> Double { getDouble("duration") }

    /// The current subtitle delay in seconds (mpv `sub-delay`), read back so the sync-capture path can pool
    /// the user's learned offset. 0 when unset / unavailable.
    func currentSubDelaySeconds() -> Double { getDouble("sub-delay") }

    /// Manual audio sync, in seconds. Maps to mpv `audio-delay`.
    func setAudioDelay(_ seconds: Double) { setString("audio-delay", String(format: "%.2f", seconds)) }

    /// Current media summary for the player's metadata line: encoded video height (e.g. 2160) and the
    /// active audio codec (e.g. "eac3"). Both can be 0/"" early in load, before the first frame.
    func mediaSummary() -> (width: Int, height: Int, audioCodec: String) {
        guard mpv != nil else { return (0, 0, "") }
        return (getInt("video-params/w"), getInt("video-params/h"), getString("audio-codec-name") ?? "")
    }

    /// Persisted video-size mode, read at startup so the first frame already uses it.
    private(set) var videoSizeMode = UserDefaults.standard.string(forKey: "stremiox.videoSize") ?? MPVMetalViewController.defaultVideoSizeMode

    /// Default sizing per device. iPhone fills the screen (crop) so a 16:9 stream doesn't leave thick side
    /// bars on a tall phone in landscape — the "thick bezels, fill it like this" report. iPad / Mac / Apple
    /// TV keep "original" (whole frame, letterboxed): their larger screens make bars fine, and cropping a
    /// 2.39:1 film on a TV would lose too much of the picture. The user can still change it in the player's
    /// Aspect control, which persists the override.
    private static var defaultVideoSizeMode: String {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone ? "fill" : "original"
        #else
        return "original"
        #endif
    }

    /// Video sizing. "original" (default) = the whole frame at its correct aspect, with bars where
    /// the film is wider/narrower than the screen, exactly like actual Stremio. "zoom" crops to fill
    /// the screen; "stretch" distorts to fill. The render now looks identical across clips because
    /// the drawable is pinned to the screen size every layout (the real "4 videos 4 sizes" fix).
    func setVideoSize(_ mode: String) {
        videoSizeMode = mode
        UserDefaults.standard.set(mode, forKey: "stremiox.videoSize")
        applyVideoSize { self.setString($0, $1) }
    }

    /// Apply `videoSizeMode` via `set`, `mpv_set_option_string` before init, `setString` (property)
    /// after, so the mode is realised identically at startup and on every video-output rebuild.
    /// When true, this instance ALWAYS crops-to-fill regardless of the user's global videoSize setting. Set
    /// only by the ambient hero trailer clip (#44) so it fills the whole hero band instead of letterboxing in
    /// a small centered box on iPad/Mac/tvOS. Never set on the main player, so real playback aspect is unchanged.
    var forceFillVideo = false

    private func applyVideoSize(_ set: (String, String) -> Void) {
        if forceFillVideo { set("keepaspect", "yes"); set("panscan", "1.0"); return }   // ambient hero: fill the band
        switch videoSizeMode {
        case "zoom", "fill": set("keepaspect", "yes"); set("panscan", "1.0")   // crop to fill
        case "stretch":      set("keepaspect", "no");  set("panscan", "0.0")   // distort to fill
        default:             set("keepaspect", "yes"); set("panscan", "0.0")   // original: whole frame, keep aspect
        }
    }

    func setSpeed(_ speed: Double) { setString(MPVProperty.speed, String(format: "%.2f", speed)) }

    /// Live playback position (mpv `time-pos`), for the wall-clock trickplay capture driver. 0 before the
    /// first frame or when nothing is open.
    var playbackPositionSeconds: Double { getDouble("time-pos") }

    /// Live audio volume on mpv's 0...100 scale (`volume` property; 100 = source level). Clamped 0...100.
    /// Independent of `mute`, so the chrome can restore the level after an unmute.
    func setVolume(_ volume0to100: Double) {
        let v = max(0, min(100, volume0to100))
        setString("volume", String(format: "%.0f", v))
    }

    /// Mute / unmute the live audio output (mpv `mute`) without disturbing the `volume` level.
    func setMuted(_ muted: Bool) { setFlag("mute", muted) }

    /// Whether VideoToolbox hardware decoding is currently requested (the player's Decoder option).
    private(set) var hardwareDecoding = true

    /// Switch between hardware (VideoToolbox) and software decoding at runtime. mpv re-probes the
    /// decoder on the property change, so this takes effect on the playing file without a reload.
    /// Software decode is a rescue path for clips whose hardware decode misbehaves (artifacts,
    /// green frames, unsupported profile); it costs CPU, so hardware stays the default.
    func setHardwareDecoding(_ on: Bool) {
        hardwareDecoding = on
        setString("hwdec", on ? "videotoolbox" : "no")
    }

    /// Switch the audio output policy (Auto / Stereo / Surround / Passthrough) on the playing file.
    /// Persists the choice, then re-applies the channel layout and the spdif bitstream list live so it
    /// takes effect without a reload — mpv re-opens the audio output when these properties change.
    /// `channelPolicy` reads `AudioOutputMode.current`, so persisting first makes it reflect `mode`.
    /// Setting `audio-spdif` to "" (when leaving Passthrough) tells mpv to decode to PCM again.
    func setAudioOutputMode(_ mode: AudioOutputMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: AudioOutputMode.key)
        setString("audio-channels", channelPolicy)
        // Never arm spdif on a stereo-only route (TV built-in / AirPlay): passthrough there freezes
        // the AO (#78). channelPolicy already forces a stereo downmix for those routes; keep spdif off
        // so a runtime switch to Passthrough on the built-in speakers degrades to decoded stereo PCM.
        #if os(tvOS)
        // tvOS: never arm raw spdif - it wedges the AO and freezes the player (#78/#101). Decode to PCM; the
        // avfoundation AO + the audio session let the system pass Atmos/multichannel through to the receiver.
        let spdif: String? = nil
        #elseif canImport(UIKit)
        let spdif = routeIsStereoOnly ? nil : mode.spdifCodecs
        #else
        let spdif = mode.spdifCodecs
        #endif
        setString("audio-spdif", spdif ?? "")
    }

    /// Live numbers for the player's "Playback info" overlay. Deliberately verbose: this panel is the field
    /// diagnostic for the audio (#78/#101) and HDR/DV (#76) reports, so it surfaces the player, the active
    /// audio output (AO) + what it actually opened, the route, and passthrough state - not just the source.
    func playbackStats() -> [(String, String)] {
        guard mpv != nil else { return [] }
        var rows: [(String, String)] = []
        rows.append(("Player", "libmpv"))   // this overlay is the libmpv path; the AVPlayer path (HLS/DV) has its own
        // --- Video ---
        let w = getInt("video-params/w"), h = getInt("video-params/h")
        if w > 0 { rows.append(("Video", "\(w)×\(h)  \(getString("video-codec-name") ?? "")")) }
        let gamma = getString("video-params/gamma") ?? ""
        let primaries = getString("video-params/primaries") ?? ""
        let range = gamma == "pq" ? "HDR (PQ)" : gamma == "hlg" ? "HLG" : "SDR"
        rows.append(("Range", primaries.isEmpty ? range : "\(range)  \(primaries)"))   // #76: primaries shows BT.2020 vs 709
        rows.append(("Decode", getString("hwdec-current") ?? "software"))
        let fps = getDouble("container-fps")
        if fps > 0 { rows.append(("FPS", String(format: "%.3f", fps))) }
        rows.append(("Dropped", "\(getInt("frame-drop-count"))"))
        // --- Audio (the soundbar / Atmos / passthrough diagnosis) ---
        if let audio = getString("audio-codec-name") {
            let ch = getInt("audio-params/channel-count"), sr = getInt("audio-params/samplerate")
            var s = audio
            if ch > 0 { s += "  \(ch)ch" }
            if sr > 0 { s += "  \(sr / 1000)kHz" }
            rows.append(("Audio in", s))
        }
        // The active AO is THE discriminator for #78/#101: "avfoundation" = the route opened via Apple's path
        // (the fix), "audiounit" = the old path that goes silent on continuous-audio HDMI / "null" = no sound.
        if let ao = getString("current-ao") { rows.append(("Audio out (AO)", ao)) }
        let oc = getInt("audio-out-params/channel-count"), osr = getInt("audio-out-params/samplerate")
        if oc > 0 { rows.append(("AO opened", osr > 0 ? "\(oc)ch  \(osr / 1000)kHz" : "\(oc)ch")) }
        #if canImport(UIKit)
        if let port = outputPortType?.rawValue { rows.append(("Route", port)) }
        #endif
        let spdif = getString("audio-spdif") ?? ""
        rows.append(("Passthrough", spdif.isEmpty ? "off (decoding to PCM)" : "on"))
        let cache = getDouble("demuxer-cache-duration")
        if cache > 0 { rows.append(("Buffer", String(format: "%.0fs ahead", cache))) }
        let speed = getDouble("speed")
        if speed > 0, abs(speed - 1) > 0.01 { rows.append(("Speed", "\(speed.formatted())×")) }
        return rows
    }

    /// Re-apply the current subtitle appearance to a running player (used after a settings change).
    func applySubtitleStyle() {
        for (name, value) in SubtitleStyle.mpvOptions { setString(name, value) }
    }

    func command(
        _ command: String,
        args: [String?] = [],
        checkForErrors: Bool = true,
        returnValueCallback: ((Int32) -> Void)? = nil
    ) {
        guard mpv != nil else {
            return
        }
        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for ptr in cargs where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr!))
            }
        }
        //print("\(command) -- \(args)")
        let returnValue = mpv_command(mpv, &cargs)
        if checkForErrors {
            checkError(returnValue)
        }
        if let cb = returnValueCallback {
            cb(returnValue)
        }
    }

    func captureFrameJPEGData(maxWidth: CGFloat, completion: @escaping (Data?) -> Void) {
        guard mpv != nil else { completion(nil); return }
        // Build or rebuild the pipeline lazily — at VIDEO_RECONFIG time the device/drawableSize may
        // not be set yet (especially on tvOS); calling here retries until everything is ready.
        // updateCapturePipeline is a no-op once the pipeline matches the current resolution/format.
        updateCapturePipeline()
        // requestCapture schedules a blit for the next nextDrawable() call on mpv's VO thread.
        // handler(nil) is called immediately by MetalLayer if the blit cannot be submitted, so
        // the caller's in-flight guard is always released even when the pipeline isn't ready yet.
        metalLayer.requestCapture { [weak self] texture in
            guard let self, let texture else { completion(nil); return }
            self.captureQueue.async {
                // CIImage(mtlTexture:) wraps the texture lazily. Metal textures have (0,0) at
                // top-left; CIImage has (0,0) at bottom-left — flip y while scaling to 480px wide.
                guard let raw = CIImage(mtlTexture: texture,
                                        options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]) else {
                    completion(nil); return
                }
                let tw = CGFloat(texture.width), th = CGFloat(texture.height)
                let s = min(maxWidth, tw) / tw   // never upscale: trickplay passes 480, frame-grab passes full
                let image = raw.transformed(by: CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: 0, ty: th * s))
                if self.ciContext == nil { self.ciContext = CIContext(mtlDevice: texture.device) }
                guard let ctx = self.ciContext,
                      let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
                      let jpeg = ctx.jpegRepresentation(
                          of: image, colorSpace: sRGB,
                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]
                      ) else {
                    completion(nil); return
                }
                completion(jpeg)
            }
        }
    }

    private func makeCArgs(_ command: String, _ args: [String?]) -> [String?] {
        if !args.isEmpty, args.last == nil {
            fatalError("Command do not need a nil suffix")
        }
        
        var strArgs = args
        strArgs.insert(command, at: 0)
        strArgs.append(nil)
        
        return strArgs
    }
    
    /// Deliver a property change on the main thread, dropping it if the player has been torn
    /// down (mpv == nil). Without the guard, a queued block force-unwraps the nil IUO mpv and
    /// traps, the crash on close.
    private func emit(_ name: String, _ data: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            self.playDelegate?.propertyChange(propertyName: name, data: data)
        }
    }

    /// mpv emits time-pos changes far faster than the UI needs (often per decoded
    /// frame), and each one hops to the main actor and re-renders the player's
    /// scrubber. Coalesce to ~4 Hz: smooth for a scrubber, and it stops the playhead
    /// from competing with remote input on the main thread (the player-sluggishness
    /// the audit flagged). Threshold logic in the delegate still fires fine at 4 Hz.
    private var lastTimePosEmit: TimeInterval = 0
    /// Coalesces the buffered-ahead (`demuxer-cache-time`) emits to ~2 Hz for the grey scrubber band.
    private var lastCacheTimeEmit: TimeInterval = 0

    func readEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            
            while true {
                // Re-check per iteration and hold a local: stop() nils `mpv` from the main
                // thread mid-drain, and the handle itself stays valid until stop()'s destroy
                // block, which is queued BEHIND this drain on the same serial queue.
                guard let handle = self.mpv else { break }
                let event = mpv_wait_event(handle, 0)
                if event?.pointee.event_id == MPV_EVENT_NONE {
                    break
                }
                
                switch event!.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    let dataOpaquePtr = OpaquePointer(event!.pointee.data)
                    if let property = UnsafePointer<mpv_event_property>(dataOpaquePtr)?.pointee {
                        let propertyName = String(cString: property.name)
                        switch propertyName {
                        case MPVProperty.videoParamsSigPeak:
                            if let sigPeak = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                                DispatchQueue.main.async { [weak self] in
                                    guard let self, self.mpv != nil else { return }   // dropped if torn down
                                    #if canImport(UIKit)
                                    let maxEDRRange = self.view.window?.screen.potentialEDRHeadroom ?? 1.0
                                    #elseif canImport(AppKit)
                                    let maxEDRRange = self.view.window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
                                    #endif
                                    // display screen support HDR and current playing HDR video
                                    self.hdrAvailable = maxEDRRange > 1.0 && sigPeak > 1.0
                                    self.syncDisplayDynamicRange(sigPeak: sigPeak)
                                    self.playDelegate?.propertyChange(propertyName: propertyName, data: sigPeak)
                                }
                            }
                        case MPVProperty.videoParamsGamma:
                            // Gamma settled (e.g. HLG, or a late pq on an in-place switch). Re-derive the
                            // range from the current params; reapplyDynamicRange reads sig-peak fresh.
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.mpv != nil else { return }
                                self.reapplyDynamicRange()
                            }
                        case MPVProperty.pausedForCache:
                            let buffering = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee ?? true
                            VXProbeState.shared.setPlayer(buffering: buffering)
                            VXProbe.event("player", "buffering \(buffering ? "start" : "end")")
                            self.emit(propertyName, buffering)
                        case MPVProperty.duration:
                            if let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                                VXProbeState.shared.setPlayer(dur: Int(value))
                                self.emit(propertyName, value)
                            }
                        case MPVProperty.seekable:
                            let seekable = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee ?? true
                            self.emit(propertyName, seekable)
                        case MPVProperty.demuxerCacheTime:
                            // Buffered-ahead edge (absolute seconds). mpv fires this often; coalesce to a
                            // couple of Hz so the grey scrubber band updates smoothly without churn.
                            if let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                                let now = ProcessInfo.processInfo.systemUptime
                                if now - self.lastCacheTimeEmit >= 0.5 {
                                    self.lastCacheTimeEmit = now
                                    self.emit(propertyName, value)
                                }
                            }
                        case MPVProperty.timePos:
                            if let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                                let now = ProcessInfo.processInfo.systemUptime
                                // Coalesce the play head (mpv fires this per decoded frame). 4 Hz on
                                // capable hardware for a smooth progress bar; 2 Hz on a constrained
                                // Apple TV (A8) so the play-head re-render stops competing with decode
                                // and the embedded server for its weak main thread, which is what froze
                                // the remote during torrent playback there. Capable devices are unaffected.
                                let minInterval = PerformanceMode.reduced ? 0.5 : 0.25
                                if now - self.lastTimePosEmit >= minInterval {
                                    self.lastTimePosEmit = now
                                    VXProbeState.shared.setPlayer(pos: Int(value))
                                    self.emit(propertyName, value)
                                }
                            }
                        case MPVProperty.pause:
                            let paused = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee ?? false
                            VXProbeState.shared.setPlayer(state: paused ? "paused" : "playing")
                            VXProbe.log("player", paused ? "paused" : "playing")
                            self.emit(propertyName, paused)
                        case MPVProperty.trackList:
                            self.emit(propertyName, nil)
                        default: break
                        }
                    }
                case MPV_EVENT_FILE_LOADED:
                    // The file opened and its tracks/params are known. Push a compact source label (the
                    // current path's host, redacted of any token-bearing query) into the probe state so the
                    // heartbeat names what is playing, and mark the engine as mpv + state playing.
                    let loadedHost = self.getString("path").flatMap { URL(string: $0)?.host }
                        ?? self.playUrl?.host ?? "?"
                    VXProbeState.shared.setPlayer(state: "playing", source: loadedHost, engine: "mpv")
                    VXProbe.event("player", "loaded \(loadedHost)")
                case MPV_EVENT_VIDEO_RECONFIG:
                    // The video output was (re)configured for the now-current file/params. This EVENT is
                    // not value-coalesced like the sig-peak property observer, so it fires reliably on
                    // every in-place episode switch even when two HDR episodes share a mastering peak —
                    // exactly the case that left ~2 of 3 switches dull. Re-derive + re-apply HDR from the
                    // freshly settled params (the nil sentinel set in loadFile guarantees it isn't swallowed).
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.mpv != nil else { return }
                        self.reapplyDynamicRange()
                        self.updateCapturePipeline()
                    }
                case MPV_EVENT_END_FILE:
                    // A file finished, if it ENDED IN ERROR (couldn't open: dead/uncached link,
                    // refused, unsupported, timed out), surface it so the UI can stop "buffering
                    // forever" and let the user pick another source.
                    if let data = event!.pointee.data {
                        let ef = UnsafePointer<mpv_event_end_file>(OpaquePointer(data)).pointee
                        if ef.reason == MPV_END_FILE_REASON_ERROR {
                            let msg = String(cString: mpv_error_string(ef.error))
                            self.mpvLog.error("end-file error: \(msg, privacy: .public)")
                            VXProbe.event("player", "endfile error \(msg)")
                            self.emit(MPVProperty.endFileError, msg)
                        } else if ef.reason == MPV_END_FILE_REASON_EOF {
                            VXProbe.event("player", "endfile eof")
                            self.emit(MPVProperty.endFileEof, nil)   // natural end → auto-play-next
                        }
                    }
                case MPV_EVENT_SHUTDOWN:
                    // "quit" landed (only stop() sends it). Destruction belongs to stop()'s
                    // queued block, which runs after this drain on the same serial queue;
                    // destroying here too was a double terminate. Just stop draining.
                    return
                case MPV_EVENT_LOG_MESSAGE:
                    if let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(event!.pointee.data)) {
                        let prefix = String(cString: msg.pointee.prefix)
                        let level = String(cString: msg.pointee.level)
                        let text = String(cString: msg.pointee.text).trimmingCharacters(in: .newlines)
                        // mpv's verbose log echoes resolved URLs and request headers (Authorization / Cookie),
                        // so keep the message body private; prefix + level stay public for log filtering.
                        if !text.isEmpty { self.mpvLog.log("[\(prefix, privacy: .public)/\(level, privacy: .public)] \(text, privacy: .private)") }
                    }
                default:
                    let eventName = mpv_event_name(event!.pointee.event_id )
                    print("event: \(String(cString: (eventName)!))");
                }
                
            }
        }
    }
    
    
    private func checkError(_ status: CInt) {
        if status < 0 {
            print("MPV API error: \(String(cString: mpv_error_string(status)))\n")
        }
    }
    
}
