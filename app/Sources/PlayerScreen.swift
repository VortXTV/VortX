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
    let season: Int?
    let episode: Int?

    init(id: String, label: String, season: Int? = nil, episode: Int? = nil) {
        self.id = id
        self.label = label
        self.season = season
        self.episode = episode
    }
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
    var preparationRequest: NextEpisodePreparationRequest? = nil
    var torrentPreparationLease: PreparedTorrentEngineLease? = nil
    var preparedRemux: VortXPreparedRemuxAttachment? = nil
}

/// High-frequency playback position lives outside PlayerScreen's observed state. Only the small clock
/// leaves below subscribe to these ticks, so engine time updates do not invalidate the full player hierarchy.
private final class TimePosClock: ObservableObject {
    @Published var position: Double = 0
}

private struct PlayerTimeLabel: View {
    @ObservedObject var clock: TimePosClock
    var opacity: Double = 1
    var showWhenPositive = false

    var body: some View {
        Text(formattedTime(clock.position))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(opacity))
            .opacity(!showWhenPositive || clock.position > 0 ? 1 : 0)
    }

    private func formattedTime(_ time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time), hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

private struct PlayerClockSlider: View {
    @ObservedObject var clock: TimePosClock
    @Binding var scrubbing: Bool
    @Binding var scrubTarget: Double
    let duration: Double
    let onScrubChanged: (Double) -> Void
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        Slider(
            value: Binding(
                get: { scrubbing ? scrubTarget : clock.position },
                set: { scrubTarget = $0; onScrubChanged($0) }
            ),
            in: 0...max(duration, 1),
            onEditingChanged: onEditingChanged
        )
    }
}

private struct PlayerBufferedBand: View {
    @ObservedObject var clock: TimePosClock
    let duration: Double
    let bufferedTime: Double
    let trackWidth: CGFloat
    let sliderInset: CGFloat
    let height: CGFloat

