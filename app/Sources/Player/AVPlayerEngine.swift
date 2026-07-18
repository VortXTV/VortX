#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import AVKit
import AVFoundation
import CoreMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

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
final class AVPlayerEngineController: NSObject, PlayerEngine {
    let player = AVPlayer()
    /// The chrome's Coordinator. Property changes are pushed here with the same string keys the libmpv
    /// controller emits, so `handleProperty()` runs unchanged against either engine.
    weak var playDelegate: MPVPlayerDelegate?

    private var item: AVPlayerItem?
    private var isReady = false
    private var didStart = false
    /// One fatal `endFileError` per loaded item. The item's `.failed` KVO and the failed-to-play-to-end
    /// notification can BOTH fire for one failure; a duplicate event lands after the chrome has already
    /// demoted to libmpv and used to punch through into its retry/error path (the DV "error screen").
    private var fatalErrorEmitted = false
    /// One-shot per mount for the healthy-mount retry (#76). A DV mount whose remux is provably healthy (init
    /// published, buffer not failed) can still fail its AVPlayerItem 4-5ms after /init.mp4 is fetched (a
    /// CoreMedia startup hiccup on the loopback HLS origin). The chrome retries ONE fresh item on the same mount
    /// before demoting; this flag makes that retry happen at most once, resetting only on the next loadFile.
    private var healthyMountRetried = false
    // AUDIO-OVER-BLACK watchdog state (#76 residual, native DV lane only; see checkAudioOverBlackWatchdog).
    // `videoFrameEverProduced` latches TRUE on the first observed video frame and permanently disarms the
    // watchdog for this item, so it can never fire on a session that ever showed a picture. `audioOverBlackSince`
    // anchors the sustained no-picture window (0 = not currently counting); `audioOverBlackFired` makes the
    // demote one-shot per item, alongside the fatalErrorEmitted latch it shares with the other fatal paths.
    private var videoFrameEverProduced = false
    private var audioOverBlackSince: TimeInterval = 0
    private var audioOverBlackFired = false
    /// Sustained window of advancing playback clock with ZERO video frames before demoting. Long enough to
    /// clear a slow first-frame on a healthy native DV start (normally sub-second once timePos ticks), short
    /// enough that black-with-Atmos flips to a working picture on libmpv in well under ten seconds.
    private let audioOverBlackWindowSeconds: TimeInterval = 8
    private var pendingSeek: Double?
    private var requestedRate: Float = 1
    private var timeObserver: Any?
    /// Throttle marks for the two EXPENSIVE per-tick side effects, mirroring the libmpv path
    /// (MPVMetalViewController.swift lastTimePosEmit / lastCacheTimeEmit). The periodic observer still
    /// fires at 0.25s, but the probe write (NSLock) and the loadedTimeRanges scan are gated behind the same
    /// PerformanceMode-scaled interval so a constrained device gets the same relief the libmpv path already has.
    /// Confined to the main actor (only read/written inside the observer's MainActor.assumeIsolated block).
    private var lastProbeEmit: TimeInterval = 0
    private var lastCacheEmit: TimeInterval = 0
    private var observations: [NSKeyValueObservation] = []
    private var pipController: AVPictureInPictureController?
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
    // External-subtitle rendering (add-on + community-pooled srt/vtt). AVFoundation has no API to side-load or
    // time-shift an external SRT, so VortX owns it: parse the file into cues and draw the active cue in
    // `subtitleOverlay` (a view above the AVPlayerLayer), synced to the player clock, with `setSubDelay` as an
    // offset. `externalSubActive` is true while an external overlay sub is showing; when it is, any AVPlayer-native
    // legible track is deselected to avoid double subtitles.
    private let subtitleRenderer = SubtitleCueRenderer()
    private weak var subtitleOverlay: SubtitleOverlayView?
    private var externalSubActive = false
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
    /// Whether the forward-only DV remux is mounted for the CURRENT item (either delivery). The chrome reads
    /// this to suppress its Continue-Watching resume seek: the remux produces bytes linearly, so a pre-start
    /// seek lands in bytes that do not exist yet, no frame ever arrives, and the start watchdog demotes the
    /// whole session to libmpv (killing BOTH true DV and Atmos on every replay).
    var isRemuxMounted: Bool { remuxLoader != nil || remuxHLSServer != nil }

    /// Progress counters for the mounted DV remux (either delivery), or nil when no remux is mounted. The
    /// chrome's PROGRESS-AWARE start watchdog polls this ~1 Hz to tell a slow-but-alive 4K source (counters
    /// still moving -> extend the start window) from a TRUE stall (nothing moved for the whole stall window
    /// -> demote to libmpv). Cheap: two lock hops per read, no allocation beyond the tiny struct.
    var remuxMountProgress: VortXMKVRemuxStream.MountProgress? {
        if let server = remuxHLSServer { return server.mountProgress }
        if let loader = remuxLoader { return loader.mountProgress }
        return nil
    }

