#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import AVKit
import AVFoundation
import Combine
import CoreMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Current-item remux intent published to startup watchdogs. `pendingGeneration` is stamped only after the
/// matching `loadFile` has decided to enter a remux lane, so intent from a retired item cannot extend a newer
/// direct load. Mounted state is already current-item-owned by synchronous teardown and guarded async attach.
struct AVPlayerRemuxStartupSignal: Equatable {
    let itemGeneration: UInt64
    let pendingGeneration: UInt64?
    let mounted: Bool

    var pendingOrMounted: Bool {
        mounted || pendingGeneration == itemGeneration
    }
}

// MARK: - PiP state machine (dependency-free)

enum AVPlayerPictureInPictureCommand: Equatable, Sendable {
    case start(UInt64)
    case stop(UInt64)
}

/// PiP is bound to the AVPlayerLayer, not to one AVPlayerItem. Replacing an episode or source on the same
/// layer therefore keeps the controller generation alive. Only an engine stop or an actual layer-identity
/// change retires it. Active/transitioning PiP also keeps the old item mounted until the prepared replacement
/// is attached, avoiding a transient nil currentItem that can make AVKit tear down the floating session.
enum AVPlayerPictureInPictureOwnershipEvent: Equatable, Sendable {
    case itemReplacement(isActive: Bool, isTransitioning: Bool)
    case engineStop
    case layerReplacement

    var invalidatesController: Bool {
        switch self {
        case .itemReplacement: false
        case .engineStop, .layerReplacement: true
        }
    }

    var clearsCurrentItemBeforeAttach: Bool {
        switch self {
        case let .itemReplacement(isActive, isTransitioning):
            !isActive && !isTransitioning
        case .engineStop, .layerReplacement:
            true
        }
    }
}

/// Main-actor AVKit callbacks are asynchronous and can arrive after a replacement has retired the controller
/// that emitted them. This small state machine owns the request latch and generation fence independently of
/// AVKit, so unsupported devices, failed starts, repeated taps, and old callbacks all fail closed.
struct AVPlayerPictureInPictureState: Equatable, Sendable {
    enum Transition: Equatable, Sendable {
        case starting
        case stopping
    }

    private(set) var generation: UInt64 = 0
    private(set) var isSupported = false
    private(set) var isPossible = false
    private(set) var isActive = false
    private(set) var transition: Transition?

    var isAvailable: Bool { isSupported && isPossible }
    var isTransitioning: Bool { transition != nil }

    @discardableResult
    mutating func attach(supported: Bool, possible: Bool, active: Bool) -> UInt64 {
        generation &+= 1
        isSupported = supported
        isPossible = supported && possible
        isActive = supported && active
        transition = nil
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
        isSupported = false
        isPossible = false
        isActive = false
        transition = nil
    }

    mutating func requestStart() -> AVPlayerPictureInPictureCommand? {
        guard isAvailable, !isActive, transition == nil else { return nil }
        transition = .starting
        return .start(generation)
    }

    mutating func requestStop() -> AVPlayerPictureInPictureCommand? {
        guard isSupported, isActive, transition == nil else { return nil }
        transition = .stopping
        return .stop(generation)
    }

    @discardableResult
    mutating func willStart(generation callbackGeneration: UInt64) -> Bool {
        // The delegate callback is AVKit's authoritative start decision; a possible-state KVO update may still
        // be queued behind it, so do not reject an otherwise current automatic inline start on stale `isPossible`.
        guard isCurrent(callbackGeneration), !isActive, transition != .stopping else { return false }
        transition = .starting
        return true
    }

    @discardableResult
    mutating func willStop(generation callbackGeneration: UInt64) -> Bool {
        guard isCurrent(callbackGeneration), isSupported, transition != .starting else { return false }
        transition = .stopping
        return true
    }

    /// Observe state from the current AVPictureInPictureController without settling a transition. AVKit can
    /// transiently report `isPictureInPicturePossible == false` while a start or stop is still in flight, so
    /// only the matching-generation delegate callbacks below may settle those transitions.
    @discardableResult
    mutating func observe(possible: Bool, active: Bool, generation callbackGeneration: UInt64) -> Bool {
        guard isCurrent(callbackGeneration) else { return false }
        isPossible = possible
        isActive = active
        return true
    }

    @discardableResult
    mutating func didStart(
        possible: Bool,
        active: Bool,
        generation callbackGeneration: UInt64
    ) -> Bool {
        guard isCurrent(callbackGeneration) else { return false }
        isPossible = possible
        isActive = active
        transition = nil
        return true
    }

    @discardableResult
    mutating func didStop(
        possible: Bool,
        active: Bool,
        generation callbackGeneration: UInt64
    ) -> Bool {
        guard isCurrent(callbackGeneration) else { return false }
        isPossible = possible
        isActive = active
        transition = nil
        return true
    }

    @discardableResult
    mutating func failStart(generation callbackGeneration: UInt64) -> Bool {
        guard isCurrent(callbackGeneration) else { return false }
        isActive = false
        transition = nil
        return true
    }

    private func isCurrent(_ callbackGeneration: UInt64) -> Bool {
        isSupported && generation == callbackGeneration
    }
}

// MARK: - Stall telemetry episode (dependency-free)

/// One logical AVPlayer stall can span many `timeControlStatus` KVO callbacks: the wait reason changes
/// mid-wait (buffering-rate -> minimize-stalls), and the transport can flip to `.paused` and back while the
/// media clock never moves. Deriving `stall start`/`stall end` straight off `timeControlStatus == .waitingToPlayAtSpecifiedRate`
/// therefore emits a duplicate start on every reason change and a false end on pause, which was making the
/// recovery telemetry lie (root-cause report section 2). This owns ONE episode per item/load-generation: a
/// start fires only on the genuine idle -> waiting edge, a reason change updates the episode without a second
/// start, and the episode ends only once the media clock has proven forward progress, never off `.paused` or
/// `.playing` alone.
struct AVPlayerStallEpisodeState: Equatable {
    enum Event: Equatable {
        case none
        case started(AVPlayer.WaitingReason?)
        case reasonChanged(AVPlayer.WaitingReason?)
        case ended
    }

    /// Media/displayed time must advance at least this much past the episode's baseline before it counts as
    /// proven progress rather than clock jitter.
    static let minimumProgressSeconds: Double = 0.10

    private(set) var active = false
    private(set) var reason: AVPlayer.WaitingReason?
    private(set) var baselinePosition: Double?

    mutating func enteredWaiting(reason: AVPlayer.WaitingReason?, position: Double) -> Event {
        if !active {
            active = true
            self.reason = reason
            baselinePosition = position
            return .started(reason)
        }
        if self.reason != reason {
            self.reason = reason
            return .reasonChanged(reason)
        }
        return .none
    }

    mutating func mediaAdvanced(to position: Double) -> Event {
        guard active, let baselinePosition,
              position.isFinite, position - baselinePosition >= Self.minimumProgressSeconds else {
            return .none
        }
        self = .init()
        return .ended
    }

    /// Item/load-generation replacement: retire the episode WITHOUT emitting `stall end`. The retired item's
    /// own telemetry stream is already closed by whatever terminal event (ready/failed/endfile) ended it.
    mutating func reset() {
        self = .init()
    }
}

// MARK: - AVPlayer engine

/// AVFoundation implementation of `PlayerEngine`. It drives one `AVPlayer` and maps its KVO + a periodic
/// time observer onto the SAME `MPVProperty` event keys the chrome already listens for, so the full
/// PlayerScreen chrome can drive AVPlayer exactly as it drives the libmpv controller (the chrome holds the
/// engine as `coordinator.player`, an `any PlayerEngine`). This is the engine VortX routes Dolby Vision and
/// HTTP/HLS streams to: libmpv/MoltenVK cannot do true DV passthrough (it tone-maps to SDR), while
/// AVPlayerLayer is DV/EDR native.
///
/// iOS + macOS + tvOS (#46, #76): all three route Dolby Vision / HLS here under the full player chrome via
/// `PlayerEngineRouter`, with a fail-soft fallback to libmpv if the AVPlayer item fails to load. tvOS now hosts
/// this same engine under the existing `TVPlayerView` chrome (the control bar, scrubber, options panels, and
/// failover are plain SwiftUI over the video surface, driven only through `coordinator.player` and the
/// `MPVProperty` event bus, so they render over an `AVPlayerLayer` exactly as over libmpv). Remote input still
/// goes through `TVPlayerView`'s UIKit `RemoteCatcher`, so no focusable SwiftUI overlay competes with the
/// Siri-remote focus engine.
///
/// This conforms to `PlayerEngine` and emits events; rendering is owned by a sibling AVPlayerLayer host that
/// calls `attachLayer`, while this object owns playback + state only. Embedded track selection (audio +
/// subtitles via `AVMediaSelectionGroup`), `mediaSummary`, and `playbackStats` are real; chapters load from
/// asset metadata when present. External add-on / community subtitles ARE real here: AVFoundation cannot
/// side-load an SRT, so VortX downloads + parses the file and draws the cues over the AVPlayerLayer itself
/// (`subtitleOverlay`), with `setSubDelay` as a live offset and `applySubtitleStyle` styling that overlay.
/// Trickplay frame capture is real too (`AVPlayerItemVideoOutput`, tone-mapped to SDR). The genuine no-ops
/// are the controls with no AVFoundation equivalent: audio delay (`setAudioDelay`), audio output mode
/// (`setAudioOutputMode`, the system negotiates routing), and the hardware-decoding toggle
/// (`setHardwareDecoding`, always hardware); the chrome hides those rows when this engine is active. iOS HLS
/// now flows through this same full-chrome engine (Gap 1), so the bare `HLSPlayerView` path is no longer mounted.
@MainActor
final class AVPlayerEngineController: NSObject, ObservableObject, PlayerEngine {
    let player = AVPlayer()
    /// The chrome's Coordinator. Property changes are pushed here with the same string keys the libmpv
    /// controller emits, so `handleProperty()` runs unchanged against either engine.
    weak var playDelegate: MPVPlayerDelegate?

    private var item: AVPlayerItem?
    /// Monotonic exact-item ownership. Logical retries may intentionally reuse a load token, so queued
    /// delivery must also prove that the AVPlayerItem generation that emitted the event is still mounted.
    private var itemGeneration: UInt64 = 0
    private(set) var activeLoadToken: PlayerLoadToken?
    /// Newest-wins ownership for asynchronous local-HLS seeks. A later scrub/D-pad input invalidates every
    /// older task and completion callback, even when they target the same AVPlayerItem generation.
    private var seekRequestGeneration: UInt64 = 0
    private var preparedSeekTask: Task<Void, Never>?
    private weak var registeredSeekServer: VortXRemuxHLSServer?
    private var registeredSeekRequestID: UInt64?
    #if os(tvOS)
    /// Current native-DV preflight. A new load/stop cancels it, and its completion must also match both the
    /// logical load token and exact item generation before it may switch the display or attach anything.
    private var nativePreAttachTask: Task<Void, Never>?
    /// The exact object loaded from `AVAsset.preferredDisplayCriteria`. Ready-to-play may reapply this same
    /// Apple-owned object if the window's display manager was replaced; it never constructs a second criterion.
    private var nativeDisplayCriteria: AVDisplayCriteria?
    #endif
    private var isReady = false
    private var didStart = false
    /// One fatal `endFileError` per loaded item. The item's `.failed` KVO and the failed-to-play-to-end
    /// notification can BOTH fire for one failure; a duplicate event lands after the chrome has already
    /// demoted to libmpv and used to punch through into its retry/error path (the DV "error screen").
    private var fatalErrorEmitted = false
    /// EOF and error share one exact-item terminal edge. Unlike `fatalErrorEmitted`, this also suppresses a
    /// later failure after EOF and resets only when `itemGeneration` advances.
    private var terminalLatch = VortXPlaybackTerminalLatch()
    /// One-shot per mount for an explicit HDR-only recovery item. The initial DV item has exactly one video
    /// variant, so AVPlayer cannot jump into a stripped-DV representation inside the same adaptive set. An exact
    /// CoreMedia -12927 rejection on a healthy, base-layer-compatible mount gets one fresh item at
    /// `/master-hdr.m3u8`; a second failure demotes normally.
    private var hdrFallbackRetried = false
    /// True only while the current item is the explicit HDR-only recovery item.
    private var usingHDRFallbackItem = false
    /// One identity for each source/remux mount. HDR recovery advances the item generation while deliberately
    /// keeping this identity; a source-audio remount or hosted-to-local recovery advances both.
    private var playbackMountIdentity: UInt64 = 0
    /// The only remount-spanning snapshot. Audio replacement, HDR recovery and host loss update and rebind this
    /// same value, and `loadSelectionGroups` is the one restore/consume point.
    private var pendingPlaybackIntent: PlaybackIntentPolicy.Intent?
    /// A hosted status poll may lag the init-surgery publication that makes HDR recovery possible. Exactly one
    /// bounded refresh owns that uncertainty for the current failed item; duplicate KVO and notification
    /// callbacks observe this task and wait for its single retry or fatal completion.
    private var hdrFallbackCapabilityRefreshTask: Task<Void, Never>?
    /// #147 reactive net, one-shot: a RAW (non-remux) mount that failed container-unsupported ("Cannot Open" -
    /// AVFoundation has no Matroska demuxer) gets ONE retry through the PLAIN remux lane before the libmpv
    /// demote (which would lose Picture in Picture). Loop-safe even though loadFile resets it: the retry
    /// mounts the remux, and the retry gate refuses any remux-mounted failure (`!isRemuxMounted`), so a failed
    /// retry demotes normally.
    private var plainRemuxRetried = false
    /// Forces the next loadFile onto the PLAIN remux lane (#147), bypassing the router's explicit-Matroska
    /// candidacy (the reactive retry has already proven raw AVPlayer cannot demux the bytes). Consumed (reset
    /// to false) inside loadFile; set only by the container-unsupported retry in handleStatus.
    private var forcePlainRemux = false
    // AUDIO-OVER-BLACK watchdog state (#76 residual, native DV lane only; see checkAudioOverBlackWatchdog).
    // `videoFrameEverProduced` latches TRUE on the first observed video frame and permanently disarms the
    // watchdog for this item, so it can never fire on a session that ever showed a picture. `audioOverBlackSince`
    // anchors the sustained no-picture window (0 = not currently counting); `audioOverBlackFired` makes the
    // demote one-shot per item, alongside the fatalErrorEmitted latch it shares with the other fatal paths.
    private var videoFrameEverProduced = false
    /// Exact origin for the current item's forward-buffer and stall-wait policy.
    private var forwardBufferMount: VortXRemuxForwardBufferPolicy.Mount {
        if remuxRemoteMount != nil { return .remoteRemux }
        if remuxHLSServer != nil || remuxLoader != nil { return .localRemux }
        return .direct
    }
    /// Render proof for the chrome's first-frame commit. AVPlayer can hold its clock at exactly zero while its
    /// layer already displays the first decoded frame, so a positive time position cannot be the sole owner of
    /// timer cancellation or episode-identity publication.
    var hasProducedPlayableVideoFrame: Bool {
        let seconds = item?.currentTime().seconds ?? 0
        return latchPlayableVideoFrame(atClock: seconds.isFinite ? seconds : 0)
    }

    private func latchPlayableVideoFrame(atClock seconds: Double) -> Bool {
        if videoFrameEverProduced { return true }
        guard hasProducedPicture(atClock: seconds) else { return false }
        videoFrameEverProduced = true
        if isRemuxMounted {
            let steadyDuration = VortXRemuxForwardBufferPolicy.preferredDuration(
                mount: forwardBufferMount,
                hasProducedFirstFrame: true)
            if item?.preferredForwardBufferDuration != steadyDuration {
                item?.preferredForwardBufferDuration = steadyDuration
            }
        }
        if let server = remuxHLSServer {
            DiagnosticsLog.log(
                "dv",
                "startup phase=first-video-frame elapsedMs=\(server.startupElapsedMilliseconds) "
                    + "forwardBufferSeconds=\(Int(VortXRemuxForwardBufferPolicy.steadyStateSeconds))")
        } else if remuxRemoteMount != nil {
            DiagnosticsLog.log(
                "engine",
                "startup phase=first-video-frame forwardBufferSeconds="
                    + "\(Int(VortXRemuxForwardBufferPolicy.steadyStateSeconds))")
        }
        return true
    }
    /// Pin the one-variant DV item only after AVFoundation has produced a real picture. This avoids a
    /// pre-decode hint changing route selection while preventing any later throughput heuristic from moving
    /// away from the proven variant.
    private var preferredPeakBitRatePinned = false
    private var audioOverBlackSince: TimeInterval = 0
    private var audioOverBlackFired = false
    /// Progress-proven AVPlayer stall episode for the CURRENT item (root-cause report section 2). Advanced by
    /// the `timeControlStatus` KVO (start on the idle -> waiting edge, reason changes update it silently) and
    /// by the periodic time observer (end, only once the media clock proves forward progress). Reset alongside
    /// the other item-scoped latches in `loadFile`.
    private var stallEpisode = AVPlayerStallEpisodeState()
    /// Sustained window of advancing playback clock with ZERO video frames before demoting. Long enough to
    /// clear a slow first-frame on a healthy native DV start (normally sub-second once timePos ticks), short
    /// enough that black-with-Atmos flips to a working picture on libmpv in well under ten seconds.
    private let audioOverBlackWindowSeconds: TimeInterval = 8
    private var pendingSeek: Double?
    private var requestedRate: Float = 1
    /// User transport intent, independent of AVPlayer's transient status during item failure and replacement.
    /// A recovery item must not turn a deliberate pause into autoplay.
    private var playbackRequested = true
    private var timeObserver: Any?
    /// SECOND periodic observer, delivered OFF the main queue, whose only job is the DV/remux playhead receipt.
    /// The receipt is the single input that lets the local HLS server slide its published window and reclaim
    /// spool bytes; while it is missing the window PINS and the remux producer parks on the spool ceiling
    /// (VortXRemuxHLSServer.swift:1206-1209), which drains AVPlayer's buffer and stalls playback. Delivering it
    /// on .main made any main-actor stall (a settings-sync burst, a heavy SwiftUI re-render) able to cause that,
    /// so it now rides a dedicated serial queue and is immune to main-thread pressure. Torn down in lockstep
    /// with `timeObserver`.
    private var playheadObserver: Any?
    private let playheadQueue = DispatchQueue(label: "vortx.dvremux.playhead")
    /// Throttle marks for the two EXPENSIVE per-tick side effects, mirroring the libmpv path
    /// (MPVMetalViewController.swift lastTimePosEmit / lastCacheTimeEmit). The periodic observer still
    /// fires at 0.25s, but the probe write (NSLock) and the loadedTimeRanges scan are gated behind the same
    /// PerformanceMode-scaled interval so a constrained device gets the same relief the libmpv path already has.
    /// Confined to the main actor (only read/written inside the observer's MainActor.assumeIsolated block).
    private var lastProbeEmit: TimeInterval = 0
    private var lastCacheEmit: TimeInterval = 0
    /// Local stream truth can change after the initial AVMediaSelection load, while remote truth arrives through
    /// the host's status poll. This wall-clock task keeps propagation bounded even while playback is paused.
    private static let remuxSubtitleInventoryRefreshInterval: Duration = .milliseconds(500)
    private var remuxSubtitleInventoryRefreshTask: Task<Void, Never>?
    private var observations: [NSKeyValueObservation] = []
    private var pipController: AVPictureInPictureController?
    private var pipObservations: [NSKeyValueObservation] = []
    private var pipState = AVPlayerPictureInPictureState()
    /// Published from the current AVPictureInPictureController only. The PlayerScreen child view observes the
    /// engine so the button appears/disappears and changes glyph after AVKit settles, including a failed start.
    @Published private(set) var isPictureInPicturePossible = false
    @Published private(set) var isPictureInPictureActive = false
    @Published private(set) var pictureInPictureTransition: AVPlayerPictureInPictureState.Transition? = nil
    var isPictureInPictureTransitioning: Bool { pictureInPictureTransition != nil }
    private weak var playerLayer: AVPlayerLayer?
    /// On-demand video frame tap for trickplay (community scrub previews). Pull-model: AVFoundation only
    /// converts a frame when copyPixelBuffer is called (~every 10s), so it adds no steady-state cost. The MPV
    /// engine captures via a Metal blit; AVPlayer previously had NO capture path (captureFrameJPEGData was a
    /// nil stub), so AVPlayer-routed titles (Dolby Vision / HLS on Auto) generated zero trickplay frames.
    /// Requesting BGRA output makes the system tone-map HDR / Dolby Vision frames to SDR, so the JPEG is usable.
    private var videoOutput: AVPlayerItemVideoOutput?
    private lazy var captureContext = CIContext(options: nil)
    private(set) var videoSizeMode = UserDefaults.standard.string(forKey: "stremiox.videoSize") ?? "original"
    // Cached AVMediaSelection groups + their MPVTrack views (loaded async once the item is ready). The
    // MPVTrack.id is the option's index in the group; mpv's -1 = off (deselect the group).
    private var audioGroup: AVMediaSelectionGroup?
    private var subGroup: AVMediaSelectionGroup?
    private var audioTracks: [MPVTrack] = []
    private var subTracks: [MPVTrack] = []
    /// Source-container audio identities published by the active remux. Unlike AVMediaSelection options these
    /// IDs survive replacement mounts and include every deliverable track without spawning parallel muxers.
    private var remuxSourceAudioTracks: [VortXEngineProtocol.AudioTrack] = []
    private var selectedRemuxAudioSourceIndex: Int?
    /// Main-actor snapshot taken once for a fresh logical load and retained across same-token fallbacks or
    /// explicit source remounts. Optional storage distinguishes startup before any load from an explicit
    /// current-client empty preference chain.
    private var remuxPreferredAudioLanguages: [String]?
    private var remuxAudioRejectTerms: [String]?
    /// Stable source subtitle identities. Text rows map to HLS rendition indices; bitmap rows stay visible
    /// with an unavailable reason instead of silently disappearing.
    private var remuxSourceSubtitleTracks: [VortXEngineProtocol.SubtitleTrack] = []
    /// One fresh load may explicitly retain a selected source identity, used when a hosted mount fails over to
    /// the device. The boolean distinguishes "not configured" from a deliberate nil reset.
    private var configuredAudioSourceIndex: Int?
    private var hasConfiguredAudioSourceIndex = false
    /// Generation-owned replacement transaction for a source-audio change. It keeps the previous working
    /// source as a one-shot rollback and remains writable while no AVPlayerItem is mounted.
    private var audioReplacement: RemuxAudioReplacementPolicy.State?
    private var selectionRefreshState = DVPlaybackPolicy.SelectionRefreshState()
    /// Track-list is one atomic topology publication. AVFoundation selection notifications and synchronous
    /// chapter discovery can both arrive while the audible and legible group loads are still suspended.
    /// Publishing either path early lets the chrome consume its one-shot automatic selection on audio-only
    /// rows. The generation becomes publishable only after both group loads and intent restoration finish.
    private var selectionTopologyGeneration: UInt64?
    // External-subtitle rendering (add-on + community-pooled srt/vtt). AVFoundation has no API to side-load or
    // time-shift an external SRT, so VortX owns it: parse the file into cues and draw the active cue in
    // `subtitleOverlay` (a view above the AVPlayerLayer), synced to the player clock, with `setSubDelay` as an
    // offset. `externalSubActive` is true while an external overlay sub is showing; when it is, any AVPlayer-native
    // legible track is deselected to avoid double subtitles.
    private let subtitleRenderer = SubtitleCueRenderer()
    private weak var subtitleOverlay: SubtitleOverlayView?
    private var externalSubActive = false
    /// Label of the loaded external overlay subtitle, so it can be published as a REAL row of `tracks(ofType:
    /// "sub")` instead of being invisible to the chrome. Build 191 field defect: on this engine an add-on /
    /// pooled subtitle rendered over the video while the picker showed "Off" ticked and the row the viewer
    /// tapped vanished from the add-on section (the chrome hides an added row because on libmpv the same
    /// subtitle re-appears in the ordinary track list - a promise this engine never kept). Non-nil exactly
    /// while `externalSubActive` is true, so a load / disable can never leave a phantom row behind.
    private var externalSubLabel: (title: String, lang: String)?
    // Asset chapter markers, loaded async once the item is ready (empty when the asset carries none).
    private var loadedChapters: [MPVChapter] = []
    // Container frame rate for the subtitle release fingerprint (Gap 8), loaded async at readyToPlay from the
    // video track's nominalFrameRate. 0 until resolved / for HLS (no AVAssetTrack objects); the fingerprint
    // tolerates 0 and rebuilds. Read synchronously by containerFrameRate(); the async load avoids the
    // deprecated synchronous AVAssetTrack.nominalFrameRate accessor.
    private var containerFPS: Double = 0
    // DV-for-MKV streaming remux (Phase 1). When non-nil, this session is playing an MKV that was remuxed
    // in-process to fragmented MP4 and served to AVPlayer over the `vortxremux://` scheme. Held for the whole
    // session so its resource-loader delegate + remux thread stay alive; torn down in stop()/loadFile().
    // LEGACY delivery: kept compiled as the rollback path behind VortXRemuxHLSServer.deliveryEnabled.
    private var remuxLoader: VortXRemuxResourceLoader?
    // DV-for-MKV streaming remux, LOCAL HLS delivery (b166, the default). The same remux stream, indexed
    // into init + media segments and served to AVPlayer as vanilla HLS from 127.0.0.1, which is the one
    // delivery AVFoundation supports for a growing fMP4 (the progressive loader path above never framed on
    // device). Held for the whole session; torn down in stop()/loadFile().
    private var remuxHLSServer: VortXRemuxHLSServer?
    private struct ConfiguredPreparedRemux {
        let handle: VortXPreparedRemuxHandle
        let ownerIdentity: VortXPreparedRemuxOwnerIdentity
    }
    /// One transport-only next load candidate. The caller must configure the exact owner immediately before
    /// issuing that load. `loadFile` consumes this slot even on rejection, so it cannot leak into a later title.
    private var configuredPreparedRemux: ConfiguredPreparedRemux?
    /// EXTERNAL ENGINE MODE: the same remux, produced on ANOTHER machine and mounted over the LAN.
    ///
    /// A separate optional rather than a protocol over the local server, deliberately. The local type is at the
    /// centre of a lane that took two field regressions to stabilise, and the engine already reads its mount
    /// through a two-lane `??` chain (`remuxHLSServer?.x ?? remuxLoader?.x`) for the legacy delivery. Extending
    /// that chain by one arm leaves every existing local expression untouched and makes default-off provably
    /// byte-identical: with external mode off this is always nil and every `??` short-circuits before reaching
    /// it. A protocol refactor would have touched the local path at ten sites to buy nothing a user can see.
    private var remuxRemoteMount: VortXRemoteRemuxMount?
    /// Generations owned by `remuxRemoteMount`. The opening generation identifies the asynchronous mount
    /// request; the item generation advances when the same mount receives its one HDR recovery item.
    private var remuxRemoteOpeningGeneration: UInt64?
    private var remuxRemoteItemGeneration: UInt64?
    /// One-shot: forces the NEXT loadFile to skip external engine mode and mount on-device. Consumed inside
    /// loadFile, exactly like `forceRemux` and `forcePlainRemux`. Set when a host refuses or dies, so the retry
    /// takes the ordinary local lane instead of asking the same dead host again.
    private var bypassExternalEngine = false
    /// The in-flight external mount preflight, cancelled by the next load exactly as `nativePreAttachTask` is.
    private var externalMountTask: Task<Void, Never>?
    /// A pending remote open can already have caused the host to construct a producer before its response
    /// reaches us. Its terminal relay is owned immediately and joins AV→MPV teardown just like an attached
    /// remote mount; cancellation alone is not a physical-release receipt.
    private var externalMountTerminalRelay: VortXRemuxProducerTerminalRelay?
    /// One-shot resume request configured by the chrome before `loadFile`. `currentLoadResumeOrigin` retains
    /// the request only for same-token internal remounts (plain-remux and hvc1 repair); a new logical load with
    /// no configuration resets it to zero. `remuxTimelineOrigin` is the achieved base-video timestamp reported
    /// by the mounted stream and is the sole offset used for source-clock/player-clock conversion.
    private var resumeConfiguration = RemuxResumeConfiguration()
    private var currentLoadResumeOrigin: Double = 0
    private var remuxTimelineOrigin: Double = 0
    /// A user seek outside the current forward-only item is fulfilled by opening a new remux at that source
    /// second. The target remains set until the replacement publishes and restores its playback intent, so a
    /// failed replacement still exposes the requested source position to the chrome's libmpv fallback.
    private var remuxSeekRemountTarget: Double?
    /// Whether the forward-only remux is mounted for the CURRENT item (either delivery). A mounted origin can
    /// begin part-way through the source, but later seeks remain bounded to the bytes produced from that point.
    var isRemuxMounted: Bool { remuxLoader != nil || remuxHLSServer != nil || remuxRemoteMount != nil }

