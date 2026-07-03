import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if os(iOS)
import AVKit   // AVRoutePickerView (in-player AirPlay button)
#endif

/// Full-screen native libmpv player for iOS / Mac, brought to parity with the tvOS `TVPlayerView`:
/// transport (play/pause, seek, skip ±10s), in-player SOURCE SWITCHING (hop to another loaded source
/// without backing out), grouped Audio / Subtitle panels (with sync + style controls), an Aspect/zoom
/// control, a playback-info overlay, skip-intro/outro pills, accent-themed chrome, and bounded
/// auto-recovery (stall watchdog + source failover) so a frozen / black-screen stream recovers in
/// place instead of dying. Observes `ThemeManager` so accent + app-text-size repaint it live.
/// A season episode the in-player Next / Prev / list navigates between. `label` is the display
/// string (e.g. "E2 · The Kingsroad"); `id` matches the stream/video id `PlaybackMeta` carries.
struct PlayerEpisodeRef: Identifiable, Equatable {
    let id: String
    let label: String
}

/// A resolved, ready-to-play episode handed back by the caller's `loadEpisode` closure: the picked
/// stream + its playable URL, the `PlaybackMeta` to record against, the chrome title, and the saved
/// resume offset. The caller owns the heavy lifting (load meta, rank, prime torrent, resume); the
/// player only hot-swaps to it in place, so there is no cover teardown between episodes.
struct PlayerEpisodeStream {
    let stream: CoreStream
    let url: URL
    let meta: PlaybackMeta
    let title: String
    let resume: Double
}

struct PlayerScreen: View {
    let url: URL
    let title: String
    var headers: [String: String]? = nil                    // behaviorHints.proxyHeaders for header-gated CDNs
    var resumeSeconds: Double = 0                            // saved position to resume from
    var hasNext: Bool = false                               // show the Next Episode button
    // Continue-Watching / quality-continuity parity with tvOS: when set, the working link is recorded
    // into LastStreamStore once playback actually starts, so a later CW tap can resume this exact
    // stream and reopening the title auto-picks the same quality. nil for ad-hoc plays (paste-a-link),
    // which have no library item to key the memory against. Mirrors TVPlayerView.LastStreamStore.record.
    var recordMeta: PlaybackMeta? = nil
    var recordQualityText: String? = nil                    // StreamRanking.signature(stream) of the launching stream
    var recordBingeGroup: String? = nil                     // behaviorHints.bingeGroup of the launching stream (CW binge continuity)
    var recordIsTorrent: Bool = false                       // stream rides the embedded torrent engine
    var recordDebridRef: DebridPlaybackRef? = nil           // native-debrid provenance, for CW reresolve of an expired link
    var isTrailer: Bool = false                             // a trailer preview: always plays in-app, never auto-routes external
    /// yt-direct adaptive pair (trailers): the separate AUDIO stream mpv mounts alongside the video-only
    /// `url` (`--audio-files`). Forces the libmpv engine (AVPlayer can't merge a second remote file).
    var audioSidecarURL: URL? = nil
    /// The release group of the CURRENTLY playing stream, updated on an in-player episode switch so the
    /// recorded binge group tracks the live episode (not the stale launch value). nil = use recordBingeGroup.
    @State private var curBingeState: String? = nil
    // In-player episode navigation (series only). The ordered season episodes + a closure resolving any
    // episode id to a ready-to-play stream let the player advance Next / Prev and at end-of-episode IN
    // PLACE (a smooth source hot-swap, no cover teardown). Empty for movies / ad-hoc plays. The caller
    // (iOSEpisodeStreams) owns the resolve, so ranking / direct-links / torrent-prime / resume stay in one
    // place. Declared here (right after the record-* inputs) so the call-site argument order is valid.
    // When `episodes` is non-empty the player derives Next/Prev from the CURRENT episode, ignoring the
    // legacy `hasNext` / `onNext`.
    var episodes: [PlayerEpisodeRef] = []
    var loadEpisode: ((String) async -> PlayerEpisodeStream?)? = nil
    /// Optional background pre-heat for the next episode's source (start a torrent's peer search, pull
    /// the first bytes of a direct file), called once around the episode's halfway point. Distinct from
    /// `loadEpisode`: it must NOT touch the engine's meta/player slot (that would hijack the current
    /// episode's progress), it only warms network I/O. Series detail wires it; nil elsewhere is a no-op.
    var warmNextEpisode: ((String) async -> Void)? = nil
    var onProgress: (Double, Double) -> Void = { _, _ in }   // periodic forward progress (TimeChanged)
    var onSeek: (Double, Double) -> Void = { _, _ in }       // exact position on user-seek (Seek)
    var onNext: () -> Void = {}                             // advance to the next episode (legacy, non-episode callers)
    let onClose: () -> Void

    // CoreBridge / account are injected at the iOS app root; the player reads them for in-player source
    // switching (alternate loaded streams) and add-on subtitles — exactly as tvOS does. They are
    // EnvironmentObjects, so no presenter (iOSDetailView / iOSRootView) needs to change to feed them.
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager      // observe accent + textScale so the chrome repaints live
    // Compact width (iPhone portrait/landscape) shrinks the inline volume slider so the top-bar icon cluster
    // does not crowd. Regular width (iPad, Mac) keeps the full slider. macOS reports `.regular`.
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// Whether the CURRENTLY playing stream is a Live stream (tv / channel / events): live engages
    /// libmpv's live-tuned read-ahead/reconnect, shows a "LIVE" indicator in place of the scrubber, and
    /// NO-OPs resume + progress. A torrent is never a true live HLS feed, so it stays VOD. The flag
    /// tracks the active source (a source hop / switch can change torrent-ness). Mirrors tvOS
    /// `isCurrentLiveStream`.
    private var isLive: Bool {
        guard let type = recordMeta?.type, LiveTypes.contains(type) else { return false }
        return !curIsTorrent
    }
    /// The launch stream's live-ness, used before the first source hop sets `curIsTorrent`.
    private var initialIsLive: Bool {
        guard let type = recordMeta?.type, LiveTypes.contains(type) else { return false }
        return !recordIsTorrent
    }
    /// Runtime live-detection (follow-up to OrigamiSpace #94): a stream is treated as live when its meta
    /// type says so (`isLive`) OR mpv reports it as non-seekable after playback has actually begun. A VOD
    /// becomes seekable once playback starts; a true live feed stays non-seekable, so a live stream typed
    /// as VOD still gets the live treatment (no resume / progress / mark-watched / warm-next / end-of-file
    /// auto-advance). The `hasStartedPlaying` guard is CRITICAL: a still-buffering VOD also reports
    /// non-seekable, so gating on it avoids mis-flagging every movie as live (which would disable resume
    /// and progress on all VOD). Only the runtime VOD-only guards use this; the load-time mpv mode keeps
    /// the type-based `isLive`.
    private var effectivelyLive: Bool {
        if isLive { return true }
        return hasStartedPlaying && !isSeekable
    }

    // MARK: Panels

    private enum Panel: Identifiable, Equatable {
        case speed, subtitles, subtitleSettings, audio, audioSettings, video, sources, episodes, info, playerSettings, sleep, quality, chapters
        var id: Int {
            switch self {
            case .speed: 0; case .subtitles: 1; case .subtitleSettings: 2; case .audio: 3
            case .audioSettings: 4; case .video: 5; case .sources: 6; case .info: 7
            case .playerSettings: 8; case .sleep: 9; case .episodes: 10; case .quality: 11
            case .chapters: 12
            }
        }
        var title: String {
            switch self {
            case .speed: "Playback Speed"; case .subtitles: "Subtitles"
            case .subtitleSettings: "Subtitle Settings"; case .audio: "Audio"
            case .audioSettings: "Audio Settings"; case .video: "Aspect Ratio"
            case .sources: "Sources"; case .info: "Playback Info"; case .playerSettings: "Player Settings"
            case .sleep: "Sleep Timer"; case .episodes: "Episodes"; case .quality: "Quality"
            case .chapters: "Chapters"
            }
        }
        /// Panels where picking a row is an unambiguous one-shot choice (a track, quality, source, or
        /// chapter): the panel closes after the tap so the user lands back on the video. Speed and aspect
        /// stay open (people flip between values to compare), as do the adjustment panels (sync / size /
        /// colour steppers, output mode, player settings, sleep) and the browse panels (info, episodes).
        var dismissesAfterPick: Bool {
            switch self {
            case .subtitles, .audio, .quality, .sources, .chapters: true
            default: false
            }
        }
    }
    /// A panel row: a section header (`isHeader`, not tappable), a selectable choice (with optional
    /// right-aligned `detail`), or a drill-in. Mirrors tvOS `OptionRow`.
    private struct Row: Identifiable {
        let id = UUID()
        let label: String
        var detail: String = ""
        var selected: Bool = false
        var isHeader: Bool = false
        /// Render the detail on its own line below the label, wrapping in full instead of truncating to
        /// one line. Used by the Info panel's filename row so a long release name stays fully readable.
        var wraps: Bool = false
        var apply: () -> Void = {}
    }

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    // Subtitle-sync nudge steps. Primary is 0.5s so a multi-second offset takes a few taps (5s = 10 taps, not
    // 50 at the old 0.1s); a fine 0.1s trim stays for exact alignment. Hardcoded for now (RemoteConfig later).
    private static let subSyncStep = 0.5
    private static let subSyncFine = 0.1
    private static let subSyncStepLabel = "0.5s"
    private static let subSyncFineLabel = "0.1s"

    /// Localize a display label whose English text is only known at runtime (e.g. a `SubtitleStyle` preset
    /// name). The English string doubles as the catalog key, so it resolves through `Localizable.xcstrings`
    /// and falls back to itself when no translation exists.
    private static func l10n(_ key: String) -> String { String(localized: LocalizedStringResource(stringLiteral: key)) }
    // "original" (default) = whole frame at correct aspect (panscan=0), like actual Stremio; "fill"
    // crops to fill (panscan=1); "stretch" distorts. Labels mirror tvOS's Aspect Ratio panel.
    private let sizeModes: [(raw: String, label: String, detail: String)] = [
        ("original", "Fit", "default"), ("fill", "Fill", "crop to screen"), ("stretch", "Stretch", "fill, distort")
    ]

    @StateObject private var coordinator = MPVMetalPlayerView.Coordinator()
    @StateObject private var scrubThumbnails = ScrubThumbnailsStore()
    @State private var hoverPreviewTime: Double?
    @State private var hoverPreviewRatio: CGFloat?
    @State private var lastLocalTrickplayCapture = -1000.0
    @State private var localTrickplayCaptureInFlight = false
    /// Wall-clock trickplay capture driver (player-agnostic backstop to the timePos-driven tick). Cancelled on
    /// disappear. See startTrickplayCaptureTimer.
    @State private var trickplayCaptureTimer: Task<Void, Never>?
    /// Capture cadence in seconds. Matches the local frame cache's ~10s tile interval and the community
    /// upload/vtt interval, so timer-driven and timePos-driven captures share one grid.
    private static let trickplayCaptureIntervalSecs: Double = 10
    @AppStorage("stremiox.videoSize") private var videoSize = "original"   // whole frame, correct aspect
    @AppStorage("stremiox.seekStep") private var seekStep = "10"            // skip-button step in seconds ("10"/"15"/"30")
    // In-player volume (D5). Persisted 0...100 (libmpv `volume` scale; AVPlayer maps to 0...1) so the level
    // survives across plays; mute is a separate persisted flag so muting never loses the level. Applied to the
    // live engine at playback start and on every change. iOS/Mac only (tvOS uses the system/TV volume).
    @AppStorage("stremiox.playerVolume") private var playerVolume = 100.0
    @AppStorage("stremiox.playerMuted") private var playerMuted = false
    @State private var appliedVolume = false               // the launch volume/mute apply runs once per load
    @State private var appliedSize = false
    @State private var appliedInitialResume = false   // the launch-offset seek runs once; switches use nudgeResume
    @State private var markedWatched = false           // ~90%/EOF watched marker fires once per title (mirrors tvOS)
    @State private var autoAddedThisPlayback = false    // D8/D9: the ~60s auto-add + watch-ping fires once per playback
    @AppStorage("stremiox.autoAddLibrary") private var autoAddLibrary = true   // "Auto-add watched to Library" (default ON)
    @State private var buffering = true
    @State private var currentTime = 0.0
    @State private var duration = 0.0
    @State private var bufferedTime = 0.0   // buffered-ahead edge (seconds) for the YouTube-style grey scrubber band
    @State private var lastReported = -1.0     // last whole-second progress pushed to stremio-core
    @State private var isPaused = false
    @State private var speed = 1.0
    @State private var audioTracks: [MPVTrack] = []
    @State private var subtitleTracks: [MPVTrack] = []
    @State private var appliedAutoTracks = false
    @State private var videoWidth = 0           // from mediaSummary; resolution is by WIDTH (2.40:1 4K not mislabeled 1440p)
    @State private var videoHeight = 0          // from mediaSummary, for the metadata line (#20)
    @State private var audioCodec = ""
    @State private var isHDR = false
    @State private var metadataLine = ""        // "4K · HDR · EAC3"-style line shown under the title
    @State private var controlsVisible = true
    @State private var scrubbing = false
    @State private var scrubTarget: Double = 0   // committed scrub position while dragging; avoids timePos fighting the thumb (#32)
    @State private var refreshTask: Task<Void, Never>?   // debounced panel/track refresh; cancellable so it can't outlive the player (#20)
    #if os(macOS)
    /// Display-sleep assertion held while the player is open (macOS parity with the iOS idle-timer
    /// disable): keeps the Mac from dimming / sleeping mid-movie. Ended on disappear.
    @State private var macSleepActivity: NSObjectProtocol?
    /// macOS player keyDown monitor for Space/Left/Right; see installMacKeyMonitor.
    @State private var macKeyMonitor: Any?
    #endif
    @State private var panel: Panel?
    @State private var panelRows: [Row] = []   // cached so a 4×/s clock tick doesn't re-rank a thousand sources
    @State private var forcedLandscape = false
    @State private var hideTask: Task<Void, Never>?
    // Sleep timer (#5): pause playback after a set time, or stop at the end of the current episode.
    @State private var sleepMinutes: Int? = nil        // nil = off (unless sleepAtEpisodeEnd)
    @State private var sleepAtEpisodeEnd = false        // stop at episode end instead of auto-advancing
    @State private var sleepDeadline: Date? = nil       // when the timed pause fires (for the countdown label)
    @State private var sleepTask: Task<Void, Never>?
    @State private var showExternalChooser = false   // "Play in another app" sheet
    #if !os(tvOS)
    // Skip-segment editor state (iOS/Mac only). Submits keyless to skip.vortx.tv; also to skipdb.tv
    // when the user has a community key. The editor is available for any tt####### title.
    @State private var showSkipDBEdit = false
    @State private var skipDBEditType: SkipDBSubmitView.SegmentType = .intro
    @State private var skipDBEditStart: Double = 0
    @State private var skipDBEditEnd: Double = 30
    @State private var skipDBSubmitting = false
    @State private var skipDBSubmitResult: Bool? = nil
    @State private var skipDBSubmitError: String? = nil
    @State private var skipDBSubmittedKeys: Set<String> = []
    @State private var skipDBPreviewing = false
    @State private var skipDBShowEndTime = true
    @State private var skipDBIntroEstimateMs: Int? = nil
    @ObservedObject private var apiKeys = ApiKeys.shared
    #endif
    @State private var externalLinkDead = false      // pre-flight probe found the stream URL dead before handoff
    @State private var subtitleLoadFailed = false    // an add-on subtitle download timed out / failed
    @State private var subtitleLoadingURL: String?   // an add-on subtitle is downloading (shows Loading… on its row)
    @State private var warmedEpisodeID: String?      // next-episode source already warmed this episode (F6 preload)
    @State private var showShare = false             // system share sheet
    @State private var grabbedFrame: GrabbedFrame?   // a captured still, pending the share sheet (#24 frame grab)
    // Current-episode tracking for in-place episode switching: seeded from the launch values, updated on
    // every Next/Prev/list switch so progress, the watched marker, Continue-Watching, skip timestamps,
    // and add-on subtitles all key off the episode ACTUALLY playing (not the one first opened).
    @State private var curMetaState: PlaybackMeta? = nil
    @State private var curTitleState: String? = nil
    @State private var switchingEpisode = false       // a Next/Prev/list switch is resolving its stream
    private var curMeta: PlaybackMeta? { curMetaState ?? recordMeta }
    private var curTitle: String { curTitleState ?? title }
    /// True while the skip-segment editor bar is open. Always false on tvOS (the editor is iOS/Mac
    /// only), so the EOF/auto-hide/up-next guards can reference it without per-call `#if` fences.
    private var skipEditActive: Bool {
        #if os(tvOS)
        return false
        #else
        return showSkipDBEdit
        #endif
    }

    // Subtitle / audio sync + style (parity with tvOS), persisted per-profile like the tvOS player.
    @State private var subDelay = 0.0
    @State private var audioDelay = 0.0
    @AppStorage(SubtitleStyle.Key.font) private var subFont = SubtitleStyle.defaultFont
    @AppStorage(SubtitleStyle.Key.size) private var subSize = SubtitleStyle.defaultSize
    @AppStorage(SubtitleStyle.Key.sizeScale) private var subSizeScale = 1.0
    @AppStorage(SubtitleStyle.Key.color) private var subColor = SubtitleStyle.defaultColor
    @AppStorage(SubtitleStyle.Key.background) private var subBackground = SubtitleStyle.defaultBackground
    // External subtitles from the account's subtitle add-ons, listed beside the file's embedded tracks.
    @State private var addonSubs: [AddonSubtitle] = []
    @State private var addedSubURLs: Set<String> = []
    @State private var addonSubsKey = ""

    // Community-subtitle system (pooled subs P2, sync offset P3, embedded upload P4). All fail-soft + gated.
    @State private var pooledSubs: [SubtitlePoolClient.PooledSubtitle] = []
    @State private var pooledSubsKey = ""                 // contentKey the pooled list belongs to
    @State private var addedPooledIDs: Set<Int> = []      // pooled subs already loaded into the player
    @State private var pooledSeededOffset = false         // the community offset was applied once this session
    @State private var embeddedUploadDone = false         // the embedded-track upload ran once this session
    @State private var offsetCaptureTask: Task<Void, Never>?   // debounced postOffset on a manual sync change
    /// One consistent release fingerprint per playback session, so fetch/upload/offset all agree. Recomputed
    /// on a source switch or once the real duration/fps land (nil until first computed).
    @State private var subFingerprint: String?
    @State private var subFingerprintKey = ""             // curURL the fingerprint was built for