    /// The furthest position the forward-only DV remux has actually produced, used to clamp forward seeks at
    /// the one engine chokepoint (`seek(to:)`) so a scrub / nudge / skip past the produced bytes can't strand
    /// the mount frameless and demote the whole true-DV session to libmpv. Prefer the item's seekable ranges
    /// (the HLS EVENT playlist advertises produced media there); fall back to the loaded (player-buffered)
    /// edge for the legacy loader delivery. 0 means "unknown / no produced edge yet" (callers do not clamp).
    var producedEdgeSeconds: Double {
        guard let item else { return 0 }
        var edge = 0.0
        for value in item.seekableTimeRanges {
            let r = value.timeRangeValue
            let end = (r.start + r.duration).seconds
            if end.isFinite { edge = max(edge, end) }
        }
        if edge > 0 { return edge }
        for value in item.loadedTimeRanges {
            let r = value.timeRangeValue
            let end = (r.start + r.duration).seconds
            if end.isFinite { edge = max(edge, end) }
        }
        return edge
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

    func loadFile(_ url: URL, headers: [String: String]?, live: Bool) {
        teardownObservers()
        teardownRemux()
        isReady = false; didStart = false; pendingSeek = nil; fatalErrorEmitted = false; healthyMountRetried = false
        incompatibleEntryHandled = false
        lastLoadURL = url; lastLoadHeaders = headers; lastLoadLive = live
        videoFrameEverProduced = false; audioOverBlackSince = 0; audioOverBlackFired = false
        audioGroup = nil; subGroup = nil; audioTracks = []; subTracks = []; loadedChapters = []; containerFPS = 0
        disableExternalSubtitle()   // a new title starts with no external overlay sub
        // Claim .playback before play so PiP and locked-screen audio work, and advertise multichannel so the
        // system passes through Atmos (#78) and applies AirPods Spatial Audio (#88). Idempotent with the
        // libmpv path since only one engine is live at a time. macOS has no AVAudioSession (the system routes
        // audio automatically), so this is iOS/tvOS only.
        #if os(iOS) || os(tvOS)
        AVPlayerAudioSession.activateForMovie()
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
        let wantsRemux = forceRemux || (contentIsDolbyVision && PlayerEngineRouter.shouldDVRemux(url: url))
        forceRemux = false
        if wantsRemux, VortXRemuxHLSServer.deliveryEnabled,
           let mounted = VortXRemuxHLSServer.make(input: url, headers: headers) {
            remuxHLSServer = mounted.server
            mounted.server.start()
            newAsset = AVURLAsset(url: mounted.playlistURL)
            DiagnosticsLog.log("avplayer", "dv-remux mount (local HLS) host=\(url.host ?? "?") -> 127.0.0.1:\(mounted.server.port)")
            // [dv] the true-DV remux lane mounted: AVPlayer is now fed the remux as local HLS. If a classify
            // fail-soft fires next (see VortXMKVRemuxStream), the item .failed demotion below ties the reason
            // to the observed engine flip, giving one greppable [dv] trail.
            VXProbe.log("dv", "remux mounted (local HLS) host=\(url.host ?? "?") -> 127.0.0.1:\(mounted.server.port)")
        } else if wantsRemux, !VortXRemuxHLSServer.deliveryEnabled,
                  let built = VortXRemuxResourceLoader.make(input: url, headers: headers) {
            remuxLoader = built.loader
            let asset = AVURLAsset(url: built.assetURL)
            asset.resourceLoader.setDelegate(built.loader, queue: remuxLoaderQueue)
            built.loader.start()
            newAsset = asset
            DiagnosticsLog.log("avplayer", "dv-remux mount host=\(url.host ?? "?") -> \(built.assetURL.scheme ?? "?")")
            VXProbe.log("dv", "remux mounted host=\(url.host ?? "?") -> \(built.assetURL.scheme ?? "?")")
        } else if wantsRemux {
            // The router demanded the DV-for-MKV remux lane but the mount could not be built (the local HLS
            // server failed to bind, or the legacy loader could not be assembled). AVFoundation has no
            // Matroska demuxer, so loading the raw MKV here would mount an item AVPlayer can never produce a
            // frame from. Fail-soft immediately so the chrome demotes to libmpv HDR10 instead of stalling on
            // an un-demuxable asset. This ties into the [dv] demotion trail below.
            DiagnosticsLog.log("avplayer", "dv-remux mount build failed host=\(url.host ?? "?") -> demoting to libmpv")
            VXProbe.log("dv", "remux mount build failed -> endFileError demote host=\(url.host ?? "?")")
            fatalErrorEmitted = true
            emit(MPVProperty.endFileError, "DV remux unavailable")
            return
        } else {
            let options = (headers?.isEmpty ?? true) ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers!]
            newAsset = AVURLAsset(url: url, options: options)
        }
        let newItem = AVPlayerItem(asset: newAsset)
        item = newItem
        if remuxHLSServer != nil {
            // The remux window bounds OUR buffer, but AVPlayer keeps its OWN forward buffer of the served HLS
            // and, left unset, sizes it at its discretion (hundreds of MB at 4K DV bitrates, in the SAME
            // jetsam-bound process as node + mpv - a major contributor to the ~900MB that gets the app killed
            // on backgrounding). 30s is ample against a local loopback origin the producer already leads.
            newItem.preferredForwardBufferDuration = 30
        }
        // Attach a pull-model frame tap so trickplay can grab the displayed frame on demand (see videoOutput).
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        newItem.add(output)
        videoOutput = output
        #if os(tvOS)
        // TRUE DOLBY VISION: switch the panel into DV mode BEFORE the item is attached (Apple Tech Talk 503:
        // "perform this switch before assigning the AVPlayerItem"; current tvOS can even reject mismatched
        // VIDEO-RANGE HLS variants with -11868 when the panel is not switched first). Fires when the DV remux
        // mounted (it only mounts for DV) OR the routed stream is DV-flagged (a native DV MP4/MOV/HLS, which
        // previously never set preferredDisplayCriteria at all). fps/size are unknown pre-attach; the
        // readyToPlay request below re-asserts with the real values. Fail-soft: a refused/ignored request
        // changes nothing about playback, and reset() on stop() restores the default mode.
        if isRemuxMounted {
            // REMUX lane: DEFER the panel switch to the point classify confirms a DECODABLE DV profile (#76).
            // The remux stream knows the profile ~1.5-6s in; VortXRemuxHLSServer.serveMaster fires the switch
            // once the DV signaling is published and BEFORE the media playlist / first segment (still ahead of
            // the video mount, per Tech Talk 503 ordering). Firing it here on mount cycled the panel twice per
            // hop whenever classify then rejected a non-DV / undecodable source. Neither switch NOR reset here:
            // a reject 404s the playlist and demotes to libmpv (which resets on stop), and a same-DV back-to-back
            // play keeps the panel steady instead of reset-then-reswitch. Matches the old behavior of never
            // resetting on the remux path, just deferring the request.
            DiagnosticsLog.log("dv", "Dolby Vision display switch deferred to classify (remux lane)")
        } else if contentIsDolbyVision {
            // NATIVE DV lane (DV-flagged MP4/MOV/HLS on raw AVPlayer): the profile is NOT knowable before the
            // item demuxes, so keep the pre-attach switch on the text-parse DV flag. The readyToPlay re-assert
            // below corrects fps/size. An hev1/dvhe entry is re-routed to the remux lane post-attach (#76), so a
            // genuinely undecodable native DV file does not linger switched.
            HDRDisplayMode.request(.dolbyVision, fps: 0, width: 0, height: 0, in: nil)
            DiagnosticsLog.log("dv", "requested Dolby Vision display mode pre-attach (native DV lane, dvFlag=true)")
        } else {
            // A non-DV stream loading into this SAME engine (an in-player source/episode switch) must not
            // inherit a previous title's DV criteria. Idempotent: reset only clears when criteria are set.
            HDRDisplayMode.reset(in: nil)
        }
        #endif
        // START PROMPTLY. With the default (true), AVPlayer waits to build a stall-proof buffer before it
        // begins; for a large 4K / Dolby Vision debrid stream that wait can outlast any reasonable start
        // deadline, so the player mounts, shows the chrome, and never produces a frame (no item .failed, no
        // timePos) -> on tvOS that read as "AVPlayer plays nothing" and tripped the libmpv fallback for every
        // stream. We drive our own start watchdog + stall handling, so let playback begin at the first samples.
        player.automaticallyWaitsToMinimizeStalling = false
        player.replaceCurrentItem(with: newItem)
        player.allowsExternalPlayback = true   // AirPlay
        DiagnosticsLog.log("avplayer", "load host=\(url.host ?? "?") scheme=\(url.scheme ?? "?") ext=\(url.pathExtension) headers=\(headers?.count ?? 0) live=\(live)")
        observe(newItem)
        // Drive the current status now: the KVO below uses [.initial, .new], but an item that is already
        // readyToPlay at attach time still benefits from an explicit kick so play() is never skipped.
        if newItem.status != .unknown { handleStatus(newItem) }
    }