    var body: some View {
        if duration > 0 {
            let head = min(1, max(0, clock.position / duration))
            let ahead = min(1, max(0, bufferedTime / duration))
            if ahead > head {
                let sx = sliderInset + CGFloat(head) * trackWidth
                let width = CGFloat(ahead - head) * trackWidth
                Capsule().fill(.white.opacity(0.42))
                    .frame(width: max(1, width), height: 3)
                    .position(x: sx + max(1, width) / 2, y: height / 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct PlayerScreen: View {
    #if os(iOS) || os(macOS)
    private struct DirectAVNoFrameRecovery: Equatable {
        let url: URL
        let episodeGeneration: Int
        let sourceGeneration: Int
        let resumeGeneration: Int
        let attemptID: String
        let mpvLoadToken: PlayerLoadToken?
    }
    private struct AVToMPVHandoff: Equatable {
        let url: URL
        let episodeGeneration: Int
        let sourceGeneration: Int
        let resumeGeneration: Int
    }
    #endif
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
    /// Session-only engine route chosen on the detail/source surface. nil keeps the persisted automatic route.
    var initialEnginePreference: PlayerEngineRouter.Override? = nil
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
    var seriesInventoryAuthority: AppleCWSeriesInventory.Authority = .launch
    var loadEpisode: ((String) async -> PlayerEpisodeStream?)? = nil
    /// Exact CoreVideo metadata admitted by this player's request-owned authoritative refresh. This is
    /// deliberately separate from `loadEpisode`: the launch-ID resolver may close over an immutable list,
    /// while this path consumes a successor that was not present when the player was mounted.
    var loadEpisodeWithMetadata: ((CoreVideo) async -> PlayerEpisodeStream?)? = nil
    /// Optional background pre-heat for the next episode's source (start a torrent's peer search, pull
    /// the first bytes of a direct file), called once around the episode's halfway point. Distinct from
    /// `loadEpisode`: it must NOT touch the engine's meta/player slot (that would hijack the current
    /// episode's progress), it only warms network I/O. Series detail wires it; nil elsewhere is a no-op.
    var warmNextEpisode: ((NextEpisodePreparationRequest) async -> PlayerEpisodeStream?)? = nil
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

    // MARK: - System Now Playing (#157)

    /// What the Lock Screen / Control Center / Mac menu-bar card should show for what is playing RIGHT NOW.
    /// Built from the LIVE identity (`curTitle` / `curMeta`), never the immutable launch props, so a binge
    /// advance or an in-player source hop re-publishes the new episode. Series carry the show name +
    /// season/episode separately; a movie leaves them nil.
    private var nowPlayingItem: NowPlayingItem {
        let m = curMeta   // already falls back to the launch meta
        let isSeries = m?.usesSeriesLifecycle == true
        let displayTitle = curTitle.isEmpty ? (m?.name ?? title) : curTitle
        return NowPlayingItem(title: displayTitle,
                              showName: isSeries ? m?.name : nil,
                              season: isSeries ? m?.season : nil,
                              episode: isSeries ? m?.episode : nil,
                              artworkURL: m?.poster,
                              isLive: effectivelyLive)
    }

    /// Push the current position / state to the system Now Playing surface. Self-throttling, so it is safe on
    /// the 4 Hz tick; `force` is for the moments the system cannot extrapolate (first frame, play/pause).
    /// Engine-agnostic: it reads only the chrome's own state, which BOTH engines drive through the same
    /// property stream.
    ///
    /// `at` overrides the published position for the ONE caller that runs before `currentTime` has been
    /// assigned this tick's value: the first-frame publish. Without it a resumed title publishes 0 and is
    /// only corrected on the next tick, so the card would briefly show the start of a film resumed at 40
    /// minutes.
    private func updateNowPlaying(at elapsed: Double? = nil, force: Bool = false) {
        guard hasStartedPlaying else { return }
        NowPlayingCenter.update(item: nowPlayingItem,
                                elapsed: elapsed ?? currentTime,
                                duration: duration,
                                paused: isPaused,
                                speed: speed,
                                force: force)
    }

    // MARK: Panels

    private enum Panel: Identifiable, Equatable {
        case speed, subtitles, subtitleSettings, secondarySubtitles, subtitleLanguage(code: String, label: String), audio, audioSettings, video, sources, sourceAudio, episodes, info, playerSettings, sleep, quality, chapters, engine
        var id: Int {
            switch self {
            case .speed: 0; case .subtitles: 1; case .subtitleSettings: 2; case .audio: 3
            case .audioSettings: 4; case .video: 5; case .sources: 6; case .info: 7
            case .playerSettings: 8; case .sleep: 9; case .episodes: 10; case .quality: 11
            case .chapters: 12; case .engine: 13; case .secondarySubtitles: 14
            case .subtitleLanguage: 15; case .sourceAudio: 16
            }
        }
        var title: String {
            switch self {
            case .speed: "Playback Speed"; case .subtitles: "Subtitles"
            case .subtitleSettings: "Subtitle Settings"; case .secondarySubtitles: "Second Subtitle"
            case .subtitleLanguage(_, let label): label
            case .audio: "Audio"
            case .audioSettings: "Audio Settings"; case .video: "Aspect Ratio"
            case .sources: "Sources"; case .sourceAudio: "Audio"; case .info: "Playback Info"; case .playerSettings: "Player Settings"
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
            case .subtitles, .secondarySubtitles, .subtitleLanguage, .audio, .quality, .sources, .chapters, .engine: true
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
        var isEnabled: Bool = true
        var accessibilityHint: String = ""
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
    @State private var localTrickplayCaptureBreaker = TrickplayLocalCaptureBreaker()
    @State private var hoverPreviewTime: Double?
    @State private var hoverPreviewRatio: CGFloat?
    @State private var lastLocalTrickplayCapture = -1000.0
    @State private var localTrickplayCaptureInFlight = false
    @State private var localTrickplayCaptureGeneration: UInt64 = 0
    @State private var assetSanityAttempt = EpisodicAssetSanityAttempt<PlayerLoadToken>()
    @State private var assetSanityTrackListToken: PlayerLoadToken?
    @State private var assetSanityRequestedResume = 0.0
    @State private var terminalRetiredAssetSanityOwner: PlayerLoadToken?
    @State private var assetSanityDeferredStartToken: PlayerLoadToken?
    @State private var assetSanityDeferredStartPosition = 0.0
    @State private var assetSanityStartEffectsToken: PlayerLoadToken?
    @State private var assetSanityObservationTask: Task<Void, Never>?
    @State private var assetSanityObservationToken: PlayerLoadToken?
    /// Wall-clock trickplay capture driver (player-agnostic backstop to the timePos-driven tick). Cancelled on
    /// disappear. See startTrickplayCaptureTimer.
    @State private var trickplayCaptureTimer: Task<Void, Never>?
    /// Capture cadence in seconds. Matches the local frame cache's ~10s tile interval and the community
    /// upload/vtt interval, so timer-driven and timePos-driven captures share one grid.
    private static var trickplayCaptureIntervalSecs: Double {
        Double(RemoteConfig.snapshot.captureIntervalSecs)
    }
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
    /// Stored as a reference in State without observing it here. TimePosClock's leaf views own the observation.
    @State private var timePosClock = TimePosClock()
    private var currentTime: Double {
        get { timePosClock.position }
        nonmutating set { timePosClock.position = newValue }
    }
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
    @State private var audioChannels = 0
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
    /// Session audio-language filter, matching the tvOS/iOS source-picker chip (#204). On Mac the
    /// pre-play source picker runs in the embedded Stremio web UI, so this lives in the native in-player
    /// `.sources` panel instead. Non-nil is installed as `TrackPreferences.audioLanguagesOverride` (a
    /// task-local) around the source ranking so releases carrying that audio float up; nil = profile pref.
    /// Per-playback state, never persisted, exactly like the native pickers' per-detail session scope.
    @State private var sessionAudioLanguages: [String]? = nil
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
    // Settings toggle (#200): default ON = current behavior. Off disables BOTH triggers below; playback then
    // runs uninterrupted (no idle pause, auto-advance proceeds without asking). SAME key TVPlayerView binds.
    @AppStorage("vortx.stillWatchingPrompt") private var stillWatchingPromptEnabled = true
    // How many back-to-back auto-advances (zero input between them) before the binge guard asks "Still
    // watching?". User-configurable in Settings; clamped to >= 1 at the comparison so a stray 0 can never
    // disable the guard silently (the toggle above is the off switch).
    @AppStorage("vortx.stillWatchingAfterEpisodes") private var stillWatchingAfterEpisodes = 4
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
    // A libmpv resume seek stashed by the cold-pipeline resume paths (the initial-launch duration handler and
    // nudgeResume) and applied at the first-frame commit instead of immediately. A pre-first-frame absolute seek
    // on a cold libmpv pipeline arms mpv's cache-emptying hold and wedges video output (blank + frozen timer);
    // deferring it until the first frame has rendered makes it an ordinary warm scrub, which is proven to render.
    // Only set when hasStartedPlaying is false (a warm mid-play nudge seeks immediately). Cleared at every fresh
    // mount / teardown so it can never leak onto the wrong mount. iOS port of TVPlayerView.pendingLibmpvResumeSeek.
    @State private var pendingLibmpvResumeSeek: Double?
    /// Safety net for the deferred resume seek issued at first frame. A slow / non-Range source can leave mpv
    /// parked at the pre-seek position indefinitely; the plain stall ladder then reloads at the real (low)
    /// playhead and silently drops the viewer's resume point. This abandons the offset instead and resumes
    /// playback from wherever the source actually is, with the persistence floor keeping the stored position.
    @State private var postFrameResumeSeekWatchdog: Task<Void, Never>?
    private let postFrameResumeSeekWatchdogSeconds: Double = 12
    @State private var warmedEpisodeID: String?      // next-episode source already warmed this episode (F6 preload)
    @State private var preparingEpisodeID: String?
    @State private var preparedEpisode: PlayerEpisodeStream?
    @State private var nextEpisodePreparationTask: Task<Void, Never>?
    @State private var nextEpisodePreparationGeneration = 0
    @State private var nextEpisodeAttemptPolicy = PreparedEpisodeAttemptPolicy()
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
    @State private var episodeResolutionTask: Task<Void, Never>?
    @State private var episodeResolutionDeadlineTask: Task<Void, Never>?
    @State private var episodeResolutionOwner: EpisodeResolutionOwner?
    @State private var episodeResolutionTargetVideoID: String?
    @State private var episodeResolutionAdmitted = false
    private static let episodeResolutionDeadlineSeconds: Double = 30
    @State private var playbackExited = false
    @State private var terminalFinalityRefreshTarget: AppleCWTerminalRefreshTarget?
    @State private var terminalFinalityRefreshGeneration: Int?
    @State private var terminalFinalityRefreshTask: Task<Void, Never>?
    @State private var sourceSwitchGeneration = 0
    @State private var loadedSeriesEpisodes: [PlayerEpisodeRef] = []
    @State private var loadedSeriesVideoMetadata: [CoreVideo] = []
    @State private var authoritativeSeriesEpisodes: [PlayerEpisodeRef]?
    @State private var terminalRewindGate = AppleCWTerminalProgressGate()
    private var curMeta: PlaybackMeta? { curMetaState ?? recordMeta }
    private var curTitle: String { curTitleState ?? title }
    private var isEpisodePlaybackContext: Bool {
        let target = pendingAdvance?.meta ?? curMeta
        if let target, EpisodePlaybackIdentity.isEpisodicContext(
            type: target.type, season: target.season, episode: target.episode,
            videoID: target.videoId
        ) { return true }
        return loadEpisode != nil || !allEpisodeRefs.isEmpty
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
        var subtitleTimingScope: SubtitleTimingScope? = nil
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
    @AppStorage(SubtitleStyle.Key.brightness) private var subBrightness = SubtitleStyle.defaultBrightness
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
    /// Debounced persist of the manual subtitle offset (W2-B FIX 2). One write per nudge burst instead of one
    /// per press; `pendingSubOffsetSave` carries the value the task will write so a teardown can flush it.
    @State private var subOffsetSaveTask: Task<Void, Never>?
    @State private var pendingSubOffsetSave: (delay: Double, scope: SubtitleTimingScope?)?
    /// Stable local subtitle-timing identity. This is independent from the richer community fingerprint below.
    @State private var subtitleTimingScope: SubtitleTimingScope?
    @State private var subtitleTimingGeneration = 0
    @State private var subtitleDelayAppliedLoadToken: PlayerLoadToken?
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
    /// No MPV surface is constructed until the retiring AV/remux route acknowledges producer unwind.
    @State private var avToMPVHandoff: AVToMPVHandoff?
    @State private var avToMPVHandoffBlocked = false
    @State private var avToMPVHandoffTask: Task<Void, Never>?
    /// A direct source gets one AVPlayer -> MPV no-frame opportunity, bound to the exact media identity.
    @State private var directAVNoFrameRecovery: DirectAVNoFrameRecovery?
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
    /// ENGINE OF ORIGIN for that grace window (W2-A item 3a). `endFileError` is a SHARED channel - the AVPlayer
    /// engine emits on it and so does libmpv - so a purely time-based grace can also swallow the INCOMING
    /// engine's own honest failure and cost the whole post-demote timeout. The demote (and the manual engine
    /// switch) captures the OUTGOING load's token here; PlayerLoadToken is UUID-backed, so it can never collide
    /// with the load that follows. Untagged events keep the old swallow: unattributable means "assume stale".
    @State private var demotedEngineLoadToken: PlayerLoadToken?
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
    /// Post-demote start budget for the libmpv leg (W2-A item 3b; tvOS twin in TVPlayerView). A demote disarms
    /// the fast progress-aware watchdog by construction, so the ONLY owner of the mpv re-load used to be the
    /// plain 30s timer: 15s of stall plus 30s of mpv on the very same url before anything marked the source dead.
    /// 12s matches the stall window that just expired and is safe to shorten because it is not a wall -
    /// `handleStartTimeout` EXTENDS by 20s whenever the buffered edge advanced since it armed, so an mpv leg
    /// that is genuinely pulling bytes keeps its long budget and only a second silent leg pays the 12s.
    private let avPostDemoteStartTimeoutSeconds: Double = 12
    /// When the AVPlayer start watchdog was armed for the current mount; drives the [dv] time-to-first-frame
    /// line when the timePos handler disarms it. Cleared (one-shot) by that handler.
    @State private var avWatchdogArmedAt: Date?
    #endif
    @State private var loadErrorMsg = ""
    /// CW-resume only: set once we've waited for a freshly-loaded source after the stored link failed, so the
    /// wait-and-hop runs at most once per playback (no unbounded loop). Reset on each new media load.
    @State private var awaitedFreshSources = false
    @State private var hasStartedPlaying = false
    /// Wall-clock uptime of the genuine first-frame event (set only alongside the true `hasStartedPlaying =
    /// true` transition below, never at the "foreground re-mount was not issued, restore the playing state"
    /// site - that one never actually stopped presentation, so resetting this there would wrongly reopen the
    /// trickplay settle window). Nil until the first real frame of this playback has rendered. Drives
    /// `TrickplayPresentationReadinessPolicy` so a capture cannot land in the startup window the report ties
    /// to a drop burst (report item 8).
    @State private var firstFrameRenderedAt: TimeInterval?
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
    /// When the app was last suspended while this player stayed mounted, so the foreground hook knows HOW LONG
    /// it was away. Nothing on-device can tell a live debrid link from an expired one, and re-minting a healthy
    /// one would cost the viewer a reload for nothing, so the suspension length is the only honest gate.
    /// Mirrors TVPlayerView.
    @State private var suspendedAt: Date?
    /// The play head at that same moment. `keepPlayingInBackground` defaults ON, so the audio really does keep
    /// running while backgrounded and a position that MOVED across the suspension proves the mount survived it -
    /// the only cheap, honest evidence that a revalidation would cost the viewer a reload for nothing. nil (no
    /// stamp) is "in doubt": revalidate. Mirrors TVPlayerView.
    @State private var suspendedTimePos: Double?
    /// A suspension shorter than this leaves the mount alone: the stored debrid link is almost certainly still
    /// valid and today's recovery ladder covers the rare miss. Past it the link has plausibly expired, and
    /// re-minting here saves the stall-watchdog wait that used to precede it (diag-21).
    private let mountRevalidationSuspensionSeconds: TimeInterval = 60
    /// How far the play head must have moved across a suspension to count as "it kept playing".
    private let healthyForegroundProgressSeconds: Double = 1
    /// True once this foreground has already booked its one delayed loopback re-check, so a foreground can never
    /// queue more than one (no busy loop). Cleared on every foreground entry.
    @State private var foregroundMountRecheckArmed = false
    /// How long the delayed re-check waits. `VortxNativeServer` clears `publishedPort` on background and only
    /// restarts at scenePhase `.active`, which lands AFTER `willEnterForeground`, so at revalidation time
    /// `StremioServer.base` still names the dead port and the heal below can prove nothing. One re-check past
    /// the restart is what makes the heal reachable at all.
    private let foregroundMountRecheckDelay: TimeInterval = 2.0
    /// The load the mid-play failure handler has already claimed. `PlayerLoadToken` changes on every (re)load,
    /// so recording it makes a SECOND mid-play error on the same mount inert while a genuinely new mount can
    /// still fail - the once-per-load latch that keeps the handler from ping-ponging with the stall watchdog.
    @State private var midPlayFailureOwner: PlayerLoadToken?
    /// Where the viewer actually was when a MID-PLAY failure handed the load to the recovery ladder. tvOS keeps
    /// a writable `resumeSeconds` @State and simply moves it; here `resumeSeconds` is an immutable view input,
    /// so without this the ladder - which runs with `hasStartedPlaying` already cleared - would resume at THIS
    /// load's origin and restart the episode from the beginning. Read by `retryResumeTarget()` and the failover
    /// hop, and cleared the moment the next mount either first-frames or is replaced.
    @State private var midPlayFailureResume: Double?
    /// Mid-play recoveries handed to the ladder on THIS mount. Deliberately NOT cleared by the first frame:
    /// `autoRetryCount` and `recoveryDeadline` are, so a source that frames for a tick and re-dies replenished
    /// every budget it had just spent and looped at roughly a reload a second, forever (a truncated file; a
    /// debrid link that 403s after its first range). Cleared only where the mount genuinely changes: a manual
    /// source pick, and a successful hop to a DIFFERENT source. Mirrors TVPlayerView.
    @State private var midPlayRecoveryCount = 0
    /// After this many mid-play recoveries on one mount, the source itself is the problem: stop re-loading it
    /// and hop, which is bounded by `sourceHops` and ends on the error overlay.
    private let maxMidPlayRecoveries = 3
    // First-buffer grace for a big 4K remux on slow debrid: a start-timeout that fires while bytes are
    // still arriving (the demuxer-cache edge advanced since the last watchdog arm) extends the wait
    // rather than declaring the source dead. Bounded by the number of extensions and the overall
    // recovery deadline, so a genuinely stalled source still errors.
    @State private var lastBufferedAtWatchdog = -1.0
    @State private var bufferGraceUsed = 0
    private let maxBufferGraceExtensions = 3      // up to ~3×20s extra on top of the 30s watchdog, deadline-capped
    /// EVIDENCE, not a control (tvOS twin in TVPlayerView): true only while the demote about to run followed
    /// POSITIVE dead-input proof (`MountProgress.inputProvablyDead` at the start-watchdog branch), as opposed to
    /// a renderer-only failure (AVFoundation cannot demux a source libmpv handles). Only that first case earns
    /// the shortened `avPostDemoteStartTimeoutSeconds` budget; #76 says a healthy-source renderer demote MUST
    /// keep the full 30s, because libmpv legitimately needs more than 12s to first-frame a cold 4K DV url. Set
    /// immediately before the demote call and consumed (cleared) as the first statement of
    /// `demoteAVPlayerToMPV`, so it can never leak into an unrelated later demote.
    @State private var demoteFollowedDeadInput = false
    @State private var recoveryDeadline: Task<Void, Never>?
    private let maxRecoverySeconds: Double = 150
    // Mid-playback stall recovery: a watchdog reloads / hops when the position freezes while NOT
    // buffering or paused (the black-screen / hard-stall case), bounded so a dead source still errors.
    @State private var stallWatchdog: Task<Void, Never>?
    @State private var lastObservedTime = -1.0
    @State private var stalledTicks = 0
    @State private var stallRecoveries = 0
    @State private var stallStableProgressTicks = 0

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
        .onChange(of: core.streamsEpoch) { _ in
            establishSubtitleTimingScopeIfAvailable()
            if appliedAutoTracks {
                restoreSubtitleTimingOffsetIfReady()
                applyCurrentSubtitleDelayIfReady(force: false)
            }
        }
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
        if avEngineFailed || avToMPVHandoff != nil || avToMPVHandoffBlocked { return false }
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
    /// router's non-isolated predicates (dvRemuxEngaged + isDVRemuxCandidate), i.e. the exact
    /// condition AVPlayerEngine.loadFile's shouldDVRemux evaluates, without the @MainActor wrapper.
    /// `dvRemuxEngaged` (not `dvRemuxEnabled`) so an explicit "Prefer AVPlayer" pick predicts the same DV
    /// mount the engine will actually make; mirrors TVPlayerView.activeAVPlayerWouldRemux.
    private var activeAVPlayerWouldRemux: Bool {
        let activeURL = curURL ?? url
        let isDV = StreamRanking.isDolbyVision(curHint ?? recordQualityText ?? "")
        return isDV
            && PlayerEngineRouter.dvRemuxEngaged(dvDisplayCapable: DVDisplaySupport.isCapable)
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
                                               override: initialEnginePreference ?? PlayerEngineRouter.currentOverride,
                                               dvDisplayCapable: DVDisplaySupport.isCapable,
                                               plainRemuxDelivery: VortXRemuxHLSServer.deliveryEnabled)
        // [dv] routing probe: the first line of the DV trail (route -> mount -> classify -> fallback -> demote).
        // If engine is AVPlayer on a DV source it is the true-DV lane (VideoToolbox); if it is mpv here the DV
        // source tone-maps to HDR10. Emitted through the shared DEDUPLICATED breadcrumb (b210): this property
        // is re-evaluated on every render pass before `engineLatch` is seeded in onAppear, which wrote the same
        // decision 3-4x per load into the rolling export, and the breadcrumb also gives iOS/macOS the same
        // always-on route trail tvOS already had (DiagnosticsLog still mirrors into the probe log when
        // probing is on, so nothing an export used to carry is lost).
        let candidacy = PlayerEngineRouter.dvRemuxCandidacy(url)
        // The dvRemux field carries the VALUE and its SOURCE (user toggle / remote fleet value / display
        // default / explicit AVPlayer pick), so a routing flip is never diagnosed by elimination. Mirrors tvOS.
        DVRouteBreadcrumb.log("route file=\(VXProbeRedaction.identityToken(url.lastPathComponent)) ext=\(url.pathExtension) isDV=\(isDV) dvDisplayCapable=\(DVDisplaySupport.isCapable) candidate=\(candidacy.candidate) [\(candidacy.reason)] container=\(PlayerEngineRouter.isAVPlayerContainer(url)) \(PlayerEngineRouter.dvRemuxRouteDescription(dvDisplayCapable: DVDisplaySupport.isCapable)) -> engine=\(chosen.rawValue)")
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
        if avToMPVHandoff != nil || avToMPVHandoffBlocked {
            Color.black.ignoresSafeArea()
        } else if useAVPlayerEngine {
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
            .play(mpvSurfacePlayback.url, headers: mpvSurfacePlayback.headers,
                  audioSidecar: mpvSurfacePlayback.audioSidecar,
                  isDolbyVision: mpvSurfacePlayback.isDolbyVision)
            .live(mpvSurfacePlayback.live)
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
            if !isTrailer, (headers?.isEmpty ?? true),
               let externalHandoffLoadToken = coordinator.player?.activeLoadToken {
                let externalHandoff = ExternalPlayer.HandoffIdentity(
                    url: url,
                    sessionID: playbackSessionID,
                    episodeGeneration: episodeSwitchGeneration,
                    loadToken: externalHandoffLoadToken
                )
                ExternalPlayer.routeToDefaultIfSet(url, isTorrent: recordIsTorrent) { launched in
                    guard !playbackExited,
                          externalHandoff.matches(
                              url: curURL ?? url,
                              sessionID: playbackSessionID,
                              episodeGeneration: episodeSwitchGeneration,
                              loadToken: coordinator.player?.activeLoadToken
                          ) else { return }
                    if launched {
                        onClose()
                    } else {
                        externalLinkDead = true
                    }
                }
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
            establishSubtitleTimingScopeIfAvailable()
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
            let assetSanityAccepted =
                assetSanityAttempt.isAccepted(owner: coordinator.player?.activeLoadToken)
            invalidateEpisodeWorkForExit()
            invalidateLocalTrickplayCapture()
            cancelAssetSanityObservationDeadline()
            core.setPlayerActive(false)   // balance the onAppear +1; re-enables the In-Library re-decode
            hideTask?.cancel(); loadTimeout?.cancel(); autoRetryTask?.cancel()
            stallWatchdog?.cancel(); recoveryDeadline?.cancel(); skipFetchTask?.cancel()
        postFrameResumeSeekWatchdog?.cancel()
            refreshTask?.cancel(); sleepTask?.cancel(); trickplayCaptureTimer?.cancel(); idleWatchTask?.cancel()
            cancelTerminalFinalityRefresh()
            #if os(iOS) || os(macOS)
            engineNoticeTask?.cancel(); avStartWatchdog?.cancel()
            #endif
            pendingLibmpvResumeSeek = nil   // teardown: drop any deferred resume seek so it cannot fire on a later mount
            postFrameResumeSeekWatchdog?.cancel(); postFrameResumeSeekWatchdog = nil
            // Community trickplay: contribute this device's captured frames as a shared sprite-sheet
            // (first-writer-wins, background, gated; no-op if the community already had a set). Never
            // touches the player teardown below.
            if assetSanityAccepted {
                scrubThumbnails.finishAndUploadIfNeeded(srcHeight: videoHeight)   // tag the set's source height (tvOS parity)
            }
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            suspendedAt = Date()   // only read on the way back in; see revalidateMountOnForeground
            suspendedTimePos = currentTime   // ... paired with the play head, so a mount that kept playing is provable
            // A backgrounded app can be killed outright (jetsam, or the user swiping it away) with no further
            // callback, and `leavePlayback` would then never run. Flush the debounced sync offset here too, so
            // the last window in which a write is still possible is the one that takes it.
            flushPendingSubOffsetSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            let suspended = suspendedAt.map { Date().timeIntervalSince($0) } ?? 0
            let playHead = suspendedTimePos
            suspendedAt = nil
            suspendedTimePos = nil
            foregroundMountRecheckArmed = false   // one delayed re-check per foreground, never a queue of them
            reconcileAdvanceOnForeground()
            // The advance reconcile owns a straddled episode switch; this owns the mount underneath a playback
            // that never moved. They are mutually exclusive by their own guards (a re-issued advance clears
            // hasStartedPlaying, which is exactly what this one requires).
            revalidateMountOnForeground(suspendedFor: suspended, playHeadAtSuspension: playHead)
        }
        #endif
        .confirmationDialog("Play in another app", isPresented: $showExternalChooser,
                            titleVisibility: .visible) {
            ForEach(ExternalPlayer.installed) { target in
                Button(target.name) {
                    let externalHandoffURL = curURL ?? url
                    let externalHandoffSessionID = playbackSessionID
                    let externalHandoffEpisodeGeneration = episodeSwitchGeneration
                    guard let externalHandoffLoadToken = coordinator.player?.activeLoadToken else {
                        externalLinkDead = true
                        return
                    }
                    let externalHandoff = ExternalPlayer.HandoffIdentity(
                        url: externalHandoffURL,
                        sessionID: externalHandoffSessionID,
                        episodeGeneration: externalHandoffEpisodeGeneration,
                        loadToken: externalHandoffLoadToken
                    )
                    // Pre-flight the link before handing off, so a dead debrid / CDN URL is caught here
                    // (we keep playing in the built-in player and say so) instead of bouncing the user
                    // into Infuse / VLC's own load error. Loopback torrents probe as alive instantly.
                    Task { @MainActor in
                        guard !playbackExited,
                              externalHandoff.matches(
                                  url: curURL ?? url,
                                  sessionID: playbackSessionID,
                                  episodeGeneration: episodeSwitchGeneration,
                                  loadToken: coordinator.player?.activeLoadToken
                              ) else { return }
                        let probeSucceeded = await ExternalPlayer.probeAlive(externalHandoff.url)
                        guard !playbackExited,
                              externalHandoff.matches(
                                  url: curURL ?? url,
                                  sessionID: playbackSessionID,
                                  episodeGeneration: episodeSwitchGeneration,
                                  loadToken: coordinator.player?.activeLoadToken
                              ) else { return }
                        guard probeSucceeded else { externalLinkDead = true; return }
                        // Handed off, stop local playback so the stream isn't decoded twice.
                        ExternalPlayer.open(target, stream: externalHandoff.url) { launched in
                            guard !playbackExited,
                                  externalHandoff.matches(
                                      url: curURL ?? url,
                                      sessionID: playbackSessionID,
                                      episodeGeneration: episodeSwitchGeneration,
                                      loadToken: coordinator.player?.activeLoadToken
                                  ) else { return }
                            if launched, !isPaused {
                                coordinator.player?.togglePause()
                            } else if !launched {
                                externalLinkDead = true
                            }
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

    private func beginAssetSanityAttemptIfNeeded(
        loadToken: PlayerLoadToken,
        requestedResumeOrigin: Double
    ) {
        guard loadToken == coordinator.player?.activeLoadToken,
              assetSanityAttempt.owner != loadToken else { return }
        assetSanityAttempt.begin(owner: loadToken)
        terminalRetiredAssetSanityOwner = nil
        assetSanityTrackListToken = nil
        assetSanityRequestedResume = max(0, requestedResumeOrigin)
        assetSanityDeferredStartToken = nil
        assetSanityStartEffectsToken = nil
        cancelAssetSanityObservationDeadline()
    }

    private var assetSanityExpectedRuntimeSeconds: Double? {
        guard let m = curMeta,
              let loaded = core.metaDetails?.meta,
              loaded.id == m.libraryId,
              let seconds = loaded.runtimeSeconds,
              seconds > 0 else { return nil }
        return seconds
    }

    private func assetSanityEvidence(
        loadToken: PlayerLoadToken
    ) -> EpisodicAssetSanityPolicy.Evidence {
        let player = coordinator.player
        let summary = player?.mediaSummary()
        let engineDuration = player?.mediaDurationSeconds() ?? 0
        let observedDuration = duration > 0 ? duration : engineDuration
        return .init(
            isLibMPV: !(player is AVPlayerEngineController),
            season: curMeta?.season,
            episode: curMeta?.episode,
            isLive: effectivelyLive,
            isTrailer: isTrailer,
            claimedResolutionRank: curSourceStream.map(StreamRanking.resolutionRank) ?? 0,
            actualWidth: summary?.width ?? videoWidth,
            actualHeight: summary?.height ?? videoHeight,
            framesPerSecond: player?.containerFrameRate() ?? 0,
            durationSeconds: observedDuration,
            trackListObserved: assetSanityTrackListToken == loadToken,
            audioTrackCount: audioTracks.count,
            expectedRuntimeSeconds: assetSanityExpectedRuntimeSeconds
        )
    }

    private func publishAssetSanityStartEffectsIfNeeded(
        loadToken: PlayerLoadToken,
        position: Double
    ) {
        guard assetSanityAttempt.isAccepted(owner: loadToken),
              assetSanityStartEffectsToken != loadToken else { return }
        assetSanityStartEffectsToken = loadToken
        localTrickplayCaptureBreaker.reset()
        recordLastStream()
        if let m = curMeta, !effectivelyLive {
            ScrobbleCoordinator.shared.playbackStarted(
                m, position: position, duration: duration,
                sessionToken: playbackSessionID
            )
        }
        publishAcceptedDurationSideEffectsIfNeeded(
            loadToken: loadToken, durationSeconds: duration
        )
    }

    private func publishAcceptedDurationSideEffectsIfNeeded(
        loadToken: PlayerLoadToken?,
        durationSeconds: Double
    ) {
        let acceptedOwner = assetSanityAttempt.isAccepted(owner: loadToken) ? loadToken : nil
        guard EpisodicAssetSanityPolicy.canPublishDurationSideEffects(
            callbackOwner: loadToken,
            acceptedOwner: acceptedOwner,
            durationSeconds: durationSeconds
        ) else { return }
        if let m = curMeta {
            scrubThumbnails.configureCommunity(
                imdbId: m.libraryId, season: m.season, episode: m.episode,
                duration: durationSeconds, isRealDuration: true
            )
        }
        refreshSubFingerprint(force: true)
        fetchPooledSubtitles()
    }

    private func cancelAssetSanityObservationDeadline() {
        assetSanityObservationTask?.cancel()
        assetSanityObservationTask = nil
        assetSanityObservationToken = nil
    }

    private func armAssetSanityObservationDeadlineIfNeeded(
        loadToken: PlayerLoadToken
    ) {
        guard assetSanityObservationToken != loadToken,
              assetSanityDeferredStartToken == loadToken else { return }
        cancelAssetSanityObservationDeadline()
        assetSanityObservationToken = loadToken
        assetSanityObservationTask = Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(EpisodicAssetSanityPolicy.incompleteEvidenceGraceSeconds)
            )
            guard !Task.isCancelled,
                  assetSanityObservationToken == loadToken else { return }
            guard loadToken == coordinator.player?.activeLoadToken,
                  loadToken == committedLoadToken,
                  assetSanityDeferredStartToken == loadToken else {
                cancelAssetSanityObservationDeadline()
                return
            }
            srcProbe("asset sanity telemetry incomplete after bounded observation; accepting exact load")
            _ = acceptIncompleteAssetSanityIfCurrent(
                loadToken: loadToken,
                position: assetSanityDeferredStartPosition
            )
        }
    }

    @discardableResult
    private func acceptIncompleteAssetSanityIfCurrent(
        loadToken: PlayerLoadToken,
        position: Double
    ) -> Bool {
        guard loadToken == coordinator.player?.activeLoadToken,
              loadToken == committedLoadToken else { return false }
        switch assetSanityAttempt.acceptIncompleteEvidence(owner: loadToken) {
        case .accepted, .settled(.accept):
            cancelAssetSanityObservationDeadline()
            publishAssetSanityStartEffectsIfNeeded(
                loadToken: loadToken, position: position
            )
            return true
        case .rejected, .settled(.reject):
            cancelAssetSanityObservationDeadline()
            return false
        case .stale, .waiting, .settled(.wait):
            return false
        }
    }

    @discardableResult
    private func settleAssetSanityIfPossible(
        loadToken: PlayerLoadToken,
        position: Double
    ) -> Bool {
        guard loadToken == coordinator.player?.activeLoadToken,
              loadToken == committedLoadToken else { return false }
        switch assetSanityAttempt.evaluate(
            owner: loadToken,
            evidence: assetSanityEvidence(loadToken: loadToken)
        ) {
        case .stale:
            return false
        case .waiting, .settled(.wait):
            armAssetSanityObservationDeadlineIfNeeded(loadToken: loadToken)
            return true
        case .accepted, .settled(.accept):
            cancelAssetSanityObservationDeadline()
            publishAssetSanityStartEffectsIfNeeded(
                loadToken: loadToken, position: position
            )
            return true
        case .rejected:
            cancelAssetSanityObservationDeadline()
            handleRejectedEpisodicAsset(loadToken: loadToken)
            return false
        case .settled(.reject):
            cancelAssetSanityObservationDeadline()
            return false
        }
    }

    private func handleRejectedEpisodicAsset(loadToken: PlayerLoadToken) {
        guard loadToken == coordinator.player?.activeLoadToken,
              assetSanityAttempt.isRejected(owner: loadToken) else { return }
        let originalResume = assetSanityRequestedResume
        let hasAlternative = nextUntriedStream() != nil
        srcProbe(
            "rejected mismatched asset originalResume=\(Int(originalResume))s alternative=\(hasAlternative)"
        )
        loadTimeout?.cancel()
        recoveryDeadline?.cancel()
        recoveryDeadline = nil
        coordinator.player?.pause()
        invalidateLocalTrickplayCapture()
        assetSanityDeferredStartToken = nil
        cancelAssetSanityObservationDeadline()
        switch EpisodicAssetSanityPolicy.recovery(
            explicitPick: currentPickWasExplicit,
            continueWatching: currentPlaybackIsResume,
            hasAlternative: hasAlternative,
            originalResumeSeconds: originalResume
        ) {
        case .hop(let requestedResume):
            hasStartedPlaying = false
            currentTime = 0
            if hopToNextSource(
                reason: "source returned a short audio-less preview",
                resumeOverride: requestedResume,
                allowBeyondFailureBudget: true
            ) {
                return
            }
        case .showMismatch:
            break
        }
        loadErrorMsg = "This source returned a stream that does not match the selected title."
        presentTerminalLoadFailure()
    }

    private func handleProperty(_ name: String, _ data: Any?, loadToken: PlayerLoadToken? = nil) {
        if let loadToken, loadToken == coordinator.player?.activeLoadToken {
            beginAssetSanityAttemptIfNeeded(
                loadToken: loadToken,
                requestedResumeOrigin: avSurfaceResumeOrigin
                    ?? (hasStartedPlaying ? currentTime : resumeSeconds)
            )
        }
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
                    DiagnosticsLog.log(
                        "playback",
                        String(
                            format: "first frame position=%.3fs lane=%@ resume=%.3fs autoSkip=%@",
                            d,
                            isAVPlayerActive ? "avplayer" : "libmpv",
                            resumeSeconds,
                            autoSkip ? "on" : "off"
                        )
                    )
                    // [src-probe] FIRST FRAME: the overlay/spinner is about to clear and real playback begins.
                    // The gap between LOAD START and this line is the true startup latency; if a reconnect/hop
                    // message showed during that window (see the overlay-set probes) it was a transient shown
                    // then cleared here, not a real failure.
                    srcProbe("FIRST FRAME at pos=\(String(format: "%.1f", d))s (playback started, clearing overlays)")
                    hasStartedPlaying = true
                    directAVNoFrameRecovery = nil
                    firstFrameRenderedAt = ProcessInfo.processInfo.systemUptime
                    // Deferred libmpv resume seek: the pipeline is now warm (first frame rendered), so this lands
                    // as an ordinary scrub instead of the cold pre-first-frame seek that wedged video output.
                    // AVPlayer never stashes one (its resume is a pre-mount remux origin), so this is a no-op there.
                    if let t = pendingLibmpvResumeSeek {
                        pendingLibmpvResumeSeek = nil
                        // Arm the persistence fence synchronously with the seek (mirrors nudgeResume): a low
                        // tick or exit callback before the seek lands must not regress the stored resume.
                        if let floor = DeferredResumeFloorPolicy.armedFloor(targetSeconds: t) {
                            suppressedResumeFloor = max(suppressedResumeFloor ?? 0, floor)
                            lastReported = max(lastReported, suppressedResumeFloor ?? floor)
                        }
                        coordinator.player?.seek(to: t)
                        armPostFrameResumeSeekWatchdog(target: t)
                    }
                    midPlayFailureResume = nil   // a mount that is playing owns its own position again
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
                    assetSanityDeferredStartToken = event.loadToken
                    assetSanityDeferredStartPosition = d
                    guard settleAssetSanityIfPossible(
                        loadToken: event.loadToken, position: d
                    ) else { return }
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
                    autoRetryCount = 0
                    // Lock Screen / Control Center / media-key transport. Relative mpv seek so the skip always
                    // works off the LIVE position (a captured currentTime would be stale in these long-lived
                    // targets); the absolute seek is the system progress bar's own drag. play/pause are
                    // DISTINCT from the toggle now: the system sends the command it wants, so routing an
                    // explicit "play" into a toggle paused a playing film (#157).
                    NowPlayingCenter.wireCommands(
                        play: { coordinator.player?.play() },
                        pause: { coordinator.player?.pause() },
                        togglePause: { coordinator.player?.togglePause() },
                        seekBy: { delta in coordinator.player?.seek(by: delta) },
                        seekTo: { position in coordinator.player?.seek(to: position) },
                        stepSeconds: seekStepSeconds,
                        canScrub: NowPlayingPolicy.allowsScrubbing(duration: duration, isLive: effectivelyLive))
                    updateNowPlaying(at: d, force: true)   // publish the card immediately, not on the next tick
                    fetchPooledSubtitles()          // community-subtitle pool (P2/P3), fail-soft + gated
                    uploadEmbeddedSubtitlesIfNeeded()   // best-effort pooling of the file's own text tracks (P4)
                    applyPersistedVolume()          // restore the saved in-player volume + mute (D5)
                    startStallWatchdog()            // arm mid-playback freeze detection
                    fetchSkipTimestamps()           // crowd intro/outro spans (disk-cached, non-blocking)
                    fetchAddonSubtitles()
                }
                if !scrubbing {
                    currentTime = d
                    if assetSanityDeferredStartToken == event.loadToken,
                       !assetSanityAttempt.isAccepted(owner: event.loadToken),
                       !assetSanityAttempt.isRejected(owner: event.loadToken),
                       !settleAssetSanityIfPossible(
                        loadToken: event.loadToken, position: d
                       ) {
                        return
                    }
                    let assetSanityAccepted = assetSanityAttempt.isAccepted(owner: event.loadToken)
                    if assetSanityAccepted {
                        suppressedResumeFloor = DeferredResumeFloorPolicy.floorAfterAcceptedPlayback(
                            currentFloor: suppressedResumeFloor,
                            positionSeconds: d
                        )
                    }
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
                    updateNowPlaying()
                    NowPlayingCenter.setScrubbingEnabled(
                        NowPlayingPolicy.allowsScrubbing(duration: duration, isLive: effectivelyLive))
                    // Provision the community key off meta.runtime the moment the behind-playback meta lands
                    // (idempotent; no-op once keyed), so capture starts even without a duration event.
                    if assetSanityAccepted { configureCommunityTrickplayProvisional() }
                    maybeCaptureLocalTrickplay(at: d)
                    // Live streams must NOT write a resume offset: their "position" is just elapsed
                    // wall-clock of the buffer, and persisting it would make a later open seek into a
                    // bogus offset (or drop a fake Continue-Watching entry).
                    if assetSanityAccepted, !effectivelyLive,
                       duration > 0, d - lastReported >= 5 {   // push progress ~every 5s
                        lastReported = d
                        reportProgress(d)
                    }
                    // ~60s in → the user is really watching this: auto-add to the Library (D8) and send the
                    // anonymized fleet watch ping (D9), each once per playback. Both are idempotent + gated
                    // (D8 by the setting + per-profile dedup; D9 by MoatConsent + per-title/day dedup), so a
                    // resume that starts past 60s, a source hop, or an episode switch never double-fires here
                    // for the same title. Skipped for live (no library/ranking meaning) and ad-hoc plays.
                    if assetSanityAccepted, !autoAddedThisPlayback,
                       !effectivelyLive, d >= 60, let m = curMeta {
                        autoAddedThisPlayback = true
                        LibraryAutoAdd.addIfNeeded(meta: m, core: core, enabled: autoAddLibrary)
                        // Resolve a tmdb:… hub/catalog id to its tt identity first (fire-and-forget on a cache
                        // miss) so those plays feed the pool too; a tt id still pings inline. Never blocks.
                        WatchSignalClient.pingResolvingTMDB(contentId: m.libraryId, type: m.type, seriesHint: m.season != nil)
                    }
                    // Halfway through a series episode, prepare and retain the NEXT episode's exact settled
                    // source. Auto-advance consumes that generation-owned value without a cold re-rank, then
                    // advances CoreBridge's episode identity before issuing the already selected stream.
                    // Past the halfway mark when the duration is known, or after ~2 min of playback when it
                    // ISN'T: many debrid MKVs never emit mpv's `duration`, so the duration>60 trigger alone
                    // never fired for them and the next episode never pre-heated (the "next episode cold-starts"
                    // case). The attempt policy bounds retries and reserves one final credits recovery.
                    if assetSanityAccepted, !effectivelyLive,
                       ((duration > 60 && d / duration >= 0.5) || (duration <= 0 && d >= 120)) {
                        warmNextIfNeeded()
                    }
                    // ~90% in → flip the engine's watched marker live, so the title leaves Continue
                    // Watching / shows as watched without waiting for EOF (mirrors tvOS:180-183).
                    if assetSanityAccepted, !markedWatched,
                       !effectivelyLive, duration > 0, d / duration >= 0.9,
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
                            case .hidePreroll:
                                // AVPlayerEngine issues the actual corrective local seek (root-cause report
                                // section 7); this is only the UI/progress bookkeeping. Once that seek lands,
                                // the viewer sees `resumeSeconds`, not `origin`, so report that here too.
                                suppressedResumeFloor = nil
                                currentTime = resumeSeconds
                                lastReported = resumeSeconds
                            case .unreachable:
                                suppressedResumeFloor = resumeSeconds
                                lastReported = resumeSeconds
                                showEngineNotice("That resume point is unavailable for this source. Playing from the earliest available position.")
                            }
                        } else {
                            // A pre-first-frame absolute seek on a cold libmpv pipeline arms mpv's cache-emptying
                            // hold and wedges video output (blank + frozen timer); defer it to the first-frame
                            // commit so it lands as an ordinary warm scrub, which is proven to render. If the
                            // pipeline is already warm (a deferred-duration re-injection at the first frame), seek
                            // now - that is the normal scrub path.
                            if hasStartedPlaying {
                                coordinator.player?.seek(to: resumeSeconds)
                            } else {
                                pendingLibmpvResumeSeek = resumeSeconds
                            }
                            currentTime = resumeSeconds
                            lastReported = resumeSeconds
                        }
                    }
                }
                refreshSkipSegments()
                // The real duration sharpens the community trickplay key and subtitle release fingerprint,
                // but only after the exact load has passed asset sanity. A rejected short preview can share the
                // episode's local cache key, so publishing its duration here would poison the replacement load.
                publishAcceptedDurationSideEffectsIfNeeded(
                    loadToken: loadToken, durationSeconds: d
                )
                if let loadToken,
                   assetSanityDeferredStartToken == loadToken,
                   !settleAssetSanityIfPossible(
                    loadToken: loadToken,
                    position: assetSanityDeferredStartPosition
                   ) {
                    return
                }
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
            // play()/pause() emit MPVProperty.pause optimistically and the KVO echo then arrives with the same
            // value, so gate every side effect on a real change: the scrobble pause/resume must fire once per
            // press, not twice (this also collapses the pre-existing KVO double-fire). The now-playing write is
            // idempotent, so running it only on a real change is correct.
            if let b = data as? Bool, b != isPaused {
                isPaused = b
                // Reflect the play/pause state on the Lock Screen immediately (timePos stops ticking while
                // paused, so without this the now-playing rate would stay stuck at "playing").
                updateNowPlaying(force: true)
                // External sync (Trakt) live scrobble pause/resume. Scrobble ONLY: this handler persists
                // nothing else (no resume-point write). Additive + fail-soft + gated inside the coordinator;
                // a no-op with empty creds. Live content is excluded (parity with the start/stop hooks).
                // SIMKL has no live scrobble, so it is skipped by capability.
                if callbackBelongsToCommittedMedia(loadToken),
                   assetSanityAttempt.isAccepted(owner: loadToken),
                   let m = curMeta, !effectivelyLive {
                    let pos = max(currentTime, suppressedResumeFloor ?? 0)
                    if b { ScrobbleCoordinator.shared.playbackPaused(m, position: pos, duration: duration) }
                    else { ScrobbleCoordinator.shared.playbackResumed(m, position: pos, duration: duration) }
                }
            }
        case MPVProperty.trackList:
            refreshTracks()
            if let loadToken, callbackBelongsToCommittedMedia(loadToken) {
                assetSanityTrackListToken = loadToken
            }
            let summary = coordinator.player?.mediaSummary()
            videoWidth = summary?.width ?? 0; videoHeight = summary?.height ?? 0; audioCodec = summary?.audioCodec ?? ""
            audioChannels = summary?.audioChannels ?? 0
            metadataLine = computeMetadataLine()
            // Gap A (#76): on AVPlayer, chapters() is [] at readyToPlay (loadChapters is async) and the engine
            // re-emits trackList precisely once they resolve, so re-pull skip candidates + chapter marks here.
            // On libmpv chapters() is already synchronous at duration, so this is a cheap no-op re-run there.
            refreshSkipSegments()
            if !appliedAutoTracks, !audioTracks.isEmpty || !subtitleTracks.isEmpty {
                appliedAutoTracks = true
                autoSelectTracks()
            }
            applyCurrentSubtitleDelayIfReady(force: false)
            if let loadToken,
               assetSanityDeferredStartToken == loadToken,
               !settleAssetSanityIfPossible(
                loadToken: loadToken,
                position: assetSanityDeferredStartPosition
               ) {
                return
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
                let avFailureMessage = (data as? String) ?? "-"
                // A terminal zero-packet source (the remux pre-scan proved EOF before any timestamped
                // base-video packet) can never produce a frame on libmpv either: it is the same dead bytes,
                // not a decoder problem. Hop to the next source instead of burning ~30s on a second engine
                // that is guaranteed to fail the same way. Only pre-first-frame failures qualify; a mid-play
                // failure already proves packets WERE flowing, so it keeps the existing in-place demote.
                if !hasStartedPlaying, RemuxFirstPacketFailure.isTerminalZeroPacket(avFailureMessage) {
                    srcProbe("endFileError on AVPlayer -> terminal zero-packet source, hop instead of demote reason=\(avFailureMessage)")
                    if hopToNextSource(reason: "remux terminal zero-packet source") { return }
                }
                srcProbe("endFileError on AVPlayer -> demote to libmpv in place (not a hop) reason=\(avFailureMessage)")
                demoteAVPlayerToMPV(silent: !hasStartedPlaying)
                return
            }
            // Stale error from the just-dismounted AVPlayer engine (a queued event can land after the swap):
            // swallow it so it never burns the fresh mpv load's retry budget or paints the error overlay.
            // W2-A item 3a (tvOS twin in TVPlayerView): `endFileError` is a SHARED channel - libmpv emits on it
            // too - so a window keyed only on time would also eat the INCOMING engine's own fast, honest failure
            // and force the full post-demote timeout on a url libmpv already rejected. Only an event PROVEN to
            // belong to a different load than the dismounted engine's escapes; an untagged event, or a demote
            // whose outgoing token was never captured, keeps today's swallow (the fail-open direction).
            let provenFromIncomingEngine: Bool = {
                guard let loadToken, let outgoing = demotedEngineLoadToken else { return false }
                return loadToken != outgoing
            }()
            if let t = avDemotedAt, Date().timeIntervalSince(t) < 2, !provenFromIncomingEngine {
                srcProbe("endFileError SWALLOWED (stale post-demote grace <2s) reason=\((data as? String) ?? "-")")
                return
            }
            if provenFromIncomingEngine, let t = avDemotedAt, Date().timeIntervalSince(t) < 2 {
                srcProbe("endFileError inside the post-demote grace but from the INCOMING engine's own load -> handled, not swallowed reason=\((data as? String) ?? "-")")
            }
            if !hasStartedPlaying,
               let recovery = directAVNoFrameRecovery,
               recovery.url == (curURL ?? url),
               recovery.episodeGeneration == episodeSwitchGeneration,
               recovery.sourceGeneration == sourceSwitchGeneration,
               recovery.resumeGeneration == resumeRetryGeneration,
               recovery.mpvLoadToken == loadToken,
               loadToken == coordinator.player?.activeLoadToken {
                loadTimeout?.cancel()
                directAVNoFrameRecovery = nil
                DiagnosticsLog.log("playback", "fallback attempt=\(recovery.attemptID) stage=mpv-terminal outcome=no-first-frame")
                if currentPickWasExplicit {
                    loadErrorMsg = "This source didn't produce playable media. Choose another source."
                    presentTerminalLoadFailure()
                    return
                }
                if currentPlaybackIsResume, !resumeSourceReresolved,
                   retryResumeSameSource() { return }
                if hopToNextSource(reason: "fallback MPV produced no frame") { return }
                if loadErrorMsg.isEmpty { loadErrorMsg = "This source did not produce playable media." }
                presentTerminalLoadFailure()
                return
            }
            #endif
            if !hasStartedPlaying {                  // only flag failures BEFORE playback
                srcProbe("endFileError -> handleLoadFailure reason=\((data as? String) ?? "-")")
                handleLoadFailure((data as? String) ?? "")
            } else if !isLive {
                handleMidPlayFailure((data as? String) ?? "", loadToken: loadToken)
            } else {
                srcProbe("endFileError IGNORED (live stream owns its own reconnect) reason=\((data as? String) ?? "-")")
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
            if !completionOnly, let loadToken {
                guard EpisodicAssetSanityPolicy.canAcceptIncompleteEvidenceAtEOF(
                    callbackOwner: loadToken,
                    deferredFirstFrameOwner: assetSanityDeferredStartToken,
                    hasStartedPlaying: hasStartedPlaying
                ) else {
                    loadTimeout?.cancel()
                    handleLoadFailure("Media ended before its first frame")
                    return
                }
                guard settleAssetSanityIfPossible(
                    loadToken: loadToken, position: currentTime
                ) else {
                    return
                }
                if !assetSanityAttempt.isAccepted(owner: loadToken) {
                    guard acceptIncompleteAssetSanityIfCurrent(
                        loadToken: loadToken, position: currentTime
                    ) else { return }
                }
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
                if stillWatchingPromptEnabled, consecutiveAutoAdvances >= max(1, stillWatchingAfterEpisodes) {
                    presentStillWatching(pendingNext: allEpisodeRefs[i + 1].id)
                } else {
                    goToEpisode(allEpisodeRefs[i + 1].id, autoAdvance: true)
                }
            } else if hasNext, !skipEditActive {
                onNext()                                  // legacy non-episode caller (in-place)
            } else if !skipEditActive {
                if let m = curMeta, m.usesSeriesLifecycle {
                    let decision = terminalSeriesDecision(for: m)
                    if decision == .refresh, !terminalFinalityRefreshUsed {
                        refreshTerminalSeriesInventory(for: m)
                        return
                    }
                } else if let m = curMeta, terminalRewindGate.issueTerminalRewind() {
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
        if let m = curMeta { return "v:\(m.libraryId):\(m.videoId)" }
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
                guard curMeta?.libraryId == m.libraryId,
                      curMeta?.videoId == m.videoId else { return }   // still the same episode
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
        guard !localTrickplayCaptureBreaker.isOpen else { return }
        // Player-AGNOSTIC capture: both engines emit MPVProperty.timePos (libmpv's coalesced tick and the
        // AVPlayer engine's periodic time observer), so this drives capture on Mac/iOS for libmpv AND AVPlayer.
        // A parallel wall-clock timer (startTrickplayCaptureTimer) is the belt-and-suspenders backstop for a
        // stream whose timePos events are sparse/coalesced. Both funnel through captureTrickplayFrame.
        guard assetSanityAttempt.isAccepted(owner: coordinator.player?.activeLoadToken) else { return }
        guard TrickplayCaptureCadencePolicy.shouldCapture(
            playbackTime: time,
            lastCaptureTime: lastLocalTrickplayCapture,
            intervalSeconds: Self.trickplayCaptureIntervalSecs,
            playbackActive: !buffering && !isPaused,
            isScrubbing: scrubbing,
            captureInFlight: localTrickplayCaptureInFlight
        ) else { return }
        // Report item 8: withhold capture until first frame + display settle so its GPU work cannot land in
        // the startup/renegotiation window the diagnosed drop bursts cluster in. tvOS is the platform with a
        // real HDMI display-mode renegotiation; HDRDisplayMode.isSwitchSettled is a permanently-true no-op
        // on iOS/macOS, so this reduces to the elapsed-time gate there. Checked here, after the cheap cadence
        // gate, so mediaSummary() (inside isCurrentContentUHDHDR) reads only at capture boundaries, not on
        // every timePos tick.
        guard TrickplayPresentationReadinessPolicy.isReady(
            elapsedSinceFirstFrame: firstFrameRenderedAt.map { ProcessInfo.processInfo.systemUptime - $0 },
            displaySwitchSettled: HDRDisplayMode.isSwitchSettled,
            isUltraHighDefinitionHDR: isCurrentContentUHDHDR()
        ) else { return }
        captureTrickplayFrame(at: time)
    }

    /// Longer trickplay settle threshold for the most expensive frame to scale (report item 8: "lower
    /// cadence during 4K HDR/DV"). Fail-open like the equivalent tvOS check: unknown/unprobed resolution or
    /// HDR state keeps the shorter, default threshold rather than withholding capture indefinitely.
    private func isCurrentContentUHDHDR() -> Bool {
        guard let player = coordinator.player else { return false }
        guard player.contentIsDolbyVision || player.hdrAvailable else { return false }
        let summary = player.mediaSummary()
        guard summary.width > 0, summary.height > 0 else { return false }
        return TVOSFramePresentationPolicy.isUltraHighDefinition(
            width: summary.width, height: summary.height)
    }

    private func invalidateLocalTrickplayCapture() {
        localTrickplayCaptureGeneration &+= 1
        localTrickplayCaptureInFlight = false
    }

    private func ownsLocalTrickplayCapture(_ generation: UInt64) -> Bool {
        localTrickplayCaptureInFlight
            && localTrickplayCaptureGeneration == generation
    }

    /// The one place a trickplay frame is grabbed (from either capture driver). Guards the in-flight flag,
    /// stamps the cadence, and logs each stage so a silent pool can be traced from a terminal run: which gate
    /// refused, whether captureFrameJPEGData returned nil (no output attached / protected frame), and whether
    /// the frame was recorded. Engine-agnostic: uses whatever `coordinator.player` is mounted.
    private func captureTrickplayFrame(at time: Double) {
        guard assetSanityAttempt.isAccepted(
            owner: coordinator.player?.activeLoadToken
        ) else { return }
        guard !localTrickplayCaptureInFlight else { return }
        guard let player = coordinator.player else { VXProbe.log("tp", "no player mounted at \(Int(time))s"); return }
        lastLocalTrickplayCapture = time
        localTrickplayCaptureGeneration &+= 1
        let captureGeneration = localTrickplayCaptureGeneration
        localTrickplayCaptureInFlight = true
        let engine = (player is AVPlayerEngineController) ? "avplayer" : "libmpv"
        // In-flight watchdog: the libmpv capture is serviced on mpv's VO thread inside nextDrawable(), which
        // only ticks while the layer is actively rendering. If the VO thread is momentarily idle the handler
        // may never fire, and without this the in-flight flag would wedge true forever (every later capture
        // silently skipped). Release it after 3s so the next tick can retry. Idempotent with the real handler.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                  self.ownsLocalTrickplayCapture(captureGeneration) else { return }
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
                    guard self.ownsLocalTrickplayCapture(captureGeneration) else { return }
                    self.localTrickplayCaptureInFlight = false
                    if self.localTrickplayCaptureBreaker.recordCapture(hadData: false) {
                        VXProbe.log("tp", "local capture breaker OPEN after 3 consecutive nil frames; preserving remote/community previews")
                    }
                    VXProbe.log("tp", "\(engine) captureFrameJPEGData returned NIL at \(Int(time))s (no video output / protected / not-ready)")
                }
                return
            }
            VXProbe.log("tp", "\(engine) captured \(data.count) bytes at \(Int(time))s")
            let decoded = ScrubThumbnailsStore.decodeCapturedFrame(data, at: time)   // heavy decode + black-check OFF main
            Task { @MainActor in
                watchdog.cancel()
                guard self.ownsLocalTrickplayCapture(captureGeneration) else { return }
                self.localTrickplayCaptureInFlight = false
                _ = self.localTrickplayCaptureBreaker.recordCapture(hadData: true)
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
                guard hasStartedPlaying else { continue }
                guard let player = coordinator.player else { continue }
                let now = player.playbackPositionSeconds
                let t = now > 0 ? now : currentTime
                maybeCaptureLocalTrickplay(at: t)
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

    /// A post-AV fallback must construct MPV with the source that is current at the handoff boundary.
    /// Loading the immutable launch tuple first can first-frame a previous source before a deferred correction.
    private var mpvSurfacePlayback: (url: URL, headers: [String: String]?, audioSidecar: URL?, live: Bool, isDolbyVision: Bool) {
        #if os(iOS) || os(macOS)
        let usesFallbackSource = avEngineFailed
        #else
        let usesFallbackSource = false
        #endif
        let activeURL = usesFallbackSource ? (curURL ?? url) : url
        let activeHeaders = usesFallbackSource ? curHeaders : headers
        let input = playback(for: activeURL, headers: activeHeaders)
        return (
            input.url,
            input.headers,
            activeURL == url ? audioSidecarURL : nil,
            usesFallbackSource ? isLive : initialIsLive,
            StreamRanking.isDolbyVision(usesFallbackSource ? (curHint ?? recordQualityText ?? "") : (recordQualityText ?? ""))
        )
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
                                resumeOrigin: Double? = nil,
                                preparedRemux: VortXPreparedRemuxAttachment? = nil,
                                expectedPreparedRemuxOwner: VortXPreparedRemuxOwnerIdentity? = nil) -> PlayerLoadToken? {
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
        // Real DV-profile evidence only ever survives from demoteAVPlayerToMPV's Coordinator handoff into a
        // FRESH mpv controller at makeController time, never through this function. Every load THIS
        // function issues targets an already-configured engine instance directly, so any evidence already
        // sitting on it belongs to a DIFFERENT prior source (or, in the demote-reissue race where curURL
        // changed underneath it, the WRONG url) and must not leak forward into this load.
        if let mpv = coordinator.player as? MPVMetalViewController {
            mpv.dolbyVisionFallbackInfo = .unknown
        }
        guard let player = coordinator.player else { return nil }
        clearCachedAudioOutputTruth()
        let requestedResumeOrigin = live ? 0 : (
            resumeOrigin ?? avSurfaceResumeOrigin ?? (hasStartedPlaying ? currentTime : resumeSeconds)
        )
        avSurfaceResumeOrigin = requestedResumeOrigin
        player.configureResumeOrigin(seconds: requestedResumeOrigin)
        // Configure on the exact mounted AVPlayer controller immediately before its existing load command.
        // Re-check the live external-engine setting here because it may have changed since halfway preload;
        // a rejection abandons the local transport exactly once and the unmodified load below cold-loads once.
        if let preparedRemux {
            let mountIsOnDevice: Bool
            if case .onDevice = VortXExternalEngine.shared.mountPlan {
                mountIsOnDevice = true
            } else {
                mountIsOnDevice = false
            }
            let admission = expectedPreparedRemuxOwner.map {
                VortXPreparedRemuxCallerPolicy.admission(
                    actualOwner: preparedRemux.ownerIdentity,
                    expectedOwner: $0,
                    avPlayerActive: player is AVPlayerEngineController,
                    mountIsOnDevice: mountIsOnDevice
                )
            } ?? .abandonAndColdLoad
            if admission == .configure,
               let avPlayer = player as? AVPlayerEngineController,
               let expectedPreparedRemuxOwner {
                _ = avPlayer.configurePreparedRemuxForNextLoad(
                    preparedRemux.handle,
                    ownerIdentity: expectedPreparedRemuxOwner
                )
            } else {
                preparedRemux.abandon(reason: "iOS admission owner or engine mismatch")
            }
        }
        let candidateToken = player.loadFile(
            p.url, headers: p.headers, live: live, audioSidecar: sidecar,
            reusing: loadToken
        )
        let issuedToken = candidateToken == player.activeLoadToken ? candidateToken : nil
        if let issuedToken {
            sourceSwitchGeneration &+= 1
            beginAssetSanityAttemptIfNeeded(
                loadToken: issuedToken,
                requestedResumeOrigin: requestedResumeOrigin
            )
        }
        if pendingAdvance != nil {
            pendingAdvance?.loadToken = issuedToken
            pendingAdvance?.issued = issuedToken != nil
            if let issuedToken {
                pendingAdvance?.terminal = false
                pendingAdvance?.deferredDuration = nil
                pendingAdvance?.deferredTrackList = false
                pendingAdvance?.deferredSeekable = nil
                supersededAdvance = nil
                admitEpisodeResolutionIfCurrent(loadToken: issuedToken)
            }
        } else if let issuedToken {
            committedLoadToken = issuedToken
        }
        return issuedToken
    }

    /// Capture the resume origin owned by the exact active load before replacing it. An unframed source hop or
    /// episode advance can differ from the immutable launch resume, while a started load resumes from its live
    /// clock. The persistence floor remains authoritative when a forward-only engine has not reached it yet.
    private func retryResumeTarget() -> Double {
        let activeLoadToken = coordinator.player?.activeLoadToken
        let activeRequestedResume = RetryResumeTargetPolicy.ownedRequestedResume(
            activeOwner: activeLoadToken,
            attemptOwner: assetSanityAttempt.owner,
            terminalRetiredOwner: terminalRetiredAssetSanityOwner,
            requestedResumeSeconds: assetSanityRequestedResume
        )
        return RetryResumeTargetPolicy.target(
            isLive: isLive,
            hasStartedPlaying: hasStartedPlaying,
            currentTimeSeconds: currentTime,
            // A MID-PLAY failure hands the ladder a load that had already reached the viewer's position, so the
            // position - not this load's origin - is what its retry must resume at (see midPlayFailureResume).
            // nil in every other case, which is every case that existed before, so the policy is unchanged there.
            activeRequestedResumeSeconds: midPlayFailureResume ?? activeRequestedResume,
            fallbackResumeSeconds: midPlayFailureResume ?? resumeSeconds,
            persistenceFloorSeconds: suppressedResumeFloor
        )
    }

    /// Every accepted same-source reload re-arms the generation-owned deferred seek. `resumeOrigin` alone is
    /// meaningful to the native remux lane; libmpv intentionally ignores configureResumeOrigin.
    @discardableResult
    private func loadRetryIntoPlayer(
        _ u: URL,
        headers: [String: String]?,
        live: Bool,
        resumeTarget: Double
    ) -> PlayerLoadToken? {
        guard let issuedToken = loadIntoPlayer(
            u, headers: headers, live: live, resumeOrigin: resumeTarget
        ) else { return nil }
        if !live && resumeTarget > 5 {
            nudgeResume(to: resumeTarget)
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
        guard let retryLoadToken = coordinator.player?.activeLoadToken else { return false }
        let retryResume = retryResumeTarget()
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
                  activeRef == ref, curURL == retryURL, currentStream == retrySource,
                  coordinator.player?.activeLoadToken == retryLoadToken else { return }
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
                let issuedToken = loadRetryIntoPlayer(
                    fresh, headers: curHeaders, live: isLive, resumeTarget: retryResume
                )
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

    /// MID-PLAY libmpv FAILURE (diag-21). This case used to only log "IGNORED": `handleLoadFailure` is gated on
    /// `!hasStartedPlaying`, and so are the start watchdog and the recovery deadline, so the only owner left was
    /// the stall watchdog - several frozen ticks before it reloaded, and it reloaded the same URL verbatim. A
    /// background-resume death, an expired debrid link mid-episode and a server that moved port all land here,
    /// and all of them have a real recovery behind `handleLoadFailure` (auto-retry -> same-source re-resolve ->
    /// failover hop -> fresh-sources wait). Preserve where the viewer was, clear the started flag so the ladder
    /// can admit, and hand it over.
    ///
    /// BOUNDED PER MOUNT by `midPlayRecoveryCount`, because `handleLoadFailure`'s own budgets cannot bound this
    /// lane: a retry that reaches even one frame clears `autoRetryCount` AND `recoveryDeadline` at first frame,
    /// so a source that frames for a tick and re-dies replenishes everything it just spent and loops at roughly
    /// a reload a second, forever. Past the cap the SOURCE is the problem rather than the load, so hop instead -
    /// bounded in turn by `sourceHops`, and ending on the error overlay.
    ///
    /// Live streams never reach here: their reconnect lane is owned by `scheduleReconnect` off the EOF path,
    /// and widening this into it is not the fix. Mirrors TVPlayerView.handleMidPlayFailure.
    private func handleMidPlayFailure(_ failureMessage: String, loadToken: PlayerLoadToken?) {
        // Once per load, and FAIL-CLOSED on a missing token: with no token this cannot tell a second error on
        // the same mount from a first one on a fresh mount, and doing nothing is exactly the pre-wave-1
        // behavior for a mid-play error, so the unprovable case costs no regression.
        guard let failureOwner = loadToken ?? coordinator.player?.activeLoadToken,
              midPlayFailureOwner != failureOwner else { return }
        midPlayFailureOwner = failureOwner
        // Park the play head BEFORE clearing the started flag: every lane below (`retryResumeTarget`,
        // `hopToNextSource`) reads the load's ORIGIN once `hasStartedPlaying` is false, which would restart
        // the episode from the beginning. See `midPlayFailureResume`.
        let resume = max(currentTime, suppressedResumeFloor ?? 0)
        midPlayRecoveryCount += 1
        midPlayFailureResume = resume
        hasStartedPlaying = false
        guard midPlayRecoveryCount <= maxMidPlayRecoveries else {
            DiagnosticsLog.log(
                "player",
                "mid-play failure x\(midPlayRecoveryCount) on one mount -> hop instead of another reload, at \(Int(resume))s"
            )
            srcProbe("mid-play failure budget spent (\(midPlayRecoveryCount)/\(maxMidPlayRecoveries)) -> hopToNextSource")
            loadErrorMsg = failureMessage
            reconnecting = false
            if !hopToNextSource(reason: "mid-play failure budget spent", resumeOverride: resume) {
                presentTerminalLoadFailure()
            }
            return
        }
        DiagnosticsLog.log(
            "player",
            "mid-play failure -> recovery ladder at \(Int(resume))s (\(midPlayRecoveryCount)/\(maxMidPlayRecoveries))"
        )
        srcProbe("mid-play endFileError -> handleLoadFailure reason=\(failureMessage.isEmpty ? "-" : failureMessage)")
        handleLoadFailure(failureMessage)
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
        #if os(iOS) || os(macOS)
        avToMPVHandoffBlocked = false
        #endif
        srcProbe("retryLoad reload-in-place (resetAutoRetries=\(resetAutoRetries)) host=\((curURL ?? url).host ?? "-")")
        let resume = retryResumeTarget()
        withAnimation { loadFailed = false }
        bufferedTime = 0   // reload: clear the buffered-ahead band so the buffer-grace watchdog re-baselines against the new fill, not the previous source's edge
        buffering = true; hasStartedPlaying = false; isSeekable = true; appliedSize = false; loadErrorMsg = ""
        subtitleLoadingURL = nil   // self-heal: a subtitle load stranded by the old engine must not gate the reload's picks
        srcProbeLoadStart = Date()   // [src-probe] a reload is a fresh attempt: re-anchor the elapsed clock
        curURL = liveMountURL()   // self-heal a drifted embedded-server port before replaying the mount
        loadRetryIntoPlayer(
            curURL ?? url, headers: curHeaders, live: isLive, resumeTarget: resume
        )
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
        deferredResumeAttempt.invalidate()
        TerminalLoadFailurePolicy.presentTerminal(
            retire: {
                guard TerminalLoadFailurePolicy.shouldRetireBeforePublish(
                    engineIsNative: coordinator.player is AVPlayerEngineController) else { return }
                if let activeLoadToken = coordinator.player?.activeLoadToken,
                   assetSanityAttempt.owner == activeLoadToken {
                    terminalRetiredAssetSanityOwner = activeLoadToken
                }
                srcProbe("terminal failure -> retiring AVPlayer engine BEFORE the overlay (option A)")
                coordinator.player?.stop()
            },
            publish: { withAnimation { loadFailed = true } }
        )
    }

    /// Fail (or hop) if playback never starts: covers hard hangs that don't even emit an error. The ordinary
    /// 30s budget; every caller uses this one except the post-demote mpv leg.
    private func startLoadTimeout() { startLoadTimeout(seconds: 30) }

    /// `seconds` is the ordinary 30s budget for every caller except the post-demote mpv leg, which passes the
    /// shorter `avPostDemoteStartTimeoutSeconds` (W2-A item 3b). Nothing else about the timer changes.
    private func startLoadTimeout(seconds: Double) {
        loadTimeout?.cancel()
        startRecoveryDeadline()   // arms the overall pre-start cap once; later hops leave it running
        #if os(iOS) || os(macOS)
        startAVStartWatchdog()    // AVPlayer-only fast, silent, in-place demote to libmpv when it mounts but never frames
        #endif
        lastBufferedAtWatchdog = bufferedTime   // snapshot the buffered edge so the fire path can tell if bytes moved
        srcProbe("start-watchdog ARMED (\(Int(seconds))s) bufferedEdge=\(String(format: "%.1f", bufferedTime))")
        loadTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
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
        if let recovery = directAVNoFrameRecovery,
           recovery.url == (curURL ?? url),
           recovery.episodeGeneration == episodeSwitchGeneration,
           recovery.sourceGeneration == sourceSwitchGeneration,
           recovery.resumeGeneration == resumeRetryGeneration,
           recovery.mpvLoadToken == coordinator.player?.activeLoadToken,
           !isAVPlayerActive,
           !hasStartedPlaying {
            directAVNoFrameRecovery = nil
            DiagnosticsLog.log("playback", "source attempt route=libmpv-after-avplayer attempt=\(recovery.attemptID) outcome=no-first-frame")
            if currentPickWasExplicit {
                loadErrorMsg = "This source didn't produce playable media. Choose another source."
                presentTerminalLoadFailure()
                return
            }
            if currentPlaybackIsResume, !resumeSourceReresolved,
               retryResumeSameSource() { return }
            if hopToNextSource(reason: "direct AVPlayer and libmpv produced no frame") { return }
            if loadErrorMsg.isEmpty { loadErrorMsg = "This source did not produce playable media." }
            presentTerminalLoadFailure()
            return
        }
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

    /// The URL to (re)mount for the CURRENTLY playing source. Normally that is exactly what is already
    /// loaded - but a loopback mount can go stale WITHOUT the source changing: the in-process engine server is
    /// stopped on background and rebinds a FRESH ephemeral port on every foreground start, while
    /// `CoreStream.playableURL` builds its loopback URL from `StremioServer.base` AT CALL TIME. After one
    /// background cycle the stored `curURL` therefore names a port nothing is listening on, and every reload
    /// path that replayed it verbatim re-failed forever (diag-21). Re-deriving here self-heals that.
    ///
    /// Deliberately narrow, and FAIL-OPEN in every other case (MIS-260731-03 - a control that cannot prove its
    /// precondition must fall through to today's behavior, never to a new dead end):
    ///  - `StremioServer.isCustom` means the viewer pointed the app at their own remote server; its base must
    ///    never be rewritten under a playing stream.
    ///  - Both the current and the re-derived URL must be loopback AND share the same path, so this can only
    ///    ever move the AUTHORITY of one identical route. A header-gated stream keeps its raw URL in `curURL`
    ///    (`loadIntoPlayer` re-derives the `/proxy/` wrapper through `playback(for:)` on every load, so that
    ///    lane already self-heals), and swapping a proxied URL for a raw one here would strip the server-side
    ///    header injection.
    /// Returns `curURL` untouched (nil included) whenever it cannot prove a better mount, so callers keep their
    /// existing `curURL ?? url` shape and no control flow changes. Mirrors TVPlayerView.liveMountURL.
    private func liveMountURL() -> URL? {
        guard let current = curURL, !StremioServer.isCustom, isLoopback(current),
              let stream = currentStream,
              let derived = playableURL(for: stream),
              isLoopback(derived), derived != current,
              derived.path == current.path else { return curURL }
        // Exported, not just NSLog'd: `srcProbe` never reaches a diagnostics export, and this line is the one
        // that says the heal fired at all. No raw identifiers (G5) - the shape, never the URL.
        DiagnosticsLog.log("player", "mount re-derived: the embedded server moved port under the playing source")
        srcProbe("mount re-derived: the embedded server moved port under the playing source")
        return derived
    }

    /// A URL served by this device's own streaming server. Host-based, NOT port-based: the port is exactly
    /// what drifts across a background cycle, so comparing it is what went stale in the first place.
    private func isLoopback(_ u: URL) -> Bool {
        guard let host = u.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    #if canImport(UIKit)
    /// FOREGROUND MOUNT REVALIDATION (diag-21). The player is deliberately NOT torn down on background, so the
    /// same engine stays mounted across a suspension - but what it is mounted ON can die underneath it: the
    /// embedded server restarts on a fresh port, and a debrid link expires. Nothing revalidated either, so the
    /// dead mount only surfaced through the stall watchdog, which then replayed the SAME dead URL verbatim and
    /// looped. Heal it here instead, before the mpv seam's `enterForeground` play() hits a dead socket.
    ///
    /// This is a re-mount of the SAME source, never a failover: `sourceHops` and `exhaustedURLs` stay untouched,
    /// so it neither claims a source failed nor burns the hop budget the viewer needs for one that really did.
    /// Every branch that cannot prove a better mount returns and leaves exactly today's behavior in place
    /// (MIS-260731-03). Mirrors TVPlayerView.revalidateMountOnForeground; macOS never suspends, so it is not
    /// wired there (same reason the foreground reconcile is UIKit-only).
    private func revalidateMountOnForeground(suspendedFor seconds: TimeInterval,
                                             playHeadAtSuspension stamp: Double?) {
        guard hasStartedPlaying, !loadFailed, !playbackExited, pendingAdvance == nil else { return }
        // DEMONSTRABLY HEALTHY playback is left alone. `keepPlayingInBackground` defaults ON, so the audio
        // really does keep running while backgrounded, and a play head that MOVED across the suspension proves
        // the mount survived it. Re-minting a live debrid link then costs the viewer a reload plus a re-seek of
        // a stream that was fine, and it is what made the double-recovery race routine (the in-flight
        // re-resolve the identity guard silently drops). Every signal must agree, and with no stamp nothing is
        // proven, so the unprovable case keeps the revalidation below exactly as it is (MIS-260731-03).
        if let stamp, !isPaused, !buffering, !reconnecting,
           currentTime - stamp >= healthyForegroundProgressSeconds {
            DiagnosticsLog.log(
                "player",
                "foreground: playback kept running across the \(Int(seconds))s suspension (+\(Int(currentTime - stamp))s), mount left alone"
            )
            return
        }
        if let ref = curDebridRef, !ref.infoHash.isEmpty {
            guard seconds >= mountRevalidationSuspensionSeconds else { return }
            // `retryResumeSameSource()` already targets the play head through `retryResumeTarget()` (which
            // folds in `hasStartedPlaying`, `currentTime` and the suppressed-resume floor), so unlike the tvOS
            // twin nothing has to be moved before the call.
            resumeSourceReresolved = false   // one re-resolve per suspension, not one per playback
            if retryResumeSameSource() {
                DiagnosticsLog.log("player", "foreground: re-resolving the debrid mount after \(Int(seconds))s suspended")
                srcProbe("foreground: re-resolving the debrid mount after \(Int(seconds))s suspended")
            }
            return
        }
        healLoopbackMountOnForeground(allowRecheck: true)
    }

    /// The loopback half of the foreground revalidation, split out so the ONE delayed re-check below can re-run
    /// exactly it and nothing else.
    ///
    /// The re-check is what makes this lane reachable at all: `VortxNativeServer.stopOnBackground()` clears
    /// `publishedPort`, and the restart happens at scenePhase `.active`, which lands AFTER
    /// `willEnterForeground`. At first call `StremioServer.base` therefore still names the dead port, so the
    /// re-derived URL is either nil or identical to the stale one and the heal proves nothing. One re-check
    /// past the restart sees the republished port. Bounded to a single re-arm per foreground - a watcher, not
    /// a poll - and every path still returns to today's behavior when it cannot prove a better mount.
    private func healLoopbackMountOnForeground(allowRecheck: Bool) {
        guard hasStartedPlaying, !loadFailed, !playbackExited, pendingAdvance == nil else { return }
        guard let healed = liveMountURL(), healed != curURL else {
            guard allowRecheck, !foregroundMountRecheckArmed else { return }
            foregroundMountRecheckArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + foregroundMountRecheckDelay) {
                healLoopbackMountOnForeground(allowRecheck: false)
            }
            return
        }
        DiagnosticsLog.log("player", "foreground: embedded server moved port, re-mounting the same source in place")
        srcProbe("foreground: embedded server moved port, re-mounting the same source in place")
        curURL = healed
        let resume = retryResumeTarget()
        reconnectMsg = "Recovering…"
        withAnimation { reconnecting = true }
        // Preserve an explicit in-session subtitle pick across the re-mount, the same way switchPlayerEngine
        // does for an engine switch. The reload drops external subtitle tracks and resets the embedded
        // selection, but `appliedAutoTracks` stayed set here, so nothing re-selected anything and the viewer's
        // subtitles silently vanished on every port-move re-mount. Re-arm the latch ONLY when there is a pick to
        // restore, so a mount with no explicit choice keeps exactly today's behavior.
        pendingSubtitleReapply = userPickedSubtitle ? captureSubtitleChoice() : nil
        if pendingSubtitleReapply != nil { appliedAutoTracks = false }
        appliedSize = false; hasStartedPlaying = false; isSeekable = true; buffering = true
        srcProbeLoadStart = Date()
        let issuedToken = loadRetryIntoPlayer(
            curURL ?? url, headers: curHeaders, live: isLive, resumeTarget: resume
        )
        // Arm the watchdog ONLY for a load the engine actually took. A refused load leaves the OLD mount in
        // place, and the cleared flags above would then strand the viewer on a spinner nothing owns: no
        // watchdog, `hasStartedPlaying` false so no tick clears it, and `reconnecting` true forever. Put the
        // playing state back instead and let the stall watchdog - the owner this whole lane exists to pre-empt -
        // have it, which is exactly today's behavior (MIS-260731-03). `curURL` deliberately keeps the healed
        // value: the old port is provably dead, so the next reload down any path should use the re-derived one.
        guard issuedToken != nil else {
            DiagnosticsLog.log("player", "foreground re-mount was not issued; restoring the playing state")
            srcProbe("foreground re-mount NOT ISSUED -> restoring hasStartedPlaying/buffering/reconnecting")
            hasStartedPlaying = true
            buffering = false
            reconnecting = false
            // The OLD mount is still live and still carries the viewer's pick, so drop the snapshot and put the
            // latch back: re-applying it would re-add an external subtitle that was never removed.
            if pendingSubtitleReapply != nil { appliedAutoTracks = true }
            pendingSubtitleReapply = nil
            return
        }
        // The load was issued, so this is a FRESH mount that carries no external subtitles: drop the added-set
        // tracking so the picker is honest and the reapply above can re-add cleanly (same clear, same reason, as
        // switchPlayerEngine). Deliberately after the guard - the refused-load branch keeps the OLD mount alive,
        // and its rows are still real.
        addedSubURLs = []; addedPooledIDs = []
        startLoadTimeout()
    }
    #endif

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

    /// Safety net for the DEFERRED resume seek issued at first frame (the warm-pipeline scrub). On a slow or
    /// non-Range source that absolute seek can leave mpv parked at the pre-seek position indefinitely; the
    /// plain stall ladder then reloads at the real (low) playhead and silently drops the viewer's resume
    /// point. If the seek has not landed within 12s, abandon the offset instead: a relative +0.1s nudge (the
    /// proven wedge release) resumes playback from wherever the source actually is, and the floor armed at
    /// issuance keeps the stored Continue Watching position from regressing.
    private func armPostFrameResumeSeekWatchdog(target: Double) {
        postFrameResumeSeekWatchdog?.cancel()
        let armedToken = coordinator.player?.activeLoadToken
        postFrameResumeSeekWatchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(postFrameResumeSeekWatchdogSeconds))
            guard !Task.isCancelled,
                  coordinator.player?.activeLoadToken == armedToken,
                  target - currentTime > 5 else { return }
            DiagnosticsLog.log(
                "playback",
                String(format: "deferred resume seek did not land in %ds (real pos %.1f): abandoning the offset and playing from the current position",
                       Int(postFrameResumeSeekWatchdogSeconds), currentTime)
            )
            pendingLibmpvResumeSeek = nil
            coordinator.player?.seek(by: 0.1)
        }
    }

    /// Watch for a hard stall after playback has started. Both a silent frozen surface and visible buffering
    /// need a bounded recovery owner. Buffering gets a longer allowance so an ordinary short network pause is
    /// not mistaken for a wedged player. Disabled for live, whose reconnect path owns recovery separately.
    private func startStallWatchdog() {
        stallWatchdog?.cancel()
        lastObservedTime = -1; stalledTicks = 0; stallStableProgressTicks = 0
        stallWatchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(PlayerMidPlaybackStallPolicy.pollIntervalSeconds)
                )
                guard PlayerMidPlaybackStallPolicy.shouldObserve(
                    hasStartedPlaying: hasStartedPlaying,
                    isPaused: isPaused,
                    loadFailed: loadFailed,
                    isLive: isLive,
                    duration: duration,
                    buffering: buffering
                ) else {
                    lastObservedTime = -1
                    stalledTicks = 0
                    stallStableProgressTicks = 0
                    continue
                }
                if lastObservedTime < 0 {
                    stalledTicks = 0
                    stallStableProgressTicks = 0
                } else if abs(currentTime - lastObservedTime) < 0.25 {
                    stallStableProgressTicks = 0
                    stalledTicks += 1
                    if stalledTicks >= PlayerMidPlaybackStallPolicy.recoveryTickThreshold(
                        buffering: buffering
                    ) {
                        stalledTicks = 0
                        recoverFromStall()
                    }
                } else {
                    stalledTicks = 0
                    stallStableProgressTicks += 1
                    if PlayerMidPlaybackStallPolicy.shouldResetRecoveryBudget(
                        recoveries: stallRecoveries,
                        stableProgressTicks: stallStableProgressTicks
                    ) {
                        stallRecoveries = 0
                        stallStableProgressTicks = 0
                    }
                }
                lastObservedTime = currentTime
            }
        }
    }

    private func recoverFromStall() {
        let recoveryToken = coordinator.player is AVPlayerEngineController
            ? coordinator.player?.activeLoadToken : nil
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
        stallStableProgressTicks = 0
        reconnectMsg = "Recovering…"
        srcProbe("OVERLAY SET (spinner): recoverFromStall reconnect='Recovering…' reload-in-place (NOT error)")
        withAnimation { reconnecting = true }
        // Resume where it froze: reload in place, the seek lands once duration is known again.
        let resume = currentTime
        appliedSize = false; hasStartedPlaying = false; isSeekable = true; buffering = true
        // The stalled mount already had a first frame; this reload earns its own. Without clearing it,
        // elapsedSinceFirstFrame (the playback-diagnostics receipt) keeps measuring from the ORIGINAL,
        // now-stale first frame across the reload instead of the fresh one this recovery is about to render.
        firstFrameRenderedAt = nil; pendingLibmpvResumeSeek = nil   // fresh mount: no deferred resume seek from the outgoing mount
        postFrameResumeSeekWatchdog?.cancel(); postFrameResumeSeekWatchdog = nil
        curURL = liveMountURL()   // self-heal a drifted embedded-server port before replaying the mount
        let issuedToken = loadIntoPlayer(
            curURL ?? url, headers: curHeaders, live: isLive,
            reusing: recoveryToken, resumeOrigin: resume
        )
        if issuedToken != nil { startLoadTimeout() }
        if issuedToken != nil, resume > 5 {
            nudgeResume(to: resume)
        }
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
        // Consume the one-shot dead-input evidence FIRST, so it can never leak into a later demote.
        // See `demoteFollowedDeadInput`.
        let followedDeadInput = demoteFollowedDeadInput
        demoteFollowedDeadInput = false
        srcProbe("demoteAVPlayerToMPV (AVPlayer -> libmpv, SAME url, silent=\(silent), NOT a hop)")
        guard let retiringAVPlayer = coordinator.player as? AVPlayerEngineController else { return }
        resumeRetryGeneration &+= 1
        let reissueEpisodeGeneration = episodeSwitchGeneration
        let reissueSourceGeneration = sourceSwitchGeneration
        let reissueMediaGeneration = resumeRetryGeneration
        if !hasStartedPlaying {
            directAVNoFrameRecovery = DirectAVNoFrameRecovery(
                url: curURL ?? url,
                episodeGeneration: reissueEpisodeGeneration,
                sourceGeneration: reissueSourceGeneration,
                resumeGeneration: reissueMediaGeneration,
                attemptID: UUID().uuidString,
                mpvLoadToken: nil)
        }
        let directFallbackAttempt = directAVNoFrameRecovery?.attemptID
        avStartWatchdog?.cancel(); avStartWatchdog = nil
        // This timer belongs to the retiring AV load token.  It must not fire while teardown is proving the
        // old producer quiescent and misclassify the replacement MPV mount as a third attempt.
        loadTimeout?.cancel(); loadTimeout = nil
        let engineRequestedResume =
            retiringAVPlayer.pendingRequestedSourcePositionSeconds
        // Real DV-profile evidence from the outgoing AVPlayer's own remux parse (#148), captured for the
        // SAME reason as engineRequestedResume above: stop() below tears the remux session down, so this
        // MUST read before it. Feeds the fresh mpv mount's pre-probe colour fallback via the Coordinator
        // (MPVMetalPlayerView.makeController copies it onto the new controller).
        coordinator.dolbyVisionFallbackInfo =
            retiringAVPlayer.dolbyVisionFallbackInfo
        // Engine of origin for the `avDemotedAt` grace (W2-A item 3a; tvOS twin in TVPlayerView). Captured
        // BEFORE stop() clears the engine's active token: this is the exact load the grace exists to swallow.
        demotedEngineLoadToken = retiringAVPlayer.activeLoadToken
        // The next-episode prep is scoped to the TARGET episode's owner identity, not the engine surface
        // (Beta 26 C1, F7). An AV-to-mpv demote is a same-stream DV fallback, so the prewarmed next episode
        // must survive it; `PreparedEpisodeRetentionPolicy` still rejects a genuinely stale prep by episode id.
        let quiescence = retiringAVPlayer.stopForMPVFallback()
        clearCachedAudioOutputTruth()
        // An engine-owned target is a newer explicit seek and is authoritative in BOTH directions. In
        // particular, a backward MediaRemote, chapter, or skip seek from 3600s to 600s must not be replaced by
        // the stale 3600s chrome clock. Retire the old anti-regression floor first; nudgeResume arms a new floor
        // for this exact target while libmpv is mounting. With no engine transaction, keep the existing floor
        // behavior for a remux that had to restart near zero.
        let resume: Double
        if let engineRequestedResume {
            suppressedResumeFloor = nil
            resume = engineRequestedResume
        } else if hasStartedPlaying {
            resume = max(currentTime, suppressedResumeFloor ?? 0)
        } else {
            resume = max(resumeSeconds, suppressedResumeFloor ?? 0)
        }
        let handoff = AVToMPVHandoff(
            url: curURL ?? url,
            episodeGeneration: reissueEpisodeGeneration,
            sourceGeneration: reissueSourceGeneration,
            resumeGeneration: reissueMediaGeneration
        )
        avToMPVHandoff = handoff
        avToMPVHandoffTask?.cancel()
        avToMPVHandoffTask = Task { @MainActor in
            let quiescent = await quiescence.wait(timeout: .seconds(2))
            guard !Task.isCancelled,
                  avToMPVHandoff == handoff,
                  handoff.episodeGeneration == episodeSwitchGeneration,
                  handoff.sourceGeneration == sourceSwitchGeneration,
                  handoff.resumeGeneration == resumeRetryGeneration,
                  handoff.url == (curURL ?? url) else { return }
            guard VortXRemuxHandoffPolicy.canMountMPV(
                routeStillCurrent: true,
                producerQuiescent: quiescent
            ) else {
                avToMPVHandoff = nil
                avToMPVHandoffBlocked = true
                loadErrorMsg = "Playback cleanup did not complete. Try another source."
                presentTerminalLoadFailure()
                return
            }
            // The replacement view receives the live tuple before controller creation; only then may MPV own
            // a new load token and its first-frame watchdog.
            appliedSize = false; appliedVolume = false; hasStartedPlaying = false; isSeekable = true
            buffering = true; loadFailed = false; loadErrorMsg = ""
            firstFrameRenderedAt = nil; pendingLibmpvResumeSeek = nil
            postFrameResumeSeekWatchdog?.cancel(); postFrameResumeSeekWatchdog = nil
            subtitleLoadingURL = nil
            srcProbeLoadStart = Date()
            bufferGraceUsed = 0; lastBufferedAtWatchdog = -1; bufferedTime = 0
            avToMPVHandoff = nil
            avEngineFailed = true
            avDemotedAt = Date()
            if !silent, StreamRanking.isDolbyVision(recordQualityText ?? "") {
                showEngineNotice("Dolby Vision isn't supported for this file. Playing HDR10 instead.")
            }
            let mounted = await awaitReplacementMPVMount(for: handoff)
            guard !Task.isCancelled,
                  let mpv = mounted?.controller,
                  mpv.activeLoadToken == mounted?.token else { return }
            if let recovery = directAVNoFrameRecovery,
               recovery.url == handoff.url,
               recovery.episodeGeneration == handoff.episodeGeneration,
               recovery.sourceGeneration == handoff.sourceGeneration,
               recovery.resumeGeneration == handoff.resumeGeneration {
                directAVNoFrameRecovery = DirectAVNoFrameRecovery(
                    url: recovery.url,
                    episodeGeneration: recovery.episodeGeneration,
                    sourceGeneration: recovery.sourceGeneration,
                    resumeGeneration: recovery.resumeGeneration,
                    attemptID: recovery.attemptID,
                    mpvLoadToken: mounted?.token)
            }
            DiagnosticsLog.log(
                "playback",
                "fallback attempt=\(directFallbackAttempt ?? "mid-play") stage=mpv-load outcome=issued")
            if followedDeadInput {
                startLoadTimeout(seconds: avPostDemoteStartTimeoutSeconds)
            } else {
                startLoadTimeout()
            }
            if resume > 5 { nudgeResume(to: resume) }
        }
    }

    private func awaitReplacementMPVMount(
        for handoff: AVToMPVHandoff
    ) async -> (controller: MPVMetalViewController, token: PlayerLoadToken)? {
        let deadline = ContinuousClock.now + .seconds(2)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            guard !playbackExited,
                  avToMPVHandoff == nil,
                  !avToMPVHandoffBlocked,
                  handoff.episodeGeneration == episodeSwitchGeneration,
                  handoff.sourceGeneration == sourceSwitchGeneration,
                  handoff.resumeGeneration == resumeRetryGeneration,
                  handoff.url == (curURL ?? url) else { return nil }
            if let controller = coordinator.player as? MPVMetalViewController,
               let token = controller.activeLoadToken {
                return (controller, token)
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        avToMPVHandoffBlocked = true
        loadErrorMsg = "The replacement player did not start."
        presentTerminalLoadFailure()
        return nil
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
        // A manual AV→MPV pick is the same physical handoff as automatic recovery.  Going through the shared
        // transaction preserves the live URL/generations and refuses to mount MPV until every producer stops.
        if !toAVPlayer, coordinator.player is AVPlayerEngineController {
            demoteAVPlayerToMPV(silent: true)
            close()
            return
        }
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
        // Engine of origin for the grace below (W2-A item 3a). Captured before stop() clears it, for WHICHEVER
        // engine is outgoing here: a stale token from an earlier demote would make the grace treat this switch's
        // own stale error as "from the incoming engine" and stop swallowing it.
        demotedEngineLoadToken = coordinator.player?.activeLoadToken
        coordinator.player?.stop()          // straddle invariant: old engine fully down before the surface swap
        clearCachedAudioOutputTruth()
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
        // Mirrors demoteAVPlayerToMPV: the outgoing engine's first frame belongs to a mount this session is
        // leaving, so elapsedSinceFirstFrame must not keep measuring from it once the new engine mounts.
        firstFrameRenderedAt = nil; pendingLibmpvResumeSeek = nil   // fresh mount: no deferred resume seek from the outgoing mount
        postFrameResumeSeekWatchdog?.cancel(); postFrameResumeSeekWatchdog = nil
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
        // Re-apply speed once the new engine's controller is mounted (next render).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard manualEngineAVPlayer == toAVPlayer, !Task.isCancelled,
                  reissueEpisodeGeneration == episodeSwitchGeneration,
                  reissueMediaGeneration == resumeRetryGeneration,
                  reissuePendingVideoID == pendingAdvance?.meta.videoId else { return }
            if abs(speed - 1.0) > 0.01 { coordinator.player?.setSpeed(speed) }
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
                            // Input liveness is progress too: during avformat_open_input (a 10s rw_timeout) plus
                            // find_stream_info nothing has been MUXED yet, so the output counters above all sit
                            // at zero while the source is still legitimately opening. Count growing input bytes
                            // so a slow-but-alive open does not accrue the stall window and get demoted blind.
                            || ((cur.inputBytesRead ?? 0) > (prev.inputBytesRead ?? 0))
                    } ?? true
                    if progressed, !cur.failed { lastProgressAt = now }
                    last = cur
                }
                let elapsed = now.timeIntervalSince(armed)
                let stalled = now.timeIntervalSince(lastProgressAt)
                // W2-A: the input-side receipts ride the same line as the output counters, so the exportable
                // trail shows WHY a stall was called dead (or not) instead of only that it was called.
                let inBytes: String = {
                    guard let bytes = last.flatMap({ $0.inputBytesRead }) else { return "-" }
                    return "\(bytes)"
                }()
                let state = "produced=\(last?.producedBytes ?? -1)B segs=\(last?.segmentCount ?? -1) init=\(last?.initPublished ?? false) classify=\(last?.signalingPublished ?? false) failed=\(last?.failed ?? false) inBytes=\(inBytes) inOpen=\(last?.inputOpened ?? false) inOpening=\(last?.inputOpenInFlight ?? false)"
                // A stall while an input open is still in flight is not a true stall: the source is legitimately
                // blocked inside avformat_open_input / find_stream_info and has produced no output yet. Do not
                // demote on that; the hard ceiling below still bounds a source that stays inOpening forever, so
                // a genuinely dead source always fails soft to libmpv eventually.
                let trueStall = stalled >= avRemuxStallDemoteSeconds && !(last?.inputOpenInFlight ?? false)
                if trueStall || elapsed >= avRemuxStartHardCeilingSeconds {
                    let why = trueStall
                        ? "TRUE STALL, no remux progress for \(Int(stalled))s"
                        : "hard ceiling \(Int(avRemuxStartHardCeilingSeconds))s with no playable frame"
                    // W2-A item 2 (tvOS twin in TVPlayerView.startAVStartWatchdog): a demote re-loads the SAME
                    // url on libmpv, which cannot help when the shared upstream fetch delivered nothing at all.
                    // Branch to a SOURCE-level failure ONLY on the positively-evidenced dead-input case; any
                    // input byte, a completed open, an open attempt still in flight, or a delivery with no input
                    // receipts keeps today's demote (MIS-260731-03: any doubt fails open, and a hop is strictly
                    // more destructive - it spends a source hop, exhausts the url and books a provider penalty,
                    // all of which hopToNextSource already owns as the single failure choke point).
                    let inputDead = stalled >= avRemuxStallDemoteSeconds && last?.inputProvablyDead == true
                    if inputDead {
                        DiagnosticsLog.log(
                            "dv",
                            "remux input dead (no input bytes, no open, none in flight) -> source hop instead of "
                                + "an engine demote (\(state))")
                        if hopToNextSource(reason: "remux input dead") { return }
                        DiagnosticsLog.log(
                            "dv",
                            "remux input dead but no source hop was issued; falling back to the engine demote")
                    }
                    NSLog("%@", "[Player] AVPlayer start watchdog demoting (remux mounted=true, \(why), elapsed=\(Int(elapsed))s, \(state)), demoting to libmpv in place")
                    srcProbe("AV start-watchdog FIRED (remux, \(why)) -> silent demote to libmpv")
                    DiagnosticsLog.log("dv", "remux demoted: \(why) -> libmpv HDR10")
                    // Carry the dead-input verdict INTO the demote: only a leg whose upstream provably delivered
                    // nothing pays the shortened post-demote budget (this is the hop-was-refused fallback, so the
                    // same url is about to be handed to libmpv). Every other demote keeps the full 30s.
                    demoteFollowedDeadInput = inputDead
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
    @State private var deferredResumeAttempt = DeferredResumeAttempt()
    private func nudgeResume(to seconds: Double) {
        let ticket = deferredResumeAttempt.begin(targetSeconds: seconds)
        if let floor = DeferredResumeFloorPolicy.armedFloor(
            targetSeconds: ticket.targetSeconds
        ) {
            suppressedResumeFloor = max(suppressedResumeFloor ?? 0, floor)
            lastReported = max(lastReported, suppressedResumeFloor ?? floor)
        }
        Task { @MainActor in
            for _ in 0..<DeferredResumePolicy.maximumPollCount {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, deferredResumeAttempt.owns(ticket) else { return }
                if let av = coordinator.player as? AVPlayerEngineController, av.isRemuxMounted {
                    guard let origin = av.achievedRemuxTimelineOriginSeconds else { continue }
                    // A5 mirror: a carried head at or past this asset's own duration is out of range for THIS
                    // stream (a wrong or much shorter replacement), so start from the beginning rather than land
                    // at the tail; A5b's sanity policy routes a true decoy to a working source. Clamp otherwise
                    // to 5s from the end. Only clamp once a real duration is known so an unknown-duration mount
                    // fails open.
                    if duration > 0, ticket.targetSeconds >= duration {
                        suppressedResumeFloor = nil
                        currentTime = 0
                        lastReported = 0
                        _ = deferredResumeAttempt.complete(ticket)
                        return
                    }
                    switch RemuxResumePolicy.preStartSeek(
                        target: ticket.targetSeconds, origin: origin
                    ) {
                    case .satisfied:
                        suppressedResumeFloor = nil
                        let landed = duration > 0 ? min(max(0, origin), max(0, duration - 5)) : max(0, origin)
                        currentTime = landed
                        lastReported = landed
                    case .hidePreroll:
                        // AVPlayerEngine issues the actual corrective local seek (root-cause report section 7,
                        // "apply to resume + stall-recovery remounts too" - this IS the stall-recovery remount
                        // path); this is only the UI/progress bookkeeping. Once that seek lands, the viewer
                        // sees `ticket.targetSeconds`, not `origin`, so report that here too.
                        suppressedResumeFloor = nil
                        let landed = duration > 0
                            ? min(max(0, ticket.targetSeconds), max(0, duration - 5))
                            : max(0, ticket.targetSeconds)
                        currentTime = landed
                        lastReported = landed
                    case .unreachable:
                        let floor = duration > 0
                            ? min(max(0, ticket.targetSeconds), max(0, duration - 5))
                            : max(0, ticket.targetSeconds)
                        suppressedResumeFloor = floor
                        lastReported = floor
                        showEngineNotice("That resume point is unavailable for this source. Playing from the earliest available position.")
                    }
                    _ = deferredResumeAttempt.complete(ticket)
                    return
                }
                let decision = DeferredResumePolicy.decision(
                    targetSeconds: ticket.targetSeconds,
                    observedDurationSeconds: duration,
                    engineDurationSeconds: coordinator.player?.mediaDurationSeconds() ?? 0,
                    deadlineReached: false
                )
                switch decision {
                case .wait:
                    continue
                case .seek(let target):
                    // A pre-first-frame absolute seek on a cold libmpv pipeline arms mpv's cache-emptying hold
                    // and wedges video output (blank + frozen timer); defer it to the first-frame commit so it
                    // lands as an ordinary warm scrub, which is proven to render. A mid-play nudge (a stall or
                    // source-switch reload after the first frame) is already warm, so it seeks immediately.
                    if hasStartedPlaying {
                        coordinator.player?.seek(to: target)
                    } else {
                        pendingLibmpvResumeSeek = target
                    }
                    currentTime = target
                case .clear:
                    break
                }
                let ownedFloor = suppressedResumeFloor == ticket.targetSeconds
                suppressedResumeFloor = DeferredResumeFloorPolicy.floorAfterDecision(
                    currentFloor: suppressedResumeFloor,
                    targetSeconds: ticket.targetSeconds,
                    decision: decision
                )
                if decision == .clear, ownedFloor {
                    lastReported = currentTime
                }
                _ = deferredResumeAttempt.complete(ticket)
                return
            }
            guard deferredResumeAttempt.owns(ticket),
                  DeferredResumePolicy.decision(
                    targetSeconds: ticket.targetSeconds,
                    observedDurationSeconds: duration,
                    engineDurationSeconds: coordinator.player?.mediaDurationSeconds() ?? 0,
                    deadlineReached: true
                  ) == .clear else { return }
            let ownedFloor = suppressedResumeFloor == ticket.targetSeconds
            suppressedResumeFloor = DeferredResumeFloorPolicy.floorAfterDecision(
                currentFloor: suppressedResumeFloor,
                targetSeconds: ticket.targetSeconds,
                decision: .clear
            )
            if ownedFloor {
                lastReported = currentTime
            }
            _ = deferredResumeAttempt.complete(ticket)
        }
    }

    /// The pinned source for this title (#15), so failover keeps hopping to the pinned provider/quality
    /// when one is available, and falls back to plain ranking once it is exhausted.
    private var sourcePin: ResolvedPin? {
        guard let m = recordMeta else { return nil }
        return SourcePinStore.shared.effectivePin(SourcePinContext(metaId: m.libraryId, isSeries: m.type == "series"))
    }

    /// The key a remembered manual source pick is stored and looked up under (`SeriesSourceSticky`). It is the
    /// SAME identity `sourcePin` above uses - `libraryId`, the SHOW's id, which every episode of a series shares
    /// (the per-episode identity is `videoId`, which would give a "sticky" that reset every episode and defeat
    /// the whole point). Series only: the durable per-show memory is what the binge loop needs, and keying
    /// movies here would spend the store's per-profile cap on titles that never get a next episode.
    /// Mirrors TVPlayerView.seriesStickyKey (which reads `curMeta ?? meta`, the same launch/live pair that
    /// `sourcePin` reads on each surface).
    private var seriesStickyKey: String? {
        guard let m = curMeta, m.type == "series" else { return nil }
        return m.libraryId
    }

    /// The remembered manual pick for this show, in the shape `StreamRanking.best` / `rankedCandidates` take.
    private var seriesSticky: (addon: String?, bingeGroup: String?)? {
        seriesStickyKey.flatMap { SeriesSourceSticky.preference(for: $0) }
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
            if let hit = StreamRanking.best(capped, continuity: recordQualityText, binge: nil, pin: sourcePin,
                                            sticky: seriesSticky,
                                            providerPenalty: { ProviderHealth.penaltyActive(addonName: $0) }) {
                return hit
            }
        }
        return StreamRanking.best(remaining, continuity: recordQualityText, binge: nil, pin: sourcePin,
                                  sticky: seriesSticky,
                                  providerPenalty: { ProviderHealth.penaltyActive(addonName: $0) })
    }

    /// The playing source is dead (retry / stall budget ran out): mark it exhausted and hop to the
    /// next-best untried source automatically. Returns false when the hop budget is spent or nothing
    /// untried remains; the caller then shows the error overlay. Mirrors tvOS `hopToNextSource`.
    @discardableResult
    private func hopToNextSource(
        reason: String,
        resumeOverride: Double? = nil,
        allowBeyondFailureBudget: Bool = false
    ) -> Bool {
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
        // The playing source is being abandoned for FAILURE, whatever the caller's reason: this is the one
        // choke point every failure lane funnels through. Remember the PROVIDER, not just the URL:
        // `exhaustedURLs` is keyed by exact URL and is wiped on every source switch and every episode advance,
        // so a provider that true-stalled on episode N was fully re-eligible on N+1 - and, answering fastest,
        // was re-picked (diag-21). Recorded HERE rather than at the failure sites so a source that recovers in
        // place is never demoted; the penalty decays on its own and is a demotion, never an exclusion.
        // DELIBERATELY BEFORE the hop-budget guard below (tvOS twin does the same): the penalty is a verdict on
        // the SOURCE, not on whether we still have a hop left to spend. A source that just died with the budget
        // exhausted is exactly as guilty as one that died with hops to spare, so booking it on the way to the
        // error overlay is the point, not a leak.
        if let dying = currentStream, let dyingAddon = addonName(for: dying) {
            ProviderHealth.noteFailure(addonName: dyingAddon)
        }
        let srcProbeUntried = nextUntriedStream()
        guard (allowBeyondFailureBudget || sourceHops < maxSourceHops),
              let stream = srcProbeUntried,
              let newURL = playableURL(for: stream) else {
            srcProbe("hopToNextSource(\(reason)) FALSE: hops=\(sourceHops)/\(maxSourceHops) untriedFound=\(srcProbeUntried != nil ? "Y" : "N") totalPlayableCandidates=\(srcProbeCandidateCount) exhausted=\(exhaustedURLs.count) -> caller shows error overlay")
            return false
        }
        var tried = exhaustedURLs
        if let dead = curURL { tried.insert(dead) }
        // `midPlayFailureResume` carries the play head of a source that died MID-PLAY, whose handler had to
        // clear `hasStartedPlaying` for the ladder to admit; without it this hop would restart the episode.
        let resume: Double = resumeOverride
            ?? (hasStartedPlaying ? currentTime : (midPlayFailureResume ?? resumeSeconds))
        srcProbe("hopToNextSource(\(reason)) HOP \(sourceHops)->\(sourceHops + 1) to host=\(newURL.host ?? "-") torrent=\(stream.isTorrent ? "Y" : "N") (candidates=\(srcProbeCandidateCount))")
        guard switchStream(
            to: stream, url: newURL, userInitiated: false,
            resumeOverride: resume
        ) else {
            srcProbe("hopToNextSource(\(reason)) FALSE: player command was not admitted")
            return false
        }
        exhaustedURLs = tried
        sourceHops += 1
        midPlayRecoveryCount = 0   // a DIFFERENT source is a different mount: it earns its own mid-play budget
        return true
    }

    private func resetRuntimeForIssuedSourceSwitch(userInitiated: Bool, explicitPick: Bool) {
        clearCachedAudioOutputTruth()
        #if os(iOS) || os(macOS)
        avToMPVHandoffTask?.cancel()
        avToMPVHandoff = nil
        avToMPVHandoffBlocked = false
        #endif
        deferredResumeAttempt.invalidate()
        currentPickWasExplicit = explicitPick
        currentPlaybackIsResume = false
        bufferGraceUsed = 0; lastBufferedAtWatchdog = -1
        bufferedTime = 0
        stallRecoveries = 0
        stallStableProgressTicks = 0
        if userInitiated {
            sourceHops = 0; exhaustedURLs = []
            recoveryDeadline?.cancel(); recoveryDeadline = nil
            // A mount the viewer asked for (a manual pick, or the next episode) gets a fresh mid-play budget.
            // The automatic lane deliberately does NOT reset here - `hopToNextSource` clears it only once its
            // switch is actually issued, so a hop that is refused keeps counting toward the overlay.
            midPlayRecoveryCount = 0
        }
        appliedSize = false; appliedAutoTracks = false; autoAddonSubTried = false
        userPickedSubtitle = false; addonSubsResolveTried = false; appliedVolume = false
        pendingSubtitleReapply = nil; suppressedResumeFloor = nil; pendingLibmpvResumeSeek = nil
        postFrameResumeSeekWatchdog?.cancel(); postFrameResumeSeekWatchdog = nil
        hasStartedPlaying = false; isSeekable = true; buffering = true; loadErrorMsg = ""
        midPlayFailureResume = nil   // consumed by this switch's resumeOverride; it must not leak to the next load
        autoRetryCount = 0; reconnecting = false; autoRetryTask?.cancel(); awaitedFreshSources = false
        torrentWarmupsUsed = 0; torrentStatus = nil
        subFingerprint = nil; subFingerprintKey = ""; pooledSubs = []
        subtitlePoolRequests.invalidate(); subtitleLoadingURL = nil
        addedPooledIDs = []; embeddedUploadDone = false
        langContributeDone = false
        reconnectMsg = "Switching source…"
    }

    /// Target-only latches move at the same transaction boundary as the accepted player command. While an
    /// episode is merely resolving, the outgoing episode remains physical and published, so resetting these
    /// earlier would let a rejected replacement duplicate its watched/auto-add/progress side effects or undo
    /// the viewer's Watch Credits choice.
    private func resetRuntimeForIssuedEpisode() {
        clearCachedAudioOutputTruth()
        markedWatched = false
        autoAddedThisPlayback = false
        upNextSuppressed = false
        appliedInitialResume = true
        lastReported = -1
        stallRecoveries = 0
        stallStableProgressTicks = 0
    }

    /// Switch the playing source in place: reload the picked stream's URL and resume at the current
    /// position, so a buffering or low-quality source can be swapped without leaving the player. A
    /// deliberate pick resets the failover budget; an automatic hop restores it in `hopToNextSource`.
    /// `addon` is the NAME of the add-on a MANUAL pick came from, carried through so the choice can be
    /// remembered for the rest of the series (`SeriesSourceSticky`); the panels have it in hand already.
    @discardableResult
    private func switchStream(to stream: CoreStream, url newURL: URL, userInitiated: Bool,
                              explicitPick: Bool = false, addon: String? = nil,
                              resumeOverride: Double? = nil,
                              debridRef: DebridPlaybackRef? = nil, engineAlreadyBound: Bool = false,
                              engineAddonBaseOverride: String? = nil,
                              mediaGenerationAlreadyClaimed: Bool = false,
                              preparedRemux: VortXPreparedRemuxAttachment? = nil,
                              expectedPreparedRemuxOwner: VortXPreparedRemuxOwnerIdentity? = nil) -> Bool {
        guard newURL != curURL else {
            if let pending = pendingAdvance, !pending.issued,
               pending.meta.videoId != curMeta?.videoId {
                invalidateEpisodeResolution()
                episodeResolveGeneration = nil
                pendingAdvance = nil
                if restoreSupersededAdvance() { return false }
                switchingEpisode = false; reconnecting = false
                loadErrorMsg = "That episode resolved to the current episode's file."
                presentTerminalLoadFailure()
                return false
            }
            srcProbe("switchStream NO-OP (same url as current) userInitiated=\(userInitiated) explicit=\(explicitPick)")
            if userInitiated { close() }
            return false
        }
        if !mediaGenerationAlreadyClaimed {
            let hadEpisodeResolution = episodeResolutionOwner != nil
            invalidateEpisodeResolution()
            if hadEpisodeResolution {
                episodeResolveGeneration = nil
                let healthyPending = pendingAdvance != nil && pendingAdvance?.terminal != true
                switchingEpisode = healthyPending
                reconnecting = healthyPending
            }
            resumeRetryGeneration &+= 1
        }
        directAVNoFrameRecovery = nil
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
        // `midPlayFailureResume` carries the play head of a source that died MID-PLAY, whose handler had to
        // clear `hasStartedPlaying` before the recovery ladder would admit. Without it a switch taken from
        // that state (the viewer picking another source off the error overlay) would restart the episode.
        let resume = resumeOverride
            ?? (hasStartedPlaying ? currentTime : (midPlayFailureResume ?? resumeSeconds))
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
            resumeOrigin: resume,
            preparedRemux: preparedRemux,
            expectedPreparedRemuxOwner: expectedPreparedRemuxOwner
        )
        if pendingAdvance != nil {
            guard let issuedToken else {
                if let priorPending, priorPending.issued, !priorPending.terminal,
                   priorPending.loadToken == coordinator.player?.activeLoadToken {
                    pendingAdvance = priorPending
                    switchingEpisode = true; reconnecting = true
                    return false
                }
                invalidateEpisodeResolution()
                episodeResolveGeneration = nil
                pendingAdvance = nil
                if restoreSupersededAdvance() { return false }
                switchingEpisode = false
                loadErrorMsg = "The player could not issue this episode."
                presentTerminalLoadFailure()
                return false
            }
            pendingAdvance?.loadToken = issuedToken
            pendingAdvance?.issued = true
        } else if issuedToken == nil {
            return false
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
        let acceptedSubtitleTimingScope = subtitleTimingScope(
            for: pendingAdvance?.meta ?? curMeta,
            stream: stream
        )
        if pendingAdvance != nil {
            pendingAdvance?.subtitleTimingScope = acceptedSubtitleTimingScope
            coordinator.player?.setSubDelay(0)
        } else {
            acceptSubtitleTimingReplacement(scope: acceptedSubtitleTimingScope)
        }
        // REMEMBER A MANUAL PICK (diag-21). The in-session binge group is add-on-authored text worth +2500 and
        // loses to the cached (+8000) and source-type (15000) terms on the very next rank, so the viewer
        // re-picked the same provider every single episode. Record the choice durably here, the one place a
        // picked stream and its add-on are both in hand. Gated on `explicitPick`, NOT on `userInitiated`: an
        // episode advance also passes `userInitiated: true` (it closes panels and resets the failover budget
        // the same way), and only the sources and quality panels set `explicitPick`. Recording an auto-hop or
        // an advance would teach the store the failure, not the taste.
        if explicitPick, let key = seriesStickyKey {
            SeriesSourceSticky.record(seriesKey: key, addon: addon,
                                      bingeGroup: stream.behaviorHints?.bingeGroup)
        }
        if pendingAdvance == nil { curDebridRef = debridRef }
        curHint = nextHint
        if let oldHash, oldHash != stream.infoHash?.lowercased() { closeTorrent(hash: oldHash) }
        if resumeOverride != nil { currentTime = 0; duration = 0 }
        invalidateLocalTrickplayCapture()
        if pendingAdvance == nil {
            scrubThumbnails.configure(localCacheKey: trickplayLocalCacheKey)
            lastLocalTrickplayCapture = -1000
            configureCommunityTrickplayProvisional()
        }
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
        // A successful CURRENT-episode source switch changes the continuity, binge-group, and provider inputs
        // used to choose E+1. Retire any winner prepared under the old source and re-arm immediately when this
        // episode is already past the preload gate. During an in-flight episode advance curMeta still names the
        // outgoing episode, so that lane keeps its own pending identity and must not prepare from stale inputs.
        if pendingAdvance == nil, isEpisodePlaybackContext {
            let shouldRearm = PreparedEpisodeAttemptPolicy.shouldRearmAfterSourceSwitch(
                hasPendingAdvance: false,
                isEpisodePlayback: true,
                position: currentTime,
                duration: duration
            )
            invalidatePreparedEpisode(reason: "current source changed")
            if shouldRearm { warmNextIfNeeded() }
        }
        startLoadTimeout()
        if resume > 5 { nudgeResume(to: resume) }
        return true
    }

    // MARK: - Episode navigation (series; launch and later backfill share one ordered list)

    private var navigationEpisodeSource: [PlayerEpisodeRef] {
        guard !episodes.isEmpty else { return loadedSeriesEpisodes }
        return loadedSeriesEpisodes.count > episodes.count ? loadedSeriesEpisodes : episodes
    }

    private var allEpisodeRefs: [PlayerEpisodeRef] {
        navigationEpisodeSource.sorted {
            let ls = $0.season ?? 0, rs = $1.season ?? 0
            if ls != rs { return ls < rs }
            let le = $0.episode ?? 0, re = $1.episode ?? 0
            if le != re { return le < re }
            return $0.id < $1.id
        }
    }

    private var terminalEpisodeSource: [PlayerEpisodeRef] {
        authoritativeSeriesEpisodes ?? episodes
    }

    private func seriesInventory(from refs: [PlayerEpisodeRef],
                                 authority: AppleCWSeriesInventory.Authority) -> AppleCWSeriesInventory? {
        let identities = refs.compactMap { ref -> AppleCWSeriesEpisode? in
            guard let season = ref.season, let episode = ref.episode else { return nil }
            return AppleCWSeriesEpisode(id: ref.id, season: season, episode: episode)
        }
        guard identities.count == refs.count else { return nil }
        return AppleCWSeriesInventory(raw: identities, authority: authority)
    }

    private var terminalInventoryAuthority: AppleCWSeriesInventory.Authority {
        authoritativeSeriesEpisodes == nil ? seriesInventoryAuthority : .authoritativeFullSeries
    }

    private func terminalRefreshTarget(for m: PlaybackMeta) -> AppleCWTerminalRefreshTarget {
        AppleCWTerminalRefreshTarget(
            libraryID: m.libraryId,
            videoID: m.videoId,
            sessionID: playbackSessionID,
            episodeGeneration: episodeSwitchGeneration,
            sourceGeneration: sourceSwitchGeneration,
            resumeGeneration: resumeRetryGeneration,
            loadOwner: coordinator.player?.activeLoadToken.map { String(describing: $0) }
        )
    }

    private func terminalRefreshTargetIsCurrent(
        _ captured: AppleCWTerminalRefreshTarget,
        loadToken: PlayerLoadToken
    ) -> Bool {
        guard !playbackExited, let current = curMeta,
              current.libraryId == captured.libraryID,
              current.videoId == captured.videoID,
              AppleCWTerminalRefreshFence.accepts(
                  captured: captured, current: terminalRefreshTarget(for: current)
              ) else { return false }
        guard coordinator.player?.activeLoadToken == loadToken else { return false }
        return true
    }

    private var terminalFinalityRefreshUsed: Bool {
        guard let captured = terminalFinalityRefreshTarget, let current = curMeta else { return false }
        return AppleCWTerminalRefreshFence.accepts(
            captured: captured, current: terminalRefreshTarget(for: current)
        )
    }

    /// Cancel only this player's bridge refresh generation. SwiftUI may tear down this view after a
    /// replacement player has started a newer request against the same title, so the captured generation
    /// must be retained through teardown and passed to CoreBridge rather than using global cancellation.
    private func cancelTerminalFinalityRefresh() {
        terminalFinalityRefreshTask?.cancel()
        terminalFinalityRefreshTask = nil
        if let generation = terminalFinalityRefreshGeneration {
            core.cancelAppleCWMetaRefresh(generation: generation)
        }
        terminalFinalityRefreshGeneration = nil
        terminalFinalityRefreshTarget = nil
    }

    private var terminalRefreshResult: AppleCWSeriesRefreshResult {
        if seriesInventory(from: terminalEpisodeSource, authority: terminalInventoryAuthority) != nil,
           terminalInventoryAuthority == .authoritativeFullSeries {
            return .completedWithFullInventory
        }
        return terminalFinalityRefreshUsed ? .completedWithoutFullInventory : .notAttempted
    }

    private func terminalSeriesDecision(for m: PlaybackMeta) -> AppleCWSeriesTerminalDecision {
        let inventory = seriesInventory(from: terminalEpisodeSource, authority: terminalInventoryAuthority)
        return AppleCWSeriesTerminalPolicy.decide(currentID: m.videoId,
                                                  inventory: inventory,
                                                  refresh: terminalRefreshResult)
    }

    private func authoritativeBackfillRefs(_ videos: [CoreVideo]) -> [PlayerEpisodeRef]? {
        guard EpisodePlaybackIdentity.appleCWSeriesInventory(
            from: videos, authority: .authoritativeFullSeries
        ) != nil else { return nil }
        let candidate = videos.map {
            PlayerEpisodeRef(id: $0.id,
                             label: "S\($0.season ?? 1)E\($0.episode ?? 0) · \($0.episodeTitle)",
                             season: $0.season,
                             episode: $0.episode)
        }
        guard let launch = seriesInventory(from: episodes, authority: .launch) else {
            return episodes.isEmpty ? candidate : nil
        }
        guard let candidateInventory = seriesInventory(from: candidate, authority: .authoritativeFullSeries),
              candidateInventory.ordered.count >= launch.ordered.count else { return nil }
        if candidateInventory.ordered.count == launch.ordered.count {
            guard candidateInventory.ordered == launch.ordered else { return nil }
        } else {
            guard launch.ordered.allSatisfy({ candidateInventory.ordered.contains($0) }) else { return nil }
        }
        return candidate
    }

    private func refreshTerminalSeriesInventory(for m: PlaybackMeta) {
        guard let loadToken = coordinator.player?.activeLoadToken else { return }
        let target = terminalRefreshTarget(for: m)
        guard terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
        cancelTerminalFinalityRefresh()
        terminalFinalityRefreshTarget = target
        let requestGeneration = core.beginAppleCWAuthoritativeMetaRefresh(
            type: m.type, id: m.libraryId, streamType: m.type, streamId: m.videoId
        )
        terminalFinalityRefreshGeneration = requestGeneration
        terminalFinalityRefreshTask = Task { @MainActor in
            guard !Task.isCancelled,
                  terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
            var candidate: [CoreVideo]?
            for attempt in 0..<16 {
                guard !Task.isCancelled,
                      terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
                let receipt = AppleCWMetaRefreshReceipt(
                    requestGeneration: core.appleCWMetaRefreshReceipt?.requestGeneration,
                    selectedMetaID: core.appleCWMetaRefreshReceipt?.selectedMetaID,
                    loadedMetaID: core.appleCWMetaRefreshReceipt?.loadedMetaID,
                    settled: core.appleCWMetaRefreshReceipt?.settled == true,
                    requestedStreamID: core.appleCWMetaRefreshReceipt?.requestedStreamID
                )
                if AppleCWMetaRefreshAuthorityPolicy.accepts(
                    receipt, forRequestGeneration: requestGeneration, expectedLibraryID: m.libraryId,
                    expectedStreamID: m.videoId
                ), let loaded = core.appleCWMetaRefreshDetails?.appleCWTerminalFullMeta(
                    for: m.libraryId, streamID: m.videoId
                ),
                   let vids = loaded.videos, !vids.isEmpty {
                    candidate = vids
                    break
                }
                guard attempt < 15 else { break }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled,
                      terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
            }
            guard !Task.isCancelled,
                  terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
            if let candidate, let accepted = authoritativeBackfillRefs(candidate) {
                guard !Task.isCancelled,
                      terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
                loadedSeriesEpisodes = accepted
                loadedSeriesVideoMetadata = candidate
                authoritativeSeriesEpisodes = accepted
            }
            guard !Task.isCancelled,
                  terminalRefreshTargetIsCurrent(target, loadToken: loadToken),
                  let current = curMeta,
                  current.libraryId == target.libraryID,
                  current.videoId == target.videoID else { return }
            switch terminalSeriesDecision(for: current) {
            case .advance(let id):
                guard !Task.isCancelled,
                      terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
                guard goToEpisode(id, autoAdvance: true) else {
                    // A settled successor without an admitted resolver must never strand the player in the
                    // refresh task or consume the advance as a silent no-op. Series still exits fail-closed;
                    // `leavePlayback` never issues the movie-only rewind for this path.
                    DiagnosticsLog.log(
                        "binge",
                        "successor admission rejected target=\(VXProbeRedaction.identityToken(id)); leaving playback"
                    )
                    leavePlayback()
                    return
                }
            case .refresh, .keepState:
                guard !Task.isCancelled,
                      terminalRefreshTargetIsCurrent(target, loadToken: loadToken) else { return }
                leavePlayback()
            }
        }
    }

    private var episodeIndex: Int? {
        guard let id = curMeta?.videoId, !allEpisodeRefs.isEmpty else { return nil }
        return allEpisodeRefs.firstIndex { $0.id == id }
    }
    private var canNextEpisode: Bool { episodeIndex.map { $0 + 1 < allEpisodeRefs.count } ?? false }

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
        guard let i = episodeIndex, i + 1 < allEpisodeRefs.count else { return nil }
        return allEpisodeRefs[i + 1].label
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

    private func goToNextEpisode() { if let i = episodeIndex, i + 1 < allEpisodeRefs.count { goToEpisode(allEpisodeRefs[i + 1].id) } }
    private func goToPrevEpisode() { if let i = episodeIndex, i > 0 { goToEpisode(allEpisodeRefs[i - 1].id) } }

    /// Prepare the next episode through a bounded retry policy. Playback ticks may call this repeatedly,
    /// but only one active attempt, two delayed retries, and one final credits attempt can be admitted.
    private func warmNextIfNeeded() {
        guard let warm = warmNextEpisode, canNextEpisode, let i = episodeIndex else { return }
        let nextID = allEpisodeRefs[i + 1].id
        guard warmedEpisodeID != nextID, preparingEpisodeID != nextID else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let attempt = nextEpisodeAttemptPolicy.evaluate(
            targetEpisodeID: nextID,
            position: currentTime,
            duration: duration,
            now: now
        ) else { return }
        let originID = curMeta?.videoId
        let generation = nextEpisodePreparationGeneration
        let mountIsOnDevice: Bool
        if case .onDevice = VortXExternalEngine.shared.mountPlan {
            mountIsOnDevice = true
        } else {
            mountIsOnDevice = false
        }
        let request = attempt.preparationRequest(
            protectedTorrentHash: currentTorrentHash,
            preparedRemuxGeneration: UInt64(max(0, generation)),
            prepareLocalAVPlayerRemux: coordinator.player is AVPlayerEngineController
                && mountIsOnDevice
        )
        preparingEpisodeID = nextID
        DiagnosticsLog.log("binge", "next prepare trigger target=\(VXProbeRedaction.identityToken(nextID)) generation=\(generation) attempt=\(attempt.sequence) credits=\(attempt.nearCredits ? "Y" : "N")")
        nextEpisodePreparationTask = Task { @MainActor in
            let result = await warm(request)
            guard preparingEpisodeID == nextID,
                  PreparedEpisodeRetentionPolicy.ownsCompletion(
                    capturedGeneration: generation,
                    currentGeneration: nextEpisodePreparationGeneration,
                    capturedOriginEpisodeID: originID,
                    currentOriginEpisodeID: curMeta?.videoId,
                    canceled: Task.isCancelled
              ) else {
                retirePreparedTorrentEngine(result?.torrentPreparationLease, reason: "stale completion")
                result?.preparedRemux?.abandon(reason: "stale iOS preparation completion")
                return
            }
            preparingEpisodeID = nil
            let accepted = result.map {
                PreparedEpisodeRetentionPolicy.admitsPreparedValue(
                    requestedEpisodeID: nextID,
                    returnedEpisodeID: $0.meta.videoId
                )
            } ?? false
            let completion = nextEpisodeAttemptPolicy.complete(
                attempt,
                succeeded: accepted,
                now: ProcessInfo.processInfo.systemUptime
            )
            guard accepted, completion == .ready, let result else {
                retirePreparedTorrentEngine(result?.torrentPreparationLease, reason: "rejected completion")
                result?.preparedRemux?.abandon(reason: "rejected iOS preparation completion")
                DiagnosticsLog.log("binge", "next prepare empty target=\(VXProbeRedaction.identityToken(nextID)) generation=\(generation) attempt=\(attempt.sequence) outcome=\(String(describing: completion))")
                return
            }
            if preparedEpisode?.torrentPreparationLease !== result.torrentPreparationLease {
                retirePreparedTorrentEngine(
                    preparedEpisode?.torrentPreparationLease,
                    reason: "replacement prepared value"
                )
            }
            preparedEpisode?.preparedRemux?.abandon(reason: "replacement prepared episode")
            warmedEpisodeID = nextID
            preparedEpisode = result
            DiagnosticsLog.log("binge", "next prepare ready target=\(VXProbeRedaction.identityToken(nextID)) host=\(result.url.host ?? "-") generation=\(generation)")
        }
    }

    private func takePreparedEpisode(for videoID: String) -> PlayerEpisodeStream? {
        let result = PreparedEpisodeRetentionPolicy.consumes(
            requestedEpisodeID: videoID,
            preparedEpisodeID: preparedEpisode?.meta.videoId
        ) ? preparedEpisode : nil
        if result == nil {
            retirePreparedTorrentEngine(
                preparedEpisode?.torrentPreparationLease,
                reason: "different episode requested"
            )
            preparedEpisode?.preparedRemux?.abandon(reason: "different episode requested")
        }
        nextEpisodePreparationGeneration &+= 1
        nextEpisodePreparationTask?.cancel()
        nextEpisodePreparationTask = nil
        preparingEpisodeID = nil
        preparedEpisode = nil
        warmedEpisodeID = nil
        nextEpisodeAttemptPolicy.reset()
        if result != nil {
            DiagnosticsLog.log("binge", "next prepare consumed target=\(VXProbeRedaction.identityToken(videoID))")
        }
        return result
    }

    private func invalidatePreparedEpisode(reason: String) {
        nextEpisodePreparationGeneration &+= 1
        nextEpisodePreparationTask?.cancel()
        nextEpisodePreparationTask = nil
        preparingEpisodeID = nil
        retirePreparedTorrentEngine(preparedEpisode?.torrentPreparationLease, reason: reason)
        preparedEpisode?.preparedRemux?.abandon(reason: reason)
        preparedEpisode = nil
        warmedEpisodeID = nil
        nextEpisodeAttemptPolicy.reset()
        DiagnosticsLog.log("binge", "next prepare invalidated reason=\(reason)")
    }

    private func retirePreparedTorrentEngine(
        _ lease: PreparedTorrentEngineLease?,
        reason: String
    ) {
        guard let lease, lease.abandon() else { return }
        let protected = lease.protectsPlayingEngine
            || currentTorrentHash?.caseInsensitiveCompare(lease.hash) == .orderedSame
        if !protected { closeTorrent(hash: lease.hash) }
        DiagnosticsLog.log(
            "binge",
            "next prepare torrent retired target=\(VXProbeRedaction.identityToken(lease.request.episodeID)) attempt=\(lease.request.attemptSequence) remove=\(protected ? "N" : "Y") reason=\(reason)"
        )
    }

    private func preparedTorrentLeaseIsAdmissible(
        _ episode: PlayerEpisodeStream,
        requestedEpisodeID: String
    ) -> Bool {
        guard let lease = episode.torrentPreparationLease else { return true }
        guard let request = episode.preparationRequest,
              request.episodeID == requestedEpisodeID else { return false }
        return lease.canAdmit(
            episodeID: requestedEpisodeID,
            attemptSequence: request.attemptSequence
        )
    }

    private var currentEpisodeResolutionOwner: EpisodeResolutionOwner? {
        guard let videoID = episodeResolutionTargetVideoID else { return nil }
        return EpisodeResolutionOwner(
            episodeGeneration: episodeSwitchGeneration,
            sourceGeneration: resumeRetryGeneration,
            videoID: videoID
        )
    }

    private func armEpisodeResolutionDeadline(owner: EpisodeResolutionOwner) {
        episodeResolutionTask?.cancel()
        episodeResolutionDeadlineTask?.cancel()
        episodeResolutionOwner = owner
        episodeResolutionTargetVideoID = owner.videoID
        episodeResolutionAdmitted = false
        episodeResolutionDeadlineTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.episodeResolutionDeadlineSeconds))
            guard !Task.isCancelled else { return }
            let decision = EpisodeResolutionDeadlinePolicy.decision(
                captured: owner,
                current: currentEpisodeResolutionOwner,
                pendingVideoID: episodeResolutionTargetVideoID,
                admitted: episodeResolutionAdmitted,
                exited: playbackExited
            )
            guard decision == .timeOut else { return }
            episodeResolutionTask?.cancel()
            episodeResolutionTask = nil
            episodeResolutionDeadlineTask = nil
            episodeResolutionOwner = nil
            episodeResolutionTargetVideoID = nil
            episodeResolutionAdmitted = false
            episodeResolveGeneration = nil
            pendingAdvance = nil
            if restoreSupersededAdvance() { return }
            switchingEpisode = false
            reconnecting = false
            buffering = false
            loadErrorMsg = "No playable source resolved within 30 seconds."
            DiagnosticsLog.log(
                "binge",
                "episode resolve deadline reached before player admission for \(VXProbeRedaction.identityToken(owner.videoID))"
            )
            presentTerminalLoadFailure()
        }
    }

    private func admitEpisodeResolutionIfCurrent(loadToken: PlayerLoadToken) {
        guard let owner = episodeResolutionOwner,
              owner == currentEpisodeResolutionOwner,
              episodeResolutionTargetVideoID == owner.videoID,
              pendingAdvance?.meta.videoId == owner.videoID,
              pendingAdvance?.loadToken == loadToken,
              coordinator.player?.activeLoadToken == loadToken else { return }
        episodeResolutionAdmitted = true
        episodeResolutionDeadlineTask?.cancel()
        episodeResolutionDeadlineTask = nil
    }

    private func invalidateEpisodeResolution() {
        episodeResolutionTask?.cancel()
        episodeResolutionDeadlineTask?.cancel()
        episodeResolutionTask = nil
        episodeResolutionDeadlineTask = nil
        episodeResolutionOwner = nil
        episodeResolutionTargetVideoID = nil
        episodeResolutionAdmitted = false
    }

    private func invalidateEpisodeWorkForExit() {
        persistenceBlockedForExit = hasUncommittedIssuedMedia
        playbackExited = true
        invalidateEpisodeResolution()
        episodeSwitchGeneration &+= 1
        episodeResolveGeneration = nil
        resumeRetryGeneration &+= 1
        deferredResumeAttempt.invalidate()
        autoRetryTask?.cancel()
        pendingAdvance = nil
        supersededAdvance = nil
        switchingEpisode = false
        coordinator.player?.invalidateLoadToken()
        invalidatePreparedEpisode(reason: "player exit")
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
    @discardableResult
    private func goToEpisode(_ videoId: String, autoAdvance: Bool = false) -> Bool {
        let refreshedMetadata = loadedSeriesVideoMetadata.first { $0.id == videoId }
        let resolverRoute: AppleEpisodeResolverAdmission.Route<PlayerEpisodeStream>? =
            AppleEpisodeResolverAdmission.route(
                videoID: videoId,
                refreshedMetadata: refreshedMetadata,
                idResolver: loadEpisode,
                metadataResolver: loadEpisodeWithMetadata
            )
        guard !playbackExited, resolverRoute != nil else {
            return false
        }
        if let pending = pendingAdvance,
           PreparedEpisodeRetentionPolicy.isPendingReentry(
            requestedEpisodeID: videoId,
            pendingEpisodeID: pending.meta.videoId,
            pendingIssued: pending.issued,
            pendingTerminal: pending.terminal,
            activeLoadMatches: PlayerLoadProvenanceState.accepts(
                callbackToken: pending.loadToken,
                activeToken: coordinator.player?.activeLoadToken
            )
           ) {
            DiagnosticsLog.log(
                "binge",
                "episode reentry ignored target=\(VXProbeRedaction.identityToken(videoId)); retained preparation preserved"
            )
            return true
        }
        let retainedPreparedEpisode = takePreparedEpisode(for: videoId)
        if let pending = pendingAdvance,
           IssuedPendingEpisodeReentryPolicy.shouldPreserve(
            issued: pending.issued, terminal: pending.terminal
           ),
           PlayerLoadProvenanceState.accepts(
            callbackToken: pending.loadToken,
            activeToken: coordinator.player?.activeLoadToken
           ) {
            supersededAdvance = SupersededEpisodeAdvance(
                pending: pending, source: currentEpisodeSourceSnapshot()
            )
            // Move the active uncommitted load instead of copying it. Terminal callbacks during the newer
            // resolve now update the one superseded owner, so a timeout cannot revive a stale non-terminal copy.
            pendingAdvance = nil
        }
        switchingEpisode = true
        episodeSwitchGeneration &+= 1
        let episodeGeneration = episodeSwitchGeneration
        episodeResolveGeneration = episodeGeneration
        resumeRetryGeneration &+= 1
        let mediaGeneration = resumeRetryGeneration
        let resolutionOwner = EpisodeResolutionOwner(
            episodeGeneration: episodeGeneration,
            sourceGeneration: mediaGeneration,
            videoID: videoId
        )
        armEpisodeResolutionDeadline(owner: resolutionOwner)
        autoRetryTask?.cancel()
        if duration > 0, currentTime > 0 { reportProgress(currentTime) }   // flush the outgoing episode (floor-guarded)
        withAnimation { panel = nil }
        buffering = true; reconnecting = true; reconnectMsg = "Loading episode…"
        episodeResolutionTask = Task { @MainActor in
            // takePreparedEpisode has already removed this value from retained view state. Own its cleanup
            // before any guard, await, or stale-generation return so cancellation cannot orphan a raw engine.
            let admissionLease = retainedPreparedEpisode?.torrentPreparationLease
            let admissionPreparedRemux = retainedPreparedEpisode?.preparedRemux
            var admissionCommandIssued = false
            var admissionLeaseAdopted = false
            defer {
                if PreparedTorrentAdmissionPolicy.shouldRetireLease(
                    playerCommandIssued: admissionCommandIssued,
                    leaseAdopted: admissionLeaseAdopted
                ) {
                    retirePreparedTorrentEngine(
                        admissionLease,
                        reason: "episode admission task ended before issued ownership"
                    )
                }
                if !admissionCommandIssued {
                    admissionPreparedRemux?.abandon(
                        reason: "episode admission task ended before prepared-remux issue"
                    )
                }
            }
            let resolved: PlayerEpisodeStream?
            if let retainedPreparedEpisode,
               preparedTorrentLeaseIsAdmissible(
                    retainedPreparedEpisode,
                    requestedEpisodeID: videoId
               ) {
                // The retained URL/selection avoids a cold resolve, but CoreBridge still has to move its
                // episode-scoped source owner before switchStream can bind engine attribution or fail over.
                // This is the same identity load performed by loadEpisodeStream, without re-ranking.
                guard let sourceIdentityTarget = PreparedEpisodeRetentionPolicy.sourceIdentityTarget(
                    requestedEpisodeID: videoId,
                    preparedEpisodeID: retainedPreparedEpisode.meta.videoId
                ) else { return }
                core.loadMeta(
                    type: "series",
                    id: retainedPreparedEpisode.meta.libraryId,
                    streamType: "series",
                    streamId: sourceIdentityTarget
                )
                DiagnosticsLog.log(
                    "binge",
                    "next prepare admitted target=\(VXProbeRedaction.identityToken(videoId)); source identity advanced without reselection"
                )
                resolved = retainedPreparedEpisode
            } else {
                if let retainedPreparedEpisode {
                    retirePreparedTorrentEngine(
                        retainedPreparedEpisode.torrentPreparationLease,
                        reason: "admission identity rejected"
                    )
                    retainedPreparedEpisode.preparedRemux?.abandon(
                        reason: "admission identity rejected"
                    )
                }
                if let resolverRoute {
                    resolved = await AppleEpisodeResolverAdmission.resolve(resolverRoute)
                } else {
                    resolved = nil
                }
            }
            let resultIsCurrent = !Task.isCancelled && !playbackExited
                && episodeGeneration == episodeSwitchGeneration
                && mediaGeneration == resumeRetryGeneration
            guard resultIsCurrent else {
                // A source change can retire this result without starting a newer episode generation. Clear
                // only this generation's switch state; a newer episode request owns the state when generations
                // differ and must never be reset by this stale completion.
                if !playbackExited, episodeGeneration == episodeSwitchGeneration {
                    invalidateEpisodeResolution()
                    episodeResolveGeneration = nil
                    if restoreSupersededAdvance() { return }
                    let healthyPending = pendingAdvance != nil && pendingAdvance?.terminal != true
                    switchingEpisode = healthyPending
                    reconnecting = healthyPending
                }
                return
            }
            guard let es = resolved else {
                invalidateEpisodeResolution()
                episodeResolveGeneration = nil
                srcProbe("goToEpisode(\(videoId)) resolve returned nil (autoAdvance=\(autoAdvance ? "Y" : "N"))")
                if restoreSupersededAdvance() { return }
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
                es.preparedRemux?.abandon(reason: "duplicate episode media rejected")
                invalidateEpisodeResolution()
                episodeResolveGeneration = nil
                if restoreSupersededAdvance() { return }
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
            let expectedPreparedRemuxOwner = es.preparationRequest.map {
                VortXPreparedRemuxOwnerIdentity(
                    mediaID: es.meta.videoId,
                    generation: $0.preparedRemuxGeneration,
                    sourceSignature: StreamRanking.signature(es.stream)
                )
            }
            let issued = switchStream(
                to: es.stream, url: es.url, userInitiated: true,
                resumeOverride: es.resume, debridRef: es.debridRef,
                engineAlreadyBound: false,
                engineAddonBaseOverride: es.engineAddonBase,
                mediaGenerationAlreadyClaimed: true,
                preparedRemux: es.preparedRemux,
                expectedPreparedRemuxOwner: expectedPreparedRemuxOwner
            )
            admissionCommandIssued = issued
            if issued, let admissionLease, let request = es.preparationRequest {
                admissionLeaseAdopted = admissionLease.adopt(
                    episodeID: es.meta.videoId,
                    attemptSequence: request.attemptSequence
                )
                assert(admissionLeaseAdopted, "prepared torrent admission lost exact lease ownership")
                DiagnosticsLog.log(
                    "binge",
                    "next prepare torrent adoption target=\(VXProbeRedaction.identityToken(es.meta.videoId)) attempt=\(request.attemptSequence) transitioned=\(admissionLeaseAdopted ? "Y" : "N") issued=Y"
                )
            }
        }
        return true
    }

    /// FIRST-FRAME COMMIT of a binge advance (mirror of TVPlayerView.commitPendingAdvanceOnFirstFrame):
    /// the single point where a parked advance becomes the published current-episode identity. Publishes
    /// curMetaState/curTitleState/curBingeState together, so the label, the episode-list checkmark, the
    /// scrobble attribution, and the LastStreamStore record that follows in the same first-frame block all
    /// name the episode whose file just rendered. No-op outside an advance, so launch playback, source
    /// switches, and stall reloads are untouched.
    @discardableResult
    private func commitPendingAdvanceOnFirstFrame(loadToken: PlayerLoadToken) -> Bool {
        guard let pending = pendingAdvance,
              PlayerLoadProvenanceState.canCommit(
                callbackToken: loadToken,
                activeToken: coordinator.player?.activeLoadToken,
                pendingToken: pending.loadToken
              ) else { return false }
        let acceptedSubtitleTimingScope = pending.subtitleTimingScope
        pendingAdvance = nil
        supersededAdvance = nil
        committedLoadToken = loadToken
        uncommittedIdentityBlocked = false
        curMetaState = pending.meta
        curTitleState = pending.title
        curBingeState = pending.binge
        curDebridRef = pending.debridRef
        acceptSubtitleTimingReplacement(scope: acceptedSubtitleTimingScope, clearNewEngineDelay: false)
        // The caller replays deferredTrackList only after this scope is accepted.
        switchingEpisode = episodeResolveGeneration != nil
        playbackSessionID = UUID().uuidString
        if EpisodeTrickplayIdentityPolicy.shouldRekey(committedPendingAdvance: true) {
            scrubThumbnails.configure(localCacheKey: trickplayLocalCacheKey)
            lastLocalTrickplayCapture = -1000
            invalidateLocalTrickplayCapture()
            configureCommunityTrickplayProvisional()
        }
        // Code-level invariant (the extractable check; the app has no unit-test bundle): at commit, the
        // published episode IS the episode of the file that just first-framed - pending.url is kept in
        // step with curURL by goToEpisode and switchStream. Debug builds trap; user builds log.
        assert(pending.url == nil || pending.url == curURL,
               "binge-advance commit: published episode's media (\(pending.url?.lastPathComponent ?? "nil")) != loaded media (\(curURL?.lastPathComponent ?? "nil"))")
        if let u = pending.url, u != curURL {
            srcProbe("binge COMMIT MISMATCH: pending url \(u.lastPathComponent) != curURL \(curURL?.lastPathComponent ?? "nil")")
        }
        srcProbe("binge advance committed at first frame -> \(pending.meta.videoId) (label/selector/store now agree)")
        return true
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
              let u = pending.url,
              // UIKit suspension does not invalidate either engine's active load token. Exact equality
              // therefore proves this is still the half-open pending command. Nil or mismatch means there is
              // no owned command to replace, so fail closed instead of stomping a newer load or torn-down view.
              PlayerLoadProvenanceState.accepts(
                callbackToken: pending.loadToken,
                activeToken: coordinator.player?.activeLoadToken
              ) else { return }
        let resume = retryResumeTarget()
        srcProbe("foreground reconcile: re-issuing interrupted advance load for \(pending.meta.videoId)")
        buffering = true; reconnecting = true; reconnectMsg = "Loading episode…"
        guard let loadToken = loadRetryIntoPlayer(
            u, headers: curHeaders, live: isLive, resumeTarget: resume
        ) else { return }
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
        if !audioCodec.isEmpty {
            let channelSuffix = audioChannels > 0 ? " \(audioChannels)ch" : ""
            parts.append("\(audioLabel(audioCodec))\(channelSuffix)")
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Clear produced AVPlayer audio facts at every physical-load boundary. A following track-list event
    /// republishes truth from the newly mounted engine; until then the chrome must show no prior engine's
    /// codec or channel count, especially during an AVPlayer-to-libmpv demotion.
    private func clearCachedAudioOutputTruth() {
        audioCodec = ""
        audioChannels = 0
        metadataLine = computeMetadataLine()
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
            #if os(iOS) || os(macOS)
            // The AVPlayer engine owns the real AVPictureInPictureController. Observe that controller directly
            // so this button is absent on unsupported devices and its glyph/label follows AVKit's settled state.
            if let controller = coordinator.player as? AVPlayerEngineController {
                AVPlayerPictureInPictureButton(controller: controller) { scheduleHide() }
            }
            #endif
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
                    issueSeek(to: 0, reason: "restart")
                    currentTime = 0
                    // Direct onSeek (a restart-to-0 must bypass reportSeek's resume floor), so the
                    // account write rides along explicitly, keyed on the CURRENT episode like every
                    // other save (the hosts no longer write the account from the closures).
                    if assetSanityAttempt.isAccepted(owner: coordinator.player?.activeLoadToken),
                       duration > 0 {
                        if engineWritesOpen { onSeek(0, duration) }
                        lastReported = 0
                        saveAccountProgress(0)
                    }
                    if isPaused { coordinator.player?.togglePause() }   // restart implies resume
                    scheduleHide()
                }
            }
            #if !os(tvOS)
            // Skip-segment editor: offered for any tt####### VOD via the shared SkipEditPolicy gate (CONTENT
            // liveness, never player duration/seekability, so the DV-remux / AVPlayer lane keeps it).
            // Submission is keyless via our skip.vortx.tv worker: no third-party key to open or use it.
            if let m = curMeta, SkipEditPolicy.canEdit(isLiveContent: isLive, contentId: m.libraryId) {
                iconButton(showSkipDBEdit ? "checkmark.bubble.fill" : "checkmark.bubble",
                           label: showSkipDBEdit ? "Close skip editor" : "Edit skip segments") {
                    if !showSkipDBEdit { seedSkipDBEditor() }
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

    /// A9: single logged choke point for a seek so the exportable trail shows every jump (reason, from, to,
    /// duration). maybeResume / nudgeResume and the automatic-skip path log their own dedicated lines.
    private func issueSeek(to target: Double, reason: String) {
        DiagnosticsLog.log(
            "playback",
            String(format: "seek reason=%@ from=%.3f to=%.3f duration=%.3f", reason, currentTime, target, duration)
        )
        coordinator.player?.seek(to: target)
    }

    private func seekBy(_ delta: Double) {
        let target = min(max(currentTime + delta, 0), max(duration - 1, 0))
        issueSeek(to: target, reason: "relative")
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
                    PlayerTimeLabel(clock: timePosClock)
                    // Slider is wrapped in a GeometryReader so the trickplay bubble can be positioned
                    // relative to the knob and macOS hover can compute the preview time from cursor x.
                    GeometryReader { geo in
                        // macOS Slider track is inset by ~half the thumb diameter on each side.
                        let sliderInset: CGFloat = 10
                        let trackWidth = max(1, geo.size.width - sliderInset * 2)
                        // While dragging the thumb follows scrubTarget so an incoming timePos tick
                        // can't yank it back to the pre-seek position (#32). On release we commit.
                        PlayerClockSlider(
                            clock: timePosClock,
                            scrubbing: $scrubbing,
                            scrubTarget: $scrubTarget,
                            duration: duration,
                            onScrubChanged: { scrubThumbnails.show(time: $0) },
                            onEditingChanged: { editing in
                                scrubbing = editing
                                if editing {
                                    scrubTarget = currentTime; hideTask?.cancel()
                                    hoverPreviewTime = nil; hoverPreviewRatio = nil
                                } else {
                                    let target = scrubTarget
                                    currentTime = target
                                    issueSeek(to: target, reason: "scrub")
                                    reportSeek(target)
                                    scrubThumbnails.clear()
                                    scheduleHide()
                                }
                            }
                        )
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
                            if !scrubbing {
                                PlayerBufferedBand(
                                    clock: timePosClock,
                                    duration: duration,
                                    bufferedTime: bufferedTime,
                                    trackWidth: trackWidth,
                                    sliderInset: sliderInset,
                                    height: geo.size.height
                                )
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
                if allEpisodeRefs.count > 1 {
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

    /// Seed the skip editor bar from the current playhead + emit one values-free visibility diagnostic.
    /// Shared by the top-bar icon and the overflow "Contribute" row so both open the editor identically.
    private func seedSkipDBEditor() {
        DiagnosticsLog.log("skip", SkipEditPolicy.visibilityDiagnostic(
            canEdit: true, isLiveContent: isLive,
            hasSubmittableId: (curMeta.map { SkipEditPolicy.isSubmittableContentId($0.libraryId) } ?? false),
            engine: (coordinator.player is AVPlayerEngineController) ? "avplayer" : "libmpv"))
        let snapped = (currentTime * 2).rounded() / 2
        skipDBEditStart = max(0, snapped)
        skipDBEditEnd = min(snapped + 30, duration > 0 ? duration : snapped + 60)
        skipDBEditType = .intro
        skipDBShowEndTime = true
        skipDBSubmitResult = nil
        skipDBSubmitError = nil
        skipDBPreviewing = false
    }

    /// The SYNTHESIZED runtime (source seconds) for a submission when the engine has not emitted a finite
    /// `duration` (the DV-remux INDEFINITE edge). Reuses the loaded meta's human runtime, the same value the
    /// provisional trickplay key uses, and only when it is THIS title's meta. nil when unknown.
    private var skipSubmissionFallbackRuntimeSeconds: Double? {
        guard let m = curMeta, let loaded = core.metaDetails?.meta, loaded.id == m.libraryId,
              let secs = loaded.runtimeSeconds, secs > 0 else { return nil }
        return secs
    }

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
            duration_ms: SkipEditPolicy.submissionDurationMs(
                playerDurationSeconds: duration,
                fallbackRuntimeSeconds: skipSubmissionFallbackRuntimeSeconds)
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
            PlayerTimeLabel(clock: timePosClock, opacity: 0.85, showWhenPositive: true)
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

    #if os(iOS) || os(macOS)
    /// PiP is a real AVPlayer capability, not a routing intent. Keep the control out of the accessibility tree
    /// until AVKit reports support or an active/transitioning controller, and keep its disabled state truthful
    /// while AVKit owns a start or stop transition.
    private struct AVPlayerPictureInPictureButton: View {
        @ObservedObject var controller: AVPlayerEngineController
        let onInteraction: () -> Void

        var body: some View {
            if controller.isPictureInPicturePossible
                || controller.isPictureInPictureActive
                || controller.isPictureInPictureTransitioning {
                Button {
                    let accepted = controller.isPictureInPictureActive
                        ? controller.stopPictureInPicture()
                        : controller.startPictureInPicture()
                    if accepted { onInteraction() }
                } label: {
                    Group {
                        if controller.isPictureInPictureTransitioning {
                            ProgressView()
                        } else {
                            Image(systemName: controller.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                        }
                    }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white).padding(11)
                        .vortxGlassDisc()
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(controller.isPictureInPictureTransitioning)
                .accessibilityLabel(pictureInPictureAccessibilityLabel)
            }
        }

        private var pictureInPictureAccessibilityLabel: String {
            switch controller.pictureInPictureTransition {
            case .some(.starting): return "Starting Picture in Picture"
            case .some(.stopping): return "Stopping Picture in Picture"
            case nil:
                return controller.isPictureInPictureActive
                    ? "Exit Picture in Picture"
                    : "Enter Picture in Picture"
            }
        }
    }
    #endif

    // MARK: - Skip intro / outro

    private func skipPill(_ segment: SkipSegment) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    Haptics.success()
                    issueSeek(to: segment.end, reason: "skip")
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
            DiagnosticsLog.log(
                "playback",
                String(
                    format: "automatic skip kind=%@ start=%.3fs end=%.3fs observed=%.3fs",
                    skip.kind.rawValue,
                    skip.start,
                    skip.end,
                    time
                )
            )
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
            if panelShowsSubtitleList, let p = panel { panelRows = rows(for: p) }
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
                if ok, player === coordinator.player {
                    applyCurrentSubtitleDelayIfReady(force: false)
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

    /// Build the community content key for a supplied metadata identity. The caller can use a staged episode
    /// identity before it is published, while the live property below keeps the existing runtime live gate.
    private func communityContentKey(for targetMeta: PlaybackMeta?) -> String? {
        guard let m = targetMeta, !LiveTypes.contains(m.type) else { return nil }
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

    /// The pool content key for the published current media. Live streams and runtime non-seekable playback
    /// keep the community path disabled even when their metadata resembles a normal title.
    private var communityContentKey: String? {
        guard !effectivelyLive else { return nil }
        return communityContentKey(for: curMeta)
    }

    /// Stable local timing scope. It requires the actual stream's release description and never falls back to
    /// a URL, title, duration, or display label when that authority is absent.
    private func subtitleTimingScope(for targetMeta: PlaybackMeta?, stream: CoreStream?) -> SubtitleTimingScope? {
        guard let contentKey = communityContentKey(for: targetMeta),
              let stream else { return nil }
        let releaseDescription = StreamRanking.signature(stream)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !releaseDescription.isEmpty,
              releaseDescription.caseInsensitiveCompare("unknown") != .orderedSame else {
            return nil
        }
        let releaseFingerprint = SubtitleReleaseFingerprint.releaseFingerprint(releaseName: releaseDescription)
        return SubtitleTimingScope(contentKey: contentKey, releaseFingerprint: releaseFingerprint)
    }

    /// Establish a local scope when metadata or the actual source becomes authoritative. A late identity fill
    /// may establish a previously nil scope, but it never clears timing or advances the timing generation.
    private func establishSubtitleTimingScopeIfAvailable() {
        guard pendingAdvance == nil else { return }
        guard subtitleTimingScope == nil else { return }
        subtitleTimingScope = subtitleTimingScope(
            for: curMeta,
            stream: curSourceStream ?? currentStream
        )
    }

    /// Local v2 restore is state-only. The track-list seam applies that state once subtitle timing is ready.
    private func restoreSubtitleTimingOffsetIfReady() {
        establishSubtitleTimingScopeIfAvailable()
        guard subDelay == 0, !pooledSeededOffset,
              let scope = subtitleTimingScope,
              let savedOffset = SubtitleOffsetMemory.savedOffset(for: scope) else { return }
        subDelay = savedOffset
        pooledSeededOffset = true
    }

    /// Admit a true source or episode replacement at the accepted-load boundary. Preservation paths do not
    /// call this helper, so their timing state and generation remain intact while their new load token earns
    /// one track-ready reapplication.
    private func acceptSubtitleTimingReplacement(
        scope: SubtitleTimingScope?,
        clearNewEngineDelay: Bool = true
    ) {
        flushPendingSubOffsetSave()
        offsetCaptureTask?.cancel()
        offsetCaptureTask = nil
        subtitleTimingGeneration &+= 1
        subtitleTimingScope = scope
        let savedOffset = SubtitleOffsetMemory.savedOffset(for: scope)
        subDelay = savedOffset ?? 0
        pooledSeededOffset = savedOffset != nil
        subtitleDelayAppliedLoadToken = nil
        if clearNewEngineDelay { coordinator.player?.setSubDelay(0) }
    }

    /// Apply a nonzero restored or pooled delay once for an exact engine load token. Explicit user actions use
    /// force so Reset also reaches the engine with zero, while ordinary track-list replays stay idempotent.
    private func applyCurrentSubtitleDelayIfReady(force: Bool = false) {
        guard let player = coordinator.player,
              player.subtitleDelayAvailable,
              let loadToken = player.activeLoadToken else { return }
        if !force {
            guard subDelay != 0 else { return }
            if subtitleDelayAppliedLoadToken == loadToken { return }
        }
        player.setSubDelay(subDelay)
        subtitleDelayAppliedLoadToken = loadToken
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
        guard assetSanityAttempt.isAccepted(
            owner: coordinator.player?.activeLoadToken
        ) else { return }
        guard let contentKey = communityContentKey else { return }
        establishSubtitleTimingScopeIfAvailable()
        if appliedAutoTracks {
            restoreSubtitleTimingOffsetIfReady()
            applyCurrentSubtitleDelayIfReady(force: false)
        }
        refreshSubFingerprint()
        let fp = subFingerprint
        let poolTimingScope = SubtitleTimingScope(contentKey: contentKey, releaseFingerprint: fp)
        let capturedTimingGeneration = subtitleTimingGeneration
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
            let timingGenerationMatches = capturedTimingGeneration == subtitleTimingGeneration
            if let poolTimingScope, !pooledSeededOffset,
               poolTimingScope == SubtitleTimingScope(
                   contentKey: communityContentKey,
                   releaseFingerprint: subFingerprint
               ),
               timingGenerationMatches,
               subDelay == 0,
               let offsetMs = result.offsetMs,
               offsetMs != 0 {
                pooledSeededOffset = true
                let seconds = (Double(offsetMs) / 1000.0 * 10).rounded() / 10
                subDelay = seconds
                applyCurrentSubtitleDelayIfReady(force: false)
                VXProbe.log("subs", "community sync seeded offset=\(String(format: "%+.1f", seconds))s")
            }
            if panelShowsSubtitleList, let p = panel { panelRows = rows(for: p) }
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
        if panelShowsSubtitleList, let p = panel { panelRows = rows(for: p) }
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
                    if panelShowsSubtitleList, let p = panel { panelRows = rows(for: p) }
                }
                return
            }
            guard let localURL = downloaded else {
                if subtitlePoolRequests.finishDownload(downloadID) {
                    subtitleLoadingURL = nil
                    if !auto { subtitleLoadFailed = true }
                    if panelShowsSubtitleList, let p = panel { panelRows = rows(for: p) }
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
                    if panelShowsSubtitleList, let p = panel { panelRows = rows(for: p) }
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
                        if panelShowsSubtitleList, let p = panel { panelRows = rows(for: p) }
                    }
                    return
                }
                guard subtitlePoolRequests.finishExternal(externalID) else { return }
                subtitleLoadingURL = nil
                VXProbe.log("subs", "community subtitle loaded lang=\(sub.lang) ok=\(ok ? "Y" : "N")")
                // Same still-live-engine gate as the add-on rows: never record an add the live engine never saw.
                if ok, player === coordinator.player { addedPooledIDs.insert(sub.id) } else if !ok, !auto { subtitleLoadFailed = true }
                if ok, player === coordinator.player {
                    applyCurrentSubtitleDelayIfReady(force: false)
                }
                if panelShowsSubtitleList, let p = panel { panelRows = rows(for: p) }
            }
        }
    }

    /// The label for a pooled subtitle row: the language name plus a subtle community marker. NO add-on
    /// wording (per the framing rule) - pooled subs are just "subtitles" with a community provenance hint.
    private func pooledLabel(_ sub: SubtitlePoolClient.PooledSubtitle) -> String { langName(sub.lang) }

    /// Persist the manual subtitle offset ONCE per nudge burst instead of once per press (W2-B FIX 2; tvOS twin
    /// in TVPlayerView). Each press used to run `SubtitleOffsetMemory.save` synchronously on the main actor, and
    /// a burst is easily a dozen presses a second; the save is a UserDefaults write plus the settings-changed
    /// fan-out it triggers, all on the actor the player's own start-up work runs on. Coalescing to one write
    /// ~1s after the LAST press stores the identical value (the last one wins either way) at a fraction of the
    /// cost. `setSubDelay` stays immediate: the picture must move on every press.
    private func scheduleSubOffsetSave() {
        subOffsetSaveTask?.cancel()
        let pending = subDelay
        let scope = subtitleTimingScope
        pendingSubOffsetSave = (pending, scope)
        subOffsetSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1000))
            // No scope recheck: the scope was captured WITH the value, so this write is correct even if the
            // session has since advanced to another episode. Only cancellation may suppress it.
            guard !Task.isCancelled else { return }
            SubtitleOffsetMemory.save(pending, for: scope)
            pendingSubOffsetSave = nil
        }
    }

    /// Write a debounced offset immediately. Debouncing trades durability for cost, so the teardown path flushes
    /// first: a viewer who nudges sync and then leaves must not lose the offset they just dialled in.
    private func flushPendingSubOffsetSave() {
        subOffsetSaveTask?.cancel(); subOffsetSaveTask = nil
        guard let pending = pendingSubOffsetSave else { return }
        pendingSubOffsetSave = nil
        SubtitleOffsetMemory.save(pending.delay, for: pending.scope)
    }

    /// P3 capture: debounce a manual sync change, then submit the learned offset to the pool. Works on BOTH
    /// engines now: on libmpv it is the `sub-delay`, on AVPlayer it is the offset applied to VortX's own
    /// external-subtitle overlay (an add-on/pooled srt/vtt). Both are the same signed cue offset for this
    /// release fingerprint, so either is valid to pool. Gated + fail-soft inside the client.
    private func captureSubOffset() {
        guard let capturedContentKey = communityContentKey,
              let capturedFingerprint = subFingerprint else { return }
        offsetCaptureTask?.cancel()
        let delaySeconds = subDelay
        guard let capturedTimingScope = SubtitleTimingScope(
            contentKey: capturedContentKey,
            releaseFingerprint: capturedFingerprint
        ) else { return }
        guard subDelay.isFinite, abs(subDelay) <= 120 else { return }
        let capturedTimingGeneration = subtitleTimingGeneration
        offsetCaptureTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled,
                  capturedTimingGeneration == subtitleTimingGeneration,
                  capturedTimingScope == SubtitleTimingScope(
                    contentKey: communityContentKey,
                    releaseFingerprint: subFingerprint
                  ) else { return }
            let offsetMs = Int((delaySeconds * 1000).rounded())
            await SubtitlePoolClient.postOffset(contentKey: capturedContentKey, lang: "",
                                                fingerprint: capturedFingerprint, offsetMs: offsetMs)
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
                if !row.detail.hasSuffix("›"), let open = panel, open.dismissesAfterPick {
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
            .disabled(!row.isEnabled)
            .opacity(row.isEnabled ? 1 : 0.6)
            .accessibilityLabel(row.label)
            .accessibilityValue(row.detail)
            .accessibilityHint(row.accessibilityHint)
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
            return allEpisodeRefs.map { ep in
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
            // Settings FIRST (the primary in-session action), then Off, then one row per language. Each
            // language row drills into `.subtitleLanguage`, which lists every sub in that language across
            // embedded + add-on + community sources, so a title with dozens of subs no longer forces one
            // long flat scroll.
            let mpvEngine = coordinator.player as? MPVMetalViewController
            let secondaryID = mpvEngine?.secondarySubtitleID ?? -1
            let dualActive = secondaryID >= 0
            let primaryID = mpvEngine?.primarySubtitleID ?? -1
            let primaryOff = dualActive
                ? (primaryID < 0)
                : subtitleTracks.allSatisfy { !$0.selected || !$0.isSelectable }
            var rs: [Row] = [Row(label: String(localized: "Subtitle Settings"), detail: "›") { openPanel(.subtitleSettings) }]
            rs.append(Row(label: String(localized: "Off"), selected: primaryOff) {
                userPickedSubtitle = true
                VXProbe.log("subs", "selected track off")
                coordinator.player?.setSubtitleTrack(-1)
            })
            // External subtitles from the installed subtitle add-ons. These work on BOTH engines now: libmpv
            // sub-adds the downloaded file; AVPlayer parses it and renders the cues over the video itself. When
            // the opt-in "only preferred languages" toggle is on, non-preferred languages are hidden
            // (unknown-language subs always kept so the list never empties).
            let availableAddon = TrackSelector.keepingPreferredSubtitleLanguages(
                addonSubs.filter { !addedSubURLs.contains($0.url) }, language: { $0.lang })
            // Community-pooled subtitles (P2): other users' extracted subs for this title. Same opt-in
            // preferred-language filter as the add-on rows above.
            let availablePooled = TrackSelector.keepingPreferredSubtitleLanguages(
                pooledSubs.filter { !addedPooledIDs.contains($0.id) }, language: { $0.lang })
            // Union of every language offered by ANY source, each with its total count.
            var languageCounts: [String: Int] = [:]
            for t in subtitleTracks { languageCounts[subtitleLanguageKey(t.lang), default: 0] += 1 }
            for s in availableAddon { languageCounts[subtitleLanguageKey(s.lang), default: 0] += 1 }
            for s in availablePooled { languageCounts[subtitleLanguageKey(s.lang), default: 0] += 1 }
            for code in languageCounts.keys.sorted(by: { langName($0) < langName($1) }) {
                let count = languageCounts[code] ?? 0
                let hasSelection = subtitleTracks.contains {
                    let tSel = dualActive ? $0.id == primaryID : $0.selected
                    return $0.isSelectable && tSel && subtitleLanguageKey($0.lang) == code
                }
                rs.append(Row(label: langName(code), detail: "\(count) ›", selected: hasSelection) {
                    openPanel(.subtitleLanguage(code: code, label: langName(code)))
                })
            }
            if languageCounts.isEmpty {
                rs.append(Row(label: String(localized: "No subtitles available"), isHeader: true))
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
            return rs
        case .subtitleLanguage(let code, _):
            // One language's complete sub list: embedded tracks first, then add-on, then community.
            let mpvEngine = coordinator.player as? MPVMetalViewController
            let secondaryID = mpvEngine?.secondarySubtitleID ?? -1
            let dualActive = secondaryID >= 0
            let primaryID = mpvEngine?.primarySubtitleID ?? -1
            let primarySel: ((MPVTrack) -> Bool)? = dualActive ? { $0.id == primaryID } : nil
            var rs: [Row] = []
            let embedded = subtitleTracks.filter { subtitleLanguageKey($0.lang) == code }
            if !embedded.isEmpty {
                rs.append(Row(label: String(localized: "Embedded"), isHeader: true))
                for (i, t) in embedded.enumerated() {
                    rs.append(Row(
                        label: t.title.isEmpty ? "Track \(i + 1)" : t.title,
                        detail: t.unavailableReason ?? "",
                        selected: t.isSelectable && (primarySel?(t) ?? t.selected),
                        isEnabled: t.isSelectable
                    ) {
                        guard t.isSelectable else { return }
                        userPickedSubtitle = true
                        VXProbe.log("subs", "selected embedded track \(t.id)")
                        coordinator.player?.setSubtitleTrack(t.id)
                    })
                }
            }
            let languageAddon = TrackSelector.keepingPreferredSubtitleLanguages(
                addonSubs.filter { !addedSubURLs.contains($0.url) && subtitleLanguageKey($0.lang) == code },
                language: { $0.lang })
            if !languageAddon.isEmpty {
                rs.append(Row(label: String(localized: "From add-ons"), isHeader: true))
                for sub in languageAddon.prefix(60) {
                    let loading = subtitleLoadingURL == sub.url
                    rs.append(Row(label: sub.addonName, detail: loading ? String(localized: "Loading…") : String(localized: "Add-on")) {
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
                        if panelShowsSubtitleList { panelRows = rows(for: panel ?? .subtitles) }   // reflect Loading… in place
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
                            if ok, player === coordinator.player {
                                applyCurrentSubtitleDelayIfReady(force: false)
                            }
                            if panelShowsSubtitleList { panelRows = rows(for: panel ?? .subtitles) }
                        }
                    })
                }
            }
            let languagePooled = TrackSelector.keepingPreferredSubtitleLanguages(
                pooledSubs.filter { !addedPooledIDs.contains($0.id) && subtitleLanguageKey($0.lang) == code },
                language: { $0.lang })
            if !languagePooled.isEmpty {
                rs.append(Row(label: String(localized: "Community"), isHeader: true))
                for sub in languagePooled.prefix(60) {
                    let loading = subtitleLoadingURL == sub.url.absoluteString
                    rs.append(Row(label: pooledLabel(sub), detail: loading ? String(localized: "Loading…") : String(localized: "Community")) {
                        userPickedSubtitle = true
                        selectPooledSubtitle(sub)
                    })
                }
            }
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
            rs.append(Row(label: String(localized: "Font"), isHeader: true))
            for f in SubtitleStyle.fonts { rs.append(Row(label: Self.l10n(f.label), selected: subFont == f.id) { setSubtitleFont(f.id) }) }
            rs.append(Row(label: String(localized: "Size"), isHeader: true))
            for s in SubtitleStyle.sizes { rs.append(Row(label: Self.l10n(s.label), selected: subSize == s.id) { setSubtitleSize(s.id) }) }
            let scalePct = "\(Int((subSizeScale * 100).rounded()))%"
            rs.append(Row(label: String(localized: "Smaller  −"), detail: scalePct) { adjustSubScale(-1) })
            rs.append(Row(label: String(localized: "Bigger  +"), detail: scalePct) { adjustSubScale(1) })
            rs.append(Row(label: String(localized: "Colour"), isHeader: true))
            for c in SubtitleStyle.colors { rs.append(Row(label: Self.l10n(c.label), selected: subColor == c.id) { setSubtitleColor(c.id) }) }
            rs.append(Row(label: String(localized: "Brightness"), isHeader: true))
            for b in SubtitleStyle.brightnessLevels { rs.append(Row(label: b.label, selected: subBrightness == b.id) { setSubtitleBrightness(b.id) }) }
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
                    selected: playableURL(for: opt.stream) == curURL,
                    accessibilityHint: "Switches at the current playback position") {
                    if let url = playableURL(for: opt.stream) {
                        switchStream(to: opt.stream, url: url, userInitiated: true, explicitPick: true,
                                     addon: addonName(for: opt.stream))
                    }
                }
            }
        case .sources:
            return sourceRows()
        case .sourceAudio:
            return audioLanguageFilterRows()
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
                let hardwareDetail = (coordinator.player as? MPVMetalViewController)?
                    .hardwareDecoderSettingDetail ?? "recommended"
                rows.append(Row(label: "Decoder", isHeader: true))
                rows.append(Row(label: "Hardware", detail: hardwareDetail, selected: hw) {
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
            if let m = curMeta, SkipEditPolicy.canEdit(isLiveContent: isLive, contentId: m.libraryId) {
                rows.append(Row(label: "Contribute", isHeader: true))
                rows.append(Row(label: showSkipDBEdit ? "Close skip editor" : "Submit skip segment",
                                detail: showSkipDBEdit ? "" : "at \(timeString(currentTime))") {
                    if !showSkipDBEdit { seedSkipDBEditor() }
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
                let detail = [
                    t.title.isEmpty ? nil : t.title,
                    t.unavailableReason
                ].compactMap { $0 }.joined(separator: " · ")
                rs.append(Row(
                    label: langName(code),
                    detail: detail,
                    selected: t.isSelectable && sel(t),
                    isEnabled: t.isSelectable
                ) {
                    guard t.isSelectable else { return }
                    select(t.id)
                })
            } else {
                rs.append(Row(label: langName(code), isHeader: true))
                for (i, t) in ts.enumerated() {
                    rs.append(Row(
                        label: t.title.isEmpty ? "Track \(i + 1)" : t.title,
                        detail: t.unavailableReason ?? "",
                        selected: t.isSelectable && sel(t),
                        isEnabled: t.isSelectable
                    ) {
                        guard t.isSelectable else { return }
                        select(t.id)
                    })
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

    /// Canonical key for the per-language subtitle groups: lowercase, with 3-letter ISO 639-2 codes folded
    /// to their 2-letter base (eng -> en) so embedded, add-on and community subs share one language row.
    /// Empty / und / unknown all fold to "und" (one "Unknown" bucket), mirroring `groupedTrackRows`.
    private func subtitleLanguageKey(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, trimmed != "und", trimmed != "unknown" else { return "und" }
        if Locale.current.localizedString(forLanguageCode: trimmed) != nil { return trimmed }
        if let base = Locale(identifier: trimmed).language.languageCode?.identifier, base != trimmed {
            return base
        }
        return trimmed
    }

    /// True while a subtitle panel is open (the language menu or one language's sub list), so async
    /// subtitle arrivals (add-on fetch, pooled downloads) refresh the open panel instead of only the
    /// flat list that used to be the single subtitles surface.
    private var panelShowsSubtitleList: Bool {
        switch panel {
        case .subtitles, .subtitleLanguage: return true
        default: return false
        }
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

    /// The add-on NAME that supplied `stream` - the app-owned identity `StreamRanking` matches a pin, the
    /// sticky record and the provider-health penalty on (`manifest.name`), as opposed to `engineAddonBase`'s
    /// base URL, which the engine uses for attribution. nil when the stream is not in the loaded groups
    /// (a pasted link, or a Continue-Watching resume whose sources have not arrived yet). Mirrors tvOS.
    private func addonName(for stream: CoreStream) -> String? {
        currentSourceGroups.first { $0.streams.contains(stream) }?.addon
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
    /// Session audio-language filter rows for the `.sources` panel, matching the tvOS/iOS source-picker
    /// chip (#204): an "Audio" header with "Auto" + the curated language list. Selecting a language sets
    /// `sessionAudioLanguages`, which re-ranks the list below so releases carrying that audio float up.
    private func audioLanguageFilterRows() -> [Row] {
        var rs: [Row] = [Row(label: String(localized: "Audio"), isHeader: true)]
        rs.append(Row(label: String(localized: "Auto"), selected: sessionAudioLanguages == nil) {
            sessionAudioLanguages = nil
        })
        for lang in TrackPreferences.commonLanguages {
            rs.append(Row(label: lang.label, selected: sessionAudioLanguages == [lang.id]) {
                sessionAudioLanguages = [lang.id]
            })
        }
        return rs
    }

    private func sourceRows() -> [Row] {
        let perAddon = 5
        let maxInPlayerSources = 60
        let groups = currentSourceGroups
        if groups.isEmpty { return [Row(label: "Loading sources…", isHeader: true)] }
        var rs: [Row] = []
        if !StreamRanking.resolutionOptions(groups).isEmpty {
            rs.append(Row(label: "Quality", detail: "›",
                          accessibilityHint: "Choose a quality and keep the current playback position") {
                openPanel(.quality)
            })
        }
        rs.append(Row(label: "Audio", detail: "›",
                      accessibilityHint: "Filter sources by audio language") {
            openPanel(.sourceAudio)
        })
        rs.append(Row(label: "Sources", isHeader: true))
        var count = 0
        // Install the session audio-language filter as a task-local for the ranking reads only: #204 does
        // the same in SourceListModel's detached rank. `StreamRanking.score` -> `languageScore` reads
        // `TrackPreferences.current.audioLanguages` live at score time (StreamRanking.swift:561), so this
        // is what actually floats the chosen-audio release above a same-resolution foreign-audio one. Nil
        // (Auto) installs nothing and falls back to the persisted profile preference, exactly as tvOS/iOS.
        TrackPreferences.$audioLanguagesOverride.withValue(sessionAudioLanguages) {
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
                                  selected: sURL == curURL,
                                  accessibilityHint: "Switches at the current playback position") {
                        switchStream(to: stream, url: sURL, userInitiated: true, explicitPick: true,
                                     addon: group.addon)
                    })
                }
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
        pooledSeededOffset = true
        applyCurrentSubtitleDelayIfReady(force: true)
        VXProbe.log("subs", "synced delay=\(String(format: "%+.1f", subDelay))s")
        captureSubOffset()   // P3: pool the user-corrected offset (debounced, gated, fail-soft)
        scheduleSubOffsetSave()   // remember this title's manual offset (debounced: one write per burst)
    }
    private func adjustAudioDelay(_ delta: Double) {
        audioDelay = ((audioDelay + delta) * 10).rounded() / 10
        coordinator.player?.setAudioDelay(audioDelay)
    }
    // In-player style tweaks also stick to the active profile (Settings does the same). The profile
    // capture is DEBOUNCED: pressing Bigger five times fast must not encode + persist the whole roster
    // five times on the main thread (the subtitle-settings lag), only once, 0.7s after the last press.
    @State private var stylePrefsSaveTask: Task<Void, Never>?
    private func schedulePlaybackPrefsSave() {
        stylePrefsSaveTask?.cancel()
        stylePrefsSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            ProfileStore.shared.capturePlayback()
        }
    }
    private func setSubtitleFont(_ id: String) {
        subFont = id; coordinator.player?.applySubtitleStyle(); schedulePlaybackPrefsSave()
    }
    private func setSubtitleSize(_ id: String) {
        subSize = id; coordinator.player?.applySubtitleStyle(); schedulePlaybackPrefsSave()
    }
    private func adjustSubScale(_ direction: Int) {
        let next = subSizeScale + Double(direction) * SubtitleStyle.sizeScaleStep
        let clamped = min(max(next, SubtitleStyle.sizeScaleRange.lowerBound), SubtitleStyle.sizeScaleRange.upperBound)
        subSizeScale = (clamped * 100).rounded() / 100
        coordinator.player?.applySubtitleStyle(); schedulePlaybackPrefsSave()
    }
    private func setSubtitleColor(_ id: String) {
        subColor = id; coordinator.player?.applySubtitleStyle(); schedulePlaybackPrefsSave()
    }
    private func setSubtitleBrightness(_ id: String) {
        subBrightness = id; coordinator.player?.applySubtitleStyle(); schedulePlaybackPrefsSave()
    }
    private func setSubtitleBackground(_ id: String) {
        subBackground = id; coordinator.player?.applySubtitleStyle(); schedulePlaybackPrefsSave()
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
        let exitLoadToken = coordinator.player?.activeLoadToken
        let assetSanityAccepted = assetSanityAttempt.isAccepted(owner: exitLoadToken)
        cancelTerminalFinalityRefresh()
        flushPendingSubOffsetSave()   // a debounced sync nudge must survive the viewer leaving immediately
        invalidateEpisodeWorkForExit()
        if !persistenceBlockedForExit, assetSanityAccepted, !effectivelyLive, duration > 0,
           currentTime / duration >= 0.9, let m = curMeta {
            if !m.usesSeriesLifecycle, terminalRewindGate.issueTerminalRewind() {
                core.finishedWatching(libraryId: m.libraryId)
            }
        }
        invalidateLocalTrickplayCapture()
        cancelAssetSanityObservationDeadline()
        hideTask?.cancel(); loadTimeout?.cancel(); autoRetryTask?.cancel(); idleWatchTask?.cancel()
        stallWatchdog?.cancel(); recoveryDeadline?.cancel(); skipFetchTask?.cancel()
        postFrameResumeSeekWatchdog?.cancel()
        #if os(iOS) || os(macOS)
        avStartWatchdog?.cancel()
        avToMPVHandoffTask?.cancel()
        #endif
        if assetSanityAccepted {
            scrubThumbnails.finishAndUploadIfNeeded(srcHeight: videoHeight)
        }
        if terminalRewindGate.permitsExitProgressFlush,
           assetSanityAccepted, !effectivelyLive, duration > 0 {
            reportProgress(currentTime, acceptedOwner: exitLoadToken)
        }
        // External sync (Trakt/SIMKL): scrobble STOP on a genuine user exit. Additive + fail-soft + gated +
        // once-latched inside the coordinator; a no-op with empty creds. Near the end this records the watch
        // (deduped against the 90%/EOF record); mid-title it saves a resume/pause point (live scrobble only).
        if !persistenceBlockedForExit, assetSanityAccepted,
           !effectivelyLive, let m = curMeta {
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
        let remuxOwnsInitialAudio =
            (coordinator.player as? AVPlayerEngineController)?.isRemuxMounted == true
        let automaticAudio = TrackSelector.automaticAudioSelection(
            pick.audio,
            remuxOwnsInitialSelection: remuxOwnsInitialAudio)
        if let automaticAudio { coordinator.player?.setAudioTrack(automaticAudio) }
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
        let audioSelectionLog = remuxOwnsInitialAudio
            ? "preselected" : (automaticAudio.map(String.init) ?? "none")
        VXProbe.log("subs", "auto-select sub=\(pick.subtitle.map(String.init) ?? "none") audio=\(audioSelectionLog)")
        contributeContainerLanguagesIfNeeded()   // pool the file's REAL track langs (provenance "container")
        refreshSoon()
        // The container had no track in the preferred language chain (subs stayed off): try the add-on list.
        // Either completion point can land first (tracks vs the add-on fetch), so both call this; the guards
        // + the one-shot latch inside make the double call safe. No-op when userPickedSubtitle is set (an
        // explicit pick, incl. one just re-applied above, hard-stops the async add-on auto path).
        autoSelectAddonSubtitleIfNeeded()
        // Restore local v2 state only after tracks are ready. The track-list handler applies it once for the
        // exact engine load token below.
        restoreSubtitleTimingOffsetIfReady()
    }

    /// Push a resume/progress position to the presenter, refusing to REGRESS the stored resume below a
    /// suppressed-resume floor. A DV-remux switch that starts at 0 (forward-only, the resume seek is dropped)
    /// keeps the real resume point only in `suppressedResumeFloor`; without this the periodic saves and the
    /// exit flush would overwrite the account resume with the restarted-low position. The floor clears once
    /// the playhead passes it (the viewer caught up) or on the next source/episode load.
    private func reportProgress(
        _ position: Double,
        acceptedOwner: PlayerLoadToken? = nil
    ) {
        let integrityOwner = acceptedOwner ?? coordinator.player?.activeLoadToken
        guard assetSanityAttempt.isAccepted(owner: integrityOwner) else { return }
        guard !hasUncommittedIssuedMedia, !persistenceBlockedForExit else { return }
        if let floor = suppressedResumeFloor {
            if position < floor { return }
            suppressedResumeFloor = nil
        }
        if engineWritesOpen { onProgress(position, duration) }
        saveAccountProgress(position, acceptedOwner: integrityOwner)
    }

    /// Persist a user-initiated seek (skip buttons, macOS arrow keys, slider commit) to the presenter, which
    /// writes it to BOTH the engine library and the account. Mirrors `reportProgress`' resume-floor guard for
    /// the onSeek lane (and the tvOS scrub-commit gate): a forward seek off the remux restart-at-0 must not
    /// overwrite the real account resume until the playhead has actually passed the floor. The floor clears
    /// once passed. Backward / non-suppressed seeks pass straight through.
    private func reportSeek(_ target: Double) {
        guard assetSanityAttempt.isAccepted(owner: coordinator.player?.activeLoadToken) else { return }
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
    private func saveAccountProgress(
        _ position: Double,
        acceptedOwner: PlayerLoadToken? = nil
    ) {
        let integrityOwner = acceptedOwner ?? coordinator.player?.activeLoadToken
        guard assetSanityAttempt.isAccepted(owner: integrityOwner) else { return }
        guard !hasUncommittedIssuedMedia, !persistenceBlockedForExit else { return }
        guard let m = curMeta else { return }
        let dur = duration
        Task { await account.saveProgress(for: m, positionSeconds: position, durationSeconds: dur) }
    }

    /// Snapshot the viewer's CURRENT explicit subtitle selection so a following engine switch can re-apply it
    /// (mandated check 8). Off when no track is selected; otherwise an add-on / pooled external sub (matched
    /// back by language against the added set) or an embedded track (by lang/title).
    private func captureSubtitleChoice() -> SubtitleChoice {
        guard let sel = subtitleTracks.first(where: {
            $0.selected && $0.isSelectable
        }) else { return .off }
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
            let match = subtitleTracks.first {
                $0.isSelectable
                    && $0.lang.lowercased() == l
                    && $0.title.lowercased() == t
            } ?? subtitleTracks.first {
                $0.isSelectable && $0.lang.lowercased() == l
            }
            coordinator.player?.setSubtitleTrack(match?.id ?? -1)
        case let .external(urlStr, title, lang):
            guard let player = coordinator.player else { return }
            let subtitleLoadToken = player.activeLoadToken
            let subtitleVideoID = curMeta?.videoId
            player.addExternalSubtitle(url: urlStr, title: title, lang: lang) { ok in
                guard permitsSubtitlePublication(loadToken: subtitleLoadToken, videoID: subtitleVideoID) else { return }
                if ok, player === coordinator.player {
                    addedSubURLs.insert(urlStr)
                    applyCurrentSubtitleDelayIfReady(force: false)
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
        guard stillWatchingPromptEnabled else { return }   // disabled: never interrupt an idle session
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
        // Always pause whatever is on screen so the prompt never plays over a running video (a boundary whose
        // file already ended pauses a no-op; a next episode that already began is stopped). Continue resumes.
        if !isPaused { coordinator.player?.togglePause() }
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
