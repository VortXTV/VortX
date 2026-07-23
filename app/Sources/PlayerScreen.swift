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
    var debridRef: DebridPlaybackRef? = nil
    var engineAddonBase: String? = nil
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
    var initialSourceStream: CoreStream? = nil               // exact raw torrent selector for CW before groups are resident
    /// Exact engine episode identity confirmed by the launch presenter. nil keeps series engine writes closed.
    var initialEnginePlayerVideoId: String? = nil
    var isTrailer: Bool = false                             // a trailer preview: always plays in-app, never auto-routes external
    /// True when the LAUNCH source was an explicit user choice (a tapped source-list row / quality pick),
    /// false for an auto-pick (Watch Now / a Continue-Watching resume). An explicit pick is HONORED on a
    /// start-timeout: the player retries the SAME source with a longer first-buffer grace rather than
    /// silently hopping to a different, often lower-quality, source (the "picked 4K, got 480p" report).
    /// Only the auto path may auto-hop. Threaded from the presenter's PlayerLaunch; defaults to auto.
    var startedFromExplicitPick: Bool = false
    /// True when this launch is a Continue-Watching resume: play the exact stored source first (retry-in-place
    /// on a slow start like an explicit pick), but hop to a fresh source on a HARD load failure (a stale debrid
    /// link) instead of dead-ending like a manual pick. Threaded from iOSPlayerLaunch.wasResume.
    var startedFromResume: Bool = false
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
    // switching (alternate loaded streams) and add-on subtitles - exactly as tvOS does. They are
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
        case speed, subtitles, subtitleSettings, secondarySubtitles, audio, audioSettings, video, sources, episodes, info, playerSettings, sleep, quality, chapters, engine
        var id: Int {
            switch self {
            case .speed: 0; case .subtitles: 1; case .subtitleSettings: 2; case .audio: 3
            case .audioSettings: 4; case .video: 5; case .sources: 6; case .info: 7
            case .playerSettings: 8; case .sleep: 9; case .episodes: 10; case .quality: 11
            case .chapters: 12; case .engine: 13; case .secondarySubtitles: 14
            }
        }
        var title: String {
            switch self {
            case .speed: "Playback Speed"; case .subtitles: "Subtitles"
            case .subtitleSettings: "Subtitle Settings"; case .secondarySubtitles: "Second Subtitle"
            case .audio: "Audio"
            case .audioSettings: "Audio Settings"; case .video: "Aspect Ratio"
            case .sources: "Sources"; case .info: "Playback Info"; case .playerSettings: "Player Settings"
            case .sleep: "Sleep Timer"; case .episodes: "Episodes"; case .quality: "Quality"
            case .chapters: "Chapters"; case .engine: "Player Engine"
            }
        }
        /// Panels where picking a row is an unambiguous one-shot choice (a track, quality, source, or
        /// chapter): the panel closes after the tap so the user lands back on the video. Speed and aspect
        /// stay open (people flip between values to compare), as do the adjustment panels (sync / size /
        /// colour steppers, output mode, player settings, sleep) and the browse panels (info, episodes).
        var dismissesAfterPick: Bool {
            switch self {
            case .subtitles, .secondarySubtitles, .audio, .quality, .sources, .chapters, .engine: true
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
    /// Player Lock: while true the chrome is hidden and non-interactive and a tap on the video only
    /// reveals the small unlock chip, so a pocketed phone / a handed-over device can't seek or pause by
    /// accident. Engaged from the top bar's lock button; per-playback state (never persisted).
    @State private var isLocked = false
    /// The transient unlock affordance a locked player shows on tap; auto-hides after a few seconds.
    @State private var unlockChipVisible = false
    @State private var unlockChipHideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubTarget: Double = 0   // committed scrub position while dragging; avoids timePos fighting the thumb (#32)
    @State private var refreshTask: Task<Void, Never>?   // debounced panel/track refresh; cancellable so it can't outlive the player (#20)
    #if os(macOS)
    /// Display-sleep assertion held while the player is open (macOS parity with the iOS idle-timer
    /// disable): keeps the Mac from dimming / sleeping mid-movie. Ended on disappear.
    @State private var macSleepActivity: NSObjectProtocol?
    /// macOS player keyDown monitor for Space/Left/Right; see installMacKeyMonitor.
    @State private var macKeyMonitor: Any?
    /// Tracks whether the player's window is in native macOS fullscreen, so the toolbar glyph flips
    /// between enter/exit. Kept in sync by NSWindow's will-enter / will-exit fullscreen notifications.
    @State private var macIsFullScreen = false
    /// Observers for the fullscreen-state notifications, torn down on disappear.
    @State private var macFullScreenObservers: [NSObjectProtocol] = []
    /// Whether the player's window was ALREADY in native fullscreen when the player opened. If so the app
    /// was fullscreen for browsing (the user's own choice) and we leave it that way on teardown; if not, a
    /// fullscreen the PLAYER itself entered is dropped on close so the viewer lands back in windowed browse.
    /// See `exitPlayerFullScreenIfNeeded` (item 6).
    @State private var macWasFullScreenAtOpen = false
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
    // "Still watching?" idle guard: after a long unattended stretch (no transport/seek/tap for
    // `idleWatchTimeout`, or `idleAutoAdvanceLimit` back-to-back auto-advances with zero input between them)
    // pause playback and ask, so a binge does not run all night. ANY interaction re-arms it, so an
    // actively-attended session never trips. Mirrors TVPlayerView.
    @State private var stillWatchingPrompt = false          // the modal is up (playback paused, awaiting Continue / Stop)
    @State private var idleDeadline = Date.distantFuture    // wall-clock idle deadline; pushed forward on every interaction
    @State private var idleWatchTask: Task<Void, Never>?    // single poll loop; started on open, cancelled on teardown
    @State private var consecutiveAutoAdvances = 0          // back-to-back auto-advances with no interaction between them
    @State private var pendingStillWatchingEpisodeId: String?  // next episode to roll to when Continue is chosen at a binge boundary
    private static let idleWatchTimeout: TimeInterval = 4 * 60 * 60   // 4h of no interaction -> "Still watching?"
    private static let idleAutoAdvanceLimit = 4                       // 4 back-to-back auto-advances, zero input -> same
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
    // One-shot latch for the ADD-ON subtitle auto-select fallback (fires when the container has no track in
    // the preferred language chain but an add-on does). Reset with appliedAutoTracks so a source hop /
    // episode switch re-evaluates cleanly; latched after one attempt so a failure never loops.
    @State private var autoAddonSubTried = false
    // Set on ANY manual subtitle choice this load (panel Off / embedded / add-on / community row). Hard-stops
    // every later ASYNC auto-select re-application, so a list that lands after a manual pick never overrides it.
    // Reset wherever autoAddonSubTried resets. Mirror of TVPlayerView.
    @State private var userPickedSubtitle = false
    // One-shot latch: the tmdb->tt resolve for the add-on/pooled query id has been kicked off this load. Reset
    // wherever autoAddonSubTried resets, so a reload can retry a failed resolve exactly once. Mirror of TVPlayerView.
    @State private var addonSubsResolveTried = false
    // An explicit in-session subtitle pick captured before an engine switch (#76, mandated check 8), re-applied
    // on the new engine's first trackList instead of the preference-derived auto pick. Consumed in
    // autoSelectTracks; only read while userPickedSubtitle is true. Mirror of TVPlayerView.
    @State private var pendingSubtitleReapply: SubtitleChoice?
    // A DV-remux switch that starts at 0 (forward-only, the resume seek is dropped) keeps the REAL resume
    // point here, so the periodic / exit progress writes refuse to REGRESS the account resume below it. Clears
    // once the playhead passes it. iOS port of TVPlayerView.suppressedResumeFloor.
    @State private var suppressedResumeFloor: Double?
    @State private var warmedEpisodeID: String?      // next-episode source already warmed this episode (F6 preload)
    @State private var showShare = false             // system share sheet
    @State private var grabbedFrame: GrabbedFrame?   // a captured still, pending the share sheet (#24 frame grab)
    // Current-episode tracking for in-place episode switching: seeded from the launch values, updated on
    // every Next/Prev/list switch so progress, the watched marker, Continue-Watching, skip timestamps,
    // and add-on subtitles all key off the episode ACTUALLY playing (not the one first opened).
    @State private var curMetaState: PlaybackMeta? = nil
    @State private var curTitleState: String? = nil
    @State private var enginePlayerVideoId: String? = nil
    @State private var engineAttributionInitialized = false
    @State private var curDebridRef: DebridPlaybackRef? = nil
    @State private var switchingEpisode = false       // a Next/Prev/list switch is resolving its stream
    @State private var resumeRetryGeneration = 0
    @State private var episodeSwitchGeneration = 0
    @State private var episodeResolveGeneration: Int?
    @State private var playbackExited = false
    private var curMeta: PlaybackMeta? { curMetaState ?? recordMeta }
    private var curTitle: String { curTitleState ?? title }
    private var isEpisodePlaybackContext: Bool {
        let target = pendingAdvance?.meta ?? curMeta
        if let target, EpisodePlaybackIdentity.isEpisodicContext(
            type: target.type, season: target.season, episode: target.episode,
            videoID: target.videoId
        ) { return true }
        return loadEpisode != nil || !episodes.isEmpty
    }
    // UNIFIED CURRENT-EPISODE IDENTITY (binge-desync fix, publish-at-first-frame; mirror of
    // TVPlayerView.pendingAdvance). goToEpisode used to publish curMetaState/curTitleState the moment the
    // episode RESOLVED, before its file produced a frame, so an advance interrupted across a background
    // boundary could leave the label/selector/store naming an episode the player never actually rendered.
    // An advance now parks its identity here, and the ONE commit point is the incoming file's first frame
    // (timePos handler): display identity, the recorded binge group, and the LastStreamStore record all
    // move together. `issued` is true from creation on this platform (goToEpisode resolves FIRST, then
    // hands the load to switchStream in the same MainActor turn, so there is no pre-issue tick window);
    // `url` is what a foreground reconcile re-issues when the load died suspended. The "Loading episode…"
    // chrome already runs off `reconnecting`/`reconnectMsg`, which goToEpisode drives.
    private struct PendingEpisodeAdvance {
        let meta: PlaybackMeta
        let title: String
        let binge: String?
        let generation: Int
        var debridRef: DebridPlaybackRef?
        var url: URL? = nil
        var issued = false
        var loadToken: PlayerLoadToken? = nil
        var terminal = false
        var deferredDuration: Double? = nil
        var deferredTrackList = false
        var deferredSeekable: Bool? = nil
    }
    private struct EpisodeSourceSnapshot {
        let url: URL?
        let headers: [String: String]?
        let stream: CoreStream?
        let debridRef: DebridPlaybackRef?
        let hint: String?
        let binge: String?
        let isTorrent: Bool
        let engineVideoID: String?
        let engineAddonBase: String?
    }
    private struct SupersededEpisodeAdvance {
        var pending: PendingEpisodeAdvance
        let source: EpisodeSourceSnapshot
    }
    @State private var pendingAdvance: PendingEpisodeAdvance?
    @State private var supersededAdvance: SupersededEpisodeAdvance?
    @State private var committedLoadToken: PlayerLoadToken?
    @State private var uncommittedIdentityBlocked = false
    @State private var persistenceBlockedForExit = false
    private var hasUncommittedIssuedMedia: Bool {
        uncommittedIdentityBlocked
            || pendingAdvance?.issued == true
            || supersededAdvance?.pending.issued == true
    }
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
    @State private var subtitlePoolRequests = SubtitlePoolClient.RequestOwnership()
    @State private var addedPooledIDs: Set<Int> = []      // pooled subs already loaded into the player
    @State private var pooledSeededOffset = false         // the community offset was applied once this session
    @State private var embeddedUploadDone = false         // the embedded-track upload ran once this session
    @State private var langContributeDone = false         // the container language-index contribute ran once this session
    @State private var offsetCaptureTask: Task<Void, Never>?   // debounced postOffset on a manual sync change
    /// One consistent release fingerprint per playback session, so fetch/upload/offset all agree. Recomputed
    /// on a source switch or once the real duration/fps land (nil until first computed).
    @State private var subFingerprint: String?
    @State private var subFingerprintKey = ""             // curURL the fingerprint was built for

    // Load failure / recovery state (mirrors TVPlayerView).
    @State private var loadFailed = false            // playback couldn't start (dead/uncached link)
    // [src-probe] Diagnostic-only: wall-clock anchor for the CURRENT load attempt, stamped at every
    // (re)load / hop / switch entry, so every probe line can print elapsedSinceLoadStart for a readable
    // startup timeline. Pure instrumentation; nothing reads this to change behaviour.
    @State private var srcProbeLoadStart = Date()
    #if os(iOS) || os(macOS)
    @State private var avEngineFailed = false        // AVPlayer couldn't open this stream; fell back to libmpv
    /// The engine routing decision, LATCHED once at playback start (onAppear). Routing inputs are not all
    /// constant (`PlayerEngineRouter.dvRemuxEnabled(dvDisplayCapable:)` reads a RemoteConfig snapshot that can
    /// refresh mid-session), and `useAVPlayerEngine` is re-evaluated on every body render, so an unlatched flip
    /// yanked a playing stream into the other engine minutes in (the mid-playback "auto-switch to DV" report).
    /// Engine choice happens ONLY at start; the sole later transition is the failure demotion (avEngineFailed).
    @State private var engineLatch: Bool?
    /// Source-timeline origin handed to a newly mounted AVPlayer surface. nil uses the immutable launch input;
    /// a manual engine swap replaces it with the live position before SwiftUI constructs the new host view.
    @State private var avSurfaceResumeOrigin: Double?
    /// Quality signature of what is playing RIGHT NOW (iOS port of TVPlayerView.curHint). Seeded from the
    /// launch signature (`recordQualityText`) and re-set in `switchStream` to the switched-to stream, so the
    /// DV gate (`activeAVPlayerWouldRemux`) and the DV display-mode plumbing (`contentIsDolbyVision`) judge the
    /// ACTIVE source after an in-player source switch across DV-ness, not the immutable launch source.
    @State private var curHint: String?
    /// Set when the AVPlayer engine failed and we demoted to libmpv. Error events from the dismounting
    /// AVPlayer engine can still land shortly after the swap; anything inside this grace window is stale and
    /// must not burn the fresh mpv load's retry budget (or paint the error overlay over a recovering play).
    @State private var avDemotedAt: Date?
    /// Transient engine notice ("Dolby Vision fallback…"), shown as a small capsule and auto-dismissed.
    @State private var engineNotice: String?
    @State private var engineNoticeTask: Task<Void, Never>?
    /// AVPlayer-only START watchdog (parity with tvOS). AVPlayer can mount its surface and present chrome yet
    /// never produce a playable frame (no item .failed, no timePos tick) for an undecodable/large DV link, so
    /// the shared 30s loadTimeout leaves the user staring at dead chrome. When AVFoundation is the active engine
    /// and no frame has arrived after `avStartWatchdogSeconds`, demote to libmpv IN PLACE on the SAME URL. A
    /// stream that IS producing frames cancels this in the timePos handler, so a genuine play is never demoted.
    /// NOT armed for libmpv (torrents legitimately warm up far longer under loadTimeout / torrent warm-up).
    @State private var avStartWatchdog: Task<Void, Never>?
    // 20s, not 5s: this watchdog only ever arms for the DV remux (non-HLS AVPlayer), and the remux must mux its
    // FIRST fragment (~1s of 4K) from the debrid source before AVPlayer can present a frame, so its first-frame
    // time over debrid routinely reaches ~10-13s (libmpv on the same link took ~13s here). A 5s deadline demoted
    // a perfectly-working DV remux to mpv HDR10 before it ever rendered. 20s covers the remux startup while still
    // catching a genuinely-dead mount (the 30s loadTimeout + AVPlayer's own .failed path remain the backstops).
    // Since the progress-aware rework this fixed wall only governs NON-remux AVPlayer mounts; a mounted remux
    // uses the stall/ceiling pair below (mirrors tvOS TVPlayerView).
    private let avStartWatchdogSeconds: Double = 20
    // Progress-aware remux demote thresholds (the 0.3.13 field fix, tvOS twin in TVPlayerView): demote only on
    // a TRUE stall (no new muxed bytes / segments / classify-init flips for the whole window) or at a generous
    // hard ceiling, never merely because a heavy still-downloading 4K DV source needed longer than a fixed wall
    // to first-frame. A genuinely dead source still fails fast via the remux's own open/read timeouts -> the
    // HLS 404 -> AVPlayer .failed demote, independent of this watchdog.
    private let avRemuxStallDemoteSeconds: Double = 15
    private let avRemuxStartHardCeilingSeconds: Double = 120
    /// When the AVPlayer start watchdog was armed for the current mount; drives the [dv] time-to-first-frame
    /// line when the timePos handler disarms it. Cleared (one-shot) by that handler.
    @State private var avWatchdogArmedAt: Date?
    #endif
    @State private var loadErrorMsg = ""
    /// CW-resume only: set once we've waited for a freshly-loaded source after the stored link failed, so the
    /// wait-and-hop runs at most once per playback (no unbounded loop). Reset on each new media load.
    @State private var awaitedFreshSources = false
    @State private var hasStartedPlaying = false
    /// A per-playback token for external-sync sessions: fresh per view instance (so a rewatch of the same
    /// title scrobbles again) and re-minted on a genuine episode advance. A same-title recovery reload
    /// (source hop / demote / retry) keeps it unchanged, so the scrobble coordinator's once-latches survive
    /// and a completion recorded before the reload is never re-sent.
    @State private var playbackSessionID = UUID().uuidString
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
    /// True when the current source is a direct play from one of the user's connected media servers (its host
    /// matches a stored server url). Used to show the honest "can't direct-play, no transcode in this version"
    /// error instead of the generic source-failure copy (Phase 1 has no transcode negotiation).
    private var curIsMediaServer: Bool {
        guard let host = curURL?.host?.lowercased() else { return false }
        return MediaServerStore.shared.servers.contains { rec in
            rec.urls.contains { (URL(string: $0)?.host?.lowercased()) == host }
        }
    }
    @State private var curHeaders: [String: String]?
    @State private var curIsTorrent = false
    @State private var curSourceStream: CoreStream?
    @State private var torrentWarmupsUsed = 0          // bounded torrent peer-discovery warm-up rounds
    @State private var torrentStatus: String?          // "Connecting to peers · N connected" shown during warm-up
    // Auto-failover: when a source spends its retry / stall budget, hop to the best-ranked UNTRIED
    // source instead of dropping the viewer at the error overlay (parity with tvOS).
    @State private var exhaustedURLs: Set<URL> = []
    @State private var sourceHops = 0
    private let maxSourceHops = 4
    // Whether the CURRENTLY loading source was explicitly chosen by the user (seeded from
    // `startedFromExplicitPick`, updated on every in-player source/quality pick and auto-hop). An
    // explicit pick is retried in place on a start-timeout instead of hopping to a different source.
    @State private var currentPickWasExplicit = false
    /// True while the INITIAL source is a Continue-Watching resume (see startedFromResume). Cleared once the
    /// player switches to any other source, so only the first stored-link attempt gets resume-hop treatment.
    @State private var currentPlaybackIsResume = false
    /// True once a resume has already re-selected its SAME source (re-resolved a fresh link for the same file)
    /// after a stale-link failure, so a second failure hops to a DIFFERENT source instead of looping on it.
    @State private var resumeSourceReresolved = false
    // First-buffer grace for a big 4K remux on slow debrid: a start-timeout that fires while bytes are
    // still arriving (the demuxer-cache edge advanced since the last watchdog arm) extends the wait
    // rather than declaring the source dead. Bounded by the number of extensions and the overall
    // recovery deadline, so a genuinely stalled source still errors.
    @State private var lastBufferedAtWatchdog = -1.0
    @State private var bufferGraceUsed = 0
    private let maxBufferGraceExtensions = 3      // up to ~3×20s extra on top of the 30s watchdog, deadline-capped
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
        Group {
            // ONE full-chrome player for every stream on every platform (Gap 1). Adaptive-HLS (.m3u8) on iOS
            // used to mount the bare `HLSPlayerView` (no track selection / episode nav / skip pill / trickplay /
            // subtitle add-ons / speed / chapters / engine switch); it now flows through `mpvBody` -> the same
            // `playerSurface` the rest of the app uses, where `PlayerEngineRouter` routes HLS to the full-chrome
            // `AVPlayerEngineView` (native ABR + AirPlay + PiP) and a dead HLS link demotes to libmpv in place via
            // the engine's endFileError path (see handleProperty), matching the old bare-path onLoadFailed. macOS
            // keeps HLS on libmpv (the router's HLS rule is iOS/tvOS only; its node server transcodes HLS) and
            // tvOS routes HLS in TVPlayerView, both unchanged.
            mpvBody
        }
        // Ambient-hero gate: the browse UI (and any mounted in-hero trailer clip) stays alive UNDER this
        // fullscreen player, so signal "a player is up" for as long as this screen is mounted - the hero
        // views unmount their looping libmpv clip on it, instead of decoding a 1080p trailer beneath the
        // whole movie (micro stutter + audio crackle on every stream).
        .onAppear { FullscreenPlaybackGate.shared.playerDidAppear(); LoopbackPlaybackAssertion.begin(for: url) }
        .onDisappear { FullscreenPlaybackGate.shared.playerDidDisappear(); LoopbackPlaybackAssertion.end() }
    }

    #if os(iOS) || os(macOS)
    /// User-invoked mid-title engine override (P3, #76). nil = automatic (the latch/route decides); true = the
    /// viewer forced AVPlayer; false = the viewer forced libmpv. Supersedes the latch so `playerSurface`
    /// re-renders the other engine on the SAME view; `avEngineFailed` still wins (a failed manual AVPlayer pick
    /// falls back to libmpv, no loop).
    @State private var manualEngineAVPlayer: Bool?

    /// Whether to mount the AVFoundation engine instead of libmpv for this stream. In `auto`: remote HLS routes
    /// here for native ABR + AirPlay + PiP (Gap 1: through the full chrome now, not the old bare HLSPlayerView),
    /// and a **Dolby Vision** stream in an AVPlayer-playable container (MP4/MOV/M4V) auto-routes here for true DV
    /// passthrough (libmpv only tone-maps DV to SDR). The
    /// override (Always libmpv / Prefer AVPlayer) still wins. On an AVPlayer load failure we fall back to libmpv
    /// for this stream (`avEngineFailed`). The DV flag comes from the launching stream's quality text.
    private var useAVPlayerEngine: Bool {
        if avEngineFailed { return false }   // an AVPlayer load failure fell back to libmpv for this stream
        if let forced = manualEngineAVPlayer { return forced }   // P3: the viewer's mid-title engine pick wins over the latch
        return engineLatch ?? routedToAVPlayer
    }

    /// Whether AVPlayer can actually PLAY the ACTIVE stream, gating the "AVPlayer" row in the engine picker.
    /// The old form forced `.avfoundation` through the router, which returns AVPlayer for ANY non-torrent URL
    /// (the override bypasses every container rule), so it offered AVPlayer for a plain non-DV MKV/AVI/TS,
    /// then a pick mounted the DV remux on non-DV content (shouldDVRemux checks container only), classify
    /// rejected, and demote-bounced the position to 0. Gate on real playability instead: an AVPlayer-native
    /// container (mp4/mov/m4v/HLS), a Dolby Vision title the DV remux lane can carry, OR (#147) a non-DV
    /// Matroska title the PLAIN remux lane can carry (which is what restores the AVPlayer pick - and with it
    /// Picture in Picture - for ordinary MKVs, this time on a lane built for them). And gate on the ACTIVE
    /// source (curURL), not the immutable LAUNCH url, so an in-player switch to a torrent no longer offers a
    /// dead AVPlayer row that would feed a loopback torrent URL into AVPlayer.
    private var canUseAVPlayerEngine: Bool {
        if audioSidecarURL != nil { return false }
        let activeURL = curURL ?? url
        let loopback = activeURL.host == "127.0.0.1" || activeURL.host == "localhost"
        if curIsTorrent || loopback { return false }
        return PlayerEngineRouter.isAVPlayerContainer(activeURL) || activeAVPlayerWouldRemux
            || activeAVPlayerWouldPlainRemux
    }

    /// True when routing the ACTIVE source to AVPlayer would mount the forward-only DV remux (a Dolby Vision
    /// title in a container AVFoundation cannot demux, with the remux lane enabled for this display). Drives
    /// both the engine-picker gate and the resume-floor suppression on a switch INTO such a mount. Uses the
    /// router's non-isolated Auto-path predicates (dvRemuxEnabled + isDVRemuxCandidate), i.e. the exact
    /// condition AVPlayerEngine.loadFile's shouldDVRemux evaluates, without the @MainActor wrapper.
    private var activeAVPlayerWouldRemux: Bool {
        let activeURL = curURL ?? url
        let isDV = StreamRanking.isDolbyVision(curHint ?? recordQualityText ?? "")
        return isDV
            && PlayerEngineRouter.dvRemuxEnabled(dvDisplayCapable: DVDisplaySupport.isCapable)
            && PlayerEngineRouter.isDVRemuxCandidate(activeURL)
    }

    /// #147: true when routing the ACTIVE source to AVPlayer would mount the forward-only PLAIN (non-DV)
    /// remux: a non-DV Matroska source with the plain lane enabled and HLS delivery live. Re-opens the
    /// engine-picker AVPlayer row for plain MKVs (so a viewer can pick AVPlayer for Picture in Picture) and
    /// feeds the same resume-floor suppression a DV remux target gets (the plain mount is equally
    /// forward-only). Mirrors AVPlayerEngine.loadFile's `wantsPlainRemux` (minus the reactive force flag).
    private var activeAVPlayerWouldPlainRemux: Bool {
        let activeURL = curURL ?? url
        let isDV = StreamRanking.isDolbyVision(curHint ?? recordQualityText ?? "")
        return !isDV
            && VortXRemuxHLSServer.deliveryEnabled
            && PlayerEngineRouter.shouldPlainRemux(url: activeURL)
    }

    /// The raw routing computation. Consulted once to seed `engineLatch` (and for the first renders before
    /// onAppear runs); never re-consulted mid-playback, so a RemoteConfig refresh can't flip the engine live.
    private var routedToAVPlayer: Bool {
        // A yt-direct adaptive pair NEEDS libmpv (the audio sidecar rides mpv --audio-files; AVPlayer
        // would play the video-only stream silent), so it bypasses AVPlayer routing entirely.
        if audioSidecarURL != nil { return false }
        // V2 (trailerClientResolverV2): the resolver's HLS-master fallback hands a googlevideo manifest as the
        // trailer URL with NO sidecar, and router rule (4) below would divert any remote .m3u8 to AVPlayer,
        // which replays it under its own UA (googlevideo 403s a UA that does not match the minting client) and
        // bypasses the mpv trailer pipeline. Trailers always play on libmpv in practice already (today's mp4
        // trailer URLs take router rule (5) there), so under the flag pin EVERY trailer to libmpv. Inert when
        // the flag is off: the resolver then never returns a manifest and the pin is skipped.
        if isTrailer, YouTubeDirectResolver.isV2Enabled { return false }
        // Hard invariant: a trailer manifest must NEVER reach the router's AVPlayer HLS diversion (it would
        // drop the mpv path and 403 on the UA binding). Trips in debug if a .m3u8 trailer ever falls through
        // to the router below; compiled out of release builds.
        assert(!(isTrailer && PlayerEngineRouter.isHLS(url)),
               "trailer manifest must route to libmpv, never AVPlayer")
        let loopback = url.host == "127.0.0.1" || url.host == "localhost"
        let isDV = StreamRanking.isDolbyVision(recordQualityText ?? "")
        // Pass this display's DV capability so the DV mandate holds on macOS too (DV -> the remux->AVPlayer
        // lane on any DV-capable display). Evaluated once at play start (this feeds engineLatch in onAppear).
        // The live delivery flag gates rule (4b)'s Matroska half: with the HLS delivery lane rolled back a
        // plain MKV stays on libmpv instead of attempting an AVPlayer mount the engine could not remux.
        let chosen = PlayerEngineRouter.engine(for: url, isTorrent: loopback, isDolbyVision: isDV,
                                               dvDisplayCapable: DVDisplaySupport.isCapable,
                                               plainRemuxDelivery: VortXRemuxHLSServer.deliveryEnabled)
        // [dv] routing probe: the first line of the DV trail (route -> mount -> classify -> fallback -> demote).
        // Gated (no-op unless probing is on), so it is free in shipping builds. If engine is AVPlayer on a DV
        // source it is the true-DV lane (VideoToolbox); if it is mpv here the DV source tone-maps to HDR10.
        let candidacy = PlayerEngineRouter.dvRemuxCandidacy(url)
        VXProbe.log("dv", "route file=\(VXProbeRedaction.identityToken(url.lastPathComponent)) ext=\(url.pathExtension) isDV=\(isDV) dvDisplayCapable=\(DVDisplaySupport.isCapable) candidate=\(candidacy.candidate) [\(candidacy.reason)] container=\(PlayerEngineRouter.isAVPlayerContainer(url)) -> engine=\(chosen.rawValue)")
        return chosen == .avfoundation
    }
    #endif

    /// Whether the active player engine is AVFoundation. Mirrors tvOS's runtime check (the mounted controller's
    /// type), so the chrome can hide the rows AVPlayer has no equivalent for: audio sync (setAudioDelay), audio
    /// output mode, and the hardware-decoding toggle. External add-on subtitles work on both engines; subtitle
    /// sync is exposed only when the selected path reports `subtitleDelayAvailable`.
    ///
    /// The MOUNTED controller's type is the truth whenever a controller exists, in BOTH directions: the old
    /// form only checked "is AVPlayerEngineController" and otherwise fell back to the routing intent, so with
    /// libmpv actually mounted but the route/latch still saying AVPlayer, the engine label + Settings rows
    /// claimed AVPlayer while HDR10 tone-mapped pixels were rendering (the "shows AVPlayer but plays libmpv"
    /// mislabel). Falls back to the routing decision only before any controller mounts, so the gate is still
    /// correct on the first render.
    private var isAVPlayerActive: Bool {
        if let mounted = coordinator.player { return mounted is AVPlayerEngineController }
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
                // Pass the launching stream's Dolby Vision flag (same plumbing as mpvSurface and the tvOS
                // surface). Without it the first iOS/macOS native-DV MP4/MOV mount never armed the DV
                // watchdogs (audio-over-black, hev1/dvhe repair, DV diagnostics) that key off
                // contentIsDolbyVision; source switches were already covered via loadIntoPlayer.
                //
                // RAW url + headers, NEVER the initialPlayback proxy tuple. Routing decides on the RAW url
                // (routedToAVPlayer), but the mount used to feed the StremioServer 127.0.0.1 proxy rewrite
                // whenever the stream carried headers, so shouldDVRemux saw a loopback host, the DV remux
                // lane never mounted, the raw MKV load failed (no Matroska demuxer), and every header-carrying
                // DV title silently demoted to libmpv HDR10 while the chrome briefly claimed AVPlayer.
                // AVFoundation attaches the headers itself (AVURLAssetHTTPHeaderFieldsKey in loadFile) and
                // the remux server takes them directly; only libmpv (mpvSurface below) keeps the proxy.
                .play(url, headers: headers,
                      isDolbyVision: StreamRanking.isDolbyVision(recordQualityText ?? ""))
                .live(initialIsLive)
                .resumeOrigin(avSurfaceResumeOrigin ?? resumeSeconds)
                .onPropertyChange { _, name, data, token in handleProperty(name, data, loadToken: token) }
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
            // libmpv KEEPS the proxied initialPlayback tuple: the embedded server applies per-stream headers
            // server-side (the official-Stremio path picky CDNs need) and rewrites HLS playlists for mpv.
            .play(initialPlayback.url, headers: initialPlayback.headers, audioSidecar: audioSidecarURL,
                  isDolbyVision: StreamRanking.isDolbyVision(recordQualityText ?? ""))
            .live(initialIsLive)
            .onPropertyChange { _, name, data, token in handleProperty(name, data, loadToken: token) }
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
            Color.clear.contentShape(Rectangle())
                .onTapGesture { if isLocked { revealUnlockChip() } else { toggleControls() } }
                .ignoresSafeArea()
                .accessibilityLabel(isLocked ? "Unlock player controls" : "Show player controls")
                .accessibilityAction { if isLocked { revealUnlockChip() } else { toggleControls() } }

            if (buffering || reconnecting) && !loadFailed { bufferingOverlay }

            // Skip pill shows only while watching (controls hidden); suppressed once the Up Next band is up
            // so the two end-of-episode prompts never stack.
            // Suppressed while locked: the pill is a tap-to-seek affordance, and the whole point of the
            // lock is that no stray tap can move playback.
            if let seg = currentSkip, !controlsVisible, !isLocked, panel == nil, !loadFailed, upNextRemaining == nil { skipPill(seg) }

            // Render controls UNCONDITIONALLY (just faded/non-interactive when hidden) so VoiceOver can
            // still reach them when auto-hidden - otherwise a hidden bar drops out of the a11y tree (#31).
            // A LOCKED player keeps them faded AND non-interactive regardless of controlsVisible; the
            // unlock chip below is the only interactive element until unlock.
            if !loadFailed {
                controls.opacity(controlsVisible && !isLocked ? 1 : 0)
                    .allowsHitTesting(controlsVisible && !isLocked)
            }

            // The lock's single escape hatch: a small top-center chip, revealed by tapping the locked
            // video and auto-hidden a few seconds later. Tapping it unlocks and restores the chrome.
            if isLocked, unlockChipVisible, !loadFailed {
                VStack {
                    Button { unlock() } label: {
                        Label("Unlock", systemImage: "lock.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .vortxGlassToast(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Unlock player controls")
                    .padding(.top, 24)
                    Spacer()
                }
                .transition(.opacity)
                .zIndex(50)
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
                        // Transient engine notice as the shared VortX glass toast (warm glass + soft toast
                        // shadow), upgrading to Liquid Glass on OS 26. Background only; auto-hide logic unchanged.
                        .vortxGlassToast(in: Capsule())
                        .padding(.top, 24)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
            #endif

            if let panel { selectionSheet(panel) }

            if loadFailed { loadErrorOverlay }

            if stillWatchingPrompt { stillWatchingOverlay }

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
                                // Escape-hatch close on the shared TIGHT glass disc (shape-clipped material,
                                // never glassEffect, so no un-clipped dark halo). Background only; action unchanged.
                                .padding(12).vortxGlassDisc()
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
            // Fullscreen: Ctrl-Cmd-F, the standard macOS fullscreen shortcut. A MODIFIED key equivalent, so
            // (unlike the unmodified Space/arrows) it reaches this hidden SwiftUI button rather than being
            // swallowed by the Metal NSView's keyDown:, the same pattern the Esc/Cmd-[ handlers rely on, so
            // this never has to touch the installMacKeyMonitor NSEvent monitor.
            Button { toggleMacFullScreen() } label: { EmptyView() }
                .keyboardShortcut("f", modifiers: [.command, .control])
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
            playbackExited = false
            persistenceBlockedForExit = false
            // Diagnostic-only: this is the player surface, so the heartbeat reports the player route.
            VXProbeState.shared.setRoute("player")
            // Mark the engine player-active so CoreBridge skips the library-branch In-Library re-decode of
            // the (possibly huge) meta_details payload while the covered detail page is not visible. Cleared
            // in onDisappear. Depth-counted, so a trailer-over-detail then a real player stays active.
            core.setPlayerActive(true)
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
            if curSourceStream == nil { curSourceStream = initialSourceStream }
            if !engineAttributionInitialized {
                enginePlayerVideoId = initialEnginePlayerVideoId
                engineAttributionInitialized = true
            }
            if curDebridRef == nil { curDebridRef = recordDebridRef }
            if curHint == nil { curHint = recordQualityText }   // seed the "playing now" signature from the launch stream
            currentPickWasExplicit = startedFromExplicitPick   // honor an explicit launch pick on the first start-timeout
            currentPlaybackIsResume = startedFromResume        // a resume plays exact first but hops on a HARD failure
            #if os(iOS) || os(macOS)
            if engineLatch == nil { engineLatch = routedToAVPlayer }   // engine picked ONCE per playback
            #endif
            // [src-probe] Load-start anchor + launch classification. `resume=Y` + `explicit=N` is the
            // Continue-Watching auto-pick path (the one that produces "Tried 5 sources, none worked");
            // `explicit=Y` is a tapped source. `debridRef=Y` means the launch URL is a native-debrid link
            // that a CW resume may need to reresolve. This is the first line of the timeline for every play.
            srcProbeLoadStart = Date()
            #if os(iOS) || os(macOS)
            let srcProbeRouteAV = routedToAVPlayer ? "Y" : "N"
            #else
            let srcProbeRouteAV = "n/a"
            #endif
            srcProbe("LOAD START host=\(url.host ?? "-") resume=\(resumeSeconds > 5 ? "Y@\(Int(resumeSeconds))s" : "N") explicit=\(startedFromExplicitPick ? "Y" : "N") debridRef=\(recordDebridRef != nil ? "Y(\(recordDebridRef!.service))" : "N") trailer=\(isTrailer ? "Y" : "N") willRouteAV=\(srcProbeRouteAV)")
            // Diagnostic-only: a notable transition (a source begins loading) surfaced in the heartbeat too.
            VXProbe.event("player", "open title=\(VXProbeRedaction.identityToken(curTitle))")
            scrubThumbnails.configure(localCacheKey: trickplayLocalCacheKey)
            configureCommunityTrickplayProvisional()
            startTrickplayCaptureTimer()   // wall-clock capture backstop (fires on both engines)
            scheduleHide(); startLoadTimeout(); startIdleWatch()
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true   // hold the screen awake while the player is open (parity with tvOS)
            if !isTrailer { PlayerOrientation.forceLandscape() }   // rotate to landscape as the stream opens, even under rotation lock
            #elseif os(macOS)
            // macOS has no idle-timer API; hold a display-sleep assertion so the Mac doesn't dim/sleep
            // mid-movie (the iOS/tvOS keep-awake parity that was missing on Mac).
            macSleepActivity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled,
                                                                     reason: "StremioX video playback")
            installMacKeyMonitor()
            observeMacFullScreen()
            #endif
        }
        .onDisappear {
            invalidateEpisodeWorkForExit()
            core.setPlayerActive(false)   // balance the onAppear +1; re-enables the In-Library re-decode
            hideTask?.cancel(); loadTimeout?.cancel(); autoRetryTask?.cancel()
            stallWatchdog?.cancel(); recoveryDeadline?.cancel(); skipFetchTask?.cancel()
            refreshTask?.cancel(); sleepTask?.cancel(); trickplayCaptureTimer?.cancel(); idleWatchTask?.cancel()
            #if os(iOS) || os(macOS)
            engineNoticeTask?.cancel(); avStartWatchdog?.cancel()
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
            unobserveMacFullScreen()
            #endif
        }
        #if canImport(UIKit)
        // FOREGROUND RECONCILE (binge-desync fix, leg 2): an episode advance can straddle a background
        // boundary (the player stays mounted; iOS may kill the half-open incoming connection). Outside an
        // advance the published episode and the loaded file agree by construction, so only a pending
        // advance needs reconciling on return to foreground. Pairs with (never replaces) the mpv seam's
        // enterForeground, which restores video decode + play state. macOS never suspends: not wired there.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            reconcileAdvanceOnForeground()
        }
        #endif
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
            // Every playable source loaded for this title, newline-joined - handy for sending the whole
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

    private func terminalRoute(for loadToken: PlayerLoadToken?) -> EpisodePlaybackIdentity.TerminalEventRoute {
        EpisodePlaybackIdentity.terminalEventRoute(
            callbackToken: loadToken, activeToken: coordinator.player?.activeLoadToken,
            committedToken: committedLoadToken,
            pendingToken: pendingAdvance?.loadToken, pendingIssued: pendingAdvance?.issued == true,
            supersededToken: supersededAdvance?.pending.loadToken,
            supersededIssued: supersededAdvance?.pending.issued == true,
            switchingEpisode: switchingEpisode
        )
    }

    private func terminalAction(for loadToken: PlayerLoadToken?,
                                kind: EpisodePlaybackIdentity.TerminalEventKind)
        -> EpisodePlaybackIdentity.TerminalEventAction {
        EpisodePlaybackIdentity.terminalEventAction(
            route: terminalRoute(for: loadToken), kind: kind
        )
    }

    private func callbackBelongsToCommittedMedia(_ loadToken: PlayerLoadToken?) -> Bool {
        guard let loadToken, let committedLoadToken else { return false }
        return loadToken == committedLoadToken
            && loadToken == coordinator.player?.activeLoadToken
    }

    private func handleProperty(_ name: String, _ data: Any?, loadToken: PlayerLoadToken? = nil) {
        if pendingAdvance == nil, supersededAdvance == nil,
           let loadToken, loadToken == coordinator.player?.activeLoadToken {
            committedLoadToken = loadToken
        }
        if name == MPVProperty.duration, let value = data as? Double,
           !callbackBelongsToCommittedMedia(loadToken) {
            if pendingAdvance?.issued == true, loadToken == pendingAdvance?.loadToken {
                pendingAdvance?.deferredDuration = value
            } else if supersededAdvance?.pending.issued == true,
                      loadToken == supersededAdvance?.pending.loadToken {
                supersededAdvance?.pending.deferredDuration = value
            }
            return
        }
        if name == MPVProperty.trackList, !callbackBelongsToCommittedMedia(loadToken) {
            if pendingAdvance?.issued == true, loadToken == pendingAdvance?.loadToken {
                pendingAdvance?.deferredTrackList = true
            } else if supersededAdvance?.pending.issued == true,
                      loadToken == supersededAdvance?.pending.loadToken {
                supersededAdvance?.pending.deferredTrackList = true
            }
            return
        }
        if name == MPVProperty.seekable, let value = data as? Bool,
           !callbackBelongsToCommittedMedia(loadToken) {
            if pendingAdvance?.issued == true, loadToken == pendingAdvance?.loadToken {
                pendingAdvance?.deferredSeekable = value
            } else if supersededAdvance?.pending.issued == true,
                      loadToken == supersededAdvance?.pending.loadToken {
                supersededAdvance?.pending.deferredSeekable = value
            }
            return
        }
        switch name {
        case MPVProperty.pausedForCache:
            if let b = data as? Bool { buffering = b }
        case MPVProperty.videoParamsSigPeak:
            if let p = data as? Double { isHDR = p > 1.0; metadataLine = computeMetadataLine() }
        case MPVProperty.timePos:
            if let event = data as? PlayerTimePositionEvent,
               PlayerLoadProvenanceState.accepts(
                callbackToken: event.loadToken,
                activeToken: coordinator.player?.activeLoadToken
               ) {
                let d = event.seconds
                if pendingAdvance?.issued != true, supersededAdvance == nil {
                    committedLoadToken = event.loadToken
                }
                let supersededTick = supersededAdvance?.pending.issued == true
                    && event.loadToken == supersededAdvance?.pending.loadToken
                if supersededTick { return }
                if pendingAdvance?.issued == true,
                   event.loadToken == pendingAdvance?.loadToken, d <= 0 { return }
                if d > 0, !hasStartedPlaying {      // playback actually began
                    if let pending = pendingAdvance {
                        guard pending.issued,
                              PlayerLoadProvenanceState.canCommit(
                                callbackToken: event.loadToken,
                                activeToken: coordinator.player?.activeLoadToken,
                                pendingToken: pending.loadToken
                              ) else { return }
                    }
                    // [src-probe] FIRST FRAME: the overlay/spinner is about to clear and real playback begins.
                    // The gap between LOAD START and this line is the true startup latency; if a reconnect/hop
                    // message showed during that window (see the overlay-set probes) it was a transient shown
                    // then cleared here, not a real failure.
                    srcProbe("FIRST FRAME at pos=\(String(format: "%.1f", d))s (playback started, clearing overlays)")
                    hasStartedPlaying = true
                    // FIRST-FRAME COMMIT (binge-desync fix): the incoming episode's file actually
                    // rendered, so publish an in-flight advance NOW, before anything below
                    // (recordLastStream, the scrobble start) reads curMeta/curTitle - the store record
                    // then captures a matching (videoId, url) pair by construction.
                    let deferredDuration = pendingAdvance?.deferredDuration
                    let deferredTrackList = pendingAdvance?.deferredTrackList == true
                    let deferredSeekable = pendingAdvance?.deferredSeekable
                    commitPendingAdvanceOnFirstFrame(loadToken: event.loadToken)
                    if let deferredDuration {
                        handleProperty(MPVProperty.duration, deferredDuration, loadToken: event.loadToken)
                    }
                    if deferredTrackList {
                        handleProperty(MPVProperty.trackList, nil, loadToken: event.loadToken)
                    }
                    if let deferredSeekable {
                        handleProperty(MPVProperty.seekable, deferredSeekable, loadToken: event.loadToken)
                    }
                    loadTimeout?.cancel(); autoRetryTask?.cancel()
                    recoveryDeadline?.cancel(); recoveryDeadline = nil
                    #if os(iOS) || os(macOS)
                    avStartWatchdog?.cancel(); avStartWatchdog = nil   // a playable frame arrived: keep AVPlayer
                    // [dv] time-to-first-frame for the watchdog trail (one-shot: armedAt self-clears). Only
                    // the remux lane logs it; the mpv lane / plain AVPlayer starts are not the diag target.
                    if let armed = avWatchdogArmedAt {
                        avWatchdogArmedAt = nil
                        if (coordinator.player as? AVPlayerEngineController)?.isRemuxMounted == true {
                            DiagnosticsLog.log("dv", String(format: "remux first frame in %.1fs (start watchdog disarmed)", Date().timeIntervalSince(armed)))
                        }
                    }
                    #endif
                    reconnecting = episodeResolveGeneration != nil
                    loadFailed = false
                    autoRetryCount = 0; stallRecoveries = 0
                    recordLastStream()              // remember this working link for CW direct-resume (parity with tvOS)
                    // External sync (Trakt/SIMKL): live scrobble START. Additive + fail-soft + gated inside
                    // the coordinator (owner profile only, provider connected, toggle on); a no-op with empty
                    // creds. Live content is excluded (no scrobble meaning), mirroring the stop hooks. Duration
                    // is often still 0 at first frame, so this starts at 0% and later ticks / the stop carry
                    // the real percentage.
                    if let m = curMeta, !effectivelyLive { ScrobbleCoordinator.shared.playbackStarted(m, position: d, duration: duration, sessionToken: playbackSessionID) }
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
                    // Durationless-stream fallback (mirrors TVPlayerView): many debrid direct-HTTP MKVs
                    // never DELIVER mpv's `duration` EVENT, yet the property reads fine - and the resume
                    // seek, the ~5s progress pushes, and watched-at-90% all key off `duration > 0`, so
                    // those streams never saved a watch position. Poll the engine each (coalesced) tick
                    // until a real value lands and route it through the same handling as the event.
                    if duration <= 0, !effectivelyLive,
                       let engineDur = coordinator.player?.mediaDurationSeconds(), engineDur.isFinite, engineDur > 0 {
                        handleProperty(MPVProperty.duration, engineDur, loadToken: event.loadToken)
                    }
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
                        reportProgress(d)
                    }
                    // ~60s in → the user is really watching this: auto-add to the Library (D8) and send the
                    // anonymized fleet watch ping (D9), each once per playback. Both are idempotent + gated
                    // (D8 by the setting + per-profile dedup; D9 by MoatConsent + per-title/day dedup), so a
                    // resume that starts past 60s, a source hop, or an episode switch never double-fires here
                    // for the same title. Skipped for live (no library/ranking meaning) and ad-hoc plays.
                    if !autoAddedThisPlayback, !effectivelyLive, d >= 60, let m = curMeta {
                        autoAddedThisPlayback = true
                        LibraryAutoAdd.addIfNeeded(meta: m, core: core, enabled: autoAddLibrary)
                        // Resolve a tmdb:… hub/catalog id to its tt identity first (fire-and-forget on a cache
                        // miss) so those plays feed the pool too; a tt id still pings inline. Never blocks.
                        WatchSignalClient.pingResolvingTMDB(contentId: m.libraryId, type: m.type, seriesHint: m.season != nil)
                    }
                    // Halfway through a series episode → warm the NEXT episode's source in the
                    // background (start its torrent's peer search, pull the first bytes of a direct
                    // file) so auto-advance isn't a cold start. Purely additive: the actual advance
                    // still resolves through loadEpisode, so progress reporting and engine binding are
                    // unchanged - this only pre-heats the slow I/O the next open would otherwise pay for.
                    // Past the halfway mark when the duration is known, or after ~2 min of playback when it
                    // ISN'T: many debrid MKVs never emit mpv's `duration`, so the duration>60 trigger alone
                    // never fired for them and the next episode never pre-heated (the "next episode cold-starts"
                    // case). warmNextIfNeeded is idempotent per episode.
                    if !effectivelyLive, (duration > 60 && d / duration >= 0.5) || (duration <= 0 && d >= 120) { warmNextIfNeeded() }
                    // ~90% in → flip the engine's watched marker live, so the title leaves Continue
                    // Watching / shows as watched without waiting for EOF (mirrors tvOS:180-183).
                    if !markedWatched, !effectivelyLive, duration > 0, d / duration >= 0.9,
                       let m = curMeta {
                        markedWatched = true
                        core.markPlaybackWatched(m, allowEngineWrite: engineWritesOpen)
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
                        // A remux resume is fulfilled before mount by rebuilding from the configured source
                        // origin. Do not seek AVPlayer into a forward-only playlist after mount. Verify the
                        // achieved keyframe origin instead; only a genuinely unreachable request needs the
                        // progress floor and an unavailable notice.
                        if let av = coordinator.player as? AVPlayerEngineController,
                           let origin = av.achievedRemuxTimelineOriginSeconds {
                            switch RemuxResumePolicy.preStartSeek(target: resumeSeconds, origin: origin) {
                            case .satisfied:
                                suppressedResumeFloor = nil
                                currentTime = origin
                                lastReported = origin
                            case .unreachable:
                                suppressedResumeFloor = resumeSeconds
                                lastReported = resumeSeconds
                                showEngineNotice("That resume point is unavailable for this source. Playing from the earliest available position.")
                            }
                        } else {
                            coordinator.player?.seek(to: resumeSeconds)
                            currentTime = resumeSeconds
                            lastReported = resumeSeconds
                        }
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
                // External sync (Trakt) live scrobble pause/resume. Scrobble ONLY: this handler persists
                // nothing else (no resume-point write). Additive + fail-soft + gated inside the coordinator;
                // a no-op with empty creds. Live content is excluded (parity with the start/stop hooks).
                // SIMKL has no live scrobble, so it is skipped by capability.
                if callbackBelongsToCommittedMedia(loadToken),
                   let m = curMeta, !effectivelyLive {
                    let pos = max(currentTime, suppressedResumeFloor ?? 0)
                    if b { ScrobbleCoordinator.shared.playbackPaused(m, position: pos, duration: duration) }
                    else { ScrobbleCoordinator.shared.playbackResumed(m, position: pos, duration: duration) }
                }
            }
        case MPVProperty.trackList:
            refreshTracks()
            let summary = coordinator.player?.mediaSummary()
            videoWidth = summary?.width ?? 0; videoHeight = summary?.height ?? 0; audioCodec = summary?.audioCodec ?? ""
            metadataLine = computeMetadataLine()
            // Gap A (#76): on AVPlayer, chapters() is [] at readyToPlay (loadChapters is async) and the engine
            // re-emits trackList precisely once they resolve, so re-pull skip candidates + chapter marks here.
            // On libmpv chapters() is already synchronous at duration, so this is a cheap no-op re-run there.
            refreshSkipSegments()
            if !appliedAutoTracks, !audioTracks.isEmpty || !subtitleTracks.isEmpty {
                appliedAutoTracks = true
                autoSelectTracks()
            }
        case MPVProperty.endFileError:
            switch terminalAction(for: loadToken, kind: .error) {
            case .handleCommitted:
                break
            case .handlePending:
                pendingAdvance?.terminal = true
                uncommittedIdentityBlocked = true
            case .markSupersededTerminal:
                supersededAdvance?.pending.terminal = true
                uncommittedIdentityBlocked = true
                return
            case .ignoreOutgoingError, .ignoreStale:
                return
            case .persistOutgoingCompletionOnly:
                return
            }
            #if os(iOS) || os(macOS)
            // ANY AVPlayer failure, pre-start (a Profile 7 / TrueHD-only DV remux, a container AVPlayer
            // can't open) or MID-PLAY, demotes to libmpv IN PLACE: flipping avEngineFailed swaps
            // playerSurface to the mpv engine, which re-loads initialPlayback from scratch. A DV attempt
            // must never dead-end on the source-error screen (owner invariant).
            // A pre-first-frame failure demotes SILENTLY (no notice); a genuine mid-play decode failure keeps
            // the informative DV notice. Either way it re-loads the SAME source on libmpv, never a source hop.
            if coordinator.player is AVPlayerEngineController, !avEngineFailed {
                srcProbe("endFileError on AVPlayer -> demote to libmpv in place (not a hop) reason=\((data as? String) ?? "-")")
                demoteAVPlayerToMPV(silent: !hasStartedPlaying)
                return
            }
            // Stale error from the just-dismounted AVPlayer engine (a queued event can land after the swap):
            // swallow it so it never burns the fresh mpv load's retry budget or paints the error overlay.
            if let t = avDemotedAt, Date().timeIntervalSince(t) < 2 {
                srcProbe("endFileError SWALLOWED (stale post-demote grace <2s) reason=\((data as? String) ?? "-")")
                return
            }
            #endif
            if !hasStartedPlaying {                  // only flag failures BEFORE playback
                srcProbe("endFileError -> handleLoadFailure reason=\((data as? String) ?? "-")")
                handleLoadFailure((data as? String) ?? "")
            } else {
                srcProbe("endFileError IGNORED (already playing) reason=\((data as? String) ?? "-")")
            }
        case MPVProperty.endFileEof:
            let completionOnly: Bool
            switch terminalAction(for: loadToken, kind: .eof) {
            case .handleCommitted:
                completionOnly = false
            case .handlePending:
                pendingAdvance?.terminal = true
                uncommittedIdentityBlocked = true
                loadTimeout?.cancel()
                handleLoadFailure("Episode ended before its first frame")
                return
            case .markSupersededTerminal:
                supersededAdvance?.pending.terminal = true
                uncommittedIdentityBlocked = true
                return
            case .persistOutgoingCompletionOnly:
                completionOnly = true
            case .ignoreOutgoingError, .ignoreStale:
                return
            }
            // Mark watched if the 90% tick didn't already (short clips), then advance or finish.
            if !markedWatched, !effectivelyLive, let m = curMeta {
                markedWatched = true
                core.markPlaybackWatched(m, allowEngineWrite: engineWritesOpen)
            }
            // External sync (Trakt/SIMKL): scrobble STOP at end-of-file (a completion). Additive + fail-soft +
            // gated + once-latched inside the coordinator (dedupes against the watched record above), no-op
            // with empty creds. Fired for the finishing episode before any in-place advance opens a new session.
            if !effectivelyLive, let m = curMeta { ScrobbleCoordinator.shared.playbackStopped(m, position: max(currentTime, suppressedResumeFloor ?? 0), duration: duration) }
            if completionOnly { return }
            if sleepAtEpisodeEnd {
                // Sleep timer set to "End of episode": this one finished, so stop here. Do NOT auto-advance,
                // and do NOT finishedWatching (that would clear the whole series from Continue Watching).
                sleepAtEpisodeEnd = false
                if let h = currentTorrentHash { closeTorrent(hash: h) }   // terminal exit: free the torrent engine (no-op for direct/debrid)
                DiskCacheSetting.clearCache()   // terminal: drop the finished title's on-disk buffer
                exitPlayerFullScreenIfNeeded()  // item 6: land back in windowed browse, not stranded fullscreen
                invalidateEpisodeWorkForExit()
                onClose()
            } else if upNextSuppressed {
                // User chose "Watch Credits": play through to the end, then stop here instead of
                // auto-advancing. The episode is already marked watched above, so Continue Watching
                // rolls to the next episode on its own without yanking the viewer out of the credits.
                if let h = currentTorrentHash { closeTorrent(hash: h) }   // terminal exit: free the torrent engine (no-op for direct/debrid)
                DiskCacheSetting.clearCache()   // terminal: drop the finished title's on-disk buffer
                exitPlayerFullScreenIfNeeded()  // item 6: land back in windowed browse, not stranded fullscreen
                invalidateEpisodeWorkForExit()
                onClose()
            } else if canNextEpisode, let i = episodeIndex, !skipEditActive {
                // In-place advance to the next episode: KEEP the cache (the same player keeps playing).
                // Suppressed while the skip editor is open so an end-of-credits edit isn't yanked away.
                // "Still watching?" binge guard: after N back-to-back auto-advances with zero interaction,
                // pause at this boundary and ask instead of rolling straight on (Continue resumes the roll).
                consecutiveAutoAdvances += 1
                if consecutiveAutoAdvances >= Self.idleAutoAdvanceLimit {
                    presentStillWatching(pendingNext: episodes[i + 1].id)
                } else {
                    goToEpisode(episodes[i + 1].id, autoAdvance: true)
                }
            } else if hasNext, !skipEditActive {
                onNext()                                  // legacy non-episode caller (in-place)
            } else if !skipEditActive {
                // Finished (movie or last episode): rewind the title OUT of Continue Watching. The engine
                // keeps any item with time_offset > 0 in the rail, so without this a finished title lingers
                // at its end position forever (the "CW never clears" report). Mirrors tvOS autoAdvance:1479.
                // Guard: a series that reached EOF with NO episode list (a CW resume whose list never loaded)
                // is a mid-season episode misread as a finale, so do NOT clear the whole series from Continue
                // Watching here; only genuine finishes (movies, or a series with a real list) rewind it out.
                if let m = curMeta,
                   EpisodePlaybackIdentity.canRewindWholeTitleAtTerminal(
                       usesSeriesLifecycle: m.usesSeriesLifecycle,
                       currentEpisodeIndex: episodeIndex,
                       episodeCount: episodes.count
                   ) {
                    core.finishedWatching(libraryId: m.libraryId)
                }
                if let h = currentTorrentHash { closeTorrent(hash: h) }   // terminal exit: free the torrent engine (no-op for direct/debrid)
                DiskCacheSetting.clearCache()   // terminal: drop the finished title's on-disk buffer
                exitPlayerFullScreenIfNeeded()  // item 6: land back in windowed browse, not stranded fullscreen
                invalidateEpisodeWorkForExit()
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
    /// one-tap resume this stream and reopening the title auto-picks the same quality - the iOS/Mac twin
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
        VXProbe.log("tp", "provisional key MISS: playing=\(VXProbeRedaction.identityToken(m.libraryId)) metaDetails=\(VXProbeRedaction.identityToken(core.metaDetails?.meta?.id)) (fetching runtime)")
        Task {
            var ttId = m.libraryId
            if !ttId.hasPrefix("tt") {
                guard ttId.lowercased().hasPrefix("tmdb"),
                      let tt = await CommunityTrickplay.resolveIMDbID(rawId: m.libraryId, seriesHint: m.season != nil) else {
                    VXProbe.log("tp", "provisional key MISS stays: unresolvable id \(VXProbeRedaction.identityToken(m.libraryId))")
                    return
                }
                ttId = tt
            }
            var secs = await Self.cinemetaRuntimeSeconds(kind: "movie", id: ttId)
            if secs <= 0 { secs = await Self.cinemetaRuntimeSeconds(kind: "series", id: ttId) }
            guard secs > 0 else {
                VXProbe.log("tp", "provisional key MISS stays: no cinemeta runtime for \(VXProbeRedaction.identityToken(ttId))")
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
        // Twin of CoreMeta.runtimeSeconds: compute in Double and cap each field so an add-on/Cinemeta garbage
        // value yields 0 rather than trapping on Int overflow. A field over 24h (86_400s) is rejected; the
        // total must be finite and positive and is clamped to a 24h ceiling.
        let maxSeconds = 86_400.0
        func field(_ rawField: Substring) -> Double? {
            guard let n = Double(rawField.trimmingCharacters(in: .whitespaces)),
                  n.isFinite, n >= 0, n <= maxSeconds else { return nil }
            return n
        }
        func finalize(_ seconds: Double) -> Double {
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return min(seconds, maxSeconds)
        }
        if r.contains(":") {
            let p = r.split(separator: ":").compactMap { field($0) }
            if p.count == 3 { return finalize(p[0] * 3600 + p[1] * 60 + p[2]) }
            if p.count == 2 { return finalize(p[0] * 60 + p[1]) }
        }
        if let hRange = r.range(of: #"\d+\s*h"#, options: .regularExpression) {
            let h = Double(r[hRange].filter(\.isNumber)) ?? 0
            var mins = 0.0
            if let mRange = r.range(of: #"\d+\s*m"#, options: .regularExpression,
                                    range: hRange.upperBound..<r.endIndex) {
                mins = Double(r[mRange].filter(\.isNumber)) ?? 0
            }
            guard h <= maxSeconds, mins <= maxSeconds else { return 0 }
            return finalize(h * 3600 + mins * 60)
        }
        let minutes = Double(r.prefix { $0.isNumber }) ?? 0
        guard minutes <= maxSeconds else { return 0 }
        return finalize(minutes * 60)
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
        guard let player = coordinator.player else { VXProbe.log("tp", "no player mounted at \(Int(time))s"); return }
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
            VXProbe.log("tp", "\(engine) capture at \(Int(time))s never serviced (VO idle) - releasing guard")
        }
        player.captureFrameJPEGData(maxWidth: 480) { data in
            // MAIN-ACTOR HOP (the owner-device zero-contribution fix): the libmpv engine calls this completion
            // on its background capture queue (MPVMetalViewController.captureQueue / a Metal completion thread),
            // NOT the main thread - only the AVPlayer engine hops to main itself. On the owner's primary engine
            // (Mac 4K/HDR/DV + iOS libmpv) this closure therefore ran OFF the main actor, so the @MainActor
            // `localTrickplayCaptureInFlight` reset and `recordCapturedFrameData` (which appends to sessionFrames
            // and fires the community upload) executed on a background thread against main-actor state -> the
            // in-flight guard could wedge and the community frames never reliably accumulated, so the pool got
            // ZERO rows from libmpv plays even though the LOCAL disk cache (its own ioQueue) still worked. Hop to
            // the main actor here so BOTH engines feed record+upload identically. `data` (Data) is Sendable.
            //
            // The heavy JPEG decode + macOS near-black rasterization/sampling runs HERE, off the main actor (this
            // libmpv completion is on a background capture queue; the AVPlayer engine already hops to main before
            // calling back, so its decode is on main, which is unavoidable and cheap for that path). Only the small
            // main-actor tail (in-flight reset + record/upload of the already-decoded frame) hops to the main actor.
            guard let data else {
                Task { @MainActor in
                    watchdog.cancel()
                    self.localTrickplayCaptureInFlight = false
                    VXProbe.log("tp", "\(engine) captureFrameJPEGData returned NIL at \(Int(time))s (no video output / protected / not-ready)")
                }
                return
            }
            VXProbe.log("tp", "\(engine) captured \(data.count) bytes at \(Int(time))s")
            let decoded = ScrubThumbnailsStore.decodeCapturedFrame(data, at: time)   // heavy decode + black-check OFF main
            Task { @MainActor in
                watchdog.cancel()
                self.localTrickplayCaptureInFlight = false
                guard let decoded else { return }   // decode failed / near-black: already logged off-actor
                self.scrubThumbnails.recordDecodedFrame(decoded, data: data, at: time)
            }
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
    /// sent anywhere. iOS / Mac only - tvOS has no share sheet.
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
        // Unified-identity guard (binge-desync fix): this records the (videoId, url) pair Continue Watching
        // will replay VERBATIM, so it must only ever run on a COMMITTED identity - the first-frame hook
        // commits any in-flight advance before calling here, making curMeta and curURL the same episode by
        // construction. Refuse a mid-advance call outright so no future code path can store a mixed
        // (old-episode-url under new-episode-id) or lagging entry.
        guard pendingAdvance == nil else { return }
        guard let m = curMeta else { return }
        let ref = curDebridRef
        // A raw episode torrent has no native-debrid ref. Preserve the exact Stremio selector that made its
        // loopback URL safe so a later Continue-Watching resume does not degrade into ambiguous hash-only /0.
        let rawTorrent = curIsTorrent ? currentStream : nil
        LastStreamStore.record(libraryId: m.libraryId, entry: .init(
            videoId: m.videoId, url: (curURL ?? url).absoluteString, title: curTitle,
            season: m.season, episode: m.episode, name: m.name,
            poster: m.poster, type: m.type, qualityText: curHint ?? recordQualityText,
            bingeGroup: curBingeState ?? recordBingeGroup,
            torrent: curIsTorrent, savedAt: Date(), headers: curHeaders,
            debridService: ref?.service.rawValue,
            infoHash: curIsTorrent ? rawTorrent?.infoHash : ref?.infoHash,
            debridFileId: ref?.fileId, debridTorrentId: ref?.torrentId,
            fileIdx: curIsTorrent ? rawTorrent?.fileIdx : ref?.fileIdx,
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
    /// [src-probe] Diagnostic-only, side-effect-free. Emits a single `[src-probe]` NSLog line with the
    /// current attempt/hop counters + elapsed-since-load-start, so a single play (and a CW resume) produce a
    /// readable source-lifecycle timeline on Terminal stdout. Pure logging: never mutates state, never
    /// changes control flow. Remove once the error-flash / 5-source-fail root cause is understood.
    private func srcProbe(_ event: String) {
        let elapsed = Date().timeIntervalSince(srcProbeLoadStart)
        NSLog("[src-probe] %@ | loadFailed=%@ started=%@ reconnecting=%@ buffering=%@ hops=%d/%d retry=%d/%d explicit=%@ torrent=%@ av=%@ elapsed=%.2fs errMsg=%@",
              event,
              loadFailed ? "Y" : "N",
              hasStartedPlaying ? "Y" : "N",
              reconnecting ? "Y" : "N",
              buffering ? "Y" : "N",
              sourceHops, maxSourceHops,
              autoRetryCount, maxAutoRetries,
              currentPickWasExplicit ? "Y" : "N",
              curIsTorrent ? "Y" : "N",
              isAVPlayerActive ? "Y" : "N",
              elapsed,
              loadErrorMsg.isEmpty ? "-" : loadErrorMsg)
    }

    /// (retry, stall recovery, source switch), mirroring tvOS `loadIntoPlayer`.
    @discardableResult
    private func loadIntoPlayer(_ u: URL, headers h: [String: String]?, live: Bool,
                                reusing loadToken: PlayerLoadToken? = nil,
                                contentHint: String? = nil,
                                resumeOrigin: Double? = nil) -> PlayerLoadToken? {
        // ENGINE-AWARE playback tuple. The AVFoundation engine must receive the RAW stream url + headers:
        // it attaches the headers itself (AVURLAssetHTTPHeaderFieldsKey) and the DV remux server takes them
        // directly, while the StremioServer proxy rewrite (playback(for:)) turns the host into 127.0.0.1,
        // which makes shouldDVRemux's loopback veto reject the DV remux lane and dead-ends a DV MKV on raw
        // AVPlayer (no Matroska demuxer -> .failed -> demote to libmpv HDR10). Only libmpv keeps the proxy
        // (server-side header injection for picky CDNs + HLS playlist rewriting). Keyed off the MOUNTED
        // controller because that is exactly who receives this loadFile; when no controller is mounted the
        // call is a no-op either way.
        let p: (url: URL, headers: [String: String]?)
        if coordinator.player is AVPlayerEngineController {
            p = (u, h)
        } else {
            p = playback(for: u, headers: h)
        }
        // Keep the yt-direct audio sidecar ONLY when reloading the launch URL itself (a trailer retry);
        // any other target (episode/source switch) is a normal content stream and must load sidecar-free.
        let sidecar = (u == url) ? audioSidecarURL : nil
        // Tell the libmpv lane whether this stream is Dolby Vision (same flag the engine router uses) so a DV
        // file that lands on libmpv drives the display into DV mode instead of HDR10 (tvOS effect; harmless on
        // iOS/macOS, which have no display-mode switch).
        coordinator.player?.contentIsDolbyVision = StreamRanking.isDolbyVision(
            contentHint ?? curHint ?? recordQualityText ?? ""
        )
        guard let player = coordinator.player else { return nil }
        let requestedResumeOrigin = live ? 0 : (
            resumeOrigin ?? avSurfaceResumeOrigin ?? (hasStartedPlaying ? currentTime : resumeSeconds)
        )
        avSurfaceResumeOrigin = requestedResumeOrigin
        player.configureResumeOrigin(seconds: requestedResumeOrigin)
        let candidateToken = player.loadFile(
            p.url, headers: p.headers, live: live, audioSidecar: sidecar,
            reusing: loadToken
        )
        let issuedToken = candidateToken == player.activeLoadToken ? candidateToken : nil
        if pendingAdvance != nil {
            pendingAdvance?.loadToken = issuedToken
            pendingAdvance?.issued = issuedToken != nil
            if issuedToken != nil {
                pendingAdvance?.terminal = false
                pendingAdvance?.deferredDuration = nil
                pendingAdvance?.deferredTrackList = false
                pendingAdvance?.deferredSeekable = nil
                supersededAdvance = nil
            }
        } else if let issuedToken {
            committedLoadToken = issuedToken
        }
        return issuedToken
    }

    /// A pre-playback failure (an endFileError before the first frame). For a torrent, the engine simply
    /// isn't warm yet so a quick retry won't help - warm it up (poll peers/bytes) then reload. Otherwise
    /// auto-retry a couple of times, then hop to another source, then show the manual error overlay.
    /// Now at full parity with tvOS `handleLoadFailure`, including the embedded-server torrent warm-up.
    /// A resume's exact stored source failed (its debrid link expired). Re-select the SAME source: mint a fresh
    /// link for the same file via DebridCoordinator (a single requestdl / re-add, not a full source re-pick),
    /// reset the load state, and replay it in place. Returns true once it kicks off (the caller stops); false
    /// when there is no debrid provenance to re-resolve, so the caller falls through to the failover hop.
    private func retryResumeSameSource() -> Bool {
        let retryRef = pendingAdvance?.debridRef ?? curDebridRef
        let retryMeta = pendingAdvance?.meta ?? curMeta
        guard let ref = retryRef, !ref.infoHash.isEmpty else { return false }
        let episodeHint: DebridEpisode? = retryMeta.flatMap { meta -> DebridEpisode? in
            guard let season = meta.season, season >= 0,
                  let episode = meta.episode, episode > 0 else { return nil }
            return DebridEpisode(season: season, episode: episode)
        }
        let retryRequiresSemanticSelection = isEpisodePlaybackContext
        let hasExactProviderIDs = ref.service == .torBox && ref.torrentId != nil && ref.fileId != nil
        // Raw fileIdx is not a provider-array selector. Missing semantic identity may try only TorBox's exact
        // provider-ID path; the resolver closes before any re-add if that fast path fails.
        if retryRequiresSemanticSelection, episodeHint == nil, !hasExactProviderIDs { return false }
        resumeRetryGeneration &+= 1
        let generation = resumeRetryGeneration
        let targetVideoID = retryMeta?.videoId
        let retryURL = curURL
        let retrySource = currentStream
        resumeSourceReresolved = true
        // Fresh load state + in-place retry budget for a clean attempt at the SAME source; keep the resume offset.
        autoRetryCount = 0; bufferGraceUsed = 0; lastBufferedAtWatchdog = -1; bufferedTime = 0
        buffering = true; hasStartedPlaying = false; isSeekable = true; appliedSize = false; loadErrorMsg = ""
        reconnectMsg = "Reloading your source…"; withAnimation { reconnecting = true }
        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor in
            let fresh = try? await DebridCoordinator.shared.reresolve(
                service: ref.service, infoHash: ref.infoHash,
                torrentId: ref.torrentId, fileId: ref.fileId, fileIdx: ref.fileIdx,
                episode: episodeHint, requiresSemanticSelection: retryRequiresSemanticSelection)
            let activeMeta = pendingAdvance?.meta ?? curMeta
            let activeRef = pendingAdvance?.debridRef ?? curDebridRef
            guard !Task.isCancelled,
                  EpisodePlaybackIdentity.asyncMediaResultIsCurrent(
                    capturedGeneration: generation, currentGeneration: resumeRetryGeneration,
                    capturedVideoID: targetVideoID, currentVideoID: activeMeta?.videoId
                  ),
                  activeRef == ref, curURL == retryURL, currentStream == retrySource else { return }
            if let fresh {
                srcProbe("resume: re-selected the SAME source (fresh link) after the stored link expired")
                reconnecting = false
                curURL = fresh
                let freshRef = DebridPlaybackRef(
                    url: fresh, service: ref.service, infoHash: ref.infoHash,
                    torrentId: ref.torrentId, fileId: ref.fileId, fileIdx: ref.fileIdx
                )
                if pendingAdvance != nil {
                    pendingAdvance?.url = fresh
                    pendingAdvance?.debridRef = freshRef
                } else {
                    curDebridRef = freshRef
                }
                if let target = retryMeta, let source = currentStream {
                    let succeeded = core.loadEnginePlayer(
                        for: source, videoId: target.videoId,
                        base: engineAddonBase(for: source), resolvedURL: fresh
                    )
                    enginePlayerVideoId = EpisodePlaybackIdentity.boundVideoID(
                        requestedVideoID: target.videoId, bindingSucceeded: succeeded
                    )
                }
                // resumeSeconds is the launch input (immutable) and the resume never started, so loadIntoPlayer
                // applies the correct resume offset on its own.
                let issuedToken = loadIntoPlayer(fresh, headers: curHeaders, live: isLive)
                if pendingAdvance != nil { pendingAdvance?.loadToken = issuedToken }
                startLoadTimeout()
            } else {
                srcProbe("resume: same source unavailable on re-resolve -> hopping to another")
                reconnecting = false
                if !hopToNextSource(reason: "resume source gone") { presentTerminalLoadFailure() }
            }
        }
        return true
    }

    private func handleLoadFailure(_ msg: String) {
        guard !hasStartedPlaying, !loadFailed else {
            srcProbe("handleLoadFailure NO-OP (started=\(hasStartedPlaying ? "Y" : "N") loadFailed=\(loadFailed ? "Y" : "N")) msg=\(msg.isEmpty ? "-" : msg)")
            return
        }
        srcProbe("handleLoadFailure ENTER msg=\(msg.isEmpty ? "-" : msg)")
        loadErrorMsg = msg
        loadTimeout?.cancel()
        if curIsTorrent {
            // A torrent that errors (or never starts) before the first frame usually just isn't warm
            // yet - no peers / no data. mpv's reconnect=1 would otherwise buffer it forever. Warm the
            // engine, then hand back to mpv. Bounded + capped, so a dead torrent still errors.
            srcProbe("handleLoadFailure -> torrent, warm up")
            warmUpTorrent()
            return
        }
        if isLive {
            srcProbe("handleLoadFailure -> live reconnect")
            scheduleReconnect(reason: "live load failure", message: "Reconnecting live stream…", backoff: 0.5)
            return
        }
        guard autoRetryCount < maxAutoRetries else {
            reconnecting = false
            // Honor an explicit user pick: a hard failure after the in-place retries surfaces a clear
            // "choose another source" error instead of silently hopping to a different (often lower-quality)
            // source. Only the auto path (Watch Now / resume) falls through to the failover hop below.
            // A Continue-Watching RESUME is not a manual pick: its stored debrid link expires, so a hard failure
            // must fall through to the failover hop + fresh-sources wait below rather than dead-ending here.
            if currentPickWasExplicit && !currentPlaybackIsResume {
                if loadErrorMsg.isEmpty {
                    loadErrorMsg = curIsMediaServer
                        ? "This file's format can't direct-play on this device yet. Server transcoding isn't supported in this version."
                        : "This source didn't load. Choose another source."
                }
                srcProbe("OVERLAY SET: explicit pick failed after \(maxAutoRetries) retries -> loadFailed msg=\(loadErrorMsg)")
                presentTerminalLoadFailure()
                return
            }
            // RESUME (Continue Watching): the exact source's stored link expired. Re-select the SAME source once
            // more, minting a fresh debrid link for the same file, BEFORE hopping to a different source, so a
            // resume stays on the source you chose. Only if that source is genuinely gone do we fall through.
            if currentPlaybackIsResume, !resumeSourceReresolved, retryResumeSameSource() { return }
            srcProbe("handleLoadFailure -> auto path, retries exhausted, trying hopToNextSource")
            if hopToNextSource(reason: "load failed") { return }
            // CW-resume of a debrid/direct stream whose stored link expired (debrid URLs are time-limited):
            // iOSDirectResume kicks off a background reload of the title's streams, but they may not have
            // arrived yet, so the hop above found nothing. Wait briefly for the fresh streams and retry the
            // hop, rather than dead-ending on the "sources didn't load" overlay and forcing a manual re-pick.
            // One wait-cycle per playback; only for a metadata-backed (resumed) non-torrent play.
            if recordMeta != nil, !curIsTorrent, !awaitedFreshSources {
                awaitedFreshSources = true
                srcProbe("CW-RESUME wait-and-hop: stored link failed + no untried source yet, waiting up to ~4s for fresh streams to load")
                reconnectMsg = "Finding a fresh source…"; withAnimation { reconnecting = true }
                srcProbe("OVERLAY SET (spinner): reconnect='Finding a fresh source…' (CW-resume awaiting fresh streams)")
                autoRetryTask?.cancel()
                autoRetryTask = Task { @MainActor in
                    for i in 0 ..< 16 {   // up to ~4s for the background stream load to land
                        try? await Task.sleep(for: .milliseconds(250))
                        if Task.isCancelled { return }
                        if hopToNextSource(reason: "fresh sources after wait") {
                            srcProbe("CW-RESUME wait-and-hop SUCCEEDED after ~\(String(format: "%.2f", Double(i + 1) * 0.25))s")
                            reconnecting = false; return
                        }
                    }
                    srcProbe("CW-RESUME wait-and-hop EXHAUSTED (~4s, no untried source ever appeared) -> error overlay")
                    reconnecting = false
                    srcProbe("OVERLAY SET: loadFailed=true (CW-resume, no fresh source)")
                    presentTerminalLoadFailure()
                }
                return
            }
            srcProbe("OVERLAY SET: loadFailed=true (auto path, hop budget/candidates exhausted, not eligible for CW wait-and-hop)")
            presentTerminalLoadFailure()
            return
        }
        autoRetryCount += 1
        srcProbe("handleLoadFailure -> scheduleReconnect (auto-retry \(autoRetryCount)/\(maxAutoRetries))")
        scheduleReconnect(reason: "load failure \(autoRetryCount)", message: "Recovering…", backoff: autoRetryBackoff)
    }

    /// Shared "show Recovering… then reload" path for transient pre-start hiccups and live reconnects.
    private func scheduleReconnect(reason: String, message: String, backoff: Double) {
        buffering = true
        reconnectMsg = message
        srcProbe("OVERLAY SET (spinner): reconnect='\(message)' reason=\(reason) backoff=\(backoff)s (transient reconnect, NOT the error overlay)")
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
            // Refresh the first-buffer grace budget too, so a manual retry after an exhausted explicit pick
            // gets its full extend/retry grace back (not a single no-grace 30s attempt).
            bufferGraceUsed = 0; lastBufferedAtWatchdog = -1
        }
        autoRetryTask?.cancel()
        srcProbe("retryLoad reload-in-place (resetAutoRetries=\(resetAutoRetries)) host=\((curURL ?? url).host ?? "-")")
        let resume = hasStartedPlaying ? currentTime : resumeSeconds
        withAnimation { loadFailed = false }
        bufferedTime = 0   // reload: clear the buffered-ahead band so the buffer-grace watchdog re-baselines against the new fill, not the previous source's edge
        buffering = true; hasStartedPlaying = false; isSeekable = true; appliedSize = false; loadErrorMsg = ""
        subtitleLoadingURL = nil   // self-heal: a subtitle load stranded by the old engine must not gate the reload's picks
        srcProbeLoadStart = Date()   // [src-probe] a reload is a fresh attempt: re-anchor the elapsed clock
        loadIntoPlayer(curURL ?? url, headers: curHeaders, live: isLive, resumeOrigin: resume)
        startLoadTimeout()
    }

    /// REQ-260721-78 option A (surface side): the ONE way this screen publishes a terminal load
    /// failure. On a terminal native-HLS Dolby Vision failure the old code set `loadFailed` and left
    /// the AV controller live, so a delayed `preferredDisplayCriteria` completion could still switch
    /// the display mode, attach the item, and start playback BEHIND the terminal overlay. Retire the
    /// engine synchronously FIRST (stop() invalidates the load token, advances the item generation,
    /// cancels the native pre-attach task and criteria work, and tears down item/remux/observers),
    /// and only then publish: every completion minted before this moment fails the engine's
    /// ownership gate and is inert, while loadFile() rebuilds everything, so the overlay's Retry
    /// still works. Native engine only (see TerminalLoadFailurePolicy: libmpv's stop() destroys the
    /// core, which would turn Retry into a dead end, and libmpv parks no deferred display work).
    /// Idempotent: stop() and a repeated publication are both safe, so every terminal branch and a
    /// later dismissal can each call this. Same shape as the debrid-crash straddle root cause
    /// (stop-before-dismiss): engine down first, then the surface state change.
    private func presentTerminalLoadFailure() {
        TerminalLoadFailurePolicy.presentTerminal(
            retire: {
                guard TerminalLoadFailurePolicy.shouldRetireBeforePublish(
                    engineIsNative: coordinator.player is AVPlayerEngineController) else { return }
                srcProbe("terminal failure -> retiring AVPlayer engine BEFORE the overlay (option A)")
                coordinator.player?.stop()
            },
            publish: { withAnimation { loadFailed = true } }
        )
    }

    /// Fail (or hop) if playback never starts: covers hard hangs that don't even emit an error.
    private func startLoadTimeout() {
        loadTimeout?.cancel()
        startRecoveryDeadline()   // arms the overall pre-start cap once; later hops leave it running
        #if os(iOS) || os(macOS)
        startAVStartWatchdog()    // AVPlayer-only fast, silent, in-place demote to libmpv when it mounts but never frames
        #endif
        lastBufferedAtWatchdog = bufferedTime   // snapshot the buffered edge so the fire path can tell if bytes moved
        srcProbe("start-watchdog ARMED (30s) bufferedEdge=\(String(format: "%.1f", bufferedTime))")
        loadTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            // A cancelled watchdog (superseded by a hop / reload / new load) must NOT fire: Task.sleep throws
            // CancellationError on cancel and `try?` swallows it, so without this guard the cancelled timer
            // runs handleStartTimeout immediately, and each hop arms+cancels the next, cascading through every
            // source in milliseconds ("Tried N sources") over a source that was actually still loading.
            guard !Task.isCancelled, !hasStartedPlaying, !loadFailed else { return }
            srcProbe("start-watchdog FIRED (30s elapsed, no first frame) -> handleStartTimeout")
            handleStartTimeout()
        }
    }

    /// The 30s start-watchdog fired without playback beginning. Decide between EXTEND (bytes still
    /// arriving on a slow big source), WARM (a cold torrent), HONOR (retry an explicit pick in place), or
    /// HOP (the auto path), preserving every existing recovery path:
    ///  - A cold torrent still warms up (mpv never errors a peerless torrent).
    ///  - A big 4K first-buffer that is genuinely progressing (the demuxer-cache edge advanced since the
    ///    watchdog armed) EXTENDS instead of hopping, bounded by `maxBufferGraceExtensions` and the
    ///    overall recovery deadline, so a 4K remux on slow debrid isn't declared dead mid-fill.
    ///  - An EXPLICIT pick (a user-chosen source/quality) is retried IN PLACE, never silently swapped for
    ///    a different lower-quality source; once its grace is spent it surfaces a clear "not ready" error
    ///    with the source list, rather than dropping to a 480p different source.
    ///  - Only the AUTO path (Watch Now / resume) hops to another source.
    private func handleStartTimeout() {
        srcProbe("handleStartTimeout ENTER bufferGraceUsed=\(bufferGraceUsed)/\(maxBufferGraceExtensions) bufferedNow=\(String(format: "%.1f", bufferedTime)) bufferedAtArm=\(String(format: "%.1f", lastBufferedAtWatchdog))")
        // THE HANG: a cold torrent never emits an end-file error (mpv reconnect=1 keeps retrying the
        // peerless loopback URL), so it would buffer forever with no recovery. Warm it up instead of
        // hopping/failing.
        if curIsTorrent { srcProbe("handleStartTimeout -> torrent warm up"); warmUpTorrent(); return }
        // Bytes still arriving on a slow (typically 4K remux) first-buffer: extend rather than give up.
        if bufferGraceUsed < maxBufferGraceExtensions, bufferedTime > lastBufferedAtWatchdog + 0.25 {
            bufferGraceUsed += 1
            srcProbe("handleStartTimeout -> EXTEND (bytes still arriving) grace \(bufferGraceUsed)/\(maxBufferGraceExtensions)")
            reconnectMsg = "Buffering… this source is large"
            srcProbe("OVERLAY SET (spinner): reconnect='Buffering… this source is large' (large-source grace, NOT error)")
            withAnimation { reconnecting = true }
            buffering = true
            lastBufferedAtWatchdog = bufferedTime
            loadTimeout?.cancel()
            loadTimeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, !hasStartedPlaying, !loadFailed else { return }   // cancelled re-arm must not fire (see start-watchdog)
                handleStartTimeout()
            }
            return
        }
        // Honor an explicit user pick: retry the SAME source in place (a longer grace) instead of hopping
        // to a different, possibly lower-quality, source. Once the grace is spent, surface a clear error
        // that points at the source list, not a silent quality drop.
        if currentPickWasExplicit {
            if bufferGraceUsed < maxBufferGraceExtensions {
                bufferGraceUsed += 1
                srcProbe("handleStartTimeout -> explicit pick, retry SAME source in place grace \(bufferGraceUsed)/\(maxBufferGraceExtensions)")
                reconnectMsg = "Still starting this source…"
                srcProbe("OVERLAY SET (spinner): reconnect='Still starting this source…' (explicit-pick in-place retry, NOT error)")
                withAnimation { reconnecting = true }
                retryLoad(resetAutoRetries: false)
                return
            }
            reconnecting = false
            if loadErrorMsg.isEmpty { loadErrorMsg = "This source isn't ready (still downloading on your debrid, or slow). Choose another source." }
            srcProbe("OVERLAY SET: explicit pick timed out, grace spent -> loadFailed msg=\(loadErrorMsg)")
            presentTerminalLoadFailure()
            return
        }
        // Auto path (Watch Now / resume): hop to the next-best untried source (quality-drop-capped inside).
        srcProbe("handleStartTimeout -> auto path, trying hopToNextSource")
        if hopToNextSource(reason: "load timeout") { return }
        if loadErrorMsg.isEmpty { loadErrorMsg = "Timed out, the source never started." }
        srcProbe("OVERLAY SET: auto-path timeout, no untried source -> loadFailed msg=\(loadErrorMsg)")
        presentTerminalLoadFailure()
    }

    /// Warm a cold torrent before handing back to mpv: poll the embedded server's stats.json for peer
    /// connections + bytes downloaded. mpv with reconnect=1 buffers a peerless torrent forever instead of
    /// erroring, so without this a torrent movie hangs at "loading" with no recovery. Bounded to 2 rounds
    /// × 90s and capped by the overall recovery deadline, so a genuinely dead torrent still surfaces the
    /// error overlay. Ported from tvOS `warmUpTorrent`.
    private func warmUpTorrent() {
        guard torrentWarmupsUsed < 2, let u = curURL, u.pathComponents.count >= 2 else {
            srcProbe("warmUpTorrent EXHAUSTED (used=\(torrentWarmupsUsed)) -> hop or error")
            reconnecting = false; torrentStatus = nil
            if hopToNextSource(reason: "torrent warm-up exhausted") { return }
            if loadErrorMsg.isEmpty { loadErrorMsg = "The torrent never started sending data. Try another source." }
            srcProbe("OVERLAY SET: torrent warm-up exhausted, no untried source -> loadFailed msg=\(loadErrorMsg)")
            presentTerminalLoadFailure()
            return
        }
        torrentWarmupsUsed += 1
        let hash = u.pathComponents[1]
        buffering = true
        reconnectMsg = "Starting torrent…"
        srcProbe("OVERLAY SET (spinner): torrent warm-up round \(torrentWarmupsUsed) hash=\(hash) (NOT error)")
        withAnimation { reconnecting = true }
        torrentStatus = "Starting torrent…"
        NSLog("%@", "[Player] torrent warm-up round \(torrentWarmupsUsed) for \(hash)")
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
                srcProbe("warmUpTorrent WARM (>3MB down) -> retryLoad")
                retryLoad(resetAutoRetries: true)   // hand the now-warm torrent back to mpv
            } else {
                loadErrorMsg = "The torrent never started sending data. Try another source."
                reconnecting = false
                srcProbe("OVERLAY SET: torrent warm-up round finished cold (no data) -> loadFailed msg=\(loadErrorMsg)")
                presentTerminalLoadFailure()
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

    /// Tell the embedded server to destroy a torrent engine (GET /{hash}/remove). Each engine holds
    /// peers, sockets, and a growing disk/RAM cache; leaving them running when we switch source, auto-fail
    /// over, advance an episode, or close the player piled them up until the server's RSS ballooned and it
    /// stopped answering (the 0.2.48 "torrents stopped playing, server went offline" regression). tvOS
    /// TVPlayerView already did this; the iOS/iPad/Mac player did not, so engines leaked here across every
    /// switch and exit. Fire-and-forget on URLSession's own queue (never blocks the main thread), guards a
    /// 40-hex hash, and is a no-op for direct/debrid playback (no hash). Symmetric with the create/warm-up.
    private func closeTorrent(hash: String) {
        let h = hash.lowercased()
        guard h.count == 40, let url = URL(string: "\(StremioServer.base)/\(h)/remove") else { return }
        DiagnosticsLog.log("torrent", "remove engine \(h.prefix(8))")
        URLSession.shared.dataTask(with: url).resume()
    }

    /// The 40-hex info-hash of the currently playing torrent, or nil for a direct/debrid stream. Decided by
    /// the URL SHAPE ({server}/{40-hex-hash}/{idx}) against the ACTIVE streaming server's host:port, NOT by
    /// the launch `recordIsTorrent` / `curIsTorrent` flag, which goes stale across engine-resolved episode
    /// switches. curURL is built from StremioServer.base, so comparing host+port against base is exact and
    /// also covers a custom remote server, not just a hardcoded :11470. Mirrors TVPlayerView.currentTorrentHash.
    private var currentTorrentHash: String? {
        guard let u = curURL, let serverBase = URL(string: StremioServer.base),
              u.host == serverBase.host, u.port == serverBase.port,
              u.pathComponents.count >= 2 else { return nil }
        let hash = u.pathComponents[1]
        return (hash.count == 40 && hash.allSatisfy(\.isHexDigit)) ? hash : nil
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
            srcProbe("OVERLAY SET: overall recovery deadline (\(Int(maxRecoverySeconds))s) hit -> loadFailed msg=\(loadErrorMsg)")
            presentTerminalLoadFailure()
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
        srcProbe("recoverFromStall ENTER (mid-play freeze) stallRecoveries=\(stallRecoveries)/3 at pos=\(String(format: "%.1f", currentTime))s")
        guard stallRecoveries < 3 else {
            // Repeated stalls on one source: hop to another at the current position, falling back to
            // the error overlay once candidates run out.
            srcProbe("recoverFromStall -> stall budget exhausted, trying hopToNextSource")
            if hopToNextSource(reason: "stall budget exhausted") { return }
            loadErrorMsg = "Playback kept stalling on this source."
            srcProbe("OVERLAY SET: stall budget exhausted, no untried source -> loadFailed msg=\(loadErrorMsg)")
            presentTerminalLoadFailure()
            return
        }
        stallRecoveries += 1
        reconnectMsg = "Recovering…"
        srcProbe("OVERLAY SET (spinner): recoverFromStall reconnect='Recovering…' reload-in-place (NOT error)")
        withAnimation { reconnecting = true }
        // Resume where it froze: reload in place, the seek lands once duration is known again.
        let resume = currentTime
        appliedSize = false; hasStartedPlaying = false; isSeekable = true; buffering = true
        loadIntoPlayer(curURL ?? url, headers: curHeaders, live: isLive, resumeOrigin: resume)
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

    /// Demote the active AVFoundation engine to libmpv IN PLACE, re-loading the SAME stream URL. Flipping
    /// `avEngineFailed` re-renders `playerSurface` to the mpv surface on the SAME view, which re-loads
    /// `initialPlayback` from scratch. This does NOT touch `sourceHops` and never calls `hopToNextSource`, so
    /// it is not a failover attempt and the "trying another source" overlay never appears; libmpv just
    /// tone-maps a DV link to HDR10 (an acceptable fallback). `silent` suppresses the DV notice: the no-frame
    /// start watchdog demotes silently, while a genuine mid-play decode failure keeps the informative notice.
    private func demoteAVPlayerToMPV(silent: Bool) {
        srcProbe("demoteAVPlayerToMPV (AVPlayer -> libmpv, SAME url, silent=\(silent), NOT a hop)")
        resumeRetryGeneration &+= 1
        let reissueEpisodeGeneration = episodeSwitchGeneration
        let reissueMediaGeneration = resumeRetryGeneration
        let reissuePendingVideoID = pendingAdvance?.meta.videoId
        avStartWatchdog?.cancel(); avStartWatchdog = nil
        // Fully tear down the outgoing AVFoundation engine BEFORE flipping `avEngineFailed` mounts the libmpv
        // surface, so the old AVPlayer decoder cannot straddle into the mpv mount (the player-teardown-straddle
        // that has jetsam-hung the device). Mirrors the tvOS twin's order. stop() is idempotent with the
        // SwiftUI dismantle path.
        coordinator.player?.stop()
        avEngineFailed = true
        avDemotedAt = Date()
        // Demoting off a forward-only remux that started at 0 (its resume seek was dropped): the real position
        // lives in suppressedResumeFloor, so carry the higher of the live position and the floor into the mpv
        // re-load (mpv CAN seek). KEEP the floor across the demote: mpv's resume restore is DEFERRED (nudgeResume
        // fires after a short sleep, plus a ~400ms re-point reload when the source had switched), and in that gap
        // currentTime ticks near 0 on the fresh mount, so an exit inside the window would otherwise flush a low
        // position over the account resume. reportProgress self-clears the floor once the restored playhead
        // passes it. Pre-start / non-remux demotes are unaffected (floor is nil, currentTime wins).
        // Pre-start demote (a remux mount that never produced a frame): currentTime is ~0, so fall back to the
        // launch offset like tvOS (TVPlayerView demoteAVPlayerToMPV) instead of 0, so mpv reloads at the user's
        // real position rather than restarting a half-watched title. Once started, carry the higher of the live
        // position and the floor. The floor is derived from resumeSeconds on the launch/switch remux lanes, so
        // max() keeps whichever is authoritative.
        let resume = hasStartedPlaying
            ? max(currentTime, suppressedResumeFloor ?? 0)
            : max(resumeSeconds, suppressedResumeFloor ?? 0)
        if !silent, StreamRanking.isDolbyVision(recordQualityText ?? "") {
            showEngineNotice("Dolby Vision isn't supported for this file. Playing HDR10 instead.")
        }
        // Treat the mpv mount as a fresh load: full timeout window, no stale error/overlay state.
        appliedSize = false; appliedVolume = false; hasStartedPlaying = false; isSeekable = true
        buffering = true; loadFailed = false; loadErrorMsg = ""
        subtitleLoadingURL = nil   // self-heal: an in-flight subtitle load died with the AVPlayer engine; a stranded latch would gate every later pick
        srcProbeLoadStart = Date()   // [src-probe] fresh mpv mount: re-anchor the elapsed clock
        startLoadTimeout()
        if resume > 5 { nudgeResume(to: resume) }
        // The fresh mpv mount auto-loads the LAUNCH url; if this session had switched sources, re-point it at
        // the ACTIVE one once the controller exists.
        if let cu = curURL, cu != url || pendingAdvance?.issued == true {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard avEngineFailed, !Task.isCancelled, curURL == cu,
                      reissueEpisodeGeneration == episodeSwitchGeneration,
                      reissueMediaGeneration == resumeRetryGeneration,
                      reissuePendingVideoID == pendingAdvance?.meta.videoId else { return }
                loadIntoPlayer(cu, headers: curHeaders, live: isLive)
            }
        }
    }

    /// User-invoked mid-title engine swap (P3, #76). Generalizes `demoteAVPlayerToMPV` into a bidirectional,
    /// user-driven switch: tears the live engine down synchronously (straddle invariant) BEFORE flipping the
    /// manual override so `playerSurface` re-renders the other engine on the SAME view, carries the live
    /// position, and re-arms the one-shot latches so tracks / size / resume re-apply on the fresh mount. Speed
    /// and subtitle sync are re-applied once the new engine's controller mounts. Track choices re-derive from
    /// `TrackPreferences` via the automatic trackList -> `TrackSelector` flow (engine id spaces differ by
    /// design; matching is by lang/title). No-op when already on the requested engine.
    private func switchPlayerEngine(toAVPlayer: Bool) {
        guard toAVPlayer != isAVPlayerActive else { close(); return }
        // Re-validate against the ACTIVE source before committing: the picker row is gated by
        // canUseAVPlayerEngine, but stand down defensively if the active stream can't play on AVPlayer (a
        // non-DV MKV, or a mid-session switch to a torrent) so we never feed a dead URL into AVPlayer.
        if toAVPlayer, !canUseAVPlayerEngine {
            showEngineNotice("This source can only play on the built-in (libmpv) engine.")
            close(); return
        }
        srcProbe("user engine switch -> \(toAVPlayer ? "AVPlayer" : "libmpv") (mid-title, carry position)")
        resumeRetryGeneration &+= 1
        let reissueEpisodeGeneration = episodeSwitchGeneration
        let reissueMediaGeneration = resumeRetryGeneration
        let reissuePendingVideoID = pendingAdvance?.meta.videoId
        avStartWatchdog?.cancel(); avStartWatchdog = nil
        let resume = hasStartedPlaying ? currentTime : (resumeSeconds > 5 ? resumeSeconds : 0)
        // Whether the AVPlayer mount we're switching INTO will be the forward-only DV remux: it can't honor a
        // resume seek, so it starts at 0. Capture the real position as a save floor (mirrors tvOS maybeResume)
        // so the periodic / exit saves don't regress the account resume below where the viewer actually was.
        let targetIsRemux = toAVPlayer && (activeAVPlayerWouldRemux || activeAVPlayerWouldPlainRemux)
        // Preserve an explicit in-session subtitle pick across the switch (mandated check 8): capture it NOW,
        // before the reset below, so the new engine re-applies it instead of the preference-derived auto pick.
        pendingSubtitleReapply = userPickedSubtitle ? captureSubtitleChoice() : nil
        coordinator.player?.stop()          // straddle invariant: old engine fully down before the surface swap
        avSurfaceResumeOrigin = resume
        manualEngineAVPlayer = toAVPlayer
        avEngineFailed = false              // a manual pick gets a fresh chance even after a prior demote
        avDemotedAt = Date()               // grace window swallows a stale event from the outgoing engine
        // Treat the new mount as a fresh load (mirrors demoteAVPlayerToMPV). The new engine loads no external
        // subtitles yet, so drop the added-set tracking so the picker is honest and reapply can re-add cleanly.
        appliedSize = false; appliedVolume = false; appliedAutoTracks = false
        addedSubURLs = []; addedPooledIDs = []
        subtitleLoadingURL = nil   // self-heal: an in-flight subtitle load died with the old engine; a stranded latch would gate every later pick
        hasStartedPlaying = false; isSeekable = true
        buffering = true; loadFailed = false; loadErrorMsg = ""
        srcProbeLoadStart = Date()
        startLoadTimeout()
        if toAVPlayer { startAVStartWatchdog() }   // arm the AV no-frame demote on the new mount
        suppressedResumeFloor = nil
        // A remux target consumes `avSurfaceResumeOrigin` before its initial load. Native AVPlayer and libmpv
        // still need their ordinary post-mount seek.
        if resume > 5, !targetIsRemux { nudgeResume(to: resume) }
        // The fresh mount auto-loads the LAUNCH url; re-point at the ACTIVE source if this session switched.
        if let cu = curURL, cu != url || pendingAdvance?.issued == true {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard manualEngineAVPlayer == toAVPlayer, !Task.isCancelled, curURL == cu,
                      reissueEpisodeGeneration == episodeSwitchGeneration,
                      reissueMediaGeneration == resumeRetryGeneration,
                      reissuePendingVideoID == pendingAdvance?.meta.videoId else { return }
                loadIntoPlayer(cu, headers: curHeaders, live: isLive, resumeOrigin: resume)
            }
        }
        // Re-apply speed + subtitle sync once the new engine's controller is mounted (next render).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard manualEngineAVPlayer == toAVPlayer, !Task.isCancelled,
                  reissueEpisodeGeneration == episodeSwitchGeneration,
                  reissueMediaGeneration == resumeRetryGeneration,
                  reissuePendingVideoID == pendingAdvance?.meta.videoId else { return }
            if abs(speed - 1.0) > 0.01 { coordinator.player?.setSpeed(speed) }
            if subDelay != 0, coordinator.player?.subtitleDelayAvailable == true {
                coordinator.player?.setSubDelay(subDelay)
            }
        }
        close()   // dismiss the settings sheet so the video is visible during the swap
    }

    /// AVPlayer-only START watchdog (see `avStartWatchdogSeconds`). If AVFoundation is the active engine and no
    /// playable frame has arrived after the deadline, demote SILENTLY and IN PLACE to libmpv on the SAME URL,
    /// not a source hop. Cancelled the instant the first frame lands (the timePos handler) or the view goes
    /// away. NOT armed for libmpv (torrents warm up far longer, covered by loadTimeout / torrent warm-up).
    private func startAVStartWatchdog() {
        avStartWatchdog?.cancel()
        guard useAVPlayerEngine, !avEngineFailed else { return }
        // HLS belongs on AVPlayer (native ABR quality selector; libmpv has no equivalent), and a slow-network
        // HLS start can legitimately take more than the short watchdog to first-frame. Never demote HLS on the
        // no-frame timer: a genuinely-dead HLS link is still recovered by AVPlayer's own .failed path. The
        // watchdog exists only for the DV/remux mount-but-never-frames case, which is never HLS.
        if PlayerEngineRouter.isHLS(url) { return }
        avWatchdogArmedAt = Date()
        avStartWatchdog = Task { @MainActor in
            // Give the surface one render beat to mount the controller, then read the lane ONCE. Unlike tvOS
            // (which arms after a synchronous mount) this chrome can arm before the controller exists; a late
            // or absent controller reads remuxMounted=false and keeps today's fixed deadline, never a longer one.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !hasStartedPlaying, !loadFailed else { return }
            let remuxMounted = (coordinator.player as? AVPlayerEngineController)?.isRemuxMounted == true
            if !remuxMounted {
                try? await Task.sleep(for: .seconds(avStartWatchdogSeconds - 1))
                guard !Task.isCancelled, !hasStartedPlaying, !loadFailed else { return }
                guard coordinator.player is AVPlayerEngineController else { return }   // already on libmpv / torn down
                NSLog("%@", "[Player] AVPlayer start watchdog \(Int(avStartWatchdogSeconds))s reached with no playable frame, demoting to libmpv in place")
                srcProbe("AV start-watchdog FIRED (\(Int(avStartWatchdogSeconds))s, AVPlayer mounted but no frame) -> silent demote to libmpv")
                demoteAVPlayerToMPV(silent: true)
                return
            }
            // REMUX lane: PROGRESS-AWARE (the 0.3.13 field fix; tvOS twin in TVPlayerView). Poll the mount's
            // monotonic progress counters at ~1 Hz; demote only on a TRUE stall (nothing moved for
            // avRemuxStallDemoteSeconds) or at the hard ceiling. A slow-but-steadily-downloading 4K DV source
            // keeps its true-DV session instead of being demoted to HDR10 + PCM by a fixed wall.
            let armed = Date()
            var lastProgressAt = armed
            var last = (coordinator.player as? AVPlayerEngineController)?.remuxMountProgress
            var lastHoldLogAt = armed
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, !hasStartedPlaying, !loadFailed else { return }
                guard coordinator.player is AVPlayerEngineController else { return }   // already on libmpv / torn down
                let now = Date()
                if let cur = (coordinator.player as? AVPlayerEngineController)?.remuxMountProgress {
                    // Progress = any monotonic counter moved since the last poll. A FAILED mount never counts;
                    // its demote belongs to the HLS-404 -> .failed path, and if that somehow never fires the
                    // stall window below still bounds it.
                    let progressed = last.map { prev in
                        cur.producedBytes > prev.producedBytes
                            || cur.segmentCount > prev.segmentCount
                            || (cur.initPublished && !prev.initPublished)
                            || (cur.signalingPublished && !prev.signalingPublished)
                            || (cur.ended && !prev.ended)
                    } ?? true
                    if progressed, !cur.failed { lastProgressAt = now }
                    last = cur
                }
                let elapsed = now.timeIntervalSince(armed)
                let stalled = now.timeIntervalSince(lastProgressAt)
                let state = "produced=\(last?.producedBytes ?? -1)B segs=\(last?.segmentCount ?? -1) init=\(last?.initPublished ?? false) classify=\(last?.signalingPublished ?? false) failed=\(last?.failed ?? false)"
                if stalled >= avRemuxStallDemoteSeconds || elapsed >= avRemuxStartHardCeilingSeconds {
                    let why = stalled >= avRemuxStallDemoteSeconds
                        ? "TRUE STALL, no remux progress for \(Int(stalled))s"
                        : "hard ceiling \(Int(avRemuxStartHardCeilingSeconds))s with no playable frame"
                    NSLog("%@", "[Player] AVPlayer start watchdog demoting (remux mounted=true, \(why), elapsed=\(Int(elapsed))s, \(state)), demoting to libmpv in place")
                    srcProbe("AV start-watchdog FIRED (remux, \(why)) -> silent demote to libmpv")
                    DiagnosticsLog.log("dv", "remux demoted: \(why) -> libmpv HDR10")
                    demoteAVPlayerToMPV(silent: true)
                    return
                }
                // Past the old fixed wall and still holding: say WHY (progress is flowing), every ~10s.
                if elapsed >= avStartWatchdogSeconds, now.timeIntervalSince(lastHoldLogAt) >= 10 {
                    lastHoldLogAt = now
                    DiagnosticsLog.log("dv", "start watchdog holding: remux progressing (elapsed=\(Int(elapsed))s, quiet=\(Int(stalled))s, \(state))")
                }
            }
        }
    }
    #endif

    /// Restore a source-timeline position after an in-place load. A remux consumes that origin before mount,
    /// so this waits for its authoritative achieved keyframe and never seeks into forward-only bytes. Other
    /// engines keep the ordinary post-load absolute seek.
    @State private var pendingResume: Double?
    private func nudgeResume(to seconds: Double) {
        pendingResume = seconds
        Task { @MainActor in
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, pendingResume == seconds else { return }
                if let av = coordinator.player as? AVPlayerEngineController, av.isRemuxMounted {
                    guard let origin = av.achievedRemuxTimelineOriginSeconds else { continue }
                    switch RemuxResumePolicy.preStartSeek(target: seconds, origin: origin) {
                    case .satisfied:
                        suppressedResumeFloor = nil
                        currentTime = origin
                        lastReported = origin
                    case .unreachable:
                        suppressedResumeFloor = seconds
                        lastReported = seconds
                        showEngineNotice("That resume point is unavailable for this source. Playing from the earliest available position.")
                    }
                    pendingResume = nil
                    return
                }
                if duration > seconds + 5 {
                    coordinator.player?.seek(to: seconds)
                    currentTime = seconds
                }
                pendingResume = nil
                return
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
    ///
    /// QUALITY-DROP CAP (auto path): an automatic failover must never plunge more than one resolution
    /// tier below the best CACHED option that exists (the "picked/expected 4K, silently got 480p"
    /// report). We first try to pick from candidates within one tier of the best cached resolution; only
    /// if that leaves nothing untried do we fall back to the unfiltered ranking, so a title whose only
    /// remaining sources are low-res still plays the best it has rather than dead-ending.
    private func nextUntriedStream() -> CoreStream? {
        let remaining = currentSourceGroups.map { group in
            CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: group.streams.filter { s in
                guard let u = playableURL(for: s) else { return false }
                return u != curURL && !exhaustedURLs.contains(u)
            })
        }
        let cachedRes = StreamRanking.bestCachedResolution(remaining)
        if cachedRes > 0 {
            let floorStep = StreamRanking.resolutionTierStep(cachedRes) - 1
            let capped = remaining.map { group in
                CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: group.streams.filter { s in
                    StreamRanking.resolutionTierStep(StreamRanking.resolutionRank(s)) >= floorStep
                })
            }
            if let hit = StreamRanking.best(capped, continuity: recordQualityText, binge: nil, pin: sourcePin) {
                return hit
            }
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
            srcProbe("OVERLAY SET: trailer load failed (\(reason)) -> loadFailed msg=\(loadErrorMsg)")
            presentTerminalLoadFailure()
            return true
        }
        // [src-probe] Count how many candidate rows are visible to failover at all. On CW resume this is the
        // key number: if the fresh streams haven't loaded yet this is ~0, so the hop returns false and the
        // "Tried N sources, none worked" overlay appears even though a working cached source exists in a row
        // the user CAN pick manually a moment later (once currentSourceGroups has populated).
        let srcProbeCandidateCount = currentSourceGroups.reduce(0) {
            $0 + $1.streams.filter { playableURL(for: $0) != nil }.count
        }
        let srcProbeUntried = nextUntriedStream()
        guard sourceHops < maxSourceHops, let stream = srcProbeUntried,
              let newURL = playableURL(for: stream) else {
            srcProbe("hopToNextSource(\(reason)) FALSE: hops=\(sourceHops)/\(maxSourceHops) untriedFound=\(srcProbeUntried != nil ? "Y" : "N") totalPlayableCandidates=\(srcProbeCandidateCount) exhausted=\(exhaustedURLs.count) -> caller shows error overlay")
            return false
        }
        var tried = exhaustedURLs
        if let dead = curURL { tried.insert(dead) }
        let resume: Double = hasStartedPlaying ? currentTime : resumeSeconds
        srcProbe("hopToNextSource(\(reason)) HOP \(sourceHops)->\(sourceHops + 1) to host=\(newURL.host ?? "-") torrent=\(stream.isTorrent ? "Y" : "N") (candidates=\(srcProbeCandidateCount))")
        switchStream(to: stream, url: newURL, userInitiated: false)
        exhaustedURLs = tried
        sourceHops += 1
        if resume > 5 { nudgeResume(to: resume) }
        return true
    }

    private func resetRuntimeForIssuedSourceSwitch(userInitiated: Bool, explicitPick: Bool) {
        currentPickWasExplicit = explicitPick
        currentPlaybackIsResume = false
        bufferGraceUsed = 0; lastBufferedAtWatchdog = -1
        bufferedTime = 0
        if userInitiated {
            sourceHops = 0; exhaustedURLs = []
            recoveryDeadline?.cancel(); recoveryDeadline = nil
            stallRecoveries = 0
        }
        appliedSize = false; appliedAutoTracks = false; autoAddonSubTried = false
        userPickedSubtitle = false; addonSubsResolveTried = false; appliedVolume = false
        pendingSubtitleReapply = nil; suppressedResumeFloor = nil
        hasStartedPlaying = false; isSeekable = true; buffering = true; loadErrorMsg = ""
        autoRetryCount = 0; reconnecting = false; autoRetryTask?.cancel(); awaitedFreshSources = false
        torrentWarmupsUsed = 0; torrentStatus = nil
        subFingerprint = nil; subFingerprintKey = ""; pooledSubs = []
        subtitlePoolRequests.invalidate(); subtitleLoadingURL = nil
        addedPooledIDs = []; pooledSeededOffset = false; embeddedUploadDone = false
        langContributeDone = false
        reconnectMsg = "Switching source…"
    }

    /// Target-only latches move at the same transaction boundary as the accepted player command. While an
    /// episode is merely resolving, the outgoing episode remains physical and published, so resetting these
    /// earlier would let a rejected replacement duplicate its watched/auto-add/progress side effects or undo
    /// the viewer's Watch Credits choice.
    private func resetRuntimeForIssuedEpisode() {
        markedWatched = false
        autoAddedThisPlayback = false
        upNextSuppressed = false
        appliedInitialResume = true
        lastReported = -1
    }

    /// Switch the playing source in place: reload the picked stream's URL and resume at the current
    /// position, so a buffering or low-quality source can be swapped without leaving the player. A
    /// deliberate pick resets the failover budget; an automatic hop restores it in `hopToNextSource`.
    private func switchStream(to stream: CoreStream, url newURL: URL, userInitiated: Bool,
                              explicitPick: Bool = false, resumeOverride: Double? = nil,
                              debridRef: DebridPlaybackRef? = nil, engineAlreadyBound: Bool = false,
                              engineAddonBaseOverride: String? = nil) {
        guard newURL != curURL else {
            if let pending = pendingAdvance, !pending.issued,
               pending.meta.videoId != curMeta?.videoId {
                pendingAdvance = nil
                if restoreSupersededAdvance() { return }
                switchingEpisode = false; reconnecting = false
                loadErrorMsg = "That episode resolved to the current episode's file."
                presentTerminalLoadFailure()
                return
            }
            srcProbe("switchStream NO-OP (same url as current) userInitiated=\(userInitiated) explicit=\(explicitPick)")
            if userInitiated { close() }; return
        }
        resumeRetryGeneration &+= 1
        srcProbe("switchStream -> host=\(newURL.host ?? "-") userInitiated=\(userInitiated) explicitPick=\(explicitPick) torrent=\(stream.isTorrent ? "Y" : "N")")
        if userInitiated { close() }
        // Cleanly destroy the torrent engine we're leaving BEFORE loading the next source, so engines never
        // pile up on the embedded server (the 0.2.48 RSS-balloon regression). Every in-place transition funnels
        // through here: a source-row pick, an auto-failover hop, and an episode advance (goToEpisode calls
        // switchStream). Guarded on a DIFFERENT hash: a season-pack torrent shares one infoHash across every
        // episode (only the file index differs), and destroy-then-recreate would cold-start warm-up at 0 peers,
        // so a same-hash episode switch keeps the live engine. currentTorrentHash reads curURL, so it must be
        // evaluated before curURL is overwritten just below. No-op for a direct/debrid source (no hash).
        let oldHash = currentTorrentHash
        let resume = resumeOverride ?? (hasStartedPlaying ? currentTime : resumeSeconds)
        let priorPending = pendingAdvance
        // A source switch DURING a pending advance (the auto-hop lane when the incoming episode's first
        // source is dead) swaps WHICH FILE will first-frame, not which episode: keep the pending record
        // pointed at the live URL (and issued - this loads synchronously below) so the first-frame commit
        // and a foreground reconcile both act on the file actually in the player. Mirrors TVPlayerView.
        if pendingAdvance != nil {
            pendingAdvance?.url = newURL
            pendingAdvance?.debridRef = debridRef
            pendingAdvance?.issued = false
            pendingAdvance?.loadToken = nil
        }
        let nextHeaders = stream.requestHeaders
        let nextIsTorrent = debridRef == nil && stream.isTorrent
        let nextHint = StreamRanking.signature(stream)
        let nextLive = recordMeta.map { LiveTypes.contains($0.type) } == true && !nextIsTorrent
        let issuedToken = loadIntoPlayer(
            newURL, headers: nextHeaders, live: nextLive, contentHint: nextHint,
            resumeOrigin: resume
        )
        if pendingAdvance != nil {
            guard let issuedToken else {
                if let priorPending, priorPending.issued, !priorPending.terminal,
                   priorPending.loadToken == coordinator.player?.activeLoadToken {
                    pendingAdvance = priorPending
                    switchingEpisode = true; reconnecting = true
                    return
                }
                pendingAdvance = nil
                if restoreSupersededAdvance() { return }
                switchingEpisode = false
                loadErrorMsg = "The player could not issue this episode."
                presentTerminalLoadFailure()
                return
            }
            pendingAdvance?.loadToken = issuedToken
            pendingAdvance?.issued = true
        } else if issuedToken == nil {
            return
        }
        srcProbeLoadStart = Date()
        if priorPending?.issued == false {
            resetRuntimeForIssuedEpisode()
        }
        resetRuntimeForIssuedSourceSwitch(
            userInitiated: userInitiated, explicitPick: explicitPick
        )
        curURL = newURL
        curHeaders = nextHeaders
        curSourceStream = stream
        curIsTorrent = nextIsTorrent
        if pendingAdvance == nil { curDebridRef = debridRef }
        curHint = nextHint
        if let oldHash, oldHash != stream.infoHash?.lowercased() { closeTorrent(hash: oldHash) }
        if resumeOverride != nil { currentTime = 0; duration = 0 }
        scrubThumbnails.configure(localCacheKey: trickplayLocalCacheKey)
        lastLocalTrickplayCapture = -1000; localTrickplayCaptureInFlight = false
        configureCommunityTrickplayProvisional()
        if !engineAlreadyBound, isEpisodePlaybackContext,
           let meta = pendingAdvance?.meta ?? curMeta {
            let succeeded = core.loadEnginePlayer(
                for: stream, videoId: meta.videoId,
                base: engineAddonBaseOverride ?? engineAddonBase(for: stream),
                resolvedURL: debridRef?.url
            )
            enginePlayerVideoId = EpisodePlaybackIdentity.boundVideoID(
                requestedVideoID: meta.videoId, bindingSucceeded: succeeded
            )
        }
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
        // Floating Up Next card over the video tail on the shared VortX glass card preset (warm tint + top
        // highlight + card shadow), upgrading to Liquid Glass on OS 26. Non-interactive surface (its own
        // buttons stay pressable). Background only; countdown / auto-advance logic unchanged.
        .vortxGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                    fillAlpha: VortXGlass.cardFillAlpha, shadow: .card)
        .frame(maxWidth: 480)
        .padding(.horizontal, 24).padding(.bottom, 96)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
    private var canPrevEpisode: Bool { (episodeIndex ?? -1) > 0 }

    /// "Still watching?" modal: a dimming scrim plus a centered glass card with Stop / Continue. Raised
    /// after a long unattended stretch so a stream does not play all night; Continue resumes, Stop leaves.
    private var stillWatchingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 6) {
                Text("Still watching?")
                    .font(.title2.weight(.bold)).foregroundStyle(.white)
                Text("Playback paused after a long stretch with no activity.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button { stopStillWatching() } label: {
                        Text("Stop").font(.headline.weight(.semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop watching")
                    Button { continueStillWatching() } label: {
                        Label("Continue", systemImage: "play.fill").font(.headline.weight(.semibold))
                            .foregroundStyle(Theme.Palette.onAccent)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Theme.Palette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)   // Return / primary click = keep watching (macOS + HW keyboard)
                    .accessibilityLabel("Continue watching")
                }
                .padding(.top, 14)
            }
            .padding(24)
            .frame(maxWidth: 420)
            // Shared VortX warm-glass card (matches the Up Next / panel surfaces), upgrading to Liquid Glass on OS 26.
            .vortxGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                        fillAlpha: VortXGlass.cardFillAlpha, shadow: .card)
            .padding(.horizontal, 32)
        }
        .transition(.opacity)
        .zIndex(200)
        .accessibilityElement(children: .contain)
    }

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

    private func invalidateEpisodeWorkForExit() {
        persistenceBlockedForExit = hasUncommittedIssuedMedia
        playbackExited = true
        episodeSwitchGeneration &+= 1
        episodeResolveGeneration = nil
        resumeRetryGeneration &+= 1
        autoRetryTask?.cancel()
        pendingAdvance = nil
        supersededAdvance = nil
        switchingEpisode = false
        coordinator.player?.invalidateLoadToken()
    }

    private func currentEpisodeSourceSnapshot() -> EpisodeSourceSnapshot {
        let stream = currentStream
        return EpisodeSourceSnapshot(
            url: curURL, headers: curHeaders, stream: stream, debridRef: curDebridRef,
            hint: curHint, binge: curBingeState, isTorrent: curIsTorrent,
            engineVideoID: enginePlayerVideoId,
            engineAddonBase: stream.flatMap { engineAddonBase(for: $0) }
        )
    }

    private func restoreEpisodeSourceSnapshot(_ source: EpisodeSourceSnapshot,
                                              for pending: PendingEpisodeAdvance) {
        curURL = source.url
        curHeaders = source.headers
        curSourceStream = source.stream
        curDebridRef = source.debridRef
        curHint = source.hint
        curBingeState = source.binge
        curIsTorrent = source.isTorrent
        if let stream = source.stream {
            let succeeded = core.loadEnginePlayer(
                for: stream, videoId: pending.meta.videoId,
                base: source.engineAddonBase, resolvedURL: source.debridRef?.url
            )
            enginePlayerVideoId = EpisodePlaybackIdentity.boundVideoID(
                requestedVideoID: pending.meta.videoId, bindingSucceeded: succeeded
            )
        } else {
            enginePlayerVideoId = source.engineVideoID
        }
    }

    @discardableResult
    private func restoreSupersededAdvance() -> Bool {
        guard let superseded = supersededAdvance,
              !superseded.pending.terminal,
              PlayerLoadProvenanceState.accepts(
                callbackToken: superseded.pending.loadToken,
                activeToken: coordinator.player?.activeLoadToken
              ) else {
            supersededAdvance = nil
            return false
        }
        pendingAdvance = superseded.pending
        restoreEpisodeSourceSnapshot(superseded.source, for: superseded.pending)
        supersededAdvance = nil
        switchingEpisode = true
        reconnecting = true
        buffering = true
        return true
    }

    /// Switch to another episode in place: flush the current position, resolve the episode through the
    /// caller, then hot-swap the source and record against the new episode. No cover teardown - the
    /// chrome stays put and only the video reloads, the same feel as an in-player source switch.
    private func goToEpisode(_ videoId: String, autoAdvance: Bool = false) {
        guard let loadEpisode, !playbackExited else { return }
        switchingEpisode = true
        episodeSwitchGeneration &+= 1
        let episodeGeneration = episodeSwitchGeneration
        episodeResolveGeneration = episodeGeneration
        resumeRetryGeneration &+= 1
        let mediaGeneration = resumeRetryGeneration
        autoRetryTask?.cancel()
        if duration > 0, currentTime > 0 { reportProgress(currentTime) }   // flush the outgoing episode (floor-guarded)
        withAnimation { panel = nil }
        buffering = true; reconnecting = true; reconnectMsg = "Loading episode…"
        Task {
            let resolved = await loadEpisode(videoId)
            let resultIsCurrent = !Task.isCancelled && !playbackExited
                && episodeGeneration == episodeSwitchGeneration
                && mediaGeneration == resumeRetryGeneration
            guard resultIsCurrent else {
                // A source change can retire this result without starting a newer episode generation. Clear
                // only this generation's switch state; a newer episode request owns the state when generations
                // differ and must never be reset by this stale completion.
                if !playbackExited, episodeGeneration == episodeSwitchGeneration {
                    episodeResolveGeneration = nil
                    let healthyPending = pendingAdvance != nil && pendingAdvance?.terminal != true
                    switchingEpisode = healthyPending
                    reconnecting = healthyPending
                }
                return
            }
            guard let es = resolved else {
                episodeResolveGeneration = nil
                srcProbe("goToEpisode(\(videoId)) resolve returned nil (autoAdvance=\(autoAdvance ? "Y" : "N"))")
                if pendingAdvance?.terminal == true {
                    switchingEpisode = false
                    reconnecting = false; buffering = false
                    loadErrorMsg = "The pending episode ended before it could start."
                    presentTerminalLoadFailure()
                    return
                }
                if pendingAdvance != nil {
                    // A previously issued replacement is still the only media request in flight. Keep its
                    // exact pending identity and token until its own first frame commits, so a failed newer
                    // selection cannot strand E2 metadata beside an E3 URL.
                    switchingEpisode = true
                    reconnecting = true
                    return
                }
                switchingEpisode = false
                reconnecting = false; buffering = false
                if autoAdvance {
                    if let h = currentTorrentHash { closeTorrent(hash: h) }   // terminal exit: free the finished episode's engine (no-op for direct/debrid)
                    exitPlayerFullScreenIfNeeded()   // item 6: land back in windowed browse, not stranded fullscreen
                    invalidateEpisodeWorkForExit()
                    onClose()            // nothing playable on auto-advance: leave, don't hang on a spinner
                }
                else { loadErrorMsg = "Couldn't load that episode"; presentTerminalLoadFailure() }   // surface it: render loadErrorOverlay instead of silently continuing the old episode
                return
            }
            guard EpisodePlaybackIdentity.canIssueEpisodeSwitch(
                currentVideoID: curMeta?.videoId, targetVideoID: es.meta.videoId,
                currentURL: curURL, targetURL: es.url
            ) else {
                episodeResolveGeneration = nil
                if pendingAdvance?.terminal == true {
                    switchingEpisode = false
                    reconnecting = false; buffering = false
                    loadErrorMsg = "The pending episode ended before it could start."
                    presentTerminalLoadFailure()
                    return
                }
                if pendingAdvance != nil {
                    switchingEpisode = true
                    reconnecting = true
                    return
                }
                switchingEpisode = false
                reconnecting = false; buffering = false
                if es.meta.videoId != curMeta?.videoId {
                    loadErrorMsg = "That episode resolved to the current episode's file."
                    presentTerminalLoadFailure()
                }
                return
            }
            episodeResolveGeneration = nil
            // PUBLISH-AT-FIRST-FRAME (binge-desync fix): do NOT advance curMetaState/curTitleState here.
            // The old publish-on-resolve put the label, the episode-list checkmark, and every attribution
            // read (incl. recordLastStream) on the NEW episode before its file rendered a frame, so an
            // advance interrupted across a background boundary stranded them on media the player never
            // played. Park the identity; the incoming file's first frame (timePos handler) publishes it.
            if let pending = pendingAdvance, pending.issued {
                supersededAdvance = SupersededEpisodeAdvance(
                    pending: pending, source: currentEpisodeSourceSnapshot()
                )
            }
            pendingAdvance = PendingEpisodeAdvance(meta: es.meta, title: es.title,
                                                   binge: es.stream.behaviorHints?.bingeGroup,
                                                   generation: episodeGeneration,
                                                   debridRef: es.debridRef,
                                                   url: es.url, issued: false)
            // External sync starts only after the target's first frame commits its identity. The commit point
            // re-mints the session token, and the normal first-frame hook opens the new episode's scrobble.
            // The player command is the transaction boundary. Source state and engine attribution move only
            // after that command returns an exact active token inside switchStream.
            guard !playbackExited,
                  episodeGeneration == episodeSwitchGeneration,
                  mediaGeneration == resumeRetryGeneration,
                  pendingAdvance?.meta.videoId == es.meta.videoId else { return }
            switchStream(to: es.stream, url: es.url, userInitiated: true, resumeOverride: es.resume,
                         debridRef: es.debridRef, engineAlreadyBound: false,
                         engineAddonBaseOverride: es.engineAddonBase)
        }
    }

    /// FIRST-FRAME COMMIT of a binge advance (mirror of TVPlayerView.commitPendingAdvanceOnFirstFrame):
    /// the single point where a parked advance becomes the published current-episode identity. Publishes
    /// curMetaState/curTitleState/curBingeState together, so the label, the episode-list checkmark, the
    /// scrobble attribution, and the LastStreamStore record that follows in the same first-frame block all
    /// name the episode whose file just rendered. No-op outside an advance, so launch playback, source
    /// switches, and stall reloads are untouched.
    private func commitPendingAdvanceOnFirstFrame(loadToken: PlayerLoadToken) {
        guard let pending = pendingAdvance,
              PlayerLoadProvenanceState.canCommit(
                callbackToken: loadToken,
                activeToken: coordinator.player?.activeLoadToken,
                pendingToken: pending.loadToken
              ) else { return }
        pendingAdvance = nil
        supersededAdvance = nil
        committedLoadToken = loadToken
        uncommittedIdentityBlocked = false
        curMetaState = pending.meta
        curTitleState = pending.title
        curBingeState = pending.binge
        curDebridRef = pending.debridRef
        switchingEpisode = episodeResolveGeneration != nil
        playbackSessionID = UUID().uuidString
        // Code-level invariant (the extractable check; the app has no unit-test bundle): at commit, the
        // published episode IS the episode of the file that just first-framed - pending.url is kept in
        // step with curURL by goToEpisode and switchStream. Debug builds trap; user builds log.
        assert(pending.url == nil || pending.url == curURL,
               "binge-advance commit: published episode's media (\(pending.url?.lastPathComponent ?? "nil")) != loaded media (\(curURL?.lastPathComponent ?? "nil"))")
        if let u = pending.url, u != curURL {
            srcProbe("binge COMMIT MISMATCH: pending url \(u.lastPathComponent) != curURL \(curURL?.lastPathComponent ?? "nil")")
        }
        srcProbe("binge advance committed at first frame -> \(pending.meta.videoId) (label/selector/store now agree)")
    }

    /// FOREGROUND RECONCILE of an interrupted binge advance (mirror of TVPlayerView; UIKit platforms only,
    /// macOS never suspends the process). Outside an advance the published episode and the loaded file
    /// agree BY CONSTRUCTION (publish happens only at the incoming file's first frame), so the one state a
    /// background boundary can strand is an advance whose issued load never first-framed - the suspension
    /// killed the half-open connection. Re-issue the pending URL so the advance completes (and commits at
    /// ITS first frame) instead of hanging on a dead half-load behind the "Loading episode…" spinner.
    /// Presentation NEVER moves here - the display only advances at the first-frame commit.
    private func reconcileAdvanceOnForeground() {
        guard let pending = pendingAdvance, pending.issued, !hasStartedPlaying, !loadFailed,
              let u = pending.url else { return }
        srcProbe("foreground reconcile: re-issuing interrupted advance load for \(pending.meta.videoId)")
        buffering = true; reconnecting = true; reconnectMsg = "Loading episode…"
        guard let loadToken = loadIntoPlayer(u, headers: curHeaders, live: isLive) else { return }
        pendingAdvance?.loadToken = loadToken
        startLoadTimeout()
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
                    if duration > 0 { reportProgress(currentTime) }   // flush before advancing (floor-guarded)
                    goToNextEpisode()
                }
            } else if hasNext {
                iconButton("forward.end.fill", label: "Next episode") {
                    if duration > 0 { reportProgress(currentTime) }   // flush before advancing (floor-guarded)
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
            #if os(macOS)
            // Real in-app fullscreen toggle (item 5): drive the window into native macOS fullscreen so the
            // video goes truly edge-to-edge. Discoverable button here + the standard Ctrl-Cmd-F shortcut
            // (the hidden handler lives in mpvBody). The glyph flips to match the current window state.
            iconButton(macIsFullScreen ? "arrow.down.right.and.arrow.up.left"
                                       : "arrow.up.left.and.arrow.down.right", label: "Toggle fullscreen") {
                toggleMacFullScreen()
                scheduleHide()
            }
            #endif
            if !isLive {
                // Restart from 0:00 (tvOS parity #5): seek to the start and keep playing.
                iconButton("arrow.counterclockwise", label: "Restart") {
                    coordinator.player?.seek(to: 0)
                    currentTime = 0
                    // Direct onSeek (a restart-to-0 must bypass reportSeek's resume floor), so the
                    // account write rides along explicitly, keyed on the CURRENT episode like every
                    // other save (the hosts no longer write the account from the closures).
                    if duration > 0 {
                        if engineWritesOpen { onSeek(0, duration) }
                        lastReported = 0
                        saveAccountProgress(0)
                    }
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
            // Player Lock (touch surfaces): hide the chrome and ignore every tap until the small unlock
            // chip is used, so nothing can accidentally seek/pause. iOS-only affordance (a pointer/remote
            // can't pocket-tap); the state machinery compiles everywhere harmlessly.
            iconButton("lock.open", label: "Lock player controls") { engageLock() }
            AirPlayRoutePickerButton()   // start AirPlay from the player overlay (AVPlayer/HLS mirrors video, libmpv routes audio)
            #endif
            volumeControl   // D5: in-player volume slider + mute (libmpv `volume` / AVPlayer.volume), persisted
            iconButton("gearshape", label: "Player settings") { openPanel(.playerSettings) }   // decoder toggle + playback info (tvOS parity #22)
            iconButton("arrow.up.forward.app", label: "Play in another app") {       // hand off to Infuse / VLC / Share
                hideTask?.cancel()
                showExternalChooser = true
            }
        }
        // NO GlassEffectContainer here (the old .glassChromeCluster() wrap). Two reasons: (1) the discs are
        // now the tight material variant (vortxGlassDisc, never glassEffect), so there are no glass panes to
        // merge and the container only produced the "one continuous blurred slab" over-blur; (2) on OS 26 a
        // GlassEffectContainer renders interactive descendants with its own monochrome/vibrancy treatment,
        // which visually suppressed the volume Slider's ember accent tint (volumeControl lives in this bar).
        // Dropping the container restores the slider's .tint(Theme.Palette.accent) minimum track.
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
            // Skip back by the user's seek step (hidden for live - no fixed timeline to seek within).
            if !isLive {
                seekButton("gobackward.\(seekStep)", by: -seekStepSeconds)
            }
            Button { Haptics.tap(); coordinator.player?.togglePause(); scheduleHide() } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 50)).foregroundStyle(.white).shadow(radius: 8)
                    // Glass transport disc (mockup .big) on the TIGHT disc variant: shape-clipped material,
                    // never glassEffect (whose un-clipped ambient bloom drew a dark rounded halo around the
                    // disc over bright video). The inner 84pt disc is purely visual; the outer 100pt frame
                    // keeps the original tap target.
                    .frame(width: 84, height: 84)
                    .vortxGlassDisc()
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
    /// P2 (#76): the AUTHORITATIVE forward-only remux clamp lives at the engine chokepoint
    /// (AVPlayerEngineController.seek(to:) caps every seek at producedEdgeSeconds). This helper keeps the
    /// REPORTED position (onSeek / lastReported) in step with what the engine will actually honor, so the
    /// scrubber and saved progress don't claim a position past the produced edge. bufferedTime is the
    /// player-buffered edge, a conservative stand-in. Backward seeks / non-remux sessions pass through unchanged.
    private func remuxClampedTarget(_ target: Double) -> Double {
        guard (coordinator.player as? AVPlayerEngineController)?.isRemuxMounted == true,
              bufferedTime > currentTime, target > bufferedTime else { return target }
        return bufferedTime
    }

    private func seekBy(_ delta: Double) {
        let target = remuxClampedTarget(min(max(currentTime + delta, 0), max(duration - 1, 0)))
        coordinator.player?.seek(to: target)
        currentTime = target
        reportSeek(target)
        scheduleHide()
    }

    private func seekButton(_ icon: String, by delta: Double) -> some View {
        Button {
            seekBy(delta)
        } label: {
            Image(systemName: icon).font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white).shadow(radius: 4)
                // Glass transport disc (mockup .skip) on the TIGHT disc variant (shape-clipped material,
                // never glassEffect, no halo): inner 54pt visual disc, outer 60pt frame keeps the tap target.
                .frame(width: 54, height: 54)
                .vortxGlassDisc()
                .frame(width: 60, height: 60)
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
                                let target = remuxClampedTarget(scrubTarget)   // P2: cap forward scrub at the remux edge
                                currentTime = target
                                coordinator.player?.seek(to: target)
                                reportSeek(target)
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
                controlButton("speedometer", speed == 1.0 ? "Speed" : speedLabel(speed), active: speed != 1.0) { openPanel(.speed) }
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
                controlButton(sleepArmed ? "moon.zzz.fill" : "moon.zzz", sleepLabel, active: sleepArmed) { openPanel(.sleep) }
            }
            .padding(.horizontal, 8)
        }
        // Floating glass control bar (mockup .bottom): the scrubber + control pills ride on one rounded,
        // inset VortX glass panel that upgrades to Apple Liquid Glass on OS 26. Interior padding shapes the
        // panel; the outer inset floats it off the screen edges. Contents and wiring are unchanged.
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
        .vortxGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                    fillAlpha: VortXGlass.barFillAlpha, shadow: .bar)
        .padding(.horizontal, 16).padding(.bottom, 16)
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
        // Skip-editor bar container on the shared VortX glass pill (warm glass + pill shadow), upgrading to
        // Liquid Glass on OS 26. Its inner control pills keep their plain fills. Background only; editor logic unchanged.
        .vortxGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                    fillAlpha: VortXGlass.pillFillAlpha, shadow: .pill)
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
            // Live position indicator (in place of the scrubber) on the shared VortX glass pill, upgrading to
            // Liquid Glass on OS 26. Background only; the red dot stays a plain fill and playback state is unchanged.
            .vortxGlass(in: Capsule(), fillAlpha: VortXGlass.pillFillAlpha, shadow: .pill)
            Spacer()
            if currentTime > 0 {
                Text(timeString(currentTime)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func controlButton(_ icon: String, _ title: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                // #135: force a single line + allow the font to shrink instead of wrapping mid-word
                // ("Spee d", "Subti tles") on the narrower iOS control-row width; macOS/tvOS already
                // fit at full size so minimumScaleFactor is a no-op there.
                Text(title).font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            // Glass control pill (mockup .gp / .gp.on): a subtle chip that turns to the ember active variant
            // when its feature is engaged. Purely visual; the button's action is unchanged.
            .foregroundStyle(active ? Theme.Palette.accent : .white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(active ? 0 : 0.06)) }
            .vortxGlassActive(active, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(active ? Theme.Palette.accent.opacity(0.4) : .white.opacity(0.14), lineWidth: 1)
            }
        }
    }

    private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white).padding(11)
                // Floating top-bar disc (mockup .disc) on the TIGHT disc variant: a shape-clipped material,
                // never glassEffect, so the top-row buttons read as tight pucks (no dark halo, no over-blur).
                // Background only, hit shape unchanged.
                .vortxGlassDisc()
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
                        Image(systemName: "forward.fill").foregroundStyle(Theme.Palette.accent)
                        Text(segment.label).fontWeight(.semibold)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    // Glass ember skip pill (mockup .skippill): warm glass with an ember hairline and ember
                    // glyph, upgrading to Liquid Glass on OS 26. Ink label, ember icon.
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .vortxGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous),
                                fillAlpha: VortXGlass.barFillAlpha, shadow: .pill)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(Theme.Palette.accent.opacity(0.5), lineWidth: 1)
                    }
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
        // Subtitle add-ons come from the ENGINE's installed set (`core.addons`, the source of truth since VortX
        // went account-primary), unioned with the legacy Stremio collection (`account.addons`) as a fallback.
        // Reading account.addons alone showed NO add-on subtitles on a VortX-primary device (#148). Both load
        // async, so a playback that begins before they land would latch an EMPTY union for the whole session:
        // bail before touching the key so the panel-open retry (openPanel) fetches once the add-ons arrive.
        let sources = SubtitleAddonService.installedSources(engine: core.addons, account: account.addons)
        guard !sources.isEmpty else { return }
        // A hub / TMDB-catalog play carries a `tmdb:` library id that OpenSubtitles-class add-ons cannot answer,
        // so the raw id returns nothing and add-on subtitles never appear. Resolve tmdb -> tt ONCE (the same
        // persistent trickplay resolver), then re-enter with the tt id. A failed resolve falls through to the
        // raw-id path below exactly once (= today's behavior); addonSubsResolveTried keeps it loop-proof.
        if m.libraryId.lowercased().hasPrefix("tmdb:"),
           CommunityTrickplay.cachedIMDbID(for: m.libraryId) == nil,
           !addonSubsResolveTried {
            addonSubsResolveTried = true
            Task { @MainActor in
                _ = await CommunityTrickplay.resolveIMDbID(rawId: m.libraryId, seriesHint: m.season != nil)
                fetchAddonSubtitles()      // cache hit now, or raw-id fallback below exactly once
                fetchPooledSubtitles()     // re-key the pooled path under the resolved identity (see communityContentKey)
            }
            return
        }
        // Rewrite the tmdb: prefix of the query id to the resolved tt id when we have one; all other ids pass
        // through unchanged. "tmdb:456:1:2" -> "tt789:1:2".
        let effectiveVideoId: String = {
            guard m.libraryId.lowercased().hasPrefix("tmdb:"),
                  let tt = CommunityTrickplay.cachedIMDbID(for: m.libraryId),
                  m.videoId.hasPrefix(m.libraryId) else { return m.videoId }
            return tt + m.videoId.dropFirst(m.libraryId.count)
        }()
        let key = "\(m.type):\(effectiveVideoId)"
        guard key != addonSubsKey else { return }
        addonSubsKey = key
        addonSubs = []; addedSubURLs = []
        Task { @MainActor in
            let subs = await SubtitleAddonService.fetch(sources: sources, type: m.type, videoId: effectiveVideoId)
            guard addonSubsKey == key else { return }   // episode changed / re-keyed mid-fetch
            addonSubs = subs
            VXProbe.log("subs", "add-on subtitles listed count=\(subs.count)")
            if panel == .subtitles { panelRows = rows(for: .subtitles) }
            // The add-on list can land AFTER autoSelectTracks already ran (and left subs off because the
            // container had no chain match): re-evaluate the add-on fallback now that candidates exist.
            autoSelectAddonSubtitleIfNeeded()
        }
    }

    /// Auto-load an ADD-ON subtitle in the user's preferred language when the container itself has none.
    /// Mirror of TVPlayerView.autoSelectAddonSubtitleIfNeeded (this same UI runs on iOS and macOS): the
    /// embedded auto-select honors the preference chain for EMBEDDED tracks only, so a file with no track in
    /// the chain left subs off even when an installed subtitle add-on had the language. Fires at most once per
    /// load (latched), never overrides an already-selected track or a manual pick, respects the off /
    /// forced-only policies via TrackSelector.wantsExternalSubtitle, and fails SOFT: an auto-load failure just
    /// leaves subtitles off (no subtitleLoadFailed alert; the user did not ask for this download).
    private func autoSelectAddonSubtitleIfNeeded() {
        guard appliedAutoTracks, !autoAddonSubTried, !userPickedSubtitle,
              !(addonSubs.isEmpty && pooledSubs.isEmpty), subtitleLoadingURL == nil else { return }
        // Whether to pull an add-on sub is decided ENTIRELY by wantsExternalSubtitle (does any EMBEDDED track
        // match the preferred language chain). A stale or off-chain embedded selection must NOT short-circuit
        // this: a default English track being auto-selected while the viewer wants Turkish was latching the
        // add-on fetch off, missing the exact case the feature exists for. wantsExternalSubtitle already keeps
        // a real chain match (returns false) and respects the off / forced-only policies.
        let prefs = TrackPreferences.current
        guard TrackSelector.wantsExternalSubtitle(audio: audioTracks, subtitles: subtitleTracks, preferences: prefs) else {
            autoAddonSubTried = true
            return
        }
        // Tier 1 - installed subtitle add-ons. Walk the preference chain in priority order (same tolerant
        // language match the embedded selector uses, so "tur"/"tr-TR" still hit a "tr" preference).
        var pick: AddonSubtitle?
        for lang in prefs.subtitleLanguages {
            if let s = addonSubs.first(where: { TrackSelector.matches($0.lang, lang) }) { pick = s; break }
        }
        if let sub = pick {
            // Bind the engine BEFORE latching anything: in the engine demote/switch render gap
            // `coordinator.player` is nil, and an optional-chained call would swallow the completion,
            // stranding `subtitleLoadingURL` (every later pick then silently no-ops). Returning WITHOUT
            // latching `autoAddonSubTried` lets the next list/track completion retry on the live engine.
            guard let player = coordinator.player else { return }
            autoAddonSubTried = true
            subtitleLoadingURL = sub.url
            let subtitleLoadToken = player.activeLoadToken
            let subtitleVideoID = curMeta?.videoId
            player.addExternalSubtitle(url: sub.url, title: sub.addonName, lang: sub.lang) { ok in
                guard permitsSubtitlePublication(loadToken: subtitleLoadToken, videoID: subtitleVideoID) else { return }
                subtitleLoadingURL = nil
                // Same still-live-engine gate as the manual row: never record an add the live engine never saw.
                if ok, player === coordinator.player { addedSubURLs.insert(sub.url); hoardAddonSubtitle(sub) }
                if ok, player === coordinator.player, player.subtitleDelayAvailable, subDelay != 0 {
                    player.setSubDelay(subDelay)
                }
                refreshSoon()
                VXProbe.log("subs", "subs selected \(langName(sub.lang)) (add-on auto ok=\(ok ? "Y" : "N"))")
            }
            return
        }
        // Tier 2 - community-pooled subtitles, when no add-on had the chain language. Same tolerant match.
        var pooledPick: SubtitlePoolClient.PooledSubtitle?
        for lang in prefs.subtitleLanguages {
            if let s = pooledSubs.first(where: { TrackSelector.matches($0.lang, lang) }) { pooledPick = s; break }
        }
        if let sub = pooledPick {
            autoAddonSubTried = true
            VXProbe.log("subs", "subs selected \(langName(sub.lang)) (community auto)")
            selectPooledSubtitle(sub, auto: true)   // shared path: moat-gated download -> addExternalSubtitle -> addedPooledIDs; no alert on auto failure
            return
        }
        // No chain match. Latch only once BOTH async lists have arrived (each completion re-calls this), so a
        // pooled list landing after an empty add-on list still gets its turn.
        if !addonSubs.isEmpty && !pooledSubs.isEmpty { autoAddonSubTried = true }
    }

    // MARK: - Community subtitles (pool + sync + embedded upload)

    /// The pool `content_key` for what is playing: the imdb library id, plus season/episode for an episode.
    /// Live streams and titles with no imdb id return nil, no-oping the whole community-subtitle path.
    private var communityContentKey: String? {
        guard let m = curMeta, !effectivelyLive else { return nil }
        // A tmdb-backed play carries a `tmdb:` library id; feeding it straight into contentKey mints a bogus
        // `tt<tmdb-number>` via the bare-digit fallback. Route those through the persistent tmdb->tt resolver
        // cache instead: nil until it resolves (the whole community path no-ops rather than running under a wrong
        // identity), then the correct tt key. fetchAddonSubtitles' post-resolve fetchPooledSubtitles() re-keys it.
        if m.libraryId.lowercased().hasPrefix("tmdb:") {
            guard let tt = CommunityTrickplay.cachedIMDbID(for: m.libraryId) else { return nil }
            return SubtitleReleaseFingerprint.contentKey(imdbId: tt, season: m.season, episode: m.episode)
        }
        return SubtitleReleaseFingerprint.contentKey(imdbId: m.libraryId, season: m.season, episode: m.episode)
    }

    /// A subtitle request may finish after an episode load or same-episode reload replaced the player item.
    /// Require both its opaque load token and its content identity before publishing completion state.
    private func permitsSubtitlePublication(loadToken: PlayerLoadToken?, videoID: String?) -> Bool {
        guard let loadToken, coordinator.player?.activeLoadToken == loadToken else { return false }
        return curMeta?.videoId == videoID
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
        guard let requestID = subtitlePoolRequests.beginFetch(dedupeKey: key) else { return }
        Task { @MainActor in
            // SERVE moat gate: the pooled-subtitle READ is login-only on the worker (no VortX sign-in -> empty
            // list, the pool "shows nothing" bug). Thread the real account flag like SourceIndexClient does, so a
            // signed-in device stamps X-VX-Moat and the worker serves the pool.
            let signedIn = VortXSyncManager.shared.isSignedIn
            let publicationFence = SubtitlePoolClient.PublicationFence(contentKey: contentKey)
            let result = await SubtitlePoolClient.fetchPooled(contentKey: contentKey, lang: nil, fingerprint: fp,
                                                              isSignedIn: signedIn)
            let mayPublish = publicationFence.permits(
                currentContentKey: communityContentKey,
                isSignedIn: VortXSyncManager.shared.isSignedIn
            )
            guard mayPublish else {
                subtitlePoolRequests.finishFetch(requestID, published: false)
                return
            }
            guard subtitlePoolRequests.finishFetch(requestID, published: true) else { return }
            pooledSubs = result.subs
            VXProbe.log("subs", "community subtitles listed count=\(result.subs.count)")
            // The pooled list can land AFTER autoSelectTracks already ran (and after an empty add-on list): give
            // the language-chain auto-select its turn on these candidates too (guards above keep it safe).
            autoSelectAddonSubtitleIfNeeded()
            // P3 seed: remember the community-learned offset once. Apply it only when the active subtitle path
            // advertises live delay support (all libmpv subtitles, or AVPlayer's external cue overlay).
            if !pooledSeededOffset, subDelay == 0, let offsetMs = result.offsetMs, offsetMs != 0 {
                pooledSeededOffset = true
                let seconds = (Double(offsetMs) / 1000.0 * 10).rounded() / 10
                subDelay = seconds
                if coordinator.player?.subtitleDelayAvailable == true {
                    coordinator.player?.setSubDelay(seconds)
                }
                VXProbe.log("subs", "community sync seeded offset=\(String(format: "%+.1f", seconds))s")
            }
            if panel == .subtitles { panelRows = rows(for: .subtitles) }
        }
    }

    /// P2: load a pooled subtitle into the player, reusing the exact external-subtitle path (download to a
    /// local file, then mpv `sub-add`). Shows the shared Loading… row state. Fail-soft.
    /// `auto`: a background language-chain pick (autoSelectAddonSubtitleIfNeeded tier 2), which suppresses the
    /// subtitleLoadFailed alert on failure, matching the add-on auto path and tvOS (the user did not ask).
    private func selectPooledSubtitle(_ sub: SubtitlePoolClient.PooledSubtitle, auto: Bool = false) {
        guard subtitleLoadingURL == nil, communityContentKey == sub.contentKey,
              MoatConsent.contributeAndConsume,
              VortXSyncManager.shared.isSignedIn else { return }
        let marker = sub.url.absoluteString
        let downloadID = subtitlePoolRequests.beginDownload()
        subtitleLoadingURL = marker
        VXProbe.log("subs", "community subtitle selected lang=\(sub.lang)")
        if panel == .subtitles { panelRows = rows(for: .subtitles) }
        Task { @MainActor in
            // The pool-hosted sub TEXT is moat-gated too, so pass the same account flag the fetch used.
            let signedIn = VortXSyncManager.shared.isSignedIn
            let publicationFence = SubtitlePoolClient.PublicationFence(contentKey: sub.contentKey)
            let downloaded = await SubtitlePoolClient.download(sub, isSignedIn: signedIn)
            let mayPublishDownload = publicationFence.permits(
                currentContentKey: communityContentKey,
                isSignedIn: VortXSyncManager.shared.isSignedIn
            )
            guard mayPublishDownload else {
                if subtitlePoolRequests.finishDownload(downloadID) {
                    subtitleLoadingURL = nil
                    if panel == .subtitles { panelRows = rows(for: .subtitles) }
                }
                return
            }
            guard let localURL = downloaded else {
                if subtitlePoolRequests.finishDownload(downloadID) {
                    subtitleLoadingURL = nil
                    if !auto { subtitleLoadFailed = true }
                    if panel == .subtitles { panelRows = rows(for: .subtitles) }
                }
                return
            }
            guard let externalID = subtitlePoolRequests.beginExternal(after: downloadID) else { return }
            let title = pooledLabel(sub)
            // The engine can vanish DURING the await above (demote/switch render gap): an optional-chained
            // call would swallow the completion and strand the Loading… latch, so unlatch, close the
            // request ledger entry, and revert.
            guard let player = coordinator.player else {
                if subtitlePoolRequests.finishExternal(externalID) {
                    subtitleLoadingURL = nil
                    if panel == .subtitles { panelRows = rows(for: .subtitles) }
                }
                return
            }
            let subtitleLoadToken = player.activeLoadToken
            let subtitleVideoID = curMeta?.videoId
            player.addExternalSubtitle(url: localURL.absoluteString, title: title, lang: sub.lang) { ok in
                let mayPublishExternal = publicationFence.permits(
                    currentContentKey: communityContentKey,
                    isSignedIn: VortXSyncManager.shared.isSignedIn
                )
                let loadStillCurrent = permitsSubtitlePublication(
                    loadToken: subtitleLoadToken, videoID: subtitleVideoID
                )
                guard mayPublishExternal, loadStillCurrent else {
                    if subtitlePoolRequests.finishExternal(externalID) {
                        subtitleLoadingURL = nil
                        if panel == .subtitles { panelRows = rows(for: .subtitles) }
                    }
                    return
                }
                guard subtitlePoolRequests.finishExternal(externalID) else { return }
                subtitleLoadingURL = nil
                VXProbe.log("subs", "community subtitle loaded lang=\(sub.lang) ok=\(ok ? "Y" : "N")")
                // Same still-live-engine gate as the add-on rows: never record an add the live engine never saw.
                if ok, player === coordinator.player { addedPooledIDs.insert(sub.id) } else if !ok, !auto { subtitleLoadFailed = true }
                if ok, player === coordinator.player, player.subtitleDelayAvailable, subDelay != 0 {
                    player.setSubDelay(subDelay)
                }
                if panel == .subtitles { panelRows = rows(for: .subtitles) }
            }
        }
    }

    /// The label for a pooled subtitle row: the language name plus a subtle community marker. NO add-on
    /// wording (per the framing rule) - pooled subs are just "subtitles" with a community provenance hint.
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
    /// LOCAL FILES (finished downloads) ONLY: extraction demuxes the whole container, so on a streamed play it
    /// re-downloaded the entire file next to the player - the Apple TV "remux builds up frame drops and
    /// distorted audio" regression (same code path here on iPhone/iPad/Mac), stacking a further never-cancelled
    /// full-file read on every restart and episode switch. The extractor hard-refuses remote inputs too;
    /// checking here skips spawning the task.
    private func uploadEmbeddedSubtitlesIfNeeded() {
        guard !embeddedUploadDone, let contentKey = communityContentKey else { return }
        embeddedUploadDone = true
        let inputStr = (curURL ?? url).absoluteString
        guard SubtitleEmbeddedExtractor.isLocalFileInput(inputStr) else { return }
        refreshSubFingerprint()
        let fp = subFingerprint
        Task.detached(priority: .utility) {
            let tracks = SubtitleEmbeddedExtractor.extractTextSubtitles(input: inputStr)
            for track in tracks where track.cueCount > 0 {
                await SubtitlePoolClient.upload(contentKey: contentKey, lang: track.lang, fingerprint: fp,
                                                origin: "embedded", format: track.format, text: track.srt)
            }
        }
    }

    /// Hoard a successfully-loaded ADD-ON subtitle into the community pool (origin "addon") so the next user
    /// gets it without hitting the add-on. Best-effort, off-main, gated + size-capped + fail-soft inside
    /// `SubtitlePoolClient.upload`; never blocks playback. The sub text is downloaded once from the add-on URL.
    private func hoardAddonSubtitle(_ sub: AddonSubtitle) {
        guard let contentKey = communityContentKey, let subURL = URL(string: sub.url) else { return }
        refreshSubFingerprint()
        let fp = subFingerprint
        let lang = sub.lang
        // Infer the format from the URL extension; default to srt (the pool + worker treat unknowns as srt).
        let ext = subURL.pathExtension.lowercased()
        let format = ["srt", "vtt", "ass"].contains(ext) ? ext : "srt"
        Task.detached(priority: .utility) {
            guard let data = try? await URLSession.shared.data(from: subURL).0,
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  !text.isEmpty else { return }
            await SubtitlePoolClient.upload(contentKey: contentKey, lang: lang, fingerprint: fp,
                                            origin: "addon", format: format, text: text)
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
                            // Panel close on the shared TIGHT glass disc, matching the transport discs
                            // (shape-clipped material, never glassEffect, no halo). Background only;
                            // close() action unchanged.
                            .foregroundStyle(.white.opacity(0.7)).padding(7)
                            .vortxGlassDisc()
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
            // Selection panel on the shared high-alpha VortX glass panel so it stays legible over bright,
            // moving video, upgrading to Liquid Glass on OS 26. Content is clipped to the same rounded shape
            // first so the inner selected-row fills round with it; the glass shape / stroke / shadow match.
            // Background only; panel rows and their apply() logic are unchanged.
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .vortxGlassPanel(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            // Dual-subtitle state (libmpv only). When a secondary subtitle is on, libmpv marks BOTH the
            // primary and secondary tracks `selected`, so the flag can no longer identify the primary on its
            // own: key the primary checkmarks off the engine's explicit `primarySubtitleID` instead. When no
            // secondary is set (the ordinary case, and always on the AVPlayer engine where `mpvEngine` is nil)
            // this stays nil and the rows fall back to the `selected` flag exactly as before.
            let mpvEngine = coordinator.player as? MPVMetalViewController
            let secondaryID = mpvEngine?.secondarySubtitleID ?? -1
            let dualActive = secondaryID >= 0
            let primaryID = mpvEngine?.primarySubtitleID ?? -1
            let primaryOff = dualActive ? (primaryID < 0) : subtitleTracks.allSatisfy { !$0.selected }
            let primarySel: ((MPVTrack) -> Bool)? = dualActive ? { $0.id == primaryID } : nil
            var rs: [Row] = [Row(label: String(localized: "Off"), selected: primaryOff) {
                userPickedSubtitle = true
                VXProbe.log("subs", "selected track off")
                coordinator.player?.setSubtitleTrack(-1)
            }]
            rs += groupedTrackRows(subtitleTracks, isSelected: primarySel) { id in
                userPickedSubtitle = true
                VXProbe.log("subs", "selected embedded track \(id)")
                coordinator.player?.setSubtitleTrack(id)
            }
            // External subtitles from the installed subtitle add-ons. These work on BOTH engines now: libmpv
            // sub-adds the downloaded file; AVPlayer parses it and renders the cues over the video itself. When
            // the opt-in "only preferred languages" toggle is on, non-preferred languages are hidden
            // (unknown-language subs always kept so the list never empties).
            let available = TrackSelector.keepingPreferredSubtitleLanguages(
                addonSubs.filter { !addedSubURLs.contains($0.url) }, language: { $0.lang })
            if !available.isEmpty {
                rs.append(Row(label: String(localized: "From add-ons"), isHeader: true))
                for sub in available.prefix(30) {
                    let loading = subtitleLoadingURL == sub.url
                    rs.append(Row(label: langName(sub.lang), detail: loading ? String(localized: "Loading…") : sub.addonName) {
                        // Non-blocking: the download + sub-add happen off the main thread with a timeout, so a
                        // slow or hanging subtitle endpoint can't freeze the player. The row shows Loading…
                        // until the track arrives (or an alert surfaces if it never does). A cached subtitle
                        // reuses its on-disk file and loads instantly (no network).
                        // Bind the engine BEFORE latching subtitleLoadingURL: `coordinator.player` is a weak
                        // reference that is nil in the engine demote/switch render gap, and an optional-chained
                        // call there would swallow the completion, stranding the latch so EVERY later subtitle
                        // pick is silently dead for the session (the "stuck on Loading…" report).
                        guard subtitleLoadingURL == nil, let player = coordinator.player else { return }
                        userPickedSubtitle = true
                        subtitleLoadingURL = sub.url
                        VXProbe.log("subs", "add-on subtitle selected lang=\(sub.lang) src=\(sub.addonName)")
                        if panel == .subtitles { panelRows = rows(for: .subtitles) }   // reflect Loading… in place
                        let subtitleLoadToken = player.activeLoadToken
                        let subtitleVideoID = curMeta?.videoId
                        player.addExternalSubtitle(url: sub.url, title: sub.addonName, lang: sub.lang) { ok in
                            guard permitsSubtitlePublication(
                                loadToken: subtitleLoadToken, videoID: subtitleVideoID
                            ) else { return }
                            subtitleLoadingURL = nil
                            VXProbe.log("subs", "add-on subtitle loaded lang=\(sub.lang) ok=\(ok ? "Y" : "N")")
                            // Record the add ONLY when it landed on the still-live engine: a demote/switch
                            // mid-download applies the sub to the dead engine, and recording it would drop
                            // the row from the list with nothing rendering.
                            if ok, player === coordinator.player { addedSubURLs.insert(sub.url); hoardAddonSubtitle(sub) }
                            else if !ok { subtitleLoadFailed = true }
                            if ok, player === coordinator.player, player.subtitleDelayAvailable, subDelay != 0 {
                                player.setSubDelay(subDelay)
                            }
                            if panel == .subtitles { panelRows = rows(for: .subtitles) }
                        }
                    })
                }
            }
            // Community-pooled subtitles (P2): other users' extracted subs for this title, in the SAME list.
            // No add-on wording - labeled by language with a subtle "Community" provenance. Work on BOTH engines
            // now (AVPlayer renders the downloaded file over the video, same as the add-on rows above). Same
            // opt-in preferred-language filter as the add-on rows above.
            let pooled = TrackSelector.keepingPreferredSubtitleLanguages(
                pooledSubs.filter { !addedPooledIDs.contains($0.id) }, language: { $0.lang })
            if !pooled.isEmpty {
                rs.append(Row(label: String(localized: "Community"), isHeader: true))
                for sub in pooled.prefix(30) {
                    let loading = subtitleLoadingURL == sub.url.absoluteString
                    rs.append(Row(label: pooledLabel(sub), detail: loading ? String(localized: "Loading…") : String(localized: "Community")) {
                        userPickedSubtitle = true
                        selectPooledSubtitle(sub)
                    })
                }
            }
            // Second subtitle (language-study dual tracks). libmpv renders two subtitle tracks at once, so this
            // drill-in only appears on that engine and only when there are at least two tracks to choose a
            // second from. On the AVPlayer engine there is no secondary-subtitle overlay, so the row is hidden
            // and playback degrades gracefully to the single primary subtitle (see .secondarySubtitles below).
            if mpvEngine != nil, subtitleTracks.count >= 2 {
                let secondLabel: String = {
                    if let t = subtitleTracks.first(where: { $0.id == secondaryID }) {
                        return String(localized: "Second subtitle") + " · " + langName(t.lang.isEmpty ? "und" : t.lang)
                    }
                    return String(localized: "Second subtitle")
                }()
                rs.append(Row(label: secondLabel, detail: "›") { openPanel(.secondarySubtitles) })
            }
            rs.append(Row(label: String(localized: "Subtitle Settings"), detail: "›") { openPanel(.subtitleSettings) })
            return rs
        case .secondarySubtitles:
            // Pick a SECOND subtitle track shown at the same time as the primary (top of frame vs. bottom), for
            // language study. libmpv-only: driven through the concrete engine because `secondary-sid` has no
            // AVPlayer equivalent. mpv refuses to show one track as both primary and secondary, so the current
            // primary is excluded from the options. The checkmark keys off the engine's tracked secondary id.
            let mpvEngine = coordinator.player as? MPVMetalViewController
            let secondaryID = mpvEngine?.secondarySubtitleID ?? -1
            let primaryID = mpvEngine?.primarySubtitleID ?? -1
            var rs: [Row] = [Row(label: String(localized: "Off"), selected: secondaryID < 0) {
                VXProbe.log("subs", "secondary subtitle off")
                mpvEngine?.setSecondarySubtitleTrack(-1)
            }]
            let secondaryOptions = subtitleTracks.filter { primaryID < 0 || $0.id != primaryID }
            rs += groupedTrackRows(secondaryOptions, isSelected: { $0.id == secondaryID }) { id in
                VXProbe.log("subs", "selected secondary subtitle track \(id)")
                mpvEngine?.setSecondarySubtitleTrack(id)
            }
            return rs
        case .subtitleSettings:
            let now = String(format: "%+.1fs", subDelay)
            var rs: [Row] = []
            if coordinator.player?.subtitleDelayAvailable == true {
                rs.append(Row(label: String(localized: "Sync"), isHeader: true))
                rs.append(Row(label: String(localized: "Earlier  −\(Self.subSyncStepLabel)"), detail: now) { adjustSubDelay(-Self.subSyncStep) })
                rs.append(Row(label: String(localized: "Later  +\(Self.subSyncStepLabel)"), detail: now) { adjustSubDelay(Self.subSyncStep) })
                rs.append(Row(label: String(localized: "Earlier  −\(Self.subSyncFineLabel)"), detail: now) { adjustSubDelay(-Self.subSyncFine) })
                rs.append(Row(label: String(localized: "Later  +\(Self.subSyncFineLabel)"), detail: now) { adjustSubDelay(Self.subSyncFine) })
                if subDelay != 0 { rs.append(Row(label: String(localized: "Reset sync")) { adjustSubDelay(-subDelay) }) }
            } else {
                rs.append(Row(label: "Sync unavailable · external subtitles only", isHeader: true))
            }
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
            // AVPlayer manages audio delay + output routing itself: setAudioDelay / setAudioOutputMode are
            // no-ops on that engine, so hide the inert controls rather than show rows that do nothing (#76).
            if isAVPlayerActive {
                return [Row(label: String(localized: "Audio sync isn't available on the Dolby Vision player"), isHeader: true)]
            }
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
            // current position via switchStream - the in-player quality picker. The full per-add-on list
            // stays under Sources.
            let opts = StreamRanking.resolutionOptions(currentSourceGroups)
            if opts.isEmpty { return [Row(label: "No alternate qualities", isHeader: true)] }
            return opts.map { opt in
                Row(label: opt.label, detail: StreamRanking.sizeText(opt.stream) ?? "",
                    selected: playableURL(for: opt.stream) == curURL) {
                    if let url = playableURL(for: opt.stream) {
                        switchStream(to: opt.stream, url: url, userInitiated: true, explicitPick: true)
                    }
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
                if let addon = currentSourceGroups.first(where: {
                    $0.streams.contains { playableURL(for: $0) == curURL }
                })?.addon {
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
            var rows: [Row] = []
            // Decoder toggle is libmpv-only: AVPlayer always decodes in hardware and setHardwareDecoding is a
            // no-op there, so hide the Hardware/Software rows when the AVFoundation engine is active (#76).
            if !isAVPlayerActive {
                let hw = coordinator.player?.hardwareDecoding ?? true
                rows.append(Row(label: "Decoder", isHeader: true))
                rows.append(Row(label: "Hardware", detail: "recommended", selected: hw) {
                    coordinator.player?.setHardwareDecoding(true)
                })
                rows.append(Row(label: "Software", detail: "rescues green / garbled frames", selected: !hw) {
                    coordinator.player?.setHardwareDecoding(false)
                })
            }
            rows.append(Row(label: "Playback Info", detail: "›") { openPanel(.info) })
            #if os(iOS) || os(macOS)
            // Player engine picker (P3, #76): only when AVPlayer is a real option for this stream (DV / HLS /
            // debrid; never torrents or a yt-direct sidecar pair). Flips libmpv <-> AVPlayer mid-title.
            if canUseAVPlayerEngine {
                rows.append(Row(label: "Player engine",
                                detail: isAVPlayerActive ? "AVPlayer  ›" : "VortX Player  ›") { openPanel(.engine) })
            }
            #endif
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
        case .engine:
            #if os(iOS) || os(macOS)
            // Player Engine picker (P3, #76): flip libmpv <-> AVPlayer mid-title. The AVPlayer row appears only
            // when it is a valid engine for this stream (canUseAVPlayerEngine).
            let onAV = isAVPlayerActive
            var rs: [Row] = [Row(label: "VortX Player", detail: "all formats, styled subtitles", selected: !onAV) {
                switchPlayerEngine(toAVPlayer: false)
            }]
            if canUseAVPlayerEngine {
                rs.append(Row(label: "AVPlayer", detail: "Dolby Vision, HLS", selected: onAV) {
                    switchPlayerEngine(toAVPlayer: true)
                })
            }
            return rs
            #else
            return []
            #endif
        }
    }

    /// Group tracks by language so multiple same-language tracks read clearly (an "English" header with
    /// two variants), instead of a flat list of identical rows. Mirrors tvOS `groupedTrackRows`.
    /// `isSelected`, when given, decides the checkmark from an EXPLICIT id instead of the track's own
    /// `selected` flag: the dual-subtitle pickers need this because once a secondary subtitle is on, libmpv
    /// marks BOTH the primary and secondary tracks `selected`, so the flag alone can no longer tell them
    /// apart. Passing nil keeps the original behaviour (audio + the single-track subtitle case), so
    /// single-subtitle rendering is unchanged.
    private func groupedTrackRows(_ tracks: [MPVTrack],
                                  isSelected: ((MPVTrack) -> Bool)? = nil,
                                  select: @escaping (Int) -> Void) -> [Row] {
        let sel: (MPVTrack) -> Bool = { isSelected?($0) ?? $0.selected }
        let groups = Dictionary(grouping: tracks) { $0.lang.isEmpty ? "und" : $0.lang.lowercased() }
        var rs: [Row] = []
        for code in groups.keys.sorted(by: { langName($0) < langName($1) }) {
            guard let ts = groups[code] else { continue }   // defensive; key comes from groups.keys so always present
            if ts.count == 1 {
                let t = ts[0]
                rs.append(Row(label: langName(code), detail: t.title, selected: sel(t)) { select(t.id) })
            } else {
                rs.append(Row(label: langName(code), isHeader: true))
                for (i, t) in ts.enumerated() {
                    rs.append(Row(label: t.title.isEmpty ? "Track \(i + 1)" : t.title, selected: sel(t)) { select(t.id) })
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
        let target = pendingAdvance?.meta ?? curMeta
        if let meta = target, isEpisodePlaybackContext {
            return core.streamGroups(forStreamId: meta.videoId)
        }
        if let id = target?.videoId {
            let scoped = core.streamGroups(forStreamId: id)
            if !scoped.isEmpty { return scoped }
        }
        return core.streamGroups()
    }

    private func playableURL(for stream: CoreStream) -> URL? {
        EpisodePlaybackIdentity.resolvedEpisodeMediaURL(
            isUsenet: stream.isUsenet, resolvedURL: nil,
            fallbackURL: stream.playableURL(isEpisode: isEpisodePlaybackContext)
        )
    }

    private func engineAddonBase(for stream: CoreStream) -> String? {
        guard let id = currentSourceGroups.first(where: { $0.streams.contains(stream) })?.id,
              URL(string: id)?.scheme != nil else { return nil }
        return id
    }

    /// True when more than one playable source is loaded for the current title / episode.
    private var hasAlternateSources: Bool {
        currentSourceGroups.reduce(0) { $0 + $1.streams.filter { playableURL(for: $0) != nil }.count } > 1
    }

    /// The stream currently on screen: the loaded source whose playable URL matches what mpv is playing.
    /// Drives the Playback Info panel's source-file rows (release / filename / size). Nil for a pasted
    /// direct link with no matching loaded source.
    private var currentStream: CoreStream? {
        curSourceStream ?? currentSourceGroups.flatMap(\.streams).first { playableURL(for: $0) == curURL }
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
                guard let link = playableURL(for: stream)?.absoluteString else { continue }
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
            let best = group.streams.filter { playableURL(for: $0) != nil }
                .map { (stream: $0, rank: StreamRanking.score($0)) }
                .sorted { $0.rank > $1.rank }
                .prefix(perAddon)
                .map(\.stream)
            guard !best.isEmpty, count < maxInPlayerSources else { continue }
            rs.append(Row(label: group.addon, isHeader: true))
            for stream in best {
                guard count < maxInPlayerSources, let sURL = playableURL(for: stream) else { continue }
                count += 1
                let info = StreamRanking.sourceDetail(stream)
                let name = String(sourceLabel(stream).prefix(40))
                rs.append(Row(label: "\(info.tags)   \(name)", detail: info.size ?? "",
                              selected: sURL == curURL) {
                    switchStream(to: stream, url: sURL, userInitiated: true, explicitPick: true)
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
        guard coordinator.player?.subtitleDelayAvailable == true else { return }
        subDelay = ((subDelay + delta) * 10).rounded() / 10
        coordinator.player?.setSubDelay(subDelay)
        VXProbe.log("subs", "synced delay=\(String(format: "%+.1f", subDelay))s")
        captureSubOffset()   // P3: pool the user-corrected offset (debounced, gated, fail-soft)
        SubtitleOffsetMemory.save(subDelay, forContentKey: communityContentKey)   // remember this title's manual offset (device-local, exact)
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
    /// the cover down - so a stuck load can never trap the user with a Task still spinning. Routed from
    /// the always-present pre-start close button, the error-overlay Back, and the top-bar chevron.
    @MainActor private func leavePlayback() {
        invalidateEpisodeWorkForExit()
        hideTask?.cancel(); loadTimeout?.cancel(); autoRetryTask?.cancel(); idleWatchTask?.cancel()
        stallWatchdog?.cancel(); recoveryDeadline?.cancel(); skipFetchTask?.cancel()
        #if os(iOS) || os(macOS)
        avStartWatchdog?.cancel()
        #endif
        if !effectivelyLive, duration > 0 {
            reportProgress(currentTime)
            // A manual close at/near the end must clear Continue Watching too, not only a natural EOF. The
            // engine keeps any item with time_offset > 0 in the rail, so a title watched to the credits then
            // closed by hand would linger there forever (the "CW never clears" report). Rewind it OUT of CW,
            // mirroring the EOF branch; 0.9 is the engine's own CREDITS threshold.
            if !persistenceBlockedForExit, let m = curMeta,
               currentTime / duration >= 0.9,
               EpisodePlaybackIdentity.canRewindWholeTitleAtTerminal(
                   usesSeriesLifecycle: m.usesSeriesLifecycle,
                   currentEpisodeIndex: episodeIndex,
                   episodeCount: episodes.count
               ) {
                core.finishedWatching(libraryId: m.libraryId)
            }
        }
        // External sync (Trakt/SIMKL): scrobble STOP on a genuine user exit. Additive + fail-soft + gated +
        // once-latched inside the coordinator; a no-op with empty creds. Near the end this records the watch
        // (deduped against the 90%/EOF record); mid-title it saves a resume/pause point (live scrobble only).
        if !persistenceBlockedForExit, !effectivelyLive, let m = curMeta {
            ScrobbleCoordinator.shared.playbackStopped(
                m, position: max(currentTime, suppressedResumeFloor ?? 0), duration: duration
            )
        }
        // Free the live torrent engine on a GENUINE user exit (this chokepoint, plus the terminal EOF
        // finishers), never in onDisappear: a SwiftUI teardown can fire onDisappear without the user leaving,
        // and tearing the engine down there would kill a live swarm mid-play. No-op for direct/debrid.
        if let hash = currentTorrentHash { closeTorrent(hash: hash) }
        // Wipe the configurable on-disk streaming cache for the title that just finished/closed, so a
        // completed movie or episode never leaves its buffer on disk (the owner's clear-on-finish
        // guardrail). No-op when the disk cache is off or empty. Genuine-exit path only; additive,
        // does not touch player teardown.
        DiskCacheSetting.clearCache()
        // If the player put the window into fullscreen, drop back to windowed browse on the way out (item 6).
        exitPlayerFullScreenIfNeeded()
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

    /// The window hosting the player. The Mac player is rendered at the app window's root via
    /// MacRootPlayerOverlay, so the key window (falling back to the main window) is that window.
    private var macPlayerWindow: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    /// Toggle native macOS fullscreen for the player window (item 5). Truly edge-to-edge: the window's
    /// content is already black + `.ignoresSafeArea()`, and MacRootPlayerOverlay paints a full-bleed black
    /// backdrop behind the player so no window background bleeds through at any edge in fullscreen.
    private func toggleMacFullScreen() {
        macPlayerWindow?.toggleFullScreen(nil)
    }

    /// Player-teardown vs fullscreen interplay (item 6). If the PLAYER put the window into native fullscreen
    /// (the app was NOT already fullscreen when the player opened), drop back out of fullscreen as the player
    /// closes, so the viewer lands in the normal windowed browse UI instead of a stranded fullscreen window
    /// whose only fullscreen affordance (the in-player toggle) just vanished with the player chrome. Because
    /// Esc / ⌘. is the `.cancelAction` close, this also makes Esc do the intuitive thing in a SINGLE press:
    /// it closes the player AND returns from fullscreen, so the close action and the native "Esc exits
    /// fullscreen" expectation stop fighting (chosen over a two-press Esc as the simplest correct behavior).
    /// If the app was ALREADY fullscreen when the player opened, that was the user's own browse choice, so we
    /// leave the window fullscreen. Called from the genuine-exit chokes (leavePlayback + the terminal EOF /
    /// auto-advance-out closes), never from onDisappear (a spurious SwiftUI teardown must not yank fullscreen
    /// mid-play, the same reason the torrent engine is not freed there). No-op on non-macOS.
    private func exitPlayerFullScreenIfNeeded() {
        guard !macWasFullScreenAtOpen,
              macPlayerWindow?.styleMask.contains(.fullScreen) == true else { return }
        macPlayerWindow?.toggleFullScreen(nil)
    }

    /// Keep `macIsFullScreen` in sync with the window so the toolbar glyph reflects the real state, whether
    /// fullscreen was toggled from our button, the shortcut, or the system green button / menu item.
    private func observeMacFullScreen() {
        // Re-entry guard mirroring installMacKeyMonitor: SwiftUI can fire onAppear twice with no intervening
        // onDisappear, and without this the second call would overwrite `macFullScreenObservers`, orphaning
        // the first observer pair for the process lifetime (they keep writing a defunct view's @State and
        // unobserveMacFullScreen can no longer remove them).
        guard macFullScreenObservers.isEmpty else { return }
        let window = macPlayerWindow
        let alreadyFullScreen = window?.styleMask.contains(.fullScreen) ?? false
        macIsFullScreen = alreadyFullScreen
        macWasFullScreenAtOpen = alreadyFullScreen
        let nc = NotificationCenter.default
        // Scope the observers to the player's own window via `object:` so an auxiliary window's fullscreen
        // transition (a Settings or About window) does not flip the player glyph. When the window is not yet
        // resolvable (object nil observes all windows), the closure's identity check is the fallback guard.
        let enter = nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { note in
            guard window == nil || (note.object as? NSWindow) === window else { return }
            macIsFullScreen = true
            // HDR/DV EDR survives fullscreen: AppKit native fullscreen re-hosts the content in a NEW
            // fullscreen window/backing, which drops the mpv Metal layer's EDR activation + colorspace
            // association, so PQ/HLG pixels presented as SDR (washed out) until a new file/gamma change.
            // These notifications fire AFTER the window/backing swap completes, the correct moment to
            // re-tag the colorspace and re-assert wantsExtendedDynamicRangeContent on the new backing.
            // mpv lane only; AVPlayerLayer is EDR-native and needs nothing.
            Task { @MainActor in
                (coordinator.player as? MPVMetalViewController)?.resyncDynamicRangeForWindowChange()
            }
        }
        let exit = nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { note in
            guard window == nil || (note.object as? NSWindow) === window else { return }
            macIsFullScreen = false
            // Same re-sync on the way OUT: exiting fullscreen swaps back to the original window/backing,
            // which loses the EDR activation the same way (see the enter handler above).
            Task { @MainActor in
                (coordinator.player as? MPVMetalViewController)?.resyncDynamicRangeForWindowChange()
            }
        }
        macFullScreenObservers = [enter, exit]
    }

    private func unobserveMacFullScreen() {
        for token in macFullScreenObservers { NotificationCenter.default.removeObserver(token) }
        macFullScreenObservers = []
    }
    #else
    /// No native window fullscreen off macOS; the genuine-exit chokes call this unconditionally.
    private func exitPlayerFullScreenIfNeeded() {}
    #endif

    private func refreshTracks() {
        audioTracks = coordinator.player?.tracks(ofType: "audio") ?? []
        subtitleTracks = coordinator.player?.tracks(ofType: "sub") ?? []
        VXProbe.log("subs", "tracks loaded embedded=\(subtitleTracks.count) audio=\(audioTracks.count)")
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
        // Mandated check 8: an explicit in-session subtitle pick captured before an engine switch must SURVIVE
        // the switch. Re-apply it here instead of the preference-derived auto pick, which would otherwise
        // override an explicit Off / language choice on the fresh mount. Only fall back to TrackSelector when
        // there was no explicit pick.
        if userPickedSubtitle {
            if let choice = pendingSubtitleReapply { reapplySubtitleChoice(choice); pendingSubtitleReapply = nil }
            // else: an explicit pick with no snapshot to restore; leave the engine's current selection, never
            // auto-override it.
        } else if let s = pick.subtitle {
            coordinator.player?.setSubtitleTrack(s)   // -1 = off
        }
        VXProbe.log("subs", "auto-select sub=\(pick.subtitle.map(String.init) ?? "none") audio=\(pick.audio.map(String.init) ?? "none")")
        contributeContainerLanguagesIfNeeded()   // pool the file's REAL track langs (provenance "container")
        refreshSoon()
        // The container had no track in the preferred language chain (subs stayed off): try the add-on list.
        // Either completion point can land first (tracks vs the add-on fetch), so both call this; the guards
        // + the one-shot latch inside make the double call safe. No-op when userPickedSubtitle is set (an
        // explicit pick, incl. one just re-applied above, hard-stops the async add-on auto path).
        autoSelectAddonSubtitleIfNeeded()
        // Restore the viewer's OWN last manual sync offset for this title (device-local, instant, offline).
        // Only when nothing is dialed in this session and the pooled seed hasn't fired; claiming the pooled
        // latch here suppresses the crowd seed so the viewer's own correction wins.
        if subDelay == 0, !pooledSeededOffset, let saved = SubtitleOffsetMemory.savedOffset(forContentKey: communityContentKey) {
            subDelay = saved
            if coordinator.player?.subtitleDelayAvailable == true {
                coordinator.player?.setSubDelay(saved)
            }
            pooledSeededOffset = true
        }
    }

    /// Push a resume/progress position to the presenter, refusing to REGRESS the stored resume below a
    /// suppressed-resume floor. A DV-remux switch that starts at 0 (forward-only, the resume seek is dropped)
    /// keeps the real resume point only in `suppressedResumeFloor`; without this the periodic saves and the
    /// exit flush would overwrite the account resume with the restarted-low position. The floor clears once
    /// the playhead passes it (the viewer caught up) or on the next source/episode load.
    private func reportProgress(_ position: Double) {
        guard !hasUncommittedIssuedMedia, !persistenceBlockedForExit else { return }
        if let floor = suppressedResumeFloor {
            if position < floor { return }
            suppressedResumeFloor = nil
        }
        if engineWritesOpen { onProgress(position, duration) }
        saveAccountProgress(position)
    }

    /// Persist a user-initiated seek (skip buttons, macOS arrow keys, slider commit) to the presenter, which
    /// writes it to BOTH the engine library and the account. Mirrors `reportProgress`' resume-floor guard for
    /// the onSeek lane (and the tvOS scrub-commit gate): a forward seek off the remux restart-at-0 must not
    /// overwrite the real account resume until the playhead has actually passed the floor. The floor clears
    /// once passed. Backward / non-suppressed seeks pass straight through.
    private func reportSeek(_ target: Double) {
        guard !hasUncommittedIssuedMedia, !persistenceBlockedForExit else { return }
        guard duration > 0 else { return }
        if let floor = suppressedResumeFloor {
            if target < floor { return }
            suppressedResumeFloor = nil
        }
        if engineWritesOpen { onSeek(target, duration) }
        lastReported = target
        saveAccountProgress(target)
    }

    /// Movies keep their historical engine-write behavior. Series writes require a confirmed explicit load
    /// whose video id matches the episode currently published by the first-frame identity commit.
    private var engineWritesOpen: Bool {
        guard isEpisodePlaybackContext else { return true }
        return EpisodePlaybackIdentity.engineWritesAllowed(
            boundVideoID: enginePlayerVideoId,
            displayedVideoID: curMeta?.videoId
        )
    }

    /// ACCOUNT-ATTRIBUTION FIX (binge advance): the account's Continue-Watching write happens HERE,
    /// keyed on `curMeta` (the episode actually playing at this event), not in the presenter closures.
    /// Every host used to close over the LAUNCH episode's `launch.meta` in onProgress/onSeek, so after
    /// an in-player `goToEpisode` advance the account save kept landing on the launch episode and the
    /// account CW position named the WRONG episode. `curMeta` is published at the new file's first
    /// frame (the binge-desync fix), so keying on it here attributes every save to the episode on
    /// screen. Mirrors tvOS `TVPlayerView.saveProgress` (already curMeta-keyed). Called only from the
    /// floor-guarded `reportProgress`/`reportSeek` chokepoints (+ the Restart lane, which reported
    /// directly), so WHEN a save fires is unchanged; only WHICH episode it names moved. No meta
    /// (trailer / paste-a-link / web shell) is a no-op, exactly like the old host-side meta guards.
    private func saveAccountProgress(_ position: Double) {
        guard !hasUncommittedIssuedMedia, !persistenceBlockedForExit else { return }
        guard let m = curMeta else { return }
        let dur = duration
        Task { await account.saveProgress(for: m, positionSeconds: position, durationSeconds: dur) }
    }

    /// Snapshot the viewer's CURRENT explicit subtitle selection so a following engine switch can re-apply it
    /// (mandated check 8). Off when no track is selected; otherwise an add-on / pooled external sub (matched
    /// back by language against the added set) or an embedded track (by lang/title).
    private func captureSubtitleChoice() -> SubtitleChoice {
        guard let sel = subtitleTracks.first(where: { $0.selected }) else { return .off }
        let selLang = sel.lang.lowercased()
        if let ext = addonSubs.first(where: { addedSubURLs.contains($0.url) && $0.lang.lowercased() == selLang }) {
            return .external(url: ext.url, title: ext.addonName, lang: ext.lang)
        }
        if let p = pooledSubs.first(where: { addedPooledIDs.contains($0.id) && $0.lang.lowercased() == selLang }) {
            return .pooled(id: p.id)
        }
        return .embedded(lang: sel.lang, title: sel.title)
    }

    /// Re-apply a captured subtitle choice on the NEW engine after a switch. Track id spaces differ per engine,
    /// so an embedded pick matches by lang/title (Off if it can't be found, never a different auto pick), and
    /// an external / pooled pick is re-added by URL / pool id (both engines auto-select the added track).
    private func reapplySubtitleChoice(_ choice: SubtitleChoice) {
        switch choice {
        case .off:
            coordinator.player?.setSubtitleTrack(-1)
        case let .embedded(lang, title):
            let l = lang.lowercased(), t = title.lowercased()
            let match = subtitleTracks.first { $0.lang.lowercased() == l && $0.title.lowercased() == t }
                     ?? subtitleTracks.first { $0.lang.lowercased() == l }
            coordinator.player?.setSubtitleTrack(match?.id ?? -1)
        case let .external(urlStr, title, lang):
            guard let player = coordinator.player else { return }
            let subtitleLoadToken = player.activeLoadToken
            let subtitleVideoID = curMeta?.videoId
            player.addExternalSubtitle(url: urlStr, title: title, lang: lang) { ok in
                guard permitsSubtitlePublication(loadToken: subtitleLoadToken, videoID: subtitleVideoID) else { return }
                if ok, player === coordinator.player {
                    addedSubURLs.insert(urlStr)
                    if player.subtitleDelayAvailable, subDelay != 0 { player.setSubDelay(subDelay) }
                }
            }
        case let .pooled(id):
            if let sub = pooledSubs.first(where: { $0.id == id }) { selectPooledSubtitle(sub, auto: true) }
        }
        VXProbe.log("subs", "re-applied explicit pick across engine switch: \(choice)")
    }

    /// Contribute the file's REAL audio + subtitle track languages to the community language index with
    /// provenance "container" -- the strongest signal, since these come from libmpv's own track list rather
    /// than a parsed release name. Fires once per session on every play (incl. Continue-Watching / card
    /// resumes that never open the detail view). Resolves a `tmdb:` library id to its `tt` id first so
    /// tmdb-only titles are not dropped (the same gap the trickplay identity fix closed). Fail-soft: an
    /// unresolvable tmdb id contributes nothing. Gated + consent-open inside `LanguageIndexClient.contribute`.
    private func contributeContainerLanguagesIfNeeded() {
        guard !langContributeDone, LanguageIndexClient.isEnabled else { return }
        let audio = audioTracks.map { $0.lang }.filter { !$0.isEmpty }
        let subs = subtitleTracks.map { $0.lang }.filter { !$0.isEmpty }
        guard !audio.isEmpty || !subs.isEmpty else { return }   // nothing container-derived to say
        langContributeDone = true

        // A tmdb-backed play carries a `tmdb:` library id. communityContentKey is now tmdb-safe, but it only
        // reads the resolver CACHE and returns nil on a miss. The language index wants the strongest signal even
        // for a title seen for the first time, so resolve tmdb -> tt HERE (cache, then network) and only fall
        // through to the direct communityContentKey for real tt / other ids.
        if let m = curMeta, !effectivelyLive, m.libraryId.lowercased().hasPrefix("tmdb:") {
            let rawId = m.libraryId
            let season = m.season, episode = m.episode
            Task.detached(priority: .utility) {
                let tt: String?
                if let cached = CommunityTrickplay.cachedIMDbID(for: rawId) {
                    tt = cached
                } else {
                    tt = await CommunityTrickplay.resolveIMDbID(rawId: rawId, seriesHint: season != nil)
                }
                guard let tt, let contentKey = SubtitleReleaseFingerprint.contentKey(imdbId: tt, season: season, episode: episode) else { return }
                await LanguageIndexClient.contribute(contentKey: contentKey, audioLangs: audio,
                                                     subLangs: subs, provenance: "container")
            }
            return
        }
        if let contentKey = communityContentKey {
            Task.detached(priority: .utility) {
                await LanguageIndexClient.contribute(contentKey: contentKey, audioLangs: audio,
                                                     subLangs: subs, provenance: "container")
            }
            return
        }
        langContributeDone = false   // no resolvable id yet; allow a later retry once tracks/meta firm up
    }

    // MARK: - Control visibility

    /// A tap toggles the controls. While the controls are visible (or a panel is open) the auto-hide
    /// timer keeps them up; showing them re-arms the timer. Mirrors tvOS's "show on input, hide on a
    /// fresh deadline" approach, fixing the unreliable show/hide.
    private func toggleControls() {
        noteInteraction()            // a tap is presence: re-arm the "Still watching?" idle guard
        if panel != nil { return }   // a tap behind an open panel shouldn't flip the bar; the scrim handles dismissal
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() } else { hideTask?.cancel() }
    }

    // MARK: - Player Lock (touch-lock)

    /// Engage the lock from the top bar: chrome drops immediately, the auto-hide timer stands down, and
    /// a brief unlock-chip flash teaches where the exit is.
    private func engageLock() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            isLocked = true
            controlsVisible = false
        }
        revealUnlockChip()
    }

    /// A tap on the locked video: flash the unlock chip for a few seconds instead of toggling controls.
    private func revealUnlockChip() {
        withAnimation(.easeInOut(duration: 0.2)) { unlockChipVisible = true }
        unlockChipHideTask?.cancel()
        unlockChipHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { unlockChipVisible = false }
        }
    }

    /// Unlock: restore the chrome exactly as a normal tap-to-show would (visible now, auto-hide re-armed).
    private func unlock() {
        unlockChipHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            isLocked = false
            unlockChipVisible = false
            controlsVisible = true
        }
        scheduleHide()
    }
    private func scheduleHide() {
        noteInteraction()            // every control interaction routes through here: re-arm the idle guard
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

    // MARK: - "Still watching?" idle guard

    /// Record any user interaction: push the idle deadline out and clear the auto-advance streak, so an
    /// actively-attended session never trips the prompt. Cheap (a Date write); safe from every control path.
    private func noteInteraction() {
        idleDeadline = Date().addingTimeInterval(Self.idleWatchTimeout)
        consecutiveAutoAdvances = 0
    }

    /// Start the single idle-watch poll. One long-lived loop (not a per-interaction Task) re-checks the
    /// deadline every 15s; interactions just move the deadline. Cancelled in onDisappear / leavePlayback.
    private func startIdleWatch() {
        idleWatchTask?.cancel()
        idleDeadline = Date().addingTimeInterval(Self.idleWatchTimeout)
        idleWatchTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                maybePromptStillWatching()
            }
        }
    }

    /// Fire the timed prompt iff the session looks unattended AND is actually playing. Never interrupts a
    /// paused / buffering / panel / failed / scrubbing session (those are not "running all night", and a
    /// modal there is just noise); each is re-checked on the next poll tick.
    private func maybePromptStillWatching() {
        guard hasStartedPlaying, !stillWatchingPrompt else { return }
        guard !isPaused, panel == nil, !scrubbing, !buffering, !loadFailed, !skipEditActive else { return }
        guard Date() >= idleDeadline else { return }
        presentStillWatching()
    }

    /// Pause playback (unless we are at an episode boundary, where the file has already ended) and raise the
    /// modal. `pendingNext` is the episode to roll to if the viewer taps Continue at a binge boundary.
    private func presentStillWatching(pendingNext: String? = nil) {
        guard !stillWatchingPrompt else { return }
        pendingStillWatchingEpisodeId = pendingNext
        if pendingNext == nil, !isPaused { coordinator.player?.togglePause() }   // mid-title: pause; boundary: already ended
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { stillWatchingPrompt = true }
    }

    /// "Continue": re-arm the guard, then resume -- either roll to the pending next episode (binge boundary)
    /// or un-pause the current title.
    private func continueStillWatching() {
        withAnimation(.easeInOut(duration: 0.2)) { stillWatchingPrompt = false }
        let next = pendingStillWatchingEpisodeId
        pendingStillWatchingEpisodeId = nil
        noteInteraction()
        if let next {
            goToEpisode(next, autoAdvance: true)
        } else {
            if isPaused { coordinator.player?.togglePause() }
            scheduleHide()
        }
    }

    /// "Stop": leave the player entirely (mirrors the transport Close).
    private func stopStillWatching() {
        stillWatchingPrompt = false
        pendingStillWatchingEpisodeId = nil
        leavePlayback()
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
            // AirPlay disc on the shared TIGHT glass disc, matching the sibling transport discs
            // (shape-clipped material, never glassEffect, no halo). Background only; the
            // AVRoutePickerView behavior is unchanged.
            .vortxGlassDisc()
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
