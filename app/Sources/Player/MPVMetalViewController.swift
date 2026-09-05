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

/// Narrows mpv's floating-point duration to the integer probe format without allowing malformed,
/// non-finite, or out-of-range media metadata to trap the event queue.
enum MPVDurationProbePolicy {
    static func integerSeconds(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }
}

/// Keeps the decoder REQUEST separate from mpv's negotiated decoder. `hwdec-current=no` can be a
/// silent fallback even while the user still requests VideoToolbox, so it must never be treated as
/// proof that the user selected Software.
enum MPVHardwareDecodePolicy {
    static let videoToolbox = "videotoolbox"

    static func requestedDecoder(arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: "-stremiox-hwdec"),
              index + 1 < arguments.count else { return videoToolbox }
        return arguments[index + 1]
    }

    static func isSoftwareFallback(requested: String, active: String?) -> Bool {
        requested != "no" && active == "no"
    }
}

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

/// Mutable Core Image and receipt state confined to one explicit serial capture queue.
/// The precondition turns an accidental future cross-queue access into a development failure.
private final class CaptureQueueState: @unchecked Sendable {
    private let queue: DispatchQueue
    private var ciContext: CIContext?
    private var ciContextDevice: ObjectIdentifier?
    private var receiptKey: String?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func prepare(for texture: MTLTexture) -> (context: CIContext, shouldEmitReceipt: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        let deviceID = ObjectIdentifier(texture.device)
        let context: CIContext
        if let existing = ciContext, ciContextDevice == deviceID {
            context = existing
        } else {
            let replacement = CIContext(mtlDevice: texture.device)
            ciContext = replacement
            ciContextDevice = deviceID
            receiptKey = nil
            context = replacement
        }

        let nextReceiptKey = "\(texture.width)x\(texture.height)-\(texture.pixelFormat.rawValue)"
        let shouldEmitReceipt = receiptKey != nextReceiptKey
        receiptKey = nextReceiptKey
        return (context, shouldEmitReceipt)
    }
}

#if os(tvOS)
/// Thread-safe admission gate between mpv's serial event queue and the main-actor memory policy.
private final class TVOSMemorySampleThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSample: TimeInterval = 0

    func shouldSchedule(now: TimeInterval, interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastSample >= interval else { return false }
        lastSample = now
        return true
    }
}
#endif

final class MPVMetalViewController: PlatformViewController {
    var metalLayer = MetalLayer()
    var mpv: OpaquePointer!
    /// The +1 relay currently registered with mpv; balanced with release() after terminate.
    private var wakeupRelay: Unmanaged<WakeupRelay>?
    var playDelegate: MPVPlayerDelegate?
    lazy var queue = DispatchQueue(label: "mpv", qos: .userInitiated)
    /// mpv loads asynchronously after `loadfile` returns. Bind logical request tokens through mpv's unique
    /// playlist-entry IDs instead of assuming START_FILE order. The same lock covers command registration
    /// and event binding, so a wakeup cannot observe START_FILE before its exact entry ID is registered.
    private let loadTokenLock = NSLock()
    private var loadProvenance = PlayerLoadProvenanceState()
    /// One destructive cache flight per controller; all mutations occur on the main queue.
    private var cacheFlushFlight = CacheFlushSingleFlight<PlayerLoadToken>()
    /// The source inputs needed for the one bounded same-source retry after a proven false EOF. Kept per
    /// accepted load (rather than reading mpv's redirected path) so signed URLs, headers, and sidecars keep
    /// the exact normal `loadFile` ownership and sanitisation path on reopen.
    private struct SeekEOFReloadSource {
        let url: URL
        let headers: [String: String]?
        let live: Bool
        let audioSidecar: URL?
    }
    private var seekEOFRecovery = SeekEOFRecoveryPolicy<PlayerLoadToken>()
    private var seekEOFReloadSource: SeekEOFReloadSource?
    private var seekEOFRecoveryTimeout: DispatchWorkItem?
    private static let seekEOFRecoveryTimeoutSeconds: TimeInterval = 12
    var activeLoadToken: PlayerLoadToken? {
        loadTokenLock.lock(); defer { loadTokenLock.unlock() }
        return loadProvenance.activeToken
    }
    private lazy var captureQueue = DispatchQueue(label: "com.stremiox.trickplay.capture", qos: .utility)
    private lazy var captureQueueState = CaptureQueueState(queue: captureQueue)
    /// One-time breadcrumb for the Apple TV HD capture gate (#188). Main-thread confined:
    /// captureFrameJPEGData is only invoked from the main-actor player views.
    private var loggedUnsupportedGPUCaptureGate = false
    // Tracks the Metal device for which the capture queue/scaler were built. Drawable size and format
    // are handled lazily inside MetalLayer because the bounded target follows each capture request.
    private var capturePipelineDevice: ObjectIdentifier?
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
    /// The VXProbe channel this instance narrates under. The real playback surface keeps `"player"`, which
    /// every existing diagnostic and export tool greps for; the ambient hero trailer sets `"trailer"` so its
    /// buffering / playing / endfile lines cannot be misread as the main player's. A muted decorative clip
    /// impersonating `[player]` produced phantom overlapping playbacks in an exported device log and cost a
    /// diagnosis. `StaticString` because a VXProbe category is a compile-time literal, never runtime text.
    var probeChannel: StaticString = "player"
    /// True only for the real playback surface. `VXProbeState.shared` holds ONE player line that the heartbeat
    /// prints, so an ambient trailer writing into it overwrites the real player's position, duration, buffering
    /// and state with a muted decorative clip's - which is exactly the phantom-playback confusion `probeChannel`
    /// was added to end, left half-fixed because the narration moved channel but the shared STATE writes did
    /// not. Compared through `description` because `StaticString` is not `Equatable`; every call site below is
    /// an event (load, pause, buffering, duration) or already coalesced to a few Hz, so the cost is noise.
    private var ownsSharedProbeState: Bool { probeChannel.description == "player" }
    private let mpvLog = Logger(subsystem: "com.stremiox.app", category: "mpv")
    /// What the app/user asked mpv to use. This intentionally differs from `hwdec-current`, which is the
    /// negotiated truth and can silently become `no` when VideoToolbox cannot decode the stream.
    private var requestedHardwareDecoder = MPVHardwareDecodePolicy.videoToolbox
    /// One negotiation receipt per file or explicit decoder change. Reset before either operation so a
    /// later fallback is visible without repeating the same line in every 30-second performance receipt.
    private var loggedHardwareDecoderNegotiation = false
    private var configuredLiveMode = false
    /// The forward-cache cap (`demuxer-max-bytes`, option-string form) loadFile applied for the CURRENT
    /// file, so the paused-cache clamp can restore it on resume. nil until the first load.
    private var activeReadAheadCap: String?
    /// The SAME cap as loadFile applied it, kept untouched by every clamp so a recovery has a ceiling to
    /// walk back toward (`activeReadAheadCap` is overwritten by each shed and therefore cannot serve as
    /// one). This is the only safe ceiling: DIAG-12 proved a recomputed or larger tvOS cap is not
    /// device-safe, and this value already passed the platform limit and the RemoteConfig clamp, so a
    /// restore may reach it and never exceed it. nil until the first load.
    private var baselineReadAheadCap: String?
    /// The back-buffer cap (`demuxer-max-back-bytes`) every file starts with on this platform: the
    /// setupMpv pre-load default. shedForMemoryPressure drops the live option to 8MiB for the rest of the
    /// CURRENT file, and nothing else re-applied it for LATER files on the same instance (loadFile's clamp
    /// reset only restored the forward cap, and configureLiveMode(false) skips its write when consecutive
    /// loads are both non-live), so every post-shed load inherited the shrunken seek-back buffer. loadFile
    /// re-applies this default per non-live file in its clamp-reset block; live keeps configureLiveMode's
    /// own tight value.
    #if os(macOS)
    private let defaultBackBufferCap = "64MiB"
    #else
    private let defaultBackBufferCap = "24MiB"
    #endif
    /// Pending "still paused after the grace period" cache clamp; cancelled on resume / new load / stop.
    private var pausedCacheClampWork: DispatchWorkItem?
    /// True while the paused clamp holds `demuxer-max-bytes` at the small floor (restored on resume).
    private var pausedCacheClamped = false
    /// True once a GENUINE-low-headroom memory warning stepped this file's cache down. The ROOT FIX means an
    /// advisory warning with ample real headroom no longer sets it (nor lowers the cap). A bookkeeping marker
    /// now that the shed steps the cap down one 64 MiB rung at a time toward the raised floor rather than
    /// distinguishing a first warning from a later one. Reset on the next loadFile (a new file starts with its
    /// buffers freed and its normal budget), and on tvOS cleared by a sustained-headroom restore that reaches
    /// the load budget, at which point this file's state matches a fresh load's.
    private var memoryCacheClamped = false
    #if os(tvOS)
    /// Nonisolated because the locked helper is the boundary between mpv's event queue and main actor.
    private nonisolated let proactiveMemorySampleThrottle = TVOSMemorySampleThrottle()
    /// Main-thread transition state: true while a proactive clamp holds this file below its load budget.
    /// It makes the clamp one-shot, so pressure cannot ratchet the cache down sample after sample; a
    /// sustained-headroom restore clears it again, which is what re-arms the clamp for the raised cap.
    private var proactiveMemoryCacheClamped = false
    private var lastProactiveMemoryReceipt: TimeInterval = 0
    /// Consecutive proactive samples that saw restore-grade headroom (twice the clamp threshold). Any
    /// sample below it resets the run, and applying a restore resets it too, so every rung of the way
    /// back up costs a fresh sustained window instead of letting the cap chatter around one boundary.
    private var proactiveRecoveredSampleCount = 0
    /// Restores this file has been granted. Capped at `TVOSProactiveMemoryPressurePolicy
    /// .maxRestoreCyclesPerFile`, after which the clamp is one-way for the rest of the file exactly as it was
    /// before recovery existed: a restore re-arms the clamp, so under external pressure oscillating around the
    /// threshold an uncapped ladder would keep paying the forced re-anchor seek. Reset
    /// in loadFile with the rest of the per-file cache state.
    private var restoreCyclesThisFile = 0
    #endif
    /// True only after the pinned engine's payload-offload capability is confirmed and setupMpv successfully
    /// arms cache-on-disk. The current pinned MPVKit capability gate is false, so ordinary RAM baselines remain
    /// authoritative even when the user has requested a streaming disk cache.
    private var diskCacheOnDiskArmed = false
    /// Forward read-ahead ramp state (disk-cache-armed remote VOD). See armDiskCacheReadaheadRamp.
    private var cacheReadaheadRampWork: DispatchWorkItem?
    private var cacheReadaheadRampGeneration: UInt64 = 0
    private var cacheReadaheadRampAppliedSecs = 0
    private var cacheReadaheadRampLastFrameDrop = 0
    /// The rung the ramp started at (loadFile), so a drop-burst back-off never sinks the forward depth below the
    /// opening cache-secs. Stored per file alongside the applied depth.
    private var cacheReadaheadRampStartSecs = 0
    /// Set on a USER-initiated seek (the remote's directional hop, a scrub commit, the iOS control bar), read-and-
    /// cleared by each read-ahead ramp sample. A high-bitrate 4K HDR remux legitimately re-decodes from a keyframe
    /// on a user seek and drops well past the burst threshold; without this the ramp reads that one-off seek burst
    /// as fill starvation and BACKS OFF the forward buffer exactly when a seek most needs it refilled (the Beta 17
    /// directional-press stutter, #202). Gates ONLY the back-off branch: a clean post-seek window may still climb,
    /// and a real starvation burst with no user seek in the window still backs off unchanged. Written from the seek
    /// entry points and read/cleared in the ramp step, both marshalled on `queue` (the serial mpv queue), so the
    /// two never race. Internal reseeks/watchdog/track-change refresh-seeks deliberately leave it unset, so genuine
    /// internal stalls are still caught.
    private var userSeekedSinceRampSample = false
    private static let diskCacheReadaheadRampStepSecs = 60      // cache-secs added per stable rung
    private static let diskCacheReadaheadRampIntervalSecs: TimeInterval = 15   // wall time between rungs
    private static let diskCacheRampReadaheadFloorSecs = 30     // demuxer-readahead-secs during the ramp (< start)
    private static let diskCacheReadaheadRampDropTolerance = 2  // output drops since last rung that still count as steady
    /// A REAL output-drop burst since the last rung (well past the jitter tolerance): the disk-offload fill is
    /// starving the Metal present thread NOW, so the ramp backs OFF one rung instead of merely holding, then
    /// resumes climbing once a clean rung passes. Tuned above the tolerance so ordinary jitter still only holds.
    private static let diskCacheReadaheadRampBurstDropThreshold = 6
    /// Bitrate-aware depth guard. A very-high-bitrate stream (UHD remux, ~80 Mbit/s+) tops out below the 900s
    /// ceiling so the forward payload the disk cache commits never over-fills; the byte budget is generous
    /// enough that ordinary 4K (well under it) keeps the FULL configured depth. Never trims below the floor.
    private static let diskCacheReadaheadRampMaxReadaheadBytes: Int64 = 8 << 30   // 8 GiB forward-payload budget
    private static let diskCacheReadaheadRampBitrateFloorSecs = 300               // never trim the ceiling below 5 min
    /// The dynamic range currently applied to the output chain (mpv transfer curve, Metal layer
    /// colorspace, and on tvOS the display mode), or nil = "unknown, force a fresh apply". Reset to nil on
    /// every file load and teardown so the FIRST re-evaluation of a new file always applies (the guard
    /// `range != appliedDynamicRange` can never be swallowed by a stale value): an in-place HDR episode
    /// switch reliably re-enters HDR, and an HDR-to-SDR switch correctly drops it.
    /// NOTE: mpv's own target-colorspace-hint must stay OFF. It is unsupported on the Metal/MoltenVK
    /// backend and known to crash it (double free); the app does the HDR signalling itself in
    /// syncDisplayDynamicRange.
    private var appliedDynamicRange: ContentDynamicRange? = nil

    /// Set by the launch site (via the `PlayerEngine` protocol) from the stream's Dolby Vision flag. When true,
    /// `syncDisplayDynamicRange` drives the Apple TV into Dolby Vision display mode for DV content this lane
    /// renders as a tone-mapped PQ base layer, so the TV lights its DV badge exactly as the reference player
    /// does on a decoded MKV. tvOS-only effect (the display-mode request is tvOS); harmless elsewhere.
    var contentIsDolbyVision = false

    /// Profile-aware evidence for `contentIsDolbyVision`, set by the same launch site when it has proof
    /// beyond the text-parsed Boolean - see DVPlaybackPolicy.DolbyVisionFallbackInfo. Defaults to `.unknown`
    /// so the pre-probe colour policy in `syncDisplayDynamicRange` never treats "labelled Dolby Vision" as
    /// proof of PQ/BT.2020 on its own; it waits for either this descriptor to prove a compatible base layer
    /// or for mpv to report real decoded parameters. `MPVMetalPlayerView.makeController` copies this from
    /// its Coordinator on every fresh mount; `demoteAVPlayerToMPV` (PlayerScreen/TVPlayerView) is the only
    /// caller that ever sets the Coordinator's copy to real evidence (the outgoing AVPlayer's own remux
    /// parse, `AVPlayerEngineController.dolbyVisionFallbackInfo`), read BEFORE the remux session tears
    /// down. Every ordinary load (`loadIntoPlayer`) resets this instance's copy back to `.unknown` first, so
    /// the evidence can never outlive the one demote it was captured for.
    var dolbyVisionFallbackInfo = DVPlaybackPolicy.DolbyVisionFallbackInfo.unknown

    /// Set only by the full playback chrome. Embedded hero/trailer controllers keep the
    /// default false and therefore cannot arm the tvOS chroma mitigation or diagnostics.
    var isFullPlayerPresentation = false {
        didSet {
            #if os(tvOS)
            if isFullPlayerPresentation {
                startFramePresentationDiagnosticsIfReady()
                updateFramePresentationPolicy()
            } else {
                stopFramePresentationDiagnostics()
                restoreFramePresentationCscale()
            }
            #endif
        }
    }

    #if os(tvOS)
    private let framePresentationDiagnostics = FramePresentationDiagnosticsAccumulator()
    /// B-instrument: last logged chroma arm-decision signature, so the one-shot decision receipt in
    /// updateFramePresentationPolicy logs only when the decision or its inputs actually change (a policy pass
    /// runs on many events and must not spam). Instrumentation only.
    private var lastFramePresentationDecisionSignature: String?
    /// Last frame-drop RATE observed by the receipt path, so the Playback info overlay can report "N total,
    /// R/min". Only the receipt may take a snapshot (taking one resets the interval), so the overlay reads
    /// what the receipt last measured instead of sampling its own. nil until the first receipt of a mount.
    private var lastReceiptFrameDropsPerMinute: Double?
    private var framePresentationGeneration: UInt64 = 0
    private var framePresentationLoadedGeneration: UInt64?
    private var framePresentationStartedGeneration: UInt64?
    private var framePresentationPriorCscale: String?
    private var framePresentationMitigationApplied = false
    private var framePresentationRestorePending = false
    private var framePresentationVOPassesWork: DispatchWorkItem?
    private static let framePresentationVOPassesCooldown: TimeInterval = 2
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        
        metalLayer.frame = view.bounds
        metalLayer.framebufferOnly = false  // must be false for MoltenVK internal blits (e.g. format resolve)
        // Insurance against render-thread/main-thread deadlocks: the drawable present must never wait
        // on the main run loop's CATransaction commit (presentsWithTransaction = false, the default,
        // made explicit), and nextDrawable() must be able to time out instead of blocking the vo thread
        // forever if drawables can't be recycled while the main thread is busy.
        metalLayer.presentsWithTransaction = false
        metalLayer.allowsNextDrawableTimeout = true
        #if os(tvOS)
        metalLayer.presentationDiagnostics = framePresentationDiagnostics
        #endif
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

        #if canImport(UIKit)
        // Jetsam relief: the system memory warning is the last call before tvOS/iOS kills the app. mpv's
        // demuxer cache is by far the largest shedable allocation in this process, so respond by clamping
        // it (see shedForMemoryPressure). Selector-based observer: stop() removes it, and NotificationCenter
        // auto-unregisters deallocated selector observers as the safety net.
        NotificationCenter.default.addObserver(self, selector: #selector(handleMemoryWarningNote),
                                               name: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil)
        #endif