    /// One-shot healthy-mount retry (#76). Field logs show the served /media.m3u8 answered and /init.mp4
    /// fetched, then the AVPlayerItem fails 4-5ms later on a mount whose remux is provably HEALTHY (init
    /// published, buffer not failed). That 5ms window is a CoreMedia startup hiccup on the loopback HLS origin,
    /// not a dead stream, so the chrome (which owns the demote decision) asks for ONE fresh AVPlayerItem on the
    /// SAME mount before demoting to libmpv. Idempotent per mount (`healthyMountRetried` resets only on the next
    /// loadFile), so a genuinely broken mount fails the fresh item too and then demotes normally. Returns true
    /// iff a retry was issued, in which case the caller swallows this failure instead of demoting.
    func retryFreshItemOnHealthyMount() -> Bool {
        // `!didStart`: the retry restarts the mount at t=0, so it must refuse a mount that already PLAYED
        // (a mid-play failure is the demote paths' job). Today unreachable mid-play via the chrome's
        // !hasStartedPlaying gate; this makes the function safe on its own terms.
        guard let server = remuxHLSServer, server.isMountHealthy, !healthyMountRetried, !didStart,
              let mountURL = (item?.asset as? AVURLAsset)?.url else { return false }
        healthyMountRetried = true
        DiagnosticsLog.log("dv", "healthy-mount retry (#76): item failed but remux healthy (init published, buffer OK) -> one fresh AVPlayerItem on 127.0.0.1:\(server.port)")
        VXProbe.log("dv", "AVPlayer .failed on a HEALTHY remux mount -> ONE fresh-item retry (same mount) before any demote")
        teardownObservers()
        // Fresh item = fresh per-item state; the mount (remux thread + local HLS server) stays up. Clear
        // fatalErrorEmitted so a SECOND failure can still emit endFileError and demote (bounded by the one-shot
        // flag above); the audio-over-black / first-frame latches reset for the new item too.
        isReady = false; didStart = false; pendingSeek = nil; fatalErrorEmitted = false
        videoFrameEverProduced = false; audioOverBlackSince = 0; audioOverBlackFired = false
        let freshItem = AVPlayerItem(asset: AVURLAsset(url: mountURL))
        item = freshItem
        freshItem.preferredForwardBufferDuration = 30   // same loopback forward-buffer cap as the initial mount
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        freshItem.add(output)
        videoOutput = output
        player.replaceCurrentItem(with: freshItem)
        observe(freshItem)
        if freshItem.status != .unknown { handleStatus(freshItem) }
        return true
    }