    /// Authoritative startup state for the exact current item. The chrome re-reads this every watchdog poll so
    /// an engine-internal same-token retry can become pending after the surface initially routed direct.
    private var pendingRemuxGeneration: UInt64?
    var remuxStartupSignal: AVPlayerRemuxStartupSignal {
        AVPlayerRemuxStartupSignal(
            itemGeneration: itemGeneration,
            pendingGeneration: pendingRemuxGeneration,
            mounted: isRemuxMounted)
    }

    /// Progress counters for the mounted DV remux (either delivery), or nil when no remux is mounted. The
    /// chrome's PROGRESS-AWARE start watchdog polls this ~1 Hz to tell a slow-but-alive 4K source (counters
    /// still moving -> extend the start window) from a TRUE stall (nothing moved for the whole stall window
    /// -> demote to libmpv). Cheap: two lock hops per read, no allocation beyond the tiny struct.
    var remuxMountProgress: VortXMKVRemuxStream.MountProgress? {
        if let server = remuxHLSServer { return server.mountProgress }
        if let remote = remuxRemoteMount { return remote.mountProgress }
        if let loader = remuxLoader { return loader.mountProgress }
        return nil
    }

    /// One coherent player-clock window for a mounted remux. Local HLS reads both bounds from one server
    /// snapshot so a concurrent playlist slide cannot combine an evicted lower bound with a newer upper bound.
    /// Other deliveries retain their existing AVPlayer range fallback.
    private var mountedPlayerWindowBounds: (servedStart: Double?, producedEdge: Double) {
        // EXTERNAL ENGINE with full-timeline retention: AVPlayer's seekable range now advertises the WHOLE
        // timeline, which is exactly the point (it is what makes a backward seek an ordinary seek instead of a
        // demote), but it therefore can no longer stand in for the PRODUCED edge. The host reports that
        // separately and it is the only trustworthy forward bound here. Converted from source seconds to player
        // seconds through the achieved origin, which is the space this property is read in.
        if let remote = remuxRemoteMount, remote.retainsFullTimeline {
            return (
                avPlayerServedStartPlayerSeconds,
                max(0, remote.producedEdgeSeconds - remuxTimelineOrigin)
            )
        }
        if let localWindow = remuxHLSServer?.publishedPlayerWindowSeconds {
            return (localWindow.lowerBound, localWindow.upperBound)
        }
        guard let item else { return (nil, 0) }
        var start: Double?
        var edge = 0.0
        for value in item.seekableTimeRanges {
            let r = value.timeRangeValue
            let candidate = r.start.seconds
            if candidate.isFinite, candidate >= 0 {
                start = min(start ?? candidate, candidate)
            }
            let end = (r.start + r.duration).seconds
            if end.isFinite { edge = max(edge, end) }
        }
        if edge <= 0 {
            for value in item.loadedTimeRanges {
                let r = value.timeRangeValue
                let end = (r.start + r.duration).seconds
                if end.isFinite { edge = max(edge, end) }
            }
        }
        return (start, edge)
    }

    /// The furthest position the forward-only remux can serve. 0 means unknown and does not clamp.
    var producedEdgeSeconds: Double { mountedPlayerWindowBounds.producedEdge }

    /// Earliest AVPlayer seekable second, used only by a retaining remote mount whose produced edge is reported
    /// separately. Local HLS obtains both bounds atomically from `mountedPlayerWindowBounds`.
    private var avPlayerServedStartPlayerSeconds: Double? {
        guard let item else { return nil }
        var start: Double?
        for value in item.seekableTimeRanges {
            let candidate = value.timeRangeValue.start.seconds
            guard candidate.isFinite, candidate >= 0 else { continue }
            start = min(start ?? candidate, candidate)
        }
        return start
    }

    /// The launch site sets this from the stream's Dolby Vision flag BEFORE loadFile (same plumbing as the
    /// libmpv lane, MPVMetalViewController.contentIsDolbyVision). Used to request the Apple TV's Dolby Vision
    /// display mode BEFORE the AVPlayerItem is attached (Apple Tech Talk 503 ordering) for ALL DV routes:
    /// with only the remux-gated post-ready request, a native DV MP4/MOV/HLS routed here never switched the
    /// panel at all (a raw AVPlayerLayer gets no AVKit auto-switching).
    var contentIsDolbyVision = false
    // Last-load params, retained so the post-attach hev1/dvhe repair (#76) can re-mount the SAME source through
    // the remux lane. A native DV MP4/MOV with an hev1/dvhe sample entry reaches readyToPlay and renders black
    // over decoded audio (AVFoundation needs the hvc1/dvh1 out-of-band form); re-loading it with `forceRemux`
    // set routes it into the container-agnostic MKV->fMP4 remux, which rewrites the sample entry to hvc1/dvh1.
    private var lastLoadURL: URL?
    private var lastLoadHeaders: [String: String]?
    private var lastLoadLive = false
    /// Forces the next loadFile onto the remux lane regardless of the router's container gate (which rejects
    /// mp4/mov). Consumed (reset to false) inside loadFile; set only by the hev1/dvhe post-attach repair.
    private var forceRemux = false
    /// One-shot per load: guards the post-attach hev1/dvhe repair so a single incompatible sample entry triggers
    /// at most one remux re-mount (or one libmpv demote). Reset on every loadFile.
    private var incompatibleEntryHandled = false
    // Dedicated serial queue for the resource-loader delegate callbacks, so the blocking buffer reads never
    // run on the main thread.
    private let remuxLoaderQueue = DispatchQueue(label: "vortx.dvremux.delegate")

    // MARK: Loading + transport

    func invalidateLoadToken() {
        activeLoadToken = nil
    }

    /// Retire the prior asynchronous admission without creating a replacement. Pre-ready intent updates,
    /// capability-refresh deferrals, item replacement and teardown all pass through here, so none of them can
    /// leave a server playhead pinned behind an admission that AVPlayer will never receive.
    @discardableResult
    private func supersedeSeekRequest() -> UInt64 {
        preparedSeekTask?.cancel()
        preparedSeekTask = nil
        if let requestID = registeredSeekRequestID,
           let server = registeredSeekServer {
            server.cancelPreparedSeek(requestID: requestID)
        }
        registeredSeekServer = nil
        registeredSeekRequestID = nil
        seekRequestGeneration &+= 1
        return seekRequestGeneration
    }

    private func invalidateSeekRequests() {
        _ = supersedeSeekRequest()
    }

    private func registerSeekAdmission(
        requestID: UInt64,
        server: VortXRemuxHLSServer
    ) -> Bool {
        guard seekRequestGeneration == requestID else { return false }
        server.registerLatestSeekRequest(requestID: requestID)
        registeredSeekServer = server
        registeredSeekRequestID = requestID
        return true
    }

    private func cancelSeekAdmission(
        requestID: UInt64,
        server: VortXRemuxHLSServer
    ) {
        server.cancelPreparedSeek(requestID: requestID)
        guard registeredSeekRequestID == requestID,
              registeredSeekServer === server else { return }
        registeredSeekServer = nil
        registeredSeekRequestID = nil
    }

    private func completeSeekAdmission(
        requestID: UInt64,
        server: VortXRemuxHLSServer,
        playerSeconds: Double
    ) {
        server.completePreparedSeek(
            requestID: requestID,
            playerSeconds: playerSeconds
        )
        guard registeredSeekRequestID == requestID,
              registeredSeekServer === server else { return }
        registeredSeekServer = nil
        registeredSeekRequestID = nil
    }

    /// Store a sanitized origin for exactly the next logical `loadFile`. This must be called before the load:
    /// initial AVPlayer attachment happens synchronously in `AVPlayerEngineView.makeHostView`, before any
    /// SwiftUI `onAppear` callback can safely retrofit the mount.
    func configureResumeOrigin(seconds: Double) {
        resumeConfiguration.configure(seconds: seconds)
    }

    private func configureAudioSourceForNextLoad(_ sourceIndex: Int?) {
        configuredAudioSourceIndex = sourceIndex
        hasConfiguredAudioSourceIndex = true
    }

    /// Create a transport-only next-episode remux using the same initial audio preference snapshot a fresh
    /// `loadFile` uses. This creates no AVPlayerItem and no visual decoder.
    static func prepareRemuxTransport(
        input: URL,
        headers: [String: String]?,
        mode: VortXPreparedRemuxMode,
        startAtSeconds: Double = 0,
        ownerIdentity: VortXPreparedRemuxOwnerIdentity,
        selectedAudioStreamIndex: Int? = nil
    ) async -> VortXPreparedRemuxHandle? {
        guard VortXRemuxHLSServer.deliveryEnabled else { return nil }
        let preferences = TrackPreferences.current
        let normalized = VortXEngineProtocol.normalizedAudioSelectionPreferences(
            preferredLanguages: preferences.audioLanguages,
            rejectTerms: preferences.rejectTerms)
        return await VortXPreparedRemuxHandle.prepare(
            input: input,
            headers: headers,
            mode: mode,
            startAtSeconds: startAtSeconds,
            ownerIdentity: ownerIdentity,
            selectedAudioStreamIndex: selectedAudioStreamIndex,
            preferredAudioLanguages: normalized?.preferredLanguages,
            audioRejectTerms: normalized?.rejectTerms)
    }

    /// Arm exactly one prepared handle for the next load. A stale owner is rejected at configuration time;
    /// source, headers, mode, origin and audio inputs are checked again inside `loadFile`.
    @discardableResult
    func configurePreparedRemuxForNextLoad(
        _ handle: VortXPreparedRemuxHandle,
        ownerIdentity: VortXPreparedRemuxOwnerIdentity
    ) -> Bool {
        guard handle.identity.owner == ownerIdentity else {
            handle.abandon(reason: "owner-mismatch")
            return false
        }
        configuredPreparedRemux?.handle.abandon(reason: "superseded-before-load")
        configuredPreparedRemux = ConfiguredPreparedRemux(
            handle: handle,
            ownerIdentity: ownerIdentity)
        return true
    }

    func discardPreparedRemuxForNextLoad(reason: String = "caller-discarded") {
        configuredPreparedRemux?.handle.abandon(reason: reason)
        configuredPreparedRemux = nil
    }