        if let url = playUrl {
            loadFile(url, headers: playHeaders, live: playUrlLive, audioSidecar: playAudioSidecarURL)
        }
    }
    
    private var lastLaidOutSize: CGSize = .zero

    /// True once layoutDrawable has kicked off the initial video-output build against a real,
    /// validly sized surface. mpv configures its VO (render context + moltenvk swapchain) for the
    /// size the metal layer has at mpv_initialize time. The full-window player and the iOS/tvOS
    /// hero already have a sized surface then, so their first frame presents normally. The macOS
    /// EMBEDDED hero clip is the exception: viewDidLoad (hence setupMpv / mpv_initialize) runs
    /// before the view is in a window, so the VO configured against a zero/unsized surface and
    /// never built a context that could present a frame, so the timePos -> showClip reveal never
    /// fired and the hero stayed static. On the first valid layout we force one VO rebuild so the
    /// context is (re)created at the real size and the first frame is produced. Gated by this flag
    /// so it fires exactly once per surface config and can never turn an ordinary resize into a
    /// VO thrash.
    private var didBuildInitialVideoOutput = false

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

    /// macOS: `viewDidLoad` runs BEFORE the view is attached to a window, so `view.window` is nil there and
    /// the Metal layer's `contentsScale` was seeded from `NSScreen.main` (a guess) with no drawable pinned to
    /// a real backing yet. For the full-window main player that is fine (it mounts straight into the window),
    /// but an EMBEDDED instance (the ambient Home/Detail hero trailer clip, which is the ONLY non-full-window
    /// libmpv surface on Mac) mounted inside a scrolling SwiftUI container could be left with a stale
    /// contentsScale / an unsized drawable and never present a frame - the "hero trailer autoplay is broken on
    /// macOS" report (works on iPhone/tvOS). `viewDidAppear` fires once the view is in the window hierarchy, so
    /// re-sync the backing scale to the ACTUAL window and re-pin the drawable there so the embedded clip
    /// renders. Idempotent (a no-op when scale + size are already current). iOS/tvOS use the UIKit path and
    /// are untouched.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        let scale = window.backingScaleFactor
        if metalLayer.contentsScale != scale {
            metalLayer.contentsScale = scale
            // Force layoutDrawable to re-pin the drawable against the corrected backing scale.
            lastLaidOutSize = .zero
            // The VO that may already have built against the GUESSED backing scale (NSScreen.main in
            // viewDidLoad) is now stale, because the drawable is being re-pinned at the real window
            // scale. Allow one fresh initial build at the corrected size. This only runs when the
            // scale actually differs (an embed on a non-main display), so it never rebuilds on an
            // ordinary re-appear where the scale already matches.
            didBuildInitialVideoOutput = false
        }
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

        // First valid layout: build the video output now that the surface has a real size (see
        // didBuildInitialVideoOutput). This is the zero/invalid -> valid transition, which is
        // DISTINCT from a live resize: didResize requires a PRIOR non-zero size, so it is false on
        // the very first layout, and without this the VO built at mpv_initialize against an unsized
        // surface (macOS embedded hero) would never be rebuilt and no first frame would present.
        // The flag makes this fire exactly once, so it can never thrash the VO on every resize;
        // ordinary resizes fall through to the didResize path below unchanged.
        if !didBuildInitialVideoOutput {
            didBuildInitialVideoOutput = true
            reconfigureVideoOutput()
        } else if didResize {
            // A live resize (rotation, macOS window drag) no longer needs the VO rebuilt. Our mpv
            // build carries scripts/mpv-moltenvk-resize.patch, which makes the moltenvk render
            // context answer VOCTRL_CHECK_EVENTS by re-reading the layer's drawableSize, resizing
            // its own swapchain and raising VO_EVENT_RESIZE. mpv therefore refills the surface by
            // itself, and the old `vid=no` then `vid=auto` teardown (which threw away the decoder
            // and the whole video chain on every single rotation) is gone.
            applyVideoSize { self.setString($0, $1) }
            wakeVideoOutputThread()
        }
    }

    /// Kick mpv's video-output thread so it polls the layer size NOW rather than whenever it next
    /// happens to run. That thread's loop checks events once per iteration and then parks for a very
    /// long time whenever it has nothing to render (video/out/vo.c), so a rotation performed while
    /// PAUSED would otherwise not be picked up until playback resumed, leaving the last frame
    /// stretched to the new bounds. Measured, not assumed: test/moltenvk-resize probes a paused
    /// rotation with no follow-up, with the size properties re-applied, and with this call.
    ///
    /// Re-applying the size properties is NOT sufficient on its own. mpv only notifies option
    /// listeners when a value actually changes (options/m_config_core.c), and `keepaspect` and
    /// `panscan` do not change across a rotation, so those writes are inert.
    ///
    /// `display-names` is read purely for the dispatch: its getter is one of the few property reads
    /// that goes through vo_control(), which hands work to the video-output thread and therefore
    /// wakes it. The value is discarded, and this lane answers VO_NOTIMPL anyway. Async so nothing
    /// on the calling thread can ever block on the video-output thread finishing a frame; this runs
    /// from a layout callback on the main thread, and that thread must never wait on the renderer
    /// (see the MetalLayer EDR note for what that costs when it goes wrong).
    private func wakeVideoOutputThread() {
        guard mpv != nil else { return }
        mpv_get_property_async(mpv, 0, "display-names", MPV_FORMAT_STRING)
    }

    /// One-shot VO rebuild for the zero-size-at-init case only (see didBuildInitialVideoOutput). Live
    /// resizes no longer come through here: mpv's own render context now notices a layer resize, so
    /// layoutDrawable just re-applies the size mode. This remains because a VO that was configured
    /// against a surface with NO size never built a presentable context at all, which no amount of
    /// resizing after the fact can repair.
    private func reconfigureVideoOutput() {
        guard mpv != nil else { return }
        // `vid` must be set as a PROPERTY. mpv_set_option_string is a silent no-op after
        // mpv_initialize, so the option-string form never actually rebuilt the VO.
        checkError(mpv_set_property_string(mpv, "vid", "no"))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            self.checkError(mpv_set_property_string(self.mpv, "vid", "auto"))
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
        return AudioRoutePolicy.channelPolicy(
            mode: AudioOutputMode.current,
            actualOutputChannels: outputChannels,
            routeIsStereoOnly: routeIsStereoOnly,
            routeIsAirPods: routeIsAirPods
        )
        #else
        return AudioRoutePolicy.channelPolicy(
            mode: AudioOutputMode.current,
            actualOutputChannels: outputChannels,
            routeIsStereoOnly: false,
            routeIsAirPods: false
        )
        #endif
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
            // #78: re-assert the route's OWN realized rate as the preferred rate so the AudioUnit opens at a
            // rate the locked Atmos/eARC route actually accepts. This backstops the pre-activation 48 kHz hint
            // above: if the route opened at its native rate (already 48k on eARC, or a different fixed rate),
            // this pins to that realized rate; on every other route the session already reports its native rate
            // so this is a no-op. Keep it (do NOT remove): it is part of the #78 eARC-silence fix.
            if session.sampleRate >= 8000 { try? session.setPreferredSampleRate(session.sampleRate) }
            refreshAudioSessionPolicy()
        } catch {
            mpvLog.error("AVAudioSession .playback setup failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    #if canImport(UIKit)
    /// Refresh the active route's AVAudioSession policy. Maximum channels bound what we request;
    /// `outputNumberOfChannels` after that request is the only count used to select mpv's layout.
    private func refreshAudioSessionPolicy() {
        let session = AVAudioSession.sharedInstance()
        let mode = AudioOutputMode.current
        let sessionMode: AVAudioSession.Mode = mode == .stereo ? .default : .moviePlayback
        do {
            try session.setCategory(.playback, mode: sessionMode, options: [])
        } catch {
            mpvLog.error("AVAudioSession policy refresh failed: \(error.localizedDescription, privacy: .public)")
        }

        outputPortType = session.currentRoute.outputs.first?.portType
        let maximumOutputChannels = session.maximumOutputNumberOfChannels
        let supportsMultichannelContent = AudioRoutePolicy.supportsMultichannelContent(
            mode: mode,
            maximumOutputChannels: maximumOutputChannels,
            routeIsStereoOnly: routeIsStereoOnly,
            routeIsAirPods: routeIsAirPods
        )
        if #available(iOS 15.0, tvOS 15.0, *) {
            try? session.setSupportsMultichannelContent(supportsMultichannelContent)
        }

        let requestedOutputChannels = AudioRoutePolicy.preferredOutputChannels(
            mode: mode,
            maximumOutputChannels: maximumOutputChannels,
            routeIsStereoOnly: routeIsStereoOnly,
            routeIsAirPods: routeIsAirPods
        )
        try? session.setPreferredOutputNumberOfChannels(requestedOutputChannels)

        let actualOutputChannels = AudioRoutePolicy.resolvedOutputChannels(session.outputNumberOfChannels)
        outputChannels = actualOutputChannels
        outputSampleRate = session.sampleRate
        DiagnosticsLog.log(
            "player",
            "audio route policy mode=\(mode.rawValue) port=\(outputPortType?.rawValue ?? "none") max=\(maximumOutputChannels) actual=\(actualOutputChannels) requested=\(requestedOutputChannels) resolved=\(channelPolicy)"
        )
    }
    #endif

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
            mpvLog.error("failed creating mpv context")
            exit(1)
        }

        // Hero-preview options (#44), set before mpv_initialize so they take at init time. `mute=yes`
        // gives a soundless ambient clip (no audio output is ever opened); `loop-file=inf` makes mpv
        // re-play the trailer forever with no app-side EOF handling. The main player sets neither.
        if startMuted { checkError(mpv_set_option_string(mpv, "mute", "yes")) }
        if loopPlayback { checkError(mpv_set_option_string(mpv, "loop-file", "inf")) }

        // Do NOT apply mpv's "fast" profile by default. It overrides gpu-next/libplacebo's sharp default
        // upscaler (lanczos) with bilinear and disables debanding/dither, which made upscaled video look
        // soft/blurry, the "player size/quality is pathetic vs the 0.1.6 IPA" report. v0.1.6 left this
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
        let hwdec = MPVHardwareDecodePolicy.requestedDecoder(
            arguments: ProcessInfo.processInfo.arguments)
        requestedHardwareDecoder = hwdec
        hardwareDecoding = hwdec != "no"
        checkError(mpv_set_option_string(mpv, "hwdec", hwdec))
        mpvLog.log("hwdec requested = \(hwdec, privacy: .public)")
        checkError(mpv_set_option_string(mpv, "video-rotate", "no"))
        // Quality tone curve for any HDR -> SDR mapping (used when the Dolby Vision /
        // HDR compatibility toggle forces SDR output for displays that show DV P7
        // remuxes as green/purple garbage). Harmless for native SDR content.
        checkError(mpv_set_option_string(mpv, "tone-mapping", "bt.2446a"))
        // Dolby Vision Profile 7 enhancement layer (FEL). For a dual-track P7 MKV (a separate base and
        // enhancement video track, i.e. ~every UHD-BluRay DV rip), libmpv now pairs the two tracks and
        // libplacebo composites the EL's residual detail onto the base layer, instead of us decoding the
        // base alone and throwing the enhancement layer away. It also means such a title finally carries
        // real DV metadata rather than none. This engages AUTOMATICALLY once the pairing succeeds, so the
        // only control we need is the OFF switch: `enhancement-layer=no` makes the format filter discard
        // the paired EL frame, which is exactly the pre-FEL behaviour. Baked ON, fleet-flippable, so a
        // field problem is a same-day remote revert instead of an emergency build. `vf` is set nowhere
        // else in the app, so owning the whole chain here is safe.
        if !RemoteConfig.snapshot.isFeatureOn("dvEnhancementLayer", default: true) {
            checkError(mpv_set_option_string(mpv, "vf", "format=enhancement-layer=no"))
            mpvLog.log("dv enhancement layer DISABLED by remote config")
        }
        // Keep the enhancement-layer track VISIBLE in `track-list`. Upstream hides dependent tracks by
        // default, which would make the FEL diagnostic below a permanent false negative: it could never
        // tell "paired and compositing" from "never found, base layer only", and that silent no-op is
        // the exact failure this feature is prone to. `tracks(ofType:)` re-hides them, so the user-facing
        // audio/subtitle pickers are byte-for-byte unchanged, and mpv's own track-preference comparator
        // ranks non-dependent tracks first, so the base layer still wins auto-selection.
        checkError(mpv_set_option_string(mpv, "show-dependent-tracks", "yes"))
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
        // FFmpeg 9 makes willclose follow multiple_requests. Persistent requests keep bounded 206 spans
        // from reopening TCP/TLS.
        checkError(mpv_set_option_string(mpv, "stream-lavf-o",
            "reconnect=1,reconnect_streamed=1,reconnect_delay_max=7,multiple_requests=1"))

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
        checkError(mpv_set_option_string(mpv, "demuxer-max-back-bytes", defaultBackBufferCap))
        checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", "256MiB"))
#else
        // iOS/tvOS: the server is in-process and jetsam-bound and its RSS includes these mpv buffers, so
        // keep the back-buffer (already-played, for seek-back) small. The per-file demuxer-max-bytes below
        // overrides the forward cache; this init is just the pre-load default.
        checkError(mpv_set_option_string(mpv, "demuxer-max-back-bytes", defaultBackBufferCap))
        checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", "128MiB"))
#endif

        // The Settings value is a REQUEST, not proof that this pinned MPVKit offloads forward payloads. Device
        // evidence shows its forward buffer remains in process RAM, so the single capability gate in
        // VortXCacheShedPolicy stays false: do not set disk options, do not claim the cache is armed, and do not
        // replace the normal RAM baseline with the smaller metadata-only cap. Keeping the dormant setup behind
        // that gate makes a future, device-proven enablement one explicit capability change instead of another
        // preference-driven guess. The requested value is logged without a filesystem path for truthful field
        // diagnosis.
        let diskCacheRequestedBytes = DiskCacheSetting.storedBytes
        let diskCacheRequestedMode = diskCacheRequestedBytes == 0
            ? "off"
            : (diskCacheRequestedBytes == DiskCacheSetting.unlimitedSentinel ? "unlimited" : "finite")
        let diskCacheRequested = DiskCacheSetting.diskCacheEnabled
        diskCacheOnDiskArmed = false
        if !startMuted {
            mpvLog.log("streaming cache requestedMode=\(diskCacheRequestedMode, privacy: .public) enabledAfterFleetGate=\(diskCacheRequested, privacy: .public) payloadOffloadConfirmed=\(VortXCacheShedPolicy.diskCachePayloadOffloadConfirmed, privacy: .public)")
        }
        if VortXCacheShedPolicy.shouldArmDiskCache(
            payloadOffloadRequested: diskCacheRequested,
            muted: startMuted
        ), let cacheDir = DiskCacheSetting.ensureCacheDirectory() {
            checkError(mpv_set_option_string(mpv, "cache-on-disk", "yes"))
            diskCacheOnDiskArmed = true
            checkError(mpv_set_option_string(mpv, "demuxer-cache-dir", cacheDir))
            checkError(mpv_set_option_string(mpv, "demuxer-cache-unlink-files", "immediate"))
            checkError(mpv_set_option_string(mpv, "cache-secs", String(RemoteConfig.snapshot.diskCacheReadaheadSecs)))
            let writable = FileManager.default.isWritableFile(atPath: cacheDir)
            mpvLog.log("streaming cache armed requested=true payloadOffloadConfirmed=true writable=\(writable, privacy: .public) cacheSecs=\(RemoteConfig.snapshot.diskCacheReadaheadSecs, privacy: .public)")
        }

#if os(tvOS)
        // Post-seek/track-change smoothing for the tvOS avfoundation AO. Every scrub commit empties the
        // forward cache and every audio/subtitle track change triggers a demuxer refresh-seek that
        // discards + re-reads it; playback then resumed instantly on a near-empty cache while the refill
        // burst saturated the network + demuxer + decoder, so the audio output underran repeatedly,
        // heard as several seconds of crackly/distorted audio with video lagging until the cache caught
        // up. The avfoundation AO is also known upstream to drop 30+ frames each time it resumes from an
        // underrun (mpv-player/mpv#16346), which compounds the visible lag. Only the deeper `audio-buffer`
        // is set globally here: it just grows a buffer, giving the AO slack to ride out the refill burst's
        // CPU spikes without underrunning. The cache hold itself (`cache-pause-initial` +
        // `cache-pause-wait`) is deliberately NOT set at setup: applied globally it held EVERY playback
        // start in the buffering state and doubled every ordinary mid-play rebuffer's wait. Instead
        // armSeekCacheHold() toggles the hold on immediately before the seeks that actually empty the
        // cache (scrub commits and the track-change refresh-seeks), and the pausedForCache=false edge in
        // the event drain releases it once playback has resumed. tvOS-only: iOS/macOS ride the
        // audiounit/coreaudio AOs and don't show this. The muted hero-preview instance keeps mpv defaults
        // so its ambient clip still starts instantly.
        if !startMuted {
            checkError(mpv_set_option_string(mpv, "audio-buffer", "0.5"))
        }