    func play() { player.rate = requestedRate }   // rate > 0 starts playback at the chosen speed
    func pause() { player.pause() }
    func togglePause() { player.timeControlStatus == .paused ? play() : pause() }

    func seek(to seconds: Double) {
        // Before the item is playable, remember the target and apply it on ready (covers the chrome's
        // resume seek issued right after loadFile, which AVPlayer would otherwise drop).
        guard isReady else { pendingSeek = seconds; return }
        let dur = item?.duration.seconds ?? 0
        var clamped = (dur.isFinite && dur > 1) ? min(max(seconds, 0), max(dur - 1, 0)) : max(seconds, 0)
        // FORWARD-ONLY DV REMUX (P2, #76): cap the target at the produced edge at the ONE engine chokepoint, so
        // EVERY seek surface is covered (scrubber, hiddenSeek right-nudge, the fwd transport button, Lock Screen
        // / Control Center seek, chapter jumps, skip-pill / auto-skip) instead of each chrome clamping on its
        // own. A seek past the produced bytes lands in content that does not exist yet, no frame arrives, and
        // the start / stall watchdog demotes the whole true-DV session to libmpv (losing DV + Atmos). Backward
        // seeks and non-remux items are unaffected (min() only lowers the ceiling; a 0 edge is "unknown", skip).
        if isRemuxMounted {
            let edge = producedEdgeSeconds
            if edge > 0, clamped > edge { clamped = edge }
        }
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        emit(MPVProperty.timePos, clamped)
        updateSubtitleOverlay(atClock: clamped)   // re-check the cue now; the observer is only ~4 Hz
    }
    func seek(by seconds: Double) { seek(to: player.currentTime().seconds + seconds) }

    func setSpeed(_ speed: Double) {
        requestedRate = Float(speed)
        if player.timeControlStatus != .paused { player.rate = requestedRate }
    }

    /// Live playback position (AVPlayer currentTime), for the wall-clock trickplay capture driver. 0 / NaN
    /// before the first sample is normalised to 0.
    var playbackPositionSeconds: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    /// Live audio volume. AVPlayer.volume is a 0...1 gain; map the chrome's 0...100 scale onto it. Muting is
    /// separate (setMuted), so setting a level never un-mutes on its own.
    func setVolume(_ volume0to100: Double) {
        player.volume = Float(max(0, min(100, volume0to100)) / 100)
    }
    func setMuted(_ muted: Bool) { player.isMuted = muted }

    func stop() {
        teardownObservers()
        teardownRemux()
        #if os(tvOS)
        // Return the TV from any Dolby Vision display mode this session requested (idempotent no-op when it
        // was not DV; only this lane sets DV criteria, and one engine is live at a time).
        HDRDisplayMode.reset(in: nil)
        #endif
        disableExternalSubtitle()
        player.pause()
        player.replaceCurrentItem(with: nil)
        pipController?.delegate = nil
        pipController = nil
        videoOutput = nil
        item = nil
    }