    @discardableResult
    func loadFile(_ url: URL, headers: [String: String]?, live: Bool, audioSidecar: URL?,
                  reusing loadToken: PlayerLoadToken?) -> PlayerLoadToken {
        invalidateSeekRequests()
        let pictureInPictureReplacement = AVPlayerPictureInPictureOwnershipEvent.itemReplacement(
            isActive: pipState.isActive || pipController?.isPictureInPictureActive == true,
            isTransitioning: pipState.isTransitioning)
        let preparedCandidate = configuredPreparedRemux
        configuredPreparedRemux = nil
        let isIntentRemount = loadToken != nil && pendingPlaybackIntent != nil
        if loadToken == nil {
            let preferences = TrackPreferences.current
            if let normalized = VortXEngineProtocol.normalizedAudioSelectionPreferences(
                preferredLanguages: preferences.audioLanguages,
                rejectTerms: preferences.rejectTerms
            ) {
                remuxPreferredAudioLanguages = normalized.preferredLanguages
                remuxAudioRejectTerms = normalized.rejectTerms
            } else {
                remuxPreferredAudioLanguages = nil
                remuxAudioRejectTerms = nil
                DiagnosticsLog.log(
                    "avplayer",
                    "ignored oversized initial audio preferences")
            }
        }
        if hasConfiguredAudioSourceIndex {
            selectedRemuxAudioSourceIndex = configuredAudioSourceIndex
            configuredAudioSourceIndex = nil
            hasConfiguredAudioSourceIndex = false
        } else if loadToken == nil {
            selectedRemuxAudioSourceIndex = nil
            remuxSourceAudioTracks = []
            remuxSourceSubtitleTracks = []
            audioReplacement = nil
        }
        // Consume before ANY remux mount can be constructed. An internal same-token remount deliberately
        // reuses the logical request's origin; a fresh unrelated load with no configuration starts at zero.
        if let configured = resumeConfiguration.consumeForNextLoad() {
            currentLoadResumeOrigin = configured
        } else if loadToken == nil {
            currentLoadResumeOrigin = 0
        }
        let requestedRemuxOrigin = currentLoadResumeOrigin
        let issuedToken = loadToken ?? PlayerLoadToken()
        itemGeneration &+= 1
        terminalLatch.reset(generation: itemGeneration)
        playbackMountIdentity &+= 1
        let issuedGeneration = itemGeneration
        audioReplacement?.bind(to: issuedGeneration)
        pendingPlaybackIntent?.bind(
            generation: issuedGeneration,
            mountIdentity: playbackMountIdentity)
        // Invalidate first so callbacks from the retired item cannot publish during replacement setup.
        // The new logical request becomes active before any mount failure or observer can emit.
        invalidateLoadToken()
        activeLoadToken = issuedToken
        externalMountTask?.cancel()
        externalMountTask = nil
        hdrFallbackCapabilityRefreshTask?.cancel()
        hdrFallbackCapabilityRefreshTask = nil
        #if os(tvOS)
        nativePreAttachTask?.cancel()
        nativePreAttachTask = nil
        nativeDisplayCriteria = nil
        #endif
        teardownObservers()
        teardownRemux()
        remuxTimelineOrigin = 0
        // Native-DV criteria loading is asynchronous. Normally retire the old item now so it cannot keep
        // playing behind the new title's preflight. Active/transitioning PiP is the exception: its controller
        // owns this stable AVPlayerLayer, so keep a paused non-nil currentItem until attachPreparedItem performs
        // the direct replacement. This preserves AVKit's PiP session without weakening the guarded attach.
        player.pause()
        if pictureInPictureReplacement.clearsCurrentItemBeforeAttach {
            player.replaceCurrentItem(with: nil)
        }
        item = nil
        videoOutput = nil
        isReady = false; didStart = false; pendingSeek = nil; fatalErrorEmitted = false
        if !isIntentRemount { playbackRequested = true }
        hdrFallbackRetried = false; usingHDRFallbackItem = false
        if !isIntentRemount {
            pendingPlaybackIntent = nil
            remuxSeekRemountTarget = nil
        }
        incompatibleEntryHandled = false; plainRemuxRetried = false
        lastLoadURL = url; lastLoadHeaders = headers; lastLoadLive = live
        videoFrameEverProduced = false; preferredPeakBitRatePinned = false
        audioOverBlackSince = 0; audioOverBlackFired = false
        stallEpisode.reset()
        audioGroup = nil; subGroup = nil; audioTracks = []; subTracks = []; loadedChapters = []; containerFPS = 0
        selectionTopologyGeneration = nil
        selectionRefreshState.reset()
        // A source-audio remount is the same title and keeps the parsed external cues; a new title discards them.
        disableExternalSubtitle(discardingCues: !isIntentRemount)
        // Claim .playback before play so PiP and locked-screen audio work, and advertise multichannel so the
        // system passes through Atmos (#78) and applies AirPods Spatial Audio (#88). Idempotent with the
        // libmpv path since only one engine is live at a time. macOS has no AVAudioSession (the system routes
        // audio automatically), so this is iOS/tvOS only.
        #if os(iOS) || os(tvOS)
        AVPlayerAudioSession.activateForMovie()
        #endif
        #if os(iOS)
        // Keep the AVPlayer lane aligned with the existing user-facing background-playback preference. PiP and
        // inline playback remain AVKit-owned; this only tells AVPlayer what to do when the app backgrounds.
        player.audiovisualBackgroundPlaybackPolicy = PlaybackSettings.keepPlayingInBackground
            ? .continuesIfPossible : .pauses
        #endif
        // DV-for-MKV streaming remux path (Phase 1, opt-in): if the router flagged this URL for the in-process
        // MKV -> fMP4 remux, mount the remux instead of loading the MKV directly (AVFoundation has no Matroska
        // demuxer). DEFAULT delivery (b166) is LOCAL HLS: the remux output is indexed into init + media
        // segments and served from 127.0.0.1 as vanilla HLS, the one way AVFoundation consumes a growing fMP4
        // (and the lane Apple documents for Dolby Vision 8.1). The legacy `vortxremux://` progressive loader
        // stays compiled behind VortXRemuxHLSServer.deliveryEnabled for instant rollback. Everything below
        // (KVO, track selection, trickplay tap) is identical; only the asset's source differs.
        let newAsset: AVURLAsset
        // `forceRemux` (set by the hev1/dvhe post-attach repair) overrides the router's container gate, which
        // rejects mp4/mov: an AVPlayer-incompatible DV MP4 still routes into the container-agnostic remux lane.
        // Consumed here so it applies to exactly this load.
        // Gate the auto-remux on an actual Dolby Vision signal (#147): shouldDVRemux checks only container
        // candidacy + a DV-capable display, never DV itself, on the false assumption (its docstring) that
        // "only DV sources reach the AVPlayer remux lane under Auto". That holds under Auto, but the "Prefer
        // AVPlayer" override (PlayerEngineRouter rule 2) sends ANY non-torrent URL here, so a plain non-DV MKV
        // was mounted on the DV remux, failed fast (dvProfile=-1 -> HDR10 404), and demoted to libmpv, losing
        // Picture in Picture after a ~2s detour. `contentIsDolbyVision` is set from the same
        // StreamRanking.isDolbyVision signal the router routes on, BEFORE this loadFile (and re-set before a
        // source-switch loadFile), so a genuine DV source under Auto still remuxes; `forceRemux` still covers
        // the DV-only hev1/dvhe post-attach repair regardless of the flag.
        let dvRemuxEnabled = PlayerEngineRouter.dvRemuxEnabled(
            dvDisplayCapable: DVDisplaySupport.isCapable)
        let wantsDVRemux = dvRemuxEnabled
            && (forceRemux || (contentIsDolbyVision && PlayerEngineRouter.shouldDVRemux(url: url)))
        forceRemux = false
        // #147 (the remaining item): PLAIN (non-DV) remux lane. A NON-DV MKV can only reach this engine on
        // explicit AVPlayer intent (the "Prefer AVPlayer" override, the in-player engine pick, or the reactive
        // container-unsupported retry below - NEVER Auto, whose rule 5 keeps non-DV MKVs on libmpv untouched),
        // and AVFoundation has no Matroska demuxer, so the raw mount was a GUARANTEED "Cannot Open" ->
        // endFileError -> libmpv demote that lost Picture in Picture, the very thing the viewer chose AVPlayer
        // for. Route it through the SAME local remux machinery in `.plain` mode instead: a straight container
        // re-wrap (no DV/RPU handling, no panel switch, range-unlabeled single-variant HLS). HLS delivery
        // only: with the delivery lane rolled back (deliveryEnabled=false) this lane is fully OFF and the raw
        // path behaves exactly as before #147. Flag-gated via PlayerEngineRouter.plainRemuxEnabled
        // (UserDefaults stremiox.plainRemux > RemoteConfig features.plainRemux > baked ON).
        let wantsPlainRemux = !wantsDVRemux && !contentIsDolbyVision && VortXRemuxHLSServer.deliveryEnabled
            && PlayerEngineRouter.plainRemuxEnabled()
            && (forcePlainRemux || PlayerEngineRouter.shouldPlainRemux(url: url))
        forcePlainRemux = false
        let wantsRemux = wantsDVRemux || wantsPlainRemux
        pendingRemuxGeneration = wantsRemux ? issuedGeneration : nil
        let startupTimeout: @Sendable (VortXRemuxHLSServer) -> Void = { [weak self] timedOutServer in
            Task { @MainActor [weak self] in
                self?.handleRemuxStartupTimeout(
                    timedOutServer, loadToken: issuedToken)
            }
        }
        var adoptedPrepared: VortXPreparedRemuxHandle.AdoptedTransport?
        if let preparedCandidate {
            if wantsRemux, VortXRemuxHLSServer.deliveryEnabled {
                let expectedIdentity = VortXPreparedRemuxIdentity(
                    owner: preparedCandidate.ownerIdentity,
                    input: url,
                    headers: headers,
                    mode: wantsPlainRemux ? .plain : .dolbyVision,
                    startAtSeconds: requestedRemuxOrigin,
                    selectedAudioStreamIndex: selectedRemuxAudioSourceIndex,
                    preferredAudioLanguages: remuxPreferredAudioLanguages,
                    audioRejectTerms: remuxAudioRejectTerms)
                if case .adopted(let transport) = preparedCandidate.handle.adopt(
                    expectedIdentity: expectedIdentity,
                    onStartupTimeout: startupTimeout
                ) {
                    adoptedPrepared = transport
                }
            } else {
                preparedCandidate.handle.abandon(reason: "load-not-local-remux")
            }
        }
        // EXTERNAL ENGINE MODE. When the user has paired a Mac and turned this on, the remux is produced THERE
        // and mounted over the LAN, so this device spends its whole chip decoding instead of demuxing, rewriting
        // the Dolby Vision RPU, muxing and spooling. The stream is a copy either way: nothing is re-encoded, so
        // the picture and the RPU are identical to the on-device lane's.
        //
        // Opening a session is a network round trip, so it cannot happen inline on this main-actor path. It
        // follows the SAME pattern the tvOS native-DV preflight already uses in this function: the old item has
        // already been retired above, an async task does the work, and `attachPreparedItem` is still the only
        // place a replacement mounts. If anything at all goes wrong (host asleep, refused, unreachable, no
        // signalling) the task sets `bypassExternalEngine` and re-enters this function on the same token, which
        // takes the ordinary local branch below. There is no state in which a bad host is worse than no host.
        let externalConsumed = bypassExternalEngine
        bypassExternalEngine = false
        if adoptedPrepared == nil,
           wantsRemux, VortXRemuxHLSServer.deliveryEnabled, !externalConsumed,
           case .external = VortXExternalEngine.shared.mountPlan {
            beginExternalEngineMount(
                url: url,
                headers: headers,
                wantsPlainRemux: wantsPlainRemux,
                startAtSeconds: requestedRemuxOrigin,
                selectedAudioStreamIndex: selectedRemuxAudioSourceIndex,
                preferredAudioLanguages: remuxPreferredAudioLanguages,
                audioRejectTerms: remuxAudioRejectTerms,
                live: live,
                audioSidecar: audioSidecar,
                loadToken: issuedToken,
                generation: issuedGeneration)
            return issuedToken
        }
        if let adopted = adoptedPrepared {
            remuxHLSServer = adopted.server
            newAsset = AVURLAsset(url: adopted.playlistURL)
            let lane = wantsPlainRemux ? "plain-remux" : "dv-remux"
            DiagnosticsLog.log(
                "avplayer",
                "\(lane) mount (prepared local HLS) host=\(url.host ?? "?") -> 127.0.0.1:\(adopted.server.port)")
            VXProbe.log(
                "dv",
                "\(lane) adopted (prepared local HLS) host=\(url.host ?? "?") -> 127.0.0.1:\(adopted.server.port)")
        } else if wantsRemux, VortXRemuxHLSServer.deliveryEnabled,
           let mounted = VortXRemuxHLSServer.make(input: url, headers: headers,
                                                  mode: wantsPlainRemux ? .plain : .dolbyVision,
                                                  startAtSeconds: requestedRemuxOrigin,
                                                  selectedAudioStreamIndex: selectedRemuxAudioSourceIndex,
                                                  preferredAudioLanguages: remuxPreferredAudioLanguages,
                                                  audioRejectTerms: remuxAudioRejectTerms,
                                                  onStartupTimeout: startupTimeout) {
            remuxHLSServer = mounted.server
            mounted.server.start()
            newAsset = AVURLAsset(url: mounted.playlistURL)
            let lane = wantsPlainRemux ? "plain-remux" : "dv-remux"
            DiagnosticsLog.log("avplayer", "\(lane) mount (local HLS) host=\(url.host ?? "?") -> 127.0.0.1:\(mounted.server.port)")
            // [dv] the remux lane mounted: AVPlayer is now fed the remux as local HLS. If a classify
            // fail-soft fires next (see VortXMKVRemuxStream), the item .failed demotion below ties the reason
            // to the observed engine flip, giving one greppable [dv] trail (the plain lane logs on the same
            // channel so one grep still shows route -> mount -> classify -> demote in order).
            VXProbe.log("dv", "\(lane) mounted (local HLS) host=\(url.host ?? "?") -> 127.0.0.1:\(mounted.server.port)")
        } else if wantsDVRemux, !VortXRemuxHLSServer.deliveryEnabled,
                  let built = VortXRemuxResourceLoader.make(
                    input: url,
                    headers: headers,
                    selectedAudioStreamIndex: selectedRemuxAudioSourceIndex,
                    preferredAudioLanguages: remuxPreferredAudioLanguages,
                    audioRejectTerms: remuxAudioRejectTerms) {
            remuxLoader = built.loader
            let asset = AVURLAsset(url: built.assetURL)
            asset.resourceLoader.setDelegate(built.loader, queue: remuxLoaderQueue)
            built.loader.start()
            newAsset = asset
            DiagnosticsLog.log("avplayer", "dv-remux mount host=\(url.host ?? "?") -> \(built.assetURL.scheme ?? "?")")
            VXProbe.log("dv", "remux mounted host=\(url.host ?? "?") -> \(built.assetURL.scheme ?? "?")")
        } else if wantsRemux {
            // The remux lane (DV or plain) was demanded but the mount could not be built (the local HLS
            // server failed to bind, or the legacy loader could not be assembled). AVFoundation has no
            // Matroska demuxer, so loading the raw MKV here would mount an item AVPlayer can never produce a
            // frame from. Fail-soft immediately so the chrome demotes to libmpv instead of stalling on
            // an un-demuxable asset. This ties into the [dv] demotion trail below.
            let lane = wantsPlainRemux ? "plain-remux" : "dv-remux"
            if recoverAudioReplacementIfNeeded(
                generation: issuedGeneration,
                reason: "\(lane) mount build failed") {
                return issuedToken
            }
            DiagnosticsLog.log("avplayer", "\(lane) mount build failed host=\(url.host ?? "?") -> demoting to libmpv")
            VXProbe.log("dv", "\(lane) mount build failed -> endFileError demote host=\(url.host ?? "?")")
            guard terminalLatch.claim(generation: issuedGeneration) else { return issuedToken }
            fatalErrorEmitted = true
            emit(MPVProperty.endFileError,
                 wantsPlainRemux ? "Remux unavailable" : "DV remux unavailable",
                 loadToken: issuedToken)
            return issuedToken
        } else {
            let options = (headers?.isEmpty ?? true) ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers!]
            newAsset = AVURLAsset(url: url, options: options)
        }
        let newItem = AVPlayerItem(asset: newAsset)
        // A10-ii: name the AVPlayer lane on the probe at the mount, so the first heartbeat after routing shows
        // engine=avplayer + the source host instead of a stale or blank lane. The KVO observers refine the
        // state, position and duration as playback settles.
        VXProbeState.shared.setPlayer(state: "buffering", source: url.host, engine: "avplayer")
        if isRemuxMounted {
            // The remux window bounds OUR buffer, but AVPlayer keeps its OWN forward buffer of the served HLS
            // and, left unset, sizes it at its discretion (hundreds of MB at 4K DV bitrates, in the SAME
            // jetsam-bound process as node + mpv). Local production starts at the four-second HLS floor,
            // then restores the field-proven 30s cap at the first rendered frame.
            newItem.preferredForwardBufferDuration =
                VortXRemuxForwardBufferPolicy.preferredDuration(
                    mount: forwardBufferMount,
                    hasProducedFirstFrame: false)
        }
        // Attach a pull-model frame tap so trickplay can grab the displayed frame on demand (see videoOutput).
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        newItem.add(output)
        #if os(tvOS)
        // TRUE DOLBY VISION: switch the panel into DV mode BEFORE the item is attached (Apple Tech Talk 503:
        // "perform this switch before assigning the AVPlayerItem"; current tvOS can even reject mismatched
        // VIDEO-RANGE HLS variants with -11868 when the panel is not switched first). Fires when the DV remux
        // mounted (it only mounts for DV) OR the routed stream is DV-flagged (a native DV MP4/MOV/HLS, which
        // previously never set preferredDisplayCriteria at all). fps/size are unknown pre-attach; the
        // readyToPlay request below re-asserts with the real values. Fail-soft: a refused/ignored request
        // changes nothing about playback, and reset() on stop() restores the default mode.
        if isRemuxMounted, wantsDVRemux {
            // DV REMUX lane: DEFER the panel switch to the point classify confirms a DECODABLE DV profile (#76).
            // The remux stream knows the profile ~1.5-6s in; VortXRemuxHLSServer.serveMaster fires the switch
            // once the DV signaling is published and BEFORE the media playlist / first segment (still ahead of
            // the video mount, per Tech Talk 503 ordering). Firing it here on mount cycled the panel twice per
            // hop whenever classify then rejected a non-DV / undecodable source. Neither switch NOR reset here:
            // a reject 404s the playlist and demotes to libmpv (which resets on stop), and a same-DV back-to-back
            // play keeps the panel steady instead of reset-then-reswitch. Matches the old behavior of never
            // resetting on the remux path, just deferring the request.
            DiagnosticsLog.log("dv", "Dolby Vision display switch deferred to classify (remux lane)")
        } else if contentIsDolbyVision {
            // NATIVE DV lane: `request(... fps: 0)` was a dead pre-attach path because unknown rates are
            // correctly rejected. The async preflight below loads Apple's own preferredDisplayCriteria, applies
            // that exact object, then attaches. No criterion is constructed from the text-parse DV hint.
            DiagnosticsLog.log("dv", "native Dolby Vision item awaiting asset-owned display criteria before attach")
        } else {
            // A non-DV stream loading into this SAME engine (an in-player source/episode switch) must not
            // inherit a previous title's DV criteria. Idempotent: reset only clears when criteria are set.
            // #147: a mounted PLAIN remux lands here too (contentIsDolbyVision=false, wantsDVRemux=false), so
            // a plain MKV following a DV title correctly clears the panel; the plain lane's server never
            // requests a switch (serveMaster is gated on sig.dolbyVision).
            HDRDisplayMode.reset(in: nil)
        }
        #endif
        // Remux mounts use AVPlayer's stall-aware start against their explicit bounded startup buffer. Direct
        // mounts retain the established prompt-start behavior because their source buffering remains unbounded
        // by VortX and their watchdog contract has not changed.
        player.automaticallyWaitsToMinimizeStalling =
            VortXRemuxForwardBufferPolicy.automaticallyWaitsToMinimizeStalling(
                mount: forwardBufferMount)
        player.allowsExternalPlayback = true   // AirPlay
        DiagnosticsLog.log("avplayer", "load host=\(url.host ?? "?") scheme=\(url.scheme ?? "?") ext=\(url.pathExtension) headers=\(headers?.count ?? 0) live=\(live)")
        #if os(tvOS)
        if contentIsDolbyVision && !isRemuxMounted {
            beginNativeDVPreAttach(
                asset: newAsset,
                item: newItem,
                output: output,
                loadToken: issuedToken,
                generation: issuedGeneration)
            return issuedToken
        }
        #endif
        attachPreparedItem(
            newItem,
            output: output,
            loadToken: issuedToken,
            generation: issuedGeneration)
        return issuedToken
    }

    private func pendingLoadIsCurrent(loadToken: PlayerLoadToken, generation: UInt64) -> Bool {
        activeLoadToken == loadToken && itemGeneration == generation
    }

    /// The only initial-item attach point. There is no suspension inside this main-actor method, but each
    /// side effect still rechecks token + generation so the ownership contract stays explicit and auditable.
    private func attachPreparedItem(_ newItem: AVPlayerItem,
                                    output: AVPlayerItemVideoOutput,
                                    loadToken: PlayerLoadToken,
                                    generation: UInt64) {
        guard pendingLoadIsCurrent(loadToken: loadToken, generation: generation) else { return }
        item = newItem
        guard pendingLoadIsCurrent(loadToken: loadToken, generation: generation) else { return }
        videoOutput = output
        guard pendingLoadIsCurrent(loadToken: loadToken, generation: generation) else { return }
        player.replaceCurrentItem(with: newItem)
        guard pendingLoadIsCurrent(loadToken: loadToken, generation: generation),
              player.currentItem === newItem else { return }
        observe(newItem, loadToken: loadToken)
        // KVO uses [.initial, .new], but an already-ready item still gets an explicit kick.
        if newItem.status != .unknown { handleStatus(newItem, loadToken: loadToken) }
    }

    #if os(tvOS)
    private func beginNativeDVPreAttach(asset: AVAsset,
                                        item newItem: AVPlayerItem,
                                        output: AVPlayerItemVideoOutput,
                                        loadToken: PlayerLoadToken,
                                        generation: UInt64) {
        nativePreAttachTask?.cancel()
        nativePreAttachTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let criteria = try await asset.load(.preferredDisplayCriteria)
                guard !Task.isCancelled else { return }
                let outcome = DVPlaybackPolicy.completeNativePreAttach(
                    loadedCriteria: criteria,
                    isCurrent: {
                        self.pendingLoadIsCurrent(loadToken: loadToken, generation: generation)
                            && !Task.isCancelled
                    },
                    apply: { loadedCriteria in
                        self.nativeDisplayCriteria = loadedCriteria
                        let applied = HDRDisplayMode.applyNativePreferredCriteria(loadedCriteria, in: nil)
                        DiagnosticsLog.log(
                            "dv", "native asset-owned criteria pre-attach apply=\(applied ? "accepted" : "fail-soft") generation=\(generation)")
                    },
                    attach: {
                        self.attachPreparedItem(
                            newItem,
                            output: output,
                            loadToken: loadToken,
                            generation: generation)
                    })
                if self.pendingLoadIsCurrent(loadToken: loadToken, generation: generation) {
                    self.nativePreAttachTask = nil
                }
                DiagnosticsLog.log("dv", "native display preflight completed outcome=\(String(describing: outcome)) generation=\(generation)")
            } catch {
                guard !Task.isCancelled else { return }
                let outcome = DVPlaybackPolicy.completeNativePreAttach(
                    loadedCriteria: Optional<AVDisplayCriteria>.none,
                    isCurrent: {
                        self.pendingLoadIsCurrent(loadToken: loadToken, generation: generation)
                            && !Task.isCancelled
                    },
                    apply: { _ in },
                    attach: {
                        self.attachPreparedItem(
                            newItem,
                            output: output,
                            loadToken: loadToken,
                            generation: generation)
                    })
                if self.pendingLoadIsCurrent(loadToken: loadToken, generation: generation) {
                    self.nativePreAttachTask = nil
                }
                DiagnosticsLog.log(
                    "dv", "native preferredDisplayCriteria load failed; attach fail-soft outcome=\(String(describing: outcome)) error=\(error.localizedDescription)")
            }
        }
        DiagnosticsLog.log(
            "dv", "native display preflight started; retired item detached, existing chrome start watchdogs remain the outer slow-load bound generation=\(generation)")
    }
    #endif

    // MARK: - External engine mode

    /// Open a hosted remux session, wait for its signalling, switch the panel, then attach.
    ///
    /// Modelled directly on `beginNativeDVPreAttach`: the retired item is already detached by the time this is
    /// called, the async work is cancellable, every side effect rechecks token and generation, and
    /// `attachPreparedItem` remains the only place a replacement mounts. The chrome's existing start watchdog is
    /// still the outer bound on a slow load, so nothing new can hang playback.
    private func beginExternalEngineMount(url: URL,
                                          headers: [String: String]?,
                                          wantsPlainRemux: Bool,
                                          startAtSeconds: Double,
                                          selectedAudioStreamIndex: Int?,
                                          preferredAudioLanguages: [String]?,
                                          audioRejectTerms: [String]?,
                                          live: Bool,
                                          audioSidecar: URL?,
                                          loadToken: PlayerLoadToken,
                                          generation: UInt64) {
        externalMountTask?.cancel()
        let terminalRelay = VortXRemuxProducerTerminalRelay()
        externalMountTerminalRelay = terminalRelay
        let mode: VortXEngineProtocol.RemuxMode = wantsPlainRemux ? .plain : .dolbyVision
        DiagnosticsLog.log("engine", "external engine mount requested mode=\(mode.rawValue) generation=\(generation)")
        externalMountTask = Task { @MainActor [weak self] in
            defer {
                terminalRelay.fire()
                if self?.externalMountTerminalRelay === terminalRelay {
                    self?.externalMountTerminalRelay = nil
                }
            }
            guard let self else { return }
            let mount = await VortXRemoteRemuxMount.open(
                input: url, headers: headers, mode: mode, startAtSeconds: startAtSeconds,
                selectedAudioStreamIndex: selectedAudioStreamIndex,
                preferredAudioLanguages: preferredAudioLanguages,
                audioRejectTerms: audioRejectTerms,
                onLost: { [weak self] emittingMount in
                    Task { @MainActor [weak self] in
                        self?.handleExternalEngineLost(
                            loadToken: loadToken,
                            openingGeneration: generation,
                            emittingMount: emittingMount)
                    }
                })
            guard !Task.isCancelled,
                  self.pendingLoadIsCurrent(loadToken: loadToken, generation: generation) else {
                mount?.invalidate()
                return
            }
            guard let mount else {
                // The host refused, is asleep, or is unreachable. Re-enter loadFile on the SAME token with the
                // external lane bypassed, which is the ordinary on-device mount and therefore the shipped
                // behaviour exactly. The user sees a slightly slower start, never a failure.
                DiagnosticsLog.log(
                    "engine",
                    "external engine fallback reason=session-open-failed -> on-device remux mount")
                self.bypassExternalEngine = true
                _ = self.loadFile(url, headers: headers, live: live,
                                  audioSidecar: audioSidecar, reusing: loadToken)
                return
            }
            // Wait for init plus classify under one bounded startup deadline. Steady-state health polling starts
            // only after this succeeds, so a young host session cannot be abandoned on its first legacy
            // `healthy=false` status before init publication.
            let readiness = await mount.awaitSignalling()
            guard !Task.isCancelled,
                  self.pendingLoadIsCurrent(loadToken: loadToken, generation: generation) else {
                mount.invalidate()
                return
            }
            guard case .success(let receipt) = readiness else {
                let reason: String
                if case .failure(let failure) = readiness {
                    reason = failure.rawValue
                } else {
                    reason = "unknown-readiness-result"
                }
                DiagnosticsLog.log(
                    "engine",
                    "external engine fallback reason=\(reason) session=\(mount.identity.sessionID) "
                        + "-> on-device remux mount")
                mount.invalidate()
                self.bypassExternalEngine = true
                _ = self.loadFile(url, headers: headers, live: live,
                                  audioSidecar: audioSidecar, reusing: loadToken)
                return
            }
            guard VortXEngineHostPolicy.readinessReceiptMatches(
                expected: mount.identity,
                received: receipt.identity) else {
                DiagnosticsLog.log(
                    "engine",
                    "external engine fallback reason=stale-readiness-receipt "
                        + "expected=\(mount.identity.sessionID) received=\(receipt.identity.sessionID) "
                        + "-> on-device remux mount")
                mount.invalidate()
                self.bypassExternalEngine = true
                _ = self.loadFile(url, headers: headers, live: live,
                                  audioSidecar: audioSidecar, reusing: loadToken)
                return
            }
            mount.start()
            DiagnosticsLog.log(
                "engine",
                "external engine ready session=\(mount.identity.sessionID) init=true signaling=true "
                    + "-> attaching remote remux")
            self.attachRemoteRemux(mount, signalling: receipt.status,
                                   wantsPlainRemux: wantsPlainRemux,
                                   loadToken: loadToken, generation: generation)
        }
    }

    /// Build and attach the item for a hosted mount.
    ///
    /// This deliberately does NOT share the local branch's tail. The two differ in the one place that matters:
    /// on-device the panel switch is deferred to the remux server and fires when it serves the master, while
    /// here it fires BEFORE the item exists, which is the ordering Apple Tech Talk 503 actually asks for and
    /// which only a client that already knows the signalling can achieve. Folding them together would mean a
    /// conditional inside the shipped local path, which is the one path that must not move.
    private func attachRemoteRemux(_ mount: VortXRemoteRemuxMount,
                                   signalling: VortXEngineProtocol.SessionStatus,
                                   wantsPlainRemux: Bool,
                                   loadToken: PlayerLoadToken,
                                   generation: UInt64) {
        guard pendingLoadIsCurrent(loadToken: loadToken, generation: generation) else {
            mount.invalidate()
            return
        }
        remuxRemoteMount = mount
        remuxRemoteOpeningGeneration = generation
        remuxRemoteItemGeneration = generation
        refreshRemuxSourceAudioTracks()
        let newItem = AVPlayerItem(asset: AVURLAsset(url: mount.playlistURL))
        newItem.preferredForwardBufferDuration =
            VortXRemuxForwardBufferPolicy.preferredDuration(
                mount: .remoteRemux,
                hasProducedFirstFrame: false)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        newItem.add(output)
        #if os(tvOS)
        if !wantsPlainRemux, signalling.dolbyVision, signalling.frameRate > 0,
           signalling.width > 0, signalling.height > 0 {
            HDRDisplayMode.request(.dolbyVision, fps: signalling.frameRate,
                                   width: signalling.width, height: signalling.height, in: nil)
            DiagnosticsLog.log(
                "dv",
                "hosted remux confirmed DV -> requested Dolby Vision display mode pre-attach (fps=\(String(format: "%.3f", signalling.frameRate)) \(signalling.width)x\(signalling.height))")
        } else if !signalling.dolbyVision {
            // A hosted PLAIN or non-DV session must clear a previous title's criteria, exactly as the local
            // lane's else-branch does. Idempotent.
            HDRDisplayMode.reset(in: nil)
        }
        #endif
        player.automaticallyWaitsToMinimizeStalling =
            VortXRemuxForwardBufferPolicy.automaticallyWaitsToMinimizeStalling(
                mount: .remoteRemux)
        player.allowsExternalPlayback = true
        DiagnosticsLog.log(
            "avplayer",
            "external-remux mount host=\(mount.playlistURL.host ?? "?") retainsTimeline=\(mount.retainsFullTimeline) generation=\(generation)")
        VXProbe.log("dv", "remux mounted on an EXTERNAL engine host=\(mount.playlistURL.host ?? "?") seekAnywhere=\(mount.retainsFullTimeline)")
        attachPreparedItem(newItem, output: output, loadToken: loadToken, generation: generation)
    }

    /// The Mac went away mid-playback: lid closed, slept, quit, or dropped off Wi-Fi.
    ///
    /// Degrade to an on-device mount AT THE CURRENT POSITION rather than stalling. This reuses the resume-origin
    /// machinery the chrome already owns instead of inventing anything: `configureResumeOrigin` is the one-shot
    /// handoff a fresh remux reads to start part-way in. The user sees a rebuffer, which is the correct and
    /// honest outcome, and playback continues on the lane that never needed a Mac.
    private func handleExternalEngineLost(
        loadToken: PlayerLoadToken,
        openingGeneration: UInt64,
        emittingMount: VortXRemoteRemuxMount
    ) {
        guard let mount = remuxRemoteMount, let url = lastLoadURL else { return }
        guard VortXEngineHostPolicy.remoteCallbackIsCurrent(
            loadTokenMatches: activeLoadToken == loadToken,
            expectedOpeningGeneration: remuxRemoteOpeningGeneration,
            emittingOpeningGeneration: openingGeneration,
            itemGenerationMatches: remuxRemoteItemGeneration == itemGeneration,
            mountedIdentity: mount.identity,
            emittingIdentity: emittingMount.identity
        ), mount === emittingMount else {
            DiagnosticsLog.log(
                "engine",
                "ignored stale external engine loss callback "
                    + "mounted=\(mount.identity.sessionID) emitting=\(emittingMount.identity.sessionID) "
                    + "openingGeneration=\(openingGeneration) currentGeneration=\(itemGeneration)")
            return
        }
        // Snapshot before the remote item and its media-selection groups disappear. This is the same intent
        // audio and HDR remounts use, so host loss cannot rewind an older transaction or turn explicit Off
        // back into an automatic subtitle.
        let intent = capturePlaybackIntent(from: item)
        pendingPlaybackIntent = intent
        let resumeAt = intent.sourceSeconds
        DiagnosticsLog.log(
            "engine",
            "external engine lost mid-playback -> on-device remount at \(String(format: "%.1f", resumeAt))s")
        remuxRemoteMount = nil
        remuxRemoteOpeningGeneration = nil
        remuxRemoteItemGeneration = nil
        mount.invalidate()
        switch PlaybackIntentPolicy.hostLossAction(
            hasAudioReplacement: audioReplacement != nil
        ) {
        case .remountAudioReplacement:
            // A hosted B/C replacement still owns its original source playhead. Stay on the same logical
            // transaction so the local retry binds a newer generation instead of clearing the replacement.
            bypassExternalEngine = true
            mountCurrentAudioReplacement(reason: "hosted audio replacement failed over to device")
            return
        case .reloadLocalSameToken:
            break
        }
        configureResumeOrigin(seconds: resumeAt)
        configureAudioSourceForNextLoad(selectedRemuxAudioSourceIndex)
        bypassExternalEngine = true
        // Same logical load and one carried intent. `loadFile` assigns the new mount identity and item
        // generation, then the one restore point consumes only that exact binding.
        _ = loadFile(url, headers: lastLoadHeaders, live: lastLoadLive,
                     audioSidecar: nil, reusing: loadToken)
    }

    /// #147 reactive-net gate: should this item failure be retried through the PLAIN remux lane instead of
    /// demoting to libmpv? True only when ALL hold:
    ///  - the mount never produced playback (`!didStart`) and is a RAW mount (`!isRemuxMounted`: a failure on
    ///    an already-remuxed mount means the remux lane itself cannot serve this source, so demote honestly);
    ///  - one-shot per load (`!plainRemuxRetried`), non-DV (`!contentIsDolbyVision`: DV routing has its own
    ///    lane + repair paths, untouched), the plain lane is enabled and HLS delivery is not rolled back;
    ///  - the URL is one the remux can even attempt (`isPlainRemuxRetryCandidate`: not an AVPlayer-native
    ///    container, not loopback - the broad probe-and-fail-fast candidacy, correct here because AVPlayer
    ///    has already PROVEN it cannot demux these bytes);
    ///  - the failure is the specific CONTAINER-UNSUPPORTED signature (AVFoundation "Cannot Open",
    ///    fileFormatNotRecognized): a network / DRM / decode failure must demote as before, never re-spin
    ///    the same broken source through a remux.
    private func shouldRetryViaPlainRemux(error ns: NSError?) -> Bool {
        guard !didStart, !isRemuxMounted, !plainRemuxRetried, !contentIsDolbyVision else { return false }
        guard VortXRemuxHLSServer.deliveryEnabled, PlayerEngineRouter.plainRemuxEnabled() else { return false }
        guard let url = lastLoadURL, PlayerEngineRouter.isPlainRemuxRetryCandidate(url) else { return false }
        guard let ns, ns.domain == AVFoundationErrorDomain else { return false }
        return ns.code == AVError.Code.fileFormatNotRecognized.rawValue   // -11828, "Cannot Open"
    }

    private static func hdrFallbackTriggerError(_ error: NSError?) -> NSError? {
        guard let error else { return nil }
        if error.domain == "CoreMediaErrorDomain" { return error }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == "CoreMediaErrorDomain" {
            return underlying
        }
        return error
    }

    /// Replace a rejected DV item with one explicit HDR-only item on the same healthy remux mount. The logical
    /// load token and remux stay alive; exact-item generation advances so late callbacks from the DV item are
    /// ignored. The playhead, requested rate and current media selections are restored on the replacement.
    private func retryFreshHDRItemOnHealthyMount(
        error: NSError?,
        allowRemoteCapabilityRefresh: Bool = true,
        onUnavailable: @escaping @MainActor () -> Void
    ) -> Bool {
        guard !fatalErrorEmitted else { return false }
        let trigger = Self.hdrFallbackTriggerError(error)
        let mountHealthy = remuxHLSServer?.isMountHealthy
            ?? remuxRemoteMount?.isMountHealthy ?? false
        let fallbackAvailable = remuxHLSServer?.supportsHDRFallback
            ?? remuxRemoteMount?.supportsHDRFallback ?? false
        guard DVPlaybackPolicy.shouldAttemptHDRFallback(
            dolbyVision: contentIsDolbyVision,
            remuxMounted: isRemuxMounted,
            mountHealthy: mountHealthy,
            // Validate every immutable gate first. A hosted capability may still be absent only because the
            // client's cached status predates init surgery, which is resolved below by one authoritative poll.
            fallbackAvailable: true,
            alreadyAttempted: hdrFallbackRetried,
            errorDomain: trigger?.domain,
            errorCode: trigger?.code ?? 0
        ) else { return false }

        if !fallbackAvailable {
            guard allowRemoteCapabilityRefresh, let remote = remuxRemoteMount else { return false }
            if hdrFallbackCapabilityRefreshTask != nil { return true }
            guard let failedItem = item,
                  player.currentItem === failedItem,
                  let loadToken = activeLoadToken else { return false }
            let failedGeneration = itemGeneration
            DiagnosticsLog.log(
                "dv",
                "hosted HDR recovery capability was stale or unavailable at -12927 -> bounded authoritative refresh")
            hdrFallbackCapabilityRefreshTask = Task { @MainActor [weak self] in
                let becameAvailable = await remote.awaitHDRFallbackCapability()
                guard let self, !Task.isCancelled,
                      self.pendingLoadIsCurrent(
                        loadToken: loadToken,
                        generation: failedGeneration),
                      self.item === failedItem,
                      self.player.currentItem === failedItem,
                      self.remuxRemoteMount === remote else { return }
                self.hdrFallbackCapabilityRefreshTask = nil
                guard !self.hdrFallbackRetried,
                      !self.fatalErrorEmitted else { return }
                guard becameAvailable else {
                    DiagnosticsLog.log(
                        "dv",
                        "hosted HDR recovery capability did not become authoritative -> original fatal path")
                    onUnavailable()
                    return
                }
                guard self.retryFreshHDRItemOnHealthyMount(
                    error: error,
                    allowRemoteCapabilityRefresh: false,
                    onUnavailable: onUnavailable) else {
                    DiagnosticsLog.log(
                        "dv",
                        "hosted HDR recovery capability refreshed but retry identity no longer qualified -> original fatal path")
                    onUnavailable()
                    return
                }
            }
            return true
        }

        hdrFallbackCapabilityRefreshTask?.cancel()
        hdrFallbackCapabilityRefreshTask = nil
        guard let currentItem = item,
           let primaryURL = (currentItem.asset as? AVURLAsset)?.url,
           let fallbackURL = DVPlaybackPolicy.hdrFallbackMasterURL(from: primaryURL),
           let loadToken = activeLoadToken else { return false }
        if remountPendingSeekIfOutsideWindow() {
            return true
        }

        // Capture before groups and the current item are retired. If an audio replacement already owns an
        // intent, this refreshes that same value and preserves any newest choice made while groups were empty.
        var recoveryIntent = capturePlaybackIntent(from: currentItem)
        if let pendingSeek { recoveryIntent.updateSourceSeconds(pendingSeek) }
        pendingPlaybackIntent = recoveryIntent
        hdrFallbackRetried = true
        usingHDRFallbackItem = true
        DiagnosticsLog.log(
            "dv",
            "healthy DV item rejected CoreMedia -12927 -> one fresh HDR-only item at \(fallbackURL.lastPathComponent), sourceTime=\(String(format: "%.3f", playbackPositionSeconds))s")
        VXProbe.log(
            "dv",
            "DV item -12927 on healthy mount -> ONE explicit HDR-only recovery item before demote")

        invalidateSeekRequests()
        teardownObservers()
        player.pause()
        isReady = false; didStart = false; pendingSeek = nil; fatalErrorEmitted = false
        videoFrameEverProduced = false; preferredPeakBitRatePinned = false
        audioOverBlackSince = 0; audioOverBlackFired = false
        stallEpisode.reset()
        audioGroup = nil; subGroup = nil; audioTracks = []; subTracks = []
        selectionTopologyGeneration = nil
        selectionRefreshState.reset()

        let freshItem = AVPlayerItem(asset: AVURLAsset(url: fallbackURL))
        itemGeneration &+= 1
        terminalLatch.reset(generation: itemGeneration)
        if remuxRemoteMount != nil {
            remuxRemoteItemGeneration = itemGeneration
        }
        audioReplacement?.bind(to: itemGeneration)
        pendingPlaybackIntent?.bind(
            generation: itemGeneration,
            mountIdentity: playbackMountIdentity)
        item = freshItem
        freshItem.preferredForwardBufferDuration =
            VortXRemuxForwardBufferPolicy.preferredDuration(
                mount: forwardBufferMount,
                hasProducedFirstFrame: false)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        freshItem.add(output)
        videoOutput = output

        #if os(tvOS)
        // A hosted server is a Mac, so it cannot switch the Apple TV panel when this master is requested.
        // The client already cached the host's classify result and applies the compatible base-layer mode
        // before attaching the fresh item. The local server performs the same request inside serveMaster.
        if let remote = remuxRemoteMount, remote.authoritativeFrameRate > 0,
           remote.videoWidth > 0, remote.videoHeight > 0 {
            let recoveryRange = DVPlaybackPolicy.hdrFallbackDisplayRange(videoRange: remote.videoRange)
            HDRDisplayMode.request(
                recoveryRange == .hlg ? .hlg : .hdr10,
                fps: remote.authoritativeFrameRate,
                width: remote.videoWidth,
                height: remote.videoHeight,
                in: nil)
        }
        #endif

        player.replaceCurrentItem(with: freshItem)
        observe(freshItem, loadToken: loadToken)
        if freshItem.status != .unknown { handleStatus(freshItem, loadToken: loadToken) }
        return true
    }

    private func refreshPendingIntentTransport() {
        guard var intent = pendingPlaybackIntent else { return }
        intent.updateTransport(
            playbackRequested: playbackRequested,
            requestedRate: requestedRate)
        pendingPlaybackIntent = intent
    }

    /// A seek can arrive while hosted HDR capability is being refreshed on a failed item. Once the refresh
    /// completes, a target outside that mount's produced window must start a replacement remux rather than be
    /// clamped onto the old edge by the fresh HDR-only item.
    private func remountPendingSeekIfOutsideWindow() -> Bool {
        guard let target = pendingSeek, isRemuxMounted else { return false }
        let sourceDuration = remuxHLSServer?.sourceDurationSeconds
            ?? remuxRemoteMount?.sourceDurationSeconds ?? remuxLoader?.sourceDurationSeconds
        let mountedWindow = mountedPlayerWindowBounds
        switch RemuxResumePolicy.mountedSeekAction(
            sourceSeconds: target,
            origin: remuxTimelineOrigin,
            authoritativeSourceDurationSeconds: sourceDuration,
            playerDurationSeconds: item?.duration.seconds ?? 0,
            servedStartPlayerSeconds: mountedWindow.servedStart,
            producedEdgePlayerSeconds: mountedWindow.producedEdge) {
        case .seekPlayer:
            return false
        case .remountAtSource(let sourceSeconds):
            return remountForSeek(sourceSeconds: sourceSeconds)
        }
    }

    /// Apply only the controller's live committed transport. Remount snapshots restore playhead and media
    /// selections, but a snapshot must never replay transport captured before a later user action.
    private func applyCommittedTransport() {
        switch PlaybackIntentPolicy.committedTransportAction(
            playbackRequested: playbackRequested,
            requestedRate: requestedRate) {
        case .play(let rate):
            // Explicit play() then pin the rate. Direct mounts keep prompt-start behavior; remux mounts wait
            // only for their explicit bounded startup policy.
            player.play()
            player.rate = rate
        case .pause:
            player.pause()
        }
    }

    /// One line per transport call, carrying the committed intent, the requested rate, AVPlayer's own
    /// timeControlStatus and whether a replacement intent is outstanding. The Beta 13 remount was read from a
    /// device log in which play(), pause(), togglePause() and setSpeed() wrote NOTHING at all, so a press that
    /// reached the engine could not be told from one that never arrived. This is the receipt for the press.
    private func logTransport(_ call: String) {
        DiagnosticsLog.log(
            "avplayer",
            "\(call) playbackRequested=\(playbackRequested) requestedRate=\(requestedRate) "
                + "tcs=\(player.timeControlStatus.rawValue) pendingIntent=\(pendingPlaybackIntent != nil)")
    }

    func play() {
        playbackRequested = true
        refreshPendingIntentTransport()
        player.rate = requestedRate
        logTransport("play")
        // OPTIMISTIC TRANSPORT PUBLISH. The chrome's pause glyph hangs off this property, and its only other
        // producer is the timeControlStatus KVO -- which CANNOT fire during a remount, because the player is
        // already sitting at rate 0 / .paused and nothing changes for it to observe. A press then left the OSD
        // showing the opposite state for as long as the replacement took. Publish the committed intent here,
        // where the press is known. The KVO still reports genuine system-driven changes and is guarded (see
        // `observe`) so it can never contradict an outstanding intent mid-remount.
        emit(MPVProperty.pause, false)
    }
    func pause() {
        playbackRequested = false
        refreshPendingIntentTransport()
        player.pause()
        logTransport("pause")
        emit(MPVProperty.pause, true)   // see play(): the KVO cannot cover a press made during a remount
    }
    func togglePause() {
        logTransport("togglePause")
        playbackRequested ? pause() : play()
    }

    /// Replace a forward-only remux with one whose input begins at the requested source second. This is the
    /// actual seek operation when the current HLS item has not produced, or no longer retains, that point.
    @discardableResult
    private func remountForSeek(sourceSeconds: Double) -> Bool {
        guard let loadToken = activeLoadToken,
              let url = lastLoadURL,
              (isRemuxMounted || pendingRemuxGeneration != nil || remuxSeekRemountTarget != nil),
              !lastLoadLive else { return false }

        let requestedTarget = sourceSeconds.isFinite ? max(0, sourceSeconds) : 0
        let mountOrigin = RemuxResumePolicy.originRequest(resumeSeconds: requestedTarget)
        var intent = capturePlaybackIntent(from: item)
        intent.updateSourceSeconds(requestedTarget)
        pendingPlaybackIntent = intent
        remuxSeekRemountTarget = requestedTarget
        pendingSeek = nil
        configureResumeOrigin(seconds: mountOrigin)
        configureAudioSourceForNextLoad(selectedRemuxAudioSourceIndex)
        DiagnosticsLog.log(
            "avplayer",
            "seek outside mounted window -> source target \(String(format: "%.3f", requestedTarget))s "
                + "mount origin \(String(format: "%.3f", mountOrigin))s")
        _ = loadFile(
            url,
            headers: lastLoadHeaders,
            live: lastLoadLive,
            audioSidecar: nil,
            reusing: loadToken)
        // SEEK FEEDBACK. A seek outside the mounted window is a whole replacement mount, and for its entire
        // duration (12.9s in the Beta 13 device log) the engine published NOTHING: the heartbeat still read
        // player=playing while the picture sat frozen on the pre-seek frame, so the wait looked like a hang.
        // Publish the buffering state the chrome already renders as its spinner; readyToPlay clears it.
        // Emitted AFTER loadFile on purpose: `emit` captures `itemGeneration` and the replacement bumps it, so
        // an emit issued before the call would be discarded by its own generation guard. Skipped when the load
        // already failed fast (the chrome is demoting; a spinner on a dead mount would be noise).
        if !fatalErrorEmitted {
            emit(MPVProperty.pausedForCache, true, loadToken: loadToken)
        }
        return true
    }

    func seek(to seconds: Double) {
        let seekRequestID = supersedeSeekRequest()
        if var intent = pendingPlaybackIntent {
            intent.updateSourceSeconds(seconds)
            pendingPlaybackIntent = intent
        }
        // A hosted -12927 capability refresh intentionally keeps the failed item mounted for a bounded interval.
        // AVPlayer cannot honor a seek on that failed item, so preserve the newest source-time intent for the
        // replacement setup rather than sending it into a dead clock.
        if hdrFallbackCapabilityRefreshTask != nil {
            // The capability-refresh completion takes a fresh snapshot from the still-mounted failed item.
            // Keep this separate override so that snapshot cannot replace the user's newer requested time.
            pendingSeek = seconds
            return
        }
        // Before the item is playable, remember the target and apply it on ready (covers the chrome's
        // resume seek issued right after loadFile, which AVPlayer would otherwise drop).
        guard isReady else {
            if let remountTarget = remuxSeekRemountTarget {
                if RemuxResumePolicy.pendingMountNeedsRetarget(
                    requestedSourceSeconds: seconds,
                    mountedSourceRequestSeconds: remountTarget
                ) {
                    _ = remountForSeek(sourceSeconds: seconds)
                }
                // `remuxSeekRemountTarget` is the sole owner of this replacement transaction. Even when its
                // exact source target sanitizes to a different input origin, an equal repeat belongs to this
                // mount and must not fall through to the generic pending-generation comparison below.
                return
            }
            if pendingRemuxGeneration != nil,
               RemuxResumePolicy.pendingMountNeedsRetarget(
                requestedSourceSeconds: seconds,
                mountedSourceRequestSeconds: currentLoadResumeOrigin),
               remountForSeek(sourceSeconds: seconds) {
                return
            }
            if pendingPlaybackIntent == nil { pendingSeek = seconds }
            return
        }
        let dur = item?.duration.seconds ?? 0
        // FORWARD-ONLY REMUX: keep an in-item seek only when the current HLS window serves the target. Anything
        // before the origin, behind an evicted seekable range, or after the produced edge opens a fresh remux at
        // that source second. This single chokepoint covers the scrubber, D-pad nudges, system transport,
        // chapters, and skip actions without issuing AVPlayer seeks into bytes that do not exist.
        let clamped: Double
        if isRemuxMounted {
            let sourceDuration = remuxHLSServer?.sourceDurationSeconds
                ?? remuxRemoteMount?.sourceDurationSeconds ?? remuxLoader?.sourceDurationSeconds
            let mountedWindow = mountedPlayerWindowBounds
            switch RemuxResumePolicy.mountedSeekAction(
                sourceSeconds: seconds,
                origin: remuxTimelineOrigin,
                authoritativeSourceDurationSeconds: sourceDuration,
                playerDurationSeconds: dur,
                servedStartPlayerSeconds: mountedWindow.servedStart,
                producedEdgePlayerSeconds: mountedWindow.producedEdge) {
            case .seekPlayer(let playerSeconds):
                clamped = playerSeconds
            case .remountAtSource(let sourceSeconds):
                if remountForSeek(sourceSeconds: sourceSeconds) {
                    return
                }
                clamped = RemuxResumePolicy.playerSeek(
                    sourceSeconds: sourceSeconds,
                    origin: remuxTimelineOrigin,
                    authoritativeSourceDurationSeconds: sourceDuration,
                    playerDurationSeconds: dur,
                    producedEdgePlayerSeconds: mountedWindow.producedEdge)
            }
        } else {
            clamped = (dur.isFinite && dur > 1) ? min(max(seconds, 0), max(dur - 1, 0)) : max(seconds, 0)
        }
        if let server = remuxHLSServer {
            guard registerSeekAdmission(
                requestID: seekRequestID,
                server: server
            ) else { return }
            let seekGeneration = itemGeneration
            let seekLoadToken = activeLoadToken
            preparedSeekTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled,
                      self?.seekRequestGeneration == seekRequestID,
                      self?.itemGeneration == seekGeneration,
                      self?.activeLoadToken == seekLoadToken else {
                    self?.cancelSeekAdmission(
                        requestID: seekRequestID,
                        server: server
                    )
                    return
                }
                let admitted = await server.prepareForSeek(
                    playerSeconds: clamped,
                    requestID: seekRequestID
                )
                guard let self,
                      !Task.isCancelled,
                      self.seekRequestGeneration == seekRequestID,
                      self.itemGeneration == seekGeneration,
                      self.activeLoadToken == seekLoadToken else {
                    self?.cancelSeekAdmission(
                        requestID: seekRequestID,
                        server: server
                    )
                    return
                }
                if !admitted {
                    self.cancelSeekAdmission(
                        requestID: seekRequestID,
                        server: server
                    )
                    if self.remountForSeek(sourceSeconds: seconds) {
                        return
                    }
                }
                self.commitPlayerSeek(
                    playerSeconds: clamped,
                    requestID: seekRequestID,
                    preparedServer: admitted ? server : nil
                )
                if self.seekRequestGeneration == seekRequestID {
                    self.preparedSeekTask = nil
                }
            }
            return
        }
        commitPlayerSeek(playerSeconds: clamped, requestID: seekRequestID)
    }

    private func commitPlayerSeek(
        playerSeconds clamped: Double,
        requestID: UInt64,
        preparedServer: VortXRemuxHLSServer? = nil
    ) {
        let seekItem = item
        let seekGeneration = itemGeneration
        let seekLoadToken = activeLoadToken
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600)) {
            [weak self, weak preparedServer] finished in
            Task { @MainActor in
                guard let self,
                      finished,
                      self.seekRequestGeneration == requestID,
                      self.itemGeneration == seekGeneration,
                      self.item === seekItem,
                      self.activeLoadToken == seekLoadToken else {
                    if let self, let preparedServer {
                        self.cancelSeekAdmission(
                            requestID: requestID,
                            server: preparedServer
                        )
                    } else {
                        preparedServer?.cancelPreparedSeek(requestID: requestID)
                    }
                    return
                }
                if let preparedServer {
                    self.completeSeekAdmission(
                        requestID: requestID,
                        server: preparedServer,
                        playerSeconds: self.player.currentTime().seconds
                    )
                }
            }
        }
        let reported = RemuxResumePolicy.presented(
            playerSeconds: clamped,
            origin: remuxTimelineOrigin)
        if let item, let loadToken = activeLoadToken,
           owns(item, loadToken: loadToken) {
            emit(
                MPVProperty.timePos,
                PlayerTimePositionEvent(seconds: reported, loadToken: loadToken),
                loadToken: loadToken
            )
        }
        updateSubtitleOverlay(atClock: reported)   // re-check the cue now; the observer is only ~4 Hz
    }
    func seek(by seconds: Double) { seek(to: playbackPositionSeconds + seconds) }

    func setSpeed(_ speed: Double) {
        requestedRate = Float(speed)
        refreshPendingIntentTransport()
        if player.timeControlStatus != .paused { player.rate = requestedRate }
        logTransport("setSpeed")
    }

    /// Live playback position in SOURCE seconds. A resumed remux adds its achieved timeline origin; an
    /// unreadable pre-first-sample clock reports that origin instead of zero, protecting stored progress.
    var playbackPositionSeconds: Double {
        if remuxSeekRemountTarget != nil, let pendingPlaybackIntent {
            return pendingPlaybackIntent.sourceSeconds
        }
        return RemuxResumePolicy.presented(
            playerSeconds: player.currentTime().seconds,
            origin: remuxTimelineOrigin)
    }

    /// Newest source destination owned by an in-flight replacement. Chrome fallback reads this before stop(),
    /// because stop correctly clears every engine transaction and cannot be the point at which resume is derived.
    var pendingRequestedSourcePositionSeconds: Double? {
        if let pendingSeek, pendingSeek.isFinite { return max(0, pendingSeek) }
        return pendingPlaybackIntent?.sourceSeconds
    }

    /// Real (non-guessed) Dolby Vision profile evidence recovered from this session's own local remux, if
    /// one was mounted. `VortXMKVRemuxStream.hlsBuildSignaling` already parses the source's DOVI
    /// configuration record (dv_profile / dv_bl_signal_compatibility_id) and bakes the result into the RFC
    /// 6381 CODECS/SUPPLEMENTAL-CODECS strings this reads back out - the same evidence a libmpv demote
    /// (#148) needs so it stops guessing HDR10 from the bare "is this DV" text flag. The caller must read
    /// this BEFORE stop(), exactly like `pendingRequestedSourcePositionSeconds` above: stop() tears the
    /// remux session down (teardownRemux), and a read after that always sees .unknown.
    var dolbyVisionFallbackInfo: DVPlaybackPolicy.DolbyVisionFallbackInfo {
        guard let signaling = remuxHLSServer?.signaling, signaling.dolbyVision else { return .unknown }
        if signaling.videoCodec.hasPrefix("dvh1.05.") {
            // Profile 5: IPT-only Dolby Vision, no HDR10-compatible base layer.
            return DVPlaybackPolicy.DolbyVisionFallbackInfo(profile: 5, baseLayerHDR10Compatible: false)
        }
        if let supplemental = signaling.supplementalCodec, supplemental.hasSuffix("/db1p") {
            // Profile 8.1 (or a converted Profile 7): db1p is the HDR10/PQ-compatible base-layer brand.
            return DVPlaybackPolicy.DolbyVisionFallbackInfo(profile: 8, baseLayerHDR10Compatible: true)
        }
        // HLG-compatible (8.4, db4h) or unknown compat id: no proven HDR10-safe fallback here. The real
        // gamma=="hlg" decoded-parameter branch in MPVMetalViewController.syncDisplayDynamicRange already
        // handles 8.4 correctly once mpv decodes; guessing here would only risk a wrong pre-probe tag.
        return .unknown
    }

    /// The authoritative source-timeline origin once a remux item is ready. nil distinguishes "not ready yet"
    /// from a ready remux whose input seek genuinely fell back to source second zero.
    var achievedRemuxTimelineOriginSeconds: Double? {
        guard isReady, isRemuxMounted else { return nil }
        return remuxTimelineOrigin
    }

    /// Live audio volume. AVPlayer.volume is a 0...1 gain; map the chrome's 0...100 scale onto it. Muting is
    /// separate (setMuted), so setting a level never un-mutes on its own.
    func setVolume(_ volume0to100: Double) {
        player.volume = Float(max(0, min(100, volume0to100)) / 100)
    }
    func setMuted(_ muted: Bool) { player.isMuted = muted }

    /// Start PiP only when the current controller says it is possible. The state latch suppresses a second
    /// request while AVKit is still deciding, so repeated taps cannot queue duplicate starts.
    @discardableResult
    func startPictureInPicture() -> Bool {
        guard let pictureInPictureController = pipController,
              let generation = pictureInPictureGeneration(for: pictureInPictureController) else { return false }
        refreshPictureInPictureState(for: pictureInPictureController, generation: generation)
        guard case .start(let requestGeneration) = pipState.requestStart(),
              requestGeneration == generation,
              pictureInPictureController.isPictureInPicturePossible,
              !pictureInPictureController.isPictureInPictureActive else { return false }
        pictureInPictureController.startPictureInPicture()
        return true
    }

    /// Stop only the current active controller. Teardown uses the same controller-identity fence and never
    /// trusts a late `didStop` callback from a retired item.
    @discardableResult
    func stopPictureInPicture() -> Bool {
        guard let pictureInPictureController = pipController,
              let generation = pictureInPictureGeneration(for: pictureInPictureController) else { return false }
        refreshPictureInPictureState(for: pictureInPictureController, generation: generation)
        guard case .stop(let requestGeneration) = pipState.requestStop(),
              requestGeneration == generation,
              pictureInPictureController.isPictureInPictureActive else { return false }
        pictureInPictureController.stopPictureInPicture()
        return true
    }

    func stop() {
        invalidateSeekRequests()
        invalidateLoadToken()
        discardPreparedRemuxForNextLoad(reason: "engine-stop")
        externalMountTask?.cancel()
        externalMountTask = nil
        resumeConfiguration.reset()
        currentLoadResumeOrigin = 0
        remuxTimelineOrigin = 0
        itemGeneration &+= 1
        terminalLatch.reset(generation: itemGeneration)
        pendingRemuxGeneration = nil
        #if os(tvOS)
        nativePreAttachTask?.cancel()
        nativePreAttachTask = nil
        nativeDisplayCriteria = nil
        #endif
        hdrFallbackCapabilityRefreshTask?.cancel()
        hdrFallbackCapabilityRefreshTask = nil
        resetPictureInPictureController(for: .engineStop)
        teardownObservers()
        teardownRemux()
        #if os(tvOS)
        // Return the TV from any Dolby Vision display mode this session requested (idempotent no-op when it
        // was not DV; only this lane sets DV criteria, and one engine is live at a time).
        HDRDisplayMode.reset(in: nil)
        #endif
        disableExternalSubtitle(discardingCues: true)   // full teardown: nothing survives the session
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        item = nil
        playbackRequested = false
        usingHDRFallbackItem = false
        pendingPlaybackIntent = nil
        remuxSeekRemountTarget = nil
        audioReplacement = nil
        remuxSourceAudioTracks = []
        remuxSourceSubtitleTracks = []
        selectionTopologyGeneration = nil
        selectedRemuxAudioSourceIndex = nil
        remuxPreferredAudioLanguages = nil
        remuxAudioRejectTerms = nil
        configuredAudioSourceIndex = nil
        hasConfiguredAudioSourceIndex = false
    }

    /// Retire this AVFoundation route for a same-source mpv fallback. The returned receipt stays valid after
    /// `stop()` clears references and acknowledges only when EVERY retiring input producer has unwound.
    func stopForMPVFallback() -> VortXRemuxQuiescenceReceipt {
        var receipts: [VortXRemuxQuiescenceReceipt] = []
        if let server = remuxHLSServer { receipts.append(server.quiescenceReceipt()) }
        if let loader = remuxLoader { receipts.append(loader.quiescenceReceipt()) }
        if let remote = remuxRemoteMount { receipts.append(remote.quiescenceReceipt()) }
        if let pendingRemote = externalMountTerminalRelay {
            receipts.append(VortXRemuxQuiescenceReceipt(terminal: pendingRemote))
        }
        if let prepared = configuredPreparedRemux { receipts.append(prepared.handle.quiescenceReceipt()) }
        let receipt = VortXRemuxQuiescenceReceipt.all(receipts)
        stop()
        return receipt
    }

    /// Tear down the DV-for-MKV remux session (stop the remux thread + the local HLS server / unblock any
    /// waiting loader request). Called before loading a new file and on stop(), so the remux never straddles
    /// two titles.
    private func teardownRemux() {
        remuxLoader?.invalidate()
        remuxLoader = nil
        remuxHLSServer?.invalidate()
        remuxHLSServer = nil
        remuxRemoteMount?.invalidate()
        remuxRemoteMount = nil
        remuxRemoteOpeningGeneration = nil
        remuxRemoteItemGeneration = nil
    }

    // MARK: Video sizing

    func setVideoSize(_ mode: String) {
        videoSizeMode = mode
        UserDefaults.standard.set(mode, forKey: "stremiox.videoSize")
        playerLayer?.videoGravity = Self.gravity(for: mode)
        syncSubtitleVideoInset()   // gravity change moves the picture: re-seat the external-cue overlay over it
    }

    /// Re-seat the external-subtitle overlay above the bottom of the actual picture. `videoRect` reflects the
    /// current gravity synchronously, so the letterbox bar height (host-bottom to picture-bottom) is exact here.
    /// The host view also calls this on layout; this call catches a gravity change that does not trigger a layout.
    private func syncSubtitleVideoInset() {
        guard let layer = playerLayer, let overlay = subtitleOverlay else { return }
        let video = layer.videoRect
        guard video.height > 0, layer.bounds.height > 0 else { return }
        overlay.setVideoBottomInset(max(0, layer.bounds.maxY - video.maxY))
    }
    private static func gravity(for mode: String) -> AVLayerVideoGravity {
        switch mode {
        case "zoom", "fill": return .resizeAspectFill
        case "stretch":      return .resize
        default:             return .resizeAspect   // original: whole frame, keep aspect
        }
    }

    // MARK: Tracks / subtitles (embedded tracks via AVMediaSelection; external subs are a later step)

    /// Track id of the VortX-owned external overlay subtitle. Far above any AVMediaSelectionGroup option
    /// index (a group has a bounded number of options), so the two id spaces cannot
    /// collide and an id from either space routes unambiguously in `setSubtitleTrack`.
    static let externalSubtitleTrackID = 100_000

    func tracks(ofType type: String) -> [MPVTrack] {
        switch type {
        case "audio": return audioTracks
        case "sub":   return subTracks + externalSubtitleTracks()
        default:      return []
        }
    }

    /// The external overlay subtitle as a normal, selectable, tickable row - the same shape libmpv publishes
    /// once it has sub-added a file. Empty when no external subtitle is loaded, so a source with none keeps
    /// exactly its previous list.
    private func externalSubtitleTracks() -> [MPVTrack] {
        guard let label = externalSubLabel else { return [] }
        return [MPVTrack(id: Self.externalSubtitleTrackID, type: "sub",
                         title: label.title, lang: label.lang,
                         selected: externalSubActive, forced: false)]
    }

    private func refreshRemuxSourceAudioTracks() {
        let discovered = remuxHLSServer?.sourceAudioTracks
            ?? remuxRemoteMount?.sourceAudioTracks ?? []
        if !discovered.isEmpty {
            remuxSourceAudioTracks = discovered
            if let actual = remuxHLSServer?.selectedSourceAudioIndex
                ?? remuxRemoteMount?.selectedSourceAudioIndex {
                selectedRemuxAudioSourceIndex = actual
            }
            audioTracks = sourceAudioMPVTracks()
        }
        let subtitles = remuxHLSServer?.sourceSubtitleTracks
            ?? remuxRemoteMount?.sourceSubtitleTracks ?? []
        if !subtitles.isEmpty {
            remuxSourceSubtitleTracks = subtitles
        }
    }

    /// Poll independently of player-time progress so a pause cannot leave the picker on stale cue truth.
    private func startRemuxSubtitleInventoryRefresh(
        for item: AVPlayerItem,
        loadToken: PlayerLoadToken
    ) {
        guard isRemuxMounted else { return }
        remuxSubtitleInventoryRefreshTask?.cancel()
        remuxSubtitleInventoryRefreshTask = Task { @MainActor [weak self, weak item] in
            while let self, let item, !Task.isCancelled,
                  self.owns(item, loadToken: loadToken) {
                self.refreshRemuxSubtitleInventoryIfNeeded()
                try? await Task.sleep(for: Self.remuxSubtitleInventoryRefreshInterval)
            }
        }
    }

    /// Propagate a local-stream or remote-status cue-truth change into the cached picker rows. Source indices
    /// and order are immutable for one mount, so a status glitch cannot replace the established topology. Any
    /// same-topology value change republishes, including unavailable -> available recovery.
    private func refreshRemuxSubtitleInventoryIfNeeded() {
        let discovered = remuxHLSServer?.sourceSubtitleTracks
            ?? remuxRemoteMount?.sourceSubtitleTracks ?? []
        guard !discovered.isEmpty else { return }
        let cachedSourceIndices = remuxSourceSubtitleTracks.map(\.sourceIndex)
        let discoveredSourceIndices = discovered.map(\.sourceIndex)
        guard cachedSourceIndices.isEmpty || cachedSourceIndices == discoveredSourceIndices,
              discovered != remuxSourceSubtitleTracks else { return }
        remuxSourceSubtitleTracks = discovered
        publishSelectionTracks()
    }

    private func sourceSubtitleMPVTracks(item: AVPlayerItem) -> [MPVTrack] {
        let selectedRendition = subGroup.flatMap { Self.selectedIndex(in: $0, item: item) }
        return remuxSourceSubtitleTracks.map { source in
            let cleanTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = cleanTitle.isEmpty
                ? "\(source.codec.uppercased()) | Source \(source.sourceIndex)"
                : "\(cleanTitle) | \(source.codec.uppercased()) | Source \(source.sourceIndex)"
            return MPVTrack(
                id: source.sourceIndex,
                type: "sub",
                title: title,
                lang: source.language,
                selected: !externalSubActive
                    && source.renditionIndex != nil
                    && source.renditionIndex == selectedRendition,
                forced: source.isForced,
                unavailableReason: source.unavailableReason)
        }
    }

    private func nativeSubtitleIndex(forSourceID sourceID: Int) -> Int? {
        remuxSourceSubtitleTracks.first(where: {
            $0.sourceIndex == sourceID && $0.delivery == .webVTT
        })?.renditionIndex
    }

    private func selectedSourceSubtitleID(item: AVPlayerItem) -> Int? {
        guard let selectedRendition = subGroup.flatMap({
            Self.selectedIndex(in: $0, item: item)
        }) else { return nil }
        return remuxSourceSubtitleTracks.first(where: {
            $0.renditionIndex == selectedRendition
        })?.sourceIndex ?? selectedRendition
    }

    /// Capture the single remount-spanning intent immediately before a replacement begins.
    /// Once an intent exists, user transport, seek, audio, and subtitle actions mutate it at their own
    /// entrypoints. Passive recovery capture must therefore return it byte-for-byte: refreshing source time
    /// from a transient replacement-item clock can overwrite an explicit seek made while that item was
    /// loading. A newly created intent already snapshots the current playhead; passive recovery callers must
    /// not rewrite an existing one after capture.
    private func capturePlaybackIntent(from currentItem: AVPlayerItem?) -> PlaybackIntentPolicy.Intent {
        if let intent = pendingPlaybackIntent { return intent }

        let subtitle: PlaybackIntentPolicy.SubtitleSelection
        if externalSubActive {
            subtitle = .external
        } else if let currentItem, subGroup != nil {
            subtitle = selectedSourceSubtitleID(item: currentItem).map {
                .embedded(sourceIndex: $0)
            } ?? .off
        } else {
            subtitle = .unresolved
        }
        let nativeAudio = currentItem.flatMap { current in
            audioGroup.flatMap { Self.selectedIndex(in: $0, item: current) }
        }
        return PlaybackIntentPolicy.Intent(
            sourceSeconds: playbackPositionSeconds,
            playbackRequested: playbackRequested,
            requestedRate: requestedRate,
            audioSelectionKnown: !remuxSourceAudioTracks.isEmpty || audioGroup != nil,
            audioSourceIndex: remuxSourceAudioTracks.isEmpty
                ? nil : selectedRemuxAudioSourceIndex,
            nativeAudioIndex: remuxSourceAudioTracks.isEmpty ? nativeAudio : nil,
            subtitle: subtitle)
    }

    private func sourceAudioMPVTracks() -> [MPVTrack] {
        let identityCounts = Dictionary(
            grouping: remuxSourceAudioTracks,
            by: {
                "\($0.language.lowercased())|\($0.title.lowercased())|\($0.codec.lowercased())|\($0.channels)"
            })
            .mapValues(\.count)
        return remuxSourceAudioTracks.map { source in
            let cleanTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let codec = source.codec.uppercased()
            let delivery: String
            if source.delivery == .transcode {
                delivery = (source.outputCodec.map { " -> \($0.uppercased())" } ?? " -> E-AC3/AAC")
                    + (source.outputChannels.flatMap { $0 > 0 ? " \($0)ch" : nil } ?? "")
            } else {
                delivery = ""
            }
            let shape = "\(codec) \(source.channels)ch\(source.isAtmosJOC ? " Atmos" : "")\(delivery)"
            let identity = "\(source.language.lowercased())|\(source.title.lowercased())|\(source.codec.lowercased())|\(source.channels)"
            let stableSuffix = identityCounts[identity, default: 0] > 1
                ? " | Source \(source.sourceIndex)" : ""
            let title = (cleanTitle.isEmpty ? shape : "\(cleanTitle) | \(shape)") + stableSuffix
            return MPVTrack(
                id: source.sourceIndex,
                type: "audio",
                title: title,
                lang: source.language,
                selected: source.sourceIndex == selectedRemuxAudioSourceIndex)
        }
    }

    private func mountCurrentAudioReplacement(reason: String) {
        guard let replacement = audioReplacement,
              let loadToken = activeLoadToken,
              let url = lastLoadURL else { return }
        selectedRemuxAudioSourceIndex = replacement.targetSourceIndex
        audioTracks = sourceAudioMPVTracks()
        configureResumeOrigin(seconds: replacement.sourceSeconds)
        DiagnosticsLog.log(
            "avplayer",
            "\(reason) source=\(replacement.targetSourceIndex.map(String.init) ?? "default") at \(String(format: "%.3f", replacement.sourceSeconds))s")
        _ = loadFile(
            url,
            headers: lastLoadHeaders,
            live: lastLoadLive,
            audioSidecar: nil,
            reusing: loadToken)
    }

    /// A source choice is secondary to the already working video session. Its first failed mount is therefore
    /// consumed here and replaced once with the previously working/default source at the original source
    /// playhead. A rollback failure returns false so the ordinary fatal path may act, and can never recurse.
    private func recoverAudioReplacementIfNeeded(generation: UInt64, reason: String) -> Bool {
        guard var replacement = audioReplacement else { return false }
        let action = replacement.failureAction(generation: generation)
        audioReplacement = replacement
        switch action {
        case .ignoreStale:
            DiagnosticsLog.log(
                "avplayer",
                "ignored stale audio replacement failure generation=\(generation) current=\(replacement.generation)")
            return true
        case .remountRollback(let sourceIndex, let sourceSeconds):
            selectedRemuxAudioSourceIndex = sourceIndex
            pendingPlaybackIntent?.selectSourceAudio(sourceIndex)
            fatalErrorEmitted = false
            DiagnosticsLog.log(
                "avplayer",
                "audio replacement failed (\(reason)) -> one rollback source=\(sourceIndex.map { String($0) } ?? "default") at \(String(format: "%.3f", sourceSeconds))s")
            mountCurrentAudioReplacement(reason: "audio replacement rollback")
            return true
        case .noFurtherRetry:
            return false
        }
    }

    func setAudioTrack(_ id: Int) {
        guard TrackSelector.shouldApplyAudioSelection(id, to: audioTracks) else { return }
        guard remuxSourceAudioTracks.contains(where: { $0.sourceIndex == id }) else {
            select(id, in: audioGroup)
            return
        }
        if var replacement = audioReplacement {
            guard replacement.targetSourceIndex != id else { return }
            replacement.retarget(to: id)
            audioReplacement = replacement
            var intent = capturePlaybackIntent(from: item)
            intent.selectSourceAudio(id)
            pendingPlaybackIntent = intent
            mountCurrentAudioReplacement(reason: "audio replacement retargeted")
            return
        }
        guard isRemuxMounted,
              id != selectedRemuxAudioSourceIndex,
              let currentItem = item,
              activeLoadToken != nil,
              lastLoadURL != nil else { return }

        var intent = capturePlaybackIntent(from: currentItem)
        intent.selectSourceAudio(id)
        pendingPlaybackIntent = intent
        audioReplacement = RemuxAudioReplacementPolicy.State(
            rollbackSourceIndex: selectedRemuxAudioSourceIndex,
            targetSourceIndex: id,
            sourceSeconds: playbackPositionSeconds)
        mountCurrentAudioReplacement(reason: "audio source selected")
    }
    /// Selecting an embedded/HLS legible track (or turning subtitles Off) also turns OFF any external overlay
    /// sub, so the two never fight or double up. `id < 0` = Off, which the caller uses for the "Off" row.
    /// `externalSubtitleTrackID` re-selects the already-loaded external overlay (its cues stay parsed across a
    /// detour through an embedded track or Off), which is what makes the external row behave like every other
    /// row in the picker instead of being a one-way door.
    func setSubtitleTrack(_ id: Int) {
        let nativeID: Int
        if let source = remuxSourceSubtitleTracks.first(where: { $0.sourceIndex == id }) {
            guard source.unavailableReason == nil,
                  let renditionIndex = source.renditionIndex else {
                DiagnosticsLog.log(
                    "avplayer",
                    "subtitle source \(id) unavailable: \(source.unavailableReason ?? "no text rendition")")
                publishTrackListIfTopologyReady()
                return
            }
            nativeID = renditionIndex
        } else {
            nativeID = id
        }
        if pendingPlaybackIntent != nil {
            var intent = capturePlaybackIntent(from: item)
            if id == Self.externalSubtitleTrackID {
                guard externalSubLabel != nil, subtitleRenderer.hasCues else { return }
                intent.selectExternalSubtitle()
                externalSubActive = true
                subtitleOverlay?.applyStyle()
            } else if id < 0 {
                intent.selectSubtitlesOff()
                disableExternalSubtitle()
            } else {
                // The transaction carries the stable source identity. Group indices belong to one mount.
                intent.selectEmbeddedSubtitle(sourceIndex: id)
                disableExternalSubtitle()
            }
            pendingPlaybackIntent = intent
            publishTrackListIfTopologyReady()
            return
        }
        if id == Self.externalSubtitleTrackID {
            guard externalSubLabel != nil, subtitleRenderer.hasCues else { return }
            if let group = subGroup, let item = player.currentItem {
                item.select(nil, in: group)   // never render an embedded track under the overlay
            }
            externalSubActive = true
            subtitleOverlay?.applyStyle()
            updateSubtitleOverlay(atClock: player.currentTime().seconds)
            publishSelectionTracks()
            return
        }
        let wasExternal = externalSubActive
        if wasExternal { disableExternalSubtitle() }
        select(nativeID, in: subGroup)
        // A source with no legible renditions has no group, so `select` returns before publishing. Turning the
        // overlay off there still changed which row is ticked, so publish it directly.
        if wasExternal, subGroup == nil { publishSelectionTracks() }
    }

    /// Select option `id` (its index in the group) on the current item, or deselect for mpv's -1 = off.
    ///
    /// The cached track views are refreshed on EVERY call, settled or not. AVFoundation applies an HLS
    /// rendition switch asynchronously (the item refetches the rendition's playlist first), so
    /// `currentMediaSelection` can still report the previous option on return; the pre-fix early return then
    /// left the cached rows carrying their OLD selected flags, and the chrome's re-read a quarter second later
    /// silently reverted the viewer's tick with the stream buffering behind it - the field report "I click it,
    /// the stream buffers and nothing changes". A short re-read publishes the settled state when it lands, and
    /// the system's own selection-change notification remains the authoritative backstop.
    private func select(_ id: Int, in group: AVMediaSelectionGroup?) {
        guard let group, let item = player.currentItem else { return }
        let requested: AVMediaSelectionOption?
        if id < 0 {
            requested = nil
        } else {
            guard id < group.options.count else { return }
            requested = group.options[id]
        }
        item.select(requested, in: group)
        refreshSelectionTracks(for: item)
        guard item.currentMediaSelection.selectedMediaOption(in: group) != requested else { return }
        DiagnosticsLog.log(
            "player",
            "media selection not settled synchronously (group=\(group.options.count) options, requested=\(requested?.displayName ?? "off")); re-reading")
        scheduleSelectionSettleRead(for: item)
    }

    /// Re-read AVPlayer's authoritative selection a few times over the next couple of seconds, so a rendition
    /// switch that settles after `select` returns still reaches the chrome even if the system notification is
    /// coalesced away. Cheap and bounded; each read publishes only on a real change.
    private func scheduleSelectionSettleRead(for item: AVPlayerItem) {
        for delay in [0.3, 0.8, 1.6, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                self.refreshSelectionTracks(for: item)
            }
        }
    }

    /// The overlay host (in `AVPlayerEngineView`) installs its subtitle overlay here so the engine can push the
    /// active cue into it from the periodic time observer. Weak: the host view owns the overlay's lifetime.
    func attachSubtitleOverlay(_ overlay: SubtitleOverlayView) {
        subtitleOverlay = overlay
        overlay.setText(nil)
    }

    /// Load an EXTERNAL srt/vtt subtitle (add-on or community-pooled) and render it ourselves over the
    /// AVPlayerLayer. AVFoundation cannot side-load or time-shift an external SRT, so we: download the file
    /// (reusing the shared subtitle cache/session + 12s timeout + one retry), parse it into timed cues, load
    /// them into the renderer, and drive the overlay from the player clock. Turning this on hides any
    /// AVPlayer-native legible track so subtitles never double up. `completion(true)` once cues are loaded.
    func addExternalSubtitle(url: String, title: String, lang: String,
                             timeout: TimeInterval, completion: ((Bool) -> Void)?) {
        guard let remote = URL(string: url),
              let requestToken = activeLoadToken,
              let requestItem = item,
              owns(requestItem, loadToken: requestToken) else {
            completion?(false)
            return
        }
        let finish: (Bool) -> Void = { ok in DispatchQueue.main.async { completion?(ok) } }
        SubtitleFileFetcher.fetch(remote, timeout: timeout) { [weak self] data in
            guard let data else { finish(false); return }
            let cues = SubtitleCueRenderer.parse(data: data)
            guard !cues.isEmpty else { finish(false); return }
            Task { @MainActor in
                guard let self,
                      self.owns(requestItem, loadToken: requestToken) else {
                    finish(false)
                    return
                }
                self.subtitleRenderer.load(cues: cues)
                self.externalSubActive = true
                self.externalSubLabel = (title: title, lang: lang)
                // Turn off any embedded/HLS legible track so we don't render two subtitle streams at once.
                if let group = self.subGroup, let item = self.player.currentItem {
                    item.select(nil, in: group)
                }
                self.subtitleOverlay?.applyStyle()
                self.updateSubtitleOverlay(atClock: self.player.currentTime().seconds)
                // Publish unconditionally: the external row is now part of the track list, so the picker must
                // learn about it whether or not the native deselect changed a group index.
                self.publishSelectionTracks()
                finish(true)
            }
        }
    }

    /// Stop rendering the external overlay subtitle. Native track selection is untouched, so the caller can
    /// then select an embedded track or leave subtitles Off.
    ///
    /// `discardingCues: false` (the selection path) KEEPS the parsed cues and the published row, exactly as
    /// libmpv keeps a sub-added file in its track list after you switch to Off: the viewer can come back to it
    /// from the picker. Dropping the row here instead would make an add-on subtitle a one-way door, because
    /// the chrome has already hidden that add-on's own row (it lives in `addedSubURLs`) on the promise that
    /// the subtitle re-appears in the ordinary track list. `discardingCues: true` is the title-change reset.
    private func disableExternalSubtitle(discardingCues: Bool = false) {
        externalSubActive = false
        subtitleOverlay?.setText(nil)
        guard discardingCues else { return }
        externalSubLabel = nil
        subtitleRenderer.clear()
    }

    /// AVFoundation cannot time-shift native embedded/HLS legible renditions. Only the VortX-owned external
    /// cue renderer consumes `setSubDelay`, so the chrome must gate its Sync controls on this live capability.
    var subtitleDelayAvailable: Bool { externalSubActive }

    /// Manual subtitle sync in seconds (positive = subtitles appear LATER, matching libmpv `sub-delay`). Applied
    /// as the renderer's offset, so the change is live: the next overlay update uses the new offset immediately.
    func setSubDelay(_ seconds: Double) {
        subtitleRenderer.offset = seconds
        if externalSubActive { updateSubtitleOverlay(atClock: player.currentTime().seconds) }
    }
    /// No-op: AVFoundation exposes no audio-track time offset (unlike libmpv `audio-delay`). The chrome hides
    /// the audio-sync rows when this engine is active, so this is never reached from the UI on the AVPlayer path.
    func setAudioDelay(_ seconds: Double) {}
    /// Re-apply the user's subtitle appearance (size / colour / background). The VortX-owned external-cue
    /// overlay gets full styling; AVPlayer-NATIVE (embedded / HLS legible) tracks get best-effort styling via
    /// `AVTextStyleRule` (coarser than libass, but honours the same size / colour / background choices).
    func applySubtitleStyle() {
        subtitleOverlay?.applyStyle()
        applyEmbeddedSubtitleTextStyle()
    }

    /// Best-effort styling for AVPlayer-native subtitle tracks (P5, #76). AVFoundation exposes only a coarse
    /// text-markup surface (relative font size + fg/bg colour) via `AVTextStyleRule`, far short of libass, and
    /// only for text-based legible tracks, so this is honest best-effort, not full parity. Reads the SAME
    /// `SubtitleStyle` keys the libmpv path uses. Fail-soft: a nil rule just leaves the system default styling.
    private func applyEmbeddedSubtitleTextStyle() {
        guard let item = player.currentItem else { return }
        var attrs: [String: Any] = [:]
        if let fg = Self.argbComponents(fromHex: SubtitleStyle.colorHex) {
            attrs[kCMTextMarkupAttribute_ForegroundColorARGB as String] = fg
        }
        attrs[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] =
            Self.backgroundARGB(SubtitleStyle.backgroundId)
        // Named base sizes (40 / 55 / 72 / 92 libass px on a ~720 canvas) mapped to a percentage of video
        // height: Medium ~= 5%, scaling linearly, so the Smaller/Larger steps visibly change AVPlayer subs too.
        let pct = max(2.0, min(12.0, Double(SubtitleStyle.fontSize) / 11.0))
        attrs[kCMTextMarkupAttribute_BaseFontSizePercentageRelativeToVideoHeight as String] = pct
        item.textStyleRules = AVTextStyleRule(textMarkupAttributes: attrs).map { [$0] }
    }

    /// Parse a `#RRGGBB` hex string into the [alpha, red, green, blue] 0...1 component array
    /// `kCMTextMarkupAttribute_ForegroundColorARGB` expects (opaque alpha). nil on a malformed string.
    private static func argbComponents(fromHex hex: String) -> [Double]? {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return [1.0, r, g, b]
    }

    /// The [alpha, red, green, blue] background colour for the named background style (mirrors the libmpv
    /// `sub-back-color`): outline = transparent, shaded = ~50% black, box = opaque black.
    private static func backgroundARGB(_ id: String) -> [Double] {
        switch id {
        case "shaded": return [0.5, 0, 0, 0]
        case "box":    return [1.0, 0, 0, 0]
        default:       return [0.0, 0, 0, 0]   // outline only: transparent background
        }
    }
    /// The current external-subtitle delay in seconds, so the sync-capture path can pool the learned offset.
    func currentSubDelaySeconds() -> Double { subtitleRenderer.offset }

    /// Push the cue that should be visible at player clock time `clock` into the overlay (nil hides it). No-op
    /// when no external sub is loaded, so native/embedded subtitle selection is never disturbed.
    private func updateSubtitleOverlay(atClock clock: Double) {
        guard externalSubActive else { return }
        subtitleOverlay?.setText(subtitleRenderer.activeText(atClock: clock))
    }

    // MARK: Chapters / media info

    /// Asset chapter markers, populated async once the item is ready (see `loadChapters`). Empty until then
    /// and for assets that carry none, so the Chapters panel simply shows nothing.
    func chapters() -> [MPVChapter] { loadedChapters }

    /// Encoded video height (so the chrome's metadata line can label "4K" / "1080p") and the active audio
    /// codec name. Height comes from the item's presentation size (its decoded frame dimensions); the codec
    /// from the selected audible option's media format. Both are best-effort and empty before the item loads.
    func mediaSummary() -> (width: Int, height: Int, audioCodec: String, audioChannels: Int) {
        let size = item?.presentationSize ?? .zero
        return (
            width: Int(size.width),
            height: Int(size.height),
            audioCodec: selectedAudioCodec(),
            audioChannels: selectedAudioChannels())
    }

    /// Video frame rate for the community-subtitle release fingerprint (Gap 8). The libmpv engine reads the
    /// container-declared fps; AVFoundation surfaces the same via the video track's `nominalFrameRate`, loaded
    /// asynchronously at readyToPlay (see `loadContainerFrameRate`) and cached here. 0 until it resolves (and
    /// for an HLS asset, which reports no AVAssetTrack objects), which the fingerprint tolerates and rebuilds.
    func containerFrameRate() -> Double { containerFPS }

    /// Live playback stats from AVFoundation's access log (the only per-stream telemetry AVPlayer exposes):
    /// the negotiated + observed bitrates and the indicated resolution. Empty before playback or when the log
    /// has no events yet.
    func playbackStats() -> [(String, String)] {
        guard let event = item?.accessLog()?.events.last else { return [] }
        var rows: [(String, String)] = []
        let h = Int(item?.presentationSize.height ?? 0)
        if h > 0 { rows.append(("Resolution", "\(Int(item?.presentationSize.width ?? 0))×\(h)")) }
        if event.indicatedBitrate > 0 { rows.append(("Stream bitrate", bitrateString(event.indicatedBitrate))) }
        if event.observedBitrate > 0 { rows.append(("Observed bitrate", bitrateString(event.observedBitrate))) }
        if event.numberOfStalls > 0 { rows.append(("Stalls", "\(event.numberOfStalls)")) }
        return rows
    }

    private func bitrateString(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
            : String(format: "%.0f kbps", bitsPerSecond / 1_000)
    }

    /// The codec four-char-code of the selected audible option, lowercased to read like the libmpv codec
    /// names the metadata line already shows (e.g. "ec-3", "aac"). Empty when nothing is resolvable yet.
    private func selectedAudioCodec() -> String {
        if let selectedRemuxAudioSourceIndex,
           let source = remuxSourceAudioTracks.first(where: {
               $0.sourceIndex == selectedRemuxAudioSourceIndex
           }) {
            return source.activeCodec.lowercased()
        }
        guard let item = player.currentItem, let group = audioGroup,
              let option = item.currentMediaSelection.selectedMediaOption(in: group),
              let format = option.mediaSubTypes.first else { return "" }
        // mediaSubTypes is [NSNumber] of FourCharCodes; a FourCharCode is four ASCII bytes (high byte first).
        let code = format.uint32Value
        var chars = ""
        for shift in [24, 16, 8, 0] {
            let byte = UInt8(truncatingIfNeeded: code >> UInt32(shift))
            if byte > 32 { chars.append(Character(UnicodeScalar(byte))) }
        }
        return chars.lowercased()
    }

    /// Produced primary channel count for the selected remux row. A prior host that identifies a transcode but
    /// omits outputChannels stays unknown (0), while a fully legacy stream-copy row safely falls back to source.
    private func selectedAudioChannels() -> Int {
        guard let selectedRemuxAudioSourceIndex,
              let source = remuxSourceAudioTracks.first(where: {
                  $0.sourceIndex == selectedRemuxAudioSourceIndex
              }) else { return 0 }
        return source.activeChannels ?? 0
    }

    /// Load asset chapter markers off the main thread, then cache them and re-emit track-list so the chrome
    /// re-pulls `chapters()`. Cheap (a metadata read), and a no-chapter asset just yields []. Mirrors the
    /// async pattern of `loadSelectionGroups`.
    private func loadChapters() {
        guard let item = player.currentItem else { return }
        // DV remux lane (Gap 3): the served fMP4/HLS carries no chapter metadata, but the remux stream read the
        // source MKV's libav chapter list at open (same window as the source duration, which is already ready
        // here). Pull those directly; `loadChapterMetadataGroups` on the local HLS playlist would return none.
        if isRemuxMounted {
            let remuxChapters = remuxHLSServer?.chapters
                ?? remuxRemoteMount?.chapters ?? remuxLoader?.chapters ?? []
            if !remuxChapters.isEmpty {
                loadedChapters = remuxChapters
                    .map { MPVChapter(title: $0.title, start: $0.start) }
                    .sorted { $0.start < $1.start }
                publishTrackListIfTopologyReady()
            }
            return
        }
        let asset = item.asset
        Task { @MainActor in
            let locale = Locale.current
            let groups = (try? await asset.loadChapterMetadataGroups(
                bestMatchingPreferredLanguages: locale.language.languageCode.map { [$0.identifier] } ?? [])) ?? []
            guard player.currentItem === item else { return }   // a newer file loaded meanwhile
            var chapters: [MPVChapter] = []
            for group in groups {
                let start = group.timeRange.start.seconds
                guard start.isFinite else { continue }
                let titleItem = group.items.first { $0.commonKey == .commonKeyTitle }
                let title = (try? await titleItem?.load(.stringValue)) ?? nil
                chapters.append(MPVChapter(title: title ?? "", start: start))
            }
            guard player.currentItem === item else { return }
            loadedChapters = chapters.sorted { $0.start < $1.start }
            if !loadedChapters.isEmpty { publishTrackListIfTopologyReady() }
        }
    }

    /// HDR/DV metadata chip (Gap 7). The chrome lights its "HDR" chip off `MPVProperty.videoParamsSigPeak > 1.0`
    /// (a libmpv-only signal); AVPlayer exposes no sig-peak, so the chip never lit on the AVPlayer lane. Emit an
    /// equivalent > 1.0 peak when the content is HDR: DV is HDR by definition (`contentIsDolbyVision`), and a
    /// native HDR10 / HLG track is detected from its video format description's transfer function. SDR content
    /// emits nothing, so the chip correctly stays off. Any value > 1.0 works; 4.0 is a representative peak.
    private func emitDynamicRange(_ item: AVPlayerItem) {
        if contentIsDolbyVision {
            emit(MPVProperty.videoParamsSigPeak, 4.0)
            return
        }
        // Native (non-HLS) HDR10 / HLG: probe the video track transfer function off the main thread, then emit.
        // An HLS asset reports no AVAssetTrack objects, so this is a no-op there (its HDR chip stays off; the
        // access-log playbackStats still describe the stream). Identity-guarded like loadChapters.
        let asset = item.asset
        Task { @MainActor in
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            guard player.currentItem === item else { return }
            for track in tracks {
                let descs = (try? await track.load(.formatDescriptions)) ?? []
                guard player.currentItem === item else { return }
                for desc in descs {
                    guard let tf = CMFormatDescriptionGetExtension(
                        desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String else { continue }
                    if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                        || tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
                        self.emit(MPVProperty.videoParamsSigPeak, 4.0)
                        return
                    }
                }
            }
        }
    }

    /// Load the video track's nominal frame rate off the main thread and cache it for `containerFrameRate()`
    /// (Gap 8), using the non-deprecated async `load(.nominalFrameRate)`. No-op for HLS (no AVAssetTrack
    /// objects) and identity-guarded like loadChapters, so a later load never sees a stale value.
    private func loadContainerFrameRate(_ item: AVPlayerItem) {
        let asset = item.asset
        Task { @MainActor in
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            guard player.currentItem === item else { return }
            for track in tracks {
                let fps = (try? await track.load(.nominalFrameRate)) ?? 0
                guard player.currentItem === item else { return }
                if fps > 0 { containerFPS = Double(fps); return }
            }
        }
    }

    // MARK: Decode / audio routing (AVFoundation-managed; no-ops on this engine)

    func setHardwareDecoding(_ on: Bool) {}
    var hardwareDecoding: Bool { true }
    func setAudioOutputMode(_ mode: AudioOutputMode) {}

    // MARK: Trickplay / HDR

    func captureFrameJPEGData(maxWidth: CGFloat, completion: @escaping (Data?) -> Void) {
        guard let output = videoOutput else { completion(nil); return }
        let time = player.currentTime()
        // Protected (FairPlay) or not-yet-rendered frames return nil here; fail soft (skip this capture tick).
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            completion(nil); return
        }
        let ctx = captureContext
        // Downscale + JPEG-encode off the main thread; CVPixelBuffer and CIContext are safe to hand off.
        DispatchQueue.global(qos: .utility).async {
            let data = Self.encodeJPEG(from: pixelBuffer, maxWidth: maxWidth, context: ctx)
            DispatchQueue.main.async { completion(data) }
        }
    }

    /// CVPixelBuffer (BGRA) -> downscaled JPEG via ImageIO (cross-platform; no UIKit/AppKit dependency).
    private static func encodeJPEG(from pixelBuffer: CVPixelBuffer, maxWidth: CGFloat, context: CIContext) -> Data? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let width = ci.extent.width
        guard width > 0, ci.extent.height > 0 else { return nil }
        let scale = min(1, maxWidth / width)
        let image = scale < 1 ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality as String: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
    /// AVPlayerLayer negotiates HDR/DV with the display itself, so there is no app-driven HDR toggle here.
    var hdrAvailable: Bool { false }

    func setOrientation(landscape: Bool) {}   // the hosting view controller drives device orientation

    // MARK: Rendering hand-off + PiP

    /// The AVPlayerLayer host calls this once its layer exists, so video gravity + PiP bind to the live layer.
    func attachLayer(_ layer: AVPlayerLayer) {
        if let previousLayer = playerLayer, previousLayer !== layer {
            resetPictureInPictureController(for: .layerReplacement)
        }
        playerLayer = layer
        layer.videoGravity = Self.gravity(for: videoSizeMode)
        installPictureInPictureController(on: layer)
    }

    private func installPictureInPictureController(on layer: AVPlayerLayer) {
        guard pipController == nil else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            pipState.attach(supported: false, possible: false, active: false)
            publishPictureInPictureState()
            return
        }
        guard let pictureInPictureController = AVPictureInPictureController(playerLayer: layer) else {
            pipState.attach(supported: false, possible: false, active: false)
            publishPictureInPictureState()
            return
        }
        pictureInPictureController.delegate = self
        // Allow AVKit to enter PiP automatically when this inline layer backgrounds. Explicit starts still go
        // through startPictureInPicture(), so the manual button and automatic entry share the same state truth.
        #if os(iOS)
        pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        pipController = pictureInPictureController
        let generation = pipState.attach(
            supported: true,
            possible: pictureInPictureController.isPictureInPicturePossible,
            active: pictureInPictureController.isPictureInPictureActive)
        publishPictureInPictureState()
        observePictureInPicture(pictureInPictureController, generation: generation)
    }

    /// Retire every KVO/delegate edge only when its owning engine or physical layer is going away. The old
    /// controller is stopped after its delegate is cleared, so a late AVKit callback cannot revive state.
    private func resetPictureInPictureController(for event: AVPlayerPictureInPictureOwnershipEvent) {
        guard event.invalidatesController else { return }
        let retiredController = pipController
        let shouldStop = retiredController?.isPictureInPictureActive == true || pipState.isTransitioning
        pipObservations.forEach { $0.invalidate() }
        pipObservations.removeAll()
        retiredController?.delegate = nil
        pipController = nil
        pipState.invalidate()
        publishPictureInPictureState()
        if shouldStop { retiredController?.stopPictureInPicture() }
    }

    private func publishPictureInPictureState() {
        isPictureInPicturePossible = pipState.isAvailable
        isPictureInPictureActive = pipState.isActive
        pictureInPictureTransition = pipState.transition
    }

    private func pictureInPictureGeneration(
        for pictureInPictureController: AVPictureInPictureController
    ) -> UInt64? {
        guard pipController === pictureInPictureController, pipState.isSupported else { return nil }
        return pipState.generation
    }

    private func refreshPictureInPictureState(
        for pictureInPictureController: AVPictureInPictureController,
        generation: UInt64
    ) {
        guard pipController === pictureInPictureController,
              pipState.observe(
                possible: pictureInPictureController.isPictureInPicturePossible,
                active: pictureInPictureController.isPictureInPictureActive,
                generation: generation) else { return }
        publishPictureInPictureState()
    }

    private func observePictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController,
        generation: UInt64
    ) {
        let possible = pictureInPictureController.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]) { [weak self] observedController, _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          let callbackGeneration = self.pictureInPictureGeneration(for: observedController),
                          callbackGeneration == generation else { return }
                    self.refreshPictureInPictureState(
                        for: observedController,
                        generation: generation)
                }
            }
        let active = pictureInPictureController.observe(
            \.isPictureInPictureActive,
            options: [.initial, .new]) { [weak self] observedController, _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          let callbackGeneration = self.pictureInPictureGeneration(for: observedController),
                          callbackGeneration == generation else { return }
                    self.refreshPictureInPictureState(
                        for: observedController,
                        generation: generation)
                }
            }
        pipObservations.append(contentsOf: [possible, active])
    }

    // MARK: Observation -> MPVProperty events

    private func owns(_ item: AVPlayerItem, loadToken: PlayerLoadToken) -> Bool {
        PlayerLoadProvenanceState.acceptsAVCallback(
            callbackToken: loadToken,
            activeToken: activeLoadToken,
            capturedItemIsCurrent: self.item === item && player.currentItem === item
        )
    }

    private func observe(_ item: AVPlayerItem, loadToken: PlayerLoadToken) {
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            Task { @MainActor in self?.handleStatus(observedItem, loadToken: loadToken) }
        })
        observations.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self, self.owns(observedItem, loadToken: loadToken) else { return }
                self.emit(
                    MPVProperty.pausedForCache, observedItem.isPlaybackBufferEmpty,
                    loadToken: loadToken
                )
            }
        })
        observations.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self, observedItem.isPlaybackLikelyToKeepUp,
                      self.owns(observedItem, loadToken: loadToken) else { return }
                self.emit(MPVProperty.pausedForCache, false, loadToken: loadToken)
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, self.owns(item, loadToken: loadToken) else { return }
                // Diagnostic: a player stuck at .waitingToPlayAtSpecifiedRate (2) with a buffering wait-reason
                // is the "mounts but never plays" signature; logging the reason pinpoints it in one test.
                DiagnosticsLog.log("avplayer", "timeControlStatus=\(player.timeControlStatus.rawValue) waitReason=\(player.reasonForWaitingToPlay?.rawValue ?? "none")")
                // AUTO-RESUME GUARD. The DV / remux lane is served to AVPlayer as a LIVE, indefinite-duration
                // HLS (a sliding window with no EXT-X-ENDLIST) with automaticallyWaitsToMinimizeStalling on, and
                // AVFoundation does not honor an indefinite user pause on a live item: after roughly a forward-
                // buffer window it leaves .paused on its own to track the growing edge, and nothing else re-
                // pauses it, so a deliberately paused title silently resumes about a minute later. `playbackRequested`
                // is the user's committed transport intent, false ONLY when the viewer (or an explicit Now Playing
                // pause) asked to stop; when it is false a departure from .paused was never requested, so re-assert
                // the pause. This can only ever CANCEL an unrequested resume: a genuine play() sets
                // playbackRequested = true BEFORE it moves the rate, so an intended resume - and the ordinary
                // .waitingToPlayAtSpecifiedRate buffering that precedes intended playback - is never touched.
                // Return before the state emit so the chrome never flashes a buffering / playing blip: the pause
                // settles and this observer re-fires at .paused, republishing the already-correct paused state.
                if !self.playbackRequested, player.timeControlStatus != .paused {
                    player.pause()
                    DiagnosticsLog.log("avplayer", "re-asserted user pause: AVPlayer left .paused (tcs=\(player.timeControlStatus.rawValue) waitReason=\(player.reasonForWaitingToPlay?.rawValue ?? "none")) while transport intent was paused")
                    return
                }
                // Mirror the transport state + buffering wait into the probe so the heartbeat is meaningful
                // on the AVPlayer path (DV / HLS). waitingToPlayAtSpecifiedRate is AVPlayer's "buffering".
                let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                let stateText = player.timeControlStatus == .paused ? "paused"
                    : (waiting ? "buffering" : "playing")
                VXProbeState.shared.setPlayer(state: stateText, engine: "avplayer", buffering: waiting)
                // Progress-proven stall telemetry (root-cause report section 2): a start fires only on the
                // idle -> waiting edge, and a wait-reason change (buffering-rate -> minimize-stalls etc.)
                // updates the SAME episode without a second start. `.paused`/`.playing` never end it here -
                // only proven media-clock progress does, in the periodic time observer below.
                if waiting {
                    let baseline = player.currentTime().seconds
                    switch self.stallEpisode.enteredWaiting(
                        reason: player.reasonForWaitingToPlay,
                        position: baseline.isFinite ? baseline : 0
                    ) {
                    case .started:
                        VXProbe.event("player", "stall start")
                    case .reasonChanged, .none, .ended:
                        break
                    }
                }
                self.emit(
                    MPVProperty.pausedForCache, waiting,
                    loadToken: loadToken
                )
                // The KVO is no longer the sole producer of the pause state: play()/pause() publish the
                // committed intent optimistically so the OSD flips on the press. Echoing the raw status while
                // a replacement is in flight would FIGHT that emit, because a remounting player legitimately
                // sits at rate 0 / .paused while the user's intent is PLAYING, and the glyph would flick back.
                // Publish the observed status only when it AGREES with the committed intent, or when no
                // replacement is outstanding (the steady state, where the status IS the truth: a system pause,
                // an interruption, or an end-of-item stop). The two producers can therefore never oscillate.
                let observedPaused = player.timeControlStatus == .paused
                let replacementInFlight =
                    self.pendingPlaybackIntent != nil || self.remuxSeekRemountTarget != nil
                if !replacementInFlight || observedPaused == !self.playbackRequested {
                    self.emit(
                        MPVProperty.pause, observedPaused,
                        loadToken: loadToken
                    )
                }
            }
        })
        // ~4 Hz, matching the libmpv controller's coalesced time-pos cadence. Delivered on .main, so it runs
        // synchronously on the main actor (no extra Task hop that could fire after teardown nils the observer).
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.timeObserver != nil,
                      self.owns(item, loadToken: loadToken) else { return }
                // Cheap, every tick: the play head (scrubber smoothness) and the subtitle overlay clock. These
                // must stay at the full 0.25s cadence or the progress bar and external subs visibly lag.
                let position = RemuxResumePolicy.presented(
                    playerSeconds: time.seconds,
                    origin: self.remuxTimelineOrigin)
                self.emit(
                    MPVProperty.timePos,
                    PlayerTimePositionEvent(seconds: position, loadToken: loadToken),
                    loadToken: loadToken
                )
                self.updateSubtitleOverlay(atClock: position)   // sync external-sub overlay to source time
                // Proven-progress stall-episode end (root-cause report section 2): the raw AVPlayer clock, in
                // the SAME seconds space the KVO handler above baselined the episode against. `.paused`/
                // `.playing` transitions never end the episode on their own; only actual forward movement of
                // this clock does.
                if case .ended = self.stallEpisode.mediaAdvanced(to: time.seconds) {
                    VXProbe.event("player", "stall end")
                }
                // Gate the two EXPENSIVE side effects (the NSLock probe write and the loadedTimeRanges scan)
                // behind the same PerformanceMode-scaled interval the libmpv path uses (0.5s reduced, else
                // 0.25s), so a constrained device is not doing an unconditional lock + O(ranges) loop 4x/sec.
                let clock = ProcessInfo.processInfo.systemUptime
                self.pinPreferredPeakBitRateAfterFirstFrame(item, atClock: time.seconds)
                // AUDIO-OVER-BLACK probe (native DV lane only). Two boolean guards once latched/off-route,
                // so the non-DV steady state pays nothing (see checkAudioOverBlackWatchdog).
                self.checkAudioOverBlackWatchdog(clock: clock, position: time.seconds)
                let minInterval = PerformanceMode.reduced ? 0.5 : 0.25
                // Push the play head (and duration when known) into the probe, throttled.
                if clock - self.lastProbeEmit >= minInterval {
                    self.lastProbeEmit = clock
                    // A10-iii: on a remux mount item.duration is only the LOCAL served playlist window (e.g.
                    // 1305s), not the true source, so feed the probe the retained full source duration so the
                    // heartbeat's pos/dur reflects the real title. Keep item.duration for genuine partial/live HLS.
                    let sourceDuration: Double? = self.isRemuxMounted
                        ? (self.remuxHLSServer?.sourceDurationSeconds
                            ?? self.remuxRemoteMount?.sourceDurationSeconds
                            ?? self.remuxLoader?.sourceDurationSeconds)
                        : nil
                    let dur = sourceDuration ?? (self.item?.duration.seconds ?? 0)
                    VXProbeState.shared.setPlayer(pos: position.isFinite ? Int(position) : 0,
                                                  dur: dur.isFinite && dur > 0 ? Int(dur) : nil,
                                                  engine: "avplayer")
                }
                // YouTube-style buffered-ahead edge: the end of the loaded range that CONTAINS the playhead
                // (AVPlayer reports one or more loaded ranges). Emitting the same key libmpv uses lets the
                // scrubber render the grey band identically on both engines. Fail-soft: no matching range -> 0.
                // Throttled to match libmpv, which already caps demuxerCacheTime at 0.5s.
                if clock - self.lastCacheEmit >= minInterval, let item = self.item {
                    self.lastCacheEmit = clock
                    let now = time.seconds
                    var aheadEdge = 0.0
                    for value in item.loadedTimeRanges {
                        let r = value.timeRangeValue
                        let start = r.start.seconds, end = (r.start + r.duration).seconds
                        guard start.isFinite, end.isFinite else { continue }
                        if now >= start - 1 && now <= end { aheadEdge = max(aheadEdge, end) }
                    }
                    if aheadEdge > 0 {
                        self.emit(
                            MPVProperty.demuxerCacheTime,
                            RemuxResumePolicy.presented(
                                playerSeconds: aheadEdge,
                                origin: self.remuxTimelineOrigin),
                            loadToken: loadToken)
                    }
                }
            }
        }
        // The DV/remux playhead receipt, on its own serial queue. `reportPlaybackPosition` is a lock-guarded
        // (VortXRemuxHLSServer.swift:387-391) write of one Double into a struct that itself refuses samples
        // while a seek is pending (VortXHLSSeekAnchorState.swift:16-22), so it is safe off the main actor and
        // cannot reorder ahead of a seek destination. The server is bound weakly HERE rather than read through
        // `self` each tick because `self` is @MainActor-isolated: `remuxHLSServer` is assigned exactly once per
        // load (in load(), before this attach point), so the binding is the same object the main-queue block
        // used to reach. A no-remux mount captures nil and the block is a no-op, matching the old `?.` behaviour.
        playheadObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: playheadQueue
        ) { [weak remuxServer = remuxHLSServer] time in
            remuxServer?.reportPlaybackPosition(playerSeconds: time.seconds)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didPlayToEnd(_:)),
                                               name: .AVPlayerItemDidPlayToEndTime, object: item)
        NotificationCenter.default.addObserver(self, selector: #selector(failedToEnd(_:)),
                                               name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaSelectionDidChange(_:)),
                                               name: AVPlayerItem.mediaSelectionDidChangeNotification,
                                               object: item)
        startRemuxSubtitleInventoryRefresh(for: item, loadToken: loadToken)
        #if canImport(UIKit)
        // Jetsam relief (mirrors MPVMetalViewController.shedForMemoryPressure): a paused AVPlayer keeps
        // filling its forward buffer at its own discretion, and a 4K / DV-remux HLS stream buffers
        // hundreds of MB; on tvOS the pause also lets the screensaver (its own 4K pipeline) start on
        // top, and jetsam reaps this app. The memory warning is the system's last call before that;
        // respond by capping the item's forward buffer so AVFoundation trims instead of being killed.
        // Registered per-load because teardownObservers() drops every observer on this object.
        NotificationCenter.default.addObserver(self, selector: #selector(handleMemoryWarningNote),
                                               name: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil)
        #endif
    }

    #if canImport(UIKit)
    /// System memory warning: lower the current item's forward buffer to its phase cap (default 0 = "system
    /// decides", which on a high-bitrate stream is far too generous for a jetsam-bound app). Never increase an
    /// explicit smaller duration: that would undo the startup tester precisely while the system asks for relief.
    /// Sticky for the rest of this item; the next loadFile mints a fresh item with its phase's normal value.
    @objc private func handleMemoryWarningNote() {
        guard let item,
              let replacement = VortXRemuxForwardBufferPolicy.memoryWarningReplacementDuration(
                  currentDuration: item.preferredForwardBufferDuration,
                  mount: forwardBufferMount,
                  hasProducedFirstFrame: videoFrameEverProduced) else { return }
        item.preferredForwardBufferDuration = replacement
        DiagnosticsLog.log(
            "avplayer",
            "memory warning: preferredForwardBufferDuration capped to \(Int(replacement))s")
    }
    #endif

    private func handleRemuxStartupTimeout(_ timedOutServer: VortXRemuxHLSServer,
                                           loadToken: PlayerLoadToken) {
        guard remuxHLSServer === timedOutServer,
              activeLoadToken == loadToken,
              !isReady,
              !fatalErrorEmitted,
              !terminalLatch.hasEmitted else { return }
        if recoverAudioReplacementIfNeeded(
            generation: itemGeneration,
            reason: "local remux startup timeout") {
            return
        }
        guard terminalLatch.claim(generation: itemGeneration) else { return }
        fatalErrorEmitted = true
        DiagnosticsLog.log(
            "dv", "HLS mount-to-ready deadline expired -> endFileError demote")
        emit(
            MPVProperty.endFileError,
            "HLS remux did not become ready within 30 seconds",
            loadToken: loadToken)
    }

    private func handleStatus(_ item: AVPlayerItem, loadToken: PlayerLoadToken) {
        guard owns(item, loadToken: loadToken) else { return }
        switch item.status {
        case .readyToPlay:
            // A recovery item reuses a mount that already crossed its one-time ready edge. Calling the local
            // deadline transition again returns false by design and would strand the fresh item before play.
            remuxRemoteMount?.markEngineReady()
            if let server = remuxHLSServer {
                let accepted = server.markEngineReady()
                if !DVPlaybackPolicy.acceptsRemuxReady(
                    transitionAccepted: accepted,
                    mountAlreadyReady: server.hasMarkedEngineReady,
                    recoveryItem: usingHDRFallbackItem) {
                    return
                }
            }
            isReady = true
            // Clear the seek-remount spinner (see remountForSeek). The replacement is playable, so whatever
            // wait it advertised is over; an item that is still genuinely starved re-raises this from its own
            // buffer observers on the very next callback.
            emit(MPVProperty.pausedForCache, false, loadToken: loadToken)
            // F3: the engine has a decodable first frame. Widen the remux producer lead from the reduced
            // pre-ready value to the full lead now that the pre-first-frame co-resident window (when a demote
            // may re-open the same 4K stream on libmpv) is past. No-op on a non-remux item.
            remuxLoader?.markEngineReady()
            // Latch the achieved base-video origin before reporting any position or resolving a pending seek.
            // The input seek may land on an earlier keyframe, so this authoritative value can differ slightly
            // from the requested origin. Zero keeps the entire mapping path an identity for ordinary loads.
            if let origin = remuxHLSServer?.timelineOriginSeconds
                ?? remuxRemoteMount?.timelineOriginSeconds, origin > 0 {
                remuxTimelineOrigin = origin
                DiagnosticsLog.log(
                    "dv",
                    "remux timeline origin \(Int(origin))s: player clock 0 is source \(Int(origin))s")
            }
            let dur = item.duration.seconds
            var seekable = dur.isFinite && dur > 0   // an indefinite duration is a live stream
            var emittedDuration = dur
            // DV-REMUX SOURCE DURATION: AVPlayer's duration is measured from player second zero, while every
            // chrome clock is in source seconds. Prefer the demuxer's authoritative source duration whether
            // AVPlayer reports finite or indefinite. If the demuxer cannot provide one and AVPlayer is finite,
            // add the achieved origin to recover a source-timeline duration. Non-remux values remain untouched.
            if isRemuxMounted {
                let authoritativeDuration = remuxHLSServer?.sourceDurationSeconds
                    ?? remuxRemoteMount?.sourceDurationSeconds
                    ?? remuxLoader?.sourceDurationSeconds
                emittedDuration = RemuxResumePolicy.reportedDuration(
                    playerDurationSeconds: dur,
                    origin: remuxTimelineOrigin,
                    authoritativeSourceDurationSeconds: authoritativeDuration,
                    isRemuxMounted: true)
                seekable = emittedDuration.isFinite && emittedDuration > 0
                if let authoritativeDuration,
                   authoritativeDuration.isFinite, authoritativeDuration > 0 {
                    DiagnosticsLog.log(
                        "dv",
                        "authoritative remux source duration \(Int(authoritativeDuration))s (player duration \(Int(dur.isFinite ? dur : 0))s)")
                } else if dur.isFinite, dur > 0 {
                    DiagnosticsLog.log(
                        "dv",
                        "mapped remux source duration \(Int(emittedDuration))s (origin \(Int(remuxTimelineOrigin))s + player duration \(Int(dur))s)")
                }
            }
            if seekable { emit(MPVProperty.duration, emittedDuration, loadToken: loadToken) }
            emit(MPVProperty.seekable, seekable, loadToken: loadToken)
            refreshRemuxSourceAudioTracks()
            // Publish audio and subtitle topology together after both media-selection groups resolve. An
            // audio-only publication would consume the chrome's one-shot automatic selection before the
            // subtitle rows exist.
            loadSelectionGroups()
            loadChapters()                     // async; re-emits track-list if the asset has chapter markers
            emitDynamicRange(item)             // Gap 7: light the chrome's HDR chip for DV / HDR10 / HLG content
            loadContainerFrameRate(item)       // Gap 8: cache the video track fps for the subtitle fingerprint
            if let target = pendingSeek, seekable {
                pendingSeek = nil
                // A remux resume is fulfilled by opening the INPUT at its origin, not by seeking AVPlayer into
                // bytes that have not been produced. A keyframe landing exactly on the target is already
                // satisfied; one within one GOP hides its own preroll with ONE local seek (root-cause report
                // section 7 - decode needs those extra reference frames, but the viewer must never see them);
                // anything farther ahead remains unreachable on the forward-only mount and is safely dropped.
                if isRemuxMounted {
                    switch RemuxResumePolicy.preStartSeek(
                        target: target,
                        origin: remuxTimelineOrigin) {
                    case .satisfied:
                        DiagnosticsLog.log(
                            "dv",
                            "pre-start seek to \(Int(target))s already satisfied by remux origin \(Int(remuxTimelineOrigin))s")
                    case .hidePreroll(let playerSeconds):
                        // `playerSeconds` is already the exact local-clock destination (see the policy's own
                        // header): the SAME CMTime construction the non-remux branch below uses, so a mutant
                        // that reused `target` (the SOURCE second) here instead would seek to the wrong clock
                        // on every resumed remux mount, not just fail to hide the preroll.
                        player.seek(to: CMTime(seconds: max(playerSeconds, 0), preferredTimescale: 600))
                        DiagnosticsLog.log(
                            "dv",
                            "pre-start seek to \(Int(target))s: hiding \(String(format: "%.3f", playerSeconds))s of keyframe preroll from remux origin \(Int(remuxTimelineOrigin))s")
                    case .unreachable(let ahead):
                        DiagnosticsLog.log(
                            "dv",
                            "dropped pre-start seek to \(Int(target))s: \(Int(ahead))s past remux origin \(Int(remuxTimelineOrigin))s")
                    }
                } else {
                    player.seek(to: CMTime(seconds: max(target, 0), preferredTimescale: 600))
                }
            }
            if !didStart {
                didStart = true
                applyCommittedTransport()
                DiagnosticsLog.log(
                    "avplayer",
                    "readyToPlay -> committed transport playbackRequested=\(playbackRequested) requestedRate=\(requestedRate) tcs=\(player.timeControlStatus.rawValue) waitReason=\(player.reasonForWaitingToPlay?.rawValue ?? "none")")
                // Variant-pick observability: each item has exactly one video variant. The path identifies
                // whether this is the primary DV item or the explicit HDR-only recovery item.
                let indicatedBitrate = item.accessLog()?.events.last?.indicatedBitrate ?? -1
                DiagnosticsLog.log(
                    "avplayer",
                    "readyToPlay variant: mode=\(usingHDRFallbackItem ? "hdr-recovery" : "primary") eligibleForHDRPlayback=\(AVPlayer.eligibleForHDRPlayback) indicatedBitrate=\(Int(indicatedBitrate))")
                let host = (item.asset as? AVURLAsset)?.url.host ?? "?"
                VXProbeState.shared.setPlayer(state: "playing", source: host, engine: "avplayer")
                VXProbe.event("player", "ready \(host)")
                #if os(tvOS)
                // TRUE DOLBY VISION: the remux lane re-asserts its classifier-derived request now that the
                // item has real size/rate. Native DV never constructs such a request: it only reapplies the
                // exact AVAsset.preferredDisplayCriteria object loaded and applied before attach, which covers
                // a replaced display manager without inventing metadata. reset() on stop returns the default.
                if isRemuxMounted {
                    let size = item.presentationSize
                    let assetFPS = Double(item.tracks.first {
                        $0.assetTrack?.mediaType == .video
                    }?.assetTrack?.nominalFrameRate ?? 0)
                    let classifiedFPS = remuxHLSServer?.authoritativeFrameRate
                        ?? remuxRemoteMount?.authoritativeFrameRate ?? 0
                    if let fps = DVPlaybackPolicy.frameRate(
                        classified: classifiedFPS, assetTrack: assetFPS) {
                        let videoRange = remuxHLSServer?.signaling?.videoRange
                            ?? remuxRemoteMount?.videoRange
                        let recoveryRange = DVPlaybackPolicy.hdrFallbackDisplayRange(
                            videoRange: videoRange)
                        let requestedRange: ContentDynamicRange = usingHDRFallbackItem
                            ? (recoveryRange == .hlg ? .hlg : .hdr10)
                            : .dolbyVision
                        HDRDisplayMode.request(requestedRange, fps: fps,
                                               width: Int(size.width), height: Int(size.height), in: nil)
                        VXProbe.log(
                            "dv",
                            "AVPlayer ready -> re-asserted \(requestedRange.rawValue) display mode fps=\(fps) \(Int(size.width))x\(Int(size.height)) remux=\(isRemuxMounted)")
                    } else {
                        VXProbe.log("dv", "AVPlayer ready -> display mode deferred: frame rate unknown \(Int(size.width))x\(Int(size.height)) remux=\(isRemuxMounted)")
                    }
                } else if contentIsDolbyVision, let nativeDisplayCriteria {
                    let reapplied = HDRDisplayMode.applyNativePreferredCriteria(nativeDisplayCriteria, in: nil)
                    VXProbe.log(
                        "dv", "AVPlayer ready -> re-applied same asset-owned native display criteria accepted=\(reapplied)")
                } else if contentIsDolbyVision {
                    VXProbe.log(
                        "dv", "AVPlayer ready -> native criteria unavailable after fail-soft preflight; no criterion constructed")
                }
                #endif
                // Case-C visibility (#76 b166): a NATIVE DV mp4 reached readyToPlay on ozdek's device, played
                // its Atmos audio, but produced NO video and misreported 3840x2160 as 1280x720. Dump every
                // video track's format description once per DV-flagged load so the next diagnostics export
                // names WHAT VideoToolbox refused (fourcc / coded dimensions / dvcC-dvvC presence / enabled).
                if isRemuxMounted || contentIsDolbyVision { logDVVideoTrackDiagnostics(item) }
            }
        case .failed:
            // Identity guard (#76 rework): a status Task enqueued for the OLD item can deliver after the
            // healthy-mount retry swapped in a fresh item and reset fatalErrorEmitted; acting on it would
            // re-emit endFileError and insta-demote the retry. Only the CURRENT item's failure may demote.
            guard item === self.item, !terminalLatch.hasEmitted else { break }
            let ns = item.error as NSError?
            let underlying = (ns?.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain)#\($0.code)" } ?? "none"
            DiagnosticsLog.log("avplayer", "item FAILED: \(ns?.localizedDescription ?? "?") domain=\(ns?.domain ?? "?") code=\(ns?.code ?? 0) underlying=\(underlying)")
            // #143: the HLS stack's REAL reason lives only in the item's error log (the NSError carries a
            // bare CoreMedia code like -12927 with no comment). Dump the last few events so the next device
            // export names the exact resource + CoreMedia's own errorComment. Fail-soft, bounded.
            if let events = item.errorLog()?.events, !events.isEmpty {
                for ev in events.suffix(4) {
                    let uri = ev.uri.flatMap { URL(string: $0)?.lastPathComponent ?? $0 } ?? "?"
                    DiagnosticsLog.log("avplayer", "errorLog: \(ev.errorDomain)#\(ev.errorStatusCode) uri=\(uri) comment=\(ev.errorComment ?? "none")")
                }
            }
            VXProbe.event("player", "failed \(ns?.localizedDescription ?? "?")")
            // #147 reactive net: a RAW (non-remux) mount that failed because AVFoundation cannot demux the
            // container ("Cannot Open" - the raw-MKV signature, since AVFoundation has no Matroska demuxer)
            // gets ONE retry through the PLAIN remux lane BEFORE the libmpv demote, so an MKV the proactive
            // gate could not name (an extensionless debrid link) still keeps AVPlayer + Picture in Picture.
            // Tightly gated (see shouldRetryViaPlainRemux): pre-start only, raw mounts only, non-DV only,
            // the specific container-unsupported error code only, a remux-attemptable URL only, one-shot.
            // Worst case the remux classify fails fast and the SAME demote runs a few seconds later.
            if shouldRetryViaPlainRemux(error: ns), let failedURL = lastLoadURL {
                plainRemuxRetried = true
                forcePlainRemux = true
                DiagnosticsLog.log("avplayer", "raw mount failed container-unsupported (code=\(ns?.code ?? 0)) -> ONE plain-remux retry before any libmpv demote (#147)")
                VXProbe.log("dv", "AVPlayer raw mount container-unsupported -> plain-remux retry host=\(failedURL.host ?? "?")")
                loadFile(
                    failedURL, headers: lastLoadHeaders, live: lastLoadLive,
                    audioSidecar: nil, reusing: loadToken
                )
                return
            }
            if recoverAudioReplacementIfNeeded(
                generation: itemGeneration,
                reason: ns?.localizedDescription ?? "item failed") {
                return
            }
            let finishFailure: @MainActor () -> Void = { [weak self, weak item] in
                guard let self, let item,
                      self.owns(item, loadToken: loadToken),
                      !self.fatalErrorEmitted else { return }
                let terminalMessage = self.remuxHLSServer?.terminalFailureReason
                    ?? item.error?.localizedDescription
                    ?? "Playback failed"
                // [dv] the demotion edge: the AVPlayer item failed and the chrome will fall back to libmpv
                // HDR10. For a DV source this is the tail of the [dv] trail.
                VXProbe.log(
                    "dv",
                    "AVPlayer item .failed -> terminal recovery: \(terminalMessage)")
                guard self.terminalLatch.claim(generation: self.itemGeneration) else { return }
                self.fatalErrorEmitted = true
                self.emit(
                    MPVProperty.endFileError,
                    terminalMessage,
                    loadToken: loadToken
                )
            }
            if retryFreshHDRItemOnHealthyMount(
                error: ns,
                onUnavailable: finishFailure) {
                return
            }
            finishFailure()
        default:
            break
        }
    }

    /// Case-C diagnostics (#76 b166): once per DV-flagged load that reaches readyToPlay, log every video
    /// track's sample-entry fourcc, coded dimensions, natural size, enabled flag, and which sample
    /// description extension atoms (dvcC/dvvC/hvcC/...) are present. This is the data that separates "the
    /// file's DV carriage is one tvOS cannot decode" (audio over black, wrong presentationSize) from any
    /// app-side cause. b176 (#76): it also ACTS on an AVPlayer-incompatible hev1/dvhe entry on the native DV
    /// lane, routing it through the remux lane (or to libmpv HDR10) instead of leaving it black. Fail-soft:
    /// any load error just logs.
    private func logDVVideoTrackDiagnostics(_ item: AVPlayerItem) {
        let asset = item.asset
        Task { @MainActor in
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            // Identity guard (#76 rework): the awaits here can straddle a source/episode switch; without it the
            // repair below would judge the OLD item's fourcc and ACT on the NEW load (forcing a healthy hvc1
            // load through remux, or wrongly demoting). Same pattern as loadChapters/loadSelectionGroups.
            guard player.currentItem === item else { return }   // a newer file loaded meanwhile
            if tracks.isEmpty {
                // Neutral: an HLS asset (every healthy remux play) reports no AVAssetTrack objects here, so this
                // is NOT an error and NOTHING keys logic off it. The native-lane repair below reads real tracks.
                DiagnosticsLog.log("dv", "item reports no track objects (normal for HLS)")
                return
            }
            for track in tracks {
                let descs = (try? await track.load(.formatDescriptions)) ?? []
                let natural = (try? await track.load(.naturalSize)) ?? .zero
                let enabled = (try? await track.load(.isEnabled)) ?? true
                if descs.isEmpty {
                    DiagnosticsLog.log("dv", "video track id=\(track.trackID) has NO format description natural=\(Int(natural.width))x\(Int(natural.height)) enabled=\(enabled)")
                    continue
                }
                for desc in descs {
                    let sub = CMFormatDescriptionGetMediaSubType(desc)
                    var fourcc = ""
                    for shift in [24, 16, 8, 0] {
                        let byte = UInt8(truncatingIfNeeded: sub >> UInt32(shift))
                        fourcc.append(byte >= 32 && byte < 127 ? Character(UnicodeScalar(byte)) : "?")
                    }
                    let dims = CMVideoFormatDescriptionGetDimensions(desc)
                    var atoms = "none"
                    if let ext = CMFormatDescriptionGetExtension(
                        desc, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms),
                       let dict = ext as? [String: Any] {
                        atoms = dict.keys.sorted().joined(separator: ",")
                    }
                    DiagnosticsLog.log("dv", "video track id=\(track.trackID) fourcc=\(fourcc) coded=\(dims.width)x\(dims.height) natural=\(Int(natural.width))x\(Int(natural.height)) enabled=\(enabled) atoms=[\(atoms)]")
                    // #76: hev1/dvhe carry parameter sets IN-BAND; AVFoundation decodes DV/HEVC only from the
                    // out-of-band hvc1/dvh1 form, so a native DV MP4/MOV with this entry reaches readyToPlay and
                    // renders BLACK over decoded audio. Route it through the remux lane (which rewrites the sample
                    // entry to hvc1/dvh1) immediately, rather than sitting on black until the audio-over-black
                    // watchdog. Native DV lane only (the remux output is already hvc1/dvh1); one-shot per load.
                    // The identity re-check covers the per-track awaits above, which can also straddle a switch.
                    if !isRemuxMounted, contentIsDolbyVision, !incompatibleEntryHandled,
                       player.currentItem === item,
                       fourcc == "hev1" || fourcc == "dvhe" {
                        incompatibleEntryHandled = true
                        repairIncompatibleDVSampleEntry(fourcc)
                        return
                    }
                }
            }
        }
    }

    /// Post-attach hev1/dvhe repair (#76). AVFoundation cannot decode a Dolby Vision HEVC track whose sample
    /// entry is hev1/dvhe (in-band parameter sets): it reaches readyToPlay and plays audio over a black picture.
    /// The remux lane re-opens the SAME source with libav (container-agnostic: MP4 demuxes as readily as MKV)
    /// and re-muxes to fMP4 with an hvc1/dvh1 sample entry, so re-mount THIS url through it for true DV. When the
    /// remux lane is off for this display, demote straight to libmpv HDR10 (honest) instead of waiting for the
    /// audio-over-black watchdog. Runs on the main actor (the diagnostics Task hops there before calling this).
    @MainActor
    private func repairIncompatibleDVSampleEntry(_ fourcc: String) {
        guard let url = lastLoadURL, let loadToken = activeLoadToken else { return }
        // `dvRemuxEngaged`, so an explicit "Prefer AVPlayer" pick repairs the sample entry through the remux
        // lane (true DV) instead of demoting to libmpv HDR10 the moment the toggle happens to be off.
        if VortXRemuxHLSServer.deliveryEnabled,
           PlayerEngineRouter.dvRemuxEngaged(dvDisplayCapable: DVDisplaySupport.isCapable) {
            DiagnosticsLog.log("dv", "native DV \(fourcc) sample entry is not AVPlayer-decodable (black over audio) -> re-mounting \(url.host ?? "?") through the remux lane for hvc1 repair")
            VXProbe.log("dv", "native DV \(fourcc) -> remux re-mount (hvc1/dvh1 repair)")
            forceRemux = true
            loadFile(
                url, headers: lastLoadHeaders, live: lastLoadLive,
                audioSidecar: nil, reusing: loadToken
            )
        } else {
            guard !fatalErrorEmitted else { return }
            guard terminalLatch.claim(generation: itemGeneration) else { return }
            fatalErrorEmitted = true
            DiagnosticsLog.log("dv", "native DV \(fourcc) sample entry is not AVPlayer-decodable and the remux lane is off -> demoting to libmpv HDR10")
            VXProbe.log("dv", "native DV \(fourcc) -> libmpv HDR10 (remux lane off)")
            emit(
                MPVProperty.endFileError,
                "Dolby Vision sample entry not decodable (\(fourcc))",
                loadToken: loadToken
            )
        }
    }

    /// AUDIO-OVER-BLACK watchdog (#76 residual). On the NATIVE DV lane (a DV-flagged MP4/MOV/HLS routed to
    /// AVPlayer; NOT the remux lane, whose VortXMKVRemuxStream classify guards already fail fast), some files
    /// reach readyToPlay, play their Atmos audio, and never produce a picture (ozdek's Case C: the
    /// diagnostics above name the refused carriage, but playback used to sit on black forever). The audio
    /// clock advances timePos, so the chrome's start watchdog disarms on the first tick (hasStartedPlaying)
    /// and nothing else ever intervenes. Detect it HERE, where the frame evidence lives, and emit the SAME
    /// one-shot endFileError the .failed / remux-mount-failure paths use, so the chrome demotes to libmpv in
    /// place and the viewer gets a real picture (honest HDR10 + decoded audio) instead of black-with-Atmos.
    ///
    /// Fires only when ALL of these hold for a sustained `audioOverBlackWindowSeconds` window:
    ///  - the route is the native DV lane: `contentIsDolbyVision && !isRemuxMounted`. This lane cannot mount
    ///    an intentional audio-only asset (the router only DV-flags video streams), so the "audio-only file"
    ///    false positive is excluded by the route condition itself.
    ///  - the item started (`didStart`) and the transport is actually running (`.playing` with an advancing
    ///    clock); a pause or a buffering stall RESETS the window rather than counting toward it.
    ///  - NO video frame was EVER produced for this item: `videoFrameEverProduced` latches permanently on the
    ///    first frame seen by ANY signal in `hasProducedPicture` (layer readiness, live frame rate, frame
    ///    tap), so a session that ever showed a picture can never demote through this path (a mid-play video
    ///    freeze is the stall watchdog's job, not ours). The fire edge additionally re-checks
    ///    `playerLayer.isReadyForDisplay` and stands down if the layer holds a displayable frame.
    /// The demote log carries the presentationSize evidence. NOTE presentationSize is corroborating output
    /// only, not a veto: ozdek's file misreported 3840x2160 as a NON-zero 1280x720 while producing nothing,
    /// so a zero-size check alone would miss the confirmed case.
    private func checkAudioOverBlackWatchdog(clock: TimeInterval, position: Double) {
        guard !audioOverBlackFired, !videoFrameEverProduced else { return }
        guard contentIsDolbyVision, !isRemuxMounted, didStart else { return }
        guard position > 0, player.timeControlStatus == .playing else {
            audioOverBlackSince = 0   // not advancing: never count paused/buffering time toward the window
            return
        }
        if latchPlayableVideoFrame(atClock: position) {
            audioOverBlackSince = 0
            return
        }
        if audioOverBlackSince == 0 { audioOverBlackSince = clock; return }
        guard clock - audioOverBlackSince >= audioOverBlackWindowSeconds else { return }
        // IRREVERSIBLE edge, so corroborate ONE more time against Apple's own layer signal right before the
        // call: AVPlayerLayer.isReadyForDisplay is the documented "this layer has a displayable frame". The
        // per-tick proxies can false-NEGATIVE (currentVideoFrameRate needs a stabilization run; the video
        // output is poll-based and can be delivery-suspended), and a false demote is expensive (true DV +
        // Atmos lost for the whole title), so the demote may only fire while the layer itself reports NO
        // displayable frame, or no layer is attached at all.
        if playerLayer?.isReadyForDisplay == true {
            _ = latchPlayableVideoFrame(atClock: position)
            audioOverBlackSince = 0
            return
        }
        audioOverBlackFired = true
        // Respect an earlier fatal FIRST, before any logging: a genuine item .failed can land inside the
        // window, and the [dv] trail is triage-critical, so the watchdog must never log a demote claim for
        // a fallback that .failed actually caused.
        guard !fatalErrorEmitted else { return }
        guard terminalLatch.claim(generation: itemGeneration) else { return }
        fatalErrorEmitted = true
        let size = item?.presentationSize ?? .zero
        DiagnosticsLog.log("dv", "audio-over-black watchdog: \(Int(audioOverBlackWindowSeconds))s of advancing clock with ZERO video frames (presentationSize=\(Int(size.width))x\(Int(size.height)) pos=\(Int(position))s) -> endFileError demote to libmpv HDR10")
        VXProbe.log("dv", "audio-over-black demote: no frame in \(Int(audioOverBlackWindowSeconds))s presentationSize=\(Int(size.width))x\(Int(size.height))")
        emit(MPVProperty.endFileError, "Dolby Vision video produced no picture (audio over a black screen)")
    }

    /// Whether the CURRENT item has demonstrably rendered a video frame. Three independent signals, any one
    /// latches the watchdog off for the rest of the item:
    ///  1. `AVPlayerLayer.isReadyForDisplay` -- Apple's documented "the layer has a frame to show". Checked
    ///     first (authoritative and cheapest); nil when no layer host has attached yet, so it can never
    ///     latch on absence alone.
    ///  2. Any AVPlayerItemTrack reporting `currentVideoFrameRate > 0` -- the render pipeline's own live
    ///     frame-rate report, which is 0.0 for audio tracks and for a video track producing nothing.
    ///  3. The trickplay frame tap (`videoOutput`) holding a decoded pixel buffer for the current clock.
    ///     Last because AVFoundation may suspend an unpolled output's delivery (a false NEGATIVE, never
    ///     a false positive) -- all three signals only ever err toward "keep waiting", not toward demoting.
    private func hasProducedPicture(atClock seconds: Double) -> Bool {
        if playerLayer?.isReadyForDisplay == true { return true }
        if let tracks = item?.tracks, tracks.contains(where: { $0.currentVideoFrameRate > 0 }) { return true }
        if let output = videoOutput,
           output.hasNewPixelBuffer(forItemTime: CMTime(seconds: seconds, preferredTimescale: 600)) {
            return true
        }
        return false
    }

    /// Once the primary remux item has produced a picture, pin AVFoundation to the bandwidth declared by that
    /// proven DV variant. The one-variant master already removes the old HDR ABR leg; this is a second guard
    /// against a later selector reinterpretation. Hosted mounts receive the same value over the optional status
    /// field, while older hosts safely leave the preference unset.
    private func pinPreferredPeakBitRateAfterFirstFrame(_ item: AVPlayerItem, atClock seconds: Double) {
        let producedPicture = latchPlayableVideoFrame(atClock: seconds)
        let signalingDolbyVision: Bool
        if let localSignaling = remuxHLSServer?.signaling {
            signalingDolbyVision = localSignaling.dolbyVision
        } else {
            // A hosted DV session always reports PQ or HLG. Plain remux status intentionally carries nil.
            signalingDolbyVision = remuxRemoteMount?.videoRange != nil
        }
        guard !preferredPeakBitRatePinned,
              DVPlaybackPolicy.shouldPinPreferredPeakBitRate(
                  isRemuxMounted: isRemuxMounted,
                  usingHDRFallbackItem: usingHDRFallbackItem,
                  contentIsDolbyVision: contentIsDolbyVision,
                  signalingDolbyVision: signalingDolbyVision),
              producedPicture else { return }
        let declared = remuxHLSServer?.signaling?.bandwidth
            ?? remuxRemoteMount?.declaredBandwidth ?? 0
        guard declared > 0 else { return }
        item.preferredPeakBitRate = Double(declared)
        preferredPeakBitRatePinned = true
        DiagnosticsLog.log(
            "dv",
            "first frame produced -> preferredPeakBitRate pinned to declared DV bandwidth \(declared)")
    }

    @objc private func didPlayToEnd(_ note: Notification) {
        guard let endedItem = note.object as? AVPlayerItem,
              let loadToken = activeLoadToken,
              owns(endedItem, loadToken: loadToken) else { return }
        let remuxTerminal: (ended: Bool, failureReason: String?)?
        if let server = remuxHLSServer {
            remuxTerminal = (server.hasReachedEndOfStream, server.terminalFailureReason)
        } else if let remote = remuxRemoteMount {
            let progress = remote.mountProgress
            remuxTerminal = (
                progress.ended,
                progress.failed ? VortXRemuxItemEndPolicy.producerFailedReason : nil)
        } else if let loader = remuxLoader {
            let progress = loader.mountProgress
            remuxTerminal = (
                progress.ended,
                progress.failed ? VortXRemuxItemEndPolicy.producerFailedReason : nil)
        } else {
            remuxTerminal = nil
        }
        switch VortXRemuxItemEndPolicy.classify(
            isRemux: remuxTerminal != nil,
            producerEnded: remuxTerminal?.ended ?? true,
            producerFailureReason: remuxTerminal?.failureReason
        ) {
        case .contentEOF:
            guard terminalLatch.claim(generation: itemGeneration) else { return }
            VXProbe.event("player", "endfile eof")
            emit(MPVProperty.endFileEof, nil, loadToken: loadToken)
        case .remuxFailure(let reason):
            guard !fatalErrorEmitted, !terminalLatch.hasEmitted else { return }
            if recoverAudioReplacementIfNeeded(
                generation: itemGeneration,
                reason: reason) {
                return
            }
            guard terminalLatch.claim(generation: itemGeneration) else { return }
            fatalErrorEmitted = true
            DiagnosticsLog.log(
                "dv",
                "AVPlayer item ended without a clean remux completion -> endFileError: \(reason)")
            VXProbe.event("player", "endfile error \(reason)")
            emit(MPVProperty.endFileError, reason, loadToken: loadToken)
        }
    }
    @objc private func failedToEnd(_ note: Notification) {
        guard !fatalErrorEmitted,
              !terminalLatch.hasEmitted,
              let failedItem = note.object as? AVPlayerItem,
              let loadToken = activeLoadToken,
              owns(failedItem, loadToken: loadToken) else { return }
        let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        let message = err?.localizedDescription ?? "Playback failed"
        if recoverAudioReplacementIfNeeded(
            generation: itemGeneration,
            reason: message) {
            return
        }
        let finishFailure: @MainActor () -> Void = { [weak self, weak failedItem] in
            guard let self, let failedItem,
                  self.owns(failedItem, loadToken: loadToken),
                  !self.fatalErrorEmitted else { return }
            let terminalMessage = self.remuxHLSServer?.terminalFailureReason ?? message
            guard self.terminalLatch.claim(generation: self.itemGeneration) else { return }
            self.fatalErrorEmitted = true
            VXProbe.event("player", "endfile error \(terminalMessage)")
            self.emit(
                MPVProperty.endFileError,
                terminalMessage,
                loadToken: loadToken
            )
        }
        if retryFreshHDRItemOnHealthyMount(
            error: (err as NSError?) ?? (failedItem.error as NSError?),
            onUnavailable: finishFailure) {
            return
        }
        finishFailure()
    }

    private func emit(_ name: String, _ data: Any?, loadToken: PlayerLoadToken? = nil) {
        guard let capturedToken = loadToken ?? activeLoadToken,
              capturedToken == activeLoadToken else { return }
        let capturedItemGeneration = itemGeneration
        // Never call the chrome synchronously from `loadFile`. A mount can fail while the caller is still
        // inside that method, before it has stored the returned token in its pending transaction. Queueing
        // every event preserves the atomic contract: return/register first, callbacks second.
        DispatchQueue.main.async { [weak self] in
            guard let self, capturedToken == self.activeLoadToken,
                  capturedItemGeneration == self.itemGeneration else { return }
            self.playDelegate?.propertyChange(
                propertyName: name, data: data, loadToken: capturedToken
            )
        }
    }

    /// Exact ownership check for an async media-selection operation. A logical load token can survive HDR
    /// recovery, so item object identity, item generation, and source-mount identity must all still agree.
    private func selectionContextIsCurrent(
        item: AVPlayerItem,
        generation: UInt64,
        mountIdentity: UInt64
    ) -> Bool {
        player.currentItem === item
            && self.item === item
            && itemGeneration == generation
            && playbackMountIdentity == mountIdentity
    }

    /// AVFoundation applies HLS media selection asynchronously. The source-audio row represents the URI-less
    /// primary rendition in the remux master, so do not publish that row as selected until AVFoundation's
    /// authoritative currentMediaSelection agrees. Retries are bounded to three seconds total. Returning false
    /// is fail-soft: the caller discards source-level identities and publishes the native HLS options actually
    /// selected by AVFoundation.
    private func alignSourceBackedPrimaryAudio(
        _ primary: AVMediaSelectionOption,
        in group: AVMediaSelectionGroup,
        item: AVPlayerItem,
        generation: UInt64,
        mountIdentity: UInt64
    ) async -> Bool {
        guard selectionContextIsCurrent(
            item: item,
            generation: generation,
            mountIdentity: mountIdentity
        ) else { return false }

        item.select(primary, in: group)
        let settleDelays: [Duration] = [
            .milliseconds(200),
            .milliseconds(800),
            .seconds(2),
        ]
        for (attempt, delay) in settleDelays.enumerated() {
            if item.currentMediaSelection.selectedMediaOption(in: group) == primary {
                return true
            }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  selectionContextIsCurrent(
                    item: item,
                    generation: generation,
                    mountIdentity: mountIdentity
                  ) else { return false }
            if item.currentMediaSelection.selectedMediaOption(in: group) == primary {
                return true
            }
            if attempt < settleDelays.count - 1 {
                item.select(primary, in: group)
            }
        }
        return false
    }

    /// Load the audio + subtitle selection groups off the asset (async, non-deprecated), cache them as
    /// [MPVTrack] (option index = id; mpv's -1 = off), then re-emit track-list so the chrome re-pulls.
    private func loadSelectionGroups() {
        guard let item = player.currentItem,
              let selectionLoadToken = activeLoadToken else { return }
        let asset = item.asset
        let selectionGeneration = itemGeneration
        let selectionMountIdentity = playbackMountIdentity
        Task { @MainActor in
            let ag = try? await asset.loadMediaSelectionGroup(for: .audible)
            guard player.currentItem === item,
                  self.item === item,
                  itemGeneration == selectionGeneration,
                  playbackMountIdentity == selectionMountIdentity else { return }
            let sg = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard player.currentItem === item,
                  self.item === item,
                  itemGeneration == selectionGeneration,
                  playbackMountIdentity == selectionMountIdentity else { return }
            audioGroup = ag
            subGroup = sg
            // VortX owns track selection from here on (TrackSelector runs on the first track-list publication
            // and the picker drives every later change), so stop AVFoundation re-applying its OWN automatic
            // criteria on top. Apple's contract for `select(_:in:)` is exactly this: an app that selects
            // explicitly must clear this flag, otherwise the framework re-asserts its automatic choice at the
            // next selection opportunity and silently reverts the app's pick. Left at its default `true`,
            // that is a live fight on the remux lane, whose master carries DEFAULT=YES / AUTOSELECT rows:
            // an explicit deselect could come back on (subtitles rendering while the picker says Off) and an
            // explicit pick could be undone right after the rendition finished buffering ("I click it, the
            // stream buffers and nothing changes"). Clearing the flag deselects nothing, so whatever is
            // already playing keeps playing; it only stops future automatic overrides. Applied HERE rather
            // than before the item mounts on purpose: the framework's initial automatic pick still happens, so
            // a source whose TrackSelector run picks no audio keeps the audible track it has today. The remux
            // source topology is the exception below: VortX must explicitly keep its selected source row and
            // audible in-band rendition aligned.
            player.appliesMediaSelectionCriteriaAutomatically = false
            let sourceBackedAudio = !remuxSourceAudioTracks.isEmpty
            let selectedSourcePublished = selectedRemuxAudioSourceIndex.map { selected in
                remuxSourceAudioTracks.contains(where: { $0.sourceIndex == selected })
            } ?? false
            var hasNativePrimaryOption = false
            var primaryAligned = false
            if sourceBackedAudio {
                if let group = ag,
                   let inBandPrimary = group.defaultOption ?? group.options.first {
                    hasNativePrimaryOption = true
                    // Await alignment before taking the intent snapshot. Nothing may suspend after that
                    // snapshot because every user action must either update the consumed intent or act on the
                    // settled item, never race a stale local copy across an await.
                    primaryAligned = await alignSourceBackedPrimaryAudio(
                        inBandPrimary,
                        in: group,
                        item: item,
                        generation: selectionGeneration,
                        mountIdentity: selectionMountIdentity)
                    guard selectionContextIsCurrent(
                        item: item,
                        generation: selectionGeneration,
                        mountIdentity: selectionMountIdentity
                    ) else { return }
                }
            }
            let sourcePrimaryReady = RemuxAudioReplacementPolicy.sourcePrimaryIsReady(
                hasNativePrimaryOption: hasNativePrimaryOption,
                nativePrimaryAligned: primaryAligned,
                selectedSourcePublished: selectedSourcePublished)
            if sourceBackedAudio {
                DiagnosticsLog.log(
                    "avplayer",
                    "source audio topology count=\(remuxSourceAudioTracks.count) selected=\(selectedRemuxAudioSourceIndex.map(String.init) ?? "none") nativePrimary=\(hasNativePrimaryOption) aligned=\(primaryAligned) ready=\(sourcePrimaryReady)")
            }
            if audioReplacement != nil {
                if sourcePrimaryReady,
                   audioReplacement?.markReady(generation: selectionGeneration) == true {
                    DiagnosticsLog.log(
                        "avplayer",
                        "audio replacement generation \(selectionGeneration) reached source ready source=\(selectedRemuxAudioSourceIndex.map { String($0) } ?? "default")")
                } else {
                    let reason = selectedSourcePublished
                        ? "audio replacement native primary selection did not settle"
                        : "audio replacement selected source was not published"
                    if recoverAudioReplacementIfNeeded(
                        generation: selectionGeneration,
                        reason: reason) {
                        return
                    }
                    guard owns(item, loadToken: selectionLoadToken),
                          selectionContextIsCurrent(
                            item: item,
                            generation: selectionGeneration,
                            mountIdentity: selectionMountIdentity
                          ),
                          !fatalErrorEmitted else { return }
                    guard terminalLatch.claim(generation: itemGeneration) else { return }
                    fatalErrorEmitted = true
                    DiagnosticsLog.log(
                        "avplayer",
                        "\(reason) after rollback -> endFileError")
                    emit(
                        MPVProperty.endFileError,
                        reason,
                        loadToken: selectionLoadToken)
                    return
                }
            } else if sourceBackedAudio && !sourcePrimaryReady {
                // An initial mount has no prior working source to roll back to. Keep playback alive, but do
                // not claim that a source-level row is selected without either the remuxer's authoritative
                // selected source or exact alignment of the native primary option. Keep the full inventory
                // visible so the viewer can still choose any source track and start an owned replacement.
                DiagnosticsLog.log(
                    "avplayer",
                    "source audio primary was not ready; retaining \(remuxSourceAudioTracks.count) source rows with no selected claim")
                selectedRemuxAudioSourceIndex = nil
            }
            let intentSnapshot = pendingPlaybackIntent
            let replacementReady = audioReplacement.map {
                $0.isReady(generation: selectionGeneration)
            } ?? true
            var ownedIntent = intentSnapshot
            let restore = replacementReady
                ? ownedIntent?.consume(
                    generation: selectionGeneration,
                    mountIdentity: selectionMountIdentity)
                : nil
            if let restore {
                let playerSeconds: Double
                if isRemuxMounted {
                    let sourceDuration = remuxHLSServer?.sourceDurationSeconds
                        ?? remuxRemoteMount?.sourceDurationSeconds
                        ?? remuxLoader?.sourceDurationSeconds
                    playerSeconds = RemuxResumePolicy.playerSeek(
                        sourceSeconds: restore.sourceSeconds,
                        origin: remuxTimelineOrigin,
                        authoritativeSourceDurationSeconds: sourceDuration,
                        playerDurationSeconds: item.duration.seconds,
                        producedEdgePlayerSeconds: producedEdgeSeconds)
                } else {
                    playerSeconds = restore.sourceSeconds
                }
                // Queue a normal AVPlayer seek. An exact awaited seek can suspend on a forward-only HLS mount
                // when the viewer changed the target during remount. The policy above clamps the newest source
                // intent into the produced player window, and this MainActor block has no suspension between
                // consuming and clearing that intent.
                player.seek(
                    to: CMTime(seconds: playerSeconds, preferredTimescale: 600),
                    completionHandler: { _ in })
                if restore.audioSelectionKnown,
                   remuxSourceAudioTracks.isEmpty,
                   restore.audioSourceIndex == nil,
                   let group = ag {
                    let option = restore.nativeAudioIndex.flatMap { index in
                        group.options.indices.contains(index) ? group.options[index] : nil
                    }
                    item.select(option, in: group)
                }
                switch restore.subtitle {
                case .external:
                    if let group = sg {
                        item.select(nil, in: group)
                    }
                    externalSubActive = true
                case .off:
                    if let group = sg { item.select(nil, in: group) }
                    externalSubActive = false
                case .embedded(let sourceIndex):
                    if let group = sg {
                        let index = nativeSubtitleIndex(forSourceID: sourceIndex) ?? sourceIndex
                        let option = group.options.indices.contains(index)
                            ? group.options[index] : nil
                        item.select(option, in: group)
                    }
                    externalSubActive = false
                case .unresolved:
                    break
                }

                // The snapshot owns playhead and media selections only. Transport is live controller state:
                // play(), pause() and setSpeed() may have committed a newer choice while groups were loading.
                applyCommittedTransport()
                pendingPlaybackIntent = nil
                remuxSeekRemountTarget = nil
                audioReplacement = nil
                DiagnosticsLog.log(
                    "avplayer",
                    "playback intent restored once generation=\(selectionGeneration) mount=\(selectionMountIdentity) sourceTime=\(String(format: "%.3f", restore.sourceSeconds)) audio=\(restore.audioSourceIndex.map(String.init) ?? restore.nativeAudioIndex.map(String.init) ?? "default") subtitle=\(String(describing: restore.subtitle)) capturedPlaybackRequested=\(restore.playbackRequested) capturedRate=\(restore.requestedRate) committedPlaybackRequested=\(playbackRequested) committedRate=\(requestedRate)")
            } else if pendingPlaybackIntent != nil {
                // A live mount always restores here: `replacementReady` is true by this point (the audio
                // replacement block above either marks the transaction ready or returns), and loadFile / the
                // recovery remount rebind the intent to every mount's generation and identity, so `consume`
                // matches and lands exactly once for the current mount. The only way to reach this branch is a
                // stale selection pass whose generation the guards above already rejected; keep the unconsumed
                // local copy so nothing is lost, but there is no restore to retry.
                pendingPlaybackIntent = ownedIntent
            }
            // A selection notification may arrive before the groups finish loading and publish an empty
            // snapshot. Open the generation gate only after both groups and restoration are complete, then
            // force the newly available option topology to publish once even when both are Off.
            selectionTopologyGeneration = selectionGeneration
            selectionRefreshState.reset()
            refreshSelectionTracks(for: item)
            applyEmbeddedSubtitleTextStyle()   // P5: style native legible tracks from the start (best-effort)
        }
    }

    /// Rebuild cached selected flags from AVPlayer's authoritative currentMediaSelection. Called after every
    /// explicit selection, from the bounded settle re-read, and from AVPlayer's system-driven
    /// selection-change notification.
    ///
    /// The VortX-owned external overlay subtitle participates in the SAME "which row is ticked" identity, so
    /// turning it on or off publishes a new track list even when no AVMediaSelectionGroup index moved. Without
    /// that, an add-on subtitle could start rendering while the picker still showed Off ticked (the build 191
    /// field report) because nothing in the group had changed.
    private func refreshSelectionTracks(for item: AVPlayerItem) {
        guard player.currentItem === item else { return }
        let audioID = remuxSourceAudioTracks.isEmpty
            ? audioGroup.flatMap { Self.selectedIndex(in: $0, item: item) }
            : selectedRemuxAudioSourceIndex
        let nativeSubtitleID = subGroup.flatMap { Self.selectedIndex(in: $0, item: item) }
        let sourceSubtitleID = nativeSubtitleID.flatMap { renditionIndex in
            remuxSourceSubtitleTracks.first(where: {
                $0.renditionIndex == renditionIndex
            })?.sourceIndex
        }
        let subtitleID = externalSubActive
            ? Self.externalSubtitleTrackID
            : (sourceSubtitleID ?? nativeSubtitleID)
        audioTracks = remuxSourceAudioTracks.isEmpty
            ? (audioGroup.map { Self.mpvTracks(from: $0, type: "audio", item: item) } ?? [])
            : sourceAudioMPVTracks()
        subTracks = remuxSourceSubtitleTracks.isEmpty
            ? (subGroup.map { Self.mpvTracks(from: $0, type: "sub", item: item) } ?? [])
            : sourceSubtitleMPVTracks(item: item)
        if selectionRefreshState.update(audio: audioID, subtitle: subtitleID) {
            publishTrackListIfTopologyReady()
        }
    }

    private func publishTrackListIfTopologyReady() {
        guard selectionTopologyGeneration == itemGeneration else { return }
        emit(MPVProperty.trackList, nil)
    }

    /// Force one track-list publication from the engine's current state. Used by the external-subtitle paths,
    /// whose change is invisible to the group-index snapshot the incremental refresh compares against.
    private func publishSelectionTracks() {
        guard let item = player.currentItem else { return }
        selectionRefreshState.reset()
        refreshSelectionTracks(for: item)
    }

    private static func selectedIndex(in group: AVMediaSelectionGroup, item: AVPlayerItem) -> Int? {
        guard let selected = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return group.options.firstIndex(of: selected)
    }

    private static func mpvTracks(from group: AVMediaSelectionGroup, type: String, item: AVPlayerItem) -> [MPVTrack] {
        let selectedIndex = selectedIndex(in: group, item: item)
        let flags = DVPlaybackPolicy.selectedFlags(optionCount: group.options.count, selectedIndex: selectedIndex)
        return group.options.enumerated().map { idx, opt in
            MPVTrack(id: idx, type: type, title: opt.displayName,
                     lang: opt.extendedLanguageTag ?? "", selected: flags[idx],
                     forced: opt.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
        }
    }

    @objc private func mediaSelectionDidChange(_ note: Notification) {
        guard let changedItem = note.object as? AVPlayerItem,
              changedItem === player.currentItem,
              selectionTopologyGeneration == itemGeneration else { return }
        refreshSelectionTracks(for: changedItem)
    }

    private func teardownObservers() {
        remuxSubtitleInventoryRefreshTask?.cancel()
        remuxSubtitleInventoryRefreshTask = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let playheadObserver { player.removeTimeObserver(playheadObserver) }
        playheadObserver = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        // stop() is the normal teardown; this is a safety net if the engine is released without it.
        remuxSubtitleInventoryRefreshTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let playheadObserver { player.removeTimeObserver(playheadObserver) }
        observations.forEach { $0.invalidate() }
        pipObservations.forEach { $0.invalidate() }
        pipController?.delegate = nil
        NotificationCenter.default.removeObserver(self)   // matches teardownObservers(): drop AVPlayerItem note observers before dealloc
        remuxLoader?.invalidate()
        remuxHLSServer?.invalidate()
        configuredPreparedRemux?.handle.abandon(reason: "engine-deinit")
    }
}