#endif

        // HLS: pick the HIGHEST-bandwidth variant of an adaptive master playlist. mpv's documented
        // default is already `max`, but add-ons that serve a single adaptive master (e.g. KhmerHub's
        // OK.ru streams) were starting at the lowest rendition (the "144p instead of 720p" report),
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
        // Audio route policy is iOS/tvOS only: mpv there uses the low-level audiounit AO that does
        // not resample or downmix to the route on its own, so we drive it (the soundbar fixes). On
        // macOS mpv uses the coreaudio AO, which negotiates rate, channels, and routing natively
        // like desktop mpv. Only a saved Stereo compatibility override needs app-side setup there.
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
        // never arm spdif on tvOS by default. iOS keeps it, gated off stereo-only / AirPods routes that can't
        // take it.
        #if !os(tvOS)
        if !routeIsStereoOnly, !routeIsAirPods, let spdif = AudioOutputMode.current.spdifCodecs {
            checkError(mpv_set_option_string(mpv, "audio-spdif", spdif))
        }
        #else
        // tvOS bitstream EXPERIMENT (Atmos survival on the libmpv fallback lane; see
        // AudioOutputMode.tvosSpdifExperimentEnabled for the full gate rationale). Whenever a DV title lands
        // on this lane (a demoted remux, a torrent), decoding E-AC-3 to PCM strips the JOC (Atmos) metadata:
        // the receiver shows "Dolby Audio"/PCM, never Atmos. DOUBLE-gated so the fleet default is EXACTLY
        // today's decode path: the user's explicit Passthrough pick AND the tvosSpdif defaults/RemoteConfig
        // flag, on a route that can take a bitstream (never built-in speakers / AirPlay / Bluetooth), and
        // never for the muted hero-preview instance. When armed, the AO list is pinned to avfoundation ALONE:
        // the #78/#101 freeze was audiounit + spdif, and that pair must never re-arise via AO fallback. If
        // the avfoundation AO refuses the compressed format, mpv falls back to decoding the same track to
        // PCM (the documented spdif fallback; also asserted by AudioOutputMode.detail), i.e. the worst case
        // is exactly today's behavior.
        if !startMuted, !routeIsStereoOnly, !routeIsAirPods,
           AudioOutputMode.current == .passthrough, AudioOutputMode.tvosSpdifExperimentEnabled,
           let spdif = AudioOutputMode.current.spdifCodecs {
            checkError(mpv_set_option_string(mpv, "ao", "avfoundation"))   // never audiounit with spdif armed
            checkError(mpv_set_option_string(mpv, "audio-spdif", spdif))
            DiagnosticsLog.log("player", "tvOS bitstream experiment ARMED: audio-spdif=\(spdif), ao pinned to avfoundation (Passthrough + tvosSpdif flag, multichannel route)")
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
        #elseif os(macOS)
        // Desktop mpv's CoreAudio output owns route, sample-rate, and multichannel negotiation. The
        // one safe persisted override is Stereo, which must be installed before `mpv_initialize` so
        // a saved compatibility choice survives relaunch. All other modes retain CoreAudio/mpv's
        // normal automatic route and do not make an app-side SPDIF request at startup.
        if AudioOutputMode.current == .stereo {
            checkError(mpv_set_option_string(mpv, "audio-channels", "stereo"))
        }
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
        #if os(tvOS)
        // Sparse counter/cue events feed one lock-backed aggregate. `sub-start` is numeric,
        // so repeated property notifications can be deduplicated without reading subtitle text.
        mpv_observe_property(mpv, 0, MPVProperty.frameDropCount, MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, MPVProperty.decoderFrameDropCount, MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, MPVProperty.subtitleStart, MPV_FORMAT_DOUBLE)
        #endif
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
    /// Whether playback was actually playing when we backgrounded, so `enterForeground` resumes only a title
    /// that was playing and never un-pauses one the user paused (or one that never started).
    private var wasPlayingBeforeBackground = false

    @objc public func enterBackground() {
        // Remember the play state BEFORE we pause below, so foregrounding does not silently resume a
        // user-paused title.
        wasPlayingBeforeBackground = mpv != nil && !getFlag(MPVProperty.pause)
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
        // `vid` is toggled at RUNTIME here, so it must go through the PROPERTY setter: mpv_set_option_string
        // is a silent no-op after mpv_initialize (see applyChannelPolicy), so the option-string form left the
        // background "drop video decode" doing nothing.
        checkError(mpv_set_property_string(mpv, "vid", "no"))
        // Clamp the read-ahead NOW rather than after the 60s grace. The grace exists for a FOREGROUND pause,
        // where the viewer may resume at any second and a refill would be visible; a backgrounded pause has no
        // picture to buffer for, and the timer could not fire there anyway: `pausedStateChanged` arms it on the
        // main queue, main-queue timers do not run while the process is suspended, and the overdue work item
        // then bails on its own `pause` guard once foregrounding has already resumed playback. So the clamp
        // written for exactly this case never applied to it.
        // Guarded by applyPausedCacheClamp's own `pause` read, which is what makes the iOS background-AUDIO
        // case fail open: with keepPlayingInBackground on and audio still playing we are NOT paused, the
        // demuxer is still feeding the AO, and clamping would starve it. Only a title actually paused at
        // background time (every tvOS background, and iOS either without the keep-alive or paused by the
        // viewer) is clamped.
        pausedCacheClampWork?.cancel(); pausedCacheClampWork = nil
        applyPausedCacheClamp(reason: "backgrounded while paused")
    }

    @objc public func enterForeground() {
        // A silent hero preview never claimed the audio session (setupMpv skips configureAudioSession when
        // startMuted), so it must not reactivate the session or reapply the channel policy here either.
        if !startMuted {
            // Reclaim the session in case another app deactivated it while we were backgrounded,
            // then re-evaluate the audio route (it may have changed off-screen).
            do { try AVAudioSession.sharedInstance().setActive(true) } catch {
                mpvLog.error("AVAudioSession reactivate on foreground failed: \(error.localizedDescription, privacy: .public)")
            }
            applyChannelPolicy()
        }
        checkError(mpv_set_property_string(mpv, "vid", "auto"))   // runtime toggle: property, not option (no-op post-init)
        applyVideoSize { self.setString($0, $1) }   // re-apply size after the rebuild
        if wasPlayingBeforeBackground { play() }   // only resume a title that was actually playing
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
    private func applyChannelPolicy(force: Bool = false) {
        guard mpv != nil else { return }
        refreshAudioSessionPolicy()
        let next = (channelPolicy, sampleRatePolicy ?? 0)
        if !force, let applied = appliedAudioPolicy, applied == next { return }   // no real change: don't churn the AO
        appliedAudioPolicy = next
        setString("audio-channels", next.0)
        setString("audio-samplerate", String(next.1))
        mpvLog.log("audio reapplied: channels=\(next.0, privacy: .public) samplerate=\(next.1 > 0 ? String(next.1) : "content", privacy: .public) (route \(self.outputChannels) ch @ \(Int(self.outputSampleRate)) Hz)")
    }

    @objc private func audioRouteChanged(_ note: Notification) {
        // Hop to the main actor: the notification can arrive on an arbitrary thread and we touch
        // the mpv handle. (mpv option-set is thread-safe, but keep the AVAudioSession read + log
        // ordering deterministic.)
        DispatchQueue.main.async { [weak self] in self?.applyChannelPolicy() }
    }
    #endif   // canImport(UIKit): audio-session + lifecycle observers are iOS/tvOS only

    func invalidateLoadToken() {
        finishCacheFlushFlight(cacheFlushFlight.reset())
        seekEOFRecoveryTimeout?.cancel(); seekEOFRecoveryTimeout = nil
        seekEOFRecovery.cancel()
        loadTokenLock.lock(); defer { loadTokenLock.unlock() }
        loadProvenance.invalidate()
    }

    private func callbackLoadToken(requiresLoadedFile: Bool = false) -> PlayerLoadToken? {
        loadTokenLock.lock(); defer { loadTokenLock.unlock() }
        return loadProvenance.callbackToken(requiresLoadedFile: requiresLoadedFile)
    }

    private func bindStartFile(entryID: Int64) {
        loadTokenLock.lock(); defer { loadTokenLock.unlock() }
        loadProvenance.bindStart(entryID: entryID)
    }

    private func markActiveFileLoaded() {
        loadTokenLock.lock(); defer { loadTokenLock.unlock() }
        loadProvenance.markFileLoaded()
    }

    private func loadToken(forEntryID entryID: Int64) -> PlayerLoadToken? {
        loadTokenLock.lock(); defer { loadTokenLock.unlock() }
        return loadProvenance.token(forEntryID: entryID)
    }

    private func propagateRedirect(_ event: mpv_event_end_file) {
        loadTokenLock.lock(); defer { loadTokenLock.unlock() }
        loadProvenance.propagateRedirect(
            from: event.playlist_entry_id,
            firstInsertedID: event.playlist_insert_id,
            count: Int(event.playlist_insert_num_entries)
        )
    }

    /// Tear mpv down safely when the player closes. Clearing the wakeup callback first
    /// prevents it from firing into a deallocated controller (the crash on close), and
    /// destruction is serialized onto the event queue so it can't race `readEvents`.
    func stop() {
        #if os(tvOS)
        stopFramePresentationDiagnostics()
        restoreFramePresentationCscale()
        #endif
        invalidateLoadToken()
        NotificationCenter.default.removeObserver(self)
        pausedCacheClampWork?.cancel(); pausedCacheClampWork = nil
        cacheReadaheadRampWork?.cancel(); cacheReadaheadRampWork = nil
        cacheReadaheadRampGeneration &+= 1
#if os(tvOS)
        cancelSeekRefillWatchdog()   // no pending reseek may fire after teardown
        // Hand the TV back its default display mode; the view can already be
        // detached here, so HDRDisplayMode falls back to the app's window.
        // Ambient hero previews (#44, startMuted) never requested a mode, and their teardown runs on
        // every hero change while scrolling (and right as full-screen playback starts), so a preview
        // reset here cleared the MAIN player's criteria and wiped the request ledger: one more HDMI
        // renegotiation per scroll step. Only non-preview instances reset the panel.
        if !startMuted {
            HDRDisplayMode.reset(in: viewIfLoaded?.window)
        }
#endif
        appliedDynamicRange = nil
        guard let handle = mpv else { return }
        // Nil the handle SYNCHRONOUSLY so exactly one owner destroys it: deinit's safety net
        // sees nil (no double terminate when dealloc beats the queued block), the event drain
        // stops picking it up, and every property accessor becomes a guarded no-op.
        mpv = nil
        let surface = isFullPlayerPresentation || probeChannel.description == "player" ? "player" : "ambient"
        DiagnosticsLog.log("mpv", "stop-requested surface=\(surface)")
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
            DiagnosticsLog.log("mpv", "destroy-finished surface=\(surface)")
            relay?.release()   // no callbacks after terminate_destroy; safe to drop the relay
        }
    }

    deinit {
        // Safety net: if the view controller is torn down without stop() (e.g. an
        // unexpected dealloc), make sure mpv can't call back into freed memory. Mirror stop()'s
        // SERIALIZED teardown rather than destroying inline: an inline mpv_terminate_destroy here
        // could race an in-flight readEvents drain on `queue` (double-destroy / use-after-free), so
        // nil the handle synchronously (one owner) and dispatch the destroy onto the event queue.
        // The gate is main-queue-owned. stop()/invalidateLoadToken() cancels its timeout before normal teardown;
        // if deinit is the safety-net path, the timeout's weak self capture makes the queued work a no-op.
        if let handle = mpv {
            mpv = nil
            mpv_set_wakeup_callback(handle, nil, nil)
            let relay = wakeupRelay
            wakeupRelay = nil
            queue.async {
                mpv_terminate_destroy(handle)
                relay?.release()   // no callbacks after terminate_destroy; safe to drop the relay
            }
        } else {
            wakeupRelay?.release()
        }
    }

    private func finishCacheFlushFlight(
        _ flight: CacheFlushFlight<PlayerLoadToken>?,
        sampleLiveState: Bool = true
    ) {
        guard let flight else { return }
        #if canImport(UIKit)
        let bufferedAheadReceipt: String
        let pausedForCacheReceipt: String
        if sampleLiveState {
            bufferedAheadReceipt = cacheFlushSampleReceipt("demuxer-cache-duration")
            pausedForCacheReceipt = diagnosticFlag("paused-for-cache")
                .map { $0 ? "true" : "false" } ?? "unknown"
        } else {
            bufferedAheadReceipt = "unknown"
            pausedForCacheReceipt = "unknown"
        }
        DiagnosticsLog.log(
            "player",
            "internal-cache-flush-end operation=atomic-reanchor flightId=\(flight.id) reason=\(flight.reason.rawValue) target=\(flight.targetArgument) bufferedAhead=\(bufferedAheadReceipt) pausedForCache=\(pausedForCacheReceipt) loadToken=\(flight.owner.hashValue) coalesced=\(flight.coalescedCount) elapsed=\(cacheFlushElapsedReceipt(startUptime: flight.startUptime)) outcome=\(flight.result.rawValue)"
        )
        #else
        _ = flight
        _ = sampleLiveState
        #endif
    }

    /// mpv's stock User-Agent, captured once so a stream with custom headers can never leak
    /// its UA into the next stream.
    private lazy var defaultUserAgent = getString("user-agent") ?? ""

    @discardableResult
    func loadFile(
        _ url: URL,
        headers: [String: String]? = nil,
        live: Bool = false,
        audioSidecar: URL? = nil,
        reusing loadToken: PlayerLoadToken? = nil,
        preservingSeekEOFRecovery: Bool = false
    ) -> PlayerLoadToken {
        // libmpv has no exact AVPlayerItem-style ownership fence. Every load therefore mints a fresh token,
        // including internal reloads, so a queued callback can never become valid again through token reuse.
        let issuedToken = PlayerLoadToken()
        // Keep the prior request's provenance until `loadfile replace` succeeds. The synchronous command can
        // reject before changing mpv's playlist; eagerly invalidating here would erase the still-playing
        // request and make a caller-restored pending episode impossible to commit. START_FILE is blocked by
        // `loadTokenLock` during the command below, then success atomically retires the old request and
        // registers the new entry.
        // Teardown nils the handle; a loadFile racing close must not hand a NULL mpv to the raw
        // mpv_set_property_string calls below (the setString/command helpers self-guard, these do not).
        guard mpv != nil else { return issuedToken }
        loggedHardwareDecoderNegotiation = false
        // Re-arm HDR detection for THIS file. appliedDynamicRange otherwise persists from the previous
        // file, so an in-place episode / source switch left it stale and the guard SKIPPED re-applying the
        // colorspace; the new (HDR) episode then kept rendering in the previous SDR output (dull) until a
        // full replay rebuilt the player. Resetting to the nil SENTINEL (not .sdr) means the next
        // re-evaluation ALWAYS applies the new file's true range (nil != any real range), so an HDR->HDR,
        // HDR->SDR, or SDR->HDR switch all re-tag correctly. The re-evaluation no longer depends on the
        // value-coalesced sig-peak property event firing (two same-mastering-peak HDR episodes fire none):
        // MPV_EVENT_VIDEO_RECONFIG drives reapplyDynamicRange() on every new file. This was the "~2 of 3
        // auto-advanced / skipped episodes are washed out" report. (HDR is only verifiable on a real HDR
        // display, not the Simulator.)
        appliedDynamicRange = nil
        // A fresh `loadfile ... replace` re-runs mpv's track auto-selection, which clears any secondary
        // subtitle back to none. Mirror that here so an in-place episode / source switch doesn't leave the
        // dual-subtitle picker showing a stale second-language checkmark from the previous file.
        secondarySubtitleID = -1
        // The URL / audio sidecar mpv actually opens. `url` and `audioSidecar` are `let` params; a googlevideo
        // trailer swaps these to their local VXTrailerProxy (127.0.0.1) equivalents below, BEFORE they are handed
        // to mpv via `args` and the `audio-files` append. Everything downstream (args, isLocalStream, the audio
        // sidecar append, the redacted log) reads these, so the swap flows through the rest of loadFile untouched.
        var playURL = url
        var sidecar = audioSidecar
        var args = [playURL.absoluteString]

        args.append("replace")

        // Per-stream HTTP headers (behaviorHints.proxyHeaders): some add-ons front CDNs that
        // require a specific Referer or a browser User-Agent; without them the server rejects
        // the stream ("loading failed" on sources that play fine in clients that apply them).
        // ALWAYS set all three so the previous file's headers never bleed into this one.
        var fields: [String] = []
        var userAgent = ""
        var referrer = ""
        for (name, value) in StreamRequestHeaderPolicy.sanitized(headers) {
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
            // UA lockstep (trailerClientResolverV2): googlevideo binds each issued URL to the InnerTube client
            // that MINTED it, so ask the resolver for the UA recorded against this exact URL. mpv's
            // `user-agent` option applies to every stream this load opens (video + the --audio-files sidecar),
            // and both legs always come from the same minting client, so one lookup covers both. With the flag
            // off the registry is empty and the lookup returns the IOS constant, byte-identical to before.
            let requiredUA = YouTubeDirectResolver.requiredUserAgent(for: (isGoogleVideo(url) ? url : audioSidecar) ?? url)
            if isGoogleVideo(url) {
                if YouTubeDirectResolver.isManifestURL(url) {
                    // V2 HLS-master fallback: mpv opens the manifest DIRECTLY. The range-proxy cannot serve it
                    // (it needs the `clen`/`&range=` mechanics of a bare media URL, which a manifest lacks),
                    // and manifests + their segment fetches are plain GETs, so there is no Range shape to fix;
                    // only the UA force below matters. This branch never fires with the flag off (the resolver
                    // then never returns a manifest URL).
                    playURL = url
                } else {
                    playURL = VXTrailerProxy.shared.proxied(url, mime: "video/mp4") ?? url
                }
            }
            if let audioSidecar, isGoogleVideo(audioSidecar) {
                sidecar = VXTrailerProxy.shared.proxied(audioSidecar, mime: "audio/mp4") ?? audioSidecar
            }
            args[0] = playURL.absoluteString
            setString("user-agent", requiredUA)
            // Referer/extra headers from a browser context would only confuse googlevideo's UA binding.
            setString("referrer", "")
            setString("http-header-fields", "")
            // Trailer audio-language belt-and-suspenders: the resolver already selects the preferred-language
            // audio LEG (the load-bearing fix for multi-language trailers). This additionally tells mpv which
            // language to auto-select IF a single opened file itself exposes more than one embedded audio track
            // (a muxed multi-audio format, or a future HLS path). Set only on this googlevideo (trailer) branch,
            // so the main player's default track selection is never touched. Trailer instances only ever play
            // trailers, so it does not bleed into anything else.
            let trailerAlang = TrackPreferences.trailerAudioLanguages
            if !trailerAlang.isEmpty {
                setString("alang", trailerAlang.joined(separator: ","))
            }
            NSLog("[trailer] loadFile googlevideo: proxying via 127.0.0.1 playHost=%@ sidecar=%@ alang=%@ ua=%@",
                  playURL.host ?? "?", sidecar == nil ? "none" : (sidecar!.host ?? "?"),
                  trailerAlang.joined(separator: ","), requiredUA)
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
        let isLocalStream = StreamRequestHeaderPolicy.isLocalPlaybackURL(playURL)
            // A trailer is a short clip and never needs the big remote read-ahead. A googlevideo trailer is
            // already proxied to 127.0.0.1 (small), but a worker-fallback trailer (trailer.vortx.tv, a remote
            // host) otherwise takes the full 256 MiB remote buffer and contributes to the tvOS jetsam that the
            // owner sees as "the server died". Give the trailer host the small read-ahead too.
            || (playURL.host?.contains("trailer.vortx.tv") ?? false)
            // V2 HLS-master trailer fallback: also a short clip, opened directly on its remote googlevideo
            // manifest host (never proxied), so give it the small read-ahead for the same jetsam reason.
            // Never true with the flag off (no manifest URLs exist then).
            || (isGoogleVideo(playURL) && YouTubeDirectResolver.isManifestURL(playURL))
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
            // iOS/tvOS run the streaming server IN-PROCESS and are jetsam-bound. Crucially, the node
            // server's reported RSS INCLUDES this mpv demuxer cache (same process), so a big read-ahead
            // contributes directly to the process ceiling even on DEBRID playback. tvOS uses 128 MiB
            // below; iOS keeps its existing 256 MiB baseline. The Mac keeps a larger buffer because its
            // server and swap model are different.
            #if os(tvOS)
            // The tvOS NORMAL remote read-ahead baseline, RemoteConfig-backed (default 384 MiB, raised from
            // 128). Twelve field logs proved the earlier 128 MiB starved the forward buffer into constant
            // rebuffering because a SPURIOUS advisory-warning shed kept slamming the cap down; the shed is now
            // gated on real headroom (shedForMemoryPressure), so a 384 MiB baseline is both safe and necessary
            // for smooth 4K in the biggest files. 384 stays under the ~700 MiB jetsam wall; the applied-cap
            // policy below still bounds this even with the disk-cache setting armed. Local torrents keep the
            // tight 96 MiB (jetsam-critical in-process server), and the reduced (2 GB Apple TV HD) branch is
            // untouched.
            readAhead = isLocalStream ? "96MiB" : "\(RemoteConfig.snapshot.tvosReadAheadBaseline)MiB"
            #else
            readAhead = isLocalStream ? "96MiB" : "256MiB"
            #endif
            #endif
        }
        // `demuxer-max-bytes` for a REMOTE (debrid/direct CDN) VOD stream, reconciled by CONFIRMED cache-on-disk
        // capability rather than the user's requested setting.
        //
        // WHAT demuxer-max-bytes MEANS depends on whether the on-disk cache is armed:
        //   - cache-on-disk OFF (default): it is a HARD in-memory forward-PAYLOAD cap. mpv stops reading ahead
        //     when the RAM buffer fills, so it, not `cache-secs`, is the binding forward limit. Keep the device's
        //     RAM baseline here, UNCHANGED.
        //   - cache-on-disk ON: mpv offloads forward payloads to `demuxer-cache-dir` and frees their RAM, so this
        //     cap bounds packet METADATA (~50 MB per hour of media), NOT payload. Setting it to the multi-GB disk
        //     budget (the 0.2.11 mistake) is therefore a GB METADATA budget authorizing hours of runaway
        //     read-ahead -> jetsam (that build died ~47s in, buffer ~800s / ~700MB ahead, even on a 3 GB ATV 4K).
        //     So on this path we use a MODEST metadata cap (RemoteConfig diskCacheMetadataCapMiB, baked 128 MiB),
        //     deliberately allowed BELOW the RAM baseline because metadata is cheap; the forward DEPTH is bounded
        //     in TIME by `cache-secs` at setup. That modest value is also the RAM-payload guardrail should offload
        //     silently fall back (dir not writable).
        //
        // tvOS additionally caps the armed value under its device-safe process-memory wall (384 MiB normal /
        // 96 MiB reduced) so its server and mpv, which share one jetsam-limited process, stay bounded. A LOCAL
        // torrent buffers into the embedded server's own disk cache, and live owns its tight buffers, so both are
        // excluded from the armed branch and retain readAhead.
        let diskCacheRequestedForFile = DiskCacheSetting.diskCacheEnabled
        let usesConfirmedDiskOffload = VortXCacheShedPolicy.shouldUseDiskCacheForLoad(
            payloadOffloadRequested: diskCacheRequestedForFile,
            diskCacheOnDiskArmed: diskCacheOnDiskArmed,
            live: live,
            local: isLocalStream
        )
        let appliedCap: String
        if usesConfirmedDiskOffload {
            // ON-DISK STREAMING CACHE ARMED. Under cache-on-disk, demuxer-max-bytes bounds packet METADATA, not
            // payload, and the real forward lever is `cache-secs` (set at setup). So set a MODEST, independently
            // tunable metadata budget instead of the RAM read-ahead ceiling or the multi-GB disk budget: the
            // RemoteConfig knob diskCacheMetadataCapMiB (baked 128 MiB, clamp 48..256), which is allowed to fall
            // BELOW the RAM baseline. This is also the RAM-payload guardrail on the offload-fallback path.
            let metadataCapBytes = Int64(RemoteConfig.snapshot.diskCacheMetadataCapBytes)
            #if os(tvOS)
            // tvOS caps it under the device-safe process-memory wall (remoteVODCapBytes: 384 MiB normal /
            // 96 MiB reduced) so a remote diskCacheMetadataCapMiB near 256 can never breach it; a smaller remote
            // value passes through, so the armed cap can still go below the RAM baseline (metadata is cheap).
            // remoteVODCapBytes ignores baselineBytes when diskCacheEnabled is true, so passing the metadata cap
            // for both arguments is exact.
            let tvOSApplied = TVOSProactiveMemoryPressurePolicy.remoteVODCapBytes(
                diskCacheEnabled: true,
                baselineBytes: metadataCapBytes,
                configuredDiskCacheBytes: metadataCapBytes,
                performanceReduced: PerformanceMode.reduced,
                enforceTVOSLimit: true
            )
            appliedCap = String(tvOSApplied)
            #else
            appliedCap = String(metadataCapBytes)
            #endif
        } else {
            #if os(tvOS)
            if !live, !isLocalStream {
                let baselineBytes = Int64(
                    VortXCacheShedPolicy.capBytes(readAhead)
                        ?? (PerformanceMode.reduced ? 96 << 20 : 128 << 20)
                )
                let tvOSApplied = TVOSProactiveMemoryPressurePolicy.remoteVODCapBytes(
                    diskCacheEnabled: false,
                    baselineBytes: baselineBytes,
                    configuredDiskCacheBytes: baselineBytes,
                    performanceReduced: PerformanceMode.reduced,
                    enforceTVOSLimit: true
                )
                appliedCap = String(tvOSApplied)
            } else {
                appliedCap = readAhead
            }
            #else
            appliedCap = readAhead
            #endif
        }
        // Log only scheme://host/path: debrid and direct-CDN URLs carry API tokens / signed queries in the
        // userinfo and query string, which must not land in the device's persistent unified log.
        let redactedURL = "\(playURL.scheme ?? "?")://\(playURL.host ?? "?")\(playURL.path)"
        mpvLog.log("loadFile → \(redactedURL, privacy: .public)\(sidecar != nil ? " (+audio sidecar)" : "", privacy: .public)")
        // `loadfile replace` mutates the playlist synchronously, while actual loading begins later. Hold the
        // same lock START_FILE takes and consume the immutable entry id returned by this exact command before
        // a racing event can bind. Reading playlist/0 afterward is racy because redirects and START_FILE may
        // mutate index zero as soon as the mpv core releases its own lock.
        loadTokenLock.lock()
        var commandNode = mpv_node()
        let commandResult = commandReturningNode("loadfile", args: args, result: &commandNode)
        let entryID: Int64
        if commandResult >= 0 {
            entryID = Self.returnedPlaylistEntryID(from: commandNode) ?? 0
            mpv_free_node_contents(&commandNode)
            if entryID == 0 {
                mpvLog.error("loadfile accepted without one valid returned playlist entry id; callback attribution invalidated")
            }
        } else {
            entryID = 0
        }
        loadProvenance.completeReplacement(
            commandSucceeded: commandResult >= 0,
            entryID: entryID,
            token: issuedToken
        )
        #if os(tvOS)
        if commandResult >= 0 {
            beginFramePresentationLoad()
        }
        #endif
        loadTokenLock.unlock()
        if commandResult >= 0 {
            if !preservingSeekEOFRecovery {
                seekEOFRecoveryTimeout?.cancel(); seekEOFRecoveryTimeout = nil
                seekEOFRecovery.cancel()
            }
            seekEOFReloadSource = SeekEOFReloadSource(
                url: url, headers: headers, live: live, audioSidecar: audioSidecar
            )
            finishCacheFlushFlight(cacheFlushFlight.reset(), sampleLiveState: false)
            mpv_set_property_string(mpv, "demuxer-max-bytes", appliedCap)
            activeReadAheadCap = appliedCap
            baselineReadAheadCap = appliedCap
            // Pace the forward-cache fill for an offload-armed remote VOD: start cache-secs small and ramp to the
            // 900s ceiling so the fill never bursts the present thread (climb-time output drops). Non-armed / live
            // / local sources keep their existing single cap; cancel any stale ramp from a prior in-place source.
            if usesConfirmedDiskOffload {
                armDiskCacheReadaheadRamp()
            } else {
                cacheReadaheadRampWork?.cancel(); cacheReadaheadRampWork = nil
                cacheReadaheadRampGeneration &+= 1
            }
            // Only an accepted replacement owns the new per-file cache lifecycle. A rejected command leaves
            // the current flight, cap bookkeeping, and paused state untouched so the old source can continue.
            pausedCacheClampWork?.cancel(); pausedCacheClampWork = nil
            pausedCacheClamped = false
            memoryCacheClamped = false
            // A new file starts with a fresh headroom episode: an in-band advisory flush may fire once again.
            #if canImport(UIKit)
            hasFlushedInBandSinceHeadroomRecovered = false
            #endif
            #if os(tvOS)
            proactiveMemoryCacheClamped = false
            proactiveRecoveredSampleCount = 0
            restoreCyclesThisFile = 0
            #endif
            // Restore the back-buffer for the accepted new file. A prior memory shed may have reduced it to
            // 8MiB; live keeps configureLiveMode's own tight value.
            if !live { setString("demuxer-max-back-bytes", defaultBackBufferCap) }
            #if os(tvOS)
            // A seek cache hold with no pausedForCache release edge must not hold THIS accepted file's start.
            releaseSeekCacheHoldIfArmed()
            #endif
        } else {
            // Rejected replace: preserve the previous source's cache lifecycle and any active single flight.
        }
        return issuedToken
    }

    /// Decode only the command result map promised by mpv for `loadfile`. The pure field selector lives in
    /// `PlayerLoadProvenanceState` so malformed and duplicate result cases are covered by the standalone
    /// callback-provenance contract without mirroring libmpv's threading behavior.
    private static func returnedPlaylistEntryID(from result: mpv_node) -> Int64? {
        guard result.format == MPV_FORMAT_NODE_MAP,
              let list = result.u.list,
              list.pointee.num > 0,
              let keys = list.pointee.keys,
              let values = list.pointee.values else { return nil }
        var fields: [PlayerLoadProvenanceState.CommandResultField] = []
        fields.reserveCapacity(Int(list.pointee.num))
        for index in 0..<Int(list.pointee.num) {
            guard let keyPointer = keys[index] else { continue }
            let value = values[index]
            fields.append(.init(
                key: String(cString: keyPointer),
                int64Value: value.format == MPV_FORMAT_INT64 ? value.u.int64 : nil
            ))
        }
        return PlayerLoadProvenanceState.playlistEntryID(from: fields)
    }

    private func configureLiveMode(_ live: Bool) {
        guard mpv != nil else { return }   // raw mpv_set_property_string below: never pass a nil handle post-teardown
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
                                    "reconnect=1,reconnect_streamed=1,reconnect_delay_max=7,multiple_requests=1")
        }
    }
    
    /// Ramp the forward-cache DEPTH (`cache-secs`) from a small start to the RemoteConfig ceiling instead of
    /// setting the ceiling at load. Under cache-on-disk `cache-secs` is the binding forward lever, and a fast
    /// source fills it in one max-rate burst (network TLS + demux parse + disk writes) that contends with the
    /// Metal present thread on the CPU-limited Apple TV, so frames miss their deadline WHILE the cache climbs
    /// (diag 3/4: drops accrue only as cacheSeconds rises, none once it is steady). Stepping keeps the full 900s
    /// depth but turns one long burst into short ones. demuxer-readahead-secs is dropped below the start because
    /// mpv only lets cache-secs override it when LARGER, so a low cache-secs alone would be floored at setup's 300s.
    private func armDiskCacheReadaheadRamp() {
        guard mpv != nil else { return }
        let ceiling = max(1, RemoteConfig.snapshot.diskCacheReadaheadSecs)
        let start = min(RemoteConfigDefaults.diskCacheReadaheadStartSecs, ceiling)
        cacheReadaheadRampGeneration &+= 1
        cacheReadaheadRampWork?.cancel(); cacheReadaheadRampWork = nil
        cacheReadaheadRampAppliedSecs = start
        cacheReadaheadRampStartSecs = start
        cacheReadaheadRampLastFrameDrop = diagnosticInt(MPVProperty.frameDropCount) ?? 0
        setString("demuxer-readahead-secs", String(Self.diskCacheRampReadaheadFloorSecs))
        setString("cache-secs", String(start))
        mpvLog.log("disk cache readahead ramp start=\(start, privacy: .public)s ceiling=\(ceiling, privacy: .public)s")
        guard start < ceiling else { return }
        scheduleDiskCacheReadaheadRampStep(generation: cacheReadaheadRampGeneration, ceiling: ceiling)
    }

    /// The ramp ceiling re-derived from the live stream bitrate. An extreme-bitrate stream (UHD remux) tops out
    /// below the configured 900s so the offloaded forward payload never over-commits; an unknown or ordinary
    /// bitrate keeps the FULL configured ceiling (the byte budget is generous, so normal 4K is unaffected). Only
    /// ever lowers, and never below the floor.
    private func bitrateBoundedRampCeiling(configured: Int) -> Int {
        let videoBits = max(0, diagnosticDouble("video-bitrate") ?? 0)
        let audioBits = max(0, diagnosticDouble("audio-bitrate") ?? 0)
        let bytesPerSec = (videoBits + audioBits) / 8
        guard bytesPerSec > 0 else { return configured }
        let budgetSecs = Int(Double(Self.diskCacheReadaheadRampMaxReadaheadBytes) / bytesPerSec)
        // Reduce toward the bitrate budget but never above the configured ceiling, and never below the floor -
        // with the floor itself capped at the configured ceiling so a small remote ceiling is never exceeded.
        let bounded = min(configured, budgetSecs)
        return max(bounded, min(configured, Self.diskCacheReadaheadRampBitrateFloorSecs))
    }

    private func scheduleDiskCacheReadaheadRampStep(generation: UInt64, ceiling: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mpv != nil,
                  self.cacheReadaheadRampGeneration == generation else { return }
            // Read-and-clear the user-seek marker for THIS sample window (serialized with the seek entry points on
            // `queue`). A user seek's keyframe re-decode legitimately bursts frame drops, so its window must never
            // be mistaken for fill starvation and trigger a back-off; see userSeekedSinceRampSample.
            let seeked = self.userSeekedSinceRampSample
            self.userSeekedSinceRampSample = false
            // Re-derive the ceiling from the live bitrate: a very-high-bitrate stream tops out lower so the disk
            // offload never over-fills; ordinary 4K keeps the full depth (see bitrateBoundedRampCeiling).
            let effectiveCeiling = self.bitrateBoundedRampCeiling(configured: ceiling)
            let dropCount = self.diagnosticInt(MPVProperty.frameDropCount) ?? self.cacheReadaheadRampLastFrameDrop
            let stalled = self.diagnosticFlag(MPVProperty.pausedForCache) ?? false
            let dropDelta = dropCount - self.cacheReadaheadRampLastFrameDrop
            self.cacheReadaheadRampLastFrameDrop = dropCount
            let floor = max(1, self.cacheReadaheadRampStartSecs)
            if !seeked, dropDelta > Self.diskCacheReadaheadRampBurstDropThreshold {
                // A REAL burst with no user seek this window: the fill is starving the present thread now. Back OFF
                // one rung (never below the opening depth) to relieve read pressure; the climb resumes on the next
                // clean rung. A seek's own keyframe re-decode burst is gated out above so a directional press never
                // shrinks the buffer it is about to need refilled - that window HOLDs instead (#202).
                let next = max(floor, self.cacheReadaheadRampAppliedSecs - Self.diskCacheReadaheadRampStepSecs)
                if next != self.cacheReadaheadRampAppliedSecs {
                    self.cacheReadaheadRampAppliedSecs = next
                    self.setString("cache-secs", String(next))
                    self.mpvLog.log("disk cache readahead ramp backed off to \(next, privacy: .public)s (drop burst \(dropDelta, privacy: .public))")
                }
            } else if !stalled, dropDelta <= Self.diskCacheReadaheadRampDropTolerance {
                // Steady: no burst and no cache stall, so add one rung toward the (bitrate-bounded) ceiling.
                let next = min(self.cacheReadaheadRampAppliedSecs + Self.diskCacheReadaheadRampStepSecs, effectiveCeiling)
                if next > self.cacheReadaheadRampAppliedSecs {
                    self.cacheReadaheadRampAppliedSecs = next
                    self.setString("cache-secs", String(next))
                }
            }
            // else: minor jitter (tolerance < delta <= burst) or a cache stall -> HOLD this rung.
            guard self.cacheReadaheadRampAppliedSecs < effectiveCeiling else {
                self.mpvLog.log("disk cache readahead ramp reached ceiling \(effectiveCeiling, privacy: .public)s")
                return
            }
            self.scheduleDiskCacheReadaheadRampStep(generation: generation, ceiling: ceiling)
        }
        cacheReadaheadRampWork = work
        queue.asyncAfter(deadline: .now() + Self.diskCacheReadaheadRampIntervalSecs, execute: work)
    }

    func togglePause() {
        // During seek-EOF recovery mpv is deliberately forced paused to avoid presenting the reopened file
        // at zero. Toggle the desired transport state, not that temporary implementation pause.
        if let intent = seekEOFRecovery.current,
           seekEOFRecovery.reloadIsInFlight(owner: intent.owner) {
            intent.wasPaused ? play() : pause()
            return
        }
        getFlag(MPVProperty.pause) ? play() : pause()
    }

    #if canImport(UIKit)
    // MARK: - Jetsam relief: paused-cache clamp + memory-warning shedding (iOS/tvOS)
    //
    // mpv keeps FILLING the forward demuxer cache to `demuxer-max-bytes` while PAUSED, so a viewer who
    // starts a stream and immediately pauses parks the app at its peak cache footprint (256 MiB default
    // remote; up to 256 MiB with the Streaming-cache setting) for the whole pause. On tvOS the pause also
    // re-enables the idle timer, so a few minutes in the SCREENSAVER (its own 4K video pipeline) starts on
    // top, exactly when this app is at its fattest, and jetsam reaps the app: the "start a video, pause
    // for some minutes, app is suddenly gone" crash. Two defenses, both engine-local and reset per load:
    //  1. Paused clamp: after `pausedClampGraceSeconds` of continuous pause, drop the forward cap to a
    //     small floor and atomically reanchor the demuxer at its current position. Restored on resume.
    //  2. Memory warning: the system's last call before jetsam. Clamp to the floor immediately and keep
    //     it there for the rest of this file; playback survives fine on the small rolling buffer.

    private static let pausedClampGraceSeconds: TimeInterval = 60
    private static let clampedCacheCap = "48MiB"

    /// The paused-cache clamp target in bytes (`clampedCacheCap`, 48 MiB). This "user walked away" jetsam floor
    /// is DISTINCT from the memory-warning/proactive shed floor (`shedFloorBytes`, 192/128 MiB): a parked
    /// viewer whose tvOS screensaver stacks a second 4K pipeline on top still wants the buffer cut to the
    /// minimum, then restored on resume. Kept at 48 MiB on every tier so the paused-clamp arming guards below
    /// stay correct on the 2 GB Apple TV HD too (a 96 MiB reduced buffer is still > 48 and so still arms).
    private var pausedClampFloorBytes: Int {
        VortXCacheShedPolicy.capBytes(Self.clampedCacheCap) ?? (48 << 20)
    }

    /// The device-scaled, RemoteConfig-backed shed floor in bytes for the memory-warning and (tvOS) proactive
    /// clamp/restore paths: 192 MiB on the normal tier, scaled down on PerformanceMode.reduced. This is the
    /// controller's single point of RemoteConfig/PerformanceMode resolution; the dependency-free policy takes
    /// it as a parameter.
    private var shedFloorBytes: Int {
        RemoteConfig.snapshot.tvosShedFloorBytes(reduced: PerformanceMode.reduced)
    }

    /// One memory-warning shed rung (64 MiB): a genuine-low warning steps the cap down by this toward the
    /// floor rather than halving it or slamming it to the floor in one move.
    private var shedStepBytes: Int { VortXCacheShedPolicy.stepBytes }

    /// This file's CURRENT forward-cache budget in bytes: `activeReadAheadCap` as applied by loadFile,
    /// permanently reduced by each memory-warning shed. Falls back to the paused-clamp floor when the stored
    /// spelling is unparseable (never happens with the two spellings loadFile writes; defensive only).
    private var currentReadAheadBudgetBytes: Int {
        activeReadAheadCap.flatMap(VortXCacheShedPolicy.capBytes) ?? pausedClampFloorBytes
    }

    /// Main-thread mirror of mpv's pause property (posted from the event drain). Arms the paused clamp
    /// after the grace period, and restores the per-file cache cap on resume.
    private func pausedStateChanged(_ paused: Bool) {
        pausedCacheClampWork?.cancel(); pausedCacheClampWork = nil
        if paused {
            // Live keeps its own tight buffers, and a budget already at the shed floor has nothing left to
            // clamp. #148: a memory-warning shed no longer disarms this - after a first-warning step-down the
            // file keeps a real (halved) budget, and a parked viewer must still drop to the paused floor.
            guard mpv != nil, !configuredLiveMode, !pausedCacheClamped,
                  currentReadAheadBudgetBytes > pausedClampFloorBytes else { return }
            let graceReason = "paused \(Int(Self.pausedClampGraceSeconds))s"
            let work = DispatchWorkItem { [weak self] in self?.applyPausedCacheClamp(reason: graceReason) }
            pausedCacheClampWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pausedClampGraceSeconds, execute: work)
        } else {
            // Restore only the 60-second pause floor. A pressure-triggered reanchor can exist before that timer;
            // its `activeReadAheadCap` was already lowered by the pressure policy and must never be inflated.
            if pausedCacheClamped {
                pausedCacheClamped = false
                if mpv != nil, let cap = activeReadAheadCap {
                    setString("demuxer-max-bytes", cap)
                    mpvLog.log("resumed: paused cache clamp released, demuxer-max-bytes back to \(cap, privacy: .public)")
                }
            }
        }
    }

    private static let cacheFlushTimeoutSeconds: TimeInterval = 15

    private func cacheFlushSampleReceipt(_ name: String) -> String {
        guard let value = diagnosticDouble(name), value.isFinite else { return "unknown" }
        return String(format: "%.3f", value)
    }

    private func cacheFlushElapsedReceipt(startUptime: TimeInterval) -> String {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now.isFinite && startUptime.isFinite ? max(0, now - startUptime) : 0
        return String(format: "%.3f", elapsed)
    }

    private func beginCacheFlushReceipt(_ flight: CacheFlushFlight<PlayerLoadToken>) {
        let bufferedAheadReceipt = cacheFlushSampleReceipt("demuxer-cache-duration")
        let pausedForCacheReceipt = diagnosticFlag("paused-for-cache")
            .map { $0 ? "true" : "false" } ?? "unknown"
        DiagnosticsLog.log(
            "player",
            "internal-cache-flush-begin operation=atomic-reanchor flightId=\(flight.id) reason=\(flight.reason.rawValue) target=\(flight.targetArgument) bufferedAhead=\(bufferedAheadReceipt) pausedForCache=\(pausedForCacheReceipt) loadToken=\(flight.owner.hashValue) coalesced=\(flight.coalescedCount)"
        )
    }

    private func cacheFlushCommandErrorReceipt(
        _ flight: CacheFlushFlight<PlayerLoadToken>,
        commandName: String,
        status: Int32
    ) {
        DiagnosticsLog.log(
            "player",
            "internal-cache-flush-command-error flightId=\(flight.id) reason=\(flight.reason.rawValue) target=\(flight.targetArgument) loadToken=\(flight.owner.hashValue) coalesced=\(flight.coalescedCount) command=\(commandName) status=\(status)"
        )
    }

    private func cacheFlushDispositionReceipt(_ disposition: CacheFlushDisposition) -> String {
        switch disposition {
        case .started: return "flush started"
        case .coalesced: return "flush coalesced"
        case .skipped: return "flush skipped"
        }
    }

    private func handleCacheFlushTimeout(id: UInt64, owner: PlayerLoadToken) {
        guard let ended = cacheFlushFlight.settle(id: id, owner: owner) else { return }
        mpvLog.log("cache flush settle window ended id=\(id, privacy: .public)")
        finishCacheFlushFlight(ended)
    }

    /// `reason` only labels the log line; the decision is identical on both paths. `configuredLiveMode` is
    /// re-checked here (not only in pausedStateChanged) because enterBackground calls this directly.
    private func applyPausedCacheClamp(reason: String = "long pause") {
        guard mpv != nil, !configuredLiveMode, !pausedCacheClamped,
              currentReadAheadBudgetBytes > pausedClampFloorBytes else { return }
        guard getFlag(MPVProperty.pause) else { return }   // belt-and-suspenders; resume cancels the work item
        pausedCacheClamped = true
        setString("demuxer-max-bytes", Self.clampedCacheCap)
        let flushDisposition = flushDemuxerCachePreservingPosition(reason: .pausedCacheClamp)
        mpvLog.log("\(reason, privacy: .public): demuxer cache clamped to \(Self.clampedCacheCap, privacy: .public) until resume (\(self.cacheFlushDispositionReceipt(flushDisposition), privacy: .public))")
        DiagnosticsLog.log("player", "\(reason): mpv read-ahead clamped to \(Self.clampedCacheCap) until resume (\(cacheFlushDispositionReceipt(flushDisposition)))")
    }

    private static let cacheReanchorProgressEpsilon = 0.25

    /// A queued time sample from before the forced low-level seek is never accepted as transport progress.
    private func completeCacheFlushFlightRecovery(
        owner: PlayerLoadToken,
        observedPosition: Double
    ) {
        guard let completed = cacheFlushFlight.completeOnProgress(
            owner: owner,
            observedPosition: observedPosition,
            progressEpsilon: Self.cacheReanchorProgressEpsilon
        ) else { return }
        finishCacheFlushFlight(completed)
    }

    private func observeCacheReanchorSeek(owner: PlayerLoadToken) {
        guard cacheFlushFlight.markSeekEventObserved(owner: owner) else { return }
        DiagnosticsLog.log("player", "internal-cache-reanchor seek-observed loadToken=\(owner.hashValue)")
    }

    private func completeCacheReanchorOnPlaybackRestart(owner: PlayerLoadToken) {
        guard let completed = cacheFlushFlight.completeOnPlaybackRestart(owner: owner) else { return }
        finishCacheFlushFlight(completed)
    }

    /// Force libmpv to discard its forward cache and re-anchor at the current position in one core-locked command
    /// list. `drop-buffers` alone can terminalize a fully-read finite source before a recovery command exists;
    /// the compound list admits no event turn between that drop and the exact low-level seek.
    private func flushDemuxerCachePreservingPosition(reason: CacheFlushReason) -> CacheFlushDisposition {
        guard mpv != nil else { return .skipped }
        guard var owner = callbackLoadToken(requiresLoadedFile: true) else { return .skipped }

        if cacheFlushFlight.current?.owner == owner {
            _ = cacheFlushFlight.admit(owner: owner)
            return .coalesced
        }
        if cacheFlushFlight.current != nil {
            finishCacheFlushFlight(cacheFlushFlight.reset())
            guard mpv != nil,
                  let refreshedOwner = callbackLoadToken(requiresLoadedFile: true) else {
                return .skipped
            }
            owner = refreshedOwner
        }
        guard cacheFlushFlight.admit(owner: owner) == .started else { return .coalesced }
        guard getFlag(MPVProperty.seekable) else { return .skipped }
        let pos = getDouble(MPVProperty.timePos)
        guard pos.isFinite, pos > 0 else { return .skipped }
        let targetArgument = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), pos)
        guard let handle = mpv,
              let loadedOwner = callbackLoadToken(requiresLoadedFile: true),
              loadedOwner == owner else {
            return .skipped
        }

        precondition(cacheFlushFlight.nextFlightID < UInt64.max)
        let nextFlightID = cacheFlushFlight.nextFlightID + 1
        let timeoutWorkItem = DispatchWorkItem { [weak self, owner] in
            self?.handleCacheFlushTimeout(id: nextFlightID, owner: owner)
        }
        let flight = cacheFlushFlight.install(
            owner: owner,
            reason: reason,
            target: pos,
            targetArgument: targetArgument,
            startUptime: ProcessInfo.processInfo.systemUptime,
            timeoutWorkItem: timeoutWorkItem
        )
        beginCacheFlushReceipt(flight)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.cacheFlushTimeoutSeconds,
            execute: timeoutWorkItem
        )

        guard let flight = cacheFlushFlight.current,
              cacheFlushFlight.matches(id: flight.id, owner: flight.owner),
              flight.phase == .seeking,
              mpv != nil,
              let currentOwner = callbackLoadToken(requiresLoadedFile: true),
              currentOwner == flight.owner else {
            return .started
        }
        // This reports command-list acceptance only. SEEK plus restart/progress remain the required completion
        // evidence, and a real EOF is still terminal rather than being hidden as an internal maintenance edge.
        let commandResult = mpv_command_string(
            handle,
            "no-osd drop-buffers; no-osd seek \(flight.targetArgument) absolute+exact"
        )
        if commandResult >= 0 {
            _ = cacheFlushFlight.markSeekCommandAccepted(id: flight.id, owner: flight.owner)
            // This is still only command acceptance for the cache flight. The separate EOF policy waits for
            // MPV_EVENT_SEEK before it can classify anything, so an accepted maintenance command is never
            // treated as a completed seek.
            seekEOFRecoveryTimeout?.cancel(); seekEOFRecoveryTimeout = nil
            seekEOFRecovery.begin(
                owner: flight.owner, target: flight.target, wasPaused: getFlag(MPVProperty.pause),
                duration: getDouble(MPVProperty.duration),
                origin: .cacheReanchor, now: ProcessInfo.processInfo.systemUptime
            )
        } else if let ended = cacheFlushFlight.seekCommandError(id: flight.id, owner: flight.owner) {
            cacheFlushCommandErrorReceipt(ended, commandName: "drop-buffers; seek", status: commandResult)
            finishCacheFlushFlight(ended)
        }
        return .started
    }

    /// System memory warning (registered in viewDidLoad). Posted on the main thread; re-dispatch is a
    /// cheap guarantee in case a future SDK posts it elsewhere.
    @objc private func handleMemoryWarningNote() {
        DispatchQueue.main.async { [weak self] in self?.handleMemoryWarningCoalesced() }
    }

    /// The main-thread-only cooldown deadline `handleMemoryWarningCoalesced` enforces. Not `TimeInterval`-
    /// zero-initialized as "never fired": `ProcessInfo.processInfo.systemUptime` starts at boot, so 0 is
    /// already in the past on first call and the very first warning is always acted on immediately.
    private var memoryWarningCooldownUntil: TimeInterval = 0
    /// Beta 26 stutter fix: latched after ONE destructive flush at an advisory-band headroom ([pressure,
    /// restore)), cleared only when headroom recovers to the restore bar or a new file loads. Below the pressure
    /// bar this never gates anything - jetsam relief stays unconditional.
    private var hasFlushedInBandSinceHeadroomRecovered = false
    /// Report item 8: "coalesce OS memory warnings, but do not let each callback initiate additional
    /// main-thread work" - the diagnosed log shows six `didReceiveMemoryWarningNotification`s land in one
    /// window. `shedForMemoryPressure()` is not free (an `os_proc_available_memory()` syscall, and when it
    /// decides to act, mpv property-string IPC), so running it once per callback turns one system burst
    /// into N redundant passes on the same main thread that also owns frame presentation.
    private static let memoryWarningCoalesceWindow: TimeInterval = 2

    /// Act on the FIRST warning in a burst immediately - jetsam relief must never wait on a debounce timer -
    /// then ignore every further warning until the cooldown lapses. A warning arriving after the cooldown
    /// starts a fresh one-shot evaluation rather than being silently dropped, so sustained pressure keeps
    /// getting a fresh read of `os_proc_available_memory()` every window instead of acting once and going
    /// silent for the rest of playback.
    private func handleMemoryWarningCoalesced() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= memoryWarningCooldownUntil else { return }
        memoryWarningCooldownUntil = now + Self.memoryWarningCoalesceWindow
        shedForMemoryPressure()
    }

    private func shedForMemoryPressure() {
        guard mpv != nil else { return }
        // ROOT FIX ("buffers constantly after Beta 8"): the old handler LOWERED the forward cap on EVERY
        // memory warning. But those warnings are system-wide ADVISORY signals, not this process's headroom.
        // Twelve field logs settled it: across 743 os_proc_available_memory samples during playback the
        // MINIMUM free was 712 MiB and NONE dipped below the ~384 MiB pressure threshold, yet the cap was
        // slammed toward 48 MiB 65+ times, starving the forward buffer into constant rebuffering. Now the cap
        // is lowered ONLY when THIS process's real headroom is below the PRESSURE threshold (the same bar the
        // proactive clamp uses, ~384 MiB on the 3 GB box - so the 712 MiB field-min holds comfortably), and
        // then by one 64 MiB rung toward the raised, device-scaled floor (192 MiB normal / 128 MiB reduced),
        // never to a razor-thin 48 MiB. Headroom meeting the pressure bar leaves the cap UNCHANGED. The
        // forwardCap decision owns that bar; the expensive flush stays on the stricter restore bar (see
        // shedForMemory below and shouldDeferFlushOnWarning).
        let currentCapBytes = currentReadAheadBudgetBytes
        let floor = shedFloorBytes
        let step = shedStepBytes
        let availableBytes = UInt64(os_proc_available_memory())
        let physicalBytes = ProcessInfo.processInfo.physicalMemory
        let newCapBytes = VortXCacheShedPolicy.forwardCapAfterWarning(
            currentBytes: currentCapBytes,
            availableBytes: availableBytes,
            physicalBytes: physicalBytes,
            floorBytes: floor,
            stepBytes: step)
        let capLowered = newCapBytes < currentCapBytes

        // The flush gate: a forced exact re-anchor frees resident bytes NOW but causes a visible
        // frame-drop burst, so defer it when headroom is provably ample AND the live cache already fits the
        // reduced cap (the drop would free nothing the cap does not already bound). A failed fill read passes
        // Int.max, which overflows any reduced cap, so an unreadable fill keeps the drop; when headroom is
        // genuinely low the drastic flush fires, jetsam intact.
        //
        // Beta 26 stutter fix: field logs show headroom PARKED at ~400-420 MiB on the 3 GB box - permanently in
        // the [pressure, restore) band - with advisory warnings arriving every minute or two. The level-triggered
        // gate above flushed on EVERY one (~15 s of disruption each), producing a metronome-steady mid-play
        // stutter while freeing nothing durable (the cache just refills to the same held cap). The in-band flush
        // is now edge-triggered: once per headroom episode, re-armed only when headroom actually recovers to the
        // restore bar. Below the pressure bar the flush still fires unconditionally.
        let cacheFillBytes = diagnosticInt("demuxer-cache-state/fw-bytes") ?? Int.max
        let pressureBar = TVOSProactiveMemoryPressurePolicy.pressureThresholdBytes(physicalMemoryBytes: physicalBytes)
        let restoreBar = TVOSProactiveMemoryPressurePolicy.restoreThresholdBytes(physicalMemoryBytes: physicalBytes)
        if availableBytes >= restoreBar {
            // Headroom recovered: a future in-band warning earns its own single flush again.
            hasFlushedInBandSinceHeadroomRecovered = false
        }
        let policyDefer = VortXCacheShedPolicy.shouldDeferFlushOnWarning(
            availableBytes: availableBytes,
            physicalBytes: physicalBytes,
            currentCapBytes: currentCapBytes,
            cacheFillBytes: cacheFillBytes,
            floorBytes: floor,
            stepBytes: step)
        let deferFlush = VortXCacheShedPolicy.shouldDeferInBandFlush(
            availableBytes: availableBytes,
            pressureThresholdBytes: pressureBar,
            restoreThresholdBytes: restoreBar,
            policyDefer: policyDefer,
            hasFlushedSinceHeadroomRecovered: hasFlushedInBandSinceHeadroomRecovered)

        if capLowered {
            // Genuine low headroom: apply the non-increasing step-down and remember this file was shed. A
            // parked player keeps the paused floor on the live property (re-inflating a parked player's
            // read-ahead is the jetsam case the paused clamp prevents); pausedStateChanged picks the reduced
            // budget up on resume.
            memoryCacheClamped = true
            activeReadAheadCap = String(newCapBytes)
            if !pausedCacheClamped {
                setString("demuxer-max-bytes", String(newCapBytes))
            }
        }
        let flushDisposition: CacheFlushDisposition
        if !deferFlush {
            // Real pressure relief: shrink the seek-back buffer and drop the forward cache. Coupled to the
            // flush so an advisory warning with ample headroom never quietly costs the viewer their rewind
            // window or a frame-drop burst.
            setString("demuxer-max-back-bytes", "8MiB")
            if availableBytes < restoreBar {
                // Advisory-band flush: latch it so the next advisory warning at the same parked headroom
                // defers instead of stuttering playback again for no durable gain.
                hasFlushedInBandSinceHeadroomRecovered = true
            }
            flushDisposition = flushDemuxerCachePreservingPosition(reason: .memoryWarning)
        } else {
            flushDisposition = .skipped
        }

        let mib = newCapBytes >> 20
        let flushNote = deferFlush ? "flush deferred" : cacheFlushDispositionReceipt(flushDisposition)
        if capLowered {
            // Genuine low headroom (below the pressure bar): cap stepped down toward the floor.
            mpvLog.log("memory warning: low headroom, demuxer cache stepped down to \(mib, privacy: .public)MiB")
            DiagnosticsLog.log("player", "memory warning: available \(availableBytes >> 20)MiB below pressure bar, cache -> \(mib)MiB + \(flushNote)")
        } else {
            // Cap HELD (headroom meets the cap threshold). The overwhelming field case; note the flush may
            // still have fired in the [pressure, restore) band, where the cap holds but the conservative flush
            // does not yet defer.
            mpvLog.log("memory warning: cap held at \(mib, privacy: .public)MiB, headroom \(availableBytes >> 20, privacy: .public)MiB (\(flushNote, privacy: .public))")
            DiagnosticsLog.log("player", "memory warning: available \(availableBytes >> 20)MiB, cap held at \(mib)MiB + \(flushNote)")
        }
    }

    #if os(tvOS)
    /// Called from the mpv event queue. It posts at most one main-thread evaluation per sample interval.
    private nonisolated func maybeScheduleProactiveMemoryCheck(now: TimeInterval) {
        guard proactiveMemorySampleThrottle.shouldSchedule(
            now: now,
            interval: TVOSProactiveMemoryPressurePolicy.sampleInterval
        ) else { return }
        DispatchQueue.main.async { [weak self] in self?.evaluateProactiveMemoryPressure() }
    }

    /// Proactive tvOS headroom check using Apple's public dirty-memory-limit snapshot. It lowers the cache
    /// the moment headroom dips, and raises it one rung at a time only after headroom has stayed at twice
    /// the clamp threshold for a sustained run of samples. It never restores under pressure and never
    /// exceeds the cap loadFile applied for this file.
    private func evaluateProactiveMemoryPressure() {
        // Ambient hero previews (#44, `startMuted`) are excluded exactly as they are from the audio session,
        // the disk cache and the display mode: a decorative clip must neither run the clamp/restore ladder on
        // its own tiny buffers nor narrate "[player] mpv cache restored…" into the diagnostics of the real
        // playback surface, which is not even the instance being measured.
        guard mpv != nil, !configuredLiveMode, !startMuted else { return }
        let available = UInt64(os_proc_available_memory())
        let physical = ProcessInfo.processInfo.physicalMemory
        let threshold = TVOSProactiveMemoryPressurePolicy.pressureThresholdBytes(
            physicalMemoryBytes: physical
        )
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProactiveMemoryReceipt
                >= TVOSProactiveMemoryPressurePolicy.receiptInterval {
            lastProactiveMemoryReceipt = now
            DiagnosticsLog.log(
                "player",
                "tvOS memory headroom \(available >> 20)MiB, threshold \(threshold >> 20)MiB, mpv cache \(currentReadAheadBudgetBytes >> 20)MiB, proactive=\(proactiveMemoryCacheClamped)"
            )
        }

        // FAIL-260804-04: every path in this lane could only LOWER the budget, so a file that shed once
        // stayed at the reduced cap for its whole runtime, underrunning a 4K stream while the sampler
        // logged hundreds of free MiB every minute. Track the recovered run first (any sample short of the
        // restore threshold breaks it), then step back up one rung. Deliberately NOT a jump to baseline
        // and NOT a buffer flush: raising `demuxer-max-bytes` is enough, mpv refills on its own, and
        // flushDemuxerCachePreservingPosition exists for the drop path (its exact seek would be a
        // gratuitous re-anchor here, the "jumps forward after a pause" regression surface).
        if available >= TVOSProactiveMemoryPressurePolicy.restoreThresholdBytes(
            physicalMemoryBytes: physical
        ) {
            proactiveRecoveredSampleCount += 1
        } else {
            proactiveRecoveredSampleCount = 0
        }
        if let baseline = baselineReadAheadCap.flatMap(VortXCacheShedPolicy.capBytes),
           let restored = TVOSProactiveMemoryPressurePolicy.restoreTargetBytes(
                availableMemoryBytes: available,
                physicalMemoryBytes: physical,
                currentCapBytes: currentReadAheadBudgetBytes,
                baselineCapBytes: baseline,
                consecutiveRecoveredSamples: proactiveRecoveredSampleCount,
                completedRestoreCycles: restoreCyclesThisFile
           ) {
            // The next rung must re-earn its own two minutes, which is what bounds how often this file can
            // pay for a raise-then-reclamp cycle; the cycle count is the hard stop behind that (past it the
            // policy returns nil for the rest of the file and the clamp is one-way again).
            proactiveRecoveredSampleCount = 0
            restoreCyclesThisFile += 1
            let restoredString = String(restored)
            activeReadAheadCap = restoredString
            // Same discipline as the clamp below: a PAUSED player keeps the paused floor on the live
            // property (re-inflating a parked player's read-ahead is the jetsam case the paused clamp
            // exists to prevent); pausedStateChanged picks the raised budget up on resume.
            if !pausedCacheClamped {
                setString("demuxer-max-bytes", restoredString)
            }
            // Re-arm the one-shot proactive clamp on EVERY rung, including partial ones: a raise that left
            // the shrink control disabled would be a control that cannot answer the pressure the raise
            // itself creates. `memoryCacheClamped` is the "this file was shed by a warning" marker; clear it
            // only on a FULL return to baseline, where this file's budget is once again exactly what a fresh
            // load would have given it.
            proactiveMemoryCacheClamped = false
            if restored >= baseline { memoryCacheClamped = false }
            let restoredMiB = restored >> 20
            mpvLog.log(
                "proactive memory recovery: demuxer cache restored to \(restoredMiB, privacy: .public)MiB"
            )
            DiagnosticsLog.log(
                "player",
                "mpv cache restored to \(restoredMiB)MiB after sustained headroom (available \(available >> 20)MiB, ceiling \(baseline >> 20)MiB)"
            )
            return
        }

        guard let target = TVOSProactiveMemoryPressurePolicy.clampTargetBytes(
            availableMemoryBytes: available,
            physicalMemoryBytes: physical,
            currentCapBytes: currentReadAheadBudgetBytes,
            floorBytes: shedFloorBytes,
            alreadyClamped: proactiveMemoryCacheClamped
        ) else { return }

        proactiveMemoryCacheClamped = true
        let targetString = String(target)
        activeReadAheadCap = targetString
        if !pausedCacheClamped {
            setString("demuxer-max-bytes", targetString)
        }
        let flushDisposition = flushDemuxerCachePreservingPosition(reason: .proactiveMemoryPressure)
        let targetMiB = target >> 20
        mpvLog.log(
            "proactive memory pressure: demuxer cache clamped to \(targetMiB, privacy: .public)MiB for this file"
        )
        DiagnosticsLog.log(
            "player",
            "proactive memory clamp: available \(available >> 20)MiB below \(threshold >> 20)MiB, mpv cache -> \(targetMiB)MiB + \(cacheFlushDispositionReceipt(flushDisposition))"
        )
    }
    #endif
    #endif

    private func updateCapturePipeline() {
        guard let device = metalLayer.device else { return }
        let deviceID = ObjectIdentifier(device)
        guard deviceID != capturePipelineDevice else { return }

        guard let queue = device.makeCommandQueue() else { return }
        metalLayer.setupCaptureQueue(queue)
        capturePipelineDevice = deviceID
    }

    #if os(tvOS)
    /// A successful replacement owns a fresh diagnostics generation. The old cscale is
    /// restored before any new file can become eligible, including in-place episode loads.
    private func beginFramePresentationLoad() {
        restoreFramePresentationCscale()
        framePresentationVOPassesWork?.cancel()
        framePresentationVOPassesWork = nil
        framePresentationDiagnostics.end()
        lastReceiptFrameDropsPerMinute = nil   // a new file must not inherit the previous title's drop rate
        framePresentationGeneration &+= 1
        framePresentationLoadedGeneration = nil
        framePresentationStartedGeneration = nil
    }

    private func framePresentationFileLoaded(loadToken: PlayerLoadToken) {
        guard PlayerLoadProvenanceState.accepts(
            callbackToken: loadToken,
            activeToken: activeLoadToken
        ) else { return }
        framePresentationLoadedGeneration = framePresentationGeneration
        startFramePresentationDiagnosticsIfReady()
        updateFramePresentationPolicy()
    }

    private func startFramePresentationDiagnosticsIfReady() {
        guard isFullPlayerPresentation,
              mpv != nil,
              framePresentationLoadedGeneration == framePresentationGeneration,
              framePresentationStartedGeneration != framePresentationGeneration else {
            return
        }
        framePresentationDiagnostics.begin(
            generation: framePresentationGeneration,
            now: ProcessInfo.processInfo.systemUptime,
            frameDropRaw: diagnosticInt(MPVProperty.frameDropCount),
            decoderDropRaw: diagnosticInt(MPVProperty.decoderFrameDropCount)
        )
        framePresentationStartedGeneration = framePresentationGeneration
    }

    private func stopFramePresentationDiagnostics() {
        framePresentationVOPassesWork?.cancel()
        framePresentationVOPassesWork = nil
        framePresentationStartedGeneration = nil
        framePresentationLoadedGeneration = nil
        framePresentationDiagnostics.end()
    }

    private func scheduleFramePresentationTerminalCleanup(
        generation: UInt64,
        loadToken: PlayerLoadToken
    ) {
        guard framePresentationStartedGeneration == generation,
              framePresentationDiagnostics.currentGeneration() == generation,
              PlayerLoadProvenanceState.accepts(
                callbackToken: loadToken,
                activeToken: activeLoadToken
              ) else {
            return
        }
        stopFramePresentationDiagnostics()
        restoreFramePresentationCscale()
    }

    private func restoreFramePresentationCscale() {
        guard !framePresentationRestorePending else { return }
        guard framePresentationMitigationApplied,
              let prior = framePresentationPriorCscale else {
            // `mpv` is set to nil only when this controller permanently tears its
            // handle down. Until then, keep any incomplete state available for a
            // later retry rather than claiming an unverified restoration.
            guard mpv == nil else { return }
            framePresentationPriorCscale = nil
            framePresentationMitigationApplied = false
            return
        }
        guard mpv != nil else {
            framePresentationPriorCscale = nil
            framePresentationMitigationApplied = false
            return
        }

        framePresentationRestorePending = true
        queue.async { [weak self] in
            guard let self else { return }
            guard let handle = self.mpv else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.framePresentationRestorePending = false
                    guard self.mpv == nil else { return }
                    self.framePresentationPriorCscale = nil
                    self.framePresentationMitigationApplied = false
                }
                return
            }

            // The default sentinel returns cscale to mpv's unset state (empty string = libplacebo
            // default); a real recorded scaler restores verbatim. Never a wrong literal on default.
            let restoreValue = TVOSFramePresentationPolicy.restoreCscaleValue(prior: prior)
            let status = mpv_set_property_string(handle, "cscale", restoreValue)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.framePresentationRestorePending = false
                guard self.framePresentationMitigationApplied,
                      self.framePresentationPriorCscale == prior else {
                    return
                }
                if self.mpv == nil {
                    // stop() has permanently retired the handle. There is no live
                    // property left to restore and no future retry to preserve.
                    self.framePresentationPriorCscale = nil
                    self.framePresentationMitigationApplied = false
                    return
                }
                // A result belongs only to the exact handle on which the setter ran.
                // If a future controller lifecycle ever replaces the live handle,
                // keep the state fail-closed instead of crediting the replacement
                // with an old handle's result.
                guard self.mpv == handle else { return }
                guard status >= 0 else {
                    self.mpvLog.error(
                        "tvOS frame presentation cscale restore failed: \(String(cString: mpv_error_string(status)), privacy: .public)"
                    )
                    return
                }

                self.framePresentationPriorCscale = nil
                self.framePresentationMitigationApplied = false
                DiagnosticsLog.log(
                    "perf",
                    "tvOS frame presentation restored cscale=\(prior)"
                )
                // A new file can finish loading while the serialized restore is in
                // flight. Re-evaluate it now that the previous state is truly gone.
                self.updateFramePresentationPolicy()
            }
        }
    }

    /// Applies only the single requested runtime property. Every other scaler and
    /// renderer option stays untouched, and an unreadable prior value fails closed.
    private func updateFramePresentationPolicy() {
        guard mpv != nil,
              isFullPlayerPresentation,
              framePresentationLoadedGeneration == framePresentationGeneration,
              framePresentationStartedGeneration == framePresentationGeneration else {
            restoreFramePresentationCscale()
            return
        }
        let input = TVOSFramePresentationPolicy.Input(
            fullPlayer: isFullPlayerPresentation,
            standardQuality: PlaybackSettings.videoUpscaling == .standard,
            videoWidth: getInt("video-params/w"),
            videoHeight: getInt("video-params/h"),
            gamma: getString(MPVProperty.videoParamsGamma) ?? "",
            dolbyVision: contentIsDolbyVision,
            signalPeak: getDouble(MPVProperty.videoParamsSigPeak),
            customOptionKeys: PlaybackSettings.parsedCustomMpvOptions.map { $0.key }
        )
        // The prior read is EMPTY on `.standard` (libplacebo default is unset), and diagnosticString
        // maps empty -> nil. The pure decision treats that nil as the default sentinel and arms,
        // instead of the old guard that bailed on an unreadable prior and so could never arm here.
        let shouldApply = TVOSFramePresentationPolicy.shouldUseBilinearChroma(input)
        let action = TVOSFramePresentationPolicy.armDecision(
            shouldApply: shouldApply,
            alreadyApplied: framePresentationMitigationApplied,
            priorCscale: diagnosticString("cscale") ?? diagnosticString("options/cscale")
        )
        // B-instrument: a one-shot receipt of the chroma arm-decision inputs, so a device capture shows exactly
        // why the mitigation did (or did not) arm, since the observed drops are the chroma mitigation, not the
        // memory clamp. Log only when the decision signature changes so a frequently-run pass does not spam.
        // Instrumentation only: it changes no behavior.
        let armActionName: String
        switch action {
        case .restore: armActionName = "restore"
        case .noChange: armActionName = "noChange"
        case .arm: armActionName = "arm"
        }
        let customScaler = TVOSFramePresentationPolicy.hasCustomRendererOrScaler(input.customOptionKeys)
        let decisionSignature = "\(armActionName)|up=\(input.standardQuality)|\(input.videoWidth)x\(input.videoHeight)|g=\(input.gamma)|dv=\(input.dolbyVision)|sp=\(input.signalPeak)|cs=\(customScaler)"
        if decisionSignature != lastFramePresentationDecisionSignature {
            lastFramePresentationDecisionSignature = decisionSignature
            DiagnosticsLog.log(
                "perf",
                "tvOS frame presentation decision armAction=\(armActionName) upscaling=\(PlaybackSettings.videoUpscaling.rawValue) vparams=\(input.videoWidth)x\(input.videoHeight) gamma=\(input.gamma.isEmpty ? "na" : input.gamma) dv=\(input.dolbyVision) sigPeak=\(input.signalPeak) customScaler=\(customScaler) shouldApply=\(shouldApply)"
            )
        }
        switch action {
        case .restore:
            restoreFramePresentationCscale()
        case .noChange:
            break
        case .arm(let prior):
            guard let handle = mpv else { return }
            let status = mpv_set_property_string(handle, "cscale", "bilinear")
            guard status >= 0 else {
                mpvLog.error(
                    "tvOS frame presentation cscale apply failed: \(String(cString: mpv_error_string(status)), privacy: .public)"
                )
                return
            }
            framePresentationPriorCscale = prior
            framePresentationMitigationApplied = true
            DiagnosticsLog.log(
                "perf",
                "tvOS frame presentation armed gate=production-4k-hdr size=\(input.videoWidth)x\(input.videoHeight) gamma=\(input.gamma) sigPeak=\(input.signalPeak) priorCscale=\(prior)"
            )
        }
    }

    private func scheduleFramePresentationVOPassesSnapshot(
        generation: UInt64,
        loadToken: PlayerLoadToken
    ) {
        guard isFullPlayerPresentation,
              framePresentationStartedGeneration == generation,
              PlayerLoadProvenanceState.accepts(
                callbackToken: loadToken,
                activeToken: activeLoadToken
              ),
              framePresentationVOPassesWork == nil,
              !framePresentationDiagnostics.hasVOPasses(generation: generation) else {
            return
        }
        let work = DispatchWorkItem { [weak self] in
            // stop() nils mpv before enqueueing destruction on this same serial queue.
            // One local handle therefore stays valid for every read in this work item.
            guard let self,
                  let handle = self.mpv,
                  self.framePresentationDiagnostics.currentGeneration() == generation,
                  PlayerLoadProvenanceState.accepts(
                    callbackToken: loadToken,
                    activeToken: self.callbackLoadToken(requiresLoadedFile: true)
                  ) else {
                return
            }
            self.captureFramePresentationVOPasses(
                handle: handle,
                generation: generation
            )
        }
        framePresentationVOPassesWork = work
        queue.asyncAfter(
            deadline: .now() + Self.framePresentationVOPassesCooldown,
            execute: work
        )
    }

    /// One bounded snapshot shortly after a generation's first drop. Raw sample arrays
    /// and perf-info are intentionally not read.
    private func captureFramePresentationVOPasses(
        handle: OpaquePointer,
        generation: UInt64
    ) {
        guard framePresentationDiagnostics.currentGeneration() == generation,
              !framePresentationDiagnostics.hasVOPasses(generation: generation) else {
            return
        }
        let passCount = min(max(
            diagnosticInt("vo-passes/fresh/count", handle: handle) ?? 0,
            0
        ), 16)
        var totalAverageNanoseconds = 0
        var peakNanoseconds = 0
        var slowestPass: String?
        for index in 0..<passCount {
            let average = max(
                0,
                diagnosticInt(
                    "vo-passes/fresh/\(index)/avg",
                    handle: handle
                ) ?? 0
            )
            let peak = max(
                0,
                diagnosticInt(
                    "vo-passes/fresh/\(index)/peak",
                    handle: handle
                ) ?? 0
            )
            totalAverageNanoseconds += average
            if peak > peakNanoseconds {
                peakNanoseconds = peak
                slowestPass = diagnosticString(
                    "vo-passes/fresh/\(index)/desc",
                    handle: handle
                ).map { String($0.prefix(48)) }
            }
        }
        framePresentationDiagnostics.recordVOPasses(
            FramePresentationVOPassesSnapshot(
                count: passCount,
                averageMilliseconds: Double(totalAverageNanoseconds) / 1_000_000,
                peakMilliseconds: Double(peakNanoseconds) / 1_000_000,
                slowest: slowestPass
            ),
            generation: generation
        )
    }

    private func selectedSubtitleFramePresentationInfo()
        -> (codec: String?, source: String) {
        let selectedID = getInt(MPVProperty.sid)
        guard selectedID > 0 else { return (nil, "off") }
        let count = getInt("track-list/count")
        guard count > 0 else { return (nil, "unknown") }
        for index in 0..<count {
            guard getString("track-list/\(index)/type") == "sub",
                  getInt("track-list/\(index)/id") == selectedID else {
                continue
            }
            let source = diagnosticFlag("track-list/\(index)/external")
                .map { $0 ? "external" : "embedded" }
                ?? "unknown"
            return (
                diagnosticString("track-list/\(index)/codec"),
                source
            )
        }
        return (nil, "unknown")
    }
    #endif

    /// Re-derive the dynamic range from the CURRENTLY decoded video params and apply it. Used by the
    /// gamma observer and MPV_EVENT_VIDEO_RECONFIG, neither of which carries a sig-peak value, so it
    /// reads sig-peak fresh. Unlike the sig-peak property-change observer this does NOT depend on a value
    /// delta, so it re-applies HDR on an in-place episode switch even when the new file's mastering peak
    /// equals the previous one's (mpv coalesces equal property values and fires no change event).
    private func reapplyDynamicRange() {
        guard mpv != nil else { return }
        syncDisplayDynamicRange(sigPeak: getDouble(MPVProperty.videoParamsSigPeak))
    }

    /// Force a FULL dynamic-range re-apply after a window/backing swap (macOS native fullscreen enter/exit,
    /// which re-hosts the content view in a new fullscreen window and drops the CAMetalLayer's EDR
    /// activation + color environment). Re-arming the nil sentinel is mandatory: the content range did not
    /// change across the transition, so without it the `range != appliedDynamicRange` guard in
    /// syncDisplayDynamicRange early-returns and the colorspace tag + wantsExtendedDynamicRangeContent are
    /// never re-applied to the new backing (the exact "force a fresh apply" pattern loadFile/teardown use).
    /// Cheap and idempotent for SDR content (re-tags nil colorspace + EDR off). Called by the macOS chrome
    /// from the didEnter/didExitFullScreen notification handlers; harmless from any other window change.
    func resyncDynamicRangeForWindowChange() {
        appliedDynamicRange = nil
        reapplyDynamicRange()
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
        #if os(tvOS)
        updateFramePresentationPolicy()
        #endif
        var range: ContentDynamicRange
        if gamma == "hlg" {
            range = .hlg
        } else if gamma == "pq" || sigPeak > 1.0 {
            range = .hdr10
        } else if contentIsDolbyVision && gamma.isEmpty && sigPeak <= 1.0 {
            // Demote-to-libmpv edge (#148): a DV/HDR title that just fell back from the AVPlayer remux lane
            // runs this the FIRST time before mpv has probed the stream (the first videoParamsSigPeak observer
            // fires with sigPeak=0.0 and gamma still empty). This branch used to treat the bare
            // `contentIsDolbyVision` text-parsed Boolean as proof the eventual frames are PQ/BT.2020 and seed
            // HDR10 immediately - unsafe: a title labelled Dolby Vision can be Profile 5, which has no
            // independently playable HDR10-compatible base layer, so pre-tagging it HDR10 before any real
            // decoded evidence exists can present a genuine green/purple matrix error as if it were correct
            // HDR10 output. Consult the profile-aware descriptor instead of assuming the label is proof.
            switch DVPlaybackPolicy.dolbyVisionFallbackOutput(
                contentIsDolbyVision: contentIsDolbyVision,
                info: dolbyVisionFallbackInfo,
                // The libmpv/libplacebo lane only ever tone-maps Dolby Vision to a PQ base layer (see the
                // .dolbyVision case comment below); it has no true DV output path to map into.
                mappedDolbyVisionAvailable: false
            ) {
            case .hdr10, .mappedDolbyVision:
                // A proven HDR10-compatible base layer (e.g. Profile 8.1). The frames ARE PQ, so seed HDR10
                // up front instead of a transient SDR tag. The later real-params apply (gamma=pq,
                // sigPeak~4.9) resolves to the same .hdr10 and no-ops on the `range != appliedDynamicRange`
                // guard below, so there is no second mode switch.
                range = .hdr10
            case .waitForDecodedParameters, .rejectAndHopSource:
                // No decoded evidence and no proven-compatible base layer. Apply NOTHING: do not set
                // target-trc/target-prim, do not tag the layer colourspace, and do not request a tvOS
                // display mode yet. Falling through to `.sdr` here would be the same kind of guess in the
                // other direction (a Profile 5 title is not proven SDR either); leaving `appliedDynamicRange`
                // untouched means the next sig-peak/gamma callback, once mpv actually decodes, makes the
                // real decision instead of this one guessing it.
                DiagnosticsLog.log(
                    "dv",
                    "libmpv pre-probe: no decoded params and no proven base-layer compatibility "
                        + "(dv=\(contentIsDolbyVision) profile=\(dolbyVisionFallbackInfo.profile.map(String.init) ?? "?") "
                        + "blHDR10Compat=\(dolbyVisionFallbackInfo.baseLayerHDR10Compatible.map(String.init) ?? "?")); "
                        + "deferring colour/display-mode apply")
                return
            }
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
#if os(tvOS)
        // HONEST OUTPUT: the mpv lane decodes/tone-maps Dolby Vision to PQ pixels, so it requests HDR10 and
        // NEVER the panel's Dolby Vision mode. An earlier build promoted .hdr10 -> .dolbyVision here when the
        // stream was DV-flagged; that flips the TV into real DV mode over tone-mapped PQ pixels ("fake Dolby
        // Vision", the behavior other players are criticized for), and decoded-pixel pipelines deliberately
        // downgrade DV requests to HDR10 for exactly this reason. The DV badge is earned only by the AVPlayer
        // remux lane, which carries the genuine bitstream to VideoToolbox. The breadcrumb for it is emitted
        // AFTER the transition guard below, so it logs once per actual transition, not on every re-derive.
#endif
        guard range != appliedDynamicRange else { return }
        appliedDynamicRange = range
        #if os(tvOS)
        // A13: one breadcrumb per real HDR10 transition (it fired 4x in 91ms when it sat above the guard).
        if contentIsDolbyVision, range == .hdr10 {
            DiagnosticsLog.log("dv", "DV title on the libmpv lane: requesting HDR10 output (tone-mapped PQ; true DV plays only on the AVPlayer remux lane)")
        }
        #endif

        // Synchronous breadcrumbs: if any of these statements kills the process
        // (MoltenVK owns the layer's drawables and mid-stream colorspace changes
        // are crash-suspect territory), the last line in diagnostics.log names it.
        let trc = (range == .hdr10 || range == .dolbyVision) ? "pq" : (range == .hlg ? "hlg" : "auto")
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
        // The libmpv lane tone-maps Dolby Vision through its PQ path and reports .hdr10 for it, so it never
        // actually produces .dolbyVision here; map it to the PQ colorspace defensively (true DV plays on the
        // AVPlayer remux lane, which owns the .dolbyVision display-mode request).
        case .dolbyVision: metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        }
        #if os(iOS) || os(macOS)
        // EDR is APP-ASSERTED here, never left to MoltenVK. MoltenVK sets
        // wantsExtendedDynamicRangeContent=true only as a one-time side effect of building the swapchain
        // (from the vo thread; see MetalLayer's override), so it is not re-assertable: on macOS, entering
        // native fullscreen moves the content into a NEW fullscreen window/backing store, which drops the
        // layer's EDR activation, and with nothing re-asserting it the PQ/HLG pixels present as SDR (the
        // washed-out fullscreen HDR/DV report). Setting it alongside the colorspace tag makes the whole
        // output chain deterministic and re-appliable via resyncDynamicRangeForWindowChange(). The MetalLayer
        // setter override is main-thread-safe (async hop when needed). tvOS has no EDR layer control at all
        // (HDR rides HDRDisplayMode below).
        metalLayer.wantsExtendedDynamicRangeContent = (range != .sdr)
        #endif
        DiagnosticsLog.logSync("mpv", "layer colorspace tagged")
        mpvLog.log("output range → \(range.rawValue, privacy: .public) (gamma=\(gamma, privacy: .public) sigPeak=\(sigPeak, privacy: .public))")
        DiagnosticsLog.log("mpv", "output range → \(range.rawValue) (gamma=\(gamma) sigPeak=\(sigPeak))")

#if os(tvOS)
        // Ambient hero previews (#44, startMuted) must NEVER drive the panel's display mode: assigning
        // preferredDisplayCriteria renegotiates the HDMI link and blanks the screen, so a Home/Detail
        // scroll that mounts one preview after another read as constant flicker on device. The preview
        // keeps its layer colorspace tagging above (per-layer compositing, no HDMI effect); only genuine
        // full-screen playback may switch the display. The main player never sets startMuted, so real
        // HDR10/HLG output on the mpv lane is unchanged.
        if startMuted {
            DiagnosticsLog.log("hdr", "display switch suppressed: muted hero preview never drives the panel mode")
        } else {
            HDRDisplayMode.request(range,
                                   fps: getDouble("container-fps"),
                                   width: getInt("video-params/w"),
                                   height: getInt("video-params/h"),
                                   in: view.window)
        }
#endif
    }
    
    func play() {
        if let owner = activeLoadToken,
           seekEOFRecovery.updateTransportIntent(owner: owner, paused: false) != nil {
            return
        }
        setFlag(MPVProperty.pause, false)
    }
    
    func pause() {
        if let owner = activeLoadToken,
           seekEOFRecovery.updateTransportIntent(owner: owner, paused: true) != nil {
            return
        }
        setFlag(MPVProperty.pause, true)
    }

    /// A new viewer seek cancels the recovery transaction, including its temporary forced pause. Restore the
    /// latest Play/Pause action before issuing the new seek so it captures the real user intent and cannot hang.
    private func supersedeSeekEOFRecoveryForExplicitSeek() {
        seekEOFRecoveryTimeout?.cancel(); seekEOFRecoveryTimeout = nil
        if let intent = seekEOFRecovery.supersedeReload() {
            setFlag(MPVProperty.pause, intent.wasPaused)
            DiagnosticsLog.log("player", "seek-eof-recovery superseded generation=\(intent.transportGeneration) loadToken=\(intent.owner.hashValue)")
        }
        seekEOFRecovery.cancel()
    }

    /// A viewer-controlled seek supersedes a cache-maintenance reanchor before it can reissue an old target.
    private func cancelCacheReanchorForExplicitSeek() {
        #if os(tvOS)
        cancelSeekRefillWatchdog()
        lastOutOfWindowSeekTarget = nil
        #endif
        guard let owner = callbackLoadToken(requiresLoadedFile: true) else { return }
        if let canceled = cacheFlushFlight.reset(owner: owner) {
            finishCacheFlushFlight(canceled)
            DiagnosticsLog.log("player", "cache-reanchor canceled by explicit seek loadToken=\(owner.hashValue)")
        }
        #if os(tvOS)
        releaseSeekCacheHoldIfArmed()
        #endif
    }

    func seek(to seconds: Double) {
        cancelCacheReanchorForExplicitSeek()
        supersedeSeekEOFRecoveryForExplicitSeek()
        // Mark this as a USER seek so the disk-cache read-ahead ramp does not misread the keyframe re-decode drop
        // burst as fill starvation (#202). Marshalled on `queue` to serialize with the ramp step's read/clear.
        queue.async { [weak self] in self?.userSeekedSinceRampSample = true }
        #if os(tvOS)
        // Only arm the cache-empty hold when the target lands OUTSIDE the currently buffered window. An in-window
        // scrub (a short hop while the forward cache holds minutes) is a cheap in-cache seek: arming there would
        // needlessly dump that buffer and stall ~2s refilling from the network (the scrub-forward stall, worst on
        // remote/aiostreams sources).
        if seekTargetOutsideCache(seconds) {
            armSeekCacheHold()   // out-of-window jump empties the forward cache; hold so the AO resumes once on a refilled cache
            lastOutOfWindowSeekTarget = seconds
            armSeekRefillWatchdog()   // recover a wedged cold-range refill fast (bounded reseek) instead of waiting on the stall reload
        }
        #endif
        let owner = callbackLoadToken(requiresLoadedFile: true)
        let wasPaused = getFlag(MPVProperty.pause)
        let duration = getDouble(MPVProperty.duration)
        command("seek", args: [String(seconds), "absolute"], returnValueCallback: { [weak self] status in
            guard let self, status >= 0, let owner else { return }
            self.seekEOFRecovery.begin(
                owner: owner, target: seconds, wasPaused: wasPaused, duration: duration, origin: .viewer,
                now: ProcessInfo.processInfo.systemUptime
            )
        })
    }

    /// Apply a saved Continue Watching offset after the player has produced its first frame.
    ///
    /// This is intentionally not a viewer scrub.  The ordinary absolute-seek route marks a user seek,
    /// and, on tvOS, may empty the forward cache and park output until a cold mid-file range refill
    /// completes.  A stored resume must be allowed to fail independently of presentation, so it issues
    /// the same mpv command without adopting that manual-scrub cache hold/watchdog transaction.
    func seekForResume(to seconds: Double) {
        cancelCacheReanchorForExplicitSeek()
        supersedeSeekEOFRecoveryForExplicitSeek()
        command("seek", args: [String(seconds), "absolute"])
    }

    /// Relative seek (e.g. -10 / +10), used by the tvOS remote's left/right. Small hops usually stay
    /// inside the buffered window, so no cache hold is armed for these.
    func seek(by seconds: Double) {
        cancelCacheReanchorForExplicitSeek()
        supersedeSeekEOFRecoveryForExplicitSeek()
        // Mark this as a USER seek (the tvOS remote's directional hop routes here via hiddenSeek) so the disk-cache
        // read-ahead ramp does not misread the keyframe re-decode drop burst as fill starvation (#202). Marshalled
        // on `queue` to serialize with the ramp step's read/clear.
        queue.async { [weak self] in self?.userSeekedSinceRampSample = true }
        command("seek", args: [String(format: "%.1f", seconds), "relative"])
    }

    #if os(tvOS)
    /// True while the one-shot post-seek cache hold is armed for an in-flight cache-emptying seek
    /// (a scrub commit, or the demuxer refresh-seek an audio/subtitle track change triggers).
    /// Main-thread only: armed from the UI's seek/track calls, released via a main hop from the
    /// event drain (mirroring pausedStateChanged).
    private var seekCacheHoldArmed = false

    /// Bounded, progress-aware watchdog for the OUT-OF-WINDOW scrub refill. An out-of-window jump empties the
    /// forward cache and then refills from a cold mid-file range read; on some sources (slow debrid CDN edges)
    /// that read resyncs slowly or wedges outright - paused-for-cache never clears and the vo never draws again
    /// (the scrub-back/forth stall). This retries the SAME seek a bounded number of times when the refill shows
    /// no forward-cache growth across a wedge window, so a wedged refill recovers in seconds instead of waiting
    /// on the ~30s mid-play stall reload. Same one-shot lifetime as the cache hold: armed by the out-of-window
    /// seek, cancelled on the pausedForCache=false release edge / loadFile / teardown. Main-thread only.
    private var seekRefillWatchdogWork: DispatchWorkItem?
    private var seekRefillWatchdogGeneration: UInt64 = 0
    private var lastOutOfWindowSeekTarget: Double?
    private var seekRefillRecoveriesThisSeek = 0
    private static let seekRefillWedgeWindowSecs: TimeInterval = 4   // no cache growth + still paused-for-cache => wedged
    private static let seekRefillProgressEpsilonSecs = 0.10          // buffered-ahead growth that proves the refill is live
    private static let seekRefillMaxRecoveries = 2                   // reseeks before deferring to the mid-play stall reload

    /// Conservative back window (seconds) still expected in the demuxer back-buffer: demuxer-max-back-bytes is
    /// small on tvOS (a handful of seconds at 4K bitrates), so a small back-scrub within this stays in cache and
    /// needs no hold.
    private let seekBackInCacheGuardSecs = 5.0

    /// True when an absolute seek target falls outside the demuxer's currently buffered window, so the seek
    /// empties the forward cache and needs the post-seek hold. A target inside [pos - backGuard, pos +
    /// forwardCached] is served from cache with no refill and must NOT arm the hold: that unnecessary dump is the
    /// scrub-forward stall. No cache sampled -> treat as out-of-window (safe: keeps the hold).
    private func seekTargetOutsideCache(_ target: Double) -> Bool {
        guard mpv != nil else { return true }
        let pos = getDouble(MPVProperty.timePos)
        let forwardCached = getDouble("demuxer-cache-duration")   // seconds buffered ahead of the playhead
        guard forwardCached > 0 else { return true }
        let forwardEdge = pos + max(0, forwardCached - 2)         // leave the last ~2s so a near-edge landing still refills cleanly
        let backEdge = pos - seekBackInCacheGuardSecs
        return target > forwardEdge || target < backEdge
    }

    /// Arm the post-seek cache hold for the seek about to be issued: hold playback in the normal
    /// buffering state until `cache-pause-wait` seconds are cached, so the avfoundation AO resumes
    /// ONCE on a refilled cache instead of stuttering through the refill (the crackly/distorted
    /// audio after scrubs and track changes; see the setupMpv comment). One-shot by design: setting
    /// these options globally at setup held EVERY playback start and doubled every ordinary mid-play
    /// rebuffer's wait. Released by releaseSeekCacheHoldIfArmed() once playback resumes (the
    /// pausedForCache=false edge), and defensively by loadFile so a lingering hold can never slow a
    /// fresh start. The muted hero-preview instance never arms, so its ambient clip keeps starting
    /// instantly.
    private func armSeekCacheHold() {
        guard !startMuted, mpv != nil else { return }
        seekCacheHoldArmed = true
        setString("cache-pause-initial", "yes")
        setString("cache-pause-wait", "1.5")
    }

    /// Put the cache-pause options back to their fast defaults once the held seek's playback has
    /// resumed (or, from loadFile, before a fresh start: a hold armed by a seek that never dipped
    /// into pausedForCache would otherwise linger onto the next file).
    private func releaseSeekCacheHoldIfArmed() {
        guard seekCacheHoldArmed else { return }
        seekCacheHoldArmed = false
        cancelSeekRefillWatchdog()   // the refill reached cache-pause-wait and playback resumed: the wedge net is done
        guard mpv != nil else { return }
        setString("cache-pause-initial", "no")
        setString("cache-pause-wait", "1")
    }

    /// Arm the bounded refill watchdog for the out-of-window seek just issued. Cancels any prior arm (a new
    /// scrub supersedes the old refill), resets the recovery budget, and starts the progress-aware poll.
    private func armSeekRefillWatchdog() {
        guard !startMuted, mpv != nil else { return }
        seekRefillWatchdogGeneration &+= 1
        seekRefillWatchdogWork?.cancel(); seekRefillWatchdogWork = nil
        seekRefillRecoveriesThisSeek = 0
        scheduleSeekRefillWatchdogCheck(
            generation: seekRefillWatchdogGeneration,
            lastCacheSample: diagnosticDouble("demuxer-cache-duration") ?? 0
        )
    }

    private func cancelSeekRefillWatchdog() {
        seekRefillWatchdogWork?.cancel(); seekRefillWatchdogWork = nil
        seekRefillWatchdogGeneration &+= 1
    }

    private func scheduleSeekRefillWatchdogCheck(generation: UInt64, lastCacheSample: Double) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mpv != nil,
                  self.seekRefillWatchdogGeneration == generation,
                  self.seekCacheHoldArmed else { return }   // hold released => refill succeeded, the watchdog is done
            if self.getFlag(MPVProperty.pause) {
                self.scheduleSeekRefillWatchdogCheck(generation: generation, lastCacheSample: lastCacheSample)
                return
            }
            let stillBuffering = self.diagnosticFlag(MPVProperty.pausedForCache) ?? false
            let forwardCache = self.diagnosticDouble("demuxer-cache-duration") ?? 0
            // A live refill is pulling bytes: the buffered-ahead edge grows. Only a genuine wedge - still
            // paused-for-cache AND no forward-cache growth across the whole window - is retried, so a healthy but
            // slow refill is never clobbered (mirrors the progress-aware start watchdog).
            let progressed = forwardCache > lastCacheSample + Self.seekRefillProgressEpsilonSecs
            if !stillBuffering || progressed {
                self.scheduleSeekRefillWatchdogCheck(generation: generation, lastCacheSample: forwardCache)
                return
            }
            guard self.seekRefillRecoveriesThisSeek < Self.seekRefillMaxRecoveries,
                  let target = self.lastOutOfWindowSeekTarget else {
                self.mpvLog.log("seek refill watchdog: wedged refill not recovered (budget spent); deferring to stall reload")
                return
            }
            self.seekRefillRecoveriesThisSeek += 1
            self.mpvLog.log("seek refill watchdog: refill wedged at \(String(format: "%.2f", forwardCache), privacy: .public)s buffered; reseek #\(self.seekRefillRecoveriesThisSeek, privacy: .public) to \(Int(target), privacy: .public)s")
            // Re-issue the SAME absolute seek: a fresh demuxer seek drops the stuck cold-range read and reopens
            // it, which is what unsticks a slow-resyncing mid-file range. Bounded; the mid-play stall watchdog
            // remains the ultimate backstop.
            self.command("seek", args: [String(target), "absolute"])
            self.scheduleSeekRefillWatchdogCheck(
                generation: generation,
                lastCacheSample: self.diagnosticDouble("demuxer-cache-duration") ?? 0
            )
        }
        seekRefillWatchdogWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seekRefillWedgeWindowSecs, execute: work)
    }
    #endif

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
        guard mpv != nil else { return false }   // teardown nils mpv; a late togglePause() must not pass NULL to libmpv
        var data = Int32()   // MPV_FORMAT_FLAG is a 4-byte C int, not Int/Int64; an 8-byte read only works by little-endian luck
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }
    
    private func setFlag(_ name: String, _ flag: Bool) {
        guard mpv != nil else { return }
        var data: Int32 = flag ? 1 : 0   // MPV_FORMAT_FLAG is a 4-byte C int; write exactly 4 bytes, not 8
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    private func getInt(_ name: String) -> Int {
        guard mpv != nil else { return 0 }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        return Int(data)
    }

    /// Optional property reads used only by the low-rate performance receipt.
    /// Unlike the player-facing helpers, these preserve "unsupported" as nil.
    private func diagnosticDouble(_ name: String) -> Double? {
        guard let handle = mpv else { return nil }
        return diagnosticDouble(name, handle: handle)
    }

    private func diagnosticDouble(_ name: String, handle: OpaquePointer) -> Double? {
        var value = Double()
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0,
              value.isFinite else { return nil }
        return value
    }

    private func diagnosticInt(_ name: String) -> Int? {
        guard let handle = mpv else { return nil }
        return diagnosticInt(name, handle: handle)
    }

    private func diagnosticInt(_ name: String, handle: OpaquePointer) -> Int? {
        var value = Int64()
        guard mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return Int(value)
    }

    private func diagnosticFlag(_ name: String) -> Bool? {
        guard let handle = mpv else { return nil }
        return diagnosticFlag(name, handle: handle)
    }

    private func diagnosticFlag(_ name: String, handle: OpaquePointer) -> Bool? {
        var value = Int32()
        guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else { return nil }
        return value > 0
    }

    private func diagnosticString(_ name: String) -> String? {
        guard let handle = mpv else { return nil }
        return diagnosticString(name, handle: handle)
    }

    private func diagnosticString(_ name: String, handle: OpaquePointer) -> String? {
        guard let cString = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cString) }
        let value = String(cString: cString)
        return value.isEmpty ? nil : value
    }

    private func setString(_ name: String, _ value: String) {
        guard mpv != nil else { return }
        mpv_set_property_string(mpv, name, value)
    }

    /// Positive evidence that Dolby Vision Profile 7 FEL pairing actually engaged.
    ///
    /// This exists because upstream mpv logs NOTHING on the success path: `f_output_chain` only warns
    /// when pairing FAILS, so "no warning" is indistinguishable from "the enhancement layer was never
    /// found and we silently rendered the base layer alone". `track-list/N/dependent` is the one
    /// property that proves the demuxer paired a base and enhancement video track, so we read it and
    /// state the outcome plainly in the probe trail.
    ///
    /// Note this reports the DEMUXER pairing. A "paired" line plus no "Failed to set up
    /// enhancement-layer" warning from mpv means the EL decoder came up and libplacebo is
    /// compositing it. Single-track interleaved Profile 7 uses mpv's splitter instead of track
    /// pairing, backed by `dovi_split` in the pinned FFmpeg release/9.0 build.
    private func probeEnhancementLayer() {
        guard mpv != nil else { return }
        let count = getInt("track-list/count")
        guard count > 0 else { return }
        var videoTracks = 0
        var dependentIDs: [Int] = []
        for i in 0..<count where (getString("track-list/\(i)/type") ?? "") == "video" {
            videoTracks += 1
            if getFlag("track-list/\(i)/dependent") { dependentIDs.append(getInt("track-list/\(i)/id")) }
        }
        guard videoTracks > 1 || !dependentIDs.isEmpty else { return }   // ordinary single-layer source
        if dependentIDs.isEmpty {
            VXProbe.log("dv", "FEL pairing unproven: \(videoTracks) video tracks, none marked dependent (no dependent-track/FEL pairing evidence)")
        } else {
            VXProbe.log("dv", "FEL paired: enhancement-layer track(s) \(dependentIDs) of \(videoTracks) video tracks")
        }
    }

    /// Read the current audio/subtitle/video tracks from mpv's `track-list`.
    func tracks(ofType type: String) -> [MPVTrack] {
        guard mpv != nil else { return [] }
        let count = getInt("track-list/count")
        guard count > 0 else { return [] }
        var result: [MPVTrack] = []
        for i in 0..<count where (getString("track-list/\(i)/type") ?? "") == type {
            // We ask mpv for `--show-dependent-tracks=yes` so the DV enhancement-layer track stays
            // observable for the FEL diagnostic. Dependent tracks are not independently decodable and
            // upstream hides them from `track-list` for exactly that reason, so re-hide them here and
            // keep the pickers identical to stock behaviour. Today this only ever matches a video EL
            // (never listed anyway), but it also pre-empts things like IAMF audio element layers.
            if getFlag("track-list/\(i)/dependent") { continue }
            result.append(MPVTrack(
                id: getInt("track-list/\(i)/id"),
                type: type,
                title: getString("track-list/\(i)/title") ?? "",
                lang: getString("track-list/\(i)/lang") ?? "",
                selected: getFlag("track-list/\(i)/selected"),
                forced: getFlag("track-list/\(i)/forced")   // AV_DISPOSITION_FORCED, for forced-subtitle auto-select
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

    func setAudioTrack(_ id: Int) {
        guard TrackSelector.shouldApplyAudioSelection(id, to: tracks(ofType: "audio")) else { return }
        #if os(tvOS)
        armSeekCacheHold()   // an aid change triggers a demuxer refresh-seek that discards + re-reads the forward cache
        #endif
        setString(MPVProperty.aid, id < 0 ? "no" : String(id))
    }
    func setSubtitleTrack(_ id: Int) {
        #if os(tvOS)
        armSeekCacheHold()   // a sid change triggers the same demuxer refresh-seek as an audio switch
        #endif
        // mpv refuses to render one track as BOTH the primary and the secondary subtitle. If the new
        // primary is the track currently pinned as the secondary, drop the secondary first so the primary
        // switch always lands (and the dual-subtitle picker stays consistent). No-op when no secondary is set.
        if id >= 0, id == secondarySubtitleID {
            setSecondarySubtitleTrack(-1)
        }
        setString(MPVProperty.sid, id < 0 ? "no" : String(id))
    }

    /// The current SECONDARY subtitle id (mpv `secondary-sid`), -1 = none. libmpv can render two subtitle
    /// tracks at once for language study: the primary at its normal bottom position and this one pinned to
    /// the top. Tracked here (not read back from the property each time) because the chrome's picker needs a
    /// stable selected-id and the track-list `selected` flag is true for BOTH the primary and secondary
    /// tracks once dual subtitles are on, so it can't tell them apart.
    private(set) var secondarySubtitleID: Int = -1

    /// The current PRIMARY subtitle id (mpv `sid`), or -1 when subtitles are off. Read back so the chrome can
    /// distinguish the primary track from the secondary one when building the dual-subtitle pickers. mpv
    /// subtitle track ids are 1-based, so a 0/absent read means "off".
    var primarySubtitleID: Int {
        guard mpv != nil else { return -1 }
        let v = getInt(MPVProperty.sid)
        return v > 0 ? v : -1
    }

    /// Select (or clear, with a negative id) the SECONDARY subtitle track. mpv shows it alongside the primary
    /// `sid` for dual-language study. The secondary line is pinned to the TOP (`secondary-sub-pos` = 0) so it
    /// never collides with the primary line at the bottom; recent mpv already defaults the secondary to the
    /// top, and setting an unknown property is a harmless no-op, so this is safe across engine versions. The
    /// user's subtitle style (font, size, colour) applies to both tracks automatically.
    func setSecondarySubtitleTrack(_ id: Int) {
        secondarySubtitleID = id
        #if os(tvOS)
        armSeekCacheHold()   // a secondary-sid change triggers the same demuxer refresh-seek as a primary sid switch
        #endif
        guard id >= 0 else {
            setString(MPVProperty.secondarySid, "no")
            return
        }
        setString(MPVProperty.secondarySid, String(id))
        setString(MPVProperty.secondarySubPos, "0")   // top of frame, clear of the primary line at the bottom
    }

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

    /// Per-pick network timeout and retry count for subtitle downloads. Hardcoded constants for now (a later
    /// pass may move these to RemoteConfig). 20s rides out a slow provider that shares bandwidth with a big
    /// remux spool (the "subtitle fails to load on big files" report); ONE retry rescues a transient timeout
    /// or flaky first connection.
    private static let subtitleDownloadTimeout: TimeInterval = 20
    private static let subtitleDownloadRetries = 1
    private static let maximumExternalSubtitleBytes = 8 * 1024 * 1024
    private let externalSubtitleRequestLock = NSLock()
    private var externalSubtitleRequestGeneration: UInt64 = 0

    private static func acceptsExternalSubtitleURL(_ url: URL) -> Bool {
        guard (url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http"),
              let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else { return false }
        // Reject local and private numeric targets before a request is issued.  DNS names remain subject to
        // the normal platform resolver; this closes direct file/loopback/LAN SSRF from untrusted add-ons.
        let forbidden = ["localhost", "::1", "0.0.0.0"]
        guard !forbidden.contains(host), !host.hasPrefix("127."), !host.hasPrefix("10."),
              !host.hasPrefix("192.168."), !host.hasPrefix("169.254."), !host.hasPrefix("fc"),
              !host.hasPrefix("fd") else { return false }
        if host.hasPrefix("172."), let second = host.split(separator: ".").dropFirst().first,
           let octet = Int(second), (16...31).contains(octet) { return false }
        return true
    }

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
        guard let remote = URL(string: url), Self.acceptsExternalSubtitleURL(remote),
              let requestToken = activeLoadToken else {
            completion?(false)
            return
        }
        externalSubtitleRequestLock.lock()
        externalSubtitleRequestGeneration &+= 1
        let requestGeneration = externalSubtitleRequestGeneration
        externalSubtitleRequestLock.unlock()
        let finish: (Bool) -> Void = { ok in DispatchQueue.main.async { completion?(ok) } }

        // Fast path: reuse a previously downloaded file if it's still on disk (no network).
        if let cached = Self.cachedSubtitleFile(for: remote) {
            self.queue.async { [weak self] in
                guard let self else { finish(false); return }
                finish(self.applyExternalSubtitle(
                    cached, title: title, lang: lang, loadToken: requestToken,
                    requestGeneration: requestGeneration
                ))
            }
            return
        }

        Self.downloadSubtitle(remote, timeout: timeout, retriesLeft: Self.subtitleDownloadRetries) { [weak self] localFile in
            guard let self, let localFile else { finish(false); return }
            self.queue.async {
                finish(self.applyExternalSubtitle(
                    localFile, title: title, lang: lang, loadToken: requestToken,
                    requestGeneration: requestGeneration
                ))
            }
        }
    }

    private func applyExternalSubtitle(_ localFile: URL, title: String, lang: String,
                                       loadToken: PlayerLoadToken,
                                       requestGeneration: UInt64) -> Bool {
        // Serialize the ownership check and sub-add with replacement load issue. If replacement won the lock,
        // this fetch is stale and is dropped. If subtitle add won, it completes on the old file before that file
        // is synchronously replaced, so it cannot attach an E2 subtitle to E3 media.
        loadTokenLock.lock(); defer { loadTokenLock.unlock() }
        externalSubtitleRequestLock.lock()
        let isLatestRequest = externalSubtitleRequestGeneration == requestGeneration
        externalSubtitleRequestLock.unlock()
        guard isLatestRequest, PlayerLoadProvenanceState.accepts(
            callbackToken: loadToken, activeToken: loadProvenance.activeToken
        ) else { return false }
        command("sub-add", args: [localFile.path, "select", title, lang])
        return true
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
        // Route through the pinned transport (resolve-once, connect to a vetted numeric peer) so an add-on
        // subtitle hostname cannot re-resolve to a private address between validation and the socket open.
        // Plain-HTTP subtitle URLs fail closed here, exactly like the AVPlayer overlay path (SubtitleFileFetcher).
        guard remote.scheme?.lowercased() == "https" else { done(nil); return }
        Task.detached(priority: .utility) {
            var limits = PinnedHTTPClient.Limits()
            limits.maximumBodyBytes = maximumExternalSubtitleBytes
            limits.maximumStreamBytes = maximumExternalSubtitleBytes
            limits.maximumWireBytes = maximumExternalSubtitleBytes + 32 * 1024
            limits.timeout = max(0.1, timeout)
            do {
                let response = try await PinnedHTTPClient.execute(.init(url: remote), limits: limits)
                // Redirects fail closed (the pinned transport does not follow them) and the body is
                // budget-bounded before it is written to disk.
                guard (200 ..< 300).contains(response.statusCode),
                      !response.body.isEmpty,
                      response.body.count <= maximumExternalSubtitleBytes else { done(nil); return }
                let ext = subtitleExtension(for: remote, contentType: response.headers["content-type"])
                // Deterministic, content-addressed filename so the same subtitle reuses one on-disk file all session
                // AND two distinct URLs never collide onto the same file (a 64-bit `hashValue` gives no such
                // guarantee, which would let one track's file serve the other's cached entry).
                let digest = SHA256.hash(data: Data(remote.absoluteString.utf8))
                let name = "stremiox-sub-\(digest.map { String(format: "%02x", $0) }.joined()).\(ext)"
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                guard (try? response.body.write(to: tmp)) != nil else { done(nil); return }
                rememberSubtitleFile(remote, tmp)
                done(tmp)
            } catch {
                if retriesLeft > 0 {
                    downloadSubtitle(remote, timeout: timeout, retriesLeft: retriesLeft - 1, done: done)
                } else { done(nil) }
            }
        }
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

    /// Current media summary for the player's metadata line: encoded video size and active audio codec.
    /// The channel field stays zero on this unchanged libmpv lane; produced-channel truth is currently owned
    /// only by the AVPlayer remux, where source and encoded output can differ.
    func mediaSummary() -> (width: Int, height: Int, audioCodec: String, audioChannels: Int) {
        guard mpv != nil else { return (0, 0, "", 0) }
        return (getInt("video-params/w"), getInt("video-params/h"),
                getString("audio-codec-name") ?? "", 0)
    }

    /// Persisted video-size mode, read at startup so the first frame already uses it.
    private(set) var videoSizeMode = UserDefaults.standard.string(forKey: "stremiox.videoSize") ?? MPVMetalViewController.defaultVideoSizeMode

    /// Default sizing per device. iPhone fills the screen (crop) so a 16:9 stream doesn't leave thick side
    /// bars on a tall phone in landscape, the "thick bezels, fill it like this" report. iPad / Mac / Apple
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
        requestedHardwareDecoder = on ? MPVHardwareDecodePolicy.videoToolbox : "no"
        loggedHardwareDecoderNegotiation = false
        setString("hwdec", requestedHardwareDecoder)
    }

    /// Player-settings detail that preserves explicit intent while exposing negotiated truth. A silent
    /// VideoToolbox fallback therefore leaves Hardware selected, but no longer presents it as active.
    var hardwareDecoderSettingDetail: String {
        if MPVHardwareDecodePolicy.isSoftwareFallback(
            requested: requestedHardwareDecoder,
            active: getString("hwdec-current")) {
            return "VideoToolbox requested, software active"
        }
        return "recommended"
    }

    private func recordHardwareDecoderNegotiation(active: String?) {
        guard !loggedHardwareDecoderNegotiation,
              let active,
              getInt("video-params/w") > 0,
              getInt("video-params/h") > 0 else { return }
        loggedHardwareDecoderNegotiation = true
        let width = getInt("video-params/w")
        let height = getInt("video-params/h")
        let codec = getString("video-codec-name") ?? "unknown"
        let fallback = MPVHardwareDecodePolicy.isSoftwareFallback(
            requested: requestedHardwareDecoder, active: active)
        DiagnosticsLog.log(
            "player",
            "hwdec negotiation requested=\(requestedHardwareDecoder) active=\(active) fallback=\(fallback) codec=\(codec) video=\(width)x\(height)"
        )
    }

    /// Switch the audio output policy (Auto / Stereo / Surround / Passthrough) on the playing file.
    /// Persists the choice, then re-applies the channel layout and the spdif bitstream list live so it
    /// takes effect without a reload; mpv re-opens the audio output when these properties change.
    /// `channelPolicy` reads `AudioOutputMode.current`, so persisting first makes it reflect `mode`.
    /// Setting `audio-spdif` to "" (when leaving Passthrough) tells mpv to decode to PCM again.
    func setAudioOutputMode(_ mode: AudioOutputMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: AudioOutputMode.key)
        #if canImport(UIKit)
        // Refresh AVAudioSession before mpv reopens its audio output. This makes an explicit Stereo
        // switch withdraw multichannel support and request two channels on the live route.
        applyChannelPolicy(force: true)
        #elseif os(macOS)
        // macOS CoreAudio owns normal route negotiation. Stereo is the supported persistent
        // compatibility override; every other saved choice returns to mpv's safe automatic policy.
        setString("audio-channels", mode == .stereo ? "stereo" : "auto-safe")
        #else
        setString("audio-channels", channelPolicy)
        #endif
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
        let activeDecoder = getString("hwdec-current")
        if MPVHardwareDecodePolicy.isSoftwareFallback(
            requested: requestedHardwareDecoder, active: activeDecoder) {
            rows.append(("Decode", "software (VideoToolbox unavailable)"))
        } else {
            rows.append(("Decode", activeDecoder ?? "software"))
        }
        let fps = getDouble("container-fps")
        if fps > 0 { rows.append(("FPS", String(format: "%.3f", fps))) }
        // TOTAL AND RATE. This row used to show the bare cumulative frame-drop count, which reads as a burst:
        // the Beta 13 report was "57 dropped frames" on a title that had been playing for 51 minutes with the
        // last drop long behind it. The rate comes from the delta the 30-second receipt path already computes
        // (FramePresentationDiagnosticsSnapshot.frameDropsPerMinute); no counter is added here, and before the
        // first receipt of a mount (or off tvOS, where the receipt carries no frame-presentation snapshot) the
        // row honestly shows the total alone rather than inventing a rate.
        let dropped = getInt("frame-drop-count")
        #if os(tvOS)
        if let rate = lastReceiptFrameDropsPerMinute {
            rows.append(("Dropped", "\(dropped) total, \(String(format: "%.0f", rate))/min"))
        } else {
            rows.append(("Dropped", "\(dropped) total"))
        }
        #else
        rows.append(("Dropped", "\(dropped) total"))
        #endif
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

    /// Read a larger mpv evidence set once per receipt interval. No property is
    /// observed and no playback option is changed, so unsupported builds simply
    /// report nil for that field.
    func playbackDiagnostics() -> PlaybackDiagnostics {
        let framePresentation: FramePresentationDiagnosticsSnapshot?
        #if os(tvOS)
        updateFramePresentationPolicy()
        let subtitle = selectedSubtitleFramePresentationInfo()
        framePresentation = framePresentationDiagnostics.takeSnapshot(
            now: ProcessInfo.processInfo.systemUptime,
            subtitleCodec: subtitle.codec,
            subtitleSource: subtitle.source,
            activeCscale: diagnosticString("cscale")
                ?? diagnosticString("options/cscale"),
            mitigationPriorCscale: framePresentationPriorCscale,
            mitigationApplied: framePresentationMitigationApplied,
            mitigationGate: "production-4k-hdr"
        )
        // Keep the rate the overlay renders (see playbackStats); this snapshot has already consumed the
        // interval, so the overlay must never take one of its own.
        if let framePresentation { lastReceiptFrameDropsPerMinute = framePresentation.frameDropsPerMinute }
        #else
        framePresentation = nil
        #endif
        let hardwareDecoder = diagnosticString("hwdec-current")
        recordHardwareDecoderNegotiation(active: hardwareDecoder)
        return PlaybackDiagnostics(
            frameDropCount: diagnosticInt(MPVProperty.frameDropCount),
            decoderFrameDropCount: diagnosticInt(MPVProperty.decoderFrameDropCount),
            mistimedFrameCount: diagnosticInt("mistimed-frame-count"),
            delayedFrameCount: diagnosticInt("vo-delayed-frame-count"),
            avSync: diagnosticDouble("avsync"),
            totalAVSyncChange: diagnosticDouble("total-avsync-change"),
            pausedForCache: diagnosticFlag("paused-for-cache"),
            cacheUnderrun: diagnosticFlag("demuxer-cache-state/underrun"),
            cacheIdle: diagnosticFlag("demuxer-cache-state/idle"),
            cacheBufferingPercent: diagnosticInt("cache-buffering-state"),
            cacheDuration: diagnosticDouble("demuxer-cache-duration"),
            hardwareDecoder: hardwareDecoder,
            estimatedVideoFPS: diagnosticDouble("estimated-vf-fps"),
            containerFPS: diagnosticDouble("container-fps"),
            displayFPS: diagnosticDouble("display-fps"),
            videoSyncMode: diagnosticString("video-sync"),
            videoSpeedCorrection: diagnosticDouble("video-speed-correction"),
            audioSpeedCorrection: diagnosticDouble("audio-speed-correction"),
            audioOutput: diagnosticString("current-ao"),
            framePresentation: framePresentation
        )
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

    /// Synchronous command variant for commands whose returned node is part of correctness. The caller owns
    /// the successful result and must release it with `mpv_free_node_contents` after parsing.
    private func commandReturningNode(
        _ command: String,
        args: [String?] = [],
        result: inout mpv_node
    ) -> Int32 {
        guard mpv != nil else { return -1 }
        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for ptr in cargs where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr!))
            }
        }
        let returnValue = mpv_command_ret(mpv, &cargs, &result)
        checkError(returnValue)
        return returnValue
    }

    func captureFrameJPEGData(maxWidth: CGFloat, completion: @escaping (Data?) -> Void) {
        guard mpv != nil else { completion(nil); return }
        let captureQueue = captureQueue
        let captureQueueState = captureQueueState
        // Build or rebuild the pipeline lazily; at VIDEO_RECONFIG time the device/drawableSize may
        // not be set yet (especially on tvOS); calling here retries until everything is ready.
        // updateCapturePipeline is a no-op once the queue matches the current Metal device.
        updateCapturePipeline()
        // Apple TV HD gate (#188): on pre-Apple3 GPUs the drawable-sourced MPS scale inside
        // nextDrawable() aborts the process, so MetalLayer refuses captures there. Log the gate
        // once so field diagnostics show WHY thumbnails are absent on that device class.
        if !MetalLayer.inlineDrawableCaptureAllowed(device: metalLayer.device) {
            if !loggedUnsupportedGPUCaptureGate {
                loggedUnsupportedGPUCaptureGate = true
                DiagnosticsLog.log(
                    "tp",
                    "on-device trickplay capture disabled: pre-Apple3 GPU (Apple TV HD class); drawable-sourced MPS scale unsafe there"
                )
            }
        }
        // requestCapture schedules a bounded GPU scale for the next nextDrawable() call on mpv's VO thread.
        // handler(nil) is called immediately by MetalLayer if the scale cannot be submitted, so
        // the caller's in-flight guard is always released even when the pipeline isn't ready yet.
        metalLayer.requestCapture(maxWidth: max(1, Int(maxWidth.rounded(.down)))) { [weak self] lease in
            guard let lease else { completion(nil); return }
            guard self != nil else {
                lease.release()
                completion(nil)
                return
            }
            captureQueue.async {
                let texture = lease.texture
                let prepared = captureQueueState.prepare(for: texture)
                let ctx = prepared.context
                if prepared.shouldEmitReceipt {
                    DiagnosticsLog.log(
                        "player",
                        "GPU capture \(texture.label ?? "bounded target"), format \(texture.pixelFormat.rawValue), requested max \(Int(maxWidth))px"
                    )
                }
                let jpeg: Data? = {
                    // CIImage(mtlTexture:) wraps the texture lazily. Metal textures have (0,0) at
                    // top-left; CIImage has (0,0) at bottom-left; flip y while scaling to 480px wide.
                    guard let raw = CIImage(
                        mtlTexture: texture,
                        options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]
                    ) else {
                        return nil
                    }
                    let tw = CGFloat(texture.width), th = CGFloat(texture.height)
                    let s = min(maxWidth, tw) / tw
                    let image = raw.transformed(
                        by: CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: 0, ty: th * s)
                    )
                    guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
                        return nil
                    }
                    return ctx.jpegRepresentation(
                        of: image,
                        colorSpace: sRGB,
                        options: [
                            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7
                        ]
                    )
                }()
                // CI/JPEG has fully materialized the Data. Release the reusable GPU target before
                // invoking arbitrary caller work so thumbnail decoding cannot hold the next capture.
                lease.release()
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
    private func emit(_ name: String, _ data: Any?, loadToken: PlayerLoadToken? = nil) {
        guard let capturedToken = loadToken ?? callbackLoadToken() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mpv != nil,
                  PlayerLoadProvenanceState.accepts(
                    callbackToken: capturedToken, activeToken: self.activeLoadToken
                  ) else { return }
            self.playDelegate?.propertyChange(
                propertyName: name, data: data, loadToken: capturedToken
            )
        }
    }

    /// Deliver every EOF as terminal media state. Cache maintenance uses a normal low-level seek and must never
    /// hide an EOF from a finite source.
    private func emitEndFileEOF(loadToken: PlayerLoadToken) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mpv != nil,
                  PlayerLoadProvenanceState.accepts(
                    callbackToken: loadToken, activeToken: self.activeLoadToken
                  ) else { return }
            self.finishCacheFlushFlight(self.cacheFlushFlight.reset(owner: loadToken))
            #if os(tvOS)
            if let generation = self.framePresentationDiagnostics.currentGeneration() {
                self.scheduleFramePresentationTerminalCleanup(
                    generation: generation, loadToken: loadToken
                )
            }
            #endif
            VXProbe.event(self.probeChannel, "endfile eof")
            self.playDelegate?.propertyChange(
                propertyName: MPVProperty.endFileEof, data: nil, loadToken: loadToken
            )
        }
    }

    /// An END_FILE right after a source-fenced, observed seek to a known mid-file position is not a
    /// completion. Only finite VOD is reopened once; live/unknown-duration sources keep their normal terminal
    /// semantics. A failed reopen becomes an error so the UI can offer source recovery without marking the
    /// episode watched or advancing it.
    private func handleEndFileEOF(loadToken: PlayerLoadToken) {
        guard mpv != nil,
              PlayerLoadProvenanceState.accepts(
                callbackToken: loadToken, activeToken: activeLoadToken
              ) else { return }
        if seekEOFRecovery.reloadIsInFlight(owner: loadToken) {
            failSeekEOFRecovery(loadToken: loadToken, reason: "reopen reached EOF before the seek restored")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let source = seekEOFReloadSource, !source.live,
           (seekEOFRecovery.shouldRejectUnprovenEOF(owner: loadToken, now: now)
             || seekEOFRecovery.shouldRejectUnsettledEOF(owner: loadToken, now: now)) {
            // The current source really is parked at the just-accepted target, but no command-correlated SEEK
            // boundary exists. Do not convert that ambiguity into a retry or a terminal completion.
            failSeekEOFRecovery(loadToken: loadToken, reason: "mid-file EOF before seek boundary")
            return
        }
        guard let source = seekEOFReloadSource, !source.live,
              seekEOFRecovery.shouldRecoverEOF(owner: loadToken, now: now),
              let intent = seekEOFRecovery.consumeEOFForReload(owner: loadToken) else {
            emitEndFileEOF(loadToken: loadToken)
            return
        }
        DiagnosticsLog.log("player", "seek-eof-recovery begin origin=\(intent.origin) target=\(String(format: "%.3f", intent.target)) paused=\(intent.wasPaused) loadToken=\(loadToken.hashValue)")
        let replacement = loadFile(source.url, headers: source.headers, live: source.live,
                                   audioSidecar: source.audioSidecar, preservingSeekEOFRecovery: true)
        guard PlayerLoadProvenanceState.accepts(callbackToken: replacement, activeToken: activeLoadToken),
              seekEOFRecovery.adoptReload(owner: replacement) != nil else {
            failSeekEOFRecovery(loadToken: loadToken, reason: "same-source reopen command was rejected")
            return
        }
        seekEOFRecoveryTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self, replacement] in
            guard let self, self.seekEOFRecovery.reloadIsInFlight(owner: replacement) else { return }
            self.failSeekEOFRecovery(loadToken: replacement, reason: "same-source reopen did not restore target")
        }
        seekEOFRecoveryTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seekEOFRecoveryTimeoutSeconds, execute: timeout)
    }

    private func beginSeekEOFRecoveryReloadSeek(loadToken: PlayerLoadToken) {
        guard let intent = seekEOFRecovery.beginReloadSeek(owner: loadToken) else { return }
        // Do not flash the beginning of the reopened file; resume only once target position is observed.
        setFlag(MPVProperty.pause, true)
        command("seek", args: [String(intent.target), "absolute"], returnValueCallback: { [weak self] status in
            guard status < 0 else { return }
            DispatchQueue.main.async {
                self?.failSeekEOFRecovery(loadToken: loadToken, reason: "reopen seek command failed")
            }
        })
    }

    private func completeSeekEOFRecovery(loadToken: PlayerLoadToken, position: Double) {
        guard let intent = seekEOFRecovery.completeReloadAtPosition(owner: loadToken, position: position) else { return }
        seekEOFRecoveryTimeout?.cancel(); seekEOFRecoveryTimeout = nil
        setFlag(MPVProperty.pause, intent.wasPaused)
        DiagnosticsLog.log("player", "seek-eof-recovery restored origin=\(intent.origin) target=\(String(format: "%.3f", intent.target)) paused=\(intent.wasPaused) loadToken=\(loadToken.hashValue)")
    }

    private func failSeekEOFRecovery(loadToken: PlayerLoadToken, reason: String) {
        seekEOFRecoveryTimeout?.cancel(); seekEOFRecoveryTimeout = nil
        seekEOFRecovery.cancel(owner: loadToken)
        guard PlayerLoadProvenanceState.accepts(callbackToken: loadToken, activeToken: activeLoadToken) else { return }
        finishCacheFlushFlight(cacheFlushFlight.reset(owner: loadToken))
        mpvLog.error("seek-adjacent EOF recovery failed: \(reason, privacy: .public)")
        VXProbe.event(probeChannel, "seek-eof-recovery failed \(reason)")
        emit(MPVProperty.endFileError, "Seek recovery failed: \(reason)", loadToken: loadToken)
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
                            if let sigPeak = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee,
                               let loadToken = self.callbackLoadToken() {
                                DispatchQueue.main.async { [weak self] in
                                    guard let self, self.mpv != nil,
                                          PlayerLoadProvenanceState.accepts(
                                            callbackToken: loadToken,
                                            activeToken: self.activeLoadToken
                                          ) else { return }
                                    #if canImport(UIKit)
                                    let maxEDRRange = self.view.window?.screen.potentialEDRHeadroom ?? 1.0
                                    #elseif canImport(AppKit)
                                    let maxEDRRange = self.view.window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
                                    #endif
                                    // display screen support HDR and current playing HDR video
                                    self.hdrAvailable = maxEDRRange > 1.0 && sigPeak > 1.0
                                    self.syncDisplayDynamicRange(sigPeak: sigPeak)
                                    self.playDelegate?.propertyChange(
                                        propertyName: propertyName, data: sigPeak, loadToken: loadToken
                                    )
                                }
                            }
                        case MPVProperty.videoParamsGamma:
                            // Gamma settled (e.g. HLG, or a late pq on an in-place switch). Re-derive the
                            // range from the current params; reapplyDynamicRange reads sig-peak fresh.
                            guard let loadToken = self.callbackLoadToken() else { break }
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.mpv != nil,
                                      PlayerLoadProvenanceState.accepts(
                                        callbackToken: loadToken, activeToken: self.activeLoadToken
                                      ) else { return }
                                self.reapplyDynamicRange()
                            }
                        #if os(tvOS)
                        case MPVProperty.frameDropCount:
                            guard let loadToken = self.callbackLoadToken(
                                    requiresLoadedFile: true
                                  ),
                                  let raw = UnsafePointer<Int64>(
                                    OpaquePointer(property.data)
                                  )?.pointee else {
                                break
                            }
                            // Report item 8: mpv's OUTPUT drop counter bursts during a display-mode
                            // transition, the first seconds of a new renderer generation, before the
                            // drawable stabilises, or a seek/remount - none of those are presentation
                            // regressions, they are expected renegotiation/startup noise. Score a delta
                            // into the reported total only once the generation is past its own startup
                            // window AND no seek or HDMI display-mode switch is currently in flight; the
                            // raw counter still advances underneath regardless (recordDrop/observe), so a
                            // drop that occurs while unsettled is discarded, never deferred into the next
                            // settled sample.
                            let presentationSettled = self.framePresentationDiagnostics
                                .isGenerationPastStartupWindow(now: ProcessInfo.processInfo.systemUptime)
                                && !self.seekCacheHoldArmed
                                && HDRDisplayMode.isSwitchSettled
                            guard let sample = self.framePresentationDiagnostics.recordDrop(
                                raw: Int(raw), decoder: false, presentationSettled: presentationSettled
                            ) else {
                                break
                            }
                            if sample.shouldEmitOutputContext {
                                let cacheDuration = self.diagnosticDouble(
                                    "demuxer-cache-duration", handle: handle
                                ).map { String(format: "%.3f", $0) } ?? "na"
                                let cacheBuffering = self.diagnosticInt(
                                    "cache-buffering-state", handle: handle
                                ).map(String.init) ?? "na"
                                let pausedForCache = self.diagnosticFlag(
                                    "paused-for-cache", handle: handle
                                ).map { $0 ? "true" : "false" } ?? "na"
                                let cacheUnderrun = self.diagnosticFlag(
                                    "demuxer-cache-state/underrun", handle: handle
                                ).map { $0 ? "true" : "false" } ?? "na"
                                let cacheIdle = self.diagnosticFlag(
                                    "demuxer-cache-state/idle", handle: handle
                                ).map { $0 ? "true" : "false" } ?? "na"
                                DiagnosticsLog.log(
                                    "perf",
                                    "frame-drop output-context generation=\(sample.generation) outputDelta=\(sample.delta) demuxer-cache-duration=\(cacheDuration) cache-buffering-state=\(cacheBuffering) paused-for-cache=\(pausedForCache) demuxer-cache-state/underrun=\(cacheUnderrun) demuxer-cache-state/idle=\(cacheIdle)"
                                )
                            }
                            if sample.delta > 0, presentationSettled {
                                DispatchQueue.main.async { [weak self] in
                                    self?.scheduleFramePresentationVOPassesSnapshot(
                                        generation: sample.generation,
                                        loadToken: loadToken
                                    )
                                }
                            }
                        case MPVProperty.decoderFrameDropCount:
                            guard let loadToken = self.callbackLoadToken(
                                    requiresLoadedFile: true
                                  ),
                                  let raw = UnsafePointer<Int64>(
                                    OpaquePointer(property.data)
                                  )?.pointee,
                                  let sample = self.framePresentationDiagnostics
                                    .recordDrop(raw: Int(raw), decoder: true) else {
                                break
                            }
                            if sample.delta > 0 {
                                DispatchQueue.main.async { [weak self] in
                                    self?.scheduleFramePresentationVOPassesSnapshot(
                                        generation: sample.generation,
                                        loadToken: loadToken
                                    )
                                }
                            }
                        case MPVProperty.subtitleStart:
                            guard self.callbackLoadToken(requiresLoadedFile: true) != nil else {
                                break
                            }
                            let start = property.format == MPV_FORMAT_DOUBLE
                                ? UnsafePointer<Double>(
                                    OpaquePointer(property.data)
                                  )?.pointee
                                : nil
                            self.framePresentationDiagnostics.recordSubtitleStart(start)
                        #endif
                        case MPVProperty.pausedForCache:
                            let buffering = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee ?? true
                            let callbackToken = self.callbackLoadToken(requiresLoadedFile: true)
                            if self.ownsSharedProbeState {
                                VXProbeState.shared.setPlayer(buffering: buffering)
                            }
                            VXProbe.event(self.probeChannel, "buffering \(buffering ? "start" : "end")")
                            self.emit(propertyName, buffering)
                            #if os(tvOS)
                            // Seek cache hold: buffering just ended, so the held seek's refill reached
                            // cache-pause-wait and playback resumed. Release the one-shot hold back to
                            // the fast defaults (main hop, mirroring pausedStateChanged below).
                            if !buffering {
                                DispatchQueue.main.async { [weak self] in
                                    guard let self, let callbackToken,
                                          PlayerLoadProvenanceState.accepts(
                                            callbackToken: callbackToken, activeToken: self.activeLoadToken
                                          ),
                                          self.diagnosticFlag(MPVProperty.pausedForCache) == false else { return }
                                    self.releaseSeekCacheHoldIfArmed()
                                }
                            }
                            #endif
                        case MPVProperty.duration:
                            if let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee,
                               let duration = MPVDurationProbePolicy.integerSeconds(value) {
                                if self.ownsSharedProbeState { VXProbeState.shared.setPlayer(dur: duration) }
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
                                #if os(tvOS)
                                self.maybeScheduleProactiveMemoryCheck(now: now)
                                #endif
                                if now - self.lastCacheTimeEmit >= 0.5 {
                                    self.lastCacheTimeEmit = now
                                    self.emit(propertyName, value)
                                }
                            }
                        case MPVProperty.timePos:
                            if let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                                let now = ProcessInfo.processInfo.systemUptime
                                #if os(tvOS)
                                self.maybeScheduleProactiveMemoryCheck(now: now)
                                #endif
                                // Coalesce the play head (mpv fires this per decoded frame). 4 Hz on
                                // capable hardware for a smooth progress bar; 2 Hz on a constrained
                                // Apple TV (A8) so the play-head re-render stops competing with decode
                                // and the embedded server for its weak main thread, which is what froze
                                // the remote during torrent playback there. Capable devices are unaffected.
                                let minInterval = PerformanceMode.reduced ? 0.5 : 0.25
                                if now - self.lastTimePosEmit >= minInterval {
                                    self.lastTimePosEmit = now
                                    if self.ownsSharedProbeState { VXProbeState.shared.setPlayer(pos: Int(value)) }
                                    if let loadToken = self.callbackLoadToken(requiresLoadedFile: true) {
                                        self.emit(
                                            propertyName,
                                            PlayerTimePositionEvent(seconds: value, loadToken: loadToken),
                                            loadToken: loadToken
                                        )
                                        DispatchQueue.main.async { [weak self] in
                                            guard let self,
                                                  PlayerLoadProvenanceState.accepts(
                                                    callbackToken: loadToken,
                                                    activeToken: self.activeLoadToken
                                                  ) else { return }
                                            #if canImport(UIKit)
                                            self.completeCacheFlushFlightRecovery(
                                                owner: loadToken,
                                                observedPosition: value
                                            )
                                            #endif
                                            self.seekEOFRecovery.observePosition(
                                                owner: loadToken, position: value
                                            )
                                            self.completeSeekEOFRecovery(
                                                loadToken: loadToken, position: value
                                            )
                                        }
                                    }
                                }
                            }
                        case MPVProperty.pause:
                            let paused = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee ?? false
                            let callbackToken = self.callbackLoadToken(requiresLoadedFile: true)
                            if self.ownsSharedProbeState {
                                // A10-ii: always name the engine alongside the state so an mpv pause can never
                                // publish state=playing/paused with engine=- (a stale/blank lane in the heartbeat).
                                VXProbeState.shared.setPlayer(state: paused ? "paused" : "playing", engine: "mpv")
                            }
                            VXProbe.log(self.probeChannel, paused ? "paused" : "playing")
                            self.emit(propertyName, paused)
                            #if canImport(UIKit)
                            // Jetsam relief: arm/release the paused-cache clamp (main thread; this drain
                            // runs on the mpv event queue).
                            DispatchQueue.main.async { [weak self] in
                                guard let self, let callbackToken,
                                      PlayerLoadProvenanceState.accepts(
                                        callbackToken: callbackToken, activeToken: self.activeLoadToken
                                      ),
                                      self.getFlag(MPVProperty.pause) == paused else { return }
                                self.pausedStateChanged(paused)
                            }
                            #endif
                        case MPVProperty.trackList:
                            self.emit(propertyName, nil)
                        default: break
                        }
                    }
                case MPV_EVENT_SEEK:
                    #if canImport(UIKit)
                    guard let loadToken = self.callbackLoadToken(requiresLoadedFile: true) else { break }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.mpv != nil,
                              PlayerLoadProvenanceState.accepts(
                                callbackToken: loadToken, activeToken: self.activeLoadToken
                              ) else { return }
                        self.observeCacheReanchorSeek(owner: loadToken)
                        _ = self.seekEOFRecovery.observeSeek(owner: loadToken)
                    }
                    #else
                    break
                    #endif
                case MPV_EVENT_PLAYBACK_RESTART:
                    #if canImport(UIKit)
                    guard let loadToken = self.callbackLoadToken(requiresLoadedFile: true) else { break }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.mpv != nil,
                              PlayerLoadProvenanceState.accepts(
                                callbackToken: loadToken, activeToken: self.activeLoadToken
                              ) else { return }
                        self.completeCacheReanchorOnPlaybackRestart(owner: loadToken)
                    }
                    #else
                    break
                    #endif
                case MPV_EVENT_START_FILE:
                    if let data = event!.pointee.data {
                        let start = UnsafePointer<mpv_event_start_file>(OpaquePointer(data)).pointee
                        self.bindStartFile(entryID: start.playlist_entry_id)
                    }
                case MPV_EVENT_FILE_LOADED:
                    self.markActiveFileLoaded()
                    guard let loadedToken = self.callbackLoadToken(requiresLoadedFile: true) else { break }
                    // The file opened and its tracks/params are known. Push a compact source label (the
                    // current path's host, redacted of any token-bearing query) into the probe state so the
                    // heartbeat names what is playing, and mark the engine as mpv + state playing.
                    let loadedHost = self.getString("path").flatMap { URL(string: $0)?.host }
                        ?? self.playUrl?.host ?? "?"
                    if self.ownsSharedProbeState {
                        VXProbeState.shared.setPlayer(state: "playing", source: loadedHost, engine: "mpv")
                    }
                    VXProbe.event(self.probeChannel, "loaded \(loadedHost)")
                    self.probeEnhancementLayer()
                    #if os(tvOS)
                    DispatchQueue.main.async { [weak self] in
                        self?.framePresentationFileLoaded(loadToken: loadedToken)
                    }
                    #endif
                    DispatchQueue.main.async { [weak self] in
                        self?.beginSeekEOFRecoveryReloadSeek(loadToken: loadedToken)
                    }
                    // One-shot audio-negotiation diagnostic: what mpv DECODED vs what the AO actually OPENED
                    // (the negotiated output layout, e.g. 5.1 vs a silent stereo downmix). A6: skip it for a
                    // muted decorative clip or a trailer probe (neither opens a real AO, so it only sampled the
                    // "?@?" noise), and for the real player poll until the AO is actually open instead of a
                    // blind fixed 2.0s read that raced ahead of it.
                    if !self.startMuted, self.probeChannel.description != "trailer" {
                        self.pollNegotiatedAudio(loadToken: loadedToken, attemptsRemaining: 10)
                    }
                case MPV_EVENT_VIDEO_RECONFIG:
                    // The video output was (re)configured for the now-current file/params. This EVENT is
                    // not value-coalesced like the sig-peak property observer, so it fires reliably on
                    // every in-place episode switch even when two HDR episodes share a mastering peak,
                    // exactly the case that left ~2 of 3 switches dull. Re-derive + re-apply HDR from the
                    // freshly settled params (the nil sentinel set in loadFile guarantees it isn't swallowed).
                    guard let loadToken = self.callbackLoadToken() else { break }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.mpv != nil,
                              PlayerLoadProvenanceState.accepts(
                                callbackToken: loadToken, activeToken: self.activeLoadToken
                              ) else { return }
                        self.reapplyDynamicRange()
                        self.updateCapturePipeline()
                    }
                case MPV_EVENT_END_FILE:
                    // A file finished, if it ENDED IN ERROR (couldn't open: dead/uncached link,
                    // refused, unsupported, timed out), surface it so the UI can stop "buffering
                    // forever" and let the user pick another source.
                    if let data = event!.pointee.data {
                        let ef = UnsafePointer<mpv_event_end_file>(OpaquePointer(data)).pointee
                        if ef.reason == MPV_END_FILE_REASON_REDIRECT {
                            self.propagateRedirect(ef)
                            break
                        }
                        guard let loadToken = self.loadToken(forEntryID: ef.playlist_entry_id) else { break }
                        if ef.reason == MPV_END_FILE_REASON_ERROR {
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.mpv != nil,
                                      PlayerLoadProvenanceState.accepts(
                                        callbackToken: loadToken,
                                        activeToken: self.activeLoadToken
                                      ) else { return }
                                self.finishCacheFlushFlight(self.cacheFlushFlight.reset(owner: loadToken))
                            }
                        }
                        if ef.reason == MPV_END_FILE_REASON_ERROR {
                            #if os(tvOS)
                            DispatchQueue.main.async { [weak self] in
                                guard let self,
                                      let generation = self.framePresentationDiagnostics.currentGeneration()
                                else { return }
                                self.scheduleFramePresentationTerminalCleanup(
                                    generation: generation, loadToken: loadToken)
                            }
                            #endif
                            let msg = String(cString: mpv_error_string(ef.error))
                            self.mpvLog.error("end-file error: \(msg, privacy: .public)")
                            VXProbe.event(self.probeChannel, "endfile error \(msg)")
                            self.emit(MPVProperty.endFileError, msg, loadToken: loadToken)
                        } else if ef.reason == MPV_END_FILE_REASON_EOF {
                            DispatchQueue.main.async { [weak self] in
                                self?.handleEndFileEOF(loadToken: loadToken)
                            }
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
                case MPV_EVENT_GET_PROPERTY_REPLY:
                    // wakeVideoOutputThread reads a property purely to hand work to the
                    // video-output thread. The reply carries nothing anyone wants; swallow it here
                    // so a rotation does not print a puzzling event line in debug builds.
                    break
                default:
                    #if DEBUG
                    let eventName = mpv_event_name(event!.pointee.event_id)
                    print("event: \(String(cString: eventName!))")
                    #endif
                    break
                }
                
            }
        }
    }
    
    
    /// A6: sample the negotiated audio (decoded layout vs the layout the AO actually opened) once the AO is
    /// really open. Poll every 0.5s up to `attemptsRemaining` times (~5s) until `current-ao` is non-nil, then
    /// log once. A genuine no-AO player still logs after the cap with ao="?" (the #78 signal that no audio
    /// output ever opened). Bounded and provenance-gated, so a superseded load stops sampling.
    private func pollNegotiatedAudio(loadToken: PlayerLoadToken, attemptsRemaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.mpv != nil,
                  PlayerLoadProvenanceState.accepts(
                    callbackToken: loadToken, activeToken: self.activeLoadToken
                  ) else { return }
            let ao = self.getString("current-ao")
            if ao == nil, attemptsRemaining > 1 {
                self.pollNegotiatedAudio(loadToken: loadToken, attemptsRemaining: attemptsRemaining - 1)
                return
            }
            let dec = "\(self.getString("audio-params/hr-channels") ?? self.getString("audio-params/channel-count") ?? "?")@\(self.getString("audio-params/samplerate") ?? "?")"
            let out = "\(self.getString("audio-out-params/hr-channels") ?? self.getString("audio-out-params/channel-count") ?? "?")@\(self.getString("audio-out-params/samplerate") ?? "?")"
            let aoName = ao ?? "?"
            NSLog("%@", "[#78 audio] negotiated decode=\(dec) out=\(out) ao=\(aoName)")
            VXProbe.log(self.probeChannel, "audio negotiated decode=\(dec) out=\(out) ao=\(aoName)")
        }
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            mpvLog.error("MPV API error: \(String(cString: mpv_error_string(status)), privacy: .public)")
        }
    }

}