    // Load failure / recovery state (mirrors TVPlayerView).
    @State private var loadFailed = false            // playback couldn't start (dead/uncached link)
    #if os(iOS) || os(macOS)
    @State private var avEngineFailed = false        // AVPlayer couldn't open this stream; fell back to libmpv
    /// The engine routing decision, LATCHED once at playback start (onAppear). Routing inputs are not all
    /// constant (`PlayerEngineRouter.dvRemuxEnabled(dvDisplayCapable:)` reads a RemoteConfig snapshot that can
    /// refresh mid-session), and `useAVPlayerEngine` is re-evaluated on every body render, so an unlatched flip
    /// yanked a playing stream into the other engine minutes in (the mid-playback "auto-switch to DV" report).
    /// Engine choice happens ONLY at start; the sole later transition is the failure demotion (avEngineFailed).
    @State private var engineLatch: Bool?
    /// Set when the AVPlayer engine failed and we demoted to libmpv. Error events from the dismounting
    /// AVPlayer engine can still land shortly after the swap; anything inside this grace window is stale and
    /// must not burn the fresh mpv load's retry budget (or paint the error overlay over a recovering play).
    @State private var avDemotedAt: Date?
    /// Transient engine notice ("Dolby Vision fallback…"), shown as a small capsule and auto-dismissed.
    @State private var engineNotice: String?
    @State private var engineNoticeTask: Task<Void, Never>?
    #endif
    @State private var loadErrorMsg = ""
    /// CW-resume only: set once we've waited for a freshly-loaded source after the stored link failed, so the
    /// wait-and-hop runs at most once per playback (no unbounded loop). Reset on each new media load.
    @State private var awaitedFreshSources = false
    @State private var hasStartedPlaying = false
    /// Latest mpv "seekable" flag. Defaults true so a VOD is never mis-flagged live before mpv reports;
    /// only consulted by `effectivelyLive` AFTER `hasStartedPlaying`. A true live feed stays false.
    @State private var isSeekable = true
    @State private var loadTimeout: Task<Void, Never>?
    @State private var reconnecting = false          // showing the "Recovering…" auto-retry state
    @State private var reconnectMsg = "Recovering…"
    @State private var autoRetryCount = 0
    @State private var autoRetryTask: Task<Void, Never>?
    private let maxAutoRetries = 2
    private let autoRetryBackoff = 1.2
    // The active stream (changes on a manual source switch or an automatic failover hop), seeded from
    // the launch url/headers in onAppear so the first load is unchanged.
    @State private var curURL: URL?
    @State private var curHeaders: [String: String]?
    @State private var curIsTorrent = false
    @State private var torrentWarmupsUsed = 0          // bounded torrent peer-discovery warm-up rounds
    @State private var torrentStatus: String?          // "Connecting to peers · N connected" shown during warm-up
    // Auto-failover: when a source spends its retry / stall budget, hop to the best-ranked UNTRIED
    // source instead of dropping the viewer at the error overlay (parity with tvOS).
    @State private var exhaustedURLs: Set<URL> = []
    @State private var sourceHops = 0
    private let maxSourceHops = 4
    @State private var recoveryDeadline: Task<Void, Never>?
    private let maxRecoverySeconds: Double = 150
    // Mid-playback stall recovery: a watchdog reloads / hops when the position freezes while NOT
    // buffering or paused (the black-screen / hard-stall case), bounded so a dead source still errors.
    @State private var stallWatchdog: Task<Void, Never>?
    @State private var lastObservedTime = -1.0
    @State private var stalledTicks = 0
    @State private var stallRecoveries = 0

    // Skip intro / outro (chapter-derived + crowd-sourced timings), shown as a pill while controls hide.
    @State private var skipSegments: [SkipSegment] = []
    @State private var chapterFractions: [Double] = []   // chapter boundary positions (0...1) for scrubber ticks
    @State private var upNextSuppressed = false           // user tapped Watch Credits: hide the band + don't auto-advance this episode
    @State private var apiSkipCandidates: [SegmentCandidate] = []
    @State private var currentSkip: SkipSegment?
    @State private var autoSkippedStarts: Set<Double> = []   // segment starts already auto-skipped this episode
    @AppStorage("stremiox.autoSkip") private var autoSkip = false
    @State private var skipFetchKey = ""
    @State private var skipFetchTask: Task<Void, Never>?

    // Playback-info overlay rows, refreshed while the Info panel is open.
    @State private var infoRows: [(String, String)] = []

    var body: some View {
        #if os(iOS)
        // Adaptive-HLS (.m3u8) streams play in AVPlayer (native ABR + AirPlay + PiP); libmpv, which can't
        // ramp HLS renditions mid-stream, keeps everything else. macOS keeps libmpv (its out-of-process
        // server can transcode HLS); tvOS routes HLS in TVPlayerView.
        if PlayerEngineRouter.currentOverride == .auto, HLSPlayerView.handles(url) {
            HLSPlayerView(url: url, title: curTitle, headers: headers, resumeSeconds: resumeSeconds,
                          onProgress: onProgress, onClose: onClose)
                .ignoresSafeArea()
                .statusBarHidden(true)
        } else {
            mpvBody
        }
        #else
        // macOS (#46): the AVPlayer engine now sits behind the SAME full chrome (playerSurface mounts
        // AVPlayerEngineView for Dolby Vision / the "Prefer AVPlayer" override, else libmpv), so the Mac no
        // longer drops to a bare AVKit player without the episode list / quality / sources panels.
        mpvBody
        #endif
    }

    #if os(iOS) || os(macOS)
    /// Whether to mount the AVFoundation engine instead of libmpv for this stream. In `auto`: HLS is already
    /// handled in `body` (the minimal HLSPlayerView), and now a **Dolby Vision** stream in an AVPlayer-playable
    /// container (MP4/MOV/M4V) auto-routes here for true DV passthrough (libmpv only tone-maps DV to SDR). The
    /// override (Always libmpv / Prefer AVPlayer) still wins. On an AVPlayer load failure we fall back to libmpv
    /// for this stream (`avEngineFailed`). The DV flag comes from the launching stream's quality text.
    private var useAVPlayerEngine: Bool {
        if avEngineFailed { return false }   // an AVPlayer load failure fell back to libmpv for this stream
        return engineLatch ?? routedToAVPlayer
    }

    /// The raw routing computation. Consulted once to seed `engineLatch` (and for the first renders before
    /// onAppear runs); never re-consulted mid-playback, so a RemoteConfig refresh can't flip the engine live.
    private var routedToAVPlayer: Bool {
        // A yt-direct adaptive pair NEEDS libmpv (the audio sidecar rides mpv --audio-files; AVPlayer
        // would play the video-only stream silent), so it bypasses AVPlayer routing entirely.
        if audioSidecarURL != nil { return false }
        let loopback = url.host == "127.0.0.1" || url.host == "localhost"
        let isDV = StreamRanking.isDolbyVision(recordQualityText ?? "")
        // Pass this display's DV capability so the DV mandate holds on macOS too (DV -> the remux->AVPlayer
        // lane on any DV-capable display). Evaluated once at play start (this feeds engineLatch in onAppear).
        return PlayerEngineRouter.engine(for: url, isTorrent: loopback, isDolbyVision: isDV,
                                         dvDisplayCapable: DVDisplaySupport.isCapable) == .avfoundation
    }
    #endif

    /// Whether the active player engine is AVFoundation. Mirrors tvOS's runtime check (the mounted controller's
    /// type), so the chrome can hide the rows AVPlayer has no equivalent for: external add-on subtitles and the
    /// subtitle-sync nudge (its setSubDelay is a no-op on AVPlayer). Falls back to the routing decision before
    /// the controller mounts so the gate is correct even on the first render.
    private var isAVPlayerActive: Bool {
        if coordinator.player is AVPlayerEngineController { return true }
        #if os(iOS) || os(macOS)
        return useAVPlayerEngine
        #else
        return false
        #endif
    }

    /// The video surface: the AVFoundation engine when routed there, otherwise libmpv. Both bind to the same
    /// Coordinator and feed the same `handleProperty`, so the surrounding overlay drives either unchanged.
    @ViewBuilder private var playerSurface: some View {
        #if os(iOS) || os(macOS)
        if useAVPlayerEngine {
            AVPlayerEngineView(coordinator: coordinator)
                .play(initialPlayback.url, headers: initialPlayback.headers)
                .live(initialIsLive)
                .onPropertyChange { _, name, data in handleProperty(name, data) }
                .ignoresSafeArea()
        } else {
            mpvSurface
        }
        #else
        mpvSurface
        #endif
    }

    @ViewBuilder private var mpvSurface: some View {
        MPVMetalPlayerView(coordinator: coordinator)
            .play(initialPlayback.url, headers: initialPlayback.headers, audioSidecar: audioSidecarURL)
            .live(initialIsLive)
            .onPropertyChange { _, name, data in handleProperty(name, data) }
            .ignoresSafeArea()
    }

    private var mpvBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            playerSurface

            // Reliable tap-to-toggle: a transparent hit-test layer over the video. The UIKit
            // recognizer on the Metal view frequently missed taps (you had to tap many times);
            // a SwiftUI contentShape layer catches every tap. The controls sit above it, so their
            // buttons still work and a tap on empty space falls through here to toggle.
            Color.clear.contentShape(Rectangle()).onTapGesture { toggleControls() }.ignoresSafeArea()
                .accessibilityLabel("Show player controls")
                .accessibilityAction { toggleControls() }

            if (buffering || reconnecting) && !loadFailed { bufferingOverlay }

            // Skip pill shows only while watching (controls hidden); suppressed once the Up Next band is up
            // so the two end-of-episode prompts never stack.
            if let seg = currentSkip, !controlsVisible, panel == nil, !loadFailed, upNextRemaining == nil { skipPill(seg) }

            // Render controls UNCONDITIONALLY (just faded/non-interactive when hidden) so VoiceOver can
            // still reach them when auto-hidden — otherwise a hidden bar drops out of the a11y tree (#31).
            if !loadFailed {
                controls.opacity(controlsVisible ? 1 : 0).allowsHitTesting(controlsVisible)
            }

            if upNextRemaining != nil, panel == nil, !loadFailed, hasStartedPlaying { upNextBand }

