import Foundation
import UIKit
import Libmpv
import AVFoundation
import os

// warning: metal API validation has been disabled to ignore crash when playing HDR videos.
// Edit Scheme -> Run -> Diagnostics -> Metal API Validation -> Turn it off
// https://github.com/KhronosGroup/MoltenVK/issues/2226
final class MPVMetalViewController: UIViewController {
    var metalLayer = MetalLayer()
    var mpv: OpaquePointer!
    var playDelegate: MPVPlayerDelegate?
    lazy var queue = DispatchQueue(label: "mpv", qos: .userInitiated)
    
    var playUrl: URL?
    var onSingleTap: (() -> Void)?
    var hdrAvailable : Bool = false
    private let mpvLog = Logger(subsystem: "com.stremiox.app", category: "mpv")
    /// The dynamic range currently applied to the output chain (mpv transfer curve,
    /// Metal layer colorspace, and on tvOS the display mode). Tracked so the sig-peak
    /// observer, which fires on every video reconfigure, only reapplies on change.
    /// NOTE: mpv's own target-colorspace-hint must stay OFF here. It is unsupported
    /// on the Metal/MoltenVK backend and known to crash it (double free); the app
    /// does the HDR signalling itself in syncDisplayDynamicRange.
    private var appliedDynamicRange: ContentDynamicRange = .sdr
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        metalLayer.frame = view.bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        
        view.layer.addSublayer(metalLayer)

        // iOS only: a tap toggles the touch controls. On tvOS this UIKit recognizer would swallow
        // the Siri-remote Select press before SwiftUI's player controls see it, so don't add it,         // the tvOS player drives everything through SwiftUI focus + command modifiers.
        #if os(iOS)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        view.addGestureRecognizer(tap)
        #endif

        setupMpv()
        