extension AVPlayerEngineController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard let generation = pictureInPictureGeneration(for: pictureInPictureController),
              pipState.willStart(generation: generation) else { return }
        publishPictureInPictureState()
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard let generation = pictureInPictureGeneration(for: pictureInPictureController) else { return }
        guard pipState.didStart(
            possible: pictureInPictureController.isPictureInPicturePossible,
            active: pictureInPictureController.isPictureInPictureActive,
            generation: generation) else { return }
        publishPictureInPictureState()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        guard let generation = pictureInPictureGeneration(for: pictureInPictureController),
              pipState.failStart(generation: generation) else { return }
        publishPictureInPictureState()
        DiagnosticsLog.log("avplayer", "PiP start failed: \(error.localizedDescription)")
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard let generation = pictureInPictureGeneration(for: pictureInPictureController),
              pipState.willStop(generation: generation) else { return }
        publishPictureInPictureState()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard let generation = pictureInPictureGeneration(for: pictureInPictureController) else { return }
        guard pipState.didStop(
            possible: pictureInPictureController.isPictureInPicturePossible,
            active: pictureInPictureController.isPictureInPictureActive,
            generation: generation) else { return }
        publishPictureInPictureState()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // PlayerScreen remains mounted over the same layer, so there is no second UI to present. A retired
        // controller must decline restoration rather than waking a replacement screen with stale state.
        completionHandler(pictureInPictureGeneration(for: pictureInPictureController) != nil)
    }
}
#endif