            #if os(iOS) || os(macOS)
            // Transient engine notice (e.g. the Dolby Vision -> HDR10 demotion), top-centred and auto-hiding.
            if let notice = engineNotice {
                VStack {
                    Text(notice)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(.top, 24)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
            #endif

            if let panel { selectionSheet(panel) }

            if loadFailed { loadErrorOverlay }

            // Always-present escape hatch until the first frame arrives: a top-most close button so the
            // player is NEVER a trap, even with controls auto-hidden and the spinner covering the
            // tap-to-restore layer. macOS has no Esc/▶︎ remote fallback, so this is the only reliable
            // way out of a stuck load. Disappears once playback starts (the normal controls take over).
            if !hasStartedPlaying {
                VStack {
                    HStack {
                        Button { leavePlayback() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                                .padding(12).background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)   // ⌘. / Esc on macOS
                        .accessibilityLabel("Close player")
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.horizontal).padding(.top, 12)
                .transition(.opacity)
                .zIndex(100)
            }

            #if os(macOS)
            // The visible pre-start close button vanishes once playback starts, taking its
            // .cancelAction shortcut with it. macOS has no remote/Esc fallback otherwise, so keep an
            // always-present hidden Esc handler so ⌘. / Esc closes the player at any point (#14).
            Button { leavePlayback() } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .hidden()
            // Space/Left/Right are handled by an NSEvent keyDown monitor (installMacKeyMonitor), not
            // SwiftUI .keyboardShortcut: AppKit gives unmodified arrows+Space to the Metal NSView's
            // keyDown:, so hidden-button shortcuts never fired. The Esc/.cancelAction handler above stays.
            #endif
        }
        .animation(.easeOut(duration: 0.3), value: upNextRemaining != nil)
        #if os(iOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
        .tint(Theme.Palette.accent)
        .onAppear {
            #if os(iOS) || os(macOS)
            // Auto-route to the user's chosen default external player (Infuse / VLC), when one is set, for a
            // header-free direct/debrid stream. Torrents, header-gated streams (external apps can't apply our
            // request headers), loopback URLs, and trailers (a direct trailer URL is structurally identical
            // to a debrid movie URL, so it would otherwise be hijacked) stay in the built-in player.
            if !isTrailer, (headers?.isEmpty ?? true), ExternalPlayer.routeToDefaultIfSet(url, isTorrent: recordIsTorrent) {
                onClose(); return
            }
            #endif
            curURL = url; curHeaders = headers; curIsTorrent = recordIsTorrent
            #if os(iOS) || os(macOS)
            if engineLatch == nil { engineLatch = routedToAVPlayer }   // engine picked ONCE per playback
            #endif
            scrubThumbnails.configure(localCacheKey: trickplayLocalCacheKey)
            configureCommunityTrickplayProvisional()
            startTrickplayCaptureTimer()   // wall-clock capture backstop (fires on both engines)
            scheduleHide(); startLoadTimeout()
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true   // hold the screen awake while the player is open (parity with tvOS)
            if !isTrailer { PlayerOrientation.forceLandscape() }   // rotate to landscape as the stream opens, even under rotation lock
            #elseif os(macOS)
            // macOS has no idle-timer API; hold a display-sleep assertion so the Mac doesn't dim/sleep
            // mid-movie (the iOS/tvOS keep-awake parity that was missing on Mac).
            macSleepActivity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled,
                                                                     reason: "StremioX video playback")
            installMacKeyMonitor()
            #endif
        }
        .onDisappear {
            hideTask?.cancel(); loadTimeout?.cancel(); autoRetryTask?.cancel()
            stallWatchdog?.cancel(); recoveryDeadline?.cancel(); skipFetchTask?.cancel()
            refreshTask?.cancel(); sleepTask?.cancel(); trickplayCaptureTimer?.cancel()
            #if os(iOS) || os(macOS)
            engineNoticeTask?.cancel()
            #endif
            // Community trickplay: contribute this device's captured frames as a shared sprite-sheet
            // (first-writer-wins, background, gated; no-op if the community already had a set). Never
            // touches the player teardown below.
            scrubThumbnails.finishAndUploadIfNeeded(srcHeight: videoHeight)   // tag the set's source height (tvOS parity)
            NowPlayingCenter.clear()   // drop the Lock Screen / Control Center now-playing on close
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false  // let the screensaver / auto-lock resume once the player closes
            PlayerOrientation.release()                       // hand orientation back to the user's rotation lock
            #elseif os(macOS)
            if let token = macSleepActivity { ProcessInfo.processInfo.endActivity(token); macSleepActivity = nil }
            removeMacKeyMonitor()
            #endif
        }
        .confirmationDialog("Play in another app", isPresented: $showExternalChooser,
                            titleVisibility: .visible) {
            ForEach(ExternalPlayer.installed) { target in
                Button(target.name) {
                    // Pre-flight the link before handing off, so a dead debrid / CDN URL is caught here
                    // (we keep playing in the built-in player and say so) instead of bouncing the user
                    // into Infuse / VLC's own load error. Loopback torrents probe as alive instantly.
                    Task { @MainActor in
                        guard await ExternalPlayer.probeAlive(curURL ?? url) else { externalLinkDead = true; return }
                        // Handed off, stop local playback so the stream isn't decoded twice.
                        if ExternalPlayer.open(target, stream: curURL ?? url), !isPaused {
                            coordinator.player?.togglePause()
                        }
                    }
                }
            }
            Button("Share or open in…") { showShare = true }
            Button("Copy stream link") {
                Haptics.tap()
                #if canImport(UIKit)
                UIPasteboard.general.url = curURL ?? url
                #elseif canImport(AppKit)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString((curURL ?? url).absoluteString, forType: .string)
                #endif
            }
            if let magnet = magnetLink {
                Button("Copy magnet link") {
                    Haptics.tap()
                    #if canImport(UIKit)
                    UIPasteboard.general.string = magnet.absoluteString
                    #elseif canImport(AppKit)
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(magnet.absoluteString, forType: .string)
                    #endif
                }
            }
            // Every playable source loaded for this title, newline-joined — handy for sending the whole
            // ranked list at once. Only shown when more than one source is actually loaded (a single
            // source is already covered by "Copy stream link").
            if allSourceLinks.count > 1 {
                Button("Copy all source links") {
                    Haptics.tap()
                    let joined = allSourceLinks.joined(separator: "\n")
                    #if canImport(UIKit)
                    UIPasteboard.general.string = joined
                    #elseif canImport(AppKit)
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(joined, forType: .string)
                    #endif
                }
            }
            Button("Cancel", role: .cancel) { scheduleHide() }
        } message: {
            Text(externalChooserMessage)
        }
        .alert("Stream unavailable", isPresented: $externalLinkDead) {
            Button("OK", role: .cancel) { scheduleHide() }
        } message: {
            Text("That link is not responding right now. Try a different source.")
        }
        .alert("Subtitle unavailable", isPresented: $subtitleLoadFailed) {
            Button("OK", role: .cancel) { scheduleHide() }
        } message: {
            Text("That subtitle source did not respond in time. Try another one.")
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: [curURL ?? url]) }
        .sheet(item: $grabbedFrame) { ShareSheet(items: [$0.url]) }
    }

    // MARK: - Property handling

    private func handleProperty(_ name: String, _ data: Any?) {
        switch name {
        case MPVProperty.pausedForCache:
            if let b = data as? Bool { buffering = b }
        case MPVProperty.videoParamsSigPeak:
            if let p = data as? Double { isHDR = p > 1.0; metadataLine = computeMetadataLine() }
        case MPVProperty.timePos:
            if let d = data as? Double {
                if d > 0, !hasStartedPlaying {      // playback actually began
                    hasStartedPlaying = true
                    loadTimeout?.cancel(); autoRetryTask?.cancel()
                    recoveryDeadline?.cancel(); recoveryDeadline = nil
                    reconnecting = false; loadFailed = false
                    autoRetryCount = 0; stallRecoveries = 0
                    recordLastStream()              // remember this working link for CW direct-resume (parity with tvOS)
                    // Lock Screen / Control Center transport. Relative mpv seek so the skip always works off
                    // the LIVE position (a captured currentTime would be stale in these long-lived targets).
                    NowPlayingCenter.wireCommands(
                        togglePause: { coordinator.player?.togglePause() },
                        seek: { delta in coordinator.player?.seek(by: delta) },
                        stepSeconds: seekStepSeconds)
                    fetchPooledSubtitles()          // community-subtitle pool (P2/P3), fail-soft + gated
                    uploadEmbeddedSubtitlesIfNeeded()   // best-effort pooling of the file's own text tracks (P4)
                    applyPersistedVolume()          // restore the saved in-player volume + mute (D5)
                    startStallWatchdog()            // arm mid-playback freeze detection
                    fetchSkipTimestamps()           // crowd intro/outro spans (disk-cached, non-blocking)
                    fetchAddonSubtitles()
                }
                if !scrubbing {
                    currentTime = d
                    #if !os(tvOS)
                    if skipDBPreviewing, d >= skipDBEditStart {
                        skipDBPreviewing = false
                        coordinator.player?.seek(to: skipDBEditEnd)
                    }
                    #endif
                    updateCurrentSkip(at: d)
                    NowPlayingCenter.update(title: curTitle, elapsed: d, duration: duration, paused: isPaused)
                    // Provision the community key off meta.runtime the moment the behind-playback meta lands
                    // (idempotent; no-op once keyed), so capture starts even without a duration event.
                    configureCommunityTrickplayProvisional()
                    maybeCaptureLocalTrickplay(at: d)
                    // Live streams must NOT write a resume offset: their "position" is just elapsed
                    // wall-clock of the buffer, and persisting it would make a later open seek into a
                    // bogus offset (or drop a fake Continue-Watching entry).
                    if !effectivelyLive, duration > 0, d - lastReported >= 5 {   // push progress ~every 5s
                        lastReported = d
                        onProgress(d, duration)
                    }
                    // ~60s in → the user is really watching this: auto-add to the Library (D8) and send the
                    // anonymized fleet watch ping (D9), each once per playback. Both are idempotent + gated
                    // (D8 by the setting + per-profile dedup; D9 by MoatConsent + per-title/day dedup), so a
                    // resume that starts past 60s, a source hop, or an episode switch never double-fires here
                    // for the same title. Skipped for live (no library/ranking meaning) and ad-hoc plays.
                    if !autoAddedThisPlayback, !effectivelyLive, d >= 60, let m = curMeta {
                        autoAddedThisPlayback = true
                        LibraryAutoAdd.addIfNeeded(meta: m, core: core, enabled: autoAddLibrary)
                        WatchSignalClient.ping(contentId: m.libraryId, type: m.type)
                    }
                    // Halfway through a series episode → warm the NEXT episode's source in the
                    // background (start its torrent's peer search, pull the first bytes of a direct
                    // file) so auto-advance isn't a cold start. Purely additive: the actual advance
                    // still resolves through loadEpisode, so progress reporting and engine binding are
                    // unchanged — this only pre-heats the slow I/O the next open would otherwise pay for.
                    if !effectivelyLive, duration > 60, d / duration >= 0.5 { warmNextIfNeeded() }
                    // ~90% in → flip the engine's watched marker live, so the title leaves Continue
                    // Watching / shows as watched without waiting for EOF (mirrors tvOS:180-183).
                    if !markedWatched, !effectivelyLive, duration > 0, d / duration >= 0.9, let m = curMeta {
                        markedWatched = true
                        core.markPlaybackWatched(m)
                    }
                }
            }
        case MPVProperty.duration:
            if let d = data as? Double {
                duration = d
                if !appliedSize, d > 0 {                 // re-apply the size mode on every (re)load
                    appliedSize = true
                    coordinator.player?.setVideoSize(videoSize)
                }
                // Resume from the LAUNCH offset only on the very first load. Source switches / stall
                // reloads resume at the live position via `nudgeResume`, so this must not fire again
                // (it would yank a mid-playback switch back to the original 0:00 launch offset).
                if !appliedInitialResume, d > 0 {
                    appliedInitialResume = true
                    if resumeSeconds > 5, resumeSeconds < d - 10 {   // resume where we left off
                        coordinator.player?.seek(to: resumeSeconds)
                        currentTime = resumeSeconds
                        lastReported = resumeSeconds
                    }
                }
                refreshSkipSegments()
                // Community trickplay: re-key on the REAL playback duration (authoritative bucket) and
                // unblock uploads. Capture already started from the provisional meta.runtime key, so a
                // debrid MKV that never delivers this event still captures + can upload.
                if d > 0, let m = curMeta {
                    scrubThumbnails.configureCommunity(imdbId: m.libraryId, season: m.season, episode: m.episode,
                                                       duration: d, isRealDuration: true)
                }
                // The real duration sharpens the release fingerprint: rebuild it and re-fetch the pool so the
                // rip-matched community sync offset seeds this exact encode (P3). Fail-soft + gated inside.
                if d > 0 { refreshSubFingerprint(force: true); fetchPooledSubtitles() }
            }
        case MPVProperty.seekable:
            // Runtime live-detection: a VOD turns seekable once playback starts, a live feed stays
            // non-seekable. `effectivelyLive` reads this only after `hasStartedPlaying`, so a transient
            // false during initial buffering can't mis-flag a movie as live.
            if let s = data as? Bool { isSeekable = s }
        case MPVProperty.demuxerCacheTime:
            // Buffered-ahead edge (absolute seconds) for the YouTube-style grey scrubber band. Fail-soft:
            // ignore non-finite / behind-playhead values so the band never runs backward or breaks the bar.
            if let d = data as? Double, d.isFinite, d >= currentTime { bufferedTime = d }
        case MPVProperty.pause:
            if let b = data as? Bool {
                isPaused = b
                // Reflect the play/pause state on the Lock Screen immediately (timePos stops ticking while
                // paused, so without this the now-playing rate would stay stuck at "playing").
                NowPlayingCenter.update(title: curTitle, elapsed: currentTime, duration: duration, paused: b)
            }
        case MPVProperty.trackList:
            refreshTracks()
            let summary = coordinator.player?.mediaSummary()
            videoWidth = summary?.width ?? 0; videoHeight = summary?.height ?? 0; audioCodec = summary?.audioCodec ?? ""
            metadataLine = computeMetadataLine()
            if !appliedAutoTracks, !audioTracks.isEmpty || !subtitleTracks.isEmpty {
                appliedAutoTracks = true
                autoSelectTracks()
            }
        case MPVProperty.endFileError:
            #if os(iOS) || os(macOS)
            // ANY AVPlayer failure, pre-start (a Profile 7 / TrueHD-only DV remux, a container AVPlayer
            // can't open) or MID-PLAY, demotes to libmpv IN PLACE: flipping avEngineFailed swaps
            // playerSurface to the mpv engine, which re-loads initialPlayback from scratch. A DV attempt
            // must never dead-end on the source-error screen (owner invariant).
            if coordinator.player is AVPlayerEngineController, !avEngineFailed {
                avEngineFailed = true
                avDemotedAt = Date()
                let resume = hasStartedPlaying ? currentTime : 0
                if StreamRanking.isDolbyVision(recordQualityText ?? "") {
                    showEngineNotice("Dolby Vision isn't supported for this file. Playing HDR10 instead.")
                }
                // Treat the mpv mount as a fresh load: full timeout window, no stale error/overlay state.
                appliedSize = false; appliedVolume = false; hasStartedPlaying = false; isSeekable = true
                buffering = true; loadFailed = false; loadErrorMsg = ""
                startLoadTimeout()
                if resume > 5 { nudgeResume(to: resume) }
                // The fresh mpv mount auto-loads the LAUNCH url; if this session had switched sources,
                // re-point it at the ACTIVE one once the controller exists.
                if let cu = curURL, cu != url {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard avEngineFailed, !Task.isCancelled else { return }
                        loadIntoPlayer(cu, headers: curHeaders, live: isLive)
                    }
                }
                return
            }
            // Stale error from the just-dismounted AVPlayer engine (a queued event can land after the swap):
            // swallow it so it never burns the fresh mpv load's retry budget or paints the error overlay.
            if let t = avDemotedAt, Date().timeIntervalSince(t) < 2 { return }
            #endif
            if !hasStartedPlaying {                  // only flag failures BEFORE playback
                handleLoadFailure((data as? String) ?? "")
            }
        case MPVProperty.endFileEof:
            // Mark watched if the 90% tick didn't already (short clips), then advance or finish.
            if !markedWatched, !effectivelyLive, let m = curMeta { markedWatched = true; core.markPlaybackWatched(m) }
            if sleepAtEpisodeEnd {
                // Sleep timer set to "End of episode": this one finished, so stop here. Do NOT auto-advance,
                // and do NOT finishedWatching (that would clear the whole series from Continue Watching).
                sleepAtEpisodeEnd = false
                DiskCacheSetting.clearCache()   // terminal: drop the finished title's on-disk buffer
                onClose()
            } else if upNextSuppressed {
                // User chose "Watch Credits": play through to the end, then stop here instead of
                // auto-advancing. The episode is already marked watched above, so Continue Watching
                // rolls to the next episode on its own without yanking the viewer out of the credits.
                DiskCacheSetting.clearCache()   // terminal: drop the finished title's on-disk buffer
                onClose()
            } else if canNextEpisode, let i = episodeIndex, !skipEditActive {
                // In-place advance to the next episode: KEEP the cache (the same player keeps playing).
                // Suppressed while the skip editor is open so an end-of-credits edit isn't yanked away.
                goToEpisode(episodes[i + 1].id, autoAdvance: true)
            } else if hasNext, !skipEditActive {
                onNext()                                  // legacy non-episode caller (in-place)
            } else if !skipEditActive {
                // Finished (movie or last episode): rewind the title OUT of Continue Watching. The engine
                // keeps any item with time_offset > 0 in the rail, so without this a finished title lingers
                // at its end position forever (the "CW never clears" report). Mirrors tvOS autoAdvance:1479.
                if let m = curMeta { core.finishedWatching(libraryId: m.libraryId) }
                DiskCacheSetting.clearCache()   // terminal: drop the finished title's on-disk buffer
                onClose()
            }
        default: break
        }
    }

    /// Helper text for the "Play in another app" sheet, names installed players, or nudges the
    /// user to install one (in the Simulator none are installed, so this shows the install hint).
    private var externalChooserMessage: String {
        let names = ExternalPlayer.installed.map(\.name)
        if names.isEmpty {
            return "Send this stream elsewhere. Install Infuse or VLC to play directly from here."
        }
        return "Send this stream to \(names.joined(separator: " or ")), or share it elsewhere."
    }

    /// Persist the exact link that just started playing into LastStreamStore, so Continue-Watching can
    /// one-tap resume this stream and reopening the title auto-picks the same quality — the iOS/Mac twin
    // MARK: - Local trickplay capture

    private var trickplayLocalCacheKey: String {
        if let m = recordMeta { return "v:\(m.libraryId):\(m.videoId)" }
        return "u:\((curURL ?? url).absoluteString)"
    }

    /// Key community trickplay EARLY off a PROVISIONAL duration from the title's `meta.runtime`, so capture
    /// begins at the first positive timePos even when mpv never emits its `duration` event (a debrid
    /// direct-HTTP MKV frequently doesn't). Fail-soft + idempotent: no-op without a tt id / parseable
    /// runtime; the real mpv duration later re-keys the exact bucket and unblocks uploads.
    private func configureCommunityTrickplayProvisional() {
        guard let m = curMeta else { return }
        if let loaded = core.metaDetails?.meta, loaded.id == m.libraryId,
           let secs = loaded.runtimeSeconds, secs > 0 {
            // A tmdb-keyed hub play often carries its imdb id in the loaded meta for free
            // (behaviorHints.defaultVideoId = "tt…" / "tt…:s:e"); prefer it so the store skips its
            // network resolve. The store resolves any remaining tmdb id itself.
            let freeTT = m.libraryId.hasPrefix("tt") ? nil : CommunityTrickplay.ttPrefix(loaded.behaviorHints?.defaultVideoId)
            scrubThumbnails.configureCommunity(imdbId: freeTT ?? m.libraryId, season: m.season, episode: m.episode,
                                               duration: secs, isRealDuration: false)
            return
        }
        // The engine's metaDetails can be nil or holding ANOTHER title at play time (hub detail ->
        // add-on detail -> play replaces it, or the load raced), which silently killed the provisional
        // key: whole sessions captured frames that never became eligible to upload. Log the miss and
        // self-heal with a one-shot runtime fetch; mpv's real duration (when it does arrive) still
        // re-keys exactly as before. A tmdb-keyed play resolves its tt id FIRST (Cinemeta only speaks
        // imdb), and the resolver caches the mapping for the store's own keying. Fail-soft on every step.
        NSLog("[trickplay] provisional key MISS: playing=%@ metaDetails=%@ (fetching runtime)",
              m.libraryId, core.metaDetails?.meta?.id ?? "nil")
        Task {
            var ttId = m.libraryId
            if !ttId.hasPrefix("tt") {
                guard ttId.lowercased().hasPrefix("tmdb"),
                      let tt = await CommunityTrickplay.resolveIMDbID(rawId: m.libraryId, seriesHint: m.season != nil) else {
                    NSLog("[trickplay] provisional key MISS stays: unresolvable id %@", m.libraryId)
                    return
                }
                ttId = tt
            }
            var secs = await Self.cinemetaRuntimeSeconds(kind: "movie", id: ttId)
            if secs <= 0 { secs = await Self.cinemetaRuntimeSeconds(kind: "series", id: ttId) }
            guard secs > 0 else {
                NSLog("[trickplay] provisional key MISS stays: no cinemeta runtime for %@", ttId)
                return
            }
            await MainActor.run {
                guard curMeta?.libraryId == m.libraryId else { return }   // still the same title
                scrubThumbnails.configureCommunity(imdbId: ttId, season: m.season, episode: m.episode,
                                                   duration: secs, isRealDuration: false)
            }
        }
    }

    /// One-shot Cinemeta runtime for the provisional trickplay key when the engine meta is unavailable
    /// or mismatched at play time. Returns 0 on any miss (network, shape, unparseable runtime).
    private static func cinemetaRuntimeSeconds(kind: String, id: String) async -> Double {
        guard let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(kind)/\(id).json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = obj["meta"] as? [String: Any] else { return 0 }
        return parseRuntimeSeconds(meta["runtime"] as? String)
    }

    /// Minimal twin of CoreMeta.runtimeSeconds for a raw Cinemeta runtime string ("92 min", "1h 32m",
    /// "2:05:00"). Kept here because the raw JSON path above never decodes a full CoreMeta.
    private static func parseRuntimeSeconds(_ raw: String?) -> Double {
        guard let r = raw?.lowercased().trimmingCharacters(in: .whitespaces), !r.isEmpty else { return 0 }
        if r.contains(":") {
            let p = r.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if p.count == 3 { return Double(p[0] * 3600 + p[1] * 60 + p[2]) }
            if p.count == 2 { return Double(p[0] * 60 + p[1]) }
        }
        if let hRange = r.range(of: #"\d+\s*h"#, options: .regularExpression) {
            let h = Int(r[hRange].filter(\.isNumber)) ?? 0
            var mins = 0
            if let mRange = r.range(of: #"\d+\s*m"#, options: .regularExpression,
                                    range: hRange.upperBound..<r.endIndex) {
                mins = Int(r[mRange].filter(\.isNumber)) ?? 0
            }
            return Double(h * 3600 + mins * 60)
        }
        let minutes = Int(r.prefix { $0.isNumber }) ?? 0
        return Double(minutes * 60)
    }

    private func maybeCaptureLocalTrickplay(at time: Double) {
        // Player-AGNOSTIC capture: both engines emit MPVProperty.timePos (libmpv's coalesced tick and the
        // AVPlayer engine's periodic time observer), so this drives capture on Mac/iOS for libmpv AND AVPlayer.
        // A parallel wall-clock timer (startTrickplayCaptureTimer) is the belt-and-suspenders backstop for a
        // stream whose timePos events are sparse/coalesced. Both funnel through captureTrickplayFrame.
        guard !scrubbing, !buffering, !isPaused else { return }
        guard time - lastLocalTrickplayCapture >= Self.trickplayCaptureIntervalSecs else { return }
        captureTrickplayFrame(at: time)
    }

    /// The one place a trickplay frame is grabbed (from either capture driver). Guards the in-flight flag,
    /// stamps the cadence, and logs each stage so a silent pool can be traced from a terminal run: which gate
    /// refused, whether captureFrameJPEGData returned nil (no output attached / protected frame), and whether
    /// the frame was recorded. Engine-agnostic: uses whatever `coordinator.player` is mounted.
    private func captureTrickplayFrame(at time: Double) {
        guard !localTrickplayCaptureInFlight else { return }
        guard let player = coordinator.player else { NSLog("[tp-cap] no player mounted at %.0fs", time); return }
        lastLocalTrickplayCapture = time
        localTrickplayCaptureInFlight = true
        let engine = (player is AVPlayerEngineController) ? "avplayer" : "libmpv"
        // In-flight watchdog: the libmpv capture is serviced on mpv's VO thread inside nextDrawable(), which
        // only ticks while the layer is actively rendering. If the VO thread is momentarily idle the handler
        // may never fire, and without this the in-flight flag would wedge true forever (every later capture
        // silently skipped). Release it after 3s so the next tick can retry. Idempotent with the real handler.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self.localTrickplayCaptureInFlight else { return }
            self.localTrickplayCaptureInFlight = false
            NSLog("[tp-cap] %@ capture at %.0fs never serviced (VO idle) - releasing guard", engine, time)
        }
        player.captureFrameJPEGData(maxWidth: 480) { data in
            watchdog.cancel()
            self.localTrickplayCaptureInFlight = false
            guard let data else {
                NSLog("[tp-cap] %@ captureFrameJPEGData returned NIL at %.0fs (no video output / protected / not-ready)", engine, time)
                return
            }
            NSLog("[tp-cap] %@ captured %d bytes at %.0fs", engine, data.count, time)
            self.scrubThumbnails.recordCapturedFrameData(data, at: time)
        }
    }

    /// Wall-clock capture driver: a repeating ~10s timer, gated on active playback, that captures a frame off
    /// the LIVE player position regardless of how often (or whether) the engine emits timePos. This is the
    /// player-agnostic guarantee the trickplay mandate needs: on a 4K/HDR/DV debrid stream where mpv coalesces
    /// or never emits a steady timePos, the timer still fires. Cheap: one capture per interval, same in-flight
    /// guard + cadence stamp as the timePos path, so the two never double-capture the same second.
    private func startTrickplayCaptureTimer() {
        trickplayCaptureTimer?.cancel()
        trickplayCaptureTimer = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.trickplayCaptureIntervalSecs))
                guard !Task.isCancelled else { return }
                guard hasStartedPlaying, !scrubbing, !buffering, !isPaused else { continue }
                guard let player = coordinator.player else { continue }
                let now = player.playbackPositionSeconds
                let t = now > 0 ? now : currentTime
                guard t > 0, t - lastLocalTrickplayCapture >= Self.trickplayCaptureIntervalSecs else { continue }
                captureTrickplayFrame(at: t)
            }
        }
    }

    // MARK: - Volume (D5)

    /// Apply the persisted volume level + mute state to the live engine. Called once per load at playback
    /// start; the launch mount begins at the engine's default (100%), so this restores the user's chosen level
    /// (and re-applies after a source switch / engine demotion, which re-mount the engine). Idempotent per load.
    private func applyPersistedVolume() {
        guard !appliedVolume else { return }
        appliedVolume = true
        coordinator.player?.setVolume(playerVolume)
        coordinator.player?.setMuted(playerMuted)
    }

    /// Set the live volume from the slider (0...100), persist it, and un-mute if the user drags above 0 (moving
    /// the slider is an intent to hear audio). Dragging to 0 leaves `playerMuted` as-is (0 volume already silent).
    private func setPlayerVolume(_ v: Double) {
        let clamped = max(0, min(100, v))
        playerVolume = clamped
        coordinator.player?.setVolume(clamped)
        if clamped > 0, playerMuted { playerMuted = false; coordinator.player?.setMuted(false) }
    }

    /// Toggle mute on the live engine + persist. Unmuting to a 0 level bumps the volume to a sensible default so
    /// the user actually hears something (a common expectation when tapping the speaker).
    private func togglePlayerMute() {
        Haptics.tap()
        let next = !playerMuted
        playerMuted = next
        coordinator.player?.setMuted(next)
        if !next, playerVolume <= 0 { playerVolume = 100; coordinator.player?.setVolume(100) }
        scheduleHide()
    }

    /// The speaker glyph reflecting the current level / mute state, for the volume button.
    private var volumeGlyph: String {
        if playerMuted || playerVolume <= 0 { return "speaker.slash.fill" }
        if playerVolume < 34 { return "speaker.fill" }
        if playerVolume < 67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    /// #24 frame grab: capture the current frame at full quality (reusing the trickplay capture path at a
    /// higher maxWidth), write it to a temp JPEG, and present the share sheet so the still can be saved or
    /// sent anywhere. iOS / Mac only — tvOS has no share sheet.
    private func grabFrame() {
        coordinator.player?.captureFrameJPEGData(maxWidth: 2560) { data in
            guard let data else { return }
            let raw = recordMeta?.name ?? "VortX"
            let base = raw.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined()
            let name = "VortX-\(base.isEmpty ? "frame" : base)-\(Int(Date().timeIntervalSince1970)).jpg"
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            guard (try? data.write(to: target)) != nil else { return }
            DispatchQueue.main.async { self.grabbedFrame = GrabbedFrame(url: target) }
        }
    }

    /// A captured still awaiting the share sheet; Identifiable so it drives `.sheet(item:)`.
    private struct GrabbedFrame: Identifiable {
        let id = UUID()
        let url: URL
    }

    @ViewBuilder
    private func trickplayPopup(time: Double) -> some View {
        VStack(spacing: 4) {
            if let image = scrubThumbnails.image {
                #if canImport(AppKit)
                let img = Image(nsImage: image)
                #else
                let img = Image(uiImage: image)
                #endif
                img.resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 320, height: 180)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(.white.opacity(0.2), lineWidth: 1))
            }
            Text(timeString(time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
    }

    private func trickplayBubbleOffset(sliderWidth: CGFloat) -> CGFloat {
        // When no thumbnail, the pill is narrow (~70 pt); use that for centering/clamping.
        let popupWidth: CGFloat = scrubThumbnails.image != nil ? 320 : 70
        guard sliderWidth > 0 else { return 0 }
        let ratio: CGFloat
        if let r = hoverPreviewRatio { ratio = r }
        else if duration > 0 { ratio = CGFloat(scrubTarget / duration) }
        else { return 0 }
        return min(max(0, ratio * sliderWidth - popupWidth / 2), max(0, sliderWidth - popupWidth))
    }

    // MARK: - Continue Watching

    /// of TVPlayerView's record-on-start. Records the bare `curURL`/`curHeaders` the active source was
    /// launched with (a proxied loopback URL is rebuilt from these on resume), not the internal
    /// `initialPlayback` rewrite. No-op for ad-hoc plays with no `recordMeta` (e.g. paste-a-link).
    private func recordLastStream() {
        guard !effectivelyLive else { return }   // live has no resumable position → don't seed CW direct-resume
        guard let m = curMeta else { return }
        let ref = recordDebridRef
        LastStreamStore.record(libraryId: m.libraryId, entry: .init(
            videoId: m.videoId, url: (curURL ?? url).absoluteString, title: curTitle,
            season: m.season, episode: m.episode, name: m.name,
            poster: m.poster, type: m.type, qualityText: recordQualityText,
            bingeGroup: curBingeState ?? recordBingeGroup,
            torrent: curIsTorrent, savedAt: Date(), headers: curHeaders,
            debridService: ref?.service.rawValue, infoHash: ref?.infoHash,
            debridFileId: ref?.fileId, debridTorrentId: ref?.torrentId, fileIdx: ref?.fileIdx,
            linkSavedAt: ref != nil ? Date() : nil),
            profileID: ProfileStore.shared.activeID)
    }

    // MARK: - Load failure / auto-recovery

    /// The play URL/headers, routed through the embedded server's proxy when the stream declares
    /// request headers (the official-Stremio path that makes picky CDNs like ok.ru play). The server
    /// applies the headers + rewrites the HLS playlist, so mpv fetches plain loopback and needs no
    /// headers of its own; everything else loads directly with mpv-applied headers.
    private var initialPlayback: (url: URL, headers: [String: String]?) {
        playback(for: url, headers: headers)
    }
    private func playback(for u: URL, headers h: [String: String]?) -> (url: URL, headers: [String: String]?) {
        if let h, !h.isEmpty, let proxied = StremioServer.proxiedURL(for: u, headers: h) {
            return (proxied, nil)
        }
        return (u, h)
    }

    /// Hand the active stream to mpv with the right proxy routing + live tuning. Used by every reload
    /// (retry, stall recovery, source switch), mirroring tvOS `loadIntoPlayer`.
    private func loadIntoPlayer(_ u: URL, headers h: [String: String]?, live: Bool) {
        let p = playback(for: u, headers: h)
        // Keep the yt-direct audio sidecar ONLY when reloading the launch URL itself (a trailer retry);
        // any other target (episode/source switch) is a normal content stream and must load sidecar-free.
        let sidecar = (u == url) ? audioSidecarURL : nil
        coordinator.player?.loadFile(p.url, headers: p.headers, live: live, audioSidecar: sidecar)
    }

    /// A pre-playback failure (an endFileError before the first frame). For a torrent, the engine simply
    /// isn't warm yet so a quick retry won't help — warm it up (poll peers/bytes) then reload. Otherwise
    /// auto-retry a couple of times, then hop to another source, then show the manual error overlay.
    /// Now at full parity with tvOS `handleLoadFailure`, including the embedded-server torrent warm-up.
    private func handleLoadFailure(_ msg: String) {
        guard !hasStartedPlaying, !loadFailed else { return }
        loadErrorMsg = msg
        loadTimeout?.cancel()
        if curIsTorrent {
            // A torrent that errors (or never starts) before the first frame usually just isn't warm
            // yet — no peers / no data. mpv's reconnect=1 would otherwise buffer it forever. Warm the
            // engine, then hand back to mpv. Bounded + capped, so a dead torrent still errors.
            warmUpTorrent()
            return
        }
        if isLive {
            scheduleReconnect(reason: "live load failure", message: "Reconnecting live stream…", backoff: 0.5)
            return
        }
        guard autoRetryCount < maxAutoRetries else {
            reconnecting = false
            if hopToNextSource(reason: "load failed") { return }
            // CW-resume of a debrid/direct stream whose stored link expired (debrid URLs are time-limited):
            // iOSDirectResume kicks off a background reload of the title's streams, but they may not have
            // arrived yet, so the hop above found nothing. Wait briefly for the fresh streams and retry the
            // hop, rather than dead-ending on the "sources didn't load" overlay and forcing a manual re-pick.
            // One wait-cycle per playback; only for a metadata-backed (resumed) non-torrent play.
            if recordMeta != nil, !curIsTorrent, !awaitedFreshSources {
                awaitedFreshSources = true
                reconnectMsg = "Finding a fresh source…"; withAnimation { reconnecting = true }
                autoRetryTask?.cancel()
                autoRetryTask = Task { @MainActor in
                    for _ in 0 ..< 16 {   // up to ~4s for the background stream load to land
                        try? await Task.sleep(for: .milliseconds(250))
                        if Task.isCancelled { return }
                        if hopToNextSource(reason: "fresh sources after wait") { reconnecting = false; return }
                    }
                    reconnecting = false
                    withAnimation { loadFailed = true }
                }
                return
            }
            withAnimation { loadFailed = true }
            return
        }
        autoRetryCount += 1
        scheduleReconnect(reason: "load failure \(autoRetryCount)", message: "Recovering…", backoff: autoRetryBackoff)
    }

    /// Shared "show Recovering… then reload" path for transient pre-start hiccups and live reconnects.
    private func scheduleReconnect(reason: String, message: String, backoff: Double) {
        buffering = true
        reconnectMsg = message
        withAnimation { reconnecting = true }
        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(backoff))
            guard !Task.isCancelled, !hasStartedPlaying else { return }
            retryLoad(resetAutoRetries: false)
        }
    }

    /// Reload the current stream in place. Manual retries reset the auto-recovery budget; the auto-retry
    /// path passes `false` so its bounded count keeps counting down toward the overlay.
    private func retryLoad(resetAutoRetries: Bool = true) {
        if resetAutoRetries {
            autoRetryCount = 0; reconnecting = false
            // A deliberate manual retry re-arms the overall recovery cap: the firing deadline Task leaves
            // `recoveryDeadline` non-nil, so without this `startRecoveryDeadline`'s idempotency guard would
            // skip arming and the fresh attempt would spin uncapped. Mirrors the reset on a deliberate pick.
            recoveryDeadline?.cancel(); recoveryDeadline = nil
        }
        autoRetryTask?.cancel()
        withAnimation { loadFailed = false }
        buffering = true; hasStartedPlaying = false; isSeekable = true; appliedSize = false; loadErrorMsg = ""
        loadIntoPlayer(curURL ?? url, headers: curHeaders, live: isLive)
        startLoadTimeout()
    }

    /// Fail (or hop) if playback never starts: covers hard hangs that don't even emit an error.
    private func startLoadTimeout() {
        loadTimeout?.cancel()
        startRecoveryDeadline()   // arms the overall pre-start cap once; later hops leave it running
        loadTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !hasStartedPlaying, !loadFailed else { return }
            // THE HANG: a cold torrent never emits an end-file error (mpv reconnect=1 keeps retrying the
            // peerless loopback URL), so it would buffer forever with no recovery. Warm it up instead of
            // hopping/failing. Non-torrents time out to a hop/error as before.
            if curIsTorrent { warmUpTorrent(); return }
            if hopToNextSource(reason: "load timeout") { return }
            if loadErrorMsg.isEmpty { loadErrorMsg = "Timed out, the source never started." }
            withAnimation { loadFailed = true }
        }
    }

    /// Warm a cold torrent before handing back to mpv: poll the embedded server's stats.json for peer
    /// connections + bytes downloaded. mpv with reconnect=1 buffers a peerless torrent forever instead of
    /// erroring, so without this a torrent movie hangs at "loading" with no recovery. Bounded to 2 rounds
    /// × 90s and capped by the overall recovery deadline, so a genuinely dead torrent still surfaces the
    /// error overlay. Ported from tvOS `warmUpTorrent`.
    private func warmUpTorrent() {
        guard torrentWarmupsUsed < 2, let u = curURL, u.pathComponents.count >= 2 else {
            reconnecting = false; torrentStatus = nil
            if hopToNextSource(reason: "torrent warm-up exhausted") { return }
            if loadErrorMsg.isEmpty { loadErrorMsg = "The torrent never started sending data. Try another source." }
            withAnimation { loadFailed = true }
            return
        }
        torrentWarmupsUsed += 1
        let hash = u.pathComponents[1]
        buffering = true
        reconnectMsg = "Starting torrent…"
        withAnimation { reconnecting = true }
        torrentStatus = "Starting torrent…"
        NSLog("[Player] torrent warm-up round \(torrentWarmupsUsed) for \(hash)")
        loadTimeout?.cancel()
        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor in
            let deadline = Date().addingTimeInterval(90)
            var warm = false
            while Date() < deadline, !Task.isCancelled, !hasStartedPlaying {
                if let stats = await Self.torrentStats(hash: hash) {
                    let peers = stats.swarmConnections ?? stats.peers ?? 0
                    let speed = stats.downloadSpeed ?? 0
                    var line = "Connecting to peers · \(peers) connected"
                    if speed > 10_000 { line += String(format: " · %.1f MB/s", speed / 1_048_576) }
                    torrentStatus = line
                    if (stats.downloaded ?? 0) > 3_000_000 { warm = true; break }   // a few MB down = mpv can demux
                }
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled, !hasStartedPlaying else { torrentStatus = nil; return }
            torrentStatus = nil
            if warm {
                retryLoad(resetAutoRetries: true)   // hand the now-warm torrent back to mpv
            } else {
                loadErrorMsg = "The torrent never started sending data. Try another source."
                reconnecting = false
                withAnimation { loadFailed = true }
            }
        }
    }

    private struct TorrentStats: Decodable {
        let peers: Int?
        let swarmConnections: Int?
        let downloaded: Double?
        let downloadSpeed: Double?
    }

    /// Poll the embedded server's per-hash stats.json (peers + bytes), short timeout so a stalled
    /// request doesn't block the warm-up loop.
    private static func torrentStats(hash: String) async -> TorrentStats? {
        guard let url = URL(string: "\(StremioServer.base)/\(hash)/stats.json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(TorrentStats.self, from: data)
    }

    /// One wall-clock cap over the WHOLE pre-start recovery sequence (30s timeout × retries × 4 hops
    /// would otherwise chain into minutes of spinner on a dead title). Idempotent; reset on a fresh
    /// deliberate pick and on playback actually starting. Mirrors tvOS `startRecoveryDeadline`.
    private func startRecoveryDeadline() {
        guard recoveryDeadline == nil else { return }
        recoveryDeadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(maxRecoverySeconds))
            guard !Task.isCancelled, !hasStartedPlaying, !loadFailed else { return }
            loadTimeout?.cancel(); autoRetryTask?.cancel(); stallWatchdog?.cancel()
            if loadErrorMsg.isEmpty { loadErrorMsg = "Couldn't start playback after trying several sources." }
            withAnimation { loadFailed = true }
        }
    }

    /// Watch for a hard stall: the position frozen while NOT paused and NOT buffering (mpv's own cache
    /// stalls set `buffering`, so this fires only on the freeze / black-screen case). Reloads in place at
    /// the current position, then hops to another source, bounded so a genuinely dead source still
    /// errors. Disabled for live (its position is wall-clock and reconnect is handled differently).
    private func startStallWatchdog() {
        stallWatchdog?.cancel()
        lastObservedTime = -1; stalledTicks = 0
        stallWatchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard hasStartedPlaying, !isPaused, !buffering, !loadFailed, !isLive, duration > 0 else {
                    lastObservedTime = currentTime; stalledTicks = 0; continue
                }
                if lastObservedTime >= 0, abs(currentTime - lastObservedTime) < 0.25 {
                    stalledTicks += 1
                    if stalledTicks >= 3 {            // ~18s frozen with no buffering → recover
                        stalledTicks = 0
                        recoverFromStall()
                    }
                } else {
                    stalledTicks = 0
                    stallRecoveries = 0               // sustained good playback clears the budget
                }
                lastObservedTime = currentTime
            }
        }
    }

    private func recoverFromStall() {
        guard stallRecoveries < 3 else {
            // Repeated stalls on one source: hop to another at the current position, falling back to
            // the error overlay once candidates run out.
            if hopToNextSource(reason: "stall budget exhausted") { return }
            loadErrorMsg = "Playback kept stalling on this source."
            withAnimation { loadFailed = true }
            return
        }
        stallRecoveries += 1
        reconnectMsg = "Recovering…"
        withAnimation { reconnecting = true }
        // Resume where it froze: reload in place, the seek lands once duration is known again.
        let resume = currentTime
        appliedSize = false; hasStartedPlaying = false; isSeekable = true; buffering = true
        loadIntoPlayer(curURL ?? url, headers: curHeaders, live: isLive)
        if resume > 5 { nudgeResume(to: resume) }   // jump back to where it froze once mpv is ready
    }

    #if os(iOS) || os(macOS)
    /// Show a small transient notice over the video (engine demotion messages), auto-hidden after ~4s.
    private func showEngineNotice(_ text: String) {
        withAnimation { engineNotice = text }
        engineNoticeTask?.cancel()
        engineNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { engineNotice = nil }
        }
    }
    #endif

    /// Stall reload restarts the file at 0; nudge the playhead back to where it froze once mpv is ready,
    /// reusing the duration observer's seek. We stash the target and apply it on the next duration tick.
    @State private var pendingResume: Double?
    private func nudgeResume(to seconds: Double) {
        pendingResume = seconds
        Task { @MainActor in
            // Give the reload a beat to acquire duration, then seek directly (covers files that don't
            // re-emit duration on a same-file reload).
            try? await Task.sleep(for: .seconds(1.5))
            guard let target = pendingResume, !Task.isCancelled else { return }
            if duration > target + 5 {
                coordinator.player?.seek(to: target)
                currentTime = target
            }
            pendingResume = nil
        }
    }

    /// The pinned source for this title (#15), so failover keeps hopping to the pinned provider/quality
    /// when one is available, and falls back to plain ranking once it is exhausted.
    private var sourcePin: ResolvedPin? {
        guard let m = recordMeta else { return nil }
        return SourcePinStore.shared.effectivePin(SourcePinContext(metaId: m.libraryId, isSeries: m.type == "series"))
    }

    /// The best playable stream not yet tried for this title / episode, honouring the user's source
    /// ordering + continuity / binge hints + any pin. Returns nil when nothing untried remains.
    private func nextUntriedStream() -> CoreStream? {
        let remaining = currentSourceGroups.map { group in
            CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: group.streams.filter { s in
                guard let u = s.playableURL else { return false }
                return u != curURL && !exhaustedURLs.contains(u)
            })
        }
        return StreamRanking.best(remaining, continuity: recordQualityText, binge: nil, pin: sourcePin)
    }

    /// The playing source is dead (retry / stall budget ran out): mark it exhausted and hop to the
    /// next-best untried source automatically. Returns false when the hop budget is spent or nothing
    /// untried remains; the caller then shows the error overlay. Mirrors tvOS `hopToNextSource`.
    @discardableResult
    private func hopToNextSource(reason: String) -> Bool {
        // A trailer has no content stream of its own; nextUntriedStream() would fall back to whatever the
        // engine last loaded for this title, so a dead /yt route would silently play the ACTUAL movie.
        // Mirror tvOS (TVPlayerView.hopToNextSource): show "Trailer unavailable" and stop. Return true so
        // the caller treats the failure as handled and doesn't paint its own content-stream error.
        if isTrailer {
            DiagnosticsLog.log("player", "trailer load failed (\(reason)); not hopping to content streams")
            loadErrorMsg = "Trailer unavailable."
            withAnimation { loadFailed = true }
            return true
        }
        guard sourceHops < maxSourceHops, let stream = nextUntriedStream(), let newURL = stream.playableURL else { return false }
        var tried = exhaustedURLs
        if let dead = curURL { tried.insert(dead) }
        let resume: Double = hasStartedPlaying ? currentTime : resumeSeconds
        switchStream(to: stream, url: newURL, userInitiated: false)
        exhaustedURLs = tried
        sourceHops += 1
        if resume > 5 { nudgeResume(to: resume) }
        return true
    }

    /// Switch the playing source in place: reload the picked stream's URL and resume at the current
    /// position, so a buffering or low-quality source can be swapped without leaving the player. A
    /// deliberate pick resets the failover budget; an automatic hop restores it in `hopToNextSource`.
    private func switchStream(to stream: CoreStream, url newURL: URL, userInitiated: Bool, resumeOverride: Double? = nil) {
        guard newURL != curURL else { if userInitiated { close() }; return }
        if userInitiated { close() }
        let resume = resumeOverride ?? (hasStartedPlaying ? currentTime : resumeSeconds)
        curURL = newURL
        curHeaders = stream.requestHeaders
        curIsTorrent = stream.isTorrent
        if userInitiated {
            sourceHops = 0; exhaustedURLs = []
            recoveryDeadline?.cancel(); recoveryDeadline = nil
            stallRecoveries = 0
        }
        if resumeOverride != nil { currentTime = 0; duration = 0; bufferedTime = 0 }   // episode switch: brand-new media, reset the clock + buffered band
        // Re-key trickplay for the new source/episode and reset the local-capture throttle: otherwise the
        // new stream's capture stays gated by the PREVIOUS stream's lastLocalTrickplayCapture, so episodes
        // 2..N of a session captured nothing. configureCommunity is idempotent and re-keys on the new title.
        scrubThumbnails.configure(localCacheKey: trickplayLocalCacheKey)
        lastLocalTrickplayCapture = -1000; localTrickplayCaptureInFlight = false
        configureCommunityTrickplayProvisional()
        appliedSize = false; appliedAutoTracks = false; appliedVolume = false   // re-apply saved volume to the new engine
        hasStartedPlaying = false; isSeekable = true; buffering = true; loadErrorMsg = ""
        autoRetryCount = 0; reconnecting = false; autoRetryTask?.cancel(); awaitedFreshSources = false
        torrentWarmupsUsed = 0; torrentStatus = nil   // a new source is a fresh torrent → its own warm-up budget
        // A different rip: reset the community-subtitle session so the new fingerprint re-fetches pooled subs,
        // re-seeds its rip-matched offset, and can re-upload this rip's embedded tracks (P2/P3/P4).
        subFingerprint = nil; subFingerprintKey = ""; pooledSubsKey = ""; pooledSubs = []
        addedPooledIDs = []; pooledSeededOffset = false; embeddedUploadDone = false
        reconnectMsg = "Switching source…"
        loadIntoPlayer(newURL, headers: curHeaders, live: isLive)
        startLoadTimeout()
        if resume > 5 { nudgeResume(to: resume) }
    }

    // MARK: - Episode navigation (series; `episodes` is the ordered season list, switched in place)

    private var episodeIndex: Int? {
        guard let id = curMeta?.videoId, !episodes.isEmpty else { return nil }
        return episodes.firstIndex { $0.id == id }
    }
    private var canNextEpisode: Bool { episodeIndex.map { $0 + 1 < episodes.count } ?? false }

    /// Seconds left until auto-advance, when the Up Next band should be on screen: only with a next
    /// episode queued, a real runtime, the play head in the final stretch, and the user hasn't chosen to
    /// sit through the credits. nil hides the band. The EOF handler does the actual advance at 0.
    private var upNextRemaining: Int? {
        guard canNextEpisode, !upNextSuppressed, !skipEditActive, duration > 60, currentTime > 0 else { return nil }
        let remaining = duration - currentTime
        guard remaining > 0, remaining <= 20 else { return nil }
        return Int(remaining.rounded(.up))
    }
    /// The label of the episode that plays next, for the Up Next band.
    private var nextEpisodeLabel: String? {
        guard let i = episodeIndex, i + 1 < episodes.count else { return nil }
        return episodes[i + 1].label
    }

    /// Wall-clock time the title will finish ("Ends 10:45 PM"), from the remaining runtime. Tracks the
    /// scrub position while scrubbing. nil for live / before the duration is known.
    private var endsAtClock: String? {
        guard duration > 0 else { return nil }
        let remaining = max(0, duration - (scrubbing ? scrubTarget : currentTime))
        return "Ends \(Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened))"
    }

    /// The end-of-episode Up Next card: next-episode title, a countdown to auto-advance, and Play Now /
    /// Watch Credits. Shown bottom-trailing in the final stretch; touch/click, so no focus wiring needed.
    private var upNextBand: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("UP NEXT").font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.white.opacity(0.7))
                if let label = nextEpisodeLabel {
                    Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                }
                if let r = upNextRemaining {
                    Text("Playing in \(r)s").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 8)
            Button { upNextSuppressed = true } label: {
                Text("Watch Credits").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
            Button { goToNextEpisode() } label: {
                Label("Play Now", systemImage: "play.fill").font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Palette.onAccent)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Theme.Palette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: 480)
        .padding(.horizontal, 24).padding(.bottom, 96)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
    private var canPrevEpisode: Bool { (episodeIndex ?? -1) > 0 }

    private func goToNextEpisode() { if let i = episodeIndex, i + 1 < episodes.count { goToEpisode(episodes[i + 1].id) } }
    private func goToPrevEpisode() { if let i = episodeIndex, i > 0 { goToEpisode(episodes[i - 1].id) } }

    /// Fire the next-episode warm-up once per episode (F6 preload). Guarded so it runs a single time
    /// even though the time tick calls it every second past the halfway point, and only when a next
    /// episode exists and the caller supplied a warm closure.
    private func warmNextIfNeeded() {
        guard let warm = warmNextEpisode, canNextEpisode, let i = episodeIndex else { return }
        let nextID = episodes[i + 1].id
        guard warmedEpisodeID != nextID else { return }
        warmedEpisodeID = nextID
        Task { await warm(nextID) }
    }

    /// Switch to another episode in place: flush the current position, resolve the episode through the
    /// caller, then hot-swap the source and record against the new episode. No cover teardown — the
    /// chrome stays put and only the video reloads, the same feel as an in-player source switch.
    private func goToEpisode(_ videoId: String, autoAdvance: Bool = false) {
        guard let loadEpisode, !switchingEpisode else { return }
        switchingEpisode = true
        if duration > 0, currentTime > 0 { onProgress(currentTime, duration) }   // flush the outgoing episode
        withAnimation { panel = nil }
        buffering = true; reconnecting = true; reconnectMsg = "Loading episode…"
        Task {
            let resolved = await loadEpisode(videoId)
            switchingEpisode = false
            guard let es = resolved else {
                reconnecting = false; buffering = false
                if autoAdvance { onClose() }            // nothing playable on auto-advance: leave, don't hang on a spinner
                else { loadErrorMsg = "Couldn't load that episode" }
                return
            }
            curMetaState = es.meta
            curTitleState = es.title
            curBingeState = es.stream.behaviorHints?.bingeGroup   // keep recorded binge group on the live episode
            markedWatched = false
            autoAddedThisPlayback = false   // re-arm the 60s auto-add/watch-ping for the new episode (idempotent per show)
            upNextSuppressed = false   // re-arm the Up Next band for the new episode
            appliedInitialResume = true   // drive resume via nudgeResume below; skip the launch-offset path
            lastReported = -1
            switchStream(to: es.stream, url: es.url, userInitiated: true, resumeOverride: es.resume)
        }
    }

    private var bufferingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(.white)
            if let status = torrentStatus {   // live peer/byte progress during torrent warm-up
                Text(status).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.9))
            } else if reconnecting {
                Text(reconnectMsg).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .transition(.opacity)
    }

    private var loadErrorOverlay: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 46)).foregroundStyle(.yellow)
                Text(sourceHops > 0 ? "Tried \(sourceHops + 1) sources, none worked" : "This source didn't load")
                    .font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text(loadErrorHint).font(.callout).foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center).frame(maxWidth: 480).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    if hasAlternateSources {
                        Button { openPanel(.sources) } label: { Label("Other sources", systemImage: "rectangle.stack").padding(6) }
                    }
                    Button { retryLoad() } label: { Label("Retry", systemImage: "arrow.clockwise").padding(6) }
                    Button { leavePlayback() } label: { Label("Back", systemImage: "chevron.left").padding(6) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.Palette.accent).foregroundStyle(.white).padding(.top, 6)
            }
            .padding(40)
        }
        .transition(.opacity)
    }

    private var loadErrorHint: String {
        let base = "It may be uncached on your debrid (still downloading), offline, or an unsupported link. Try another source or go back."
        return loadErrorMsg.isEmpty ? base : base + "\n\n(\(loadErrorMsg))"
    }

    // MARK: - Controls

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerTransport
                Spacer()
                bottomBar
            }
        }
    }

    /// "4K · HDR · EAC3"-style line from the current video height + HDR + audio codec (tvOS parity #20),
    /// shown under the title so the user can tell what they actually got. Recomputed on track/HDR change.
    private func computeMetadataLine() -> String {
        var parts: [String] = []
        // Resolution is defined by WIDTH (4K is ~3840 wide at ANY aspect), so a 2.40:1 4K film (3840x1600)
        // is NOT mislabeled "1440p" off its 1600 height. Width when known, else a 16:9 height estimate.
        let res = videoWidth > 0 ? videoWidth : Int(Double(videoHeight) * 16.0 / 9.0)
        switch res {
        case 3000...:     parts.append("4K")
        case 2200..<3000: parts.append("1440p")
        case 1500..<2200: parts.append("1080p")
        case 1000..<1500: parts.append("720p")
        case 1..<1000:    if videoHeight > 0 { parts.append("\(videoHeight)p") }
        default:          break
        }
        if isHDR { parts.append("HDR") }
        if !audioCodec.isEmpty { parts.append(audioLabel(audioCodec)) }
        return parts.joined(separator: "  ·  ")
    }

    private func audioLabel(_ c: String) -> String {
        switch c.lowercased() {
        case "eac3":                 return "EAC3"
        case "ac3":                  return "AC3"
        case "truehd":               return "TrueHD"
        case "dts", "dts-hd", "dca": return "DTS"
        case "aac":                  return "AAC"
        case "flac":                 return "FLAC"
        case "opus":                 return "Opus"
        case "mp3":                  return "MP3"
        default:                     return c.uppercased()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            iconButton("chevron.down", label: "Close player") { leavePlayback() }
            if !curTitle.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text(curTitle).font(.headline.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(1).shadow(radius: 3)
                    if !metadataLine.isEmpty {
                        Text(metadataLine).font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75)).lineLimit(1).shadow(radius: 2)
                    }
                }
            }
            Spacer()
            if canPrevEpisode {
                iconButton("backward.end.fill", label: "Previous episode") { goToPrevEpisode() }
            }
            if canNextEpisode {
                iconButton("forward.end.fill", label: "Next episode") {
                    if duration > 0 { onProgress(currentTime, duration) }   // flush before advancing
                    goToNextEpisode()
                }
            } else if hasNext {
                iconButton("forward.end.fill", label: "Next episode") {
                    if duration > 0 { onProgress(currentTime, duration) }   // flush before advancing
                    onNext()
                }
            }
            #if os(iOS)
            // Manual landscape lock is an iOS-only affordance (macOS windows don't rotate).
            iconButton(forcedLandscape ? "arrow.down.right.and.arrow.up.left"
                                       : "arrow.up.left.and.arrow.down.right", label: "Toggle fullscreen") {
                forcedLandscape.toggle()
                coordinator.player?.setOrientation(landscape: forcedLandscape)
                scheduleHide()
            }
            #endif
            if !isLive {
                // Restart from 0:00 (tvOS parity #5): seek to the start and keep playing.
                iconButton("arrow.counterclockwise", label: "Restart") {
                    coordinator.player?.seek(to: 0)
                    currentTime = 0
                    if duration > 0 { onSeek(0, duration); lastReported = 0 }
                    if isPaused { coordinator.player?.togglePause() }   // restart implies resume
                    scheduleHide()
                }
            }
            #if !os(tvOS)
            // Skip-segment editor: any tt####### title qualifies. Submission is keyless via our
            // skip.vortx.tv worker, so no third-party key is required to open or use it.
            if let m = curMeta,
               m.libraryId.range(of: #"^tt\d{7,8}$"#, options: .regularExpression) != nil {
                iconButton(showSkipDBEdit ? "checkmark.bubble.fill" : "checkmark.bubble",
                           label: showSkipDBEdit ? "Close skip editor" : "Edit skip segments") {
                    if !showSkipDBEdit {
                        let snapped = (currentTime * 2).rounded() / 2
                        skipDBEditStart = max(0, snapped)
                        skipDBEditEnd = min(snapped + 30, duration > 0 ? duration : snapped + 60)
                        skipDBEditType = .intro
                        skipDBShowEndTime = true
                        skipDBSubmitResult = nil
                        skipDBSubmitError = nil
                        skipDBPreviewing = false
                    }
                    showSkipDBEdit.toggle()
                }
            }
            #endif
            #if os(iOS)
            AirPlayRoutePickerButton()   // start AirPlay from the player overlay (AVPlayer/HLS mirrors video, libmpv routes audio)
            #endif
            volumeControl   // D5: in-player volume slider + mute (libmpv `volume` / AVPlayer.volume), persisted
            iconButton("gearshape", label: "Player settings") { openPanel(.playerSettings) }   // decoder toggle + playback info (tvOS parity #22)
            iconButton("arrow.up.forward.app", label: "Play in another app") {       // hand off to Infuse / VLC / Share
                hideTask?.cancel()
                showExternalChooser = true
            }
        }
        .padding(.horizontal).padding(.top, 8)
    }

    /// In-player volume + mute (D5). The speaker button taps to toggle mute; a fixed-width inline slider sets
    /// the level. Both drive the live engine (libmpv `volume` 0-100 / AVPlayer.volume) and persist
    /// `stremiox.playerVolume` + `stremiox.playerMuted`. Fixed width keeps the top bar layout stable; dragging
    /// the slider holds the controls up (cancels the auto-hide), releasing re-arms it.
    private var volumeControl: some View {
        HStack(spacing: 4) {
            Button { togglePlayerMute() } label: {
                Image(systemName: volumeGlyph)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white).shadow(radius: 3)
                    .frame(width: 34, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playerMuted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { playerMuted ? 0 : playerVolume },
                                  set: { setPlayerVolume($0) }),
                   in: 0...100) { editing in if editing { hideTask?.cancel() } else { scheduleHide() } }
                .tint(Theme.Palette.accent)
                .frame(width: hSizeClass == .compact ? 60 : 92)   // narrower on compact iPhone so the top bar cluster doesn't crowd
                .accessibilityLabel("Volume")
        }
    }

    private var centerTransport: some View {
        HStack(spacing: 44) {
            // Skip back by the user's seek step (hidden for live — no fixed timeline to seek within).
            if !isLive {
                seekButton("gobackward.\(seekStep)", by: -seekStepSeconds)
            }
            Button { Haptics.tap(); coordinator.player?.togglePause(); scheduleHide() } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 50)).foregroundStyle(.white).shadow(radius: 8)
                    .frame(width: 100, height: 100)
            }
            .accessibilityLabel(isPaused ? "Play" : "Pause")
            if !isLive {
                seekButton("goforward.\(seekStep)", by: seekStepSeconds)
            }
        }
    }

    /// The seek-step setting as seconds, falling back to 10 if the stored value is somehow unparsable.
    private var seekStepSeconds: Double { Double(seekStep) ?? 10 }

    /// Seek relative to the play head, clamped to the timeline, and report it. Shared by the on-screen skip
    /// buttons and the macOS keyboard shortcuts.
    private func seekBy(_ delta: Double) {
        let target = min(max(currentTime + delta, 0), max(duration - 1, 0))
        coordinator.player?.seek(to: target)
        currentTime = target
        if duration > 0 { onSeek(target, duration); lastReported = target }
        scheduleHide()
    }

    private func seekButton(_ icon: String, by delta: Double) -> some View {
        Button {
            seekBy(delta)
        } label: {
            Image(systemName: icon).font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white).shadow(radius: 4).frame(width: 60, height: 60)
        }
        .accessibilityLabel(delta < 0 ? "Skip back 10 seconds" : "Skip forward 10 seconds")
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            if isLive {
                // Live: no seekable scrubber (there's no fixed duration to scrub within), just a LIVE
                // indicator. The user pauses/resumes; there's nothing to seek to.
                liveIndicator
            } else {
                HStack(spacing: 12) {
                    Text(timeString(currentTime)).font(.caption.monospacedDigit()).foregroundStyle(.white)
                    // Slider is wrapped in a GeometryReader so the trickplay bubble can be positioned
                    // relative to the knob and macOS hover can compute the preview time from cursor x.
                    GeometryReader { geo in
                        // macOS Slider track is inset by ~half the thumb diameter on each side.
                        let sliderInset: CGFloat = 10
                        let trackWidth = max(1, geo.size.width - sliderInset * 2)
                        // While dragging the thumb follows scrubTarget so an incoming timePos tick
                        // can't yank it back to the pre-seek position (#32). On release we commit.
                        Slider(value: Binding(get: { scrubbing ? scrubTarget : currentTime },
                                              set: { scrubTarget = $0; scrubThumbnails.show(time: $0) }),
                               in: 0...max(duration, 1)) { editing in
                            scrubbing = editing
                            if editing {
                                scrubTarget = currentTime; hideTask?.cancel()
                                hoverPreviewTime = nil; hoverPreviewRatio = nil
                            } else {
                                currentTime = scrubTarget
                                coordinator.player?.seek(to: scrubTarget)
                                if duration > 0 { onSeek(scrubTarget, duration); lastReported = scrubTarget }
                                scrubThumbnails.clear()
                                scheduleHide()
                            }
                        }
                        .tint(Theme.Palette.accent)
                        #if os(macOS)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                guard !scrubbing else { return }
                                let ratio = min(max(0, (loc.x - sliderInset) / trackWidth), 1)
                                hoverPreviewRatio = ratio
                                hoverPreviewTime = ratio * max(duration, 0)
                                scrubThumbnails.show(time: hoverPreviewTime!)
                            case .ended:
                                guard !scrubbing else { return }
                                hoverPreviewTime = nil; hoverPreviewRatio = nil
                                scrubThumbnails.clear()
                            }
                        }
                        #endif
                        // YouTube-style buffered-ahead band: a faint grey capsule from the playhead to the
                        // loaded edge, over the Slider's own track but under the thumb/ticks. Never intercepts
                        // the drag. Fail-soft: no buffered info (or behind the playhead) → nothing draws.
                        .overlay {
                            if duration > 0, !scrubbing {
                                let head = min(1, max(0, currentTime / duration))
                                let ahead = min(1, max(0, bufferedTime / duration))
                                if ahead > head {
                                    let sx = sliderInset + CGFloat(head) * trackWidth
                                    let w  = CGFloat(ahead - head) * trackWidth
                                    Capsule().fill(.white.opacity(0.42))
                                        .frame(width: max(1, w), height: 3)
                                        .position(x: sx + max(1, w) / 2, y: geo.size.height / 2)
                                        .allowsHitTesting(false)   // decorative; never intercept the Slider drag
                                }
                            }
                        }
                        // Chapter boundary ticks along the track (purely decorative, never intercept the
                        // Slider's own drag). Positioned within the same inset the Slider track uses.
                        .overlay {
                            ForEach(chapterFractions, id: \.self) { f in
                                Capsule().fill(.white.opacity(0.55))
                                    .frame(width: 2, height: 8)
                                    .position(x: sliderInset + CGFloat(f) * trackWidth, y: geo.size.height / 2)
                            }
                            .allowsHitTesting(false)
                        }
                        #if !os(tvOS)
                        // Loaded skip segments: faint coloured bands.
                        .overlay {
                            if duration > 0 {
                                ForEach(skipSegments) { seg in
                                    let sf = CGFloat(seg.start / duration)
                                    let ef = CGFloat(seg.end / duration)
                                    let sx = sliderInset + sf * trackWidth
                                    let w  = max(2, (ef - sf) * trackWidth)
                                    Capsule().fill(seg.kind == .intro ? Color.cyan.opacity(0.45)
                                                   : seg.kind == .recap ? Color.yellow.opacity(0.45)
                                                   : seg.kind == .credits ? Color.purple.opacity(0.45)
                                                   : Color.orange.opacity(0.45))
                                        .frame(width: w, height: 5)
                                        .position(x: sx + w / 2, y: geo.size.height / 2)
                                }
                                .allowsHitTesting(false)
                            }
                        }
                        // Segment being edited: bright band + start/end markers.
                        .overlay {
                            if showSkipDBEdit, duration > 0 {
                                let sf = CGFloat(skipDBEditStart / duration)
                                let ef = CGFloat(skipDBEditEnd   / duration)
                                let sx = sliderInset + sf * trackWidth
                                let ex = sliderInset + ef * trackWidth
                                let w  = max(2, ex - sx)
                                let cy = geo.size.height / 2
                                ZStack(alignment: .topLeading) {
                                    Rectangle().fill(Color.white.opacity(0.35))
                                        .frame(width: w, height: 6)
                                        .position(x: sx + w / 2, y: cy)
                                    Capsule().fill(Color.white)
                                        .frame(width: 3, height: 14)
                                        .position(x: sx, y: cy)
                                    Capsule().fill(Color.white)
                                        .frame(width: 3, height: 14)
                                        .position(x: ex, y: cy)
                                }
                                .allowsHitTesting(false)
                            }
                        }
                        #endif
                        // bottomLeading alignment: popup bottom anchors at slider bottom, grows upward.
                        // y: -28 lifts it 4 pt above the slider top (slider is 24 pt tall).
                        .overlay(alignment: .bottomLeading) {
                            if scrubbing || hoverPreviewTime != nil {
                                trickplayPopup(time: hoverPreviewTime ?? scrubTarget)
                                    .fixedSize()
                                    .offset(x: trickplayBubbleOffset(sliderWidth: geo.size.width), y: -28)
                                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                            }
                        }
                    }
                    .frame(height: 24)
                    .animation(.easeOut(duration: 0.12), value: scrubThumbnails.image != nil)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(timeString(duration)).font(.caption.monospacedDigit()).foregroundStyle(.white)
                        if let ends = endsAtClock {
                            Text(ends).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
            }

            #if !os(tvOS)
            if showSkipDBEdit, let m = curMeta { skipDBEditBar(meta: m) }
            #endif

            HStack(spacing: 0) {
                controlButton("speedometer", speed == 1.0 ? "Speed" : speedLabel(speed)) { openPanel(.speed) }
                Spacer()
                controlButton("captions.bubble", "Subtitles") { openPanel(.subtitles) }
                if !audioTracks.isEmpty {   // parity with tvOS: open the Audio panel for ANY track, not only when >1
                    Spacer()
                    controlButton("waveform", "Audio") { openPanel(.audio) }
                }
                Spacer()
                controlButton("aspectratio", "Aspect") { openPanel(.video) }
                if hasMultipleQualities {
                    Spacer()
                    controlButton("4k.tv", "Quality") { openPanel(.quality) }
                }
                if hasAlternateSources {
                    Spacer()
                    controlButton("rectangle.stack", "Sources") { openPanel(.sources) }
                }
                if episodes.count > 1 {
                    Spacer()
                    controlButton("list.bullet", "Episodes") { openPanel(.episodes) }
                }
                if hasChapters {
                    Spacer()
                    controlButton("list.bullet.below.rectangle", "Chapters") { openPanel(.chapters) }
                }
                Spacer()
                controlButton("camera.viewfinder", "Grab") { grabFrame() }
                Spacer()
                controlButton(sleepArmed ? "moon.zzz.fill" : "moon.zzz", sleepLabel) { openPanel(.sleep) }
            }
            .padding(.horizontal, 8)
        }
        .padding(.horizontal).padding(.bottom, 22)
    }

    #if !os(tvOS)
    // MARK: - Skip segment edit bar (iOS/Mac)

    @ViewBuilder private func skipDBEditBar(meta: PlaybackMeta) -> some View {
        let submittedKey = "\(meta.libraryId):\(meta.season ?? 0):\(meta.episode ?? 0):\(skipDBEditType.rawValue)"
        let alreadySubmitted = skipDBSubmittedKeys.contains(submittedKey)
        let segDuration = skipDBEditEnd - skipDBEditStart

        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Left: type picker + chapter nav
                HStack(spacing: 6) {
                    Text("Skip")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    Menu {
                        ForEach(SkipDBSubmitView.SegmentType.allCases) { t in
                            Button {
                                skipDBEditType = t
                                skipDBSubmitResult = nil
                                skipDBSubmitError = nil
                                if t == .outro {
                                    skipDBShowEndTime = false
                                    skipDBEditEnd = duration > 0 ? duration : skipDBEditEnd
                                } else {
                                    skipDBShowEndTime = true
                                }
                            } label: {
                                let k = "\(meta.libraryId):\(meta.season ?? 0):\(meta.episode ?? 0):\(t.rawValue)"
                                Label(t.label, systemImage: skipDBSubmittedKeys.contains(k) ? "checkmark" : "")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(skipDBEditType.label).font(.caption.weight(.semibold))
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white.opacity(0.15), in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    if hasChapters {
                        let boundaries = chapterFractions.map { $0 * duration }
                        let prevCh = boundaries.last(where: { $0 < currentTime - 1.0 })
                        let nextCh = boundaries.first(where: { $0 > currentTime + 0.5 })
                        HStack(spacing: 2) {
                            Button {
                                if let t = prevCh { coordinator.player?.seek(to: t) }
                            } label: {
                                Image(systemName: "backward.end.fill").font(.caption)
                                    .foregroundStyle(prevCh != nil ? .white : .white.opacity(0.3))
                                    .padding(4)
                            }
                            .buttonStyle(.plain).disabled(prevCh == nil)
                            .skipDBTooltip("Previous chapter")
                            Button {
                                if let t = nextCh { coordinator.player?.seek(to: t) }
                            } label: {
                                Image(systemName: "forward.end.fill").font(.caption)
                                    .foregroundStyle(nextCh != nil ? .white : .white.opacity(0.3))
                                    .padding(4)
                            }
                            .buttonStyle(.plain).disabled(nextCh == nil)
                            .skipDBTooltip("Next chapter")
                        }
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                Spacer()

                // Middle: start / end time controls
                HStack(spacing: 6) {
                    skipDBTimeControl(label: "Start", seconds: $skipDBEditStart, isEnd: false)

                    if skipDBEditType == .outro && !skipDBShowEndTime {
                        Button {
                            skipDBShowEndTime = true
                        } label: {
                            HStack(spacing: 4) {
                                Text("End").font(.caption2).foregroundStyle(.white.opacity(0.5))
                                Text("episode end")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.35))
                                Image(systemName: "plus.circle")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .buttonStyle(.plain)
                        .skipDBTooltip("Add a custom end time")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        Text(String(format: "%.1fs", max(0, segDuration)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(minWidth: 34, alignment: .center)

                        skipDBTimeControl(label: "End", seconds: $skipDBEditEnd, isEnd: true)

                        if skipDBEditType == .outro {
                            Button {
                                skipDBShowEndTime = false
                                skipDBEditEnd = duration > 0 ? duration : skipDBEditEnd
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .skipDBTooltip("Use episode end instead")
                        }

                        if skipDBEditType == .intro, let estimateMs = skipDBIntroEstimateMs {
                            let suggestedEnd = skipDBEditStart + Double(estimateMs) / 1000
                            if abs(suggestedEnd - skipDBEditEnd) > 3 {
                                Button {
                                    skipDBEditEnd = (suggestedEnd * 10).rounded() / 10
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "wand.and.stars").font(.caption2)
                                        Text(skipDBFormatTime(suggestedEnd)).font(.caption2.monospacedDigit())
                                    }
                                    .foregroundStyle(.yellow.opacity(0.85))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(.yellow.opacity(0.15), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .skipDBTooltip("Typical intro end for this series (+\(Int(Double(estimateMs) / 1000))s from start)")
                            }
                        }
                    }
                }

                Spacer()

                // Right: preview + submit + close
                HStack(spacing: 8) {
                    Button {
                        skipDBPreviewing = true
                        coordinator.player?.seek(to: max(0, skipDBEditStart - 2))
                        if isPaused { coordinator.player?.togglePause() }
                    } label: {
                        Image(systemName: skipDBPreviewing ? "stop.circle.fill" : "play.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(skipDBPreviewing ? Color.yellow : .white)
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                    .skipDBTooltip("Preview: plays 2s before start, jumps to end")

                    if skipDBSubmitting {
                        ProgressView().controlSize(.small).tint(.white).padding(.horizontal, 4)
                    } else if skipDBSubmitResult == true {
                        Label("Submitted!", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .onTapGesture { skipDBSubmitResult = nil }
                    } else {
                        Button {
                            Task { await doSkipDBSubmit(meta: meta) }
                        } label: {
                            Text(alreadySubmitted ? "Resubmit" : "Submit")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(alreadySubmitted ? Color.yellow : Color.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(skipDBEditStart >= skipDBEditEnd)
                    }

                    Button {
                        showSkipDBEdit = false
                        skipDBPreviewing = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                    .skipDBTooltip("Close editor")
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if let err = skipDBSubmitError {
                Text(err).font(.caption2).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 8)
    }

    @ViewBuilder private func skipDBTimeControl(label: String, seconds: Binding<Double>, isEnd: Bool) -> some View {
        HStack(spacing: 4) {
            Button {
                coordinator.player?.seek(to: seconds.wrappedValue)
            } label: {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .skipDBTooltip(isEnd ? "Jump to end" : "Jump to start")

            Button {
                let snapped = (currentTime * 10).rounded() / 10
                seconds.wrappedValue = max(0, snapped)
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .skipDBTooltip("Set to playhead")

            Text(skipDBFormatTime(seconds.wrappedValue))
                .font(.caption.monospacedDigit()).foregroundStyle(.white)
                .frame(minWidth: 44, alignment: .center)

            HStack(spacing: 2) {
                skipDBNudgeButton(seconds: seconds, delta: -0.5, label: "−½")
                skipDBNudgeButton(seconds: seconds, delta: -0.1, label: "−·")
                skipDBNudgeButton(seconds: seconds, delta: +0.1, label: "+·")
                skipDBNudgeButton(seconds: seconds, delta: +0.5, label: "+½")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private func skipDBNudgeButton(seconds: Binding<Double>, delta: Double, label: String) -> some View {
        Button {
            let cap = duration > 0 ? duration : Double.greatestFiniteMagnitude
            seconds.wrappedValue = min(cap, max(0, seconds.wrappedValue + delta))
        } label: {
            Text(label)
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .frame(width: 20, height: 20)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func skipDBFormatTime(_ sec: Double) -> String {
        let total = max(0, sec)
        let m = Int(total) / 60
        let s = total - Double(m * 60)
        return String(format: "%d:%04.1f", m, s)
    }

    fileprivate struct SkipDBHoverTooltip: ViewModifier {
        let text: String
        @State private var hovered = false
        func body(content: Content) -> some View {
            content
                .onHover { hovered = $0 }
                .overlay(alignment: .top) {
                    if hovered {
                        Text(text)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .fixedSize()
                            .offset(y: -20)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                            .zIndex(999)
                    }
                }
        }
    }

    /// Submit the edited segment. Always goes keyless to skip.vortx.tv; also to skipdb.tv when the
    /// user has a community key (best-effort, handled inside SkipDBClient). Credits map to "outro"
    /// via the editor's SegmentType raw value.
    private func doSkipDBSubmit(meta: PlaybackMeta) async {
        skipDBSubmitting = true
        skipDBSubmitError = nil
        let effectiveEnd = (!skipDBShowEndTime && duration > 0) ? duration : skipDBEditEnd
        let req = SkipDBClient.SubmitRequest(
            imdb_id: meta.libraryId,
            season: meta.season,
            episode: meta.episode,
            segment_type: skipDBEditType.rawValue,
            start_ms: Int(skipDBEditStart * 1000),
            end_ms: Int(effectiveEnd * 1000),
            duration_ms: duration > 0 ? Int(duration * 1000) : nil
        )
        do {
            try await SkipDBClient.submit(req)
            await SkipDBClient.invalidateCache(imdbId: meta.libraryId, season: meta.season,
                                               episode: meta.episode, durationSeconds: duration)
            let key = "\(meta.libraryId):\(meta.season ?? 0):\(meta.episode ?? 0):\(skipDBEditType.rawValue)"
            skipDBSubmittedKeys.insert(key)
            skipDBSubmitResult = true
            skipFetchKey = ""
            fetchSkipTimestamps()
        } catch {
            skipDBSubmitResult = false
            skipDBSubmitError = error.localizedDescription
        }
        skipDBSubmitting = false
    }
    #endif

    /// The Live position indicator shown in place of the scrubber: a pulsing red dot + "LIVE", and a
    /// running elapsed timer so the user can still see playback is advancing.
    private var liveIndicator: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text("LIVE").font(.caption.weight(.heavy)).foregroundStyle(.white).tracking(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(.black.opacity(0.4), in: Capsule())
            Spacer()
            if currentTime > 0 {
                Text(timeString(currentTime)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func controlButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.white)
        }
    }

    private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white).padding(11).background(.black.opacity(0.35), in: Circle())
                .frame(width: 44, height: 44).contentShape(Circle())   // min 44pt tap target (#30)
        }
        .accessibilityLabel(label)
    }

    // MARK: - Skip intro / outro

    private func skipPill(_ segment: SkipSegment) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    Haptics.success()
                    coordinator.player?.seek(to: segment.end)
                    currentTime = segment.end
                    updateCurrentSkip(at: segment.end)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "forward.fill")
                        Text(segment.label).fontWeight(.semibold)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .foregroundStyle(Theme.Palette.onAccent)
                    .background(Capsule().fill(Theme.Palette.accent))
                }
                .padding(.trailing, 28).padding(.bottom, 40)
            }
        }
        .transition(.opacity)
    }

    private func updateCurrentSkip(at time: Double) {
        let skip = hasStartedPlaying ? skipSegments.first { time >= $0.start && time < $0.end } : nil
        // Auto-skip: when the playhead enters a NEW skip segment and the setting is on, seek past it once.
        // Recording the start means a manual seek back into the same segment won't auto-skip it again.
        if autoSkip, let skip, !autoSkippedStarts.contains(skip.start) {
            autoSkippedStarts.insert(skip.start)
            coordinator.player?.seek(to: skip.end)
            currentTime = skip.end
            if currentSkip != nil { withAnimation { currentSkip = nil } }
            return
        }
        if skip?.start != currentSkip?.start {
            withAnimation(.easeInOut(duration: 0.2)) { currentSkip = skip }
        }
    }
    private func refreshSkipSegments() {
        let chapters = coordinator.player?.chapters() ?? []
        let chapterCandidates = SkipSegments.chapterCandidates(chapters: chapters, duration: duration)
        skipSegments = SegmentResolver.resolve(chapterCandidates + apiSkipCandidates, duration: duration)
        chapterFractions = ChapterMarks.fractions(chapters: chapters, duration: duration)
        updateCurrentSkip(at: currentTime)
    }
    private func fetchSkipTimestamps() {
        guard let m = curMeta, SkipTimestampService.supports(metaId: m.libraryId) else {
            skipFetchTask?.cancel(); apiSkipCandidates = []; skipFetchKey = ""; refreshSkipSegments(); return
        }
        let key = "\(m.libraryId):\(m.season ?? 0):\(m.episode ?? 0)"
        guard key != skipFetchKey else { return }
        if key != skipFetchKey { apiSkipCandidates = [] }
        skipFetchKey = key
        autoSkippedStarts = []   // new episode: let its intro/credits auto-skip once
        let dur = duration
        skipFetchTask?.cancel()
        skipFetchTask = Task { @MainActor in
            let found = await SkipTimestampService.candidates(imdbId: m.libraryId, season: m.season,
                                                              episode: m.episode, durationSeconds: dur)
            guard !Task.isCancelled, skipFetchKey == key else { return }
            apiSkipCandidates = found
            refreshSkipSegments()
            #if !os(tvOS)
            // Typical-intro-length hint (from the optional skipdb.tv read), surfaced as the editor's
            // "magic" suggested end. Keyed like the skipDB cache entry.
            skipDBIntroEstimateMs = await SkipTimestampStore.shared.introEstimate(for: "skipdb:\(key):\(Int(dur / 10) * 10)")
            #endif
        }
    }

    // MARK: - Add-on subtitles

    private func fetchAddonSubtitles() {
        guard let m = curMeta else { return }
        let key = "\(m.type):\(m.videoId)"
        guard key != addonSubsKey else { return }
        let addons = account.addons
        // The account's add-on collection loads async at app start; a playback that begins before it lands
        // would latch an EMPTY list for the whole session (add-on subtitles "gone"). Leave the key unlatched
        // so the panel-open retry (openPanel) fetches once the add-ons have arrived.
        guard !addons.isEmpty else { return }
        addonSubsKey = key
        addonSubs = []; addedSubURLs = []
        Task { @MainActor in
            let subs = await SubtitleAddonService.fetch(addons: addons, type: m.type, videoId: m.videoId)
            guard addonSubsKey == key else { return }   // episode changed mid-fetch
            addonSubs = subs
            if panel == .subtitles { panelRows = rows(for: .subtitles) }
        }
    }

    // MARK: - Community subtitles (pool + sync + embedded upload)

    /// The pool `content_key` for what is playing: the imdb library id, plus season/episode for an episode.
    /// Live streams and titles with no imdb id return nil, no-oping the whole community-subtitle path.
    private var communityContentKey: String? {
        guard let m = curMeta, !effectivelyLive else { return nil }
        return SubtitleReleaseFingerprint.contentKey(imdbId: m.libraryId, season: m.season, episode: m.episode)
    }

    /// The release name for the fingerprint: the playing stream's display name / release text.
    private var communityReleaseName: String? {
        if let s = currentStream { return sourceLabel(s) }
        return curTitle.isEmpty ? nil : curTitle
    }

    /// Build (or rebuild) the one release fingerprint for this playback session, keyed on the active URL so a
    /// source switch recomputes it. `force` rebuilds even when the key is unchanged (e.g. once the real
    /// duration/fps land and sharpen it). Kept consistent so fetch/upload/offset all agree.
    private func refreshSubFingerprint(force: Bool = false) {
        let key = (curURL ?? url).absoluteString
        if !force, key == subFingerprintKey, subFingerprint != nil { return }
        subFingerprintKey = key
        let fps = coordinator.player?.containerFrameRate() ?? 0
        let dur = coordinator.player?.mediaDurationSeconds() ?? duration
        subFingerprint = SubtitleReleaseFingerprint.releaseFingerprint(
            frameRate: fps > 0 ? fps : nil,
            durationSecs: dur > 0 ? dur : nil,
            releaseName: communityReleaseName)
    }

    /// P2/P3: fetch pooled community subtitles + the learned sync offset for this title, then (P3) seed the
    /// offset onto the player once. Gated + fail-soft inside the client. De-duped per content key.
    private func fetchPooledSubtitles() {
        guard let contentKey = communityContentKey else { return }
        refreshSubFingerprint()
        let fp = subFingerprint
        // Re-fetch when the content key changes OR when we now have a real fingerprint we didn't have before.
        let key = "\(contentKey)#\(fp ?? "")"
        guard key != pooledSubsKey else { return }
        pooledSubsKey = key
        Task { @MainActor in
            let result = await SubtitlePoolClient.fetchPooled(contentKey: contentKey, lang: nil, fingerprint: fp)
            guard communityContentKey == contentKey else { return }   // title changed mid-fetch
            pooledSubs = result.subs
            // P3 seed: apply the community-learned offset ONCE (seconds). Works on BOTH engines now: libmpv
            // maps it to `sub-delay`; the AVPlayer engine applies it as the offset on the external-subtitle
            // overlay it renders itself (a no-op until an external cue set is loaded, then it lands correctly).
            // Never override a delay the user already dialed in.
            if !pooledSeededOffset, subDelay == 0, let offsetMs = result.offsetMs, offsetMs != 0 {
                pooledSeededOffset = true
                let seconds = (Double(offsetMs) / 1000.0 * 10).rounded() / 10
                subDelay = seconds
                coordinator.player?.setSubDelay(seconds)
            }
            if panel == .subtitles { panelRows = rows(for: .subtitles) }
        }
    }

    /// P2: load a pooled subtitle into the player, reusing the exact external-subtitle path (download to a
    /// local file, then mpv `sub-add`). Shows the shared Loading… row state. Fail-soft.
    private func selectPooledSubtitle(_ sub: SubtitlePoolClient.PooledSubtitle) {
        guard subtitleLoadingURL == nil else { return }
        let marker = sub.url.absoluteString
        subtitleLoadingURL = marker
        if panel == .subtitles { panelRows = rows(for: .subtitles) }
        Task { @MainActor in
            guard let localURL = await SubtitlePoolClient.download(sub) else {
                subtitleLoadingURL = nil; subtitleLoadFailed = true
                if panel == .subtitles { panelRows = rows(for: .subtitles) }
                return
            }
            let title = pooledLabel(sub)
            coordinator.player?.addExternalSubtitle(url: localURL.absoluteString, title: title, lang: sub.lang) { ok in
                subtitleLoadingURL = nil
                if ok { addedPooledIDs.insert(sub.id) } else { subtitleLoadFailed = true }
                if panel == .subtitles { panelRows = rows(for: .subtitles) }
            }
        }
    }

    /// The label for a pooled subtitle row: the language name plus a subtle community marker. NO add-on
    /// wording (per the framing rule) — pooled subs are just "subtitles" with a community provenance hint.
    private func pooledLabel(_ sub: SubtitlePoolClient.PooledSubtitle) -> String { langName(sub.lang) }

    /// P3 capture: debounce a manual sync change, then submit the learned offset to the pool. Works on BOTH
    /// engines now: on libmpv it is the `sub-delay`, on AVPlayer it is the offset applied to VortX's own
    /// external-subtitle overlay (an add-on/pooled srt/vtt). Both are the same signed cue offset for this
    /// release fingerprint, so either is valid to pool. Gated + fail-soft inside the client.
    private func captureSubOffset() {
        guard let contentKey = communityContentKey else { return }
        offsetCaptureTask?.cancel()
        let delaySeconds = subDelay
        let fp = subFingerprint
        offsetCaptureTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, communityContentKey == contentKey else { return }
            let offsetMs = Int((delaySeconds * 1000).rounded())
            await SubtitlePoolClient.postOffset(contentKey: contentKey, lang: "",
                                                fingerprint: fp, offsetMs: offsetMs)
        }
    }

    /// P4: extract the file's own embedded TEXT subtitle tracks off-main and upload each to the pool so users
    /// on a different rip benefit. Best-effort, once per session, never blocks playback; ignores failures.
    private func uploadEmbeddedSubtitlesIfNeeded() {
        guard !embeddedUploadDone, let contentKey = communityContentKey else { return }
        embeddedUploadDone = true
        refreshSubFingerprint()
        let fp = subFingerprint
        // libav opens the SAME input the player plays (a local file, a direct/debrid HTTP URL). Torrents play
        // through the loopback streaming server URL, which libav can also open.
        let inputStr = (curURL ?? url).absoluteString
        Task.detached(priority: .utility) {
            let tracks = SubtitleEmbeddedExtractor.extractTextSubtitles(input: inputStr)
            for track in tracks where track.cueCount > 0 {
                await SubtitlePoolClient.upload(contentKey: contentKey, lang: track.lang, fingerprint: fp,
                                                origin: "embedded", format: track.format, text: track.srt)
            }
        }
    }

    // MARK: - Selection sheet (panels)

    private func selectionSheet(_ p: Panel) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { close() }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(p.title).font(.headline).foregroundStyle(.white)
                    Spacer()
                    Button { close() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7)).padding(7).background(.white.opacity(0.12), in: Circle())
                            .frame(width: 44, height: 44).contentShape(Circle())   // min 44pt tap target (#30)
                    }
                    .accessibilityLabel("Close panel")
                }
                .padding(.horizontal).padding(.vertical, 14)
                Divider().overlay(.white.opacity(0.15))
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(panelRows) { row in
                            panelRow(row)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            .background(Theme.Palette.surface1)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: 560)
            .padding()
            .tint(Theme.Palette.accent)
        }
        .transition(.opacity)
    }

    @ViewBuilder private func panelRow(_ row: Row) -> some View {
        if row.isHeader {
            Text(row.label.uppercased())
                .font(.caption2.weight(.semibold)).tracking(1)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.top, 16).padding(.bottom, 4)
        } else {
            Button {
                row.apply()
                refreshSoon()
                // After a one-shot pick (a track, quality, source, chapter, speed, aspect) close the
                // panel so the user lands back on the video. Otherwise recompute the open panel's rows
                // in place so checkmarks + readouts stay honest. apply() may have navigated into a
                // sub-panel via a "›" row, in which case `panel` is now that sub-panel and we refresh it.
                if row.detail != "›", let open = panel, open.dismissesAfterPick {
                    close()
                } else if let open = panel {
                    panelRows = rows(for: open)
                }
            } label: {
                if row.wraps {
                    // Label over a full-width, fully-wrapping detail (a long filename / release name).
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.label).foregroundStyle(.white)
                        if !row.detail.isEmpty {
                            Text(row.detail).font(.subheadline).foregroundStyle(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                } else {
                    HStack {
                        Text(row.label).foregroundStyle(.white).lineLimit(1)
                        Spacer()
                        if row.selected {
                            Image(systemName: "checkmark").foregroundStyle(Theme.Palette.accent)
                        } else if !row.detail.isEmpty {
                            Text(row.detail).font(.subheadline).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 13)
                    .background(row.selected ? Theme.Palette.accentSoft : Color.clear)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    /// Rows for a panel, computed once per open / refresh (NOT per clock tick), mirroring tvOS's cached
    /// `panelRows`. Sources / tracks are grouped + sorted, never a flat list.
    private var sleepArmed: Bool { sleepMinutes != nil || sleepAtEpisodeEnd }

    /// Bottom-bar label for the sleep control: "Sleep", a live "Sleep · 12m" countdown, or "Sleep · End".
    private var sleepLabel: String {
        if sleepAtEpisodeEnd { return "Sleep · End" }
        if let d = sleepDeadline {
            let mins = max(0, Int(ceil(d.timeIntervalSinceNow / 60)))
            return "Sleep · \(mins)m"
        }
        return "Sleep"
    }

    /// (Re)arm the sleep timer. `minutes` runs a timed auto-pause; `atEpisodeEnd` lets the current episode
    /// finish then stops (no auto-advance). Both nil/false = off. Cancels any prior timer.
    private func armSleep(minutes: Int?, atEpisodeEnd: Bool) {
        sleepTask?.cancel(); sleepTask = nil
        sleepAtEpisodeEnd = atEpisodeEnd
        sleepMinutes = minutes
        sleepDeadline = nil
        guard let minutes else { return }
        let seconds = Double(minutes) * 60
        sleepDeadline = Date().addingTimeInterval(seconds)
        sleepTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if !isPaused { coordinator.player?.togglePause() }
            sleepMinutes = nil; sleepDeadline = nil
        }
    }

    private func rows(for p: Panel) -> [Row] {
        switch p {
        case .video:
            return sizeModes.map { m in Row(label: m.label, detail: m.detail, selected: (coordinator.player?.videoSizeMode ?? videoSize) == m.raw) {
                videoSize = m.raw; coordinator.player?.setVideoSize(m.raw)
            } }
        case .speed:
            return speeds.map { s in Row(label: speedLabel(s), selected: abs(speed - s) < 0.01) {
                speed = s; coordinator.player?.setSpeed(s)
            } }
        case .episodes:
            // The season's episodes, current one highlighted; tapping switches in place (goToEpisode).
            return episodes.map { ep in
                Row(label: ep.label, selected: ep.id == curMeta?.videoId) { goToEpisode(ep.id) }
            }
        case .sleep:
            var rs: [Row] = [Row(label: "Off", selected: sleepMinutes == nil && !sleepAtEpisodeEnd) {
                armSleep(minutes: nil, atEpisodeEnd: false)
            }]
            for m in [15, 30, 45, 60, 90] {
                rs.append(Row(label: "\(m) minutes", selected: sleepMinutes == m && !sleepAtEpisodeEnd) {
                    armSleep(minutes: m, atEpisodeEnd: false)
                })
            }
            // Only meaningful for series with a next episode; it stops the auto-advance at the end of this one.
            if canNextEpisode || hasNext {
                rs.append(Row(label: "End of episode", selected: sleepAtEpisodeEnd) {
                    armSleep(minutes: nil, atEpisodeEnd: true)
                })
            }
            return rs
        case .subtitles:
            var rs: [Row] = [Row(label: String(localized: "Off"), selected: subtitleTracks.allSatisfy { !$0.selected }) {
                coordinator.player?.setSubtitleTrack(-1)
            }]
            rs += groupedTrackRows(subtitleTracks) { coordinator.player?.setSubtitleTrack($0) }
            // External subtitles from the account's subtitle add-ons. These work on BOTH engines now: libmpv
            // sub-adds the downloaded file; AVPlayer parses it and renders the cues over the video itself.
            let available = addonSubs.filter { !addedSubURLs.contains($0.url) }
            if !available.isEmpty {
                rs.append(Row(label: String(localized: "From add-ons"), isHeader: true))
                for sub in available.prefix(30) {
                    let loading = subtitleLoadingURL == sub.url
                    rs.append(Row(label: langName(sub.lang), detail: loading ? String(localized: "Loading…") : sub.addonName) {
                        // Non-blocking: the download + sub-add happen off the main thread with a timeout, so a
                        // slow or hanging subtitle endpoint can't freeze the player. The row shows Loading…
                        // until the track arrives (or an alert surfaces if it never does). A cached subtitle
                        // reuses its on-disk file and loads instantly (no network).
                        guard subtitleLoadingURL == nil else { return }
                        subtitleLoadingURL = sub.url
                        if panel == .subtitles { panelRows = rows(for: .subtitles) }   // reflect Loading… in place
                        coordinator.player?.addExternalSubtitle(url: sub.url, title: sub.addonName, lang: sub.lang) { ok in
                            subtitleLoadingURL = nil
                            if ok { addedSubURLs.insert(sub.url) } else { subtitleLoadFailed = true }
                            if panel == .subtitles { panelRows = rows(for: .subtitles) }
                        }
                    })
                }
            }
            // Community-pooled subtitles (P2): other users' extracted subs for this title, in the SAME list.
            // No add-on wording — labeled by language with a subtle "Community" provenance. Work on BOTH engines
            // now (AVPlayer renders the downloaded file over the video, same as the add-on rows above).
            let pooled = pooledSubs.filter { !addedPooledIDs.contains($0.id) }
            if !pooled.isEmpty {
                rs.append(Row(label: String(localized: "Community"), isHeader: true))
                for sub in pooled.prefix(30) {
                    let loading = subtitleLoadingURL == sub.url.absoluteString
                    rs.append(Row(label: pooledLabel(sub), detail: loading ? String(localized: "Loading…") : String(localized: "Community")) {
                        selectPooledSubtitle(sub)
                    })
                }
            }
            rs.append(Row(label: String(localized: "Subtitle Settings"), detail: "›") { openPanel(.subtitleSettings) })
            return rs
        case .subtitleSettings:
            let now = String(format: "%+.1fs", subDelay)
            var rs = [Row(label: String(localized: "Sync"), isHeader: true)]
            // Sync works on BOTH engines: libmpv maps it to `sub-delay`; AVPlayer applies it as the offset on the
            // external-subtitle overlay it renders itself (external srt/vtt only — native/embedded AVPlayer subs
            // have no time-shift API). Later = subtitles appear later on both.
            rs.append(Row(label: String(localized: "Earlier  −\(Self.subSyncStepLabel)"), detail: now) { adjustSubDelay(-Self.subSyncStep) })
            rs.append(Row(label: String(localized: "Later  +\(Self.subSyncStepLabel)"), detail: now) { adjustSubDelay(Self.subSyncStep) })
            rs.append(Row(label: String(localized: "Earlier  −\(Self.subSyncFineLabel)"), detail: now) { adjustSubDelay(-Self.subSyncFine) })
            rs.append(Row(label: String(localized: "Later  +\(Self.subSyncFineLabel)"), detail: now) { adjustSubDelay(Self.subSyncFine) })
            if subDelay != 0 { rs.append(Row(label: String(localized: "Reset sync")) { adjustSubDelay(-subDelay) }) }
            rs.append(Row(label: String(localized: "Size"), isHeader: true))
            for s in SubtitleStyle.sizes { rs.append(Row(label: Self.l10n(s.label), selected: subSize == s.id) { setSubtitleSize(s.id) }) }
            let scalePct = "\(Int((subSizeScale * 100).rounded()))%"
            rs.append(Row(label: String(localized: "Smaller  −"), detail: scalePct) { adjustSubScale(-1) })
            rs.append(Row(label: String(localized: "Bigger  +"), detail: scalePct) { adjustSubScale(1) })
            rs.append(Row(label: String(localized: "Colour"), isHeader: true))
            for c in SubtitleStyle.colors { rs.append(Row(label: Self.l10n(c.label), selected: subColor == c.id) { setSubtitleColor(c.id) }) }
            rs.append(Row(label: String(localized: "Background"), isHeader: true))
            for b in SubtitleStyle.backgrounds { rs.append(Row(label: Self.l10n(b.label), selected: subBackground == b.id) { setSubtitleBackground(b.id) }) }
            return rs
        case .audio:
            var rs = groupedTrackRows(audioTracks) { coordinator.player?.setAudioTrack($0) }
            rs.append(Row(label: String(localized: "Audio Settings"), detail: "›") { openPanel(.audioSettings) })
            return rs
        case .audioSettings:
            let now = String(format: "%+.1fs", audioDelay)
            var rs = [Row(label: String(localized: "Sync"), isHeader: true),
                      Row(label: String(localized: "Earlier  −0.1s"), detail: now) { adjustAudioDelay(-0.1) },
                      Row(label: String(localized: "Later  +0.1s"), detail: now) { adjustAudioDelay(0.1) }]
            if audioDelay != 0 { rs.append(Row(label: String(localized: "Reset sync")) { adjustAudioDelay(-audioDelay) }) }
            // Output mode, mirrored from Settings so it's reachable mid-playback (the "no passthrough
            // in the player" report). Applies live; mpv re-opens the audio output on the change.
            let mode = AudioOutputMode.current
            rs.append(Row(label: String(localized: "Output"), isHeader: true))
            for m in AudioOutputMode.allCases {
                rs.append(Row(label: m.label, selected: m == mode) {
                    coordinator.player?.setAudioOutputMode(m)
                })
            }
            return rs
        case .quality:
            // Best stream per resolution (4K / 1080p / 720p / …); picking one hot-swaps the source at the
            // current position via switchStream — the in-player quality picker. The full per-add-on list
            // stays under Sources.
            let opts = StreamRanking.resolutionOptions(currentSourceGroups)
            if opts.isEmpty { return [Row(label: "No alternate qualities", isHeader: true)] }
            return opts.map { opt in
                Row(label: opt.label, detail: StreamRanking.sizeText(opt.stream) ?? "",
                    selected: opt.stream.playableURL == curURL) {
                    if let url = opt.stream.playableURL { switchStream(to: opt.stream, url: url, userInitiated: true) }
                }
            }
        case .sources:
            return sourceRows()
        case .info:
            var rows: [Row] = []
            // Title block: what is playing, named at the top of the sheet (movie name, or show · SxE).
            rows.append(Row(label: "Now Playing", isHeader: true))
            rows.append(Row(label: curTitle, wraps: true))
            if let s = currentStream {
                rows.append(Row(label: "Source", isHeader: true))
                let release = String(sourceLabel(s).prefix(80))
                if !release.isEmpty { rows.append(Row(label: "Release", detail: release, wraps: true)) }
                if let file = s.behaviorHints?.filename, !file.isEmpty {
                    rows.append(Row(label: "File", detail: file, wraps: true))   // long filenames wrap, never truncate
                }
                if let size = StreamRanking.sizeText(s) { rows.append(Row(label: "Size", detail: size)) }
                if let addon = currentSourceGroups.first(where: { $0.streams.contains { $0.playableURL == curURL } })?.addon {
                    rows.append(Row(label: "Add-on", detail: addon))
                }
            }
            let stats = infoRows
            if !stats.isEmpty {
                rows.append(Row(label: "Playback", isHeader: true))
                rows.append(contentsOf: stats.map { Row(label: $0.0, detail: $0.1) })
            }
            // DV honesty: when the stream was flagged Dolby Vision but plays on libmpv, what renders is the
            // HDR10 tone-map (libmpv cannot emit true DV); say exactly that instead of implying true DV.
            if StreamRanking.isDolbyVision(recordQualityText ?? "") {
                rows.append(Row(label: "Dynamic range",
                                detail: isAVPlayerActive ? "Dolby Vision" : "HDR10 (tone-mapped from Dolby Vision)",
                                wraps: true))
            }
            return rows   // the title block is always present, so the sheet is never empty
        case .chapters:
            let chs = coordinator.player?.chapters() ?? []
            if chs.isEmpty { return [Row(label: "No chapters", isHeader: true)] }
            // Current chapter = the last one starting at or before the play head; tapping seeks to its start.
            let currentIdx = chs.lastIndex { $0.start <= currentTime + 0.5 }
            return chs.enumerated().map { i, ch in
                Row(label: ch.title.isEmpty ? "Chapter \(i + 1)" : ch.title,
                    detail: timeString(ch.start), selected: i == currentIdx) {
                    coordinator.player?.seek(to: ch.start)
                }
            }
        case .playerSettings:
            let hw = coordinator.player?.hardwareDecoding ?? true
            var rows: [Row] = [
                Row(label: "Decoder", isHeader: true),
                Row(label: "Hardware", detail: "recommended", selected: hw) {
                    coordinator.player?.setHardwareDecoding(true)
                },
                Row(label: "Software", detail: "rescues green / garbled frames", selected: !hw) {
                    coordinator.player?.setHardwareDecoding(false)
                },
                Row(label: "Playback Info", detail: "›") { openPanel(.info) },
            ]
            // Skip-segment submit (G): a discoverable overflow entry to the in-player editor, pre-filled with
            // the current position, so a user who wants to contribute an intro/outro timestamp finds it without
            // hunting the top-bar icon. Any tt####### title qualifies (keyless submit via skip.vortx.tv).
            if let m = curMeta,
               m.libraryId.range(of: #"^tt\d{7,8}$"#, options: .regularExpression) != nil {
                rows.append(Row(label: "Contribute", isHeader: true))
                rows.append(Row(label: showSkipDBEdit ? "Close skip editor" : "Submit skip segment",
                                detail: showSkipDBEdit ? "" : "at \(timeString(currentTime))") {
                    if !showSkipDBEdit {
                        let snapped = (currentTime * 2).rounded() / 2
                        skipDBEditStart = max(0, snapped)
                        skipDBEditEnd = min(snapped + 30, duration > 0 ? duration : snapped + 60)
                        skipDBEditType = .intro
                        skipDBShowEndTime = true
                        skipDBSubmitResult = nil
                        skipDBSubmitError = nil
                        skipDBPreviewing = false
                    }
                    showSkipDBEdit.toggle()
                    panel = nil   // close the settings sheet so the editor bar is visible over the video
                })
            }
            return rows
        }
    }

    /// Group tracks by language so multiple same-language tracks read clearly (an "English" header with
    /// two variants), instead of a flat list of identical rows. Mirrors tvOS `groupedTrackRows`.
    private func groupedTrackRows(_ tracks: [MPVTrack], select: @escaping (Int) -> Void) -> [Row] {
        let groups = Dictionary(grouping: tracks) { $0.lang.isEmpty ? "und" : $0.lang.lowercased() }
        var rs: [Row] = []
        for code in groups.keys.sorted(by: { langName($0) < langName($1) }) {
            guard let ts = groups[code] else { continue }   // defensive; key comes from groups.keys so always present
            if ts.count == 1 {
                let t = ts[0]
                rs.append(Row(label: langName(code), detail: t.title, selected: t.selected) { select(t.id) })
            } else {
                rs.append(Row(label: langName(code), isHeader: true))
                for (i, t) in ts.enumerated() {
                    rs.append(Row(label: t.title.isEmpty ? "Track \(i + 1)" : t.title, selected: t.selected) { select(t.id) })
                }
            }
        }
        return rs
    }

    private func langName(_ code: String) -> String {
        let c = code.lowercased()
        if c.isEmpty || c == "und" { return "Unknown" }
        return Locale.current.localizedString(forLanguageCode: c)?.capitalized ?? code.uppercased()
    }

    // MARK: - Source switching

    /// Stream groups for the CURRENTLY playing episode / movie. Prefer the per-streamId set so a CW resume
    /// or an episode switch shows THIS episode's sources (not a stale or empty resident set), falling back
    /// to the bare resident groups for movies / before the per-id set has populated. This is what makes the
    /// in-player Sources button reliably appear on a Continue-Watching resume.
    private var currentSourceGroups: [CoreStreamSourceGroup] {
        if let id = curMeta?.videoId {
            let scoped = core.streamGroups(forStreamId: id)
            if !scoped.isEmpty { return scoped }
        }
        return core.streamGroups()
    }

    /// True when more than one playable source is loaded for the current title / episode.
    private var hasAlternateSources: Bool {
        currentSourceGroups.reduce(0) { $0 + $1.streams.filter { $0.playableURL != nil }.count } > 1
    }

    /// The stream currently on screen: the loaded source whose playable URL matches what mpv is playing.
    /// Drives the Playback Info panel's source-file rows (release / filename / size). Nil for a pasted
    /// direct link with no matching loaded source.
    private var currentStream: CoreStream? {
        currentSourceGroups.flatMap(\.streams).first { $0.playableURL == curURL }
    }

    /// A magnet link for the current torrent, rebuilt from its info hash plus the trackers the add-on
    /// supplied, so it can be copied and opened elsewhere. Nil for non-torrent streams (their loopback
    /// server URL is useless to paste). The plain "Copy stream link" still covers direct and debrid URLs.
    private var magnetLink: URL? {
        guard recordIsTorrent, let hash = currentStream?.infoHash, !hash.isEmpty else { return nil }
        var s = "magnet:?xt=urn:btih:\(hash)"
        if let name = curTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), !name.isEmpty {
            s += "&dn=\(name)"
        }
        for tr in (currentStream?.sources ?? []) where tr.hasPrefix("tracker:") || tr.contains("://") {
            let raw = tr.hasPrefix("tracker:") ? String(tr.dropFirst("tracker:".count)) : tr
            if let e = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { s += "&tr=\(e)" }
        }
        return URL(string: s)
    }

    /// Every distinct playable link across all loaded sources for the current title / episode, in the
    /// engine's ranked order. Backs the "Copy all source links" menu action so the whole ranked list can
    /// be grabbed at once, de-duplicated so the same URL surfaced by two add-ons appears once.
    private var allSourceLinks: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for group in currentSourceGroups {
            for stream in group.streams {
                guard let link = stream.playableURL?.absoluteString else { continue }
                if seen.insert(link).inserted { out.append(link) }
            }
        }
        return out
    }

    /// More than one distinct resolution is available for the current title, so the Quality picker is worth
    /// showing (one tap to drop 4K -> 1080p -> 720p, or climb back up, at the current position).
    private var hasMultipleQualities: Bool {
        StreamRanking.resolutionOptions(currentSourceGroups).count > 1
    }

    /// The file carries embedded chapter markers (more than the implicit single whole-file chapter), so the
    /// Chapters navigator is worth offering. Reads mpv's chapter-list, the same data the skip-intro detector
    /// already uses.
    private var hasChapters: Bool { (coordinator.player?.chapters().count ?? 0) > 1 }

    /// Up to a capped number of loaded sources, grouped by add-on in their existing priority order, so
    /// switching is quick. The full (sometimes thousands-long) list stays on the detail page; capping
    /// keeps the panel light. Mirrors tvOS `sourceRows`.
    private func sourceRows() -> [Row] {
        let perAddon = 5
        let maxInPlayerSources = 60
        var rs: [Row] = []
        var count = 0
        let groups = currentSourceGroups
        if groups.isEmpty { return [Row(label: "Loading sources…", isHeader: true)] }
        for group in groups {
            let best = group.streams.filter { $0.playableURL != nil }
                .map { (stream: $0, rank: StreamRanking.score($0)) }
                .sorted { $0.rank > $1.rank }
                .prefix(perAddon)
                .map(\.stream)
            guard !best.isEmpty, count < maxInPlayerSources else { continue }
            rs.append(Row(label: group.addon, isHeader: true))
            for stream in best {
                guard count < maxInPlayerSources, let sURL = stream.playableURL else { continue }
                count += 1
                let info = StreamRanking.sourceDetail(stream)
                let name = String(sourceLabel(stream).prefix(40))
                rs.append(Row(label: "\(info.tags)   \(name)", detail: info.size ?? "",
                              selected: sURL == curURL) {
                    switchStream(to: stream, url: sURL, userInitiated: true)
                })
            }
        }
        return rs
    }

    private func sourceLabel(_ s: CoreStream) -> String {
        func firstLine(_ t: String?) -> String {
            (t ?? "").split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        let name = firstLine(s.name)
        if !name.isEmpty { return name }
        let desc = firstLine(s.description)
        return desc.isEmpty ? "Source" : desc
    }

    // MARK: - Track / panel actions

    private func adjustSubDelay(_ delta: Double) {
        subDelay = ((subDelay + delta) * 10).rounded() / 10
        coordinator.player?.setSubDelay(subDelay)
        captureSubOffset()   // P3: pool the user-corrected offset (debounced, gated, fail-soft)
    }
    private func adjustAudioDelay(_ delta: Double) {
        audioDelay = ((audioDelay + delta) * 10).rounded() / 10
        coordinator.player?.setAudioDelay(audioDelay)
    }
    private func setSubtitleSize(_ id: String) {
        subSize = id; coordinator.player?.applySubtitleStyle(); ProfileStore.shared.capturePlayback()
    }
    private func adjustSubScale(_ direction: Int) {
        let next = subSizeScale + Double(direction) * SubtitleStyle.sizeScaleStep
        let clamped = min(max(next, SubtitleStyle.sizeScaleRange.lowerBound), SubtitleStyle.sizeScaleRange.upperBound)
        subSizeScale = (clamped * 100).rounded() / 100
        coordinator.player?.applySubtitleStyle(); ProfileStore.shared.capturePlayback()
    }
    private func setSubtitleColor(_ id: String) {
        subColor = id; coordinator.player?.applySubtitleStyle(); ProfileStore.shared.capturePlayback()
    }
    private func setSubtitleBackground(_ id: String) {
        subBackground = id; coordinator.player?.applySubtitleStyle(); ProfileStore.shared.capturePlayback()
    }

    private func openPanel(_ p: Panel) {
        hideTask?.cancel()
        refreshTracks()
        if p == .info { infoRows = coordinator.player?.playbackStats() ?? [] }
        // Late add-on subtitle recovery: if the start-of-playback fetch raced an empty add-on collection (or
        // meta landed late), retry now. Key-latched inside, so this is a no-op once a real fetch has run;
        // the async result refreshes the open panel's rows in place.
        if p == .subtitles { fetchAddonSubtitles() }
        panelRows = rows(for: p)
        withAnimation(.easeInOut(duration: 0.15)) { panel = p }
    }
    private func close() {
        refreshTask?.cancel()   // a debounced refresh keyed to the now-closing panel must not fire (#20)
        withAnimation(.easeInOut(duration: 0.15)) { panel = nil }
        scheduleHide()
    }

    /// The single, always-safe way to LEAVE the player. Cancels every in-flight recovery/hide task on
    /// the main actor, flushes a final progress tick, then hands control back to the presenter to tear
    /// the cover down — so a stuck load can never trap the user with a Task still spinning. Routed from
    /// the always-present pre-start close button, the error-overlay Back, and the top-bar chevron.
    @MainActor private func leavePlayback() {
        hideTask?.cancel(); loadTimeout?.cancel(); autoRetryTask?.cancel()
        stallWatchdog?.cancel(); recoveryDeadline?.cancel(); skipFetchTask?.cancel()
        if !effectivelyLive, duration > 0 {
            onProgress(currentTime, duration)
            // A manual close at/near the end must clear Continue Watching too, not only a natural EOF. The
            // engine keeps any item with time_offset > 0 in the rail, so a title watched to the credits then
            // closed by hand would linger there forever (the "CW never clears" report). Rewind it OUT of CW,
            // mirroring the EOF branch; 0.9 is the engine's own CREDITS threshold.
            if let m = curMeta, currentTime / duration >= 0.9 { core.finishedWatching(libraryId: m.libraryId) }
        }
        // Wipe the configurable on-disk streaming cache for the title that just finished/closed, so a
        // completed movie or episode never leaves its buffer on disk (the owner's clear-on-finish
        // guardrail). No-op when the disk cache is off or empty. Genuine-exit path only; additive,
        // does not touch player teardown.
        DiskCacheSetting.clearCache()
        onClose()
    }

    #if os(macOS)
    private static let kVK_Space = 49
    private static let kVK_LeftArrow = 123
    private static let kVK_RightArrow = 124

    /// App-level keyDown monitor for the transport keys. SwiftUI .keyboardShortcut does not see
    /// unmodified Space/arrows on macOS (AppKit routes them to the Metal NSView's keyDown:), so we
    /// intercept here before responder dispatch. nil consumes the event (no beep); the event passes through.
    private func installMacKeyMonitor() {
        guard macKeyMonitor == nil else { return }
        macKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard panel == nil, !showExternalChooser, !showShare,
                  !externalLinkDead, !subtitleLoadFailed else { return event }
            let mods: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            if !event.modifierFlags.intersection(mods).isEmpty { return event }
            if event.window?.firstResponder is NSText { return event }
            switch Int(event.keyCode) {
            case Self.kVK_Space:
                coordinator.player?.togglePause(); scheduleHide(); return nil
            case Self.kVK_LeftArrow:
                seekBy(-seekStepSeconds); return nil
            case Self.kVK_RightArrow:
                seekBy(seekStepSeconds); return nil
            default:
                return event
            }
        }
    }

    private func removeMacKeyMonitor() {
        if let m = macKeyMonitor { NSEvent.removeMonitor(m); macKeyMonitor = nil }
    }
    #endif

    private func refreshTracks() {
        audioTracks = coordinator.player?.tracks(ofType: "audio") ?? []
        subtitleTracks = coordinator.player?.tracks(ofType: "sub") ?? []
    }
    private func refreshSoon() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            refreshTracks()
            if let p = panel { panelRows = rows(for: p) }
            if panel == .info { infoRows = coordinator.player?.playbackStats() ?? [] }
        }
    }

    /// Auto-pick the audio + subtitle track from the user's language preferences, once tracks are known.
    private func autoSelectTracks() {
        let pick = TrackSelector.select(audio: audioTracks, subtitles: subtitleTracks, preferences: TrackPreferences.current)
        if let a = pick.audio { coordinator.player?.setAudioTrack(a) }
        if let s = pick.subtitle { coordinator.player?.setSubtitleTrack(s) }   // -1 = off
        refreshSoon()
    }

    // MARK: - Control visibility

    /// A tap toggles the controls. While the controls are visible (or a panel is open) the auto-hide
    /// timer keeps them up; showing them re-arms the timer. Mirrors tvOS's "show on input, hide on a
    /// fresh deadline" approach, fixing the unreliable show/hide.
    private func toggleControls() {
        if panel != nil { return }   // a tap behind an open panel shouldn't flip the bar; the scrim handles dismissal
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() } else { hideTask?.cancel() }
    }
    private func scheduleHide() {
        hideTask?.cancel()
        controlsVisible = true
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            // Never auto-hide before the first frame arrives: a stuck pre-start load must KEEP its
            // controls (and their close button) on screen so the player is never a trap. Also hold
            // while scrubbing, a panel is open, or paused.
            guard !Task.isCancelled, hasStartedPlaying, !scrubbing, panel == nil, !isPaused, !skipEditActive else { return }
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    private func speedLabel(_ s: Double) -> String { s == s.rounded() ? "\(Int(s))×" : String(format: "%g×", s) }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t), h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

#if !os(tvOS)
private extension View {
    func skipDBTooltip(_ text: String) -> some View {
        modifier(PlayerScreen.SkipDBHoverTooltip(text: text))
    }
}
#endif

#if os(iOS)
/// AirPlay route picker styled to match the player's circular icon buttons. iOS only (macOS handles AirPlay
/// at the system level; there is no AVRoutePickerView there). Lets the user start AirPlay from the player
/// overlay instead of only Control Center; the AVPlayer/HLS path mirrors video, libmpv routes audio.
struct AirPlayRoutePickerButton: View {
    var body: some View {
        AirPlayPickerRepresentable()
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.35), in: Circle())
            .accessibilityLabel("AirPlay")
    }
}

private struct AirPlayPickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.prioritizesVideoDevices = true
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