        if let url = playUrl {
            loadFile(url)
        }
    }
    
    private var lastLaidOutSize: CGSize = .zero

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
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
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            mpvLog.error("AVAudioSession .playback setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setupMpv() {
        configureAudioSession()
        mpv = mpv_create()
        if mpv == nil {
            print("failed creating context\n")
            exit(1)
        }

        // Apply the "fast" profile first so it sets the baseline (cheaper scaling, no debanding/dither,
        // static HDR peak); the explicit options below override anything we care about. This is the
        // documented remedy for 4K frame drops on constrained GPUs, which is what stutters on device.
        checkError(mpv_set_option_string(mpv, "profile", "fast"))

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
        // Bundle a broad CJK font and point libass at the folder so non-Latin subtitles (e.g. Korean)
        // render instead of empty boxes. CoreText fallback alone did not cover them in this build, so we
        // ship the font and set it as the default subtitle font directly.
        if let res = Bundle.main.resourcePath {
            checkError(mpv_set_option_string(mpv, "sub-fonts-dir", res + "/fonts"))
        }
        checkError(mpv_set_option_string(mpv, "sub-font", "Noto Sans CJK KR"))
        checkError(mpv_set_option_string(mpv, "embeddedfonts", "yes"))
        // User-configured subtitle appearance (size / colour / background), see SubtitleStyle.
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
        checkError(mpv_set_option_string(mpv, "demuxer-max-back-bytes", "64MiB"))
#if os(tvOS)
        checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", "512MiB"))
#else
        checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", "256MiB"))
#endif

//        checkError(mpv_set_option_string(mpv, "target-colorspace-hint", "yes")) // HDR passthrough
//        checkError(mpv_set_option_string(mpv, "tone-mapping-visualize", "yes"))  // only for debugging purposes
//        checkError(mpv_set_option_string(mpv, "profile", "fast"))   // can fix frame drop in poor device when play 4k

        
        checkError(mpv_initialize(mpv))
        
        mpv_observe_property(mpv, 0, MPVProperty.videoParamsSigPeak, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.pausedForCache, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.timePos, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.duration, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.pause, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.trackList, MPV_FORMAT_NONE)
        mpv_set_wakeup_callback(self.mpv, { (ctx) in
            let client = unsafeBitCast(ctx, to: MPVMetalViewController.self)
            client.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        setupNotification()
    }
    
    public func setupNotification() {
        NotificationCenter.default.addObserver(self, selector: #selector(enterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    @objc public func enterBackground() {
        // fix black screen issue when app enter foreground again
        pause()
        checkError(mpv_set_option_string(mpv, "vid", "no"))
    }
    
    @objc public func enterForeground() {
        checkError(mpv_set_option_string(mpv, "vid", "auto"))
        applyVideoSize { self.setString($0, $1) }   // re-apply size after the rebuild
        play()
    }

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
        appliedDynamicRange = .sdr
        guard let handle = mpv else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        // Tell the core to wind down NOW (mpv_command_string is thread-safe): decode and network
        // stop immediately. Without this, destruction waited its turn on the event queue, and a
        // stalled network read kept a ZOMBIE core decoding 4K invisibly for over a minute after
        // close (seen live), starving the UI hard enough to wedge the tab bar.
        mpv_command_string(handle, "quit")
        queue.async { [weak self] in
            self?.mpv = nil
            mpv_terminate_destroy(handle)
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
    }

    func loadFile(
        _ url: URL
    ) {
        var args = [url.absoluteString]
        var options = [String]()
        
        args.append("replace")

        if !options.isEmpty {
            args.append(options.joined(separator: ","))
        }

        mpvLog.log("loadFile → \(url.absoluteString, privacy: .public)")
        command("loadfile", args: args)
    }
    
    func togglePause() {
        getFlag(MPVProperty.pause) ? play() : pause()
    }

    /// Match the output chain to the playing file's dynamic range: mpv encodes
    /// PQ or HLG instead of tone-mapping to SDR, the Metal layer gets the matching
    /// colorspace tag, and on tvOS the TV is asked to switch into HDR mode (which
    /// is what lights the TV's HDR badge). Runs on the main thread from the
    /// sig-peak observer, once per video reconfigure.
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
        // Dolby Vision / HDR compatibility: when on, render HDR and DV as tone-mapped
        // SDR instead of switching the display into HDR. Fixes DV Profile 7 dual-layer
        // remuxes that come out green/purple on setups that mishandle the base layer.
        if UserDefaults.standard.bool(forKey: "stremiox.forceSDRTonemap"), range != .sdr {
            DiagnosticsLog.log("mpv", "HDR compatibility on -> tone-mapping \(range.rawValue) to SDR")
            range = .sdr
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

    /// Manual subtitle sync, in seconds (positive = subtitles appear later). Maps to mpv `sub-delay`.
    func setSubDelay(_ seconds: Double) { setString("sub-delay", String(format: "%.2f", seconds)) }

    /// Manual audio sync, in seconds. Maps to mpv `audio-delay`.
    func setAudioDelay(_ seconds: Double) { setString("audio-delay", String(format: "%.2f", seconds)) }

    /// Current media summary for the player's metadata line: encoded video height (e.g. 2160) and the
    /// active audio codec (e.g. "eac3"). Both can be 0/"" early in load, before the first frame.
    func mediaSummary() -> (height: Int, audioCodec: String) {
        guard mpv != nil else { return (0, "") }
        return (getInt("video-params/h"), getString("audio-codec-name") ?? "")
    }

    /// Persisted video-size mode, read at startup so the first frame already uses it.
    private(set) var videoSizeMode = UserDefaults.standard.string(forKey: "stremiox.videoSize") ?? "original"

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
    private func applyVideoSize(_ set: (String, String) -> Void) {
        switch videoSizeMode {
        case "zoom", "fill": set("keepaspect", "yes"); set("panscan", "1.0")   // crop to fill
        case "stretch":      set("keepaspect", "no");  set("panscan", "0.0")   // distort to fill
        default:             set("keepaspect", "yes"); set("panscan", "0.0")   // original: whole frame, keep aspect
        }
    }

    func setSpeed(_ speed: Double) { setString(MPVProperty.speed, String(format: "%.2f", speed)) }

    /// Live numbers for the player's "Playback info" overlay.
    func playbackStats() -> [(String, String)] {
        guard mpv != nil else { return [] }
        var rows: [(String, String)] = []
        let w = getInt("video-params/w"), h = getInt("video-params/h")
        if w > 0 { rows.append(("Video", "\(w)×\(h)  \(getString("video-codec-name") ?? "")")) }
        let gamma = getString("video-params/gamma") ?? ""
        rows.append(("Range", gamma == "pq" ? "HDR (PQ)" : gamma == "hlg" ? "HLG" : "SDR"))
        rows.append(("Decode", getString("hwdec-current") ?? "software"))
        let fps = getDouble("container-fps")
        if fps > 0 { rows.append(("FPS", String(format: "%.3f", fps))) }
        rows.append(("Dropped", "\(getInt("frame-drop-count"))"))
        if let audio = getString("audio-codec-name") {
            let channels = getInt("audio-params/channel-count")
            rows.append(("Audio", channels > 0 ? "\(audio)  \(channels)ch" : audio))
        }
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
            guard let self, let mpv = self.mpv else { return }
            self.playDelegate?.propertyChange(mpv: mpv, propertyName: name, data: data)
        }
    }

    /// mpv emits time-pos changes far faster than the UI needs (often per decoded
    /// frame), and each one hops to the main actor and re-renders the player's
    /// scrubber. Coalesce to ~4 Hz: smooth for a scrubber, and it stops the playhead
    /// from competing with remote input on the main thread (the player-sluggishness
    /// the audit flagged). Threshold logic in the delegate still fires fine at 4 Hz.
    private var lastTimePosEmit: TimeInterval = 0

    func readEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            
            while self.mpv != nil {
                let event = mpv_wait_event(self.mpv, 0)
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
                                    guard let self, let mpv = self.mpv else { return }   // dropped if torn down
                                    let maxEDRRange = self.view.window?.screen.potentialEDRHeadroom ?? 1.0
                                    // display screen support HDR and current playing HDR video
                                    self.hdrAvailable = maxEDRRange > 1.0 && sigPeak > 1.0
                                    self.syncDisplayDynamicRange(sigPeak: sigPeak)
                                    self.playDelegate?.propertyChange(mpv: mpv, propertyName: propertyName, data: sigPeak)
                                }
                            }
                        case MPVProperty.pausedForCache:
                            let buffering = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee ?? true
                            self.emit(propertyName, buffering)
                        case MPVProperty.duration:
                            if let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                                self.emit(propertyName, value)
                            }
                        case MPVProperty.timePos:
                            if let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                                let now = ProcessInfo.processInfo.systemUptime
                                // Emit the play head at 2 Hz, not per frame. Each emit re-renders the
                                // player view, which competes with decode and remote-input handling for
                                // the main thread. On weak hardware (Apple TV HD, A8, no HEVC hardware
                                // decode) that contention is what makes the remote feel frozen during
                                // playback. 0.5 s is imperceptible on a clock and halves the churn.
                                if now - self.lastTimePosEmit >= 0.5 {
                                    self.lastTimePosEmit = now
                                    self.emit(propertyName, value)
                                }
                            }
                        case MPVProperty.pause:
                            let paused = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee ?? false
                            self.emit(propertyName, paused)
                        case MPVProperty.trackList:
                            self.emit(propertyName, nil)
                        default: break
                        }
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
                            self.emit(MPVProperty.endFileError, msg)
                        } else if ef.reason == MPV_END_FILE_REASON_EOF {
                            self.emit(MPVProperty.endFileEof, nil)   // natural end → auto-play-next
                        }
                    }
                case MPV_EVENT_SHUTDOWN:
                    print("event: shutdown\n");
                    mpv_terminate_destroy(mpv);
                    mpv = nil;
                    break;
                case MPV_EVENT_LOG_MESSAGE:
                    if let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(event!.pointee.data)) {
                        let prefix = String(cString: msg.pointee.prefix)
                        let level = String(cString: msg.pointee.level)
                        let text = String(cString: msg.pointee.text).trimmingCharacters(in: .newlines)
                        if !text.isEmpty { self.mpvLog.log("[\(prefix, privacy: .public)/\(level, privacy: .public)] \(text, privacy: .public)") }
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