    /// Tear down the DV-for-MKV remux session (stop the remux thread + the local HLS server / unblock any
    /// waiting loader request). Called before loading a new file and on stop(), so the remux never straddles
    /// two titles.
    private func teardownRemux() {
        remuxLoader?.invalidate()
        remuxLoader = nil
        remuxHLSServer?.invalidate()
        remuxHLSServer = nil
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

    func tracks(ofType type: String) -> [MPVTrack] {
        switch type {
        case "audio": return audioTracks
        case "sub":   return subTracks
        default:      return []
        }
    }
    func setAudioTrack(_ id: Int) { select(id, in: audioGroup) }
    /// Selecting an embedded/HLS legible track (or turning subtitles Off) also turns OFF any external overlay
    /// sub, so the two never fight or double up. `id < 0` = Off, which the caller uses for the "Off" row.
    func setSubtitleTrack(_ id: Int) {
        if externalSubActive { disableExternalSubtitle() }
        select(id, in: subGroup)
    }

    /// Select option `id` (its index in the group) on the current item, or deselect for mpv's -1 = off.
    private func select(_ id: Int, in group: AVMediaSelectionGroup?) {
        guard let group, let item = player.currentItem else { return }
        if id < 0 { item.select(nil, in: group) }
        else if id < group.options.count { item.select(group.options[id], in: group) }
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
        guard let remote = URL(string: url) else { completion?(false); return }
        let finish: (Bool) -> Void = { ok in DispatchQueue.main.async { completion?(ok) } }
        SubtitleFileFetcher.fetch(remote, timeout: timeout) { [weak self] data in
            guard let data else { finish(false); return }
            let cues = SubtitleCueRenderer.parse(data: data)
            guard !cues.isEmpty else { finish(false); return }
            Task { @MainActor in
                guard let self else { finish(false); return }
                self.subtitleRenderer.load(cues: cues)
                self.externalSubActive = true
                // Turn off any embedded/HLS legible track so we don't render two subtitle streams at once.
                if let group = self.subGroup { self.player.currentItem?.select(nil, in: group) }
                self.subtitleOverlay?.applyStyle()
                self.updateSubtitleOverlay(atClock: self.player.currentTime().seconds)
                finish(true)
            }
        }
    }

    /// Turn off the external overlay subtitle (clear cues + hide the overlay). Native track selection is
    /// untouched, so the caller can then select an embedded track or leave subtitles Off.
    private func disableExternalSubtitle() {
        externalSubActive = false
        subtitleRenderer.clear()
        subtitleOverlay?.setText(nil)
    }

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
    func mediaSummary() -> (width: Int, height: Int, audioCodec: String) {
        let size = item?.presentationSize ?? .zero
        return (Int(size.width), Int(size.height), selectedAudioCodec())
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

    /// Load asset chapter markers off the main thread, then cache them and re-emit track-list so the chrome
    /// re-pulls `chapters()`. Cheap (a metadata read), and a no-chapter asset just yields []. Mirrors the
    /// async pattern of `loadSelectionGroups`.
    private func loadChapters() {
        guard let item = player.currentItem else { return }
        // DV remux lane (Gap 3): the served fMP4/HLS carries no chapter metadata, but the remux stream read the
        // source MKV's libav chapter list at open (same window as the source duration, which is already ready
        // here). Pull those directly; `loadChapterMetadataGroups` on the local HLS playlist would return none.
        if isRemuxMounted {
            let remuxChapters = remuxHLSServer?.chapters ?? remuxLoader?.chapters ?? []
            if !remuxChapters.isEmpty {
                loadedChapters = remuxChapters
                    .map { MPVChapter(title: $0.title, start: $0.start) }
                    .sorted { $0.start < $1.start }
                emit(MPVProperty.trackList, nil)   // chrome re-pulls chapters() -> panel + scrubber ticks
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
            if !loadedChapters.isEmpty { emit(MPVProperty.trackList, nil) }
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
        playerLayer = layer
        layer.videoGravity = Self.gravity(for: videoSizeMode)
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let pip = AVPictureInPictureController(playerLayer: layer)
        pip?.delegate = self
        pipController = pip
    }

    // MARK: Observation -> MPVProperty events

    private func observe(_ item: AVPlayerItem) {
        observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in self?.handleStatus(item) }
        })
        observations.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.emit(MPVProperty.pausedForCache, item.isPlaybackBufferEmpty) }
        })
        observations.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in if item.isPlaybackLikelyToKeepUp { self?.emit(MPVProperty.pausedForCache, false) } }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                // Diagnostic: a player stuck at .waitingToPlayAtSpecifiedRate (2) with a buffering wait-reason
                // is the "mounts but never plays" signature; logging the reason pinpoints it in one test.
                DiagnosticsLog.log("avplayer", "timeControlStatus=\(player.timeControlStatus.rawValue) waitReason=\(player.reasonForWaitingToPlay?.rawValue ?? "none")")
                // Mirror the transport state + buffering wait into the probe so the heartbeat is meaningful
                // on the AVPlayer path (DV / HLS). waitingToPlayAtSpecifiedRate is AVPlayer's "buffering".
                let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                let stateText = player.timeControlStatus == .paused ? "paused"
                    : (waiting ? "buffering" : "playing")
                VXProbeState.shared.setPlayer(state: stateText, engine: "avplayer", buffering: waiting)
                VXProbe.event("player", "stall \(waiting ? "start" : "end")")
                self?.emit(MPVProperty.pause, player.timeControlStatus == .paused)
            }
        })
        // ~4 Hz, matching the libmpv controller's coalesced time-pos cadence. Delivered on .main, so it runs
        // synchronously on the main actor (no extra Task hop that could fire after teardown nils the observer).
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.timeObserver != nil else { return }
                // Cheap, every tick: the play head (scrubber smoothness) and the subtitle overlay clock. These
                // must stay at the full 0.25s cadence or the progress bar and external subs visibly lag.
                self.emit(MPVProperty.timePos, time.seconds)
                self.updateSubtitleOverlay(atClock: time.seconds)   // sync external-sub overlay to the clock
                // Gate the two EXPENSIVE side effects (the NSLock probe write and the loadedTimeRanges scan)
                // behind the same PerformanceMode-scaled interval the libmpv path uses (0.5s reduced, else
                // 0.25s), so a constrained device is not doing an unconditional lock + O(ranges) loop 4x/sec.
                let clock = ProcessInfo.processInfo.systemUptime
                // AUDIO-OVER-BLACK probe (native DV lane only). Two boolean guards once latched/off-route,
                // so the non-DV steady state pays nothing (see checkAudioOverBlackWatchdog).
                self.checkAudioOverBlackWatchdog(clock: clock, position: time.seconds)
                let minInterval = PerformanceMode.reduced ? 0.5 : 0.25
                // Push the play head (and duration when known) into the probe, throttled.
                if clock - self.lastProbeEmit >= minInterval {
                    self.lastProbeEmit = clock
                    let dur = self.item?.duration.seconds ?? 0
                    VXProbeState.shared.setPlayer(pos: time.seconds.isFinite ? Int(time.seconds) : 0,
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
                    if aheadEdge > 0 { self.emit(MPVProperty.demuxerCacheTime, aheadEdge) }
                }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(didPlayToEnd),
                                               name: .AVPlayerItemDidPlayToEndTime, object: item)
        NotificationCenter.default.addObserver(self, selector: #selector(failedToEnd(_:)),
                                               name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        #if canImport(UIKit)
        // Jetsam relief (mirrors MPVMetalViewController.shedForMemoryPressure): a paused AVPlayer keeps
        // filling its forward buffer at its own discretion, and a 4K / DV-remux HLS stream buffers
        // hundreds of MB — on tvOS the pause also lets the screensaver (its own 4K pipeline) start on
        // top, and jetsam reaps this app. The memory warning is the system's last call before that;
        // respond by capping the item's forward buffer so AVFoundation trims instead of being killed.
        // Registered per-load because teardownObservers() drops every observer on this object.
        NotificationCenter.default.addObserver(self, selector: #selector(handleMemoryWarningNote),
                                               name: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil)
        #endif
    }

    #if canImport(UIKit)
    /// System memory warning: cap the current item's forward buffer (default 0 = "system decides", which
    /// on a high-bitrate stream is far too generous for a jetsam-bound app). 30s at even remux bitrates
    /// is a modest, survivable footprint, and AVFoundation releases already-buffered media beyond the new
    /// preference. Sticky for the rest of this item; the next loadFile mints a fresh item with defaults.
    @objc private func handleMemoryWarningNote() {
        guard let item, item.preferredForwardBufferDuration != 30 else { return }
        item.preferredForwardBufferDuration = 30
        DiagnosticsLog.log("avplayer", "memory warning: preferredForwardBufferDuration capped to 30s")
    }
    #endif

    private func handleStatus(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            isReady = true
            // F3: the engine has a decodable first frame. Widen the remux producer lead from the reduced
            // pre-ready value to the full lead now that the pre-first-frame co-resident window (when a demote
            // may re-open the same 4K stream on libmpv) is past. No-op on a non-remux item.
            remuxHLSServer?.markEngineReady()
            remuxLoader?.markEngineReady()
            let dur = item.duration.seconds
            var seekable = dur.isFinite && dur > 0   // an indefinite duration is a live stream
            var emittedDuration = dur
            // DV-REMUX KNOWN DURATION: a remux mount serves a mid-production fMP4 EVENT playlist with no
            // EXT-X-ENDLIST, so AVPlayerItem.duration reads INDEFINITE at readyToPlay for the whole session
            // even though the source MKV runtime is known. Left uncorrected the chrome treats the entire DV
            // play as a live stream: it never arms the launch resume floor, and disables its periodic/exit
            // saves, reportSeek, scrubber range, skip clamps and mark-watched. Synthesize the demuxer-reported
            // runtime instead so the session behaves as the VOD it is (progress persists, the playhead scrubs
            // within the buffered edge per the forward-only clamp). Non-remux items keep AVPlayer's own value
            // byte for byte; the libmpv path never reaches here. Forward-only pre-start seeks are still dropped
            // below via the isRemuxMounted guard, so a synthesized seekable=true cannot resume into dead bytes.
            if !seekable, isRemuxMounted {
                let known = remuxHLSServer?.sourceDurationSeconds ?? remuxLoader?.sourceDurationSeconds ?? 0
                if known > 0 {
                    emittedDuration = known
                    seekable = true
                    DiagnosticsLog.log("dv", "synthesized remux duration \(Int(known))s (item.duration indefinite)")
                }
            }
            if seekable { emit(MPVProperty.duration, emittedDuration) }
            emit(MPVProperty.seekable, seekable)
            emit(MPVProperty.trackList, nil)   // chrome re-pulls via tracks()
            loadSelectionGroups()              // async; re-emits track-list once the groups resolve
            loadChapters()                     // async; re-emits track-list if the asset has chapter markers
            emitDynamicRange(item)             // Gap 7: light the chrome's HDR chip for DV / HDR10 / HLG content
            loadContainerFrameRate(item)       // Gap 8: cache the video track fps for the subtitle fingerprint
            if let target = pendingSeek, seekable {
                pendingSeek = nil
                // FORWARD-ONLY REMUX: never apply a pre-start (resume) seek while the DV remux is mounted.
                // The remux produces bytes linearly and advertises no byte-range access, so seeking into
                // not-yet-produced bytes yields no frame and the chrome's start watchdog then demotes to
                // libmpv (HDR10 + no Atmos) on EVERY resume of a DV title. Start at 0 instead; the chrome
                // keeps its resume offset for progress-save continuity. Belt-and-braces with the chrome's
                // own remux-aware resume suppression (TVPlayerView.maybeResume).
                if isRemuxMounted {
                    DiagnosticsLog.log("dv", "dropped pre-start resume seek to \(Int(target))s: DV remux is forward-only, starting from 0")
                } else {
                    player.seek(to: CMTime(seconds: max(target, 0), preferredTimescale: 600))
                }
            }
            if !didStart {
                didStart = true
                // Explicit play() then pin the rate. With automaticallyWaitsToMinimizeStalling = false this
                // begins at the first samples instead of waiting on a buffer heuristic that never settles.
                player.play()
                player.rate = requestedRate
                DiagnosticsLog.log("avplayer", "readyToPlay -> play() rate=\(requestedRate) tcs=\(player.timeControlStatus.rawValue) waitReason=\(player.reasonForWaitingToPlay?.rawValue ?? "none")")
                // Variant-pick observability: whether the output pipeline is HDR-eligible, plus which master
                // variant latched. The DV variant and the range-unlabeled lifeboat differ by 100 kbps of
                // BANDWIDTH, so the access log's indicatedBitrate names the pick; it is -1 until the first
                // access-log event, which is logged as-is (fail-soft, not an error).
                let indicatedBitrate = item.accessLog()?.events.last?.indicatedBitrate ?? -1
                DiagnosticsLog.log("avplayer", "readyToPlay variant: eligibleForHDRPlayback=\(AVPlayer.eligibleForHDRPlayback) indicatedBitrate=\(Int(indicatedBitrate))")
                let host = (item.asset as? AVURLAsset)?.url.host ?? "?"
                VXProbeState.shared.setPlayer(state: "playing", source: host, engine: "avplayer")
                VXProbe.event("player", "ready \(host)")
                #if os(tvOS)
                // TRUE DOLBY VISION: re-assert the DV display mode with the REAL fps/size now that the item
                // is ready (the authoritative request already fired pre-attach in loadFile, per Tech Talk 503
                // ordering). Covers the remux lane (it only mounts for DV) AND any DV-flagged native route
                // (DV MP4/MOV/HLS); window:nil uses HDRDisplayMode's fallback window. reset() on stop()
                // returns the TV to its default mode.
                if isRemuxMounted || contentIsDolbyVision {
                    let size = item.presentationSize
                    let fps = item.tracks.first { $0.assetTrack?.mediaType == .video }?.assetTrack?.nominalFrameRate ?? 0
                    HDRDisplayMode.request(.dolbyVision, fps: Double(fps),
                                           width: Int(size.width), height: Int(size.height), in: nil)
                    VXProbe.log("dv", "AVPlayer ready -> re-asserted Dolby Vision display mode fps=\(fps) \(Int(size.width))x\(Int(size.height)) remux=\(isRemuxMounted)")
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
            guard item === self.item else { break }
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
            // [dv] the demotion edge: the AVPlayer item failed and the chrome will fall back to libmpv HDR10.
            // For a DV source this is the tail of the [dv] trail (a remux fail-soft usually preceded it), so
            // grepping [dv] shows route -> mount -> classify/fallback-reason -> this demotion in order.
            VXProbe.log("dv", "AVPlayer item .failed -> demoting to libmpv HDR10: \(ns?.localizedDescription ?? "?")")
            guard !fatalErrorEmitted else { break }
            fatalErrorEmitted = true
            emit(MPVProperty.endFileError, item.error?.localizedDescription ?? "Playback failed")
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
        guard let url = lastLoadURL else { return }
        if VortXRemuxHLSServer.deliveryEnabled,
           PlayerEngineRouter.dvRemuxEnabled(dvDisplayCapable: DVDisplaySupport.isCapable) {
            DiagnosticsLog.log("dv", "native DV \(fourcc) sample entry is not AVPlayer-decodable (black over audio) -> re-mounting \(url.host ?? "?") through the remux lane for hvc1 repair")
            VXProbe.log("dv", "native DV \(fourcc) -> remux re-mount (hvc1/dvh1 repair)")
            forceRemux = true
            loadFile(url, headers: lastLoadHeaders, live: lastLoadLive)
        } else {
            guard !fatalErrorEmitted else { return }
            fatalErrorEmitted = true
            DiagnosticsLog.log("dv", "native DV \(fourcc) sample entry is not AVPlayer-decodable and the remux lane is off -> demoting to libmpv HDR10")
            VXProbe.log("dv", "native DV \(fourcc) -> libmpv HDR10 (remux lane off)")
            emit(MPVProperty.endFileError, "Dolby Vision sample entry not decodable (\(fourcc))")
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
        if hasProducedPicture(atClock: position) {
            videoFrameEverProduced = true
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
            videoFrameEverProduced = true
            audioOverBlackSince = 0
            return
        }
        audioOverBlackFired = true
        // Respect an earlier fatal FIRST, before any logging: a genuine item .failed can land inside the
        // window, and the [dv] trail is triage-critical, so the watchdog must never log a demote claim for
        // a fallback that .failed actually caused.
        guard !fatalErrorEmitted else { return }
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

    @objc private func didPlayToEnd() {
        VXProbe.event("player", "endfile eof")
        emit(MPVProperty.endFileEof, nil)
    }
    @objc private func failedToEnd(_ note: Notification) {
        guard !fatalErrorEmitted else { return }
        fatalErrorEmitted = true
        let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        VXProbe.event("player", "endfile error \(err?.localizedDescription ?? "?")")
        emit(MPVProperty.endFileError, err?.localizedDescription ?? "Playback failed")
    }

    private func emit(_ name: String, _ data: Any?) {
        playDelegate?.propertyChange(propertyName: name, data: data)
    }

    /// Load the audio + subtitle selection groups off the asset (async, non-deprecated), cache them as
    /// [MPVTrack] (option index = id; mpv's -1 = off), then re-emit track-list so the chrome re-pulls.
    private func loadSelectionGroups() {
        guard let item = player.currentItem else { return }
        let asset = item.asset
        Task { @MainActor in
            let ag = try? await asset.loadMediaSelectionGroup(for: .audible)
            let sg = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard player.currentItem === item else { return }   // a newer file loaded meanwhile
            audioGroup = ag
            subGroup = sg
            audioTracks = ag.map { Self.mpvTracks(from: $0, type: "audio", item: item) } ?? []
            subTracks = sg.map { Self.mpvTracks(from: $0, type: "sub", item: item) } ?? []
            applyEmbeddedSubtitleTextStyle()   // P5: style native legible tracks from the start (best-effort)
            emit(MPVProperty.trackList, nil)
        }
    }

    private static func mpvTracks(from group: AVMediaSelectionGroup, type: String, item: AVPlayerItem) -> [MPVTrack] {
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { idx, opt in
            MPVTrack(id: idx, type: type, title: opt.displayName,
                     lang: opt.extendedLanguageTag ?? "", selected: opt == selected,
                     forced: opt.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
        }
    }

    private func teardownObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        // stop() is the normal teardown; this is a safety net if the engine is released without it.
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        observations.forEach { $0.invalidate() }
        NotificationCenter.default.removeObserver(self)   // matches teardownObservers(): drop AVPlayerItem note observers before dealloc
        remuxLoader?.invalidate()
        remuxHLSServer?.invalidate()
    }
}

extension AVPlayerEngineController: AVPictureInPictureControllerDelegate {}
#endif
