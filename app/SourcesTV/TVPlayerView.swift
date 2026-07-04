import SwiftUI
import UIKit
import os

/// Full-screen libmpv player for tvOS. All remote input is handled at the UIKit level by a focusable
/// `RemoteCatcher` (pressesBegan), and the control bar / options panel are driven by plain state with
/// no SwiftUI focus, because SwiftUI `@FocusState` is unreliable inside a full-screen cover on tvOS.
/// Shares the MPVKit core with the iOS app.
struct TVPlayerView: View {
    let url: URL
    let title: String
    var meta: PlaybackMeta? = nil          // when set, resume + record watch progress to the library
    var episodes: [CoreVideo] = []             // series' ordered episodes (empty for movies) → Next/Prev/list
    var sourceHint: String? = nil              // quality signature of the launching stream (source continuity)
    var torrent: Bool = false                  // stream rides the embedded torrent engine (gets warm-up patience)
    var bingeGroup: String? = nil              // the launching stream's release-group tag, for sticky auto-next
    var headers: [String: String]? = nil       // HTTP headers the stream's add-on requires (proxyHeaders)
    var forceMPV: Bool = false                 // last-resort escape hatch: skip AVPlayer routing, mount libmpv directly
    var isTrailer: Bool = false                // FIX I: a trailer clip, not a content stream → never fail over to engine streams
    var audioSidecarURL: URL? = nil            // yt-direct adaptive pair: external audio mpv mounts with the video-only url (forces libmpv)
    var debridRef: DebridPlaybackRef? = nil    // native-debrid provenance of the launching link, for CW reresolve of an expired link
    /// True when the LAUNCH source was an explicit user choice (a tapped source-list row / quality pick),
    /// false for an auto-pick (Watch Now / a Continue-Watching resume). An explicit pick is HONORED on a
    /// start-timeout: retry the SAME source in place with a longer first-buffer grace rather than silently
    /// hopping to a different, often lower-quality, source. Only the auto path may auto-hop.
    var startedFromExplicitPick: Bool = false
    var onClose: () -> Void = {}           // dismiss the dedicated player window

    /// The pinned source for this title (#15), so in-player failover, auto-next, and preload keep using the
    /// user's pinned provider/quality across episodes - and still hop off it if it dies.
    private var sourcePin: ResolvedPin? {
        // Use the LIVE episode meta (curMeta), falling back to the launch prop before it is set. For a
        // series both carry the same show libraryId, but curMeta is the canonical source of truth across
        // auto-next transitions. Read fresh at each failover/auto-next/preload, so a new pin is honoured.
        guard let m = curMeta ?? meta else { return nil }
        return SourcePinStore.shared.effectivePin(SourcePinContext(metaId: m.libraryId, isSeries: m.type == "series"))
    }

    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @State private var markedWatched = false   // mark the engine watched once, near end of playback
    @State private var autoAddedThisPlayback = false   // D8/D9: the ~60s auto-add + watch-ping fires once per playback
    @AppStorage("stremiox.autoAddLibrary") private var autoAddLibrary = true   // "Auto-add watched to Library" (default ON)
    @AppStorage("stremiox.playerVolume") private var playerVolume = 100.0   // "Default volume" (D5): level a new playback starts at, SAME key as iOS/Mac
    @StateObject private var coordinator = MPVMetalPlayerView.Coordinator()
    @State private var buffering = true
    @State private var isPaused = false
    @State private var currentTime = 0.0
    @State private var duration = 0.0
    @State private var bufferedTime = 0.0       // buffered-ahead edge (seconds) for the YouTube-style grey scrubber band
    @State private var videoWidth = 0           // metadata line: encoded width (resolution is by WIDTH, so 2.40:1 4K is not mislabeled 1440p)
    @State private var videoHeight = 0          // metadata line: encoded height
    @State private var audioCodec = ""          // metadata line: active audio codec (e.g. "eac3")
    @State private var isHDR = false            // metadata line: HDR/DV detected (sig-peak > 1)
    @State private var resumeSeconds: Double? = nil   // nil until fetched; applied once duration known
    @State private var appliedResume = false
    @State private var lastSaved = -1.0               // last position persisted (throttle)
    @State private var showInfo = true
    @State private var hideTask: Task<Void, Never>?
    @State private var hideDeadline: Date = .distantFuture   // controls auto-hide once now passes this
    @State private var audioTracks: [MPVTrack] = []
    @State private var subtitleTracks: [MPVTrack] = []
    @State private var appliedAutoTracks = false       // auto-select audio/subtitle once per load
    // External subtitles from the account's subtitle add-ons (e.g. OpenSubtitles), listed in the
    // subtitles panel next to the file's embedded tracks. Picking one sub-adds it into mpv, after
    // which it lives in the normal track list; addedSubURLs hides its add-on row.
    @State private var addonSubs: [AddonSubtitle] = []
    @State private var addedSubURLs: Set<String> = []
    @State private var subtitleLoadingURL: String?     // an add-on subtitle is downloading (shows Loading… in its row)
    @State private var addonSubsKey = ""               // type:videoId the fetched list belongs to

    // Community-subtitle system (pooled subs P2, sync offset P3, embedded upload P4). All fail-soft + gated.
    @State private var pooledSubs: [SubtitlePoolClient.PooledSubtitle] = []
    @State private var pooledSubsKey = ""
    @State private var addedPooledIDs: Set<Int> = []
    @State private var pooledSeededOffset = false
    @State private var embeddedUploadDone = false
    @State private var offsetCaptureTask: Task<Void, Never>?
    @State private var subFingerprint: String?
    @State private var subFingerprintKey = ""
    @State private var showOptions = false             // options panel (audio / subtitles / aspect / episodes)
    @State private var panelKind: PanelKind = .audio   // which list the options panel shows
    @State private var subDelay: Double = 0            // manual subtitle sync, seconds
    @State private var audioDelay: Double = 0          // manual audio sync, seconds
    @AppStorage(SubtitleStyle.Key.font) private var subFont = SubtitleStyle.defaultFont
    @AppStorage(SubtitleStyle.Key.size) private var subSize = SubtitleStyle.defaultSize
    @AppStorage(SubtitleStyle.Key.sizeScale) private var subSizeScale = 1.0
    @AppStorage(SubtitleStyle.Key.color) private var subColor = SubtitleStyle.defaultColor
    @AppStorage(SubtitleStyle.Key.background) private var subBackground = SubtitleStyle.defaultBackground
    @State private var optionRow = 0                   // highlighted row in the options panel
    // Skip-segment editor (tvOS): the inline iOS/Mac editor bar is unavailable here, so the editor
    // lives in its own focus-driven options panel. State is tvOS-local; submission reuses SkipDBClient
    // (keyless to skip.vortx.tv, plus skipdb.tv / custom when keyed), exactly like the iOS path. The
    // editor is offered for any tt####### title (the same gate the iOS control-bar button uses).
    @State private var skipEditType: SkipDBSubmitView.SegmentType = .intro
    @State private var skipEditStart: Double = 0       // segment start, seconds; Left/Right adjust, Select = playhead
    @State private var skipEditEnd: Double = 30        // segment end, seconds
    @State private var skipEditSubmitting = false
    @State private var skipEditDone = false            // true once the current segment posted (shows the success row)
    @State private var skipEditError: String?          // last submit failure message, shown inline
    @State private var skipEditSubmittedKeys: Set<String> = []   // imdb:S:E:type already submitted this session
    // Time-row adjust acceleration, mirroring the scrubber's press-repeat ramp (10s → 75s on a hold).
    @State private var skipEditStep = 10.0
    @State private var skipEditLastAdjustAt = 0.0
    @State private var skipEditLastDir = 0   // last adjust direction; a reversal resets the ramp so it does not overshoot
    // Cached so the player body does not rebuild a string and rescan skip spans on
    // every playhead tick (audit #1): updated only when their inputs change.
    @State private var metadataLine = ""
    @State private var currentSkip: SkipSegment?
    @State private var autoSkippedStarts: Set<Double> = []   // segment starts already auto-skipped this episode
    /// Cumulative seek amount shown in a brief pill while seeking with the chrome HIDDEN (Netflix-style
    /// L/R seek that doesn't reveal the control bar). nil = no pill. Cleared after a short delay.
    @State private var hiddenSeekDelta: Double?
    @State private var hiddenSeekTask: Task<Void, Never>?
    // The open panel's rows, computed ONCE per open/refresh. The rows used to be a
    // computed property read by the panel body, which re-rendered ~4x a second with
    // the clock; for Sources that meant re-ranking a thousand-plus streams on the
    // main thread per frame, freezing the whole player (the "remote stopped
    // responding / sources came up a minute later" reports).
    @State private var panelRows: [OptionRow] = []
    @State private var loadFailed = false              // playback couldn't start
    @State private var loadErrorMsg = ""
    /// CW-resume only: set once we've waited for a freshly-loaded source after the stored link failed, so the
    /// wait-and-hop runs at most once per playback (TVPlayerView is fresh per playback, so it starts false).
    @State private var awaitedFreshSources = false
    @State private var hasStartedPlaying = false
    @State private var appliedVolume = false   // D5: the persisted default-volume apply runs once per load (re-armed on source switch/reload)
    // #76: AVPlayer could not open this stream (item status .failed); fell back to libmpv for it in place.
    // Flipping this re-renders `playerSurface` from AVPlayer to the mpv surface on the SAME TVPlayerView,
    // so the heavyweight forceMPV window rebuild is no longer needed for the common AVPlayer load failure.
    @State private var avEngineFailed = false
    // A brief, transient note explaining WHY the engine fell back (e.g. AVPlayer cannot demux DV-in-MKV),
    // so the silent demote the owner reported becomes an actionable explanation. Auto-clears after a few s.
    @State private var engineNote: String?
    @State private var engineNoteTask: Task<Void, Never>?
    // AVPlayer-only START watchdog: AVPlayer can mount, show the chrome, and silently never produce a
    // playable frame (no item error, no timePos tick). The real fix is in AVPlayerEngineController
    // (automaticallyWaitsToMinimizeStalling = false + explicit play() + the [.initial,.new] status race fix),
    // so a working stream now starts within a second or two; this watchdog is only the SAFETY NET for a
    // genuinely stuck stream. A working AVPlayer stream produces its first frame within a second or two, so a
    // no-frame mount is dead weight, not slow-buffering: 5s is long enough to clear a real start yet short
    // enough that the SILENT in-place demote to libmpv (which just tone-maps a DV link to HDR10) plays the SAME
    // source in about 5s instead of stalling 12s on dead chrome. It routes to the SAME libmpv fallback the
    // .failed case uses. AVPlayer-only: libmpv torrents warm up far longer under the 30s loadTimeout budget.
    @State private var avStartWatchdog: Task<Void, Never>?
    private let avStartWatchdogSeconds: Double = 5
    @State private var loadTimeout: Task<Void, Never>?
    @State private var autoRetryCount = 0              // bounded auto-recovery attempts before the error overlay
    @State private var reconnecting = false            // showing the "Reconnecting…" auto-retry state
    @State private var autoRetryTask: Task<Void, Never>?
    private let maxAutoRetries = 2                     // transient source hiccups recover; a dead link still falls through fast
    private let autoRetryBackoff = 1.2                 // seconds between auto-retries
    // Auto-failover: when a source spends its retry / stall / warm-up budget, hop to the
    // best-ranked UNTRIED source instead of dropping the viewer at the error overlay.
    @State private var exhaustedURLs: Set<URL> = []    // sources already given up on for this video
    @State private var sourceHops = 0                  // automatic source switches so far for this video
    private let maxSourceHops = 4                      // a fully-dead title still errors out, just later
    // Whether the CURRENTLY loading source was explicitly chosen by the user (seeded from
    // `startedFromExplicitPick`, updated on every in-player source/quality pick and auto-hop). An explicit
    // pick is retried in place on a start-timeout instead of hopping to a different, lower-quality source.
    @State private var currentPickWasExplicit = false
    // First-buffer grace for a big 4K remux on slow debrid: a start-timeout that fires while bytes are
    // still arriving (the demuxer-cache edge advanced since the watchdog armed) extends the wait rather
    // than declaring the source dead. Bounded by the extension count and the overall recovery deadline.
    @State private var lastBufferedAtWatchdog = -1.0
    @State private var bufferGraceUsed = 0
    private let maxBufferGraceExtensions = 3           // up to ~3×20s extra on top of the 30s watchdog, deadline-capped
    // Overall wall-clock cap on PRE-START recovery. The per-budget counters (30s load timeout x
    // retries, 2 torrent warm-ups, 4 source hops, stall reloads) are independent, so on a fully
    // dead title they could chain into minutes of spinner before the error overlay. This single
    // deadline spans the whole attempt (started once on the first load, persists across hops) and
    // gives up after maxRecoverySeconds regardless of which budget is live.
    @State private var recoveryDeadline: Task<Void, Never>?
    private let maxRecoverySeconds: Double = 150
    @State private var skipSegments: [SkipSegment] = []   // resolved skip spans (chapters + crowd timestamps)
    @State private var chapterFractions: [Double] = []    // chapter boundary positions (0...1) for scrubber ticks
    @State private var upNextSuppressed = false           // user chose Watch Credits: hide band + don't auto-advance this episode
    @State private var upNextWantsCredits = false         // which band button is focused (false = Play Now, true = Watch Credits)
    @AppStorage("stremiox.seekStep") private var seekStep = "10"   // skip step in seconds ("10"/"15"/"30"), shared with iOS
    @AppStorage("stremiox.autoSkip") private var autoSkip = false  // auto-skip intro/credits, shared with iOS/Mac
    private var seekStepSeconds: Double { Double(seekStep) ?? 10 }
    @State private var apiSkipCandidates: [SegmentCandidate] = []   // crowd-sourced spans for the current title
    @State private var skipFetchKey = ""                   // imdb:S:E the crowd spans belong to
    @State private var skipFetchTask: Task<Void, Never>?
    // Current episode (changes when switching via Next/Prev/Episodes or auto-advance). Seeded from
    // the passed url/title/meta in onAppear so the first load is unchanged.
    @State private var curURL: URL?
    @State private var curHeaders: [String: String]?   // the playing stream's required HTTP headers
    @State private var curTitle: String = ""
    @State private var curMeta: PlaybackMeta?
    // Next-episode preload: fetched + ranked in the background mid-episode so auto-advance is instant.
    @State private var preloaded: PreloadedEpisode?
    @State private var preloadingID: String?
    @State private var warmedID: String?               // next episode whose source was pre-warmed
    @State private var curHint: String?                // quality signature of what is playing now
    @State private var curBinge: String?               // bingeGroup of what is playing now (drives sticky auto-next)
    // Mid-playback stall recovery: a watchdog reloads the stream in place when the
    // position freezes while NOT buffering or paused (the black-screen / hard-stall
    // case), bounded so a genuinely dead source still falls through to the overlay.
    @State private var stallWatchdog: Task<Void, Never>?
    @State private var lastObservedTime = -1.0
    @State private var stalledTicks = 0
    @State private var stallRecoveries = 0
    // Direct-resume launches (Continue Watching) start without an episode list;
    // it loads in the background so Next/auto-advance still work.
    @State private var loadedEpisodes: [CoreVideo] = []
    @State private var curIsTorrent = false             // current stream is a torrent (switches/auto-next update it)
    @State private var curIsLive = false                // current stream is live HLS/IPTV (switches/auto-next update it)
    @State private var torrentStatus: String?           // live warm-up line ("Connecting to peers · 12 connected")
    @State private var torrentWarmupsUsed = 0           // bounded warm-up rounds before the error overlay
    @State private var playSpeed = 1.0                  // mpv playback speed (sticky for the session)
    @State private var showStats = false                // live playback info overlay
    @State private var statsRows: [(String, String)] = []
    @State private var showStreamQR = false             // QR overlay sharing the playing link to a phone
    @StateObject private var scrubThumbnails = ScrubThumbnailsStore()
    @State private var lastLocalTrickplayCapture = -1000.0
    @State private var localTrickplayCaptureInFlight = false
    /// Wall-clock trickplay capture driver (player-agnostic backstop to the timePos tick). See startTrickplayCaptureTimer.
    @State private var trickplayCaptureTimer: Task<Void, Never>?
    /// Capture cadence in seconds; matches the local cache tile interval + community upload interval.
    private static let trickplayCaptureIntervalSecs: Double = 10

    /// Which on-screen control is currently highlighted (driven by remote left/right, not SwiftUI focus).
    private enum Control: Hashable { case close, scrub, restart, back, play, fwd, audio, subs, aspect, playback, prev, next, episodes, chapters, sources, quality, settings, skipEdit }
    private enum PanelKind { case audio, audioSettings, subtitles, subtitleSettings, aspect, playback, episodes, chapters, sources, quality, playerSettings, skipEditor }
    @State private var selected: Control = .play
    @State private var lastButton: Control = .play     // remembered button-row spot, so up-then-down returns to it
    // Scrub-to-seek: left/right on the scrubber moves a preview playhead (accelerating on rapid/held
    // presses); the seek commits ~0.6s after the last move, or on Select. One mpv seek per gesture, so
    // holding to travel far doesn't thrash the decoder.
    @State private var scrubbing = false
    @State private var scrubTarget = 0.0
    @State private var scrubStep = 10.0
    @State private var lastScrubAt = 0.0
    @State private var scrubCommit: Task<Void, Never>?
    private let plog = Logger(subsystem: "com.stremiox.app", category: "tvplayer")

    private var controlsHidden: Bool { !showInfo && !showOptions && !loadFailed }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            playerSurface

            // UIKit owns ALL remote input. Presented in a dedicated key window so the focus engine has no
            // competitor and every press falls through to here. Swipes come via the pan recognizer.
            RemoteCatcher(onPress: { handlePress($0) }, onSwipe: { showControls() })

            if buffering && !loadFailed {
                VStack(spacing: Theme.Space.md) {
                    BigSpinner()
                    if let torrentStatus {
                        Text(torrentStatus)
                            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    } else if reconnecting {
                        Text(isCurrentLiveStream ? "Reconnecting live stream…" : "Reconnecting…  (\(autoRetryCount)/\(maxAutoRetries))")
                            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    } else if sourceHops > 0, !hasStartedPlaying {
                        Text("Source failed, trying another…  (\(sourceHops)/\(maxSourceHops))")
                            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showInfo && !showOptions && !loadFailed { controlBar }
            if showOptions { optionsPanel }
            if loadFailed { loadErrorOverlay }
            if controlsHidden, let seg = currentSkip, upNextRemaining == nil, !isCreditsUpNext { skipPill(seg) }
            if controlsHidden, let d = hiddenSeekDelta { hiddenSeekPill(d) }
            if controlsHidden, upNextRemaining != nil || isCreditsUpNext { upNextBand }
            if showStats, !loadFailed { statsOverlay }
            if showStreamQR, let link = shareLink {
                StreamLinkQRView(title: isTorrentPlayback ? "Magnet link" : "Stream link", link: link)
            }
            if let note = engineNote {
                Text(note)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.vertical, Theme.Space.md)
                    .frame(maxWidth: 900)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, Theme.Space.xl)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            VXProbeState.shared.setRoute("player")
            if curURL == nil {   // seed from initial request
                curURL = url; curTitle = title; curMeta = meta
                curIsTorrent = torrent; curHeaders = headers; curIsLive = initialLiveMode
                currentPickWasExplicit = startedFromExplicitPick   // honor an explicit launch pick on the first start-timeout
                maybeRouteToDefaultExternalPlayer()
            }
            scrubThumbnails.configure(localCacheKey: trickplayLocalCacheKey)
            configureCommunityTrickplayProvisional()
            startTrickplayCaptureTimer()   // wall-clock capture backstop (fires on both engines)
            if curHint == nil { curHint = sourceHint }
            if curBinge == nil { curBinge = bingeGroup }
            startStallWatchdog()
            scheduleHide(); startHideLoop()
            if episodes.isEmpty, let m = curMeta, loadedEpisodes.isEmpty {
                // Direct resume launches with no meta loaded: fetch it behind playback
                // so the sources panel shows THIS title (not whatever detail page was
                // open last), and series get their episode list for Next/auto-advance.
                Task { @MainActor in
                    core.loadMeta(type: m.type, id: m.libraryId, streamType: m.type, streamId: m.videoId)
                    guard m.type == "series" else { return }
                    for _ in 0..<40 {
                        if let loaded = core.metaDetails?.meta, loaded.id == m.libraryId,
                           let vids = loaded.videos, !vids.isEmpty {
                            loadedEpisodes = vids
                            plog.info("episode list loaded behind direct resume: \(vids.count)")
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            showInfo = true; selected = .play; scheduleHide(); startLoadTimeout()
            UIApplication.shared.isIdleTimerDisabled = true   // stop the Apple TV screensaver during playback
            if let m = curMeta {
                if let engineResume = core.engineResumeSeconds(for: m) {
                    resumeSeconds = engineResume; maybeResume()       // engine library = source of truth
                } else {
                    Task { @MainActor in resumeSeconds = await account.resumeOffset(for: m); maybeResume() }
                }
            } else {
                resumeSeconds = 0   // selftest / no library context, nothing to resume
            }
        }
        .onDisappear {
            hideTask?.cancel(); loadTimeout?.cancel(); recoveryDeadline?.cancel(); autoRetryTask?.cancel(); skipFetchTask?.cancel(); stallWatchdog?.cancel(); avStartWatchdog?.cancel(); engineNoteTask?.cancel(); trickplayCaptureTimer?.cancel()
            // Community trickplay: contribute this device's captured frames as a shared sprite-sheet
            // (first-writer-wins, background, gated; no-op if the community already had a set, or on AVPlayer
            // which captures nothing). Independent of the engine-teardown rules below.
            scrubThumbnails.finishAndUploadIfNeeded(srcHeight: videoHeight)
            saveProgress(at: currentTime)   // no-op for live
            if !isCurrentLiveStream {
                core.reportProgress(timeSeconds: currentTime, durationSeconds: duration)   // flush final position (never for live)
            }
            // The engine is NOT torn down here: RootView presents the player with `.id(req.id)`, so any
            // path that mints a fresh PlaybackRequest id rebuilds the player → onDisappear → would
            // destroy an engine that's about to be reused. (In-player source picks go through switchStream
            // in place and never rebuild, but tearing the engine down on every disappear is still wrong.)
            // Teardown happens only on genuine exits (see leavePlayback()), which onClose routes through.
            // App-backgrounding is deliberately NOT a teardown trigger: tvOS suspends the app AND the
            // embedded server together, the same player stays mounted, and returning to .active resumes
            // on the same engine — closing it on .background would kill background-resume without
            // preventing any leak (an app the system kills while suspended takes the server, and every
            // engine with it, down too). In-session leaks are covered by the switch / advance / exit paths.
            UIApplication.shared.isIdleTimerDisabled = false   // let the screensaver resume once the player closes
        }
    }

    // MARK: - Video surface (engine-routed under the same chrome)

    /// Whether to mount the AVFoundation engine instead of libmpv for this stream (#76). Routes on the RAW
    /// (un-proxied) launch URL: torrents and loopback URLs always stay on libmpv (the router enforces this),
    /// and Dolby Vision in an AVPlayer-playable container / remote HLS auto-routes to AVPlayer for true DV
    /// passthrough, AirPlay, and Picture in Picture. On an AVPlayer load failure we fall back to libmpv for
    /// this stream (`avEngineFailed`). The DV flag comes from the launching stream's quality text (`sourceHint`).
    private var useAVPlayerEngine: Bool {
        if forceMPV || avEngineFailed { return false }   // escape hatch / an AVPlayer load failure fell back to libmpv
        // A yt-direct adaptive pair NEEDS libmpv (the audio sidecar rides mpv --audio-files; AVPlayer
        // would play the video-only stream silent), so it bypasses AVPlayer routing entirely.
        if audioSidecarURL != nil { return false }
        let loopback = url.host == "127.0.0.1" || url.host == "localhost"
        let isDV = StreamRanking.isDolbyVision(sourceHint ?? "")
        // tvOS: DVDisplaySupport.isCapable is constant true (the Apple TV negotiates DV over HDMI), so the DV
        // mandate's remux lane engages for DV MKVs here too. Stable across renders (no engine flip mid-play).
        return PlayerEngineRouter.engine(for: url, isTorrent: torrent || loopback, isDolbyVision: isDV,
                                         dvDisplayCapable: DVDisplaySupport.isCapable) == .avfoundation
    }

    /// The video surface: the AVFoundation engine when routed there, otherwise libmpv. Both bind to the same
    /// Coordinator and feed the same `handleProperty`, so the surrounding chrome drives either unchanged. This
    /// mirrors `PlayerScreen.playerSurface` on iOS / macOS.
    @ViewBuilder private var playerSurface: some View {
        if useAVPlayerEngine {
            AVPlayerEngineView(coordinator: coordinator)
                .play(initialPlayback.url, headers: initialPlayback.headers)
                .live(initialLiveMode)
                .onPropertyChange { _, name, data in handleProperty(name, data) }
                .ignoresSafeArea()
        } else {
            MPVMetalPlayerView(coordinator: coordinator)
                .play(initialPlayback.url, headers: initialPlayback.headers, audioSidecar: audioSidecarURL)
                .live(initialLiveMode)
                .onPropertyChange { _, name, data in handleProperty(name, data) }
                .ignoresSafeArea()
        }
    }

    /// Whether the active player engine is AVFoundation (so the chrome can hide the rows AVPlayer has no
    /// equivalent for: external add-on subtitles, trickplay frame capture).
    private var isAVPlayerActive: Bool { coordinator.player is AVPlayerEngineController }

    // MARK: - Property handling (shared by both engines via the MPVProperty event bus)

    private func handleProperty(_ name: String, _ data: Any?) {
        switch name {
        case MPVProperty.pausedForCache: if let b = data as? Bool { buffering = b }
        case MPVProperty.pause:
            if let b = data as? Bool {
                isPaused = b
                UIApplication.shared.isIdleTimerDisabled = !b   // hold the TV awake while playing; let it sleep when paused
                if b { saveProgress(at: currentTime) }   // persist on pause
            }
        case MPVProperty.timePos:
            if let d = data as? Double {
                if d > 0, !hasStartedPlaying {            // playback actually began
                    hasStartedPlaying = true; loadTimeout?.cancel(); recoveryDeadline?.cancel(); recoveryDeadline = nil; loadFailed = false
                    avStartWatchdog?.cancel(); avStartWatchdog = nil   // a playable frame arrived: cancel the AVPlayer fallback
                    autoRetryCount = 0; reconnecting = false; autoRetryTask?.cancel()   // playback started: clear auto-recovery
                    applyDefaultVolume()            // D5: start at the user's saved "Default volume" (the launch mount begins at 100%)
                    // Live has no resumable position, so don't seed Continue-Watching direct-resume
                    // for it (mirrors PlayerScreen.recordLastStream's live guard).
                    if !isCurrentLiveStream, let m = curMeta, let u = curURL {   // remember the working link for direct resume
                        // Attach the native-debrid provenance only when the ORIGINAL launched link is what's
                        // playing (a source hop before first frame would make it stale); it lets a later CW
                        // resume mint a fresh link without the slow full add-on re-resolve.
                        let ref = (u == url) ? debridRef : nil
                        LastStreamStore.record(libraryId: m.libraryId, entry: .init(
                            videoId: m.videoId, url: u.absoluteString, title: curTitle,
                            season: m.season, episode: m.episode, name: m.name,
                            poster: m.poster, type: m.type, qualityText: curHint,
                            torrent: curIsTorrent, savedAt: Date(), headers: curHeaders,
                            debridService: ref?.service.rawValue, infoHash: ref?.infoHash,
                            debridFileId: ref?.fileId, debridTorrentId: ref?.torrentId, fileIdx: ref?.fileIdx,
                            linkSavedAt: ref != nil ? Date() : nil),
                            profileID: ProfileStore.shared.activeID)
                    }
                    fetchPooledSubtitles()          // community-subtitle pool (P2/P3), fail-soft + gated
                    uploadEmbeddedSubtitlesIfNeeded()   // best-effort pooling of the file's own text tracks (P4)
                    // Add-on subtitles were fetched only from the `duration` event, which a debrid direct-HTTP
                    // MKV frequently never delivers, so the panel's "From add-ons" section stayed empty for
                    // exactly that content. Fetch at playback start too (key-latched, so at most one real
                    // fetch runs); the duration-event call remains for streams that deliver it first.
                    fetchAddonSubtitles()
                }
                currentTime = d
                updateCurrentSkip(at: d)
                // Ensure the community key is provisioned off meta.runtime the moment the behind-playback
                // meta lands (idempotent; no-op once keyed), so capture starts even without a duration event.
                configureCommunityTrickplayProvisional()
                maybeCaptureLocalTrickplay(at: d)
                // Live: no progress is persisted (saveProgress no-ops) and nothing is reported
                // to the engine — a live stream has no meaningful watch position.
                if !isCurrentLiveStream, lastSaved < 0 || abs(d - lastSaved) >= 20 {   // persist ~every 20s
                    lastSaved = d
                    saveProgress(at: d)
                    core.reportProgress(timeSeconds: d, durationSeconds: duration)   // live -> engine
                }
                if !markedWatched, duration > 0, d / duration >= 0.9, let m = curMeta {
                    markedWatched = true            // ~90% in → flip the watched marker live
                    core.markPlaybackWatched(m)
                }
                // ~60s in → the user is really watching this: auto-add to the Library (D8) + send the anon
                // fleet watch ping (D9), once per playback. Idempotent + gated (D8 setting + per-profile dedup;
                // D9 MoatConsent + per-title/day dedup); skipped for live and ad-hoc plays.
                if !autoAddedThisPlayback, !isCurrentLiveStream, d >= 60, let m = curMeta {
                    autoAddedThisPlayback = true
                    LibraryAutoAdd.addIfNeeded(meta: m, core: core, enabled: autoAddLibrary)
                    WatchSignalClient.ping(contentId: m.libraryId, type: m.type)
                }
                if duration > 0, d / duration >= 0.5 { preloadNextIfNeeded() }   // halfway → ready the next episode
                if duration > 0, duration - d <= 100 { warmNextIfReady() }       // near the end → wake the provider
            }
        case MPVProperty.videoParamsSigPeak:
            if let p = data as? Double { isHDR = p > 1.0; metadataLine = computeMetadataLine() }
        case MPVProperty.duration:
            if let d = data as? Double {
                duration = d; maybeResume(); refreshSkipSegments(); fetchSkipTimestamps(); fetchAddonSubtitles()
                // Community trickplay: re-key on the REAL playback duration (this is the authoritative bucket)
                // and unblock uploads. Capture already started from onAppear's provisional runtime key, so a
                // debrid MKV that never delivers this event still captures + can upload via the provisional key.
                if d > 0, let m = curMeta {
                    scrubThumbnails.configureCommunity(imdbId: m.libraryId, season: m.season, episode: m.episode,
                                                       duration: d, isRealDuration: true)
                }
                // The real duration sharpens the release fingerprint: rebuild it and re-fetch the pool so the
                // rip-matched community sync offset seeds this exact encode (P3). Fail-soft + gated inside.
                if d > 0 { refreshSubFingerprint(force: true); fetchPooledSubtitles() }
            }
        case MPVProperty.demuxerCacheTime:
            // Buffered-ahead edge (absolute seconds) for the YouTube-style grey scrubber band. Fail-soft:
            // ignore non-finite / behind-playhead values so the band never jumps backward or breaks.
            if let d = data as? Double, d.isFinite, d >= currentTime { bufferedTime = d }
        case MPVProperty.trackList:
            refreshTracks()
            let s = coordinator.player?.mediaSummary()
            videoWidth = s?.width ?? 0; videoHeight = s?.height ?? 0; audioCodec = s?.audioCodec ?? ""
            metadataLine = computeMetadataLine()
            if !appliedAutoTracks, !(audioTracks.isEmpty && subtitleTracks.isEmpty) {
                appliedAutoTracks = true
                let langs = subtitleTracks.map { langName($0.lang) }.joined(separator: ",")
                VXProbe.log("subs", "subs available n=\(subtitleTracks.count) langs=\(langs)")
                autoSelectTracks()
            }
        case MPVProperty.endFileError:
            loadTimeout?.cancel()
            if !hasStartedPlaying {
                // #76: an AVPlayer item failure before playback started (e.g. a Profile 7 DV remux or a
                // Matroska AVFoundation cannot demux) demotes to libmpv IN PLACE: flipping `avEngineFailed`
                // re-renders `playerSurface` to the mpv surface on the SAME view, which re-loads the stream.
                // This is the true last resort the owner asked for, replacing the heavyweight forceMPV window
                // rebuild for the common case. Genuine mpv failures fall through to the existing recovery.
                if demoteAVPlayerToMPV() { return }
                handleLoadFailure((data as? String) ?? "")
            }
        case MPVProperty.endFileEof:
            if handleLiveStreamEOF() { break }
            if !markedWatched, let m = curMeta { markedWatched = true; core.markPlaybackWatched(m) }
            autoAdvance()                                // episode finished → play next, else exit
        default: break
        }
    }

    // MARK: - Remote handling (all input arrives here from the UIKit catcher)

    private func handlePress(_ type: UIPress.PressType) {
        if showStreamQR {
            if type == .menu || type == .select || type == .playPause { showStreamQR = false }
            return
        }
        if loadFailed {
            switch type {
            case .menu: saveProgress(at: currentTime); leavePlayback()
            case .select:
                if !core.streamGroups().isEmpty {     // jump straight to another source
                    withAnimation { loadFailed = false }
                    openPanel(.sources)
                } else { retryLoad() }
            case .playPause: retryLoad()
            default: break
            }
            return
        }
        if showOptions {
            switch type {
            case .menu:
                switch panelKind {                       // Back from a settings sub-panel returns to its list
                case .audioSettings:    openPanel(.audio)
                case .subtitleSettings: openPanel(.subtitles)
                default:                closePanel()
                }
            case .upArrow: moveOption(-1)
            case .downArrow: moveOption(1)
            case .select: activateOption()
            // Left/Right adjust a focused Start/End row in the skip editor (the only panel that uses
            // horizontal input); every other panel ignores it, so the default no-op is unchanged.
            case .leftArrow:  if let f = focusedSkipField { adjustSkipTime(f, -1) }
            case .rightArrow: if let f = focusedSkipField { adjustSkipTime(f, 1) }
            default: break
            }
            return
        }
        if controlsHidden {
            // Up Next band visible: it owns Left/Right/Select/Down (pick + activate + dismiss) so they
            // never fall through to the seek-while-hidden nudge below. Menu (exit), Play/Pause, and Up
            // still behave normally, so the band never traps the remote.
            if upNextRemaining != nil || isCreditsUpNext {
                switch type {
                case .leftArrow:  upNextWantsCredits = false; return   // focus Play Now
                case .rightArrow: upNextWantsCredits = true;  return   // focus Watch Credits
                case .select:
                    if upNextWantsCredits { upNextSuppressed = true } else { playNext() }
                    return
                case .downArrow:  upNextSuppressed = true; return      // dismiss, keep watching
                default: break                                        // menu / playPause / up fall through
                }
            }
            switch type {
            case .menu: saveProgress(at: currentTime); leavePlayback()
            case .playPause: toggle()
            case .select:
                if let seg = currentSkip { skipTo(seg) } else { showControls() }   // pill up → skip, else reveal
            // Netflix-style seek-while-hidden: Left/Right nudge -/+10s directly, with a brief time pill,
            // WITHOUT revealing the whole control bar. Up/Down (and any other press) still reveal it.
            case .leftArrow: hiddenSeek(-seekStepSeconds)
            case .rightArrow: hiddenSeek(seekStepSeconds)
            default: showControls()                       // up/down + any swipe reveals the bar
            }
            return
        }
        // Control bar is shown: 2D navigation. Up/down moves between rows (close ↔ scrubber ↔ buttons);
        // left/right seeks on the scrubber or moves within the button row.
        switch type {
        case .menu:
            if scrubbing { cancelScrub() } else { saveProgress(at: currentTime); leavePlayback() }
        case .playPause: toggle()
        case .select: activate(selected)
        case .leftArrow: horizontal(-1)
        case .rightArrow: horizontal(1)
        case .upArrow: vertical(-1)
        case .downArrow: vertical(1)
        default: break
        }
    }

    /// True for an IMDb tt####### title, the same gate the iOS control-bar uses to offer the skip
    /// editor. Live streams and non-tt ids (e.g. add-on/Kitsu ids) are excluded: the SkipDB worker keys
    /// off imdb:S:E, so a non-tt id has nothing to submit against.
    private var canEditSkip: Bool {
        guard !isCurrentLiveStream, let m = curMeta else { return false }
        return m.libraryId.range(of: #"^tt\d{7,8}$"#, options: .regularExpression) != nil
    }

    /// The bottom transport row in remote left/right order. `.close` (top bar) and `.scrub` (the seek
    /// bar) are separate rows above this one; up/down moves between the three.
    private var buttonRow: [Control] {
        // Remote left/right order mirrors the on-screen left→right layout (controlBar): the left
        // settings cluster (gear, aspect, speed, sources, quality), then the centre transport, then
        // the right track cluster (audio, subs, episodes, chapters). Keeping this in step with the
        // visual order is what makes d-pad focus land where the eye expects.
        var c: [Control] = [.settings, .aspect, .playback]
        if hasAlternateSources { c.append(.sources) }
        if hasQualityOptions { c.append(.quality) }
        c.append(.restart)
        c.append(.back)
        if allEpisodes.count > 1 && hasPrevEpisode { c.append(.prev) }
        c.append(.play)
        if allEpisodes.count > 1 && hasNextEpisode { c.append(.next) }
        c.append(.fwd)
        if !audioTracks.isEmpty { c.append(.audio) }
        c.append(.subs)
        if canEditSkip { c.append(.skipEdit) }
        if allEpisodes.count > 1 { c.append(.episodes) }
        if hasChapters { c.append(.chapters) }
        return c
    }

    /// Left/right: seek when on the scrubber, otherwise move within the button row. `.close` is alone.
    private func horizontal(_ d: Int) {
        switch selected {
        case .scrub: scrubBy(d)
        case .close: flashControls()
        default:
            let row = buttonRow
            let i = row.firstIndex(of: selected) ?? 0
            selected = row[max(0, min(row.count - 1, i + d))]
            lastButton = selected
            flashControls()
        }
    }

    /// Up/down moves between the three rows: close (top) ↔ scrubber ↔ buttons (bottom). A direction
    /// press while scrubbing commits the pending seek first. This makes "Down from the Back button drops
    /// into the controls" work, replacing the old flat left/right-only list.
    private func vertical(_ d: Int) {
        commitScrubIfNeeded()
        // Live has no scrubber row (it shows a LIVE indicator instead), so up/down skips straight
        // between the close button and the transport row, never landing on the absent `.scrub`.
        if isCurrentLiveStream {
            switch selected {
            case .close: if d > 0 { selected = lastButton }
            default:     if d < 0 { selected = .close }
            }
            flashControls()
            return
        }
        switch selected {
        case .close:
            if d > 0 { selected = .scrub }
        case .scrub:
            selected = d < 0 ? .close : lastButton
        default:                                   // a button-row control
            if d < 0 { selected = .scrub }
        }
        flashControls()
    }

    private func activate(_ c: Control) {
        switch c {
        case .close:   saveProgress(at: currentTime); leavePlayback()
        case .scrub:   scrubbing ? commitScrub() : toggle()
        case .restart: restart()
        case .back:    seek(-seekStepSeconds)
        case .fwd:     seek(seekStepSeconds)
        case .play:    toggle()
        case .prev:    playPrevious()
        case .next:    playNext()
        case .audio:    openPanel(.audio)
        case .subs:     openPanel(.subtitles)
        case .aspect:   openPanel(.aspect)
        case .playback: openPanel(.playback)
        case .episodes: openPanel(.episodes)
        case .chapters: openPanel(.chapters)
        case .sources:  openPanel(.sources)
        case .quality:  openPanel(.quality)
        case .settings: openPanel(.playerSettings)
        case .skipEdit: openSkipEditor()
        }
    }

    /// Seed the skip editor from the current playhead and open its panel. Reset on every open so a fresh
    /// segment never inherits stale times / type / result from a prior submission, matching the iOS bar.
    private func openSkipEditor() {
        let snapped = (currentTime * 2).rounded() / 2
        skipEditStart = max(0, snapped)
        skipEditEnd = min(snapped + 30, duration > 0 ? duration : snapped + 60)
        skipEditType = .intro
        skipEditDone = false
        skipEditError = nil
        skipEditSubmitting = false
        skipEditStep = 10
        openPanel(.skipEditor)
    }

    /// The loaded source currently on screen (its playable URL matches what mpv is playing), used to
    /// label the stats overlay with the release name and file size. Nil for a direct-resume link with
    /// no matching loaded source.
    private var currentStream: CoreStream? {
        core.streamGroups().flatMap(\.streams).first { $0.playableURL == curURL }
    }

    /// Source rows prepended to the live stats: release name + size. The raw filename is omitted here
    /// (the fixed-width overlay can't hold it); the iOS Playback Info list shows it in full.
    private var sourceStatRows: [(String, String)] {
        guard let s = currentStream else { return [] }
        var rows: [(String, String)] = []
        let release = String(sourceLabel(s).prefix(40))
        if !release.isEmpty { rows.append(("Source", release)) }
        if let size = StreamRanking.sizeText(s) { rows.append(("Size", size)) }
        return rows
    }

    /// Live playback numbers, top-left, refreshed every second while visible.
    private var statsOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(statsRows, id: \.0) { row in
                HStack(spacing: 12) {
                    Text(row.0).foregroundStyle(Theme.Palette.textTertiary)
                    Spacer(minLength: 8)
                    Text(row.1).foregroundStyle(Theme.Palette.textPrimary)
                }
            }
        }
        .font(.system(size: 20, design: .monospaced))
        .padding(Theme.Space.md)
        .frame(width: 440)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Theme.Space.xl)
        .task(id: showStats) {
            while showStats, !Task.isCancelled {
                statsRows = sourceStatRows + (coordinator.player?.playbackStats() ?? [])
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Control bar

    /// Resolution / HDR / audio summary under the title, read live from mpv.
    private func computeMetadataLine() -> String {
        var parts: [String] = []
        // Resolution is defined by WIDTH (4K is ~3840 wide at ANY aspect), so a 2.40:1 4K film (3840x1600)
        // is NOT mislabeled "1440p" off its 1600 height. Width when known, else a 16:9 height estimate while
        // the first frame is still loading.
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
        case "eac3":               return "EAC3"
        case "ac3":                return "AC3"
        case "truehd":             return "TrueHD"
        case "dts", "dts-hd", "dca": return "DTS"
        case "aac":                return "AAC"
        case "flac":               return "FLAC"
        case "opus":               return "Opus"
        case "mp3":                return "MP3"
        default:                   return c.uppercased()
        }
    }

    private var controlBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Theme.Space.lg) {
                ctrlButton(.close, "chevron.left")
                Spacer(minLength: Theme.Space.lg)
                VStack(alignment: .trailing, spacing: 6) {
                    if !curTitle.isEmpty {
                        Text(displayTitle).font(Theme.Typography.sectionTitle)
                            .foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                    }
                    if !metadataLine.isEmpty {
                        Text(metadataLine).font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 60).padding(.top, 50)
            .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))

            Spacer()

            VStack(spacing: Theme.Space.lg) {
                if isCurrentLiveStream {
                    // Live: no seekable scrubber (there's no fixed duration to scrub within), just a
                    // LIVE indicator. The user pauses/resumes; there's nothing to seek to. The `.scrub`
                    // control row is unreachable for live (see vertical()), so this stays presentation-only.
                    liveIndicator
                } else {
                    trickplayControls
                }
                ZStack {
                    HStack(spacing: Theme.Space.md) {
                        ctrlButton(.restart, "arrow.counterclockwise")
                        ctrlButton(.back, "gobackward.\(seekStep)")
                        if allEpisodes.count > 1 && hasPrevEpisode { ctrlButton(.prev, "backward.end.fill") }
                        ctrlButton(.play, isPaused ? "play.fill" : "pause.fill", big: true)
                        if allEpisodes.count > 1 && hasNextEpisode { ctrlButton(.next, "forward.end.fill") }
                        ctrlButton(.fwd, "goforward.\(seekStep)")
                    }
                    // Left cluster: the gear plus the "how it plays" controls (aspect, speed, source and
                    // quality switching). Grouping them here unclutters the right side, which was
                    // crowding the centre transport so the skip and audio buttons overlapped.
                    HStack(spacing: Theme.Space.md) {
                        ctrlButton(.settings, "gearshape.fill")
                        ctrlButton(.aspect, "aspectratio")
                        ctrlButton(.playback, "speedometer")
                        if hasAlternateSources { ctrlButton(.sources, "rectangle.2.swap") }
                        if hasQualityOptions { ctrlButton(.quality, "4k.tv") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Right cluster: the "what plays" controls — audio/subtitle tracks and navigation.
                    HStack(spacing: Theme.Space.md) {
                        if !audioTracks.isEmpty { ctrlButton(.audio, "waveform") }
                        ctrlButton(.subs, "captions.bubble")
                        if canEditSkip { ctrlButton(.skipEdit, "checkmark.bubble") }
                        if allEpisodes.count > 1 { ctrlButton(.episodes, "list.bullet") }
                        if hasChapters { ctrlButton(.chapters, "list.bullet.below.rectangle") }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 60).padding(.bottom, 50)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
        }
        .transition(.opacity)
    }

    /// Seekable ember bar with a knob. When the scrubber row is focused it thickens; while scrubbing it
    /// shows the preview playhead (the not-yet-committed target). Left/right move the preview and the seek
    /// commits shortly after the last move (see scrubBy / commitScrub), so it works like a YouTube scrubber.
    private var scrubber: some View {
        let focused = (selected == .scrub)
        let shown = scrubbing ? scrubTarget : currentTime
        return GeometryReader { geo in
            let frac = duration > 0 ? min(1, max(0, shown / duration)) : 0
            let w = geo.size.width
            let barH: CGFloat = focused ? 10 : 6
            let knob: CGFloat = focused ? 28 : 18
            ZStack(alignment: .leading) {
                // Track + played fill in the viewer's chosen seek-bar style (classic/wave/heartbeat/…).
                // Only the visual swaps; the knob, chapter ticks, and scrub logic below are unchanged.
                SeekBarTrack(style: SeekBarStyle.current, progress: frac,
                             accent: Theme.Palette.accent,
                             track: Theme.Palette.textPrimary.opacity(0.22),
                             buffered: duration > 0 ? min(1, max(0, bufferedTime / duration)) : 0)
                    .frame(width: w, height: focused ? 24 : 16)
                // Chapter boundary ticks along the bar (decorative; the knob still reads over them).
                ForEach(chapterFractions, id: \.self) { f in
                    Capsule().fill(.white.opacity(0.5)).frame(width: 2, height: barH).offset(x: w * f)
                }
                Circle().fill(Theme.Palette.accent).frame(width: knob, height: knob)
                    .overlay(Circle().stroke(Theme.Palette.canvas, lineWidth: focused ? 3 : 0))
                    .shadow(color: Theme.Palette.accent.opacity(0.6), radius: focused ? 10 : 6)
                    .offset(x: max(0, w * frac - knob / 2))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.15), value: focused)
            // Linear so consecutive scrub steps blend into one continuous glide instead of each easing
            // out and stuttering against the next; slightly longer when not scrubbing so the play head
            // drifts smoothly between the position updates.
            .animation(scrubbing ? .linear(duration: 0.16) : .linear(duration: 0.28), value: frac)
        }
        .frame(height: 28)
    }

    /// The Live position indicator shown in place of the scrubber: a red dot + "LIVE", and a running
    /// elapsed timer so the user can still see playback is advancing. Mirrors PlayerScreen.liveIndicator.
    private var liveIndicator: some View {
        HStack(spacing: Theme.Space.md) {
            HStack(spacing: 9) {
                Circle().fill(Theme.Palette.danger).frame(width: 12, height: 12)
                Text("LIVE").font(.callout.weight(.heavy)).foregroundStyle(Theme.Palette.textPrimary).tracking(1.5)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.4), in: Capsule())
            Spacer(minLength: 0)
            if currentTime > 0 {
                Text(timeString(currentTime)).font(.callout.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .frame(height: 28)
    }

    /// Circular control, highlighted (ember fill + lift) when it is the selected control. Visual only;
    /// activation is driven by the remote handler, not a tap.
    private func ctrlButton(_ c: Control, _ icon: String, big: Bool = false) -> some View {
        let sel = (selected == c)
        let d: CGFloat = big ? 92 : 64
        return Image(systemName: icon)
            .font(.system(size: big ? 38 : 26, weight: .semibold))
            .foregroundStyle(sel ? Theme.Palette.canvas : Theme.Palette.textPrimary)
            .frame(width: d, height: d)
            .background { ctrlButtonBackground(sel) }
            .scaleEffect(sel ? 1.12 : 1.0)
            .animation(.easeOut(duration: 0.18), value: sel)
    }

    /// Focused button keeps our accent fill (the brand highlight); the resting state uses Liquid Glass on
    /// tvOS 26+, falling back to the flat translucent fill on older tvOS.
    @ViewBuilder private func ctrlButtonBackground(_ selected: Bool) -> some View {
        if selected {
            Circle().fill(Theme.Palette.accent)
        } else if #available(tvOS 26.0, *) {
            Circle().fill(.clear).glassEffect(.regular, in: Circle())
        } else {
            Circle().fill(Theme.Palette.textPrimary.opacity(0.12))
        }
    }

    // MARK: - Options panel (audio / subtitles / episodes), driven by optionRow

    /// Tags a skip-editor row so the remote handler knows a focused Start/End row takes Left/Right to
    /// adjust the time (every other panel ignores Left/Right). nil for all non-editor rows.
    private enum SkipField { case start, end }

    private struct OptionRow: Identifiable {
        let id = UUID()
        let label: String
        var detail: String = ""        // right-aligned secondary text (e.g. current value)
        var isSelected: Bool = false
        var isHeader: Bool = false     // section header, not focusable, skipped in navigation
        var skipField: SkipField? = nil   // non-nil only on the skip editor's Start/End rows
        var action: () -> Void = {}
    }

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

    /// Rows for the currently-open panel only, never mixed. Tracks are grouped by language; a "Settings"
    /// row drills into a dedicated sub-panel (sync / size / colour for subtitles, sync for audio).
    private var optionRows: [OptionRow] {
        switch panelKind {
        case .audio:
            var rows = groupedTrackRows(audioTracks) { coordinator.player?.setAudioTrack($0); refreshTracksSoon() }
            rows.append(OptionRow(label: String(localized: "Audio Settings"), detail: "›") { openPanel(.audioSettings) })
            return rows
        case .audioSettings:
            let now = String(format: "%+.1fs", audioDelay)
            var rows = [OptionRow(label: String(localized: "Sync"), isHeader: true),
                        OptionRow(label: String(localized: "Earlier  −0.1s"), detail: now) { adjustAudioDelay(-0.1) },
                        OptionRow(label: String(localized: "Later  +0.1s"), detail: now) { adjustAudioDelay(0.1) }]
            if audioDelay != 0 { rows.append(OptionRow(label: String(localized: "Reset")) { adjustAudioDelay(-audioDelay) }) }
            return rows
        case .subtitles:
            var rows = [OptionRow(label: String(localized: "Off"), isSelected: subtitleTracks.allSatisfy { !$0.selected }) {
                coordinator.player?.setSubtitleTrack(-1); refreshTracksSoon()
                VXProbe.event("subs", "subs selected off")
            }]
            rows += groupedTrackRows(subtitleTracks) { id in
                coordinator.player?.setSubtitleTrack(id); refreshTracksSoon()
                let lang = subtitleTracks.first { $0.id == id }.map { langName($0.lang) } ?? "\(id)"
                VXProbe.event("subs", "subs selected \(lang)")
            }
            // External subtitles from the account's subtitle add-ons. Work on BOTH engines now: libmpv sub-adds
            // the downloaded file (it joins the embedded list above); AVPlayer parses it and renders the cues
            // over the video itself.
            let available = addonSubs.filter { !addedSubURLs.contains($0.url) }
            if !available.isEmpty {
                rows.append(OptionRow(label: String(localized: "From add-ons"), isHeader: true))
                for sub in available.prefix(30) {
                    let loading = subtitleLoadingURL == sub.url
                    rows.append(OptionRow(label: langName(sub.lang),
                                          detail: loading ? String(localized: "Loading…") : sub.addonName) {
                        // Non-blocking: download + sub-add happen off the main thread with a timeout, so a
                        // slow / hanging subtitle endpoint can't freeze the player. The row shows Loading…
                        // until the track arrives (then it moves into the embedded list above).
                        guard subtitleLoadingURL == nil else { return }
                        subtitleLoadingURL = sub.url
                        refreshTracksSoon()
                        coordinator.player?.addExternalSubtitle(url: sub.url, title: sub.addonName, lang: sub.lang) { ok in
                            subtitleLoadingURL = nil
                            if ok { addedSubURLs.insert(sub.url) }
                            refreshTracksSoon()
                            VXProbe.event("subs", "subs selected \(langName(sub.lang)) (add-on ok=\(ok))")
                        }
                    })
                }
            }
            // Community-pooled subtitles (P2): other users' extracted subs for this title, in the SAME list.
            // No add-on wording — labeled by language with a subtle "Community" provenance. Work on BOTH engines
            // now (AVPlayer renders the downloaded file over the video, same as the add-on rows above).
            let pooled = pooledSubs.filter { !addedPooledIDs.contains($0.id) }
            if !pooled.isEmpty {
                rows.append(OptionRow(label: String(localized: "Community"), isHeader: true))
                for sub in pooled.prefix(30) {
                    let loading = subtitleLoadingURL == sub.url.absoluteString
                    rows.append(OptionRow(label: pooledLabel(sub),
                                          detail: loading ? String(localized: "Loading…") : String(localized: "Community")) {
                        selectPooledSubtitle(sub)
                    })
                }
            }
            rows.append(OptionRow(label: String(localized: "Subtitle Settings"), detail: "›") { openPanel(.subtitleSettings) })
            return rows
        case .subtitleSettings:
            let now = String(format: "%+.1fs", subDelay)
            var rows = [OptionRow(label: String(localized: "Sync"), isHeader: true)]
            // Sync works on BOTH engines: libmpv maps it to `sub-delay`; AVPlayer applies it as the offset on the
            // external-subtitle overlay it renders itself (external srt/vtt only — native/embedded AVPlayer subs
            // have no time-shift API). Later = subtitles appear later on both.
            rows.append(OptionRow(label: String(localized: "Earlier  −\(Self.subSyncStepLabel)"), detail: now) { adjustSubDelay(-Self.subSyncStep) })
            rows.append(OptionRow(label: String(localized: "Later  +\(Self.subSyncStepLabel)"), detail: now) { adjustSubDelay(Self.subSyncStep) })
            rows.append(OptionRow(label: String(localized: "Earlier  −\(Self.subSyncFineLabel)"), detail: now) { adjustSubDelay(-Self.subSyncFine) })
            rows.append(OptionRow(label: String(localized: "Later  +\(Self.subSyncFineLabel)"), detail: now) { adjustSubDelay(Self.subSyncFine) })
            if subDelay != 0 { rows.append(OptionRow(label: String(localized: "Reset")) { adjustSubDelay(-subDelay) }) }
            rows.append(OptionRow(label: String(localized: "Font"), isHeader: true))
            for f in SubtitleStyle.fonts { rows.append(OptionRow(label: Self.l10n(f.label), isSelected: subFont == f.id) { setSubtitleFont(f.id) }) }
            rows.append(OptionRow(label: String(localized: "Size"), isHeader: true))
            for s in SubtitleStyle.sizes { rows.append(OptionRow(label: Self.l10n(s.label), isSelected: subSize == s.id) { setSubtitleSize(s.id) }) }
            let scalePct = "\(Int((subSizeScale * 100).rounded()))%"
            rows.append(OptionRow(label: String(localized: "Smaller  −"), detail: scalePct) { adjustSubScale(-1) })
            rows.append(OptionRow(label: String(localized: "Bigger  +"), detail: scalePct) { adjustSubScale(1) })
            rows.append(OptionRow(label: String(localized: "Colour"), isHeader: true))
            for c in SubtitleStyle.colors { rows.append(OptionRow(label: Self.l10n(c.label), isSelected: subColor == c.id) { setSubtitleColor(c.id) }) }
            rows.append(OptionRow(label: String(localized: "Background"), isHeader: true))
            for b in SubtitleStyle.backgrounds { rows.append(OptionRow(label: Self.l10n(b.label), isSelected: subBackground == b.id) { setSubtitleBackground(b.id) }) }
            return rows
        case .aspect:
            let mode = coordinator.player?.videoSizeMode ?? "original"
            return [
                OptionRow(label: "Fit  ·  default", isSelected: mode == "original") { coordinator.player?.setVideoSize("original") },
                OptionRow(label: "Fill  ·  crop to screen", isSelected: mode == "fill" || mode == "zoom") { coordinator.player?.setVideoSize("fill") },
                OptionRow(label: "Stretch  ·  fill, distort", isSelected: mode == "stretch") { coordinator.player?.setVideoSize("stretch") },
            ]
        case .playback:
            var rows: [OptionRow] = [OptionRow(label: "Speed", isHeader: true)]
            for s in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
                rows.append(OptionRow(label: s == 1.0 ? "Normal  ·  1×" : "\(s.formatted())×",
                                      isSelected: abs(playSpeed - s) < 0.01) {
                    playSpeed = s
                    coordinator.player?.setSpeed(s)
                })
            }
            return rows
        case .playerSettings:
            return playerSettingsRows()
        case .skipEditor:
            return skipEditorRows()
        case .episodes:
            return allEpisodes.map { ep in
                OptionRow(label: "E\(ep.episodeNumber)  ·  \(ep.episodeTitle)", isSelected: ep.id == curMeta?.videoId) {
                    play(episode: ep)
                }
            }
        case .chapters:
            let chs = coordinator.player?.chapters() ?? []
            if chs.isEmpty { return [OptionRow(label: "No chapters", isHeader: true)] }
            // Current chapter = the last one starting at or before the play head; selecting seeks to it.
            let currentIdx = chs.lastIndex { $0.start <= currentTime + 0.5 }
            return chs.enumerated().map { i, ch in
                OptionRow(label: ch.title.isEmpty ? "Chapter \(i + 1)" : ch.title,
                          detail: timeString(ch.start), isSelected: i == currentIdx) {
                    coordinator.player?.seek(to: ch.start)
                }
            }
        case .sources:
            return sourceRows()
        case .quality:
            // Best playable stream per distinct resolution (4K / 1080p / …), best-first, mirroring the
            // iOS in-player quality picker. Picking one switches the stream in place at the same spot.
            let opts = StreamRanking.resolutionOptions(core.streamGroups())
            guard opts.count > 1 else { return [OptionRow(label: "Only one quality available", isHeader: true)] }
            return opts.map { opt in
                OptionRow(label: opt.label, detail: StreamRanking.sourceDetail(opt.stream).size ?? "",
                          isSelected: opt.stream.playableURL == curURL) {
                    switchStream(to: opt.stream)
                }
            }
        }
    }

    /// Group tracks by language so multiple same-language tracks read clearly (e.g. an "English" header
    /// with two variants), instead of a flat list of identical "English" rows.
    private func groupedTrackRows(_ tracks: [MPVTrack], select: @escaping (Int) -> Void) -> [OptionRow] {
        let groups = Dictionary(grouping: tracks) { $0.lang.isEmpty ? "und" : $0.lang.lowercased() }
        var rows: [OptionRow] = []
        for code in groups.keys.sorted(by: { langName($0) < langName($1) }) {
            let ts = groups[code]!
            if ts.count == 1 {
                let t = ts[0]
                rows.append(OptionRow(label: langName(code), detail: t.title, isSelected: t.selected) { select(t.id) })
            } else {
                rows.append(OptionRow(label: langName(code), isHeader: true))
                for (i, t) in ts.enumerated() {
                    rows.append(OptionRow(label: t.title.isEmpty ? "Track \(i + 1)" : t.title, isSelected: t.selected) { select(t.id) })
                }
            }
        }
        return rows
    }

    private func langName(_ code: String) -> String {
        // Delegate to the shared helper so tvOS shows FULL names (English/French/Italian) and handles
        // 3-letter ISO 639-2 codes (eng/fre/ita) and region-tagged codes (pt-BR) gracefully, matching iOS/Mac.
        fullLanguageName(code)
    }

    // MARK: - Skip-segment editor panel (tvOS)

    /// The skip editor's rows. Type section (intro / recap / outro / preview), Start + End time rows
    /// (Left/Right adjust, Select snaps to the playhead), then a Submit row that reflects in-flight /
    /// success / error / already-submitted state. A previously-submitted type shows a check in its row.
    private func skipEditorRows() -> [OptionRow] {
        guard let m = curMeta else { return [OptionRow(label: "Unavailable for this title", isHeader: true)] }
        let key = skipSubmitKey(m, type: skipEditType)
        let already = skipEditSubmittedKeys.contains(key)
        let segLen = max(0, skipEditEnd - skipEditStart)

        var rows: [OptionRow] = [OptionRow(label: "Type", isHeader: true)]
        for t in SkipDBSubmitView.SegmentType.allCases {
            let tKey = skipSubmitKey(m, type: t)
            rows.append(OptionRow(label: t.label, detail: skipEditSubmittedKeys.contains(tKey) ? "submitted" : "",
                                  isSelected: skipEditType == t) {
                guard skipEditType != t else { return }
                skipEditType = t
                skipEditDone = false
                skipEditError = nil
            })
        }

        rows.append(OptionRow(label: "Times", isHeader: true))
        rows.append(OptionRow(label: "Start", detail: timeString(skipEditStart),
                              skipField: .start) { skipEditStart = max(0, (currentTime * 2).rounded() / 2) })
        rows.append(OptionRow(label: "End", detail: timeString(skipEditEnd),
                              skipField: .end) { skipEditEnd = max((currentTime * 2).rounded() / 2, skipEditStart + 0.5) })
        rows.append(OptionRow(label: "Length", detail: String(format: "%.1fs", segLen), isHeader: true))

        rows.append(OptionRow(label: "Submit", isHeader: true))
        if skipEditSubmitting {
            rows.append(OptionRow(label: "Submitting…"))
        } else if skipEditDone {
            rows.append(OptionRow(label: "Submitted. Thank you", isSelected: true))
        } else if already {
            rows.append(OptionRow(label: "Resubmit this \(skipEditType.label.lowercased())") { submitSkipEditor(meta: m) })
        } else {
            rows.append(OptionRow(label: "Submit \(skipEditType.label.lowercased())") { submitSkipEditor(meta: m) })
        }
        if let err = skipEditError {
            rows.append(OptionRow(label: err, isHeader: true))
        }
        return rows
    }

    /// imdb:S:E:type key for the "already submitted" check, matching the iOS editor's key shape.
    private func skipSubmitKey(_ m: PlaybackMeta, type: SkipDBSubmitView.SegmentType) -> String {
        "\(m.libraryId):\(m.season ?? 0):\(m.episode ?? 0):\(type.rawValue)"
    }

    /// Adjust the focused Start/End row by one accelerating step, reusing the scrubber's press-repeat ramp
    /// (fine 10s taps, growing to 75s on a hold) so crossing a long film takes a few presses, not dozens.
    /// Clamped so Start stays >= 0 and End stays > Start; both within the file duration when it is known.
    private func adjustSkipTime(_ field: SkipField, _ dir: Int) {
        let now = Date().timeIntervalSinceReferenceDate
        if now - skipEditLastAdjustAt < 0.4, dir == skipEditLastDir {
            skipEditStep = min(skipEditStep + 6, 75)
        } else {
            skipEditStep = 10   // a pause, or a direction reversal, resets to fine steps so it does not overshoot
        }
        skipEditLastAdjustAt = now
        skipEditLastDir = dir
        let upper = duration > 0 ? duration : .greatestFiniteMagnitude
        let delta = Double(dir) * skipEditStep
        switch field {
        case .start:
            skipEditStart = min(max(0, skipEditStart + delta), max(0, min(upper, skipEditEnd) - 0.5))
        case .end:
            skipEditEnd = min(max(skipEditStart + 0.5, skipEditEnd + delta), upper)
        }
        skipEditDone = false
        skipEditError = nil
        // Preview the new boundary under the playhead so the user sees where it lands, like the scrubber.
        let target = field == .start ? skipEditStart : skipEditEnd
        coordinator.player?.seek(to: target)
        currentTime = target
        if showOptions { panelRows = optionRows }   // refresh the time readout in place
        scheduleHide()
    }

    /// Submit the edited segment. Reuses SkipDBClient.submit (keyless skip.vortx.tv, plus skipdb.tv /
    /// custom provider when keyed) exactly like the iOS editor; on success it invalidates the cache and
    /// re-fetches so the new span shows on the scrubber. The panel stays open to show the result.
    private func submitSkipEditor(meta: PlaybackMeta) {
        guard !skipEditSubmitting else { return }
        skipEditSubmitting = true
        skipEditError = nil
        skipEditDone = false
        if showOptions { panelRows = optionRows }
        let req = SkipDBClient.SubmitRequest(
            imdb_id: meta.libraryId,
            season: meta.season,
            episode: meta.episode,
            segment_type: skipEditType.rawValue,
            start_ms: Int(skipEditStart * 1000),
            end_ms: Int(skipEditEnd * 1000),
            duration_ms: duration > 0 ? Int(duration * 1000) : nil
        )
        let key = skipSubmitKey(meta, type: skipEditType)
        Task { @MainActor in
            do {
                try await SkipDBClient.submit(req)
                await SkipDBClient.invalidateCache(imdbId: meta.libraryId, season: meta.season,
                                                   episode: meta.episode, durationSeconds: duration)
                skipEditSubmittedKeys.insert(key)
                skipEditDone = true
                skipFetchKey = ""        // force a re-fetch so the submitted span resolves onto the bar
                fetchSkipTimestamps()
            } catch {
                skipEditError = error.localizedDescription
            }
            skipEditSubmitting = false
            if showOptions { panelRows = optionRows }
        }
    }

    // MARK: - Source switching (swap to another loaded source without leaving the player)

    /// True when more than one playable source is loaded for the current title / episode.
    private var hasAlternateSources: Bool {
        core.streamGroups().reduce(0) { $0 + $1.streams.filter { $0.playableURL != nil }.count } > 1
    }

    /// True when the loaded sources span more than one distinct resolution, so an in-player quality
    /// picker (4K / 1080p / …) is worth showing. A single-resolution title hides the button.
    private var hasQualityOptions: Bool {
        StreamRanking.resolutionOptions(core.streamGroups()).count > 1
    }

    /// The file carries embedded chapter markers (beyond the implicit whole-file chapter), so the Chapters
    /// navigator is worth offering. Same mpv chapter-list the skip-intro detector reads.
    private var hasChapters: Bool { (coordinator.player?.chapters().count ?? 0) > 1 }

    /// Up to `maxInPlayerSources` loaded sources, grouped by add-on in their existing priority order, so
    /// switching is quick. The full (sometimes thousands-long) source list stays on the detail page;
    /// capping here keeps the panel light, since the options panel renders its rows eagerly.
    private func sourceRows() -> [OptionRow] {
        // Every add-on contributes its ranked best few, so a single add-on with
        // hundreds of results can no longer flood the panel and bury the rest.
        let perAddon = 5
        let maxInPlayerSources = 60
        var rows: [OptionRow] = []
        var count = 0
        let groups = core.streamGroups()
        if groups.isEmpty {
            return [OptionRow(label: "Loading sources…", isHeader: true)]
        }
        for group in groups {
            // Score each stream ONCE; the old sort recomputed the (string-heavy)
            // score inside the comparator, which is what melted the main thread
            // on thousand-source titles.
            let best = group.streams.filter { $0.playableURL != nil }
                .map { (stream: $0, rank: StreamRanking.score($0)) }
                .sorted { $0.rank > $1.rank }
                .prefix(perAddon)
                .map(\.stream)
            guard !best.isEmpty, count < maxInPlayerSources else { continue }
            rows.append(OptionRow(label: group.addon, isHeader: true))
            for stream in best {
                guard count < maxInPlayerSources else { break }
                count += 1
                let info = StreamRanking.sourceDetail(stream)
                let name = String(sourceLabel(stream).prefix(40))
                rows.append(OptionRow(label: "\(info.tags)   \(name)", detail: info.size ?? "",
                                      isSelected: stream.playableURL == curURL) {
                    switchStream(to: stream)
                })
            }
        }
        return rows
    }

    /// The gear panel: player-wide settings that aren't tied to one media kind. Handoff to an
    /// installed external player (direct/debrid URLs only; a torrent's local-server URL dies when
    /// this app suspends), the decoder choice, and the info/QR rows that used to crowd Playback.
    private func playerSettingsRows() -> [OptionRow] {
        var rows: [OptionRow] = []
        // Handoff only when the URL is self-contained. A header-gated stream needs specific request
        // headers (it is either playing through our embedded /proxy/ on a loopback URL, or as a
        // bare CDN URL whose headers live on mpv); an external player gets neither and cannot
        // replay it, so it would just fail. Hide handoff in that case.
        let handoffEligible = !isTorrentPlayback && (curHeaders?.isEmpty ?? true)
        if handoffEligible, let url = curURL {
            let players = ExternalPlayers.menu()
            if !players.isEmpty {
                rows.append(OptionRow(label: "Play in", isHeader: true))
                for player in players {
                    rows.append(OptionRow(label: player.name, detail: "›") {
                        saveProgress(at: currentTime)
                        coordinator.player?.pause()
                        ExternalPlayers.open(url, in: player)
                        withAnimation { showOptions = false }
                    })
                }
            }
        }
        rows.append(OptionRow(label: "Decoder", isHeader: true))
        let hw = coordinator.player?.hardwareDecoding ?? true
        rows.append(OptionRow(label: "Hardware  ·  default", isSelected: hw) {
            coordinator.player?.setHardwareDecoding(true)
        })
        rows.append(OptionRow(label: "Software  ·  if video misbehaves", isSelected: !hw) {
            coordinator.player?.setHardwareDecoding(false)
        })
        rows.append(OptionRow(label: "Info", isHeader: true))
        rows.append(OptionRow(label: showStats ? "Hide playback info" : "Show playback info",
                              isSelected: showStats) {
            showStats.toggle()
            withAnimation { showOptions = false }
        })
        if shareLink != nil {
            rows.append(OptionRow(label: isTorrentPlayback ? "Magnet link  ·  QR for your phone"
                                                           : "Stream link  ·  QR for your phone") {
                withAnimation { showOptions = false }
                showStreamQR = true
            })
        }
        return rows
    }

    /// When the user has chosen a default external player (Settings → Play in), hand the launch stream
    /// straight to it instead of the built-in player, mirroring iOS. Only direct/debrid remote streams
    /// are eligible: torrents and header-gated streams play through our embedded server, whose loopback
    /// URL an external app can't replay. If the chosen app isn't actually installed the open() no-ops and
    /// the built-in player just keeps playing, so a missing app never strands the user on a dead screen.
    private func maybeRouteToDefaultExternalPlayer() {
        guard let player = ExternalPlayers.defaultPlayer(),
              !isTorrentPlayback, (curHeaders?.isEmpty ?? true),
              let u = curURL, let host = u.host, host != "127.0.0.1", host != "localhost", host != "::1"
        else { return }
        ExternalPlayers.open(u, in: player)
    }

    /// A concise one-line label for a source: the first line of its name, else its description.
    private func sourceLabel(_ s: CoreStream) -> String {
        func firstLine(_ t: String?) -> String {
            (t ?? "").split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        let name = firstLine(s.name)
        if !name.isEmpty { return name }
        let desc = firstLine(s.description)
        return desc.isEmpty ? "Source" : desc
    }

    /// Hand a stream to mpv, routing header-gated HTTP streams through the embedded server's
    /// proxy when it can (the official-Stremio path that makes picky CDNs like ok.ru play). The
    /// server applies the headers and rewrites the HLS playlist, so mpv fetches plain loopback
    /// and needs no headers of its own; everything else loads directly with mpv-applied headers.
    private func loadIntoPlayer(_ url: URL, headers: [String: String]?, live: Bool) {
        // Keep the yt-direct audio sidecar ONLY when reloading the launch URL itself (a trailer retry);
        // any other target (episode/source switch) is a normal content stream and must load sidecar-free.
        let sidecar = (url == self.url) ? audioSidecarURL : nil
        if let h = headers, !h.isEmpty, let proxied = StremioServer.proxiedURL(for: url, headers: h) {
            coordinator.player?.loadFile(proxied, headers: nil, live: live, audioSidecar: sidecar)
        } else {
            coordinator.player?.loadFile(url, headers: headers, live: live, audioSidecar: sidecar)
        }
    }

    /// Switch the playing source in place: reload the picked stream's URL and resume at the current
    /// position (via `resumeSeconds`), so a buffering or low-quality source can be swapped without
    /// leaving the player. Resets the auto-recovery budget for the fresh source.
    private func switchStream(to stream: CoreStream, userInitiated: Bool = true) {
        guard let newURL = stream.playableURL, newURL != curURL else {
            if userInitiated { closePanel() }
            return
        }
        // closePanel forces the control bar up and teleports the highlight; right for a manual
        // pick, hostile when an automatic hop fires while the viewer is browsing a panel.
        if userInitiated { closePanel() }
        // Cleanly destroy the torrent engine we're leaving BEFORE starting the next source, so
        // engines never pile up on the embedded server (the regression that bloated its RSS and
        // took it offline). A hop into another torrent is fine now that the old one is closed.
        if let oldHash = currentTorrentHash, oldHash != stream.infoHash?.lowercased() {
            closeTorrent(hash: oldHash)
        }
        curURL = newURL
        curIsTorrent = stream.isTorrent
        curIsLive = isLiveMeta(curMeta) && !stream.isTorrent
        curBinge = stream.behaviorHints?.bingeGroup
        curHeaders = stream.requestHeaders
        scrubThumbnails.configure(localCacheKey: trickplayLocalCacheKey)
        // Reset the local-capture throttle on a stream switch: otherwise the new stream's capture is gated
        // by the PREVIOUS stream's lastLocalTrickplayCapture (a high value), so episodes 2..N of a session
        // captured nothing until playback passed that old timestamp.
        lastLocalTrickplayCapture = -1000; localTrickplayCaptureInFlight = false
        // A manual pick makes THIS source explicit (honor it on a start-timeout); an automatic hop makes
        // the new source non-explicit so it can hop onward normally.
        currentPickWasExplicit = userInitiated
        bufferGraceUsed = 0; lastBufferedAtWatchdog = -1   // fresh source: its own first-buffer grace budget
        sourceHops = 0; exhaustedURLs = []   // a deliberate pick resets the failover budget (failover restores it)
        recoveryDeadline?.cancel(); recoveryDeadline = nil   // fresh attempt re-arms the overall recovery cap
        torrentWarmupsUsed = 0; torrentStatus = nil; stallRecoveries = 0
        prepareTorrent(stream)   // mid-playback switches never announced the torrent before
        resumeSeconds = currentTime
        appliedResume = false
        bufferedTime = 0   // new stream: clear the buffered-ahead band until the new demuxer reports
        buffering = true; hasStartedPlaying = false; appliedAutoTracks = false; appliedVolume = false; loadErrorMsg = ""
        autoRetryCount = 0; reconnecting = false; autoRetryTask?.cancel()
        // A different rip: reset the community-subtitle session so the new fingerprint re-fetches pooled subs,
        // re-seeds its rip-matched offset, and can re-upload this rip's embedded tracks (P2/P3/P4).
        subFingerprint = nil; subFingerprintKey = ""; pooledSubsKey = ""; pooledSubs = []
        addedPooledIDs = []; pooledSeededOffset = false; embeddedUploadDone = false
        loadIntoPlayer(newURL, headers: curHeaders, live: curIsLive)
        startLoadTimeout()
    }

    /// The best playable stream not yet tried (and failed) for this video. Goes through
    /// StreamRanking.best so the pick honours the user's source-type order, the add-on-order
    /// toggle, and the continuity / binge hints, exactly like the original auto-pick did.
    private func nextUntriedStream() -> CoreStream? {
        let remaining = core.streamGroups().map { group in
            CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: group.streams.filter { s in
                guard let url = s.playableURL else { return false }
                return url != curURL && !exhaustedURLs.contains(url)
            })
        }
        // QUALITY-DROP CAP (auto path): never plunge more than one resolution tier below the best CACHED
        // option that exists (the "picked/expected 4K, silently got 480p" report). Prefer candidates within
        // one tier of the best cached resolution; fall back to the unfiltered ranking only when the cap
        // leaves nothing untried, so a title whose only remaining sources are low-res still plays.
        let cachedRes = StreamRanking.bestCachedResolution(remaining)
        if cachedRes > 0 {
            let floorStep = StreamRanking.resolutionTierStep(cachedRes) - 1
            let capped = remaining.map { group in
                CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: group.streams.filter { s in
                    StreamRanking.resolutionTierStep(StreamRanking.resolutionRank(s)) >= floorStep
                })
            }
            if let hit = StreamRanking.best(capped, continuity: curHint, binge: curBinge, pin: sourcePin) {
                return hit
            }
        }
        return StreamRanking.best(remaining, continuity: curHint, binge: curBinge, pin: sourcePin)
    }

    /// The playing source is dead (its retry, stall, or warm-up budget ran out): mark it
    /// exhausted and hop to the next-best untried source automatically. Returns false when the
    /// hop budget is spent or nothing untried remains; the caller then shows the error overlay.
    @discardableResult
    private func hopToNextSource(reason: String) -> Bool {
        // FIX I: a TRAILER never fails over to the engine's content streams. The trailer request carries no
        // content stream of its own; nextUntriedStream() would return whatever the engine last loaded for
        // this (or a still-resident) title, so a dead /yt route would silently play the actual/random movie.
        // Instead show the load-error overlay ("Trailer unavailable") and stop. Return true so the caller
        // treats the failure as handled and does not also paint its own (content-stream) error message.
        if isTrailer {
            DiagnosticsLog.log("player", "trailer load failed (\(reason)); not hopping to content streams")
            loadErrorMsg = "Trailer unavailable."
            withAnimation { loadFailed = true }
            return true
        }
        guard sourceHops < maxSourceHops, let stream = nextUntriedStream() else { return false }
        // switchStream clears the budget (it doubles as the manual-pick path) and resumes at
        // currentTime; snapshot both around the call so the hop keeps its own bookkeeping and a
        // pre-start failure keeps the original resume offset.
        var tried = exhaustedURLs
        if let dead = curURL { tried.insert(dead) }
        let hops = sourceHops + 1
        let resume: Double? = hasStartedPlaying ? currentTime : resumeSeconds
        DiagnosticsLog.log("player", "source hop \(hops)/\(maxSourceHops) (\(reason)) -> \(sourceLabel(stream).prefix(40))")
        switchStream(to: stream, userInitiated: false)
        exhaustedURLs = tried
        sourceHops = hops
        resumeSeconds = resume
        return true
    }

    /// Nudge subtitle sync by `delta` seconds (rounded to 0.1); keeps the panel open to repeat.
    private func adjustSubDelay(_ delta: Double) {
        subDelay = ((subDelay + delta) * 10).rounded() / 10
        coordinator.player?.setSubDelay(subDelay)
        VXProbe.event("subs", "subs sync \(subDelay)s")
        captureSubOffset()   // P3: pool the user-corrected offset (debounced, gated, fail-soft)
    }
    private func adjustAudioDelay(_ delta: Double) {
        audioDelay = ((audioDelay + delta) * 10).rounded() / 10
        coordinator.player?.setAudioDelay(audioDelay)
    }
    /// Apply the persisted "Default volume" (D5) to the live engine at playback start. The launch mount begins
    /// at the engine's default (100%), so this restores the user's chosen level; re-armed on source switch /
    /// reload (which re-mount the engine). Idempotent per load. tvOS has no in-player volume/mute control, so
    /// this only sets the starting level and never touches mute. SAME `stremiox.playerVolume` key as iOS/Mac.
    private func applyDefaultVolume() {
        guard !appliedVolume else { return }
        appliedVolume = true
        coordinator.player?.setVolume(playerVolume)
    }
    // In-player style tweaks also stick to the active profile (Settings does the same).
    private func setSubtitleFont(_ id: String) {
        subFont = id; coordinator.player?.applySubtitleStyle(); ProfileStore.shared.capturePlayback()
    }
    private func setSubtitleSize(_ id: String) {
        subSize = id; coordinator.player?.applySubtitleStyle(); ProfileStore.shared.capturePlayback()
    }
    private func adjustSubScale(_ direction: Int) {
        let next = subSizeScale + Double(direction) * SubtitleStyle.sizeScaleStep
        let clamped = min(max(next, SubtitleStyle.sizeScaleRange.lowerBound), SubtitleStyle.sizeScaleRange.upperBound)
        subSizeScale = (clamped * 100).rounded() / 100
        coordinator.player?.applySubtitleStyle()
        ProfileStore.shared.capturePlayback()
        if showOptions { panelRows = optionRows }   // refresh the % readout in place
    }
    private func setSubtitleColor(_ id: String) {
        subColor = id; coordinator.player?.applySubtitleStyle(); ProfileStore.shared.capturePlayback()
    }
    private func setSubtitleBackground(_ id: String) {
        subBackground = id; coordinator.player?.applySubtitleStyle(); ProfileStore.shared.capturePlayback()
    }

    private var panelTitle: String {
        switch panelKind {
        case .audio:            return "Audio"
        case .audioSettings:    return "Audio Settings"
        case .subtitles:        return "Subtitles"
        case .subtitleSettings: return "Subtitle Settings"
        case .aspect:           return "Aspect Ratio"
        case .playback:         return "Playback"
        case .episodes:         return "Episodes"
        case .chapters:         return "Chapters"
        case .sources:          return "Sources"
        case .quality:          return "Quality"
        case .playerSettings:   return "Player Settings"
        case .skipEditor:       return "Edit Skip Segment"
        }
    }

    private var optionsPanel: some View {
        let rows = panelRows
        return HStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                Text(panelTitle)
                    .font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.xl).padding(.bottom, Theme.Space.sm)
                ScrollViewReader { proxy in
                    ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            if row.isHeader {
                                Text(row.label.uppercased())
                                    .font(Theme.Typography.eyebrow).tracking(1)
                                    .foregroundStyle(Theme.Palette.textTertiary)
                                    .padding(.horizontal, Theme.Space.lg).padding(.top, Theme.Space.md).padding(.bottom, 2)
                                    .id(i)
                            } else {
                                HStack {
                                    Text(row.label).lineLimit(1)
                                        .foregroundStyle(i == optionRow ? Theme.Palette.canvas : Theme.Palette.textPrimary)
                                    Spacer()
                                    if row.isSelected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(i == optionRow ? Theme.Palette.canvas : Theme.Palette.accent)
                                    } else if !row.detail.isEmpty {
                                        Text(row.detail)
                                            .foregroundStyle(i == optionRow ? Theme.Palette.canvas.opacity(0.85) : Theme.Palette.textSecondary)
                                    }
                                }
                                .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
                                .background(i == optionRow ? Theme.Palette.accent : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                                .id(i)
                            }
                        }
                    }
                    .padding(Theme.Space.lg)
                }
                .onChange(of: optionRow) { _ in withAnimation { proxy.scrollTo(optionRow, anchor: .center) } }
                }
            }
            .frame(width: 760)
            .frame(maxHeight: .infinity)
            .background(Theme.Palette.surface1.opacity(0.98))
        }
        .ignoresSafeArea()
        .transition(.move(edge: .trailing))
        .task(id: showOptions) {
            // Sources and episodes keep arriving after the panel opens (add-ons
            // answer at their own pace; direct-resume loads meta in the background).
            // Refresh the cached rows once a second while those panels are up, but only
            // when the engine actually emitted something since the last tick: an idle
            // panel does zero ranking work.
            var seenRevision = -1
            while showOptions, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard showOptions, panelKind == .sources || panelKind == .episodes else { continue }
                guard core.revision != seenRevision else { continue }
                seenRevision = core.revision
                panelRows = optionRows
            }
        }
    }

    private func moveOption(_ d: Int) {
        let rows = panelRows
        let selectable = rows.indices.filter { !rows[$0].isHeader }
        guard !selectable.isEmpty else { return }
        let cur = selectable.firstIndex(of: optionRow) ?? 0
        optionRow = selectable[max(0, min(selectable.count - 1, cur + d))]
    }
    private func activateOption() {
        let rows = panelRows
        guard optionRow >= 0, optionRow < rows.count, !rows[optionRow].isHeader else { return }
        rows[optionRow].action()
        // Selection state may have changed (speed, tracks, aspect, stats); one
        // recompute per press keeps the checkmarks honest.
        if showOptions { panelRows = optionRows }
    }

    /// The skip-editor Start/End field under the cursor, or nil when the highlighted row is not a time
    /// row (or the panel is not the editor). Drives whether Left/Right adjusts a time vs. does nothing.
    private var focusedSkipField: SkipField? {
        guard panelKind == .skipEditor else { return nil }
        let rows = panelRows
        guard optionRow >= 0, optionRow < rows.count else { return nil }
        return rows[optionRow].skipField
    }

    private func openPanel(_ kind: PanelKind) {
        panelKind = kind
        refreshTracks()
        scheduleHide()   // loop won't hide while showOptions; this just keeps the deadline fresh
        // Late add-on subtitle recovery: if the start-of-playback fetch raced an empty add-on collection,
        // retry now. Key-latched inside (no-op once a real fetch ran); the async result refreshes the rows.
        if kind == .subtitles { fetchAddonSubtitles() }
        panelRows = optionRows
        // Single-choice panels open on the current selection; the mixed settings panel opens
        // at the top (its decoder radio would otherwise swallow the seed and skip "Play in").
        let seedOnSelection = kind != .playerSettings
        optionRow = (seedOnSelection ? panelRows.firstIndex { $0.isSelected } : nil)
            ?? panelRows.firstIndex { !$0.isHeader } ?? 0
        withAnimation { showOptions = true }
    }
    private func closePanel() {
        withAnimation { showOptions = false }
        showInfo = true; selected = .play; scheduleHide()
    }

    private func refreshTracks() {
        audioTracks = coordinator.player?.tracks(ofType: "audio") ?? []
        subtitleTracks = coordinator.player?.tracks(ofType: "sub") ?? []
    }
    private func refreshTracksSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { refreshTracks() }
    }

    /// Auto-pick the audio + subtitle track from the user's language preferences, once tracks are known.
    private func autoSelectTracks() {
        let pick = TrackSelector.select(audio: audioTracks, subtitles: subtitleTracks, preferences: TrackPreferences.current)
        if let a = pick.audio { coordinator.player?.setAudioTrack(a) }
        if let s = pick.subtitle {
            coordinator.player?.setSubtitleTrack(s)   // -1 = off
            let lang = s < 0 ? "off" : (subtitleTracks.first { $0.id == s }.map { langName($0.lang) } ?? "\(s)")
            VXProbe.event("subs", "subs selected \(lang) (auto)")
        }
        refreshTracksSoon()
    }

    // MARK: - Load failure

    private var loadErrorOverlay: some View {
        ZStack {
            Theme.Palette.canvas.opacity(0.94).ignoresSafeArea()
            VStack(spacing: Theme.Space.md) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 60)).foregroundStyle(Theme.Palette.danger)
                Text(sourceHops > 0 ? "Tried \(sourceHops + 1) sources, none worked" : "This source didn't load")
                    .font(Theme.Typography.sectionTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text(loadErrorMsg.isEmpty
                     ? "It may still be downloading on your source, offline, or an unsupported link."
                     : "It may be unavailable, offline, or unsupported.  (\(loadErrorMsg))")
                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 900)
                Text("Select = choose another source    ·    Play/Pause = retry    ·    Menu = back")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary).padding(.top, Theme.Space.xs)
            }
            .padding(Theme.Space.screenEdge)
        }
        .transition(.opacity)
    }

    /// Watch for a hard stall: the position frozen while NOT paused and NOT
    /// buffering. mpv's own cache stalls set buffering, so this fires only on the
    /// freeze/black-screen case, and reloads in place at the current position.
    private func startStallWatchdog() {
        stallWatchdog?.cancel()
        lastObservedTime = -1; stalledTicks = 0
        stallWatchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard hasStartedPlaying, !isPaused, !buffering, !loadFailed, duration > 0 else {
                    lastObservedTime = currentTime; stalledTicks = 0; continue
                }
                if lastObservedTime >= 0, abs(currentTime - lastObservedTime) < 0.25 {
                    stalledTicks += 1
                    if stalledTicks >= 3 {            // ~18s frozen with no buffering -> recover
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
            // Repeated stalls on the same source: stop reloading and let the viewer
            // pick another source from the error overlay.
            // Repeated stalls on one source: hop to another at the current position,
            // falling back to the error overlay once candidates run out.
            DiagnosticsLog.log("player", "stall recovery exhausted")
            if hopToNextSource(reason: "stall budget exhausted") { return }
            loadErrorMsg = "Playback kept stalling on this source."
            withAnimation { loadFailed = true }
            return
        }
        stallRecoveries += 1
        plog.info("mid-playback stall, reloading at \(currentTime, privacy: .public)")
        DiagnosticsLog.log("player", "mid-playback stall \(stallRecoveries), reloading at \(Int(currentTime))s")
        resumeSeconds = currentTime
        appliedResume = false; appliedAutoTracks = false
        buffering = true
        loadIntoPlayer(curURL ?? url, headers: curHeaders, live: isCurrentLiveStream)
    }

    private func startLoadTimeout() {
        loadTimeout?.cancel()
        startRecoveryDeadline()   // first call arms the overall cap; later calls (hops) leave it running
        startAVStartWatchdog()    // AVPlayer-only fast fallback to libmpv when it mounts but never plays
        lastBufferedAtWatchdog = bufferedTime   // snapshot the buffered edge so the fire path can tell if bytes moved
        loadTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            // A cancelled watchdog (superseded by a hop / reload / new load) must NOT fire: Task.sleep throws
            // CancellationError on cancel and `try?` swallows it, so without this guard the cancelled timer runs
            // handleStartTimeout immediately, and each hop arms+cancels the next, cascading through every source
            // in milliseconds ("Tried N sources") over a source that was actually still loading.
            guard !Task.isCancelled, !hasStartedPlaying, !loadFailed else { return }
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
    ///    a different lower-quality source; once its grace is spent it surfaces a clear "not ready" error.
    ///  - Only the AUTO path (Watch Now / resume) hops to another source.
    private func handleStartTimeout() {
        if isTorrentPlayback { warmUpTorrent(); return }   // a peerless torrent never errors; warm it up
        // Bytes still arriving on a slow (typically 4K remux) first-buffer: extend rather than give up.
        if bufferGraceUsed < maxBufferGraceExtensions, bufferedTime > lastBufferedAtWatchdog + 0.25 {
            bufferGraceUsed += 1
            reconnecting = true
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
        // Honor an explicit user pick: retry the SAME source in place instead of hopping to a different,
        // possibly lower-quality, source. Once the grace is spent, surface a clear error, not a silent drop.
        if currentPickWasExplicit {
            if bufferGraceUsed < maxBufferGraceExtensions {
                bufferGraceUsed += 1
                reconnecting = true
                retryLoad(resetAutoRetries: false)
                return
            }
            reconnecting = false
            if loadErrorMsg.isEmpty { loadErrorMsg = "This source isn't ready (still downloading on your debrid, or slow). Choose another source." }
            withAnimation { loadFailed = true }
            return
        }
        // Auto path (Watch Now / resume): hop to the next-best untried source (quality-drop-capped inside).
        if hopToNextSource(reason: "load timeout") { return }
        if loadErrorMsg.isEmpty { loadErrorMsg = "Timed out, the source never started." }
        withAnimation { loadFailed = true }
    }

    /// Demote the active AVFoundation engine to libmpv IN PLACE (the #76 fallback). Tears the AVPlayer
    /// engine down NOW (cancels its periodic time observer + KVO) before flipping `avEngineFailed`, so no
    /// stray timePos tick can land in the surface-swap window and set hasStartedPlaying (which would
    /// suppress a later genuine libmpv failure). SwiftUI's dismantleUIView also calls stop(); it is
    /// idempotent, so the double-stop is safe. Returns true when it actually demoted (caller should bail),
    /// false when AVPlayer is not the active engine and the caller should run its normal failure path.
    @discardableResult
    private func demoteAVPlayerToMPV() -> Bool {
        guard useAVPlayerEngine, isAVPlayerActive else { return false }
        avStartWatchdog?.cancel(); avStartWatchdog = nil
        coordinator.player?.stop()
        // SILENT demote. Flipping `avEngineFailed` re-renders `playerSurface` to the mpv surface on the SAME
        // view, which re-loads the SAME stream URL (initialPlayback.url) on libmpv. It does NOT increment
        // `sourceHops` and never calls `hopToNextSource`, so this is not a failover attempt and the
        // "Source failed, trying another (N/4)" banner (gated on `sourceHops > 0`) never shows. libmpv just
        // tone-maps a DV link to HDR10, an acceptable fallback, so no toast is surfaced.
        avEngineFailed = true
        return true
    }

    /// Show a brief player toast and auto-clear it. Used to surface the AVPlayer->libmpv fallback reason.
    private func showEngineNote(_ text: String) {
        engineNote = text
        engineNoteTask?.cancel()
        engineNoteTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            engineNote = nil
        }
    }

    /// Key community trickplay EARLY off a PROVISIONAL duration from the title's `meta.runtime`, so capture
    /// begins at the first positive timePos even when mpv never emits its `duration` event (a debrid
    /// direct-HTTP MKV frequently doesn't). Fail-soft + idempotent: no-op without a tt id or a parseable
    /// runtime; the real mpv duration later re-keys the exact bucket and unblocks uploads. Mirrors the
    /// duration-event call's identity (libraryId + season/episode).
    private func configureCommunityTrickplayProvisional() {
        guard let m = curMeta else { return }
        // The loaded meta carries the human runtime; use it only when it is THIS title's meta.
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
        // The engine's metaDetails can be nil or holding ANOTHER title at play time (a hub detail ->
        // add-on detail -> play replaces it, or the load raced), which silently killed the provisional
        // key on tvOS too: whole sessions captured frames that never became eligible to upload. Port the
        // iOS self-heal: log the miss, then one-shot the runtime (movie then series) and key
        // provisionally. A tmdb-keyed play resolves its tt id FIRST (Cinemeta only speaks imdb), and the
        // resolver caches the mapping for the store's own keying. mpv's real `duration` still re-keys.
        NSLog("[trickplay] provisional key MISS (tvOS): playing=%@ metaDetails=%@ (fetching runtime)",
              m.libraryId, core.metaDetails?.meta?.id ?? "nil")
        Task {
            var ttId = m.libraryId
            if !ttId.hasPrefix("tt") {
                guard ttId.lowercased().hasPrefix("tmdb"),
                      let tt = await CommunityTrickplay.resolveIMDbID(rawId: m.libraryId, seriesHint: m.season != nil) else {
                    NSLog("[trickplay] provisional key MISS stays (tvOS): unresolvable id %@", m.libraryId)
                    return
                }
                ttId = tt
            }
            var secs = await Self.cinemetaRuntimeSeconds(kind: "movie", id: ttId)
            if secs <= 0 { secs = await Self.cinemetaRuntimeSeconds(kind: "series", id: ttId) }
            guard secs > 0 else {
                NSLog("[trickplay] provisional key MISS stays (tvOS): no cinemeta runtime for %@", ttId)
                return
            }
            await MainActor.run {
                guard curMeta?.libraryId == m.libraryId else { return }   // still the same title
                scrubThumbnails.configureCommunity(imdbId: ttId, season: m.season, episode: m.episode,
                                                   duration: secs, isRealDuration: false)
            }
        }
    }

    /// One-shot Cinemeta runtime for the provisional trickplay key when the engine meta is unavailable or
    /// mismatched at play time (tvOS twin of PlayerScreen.cinemetaRuntimeSeconds). Returns 0 on any miss.
    private static func cinemetaRuntimeSeconds(kind: String, id: String) async -> Double {
        guard let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(kind)/\(id).json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let meta = obj["meta"] as? [String: Any] else { return 0 }
        return parseRuntimeSeconds(meta["runtime"] as? String)
    }

    /// Minimal twin of CoreMeta.runtimeSeconds for a raw Cinemeta runtime string ("92 min", "1h 32m",
    /// "2:05:00"), used by the provisional-key self-heal above.
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

    /// AVPlayer-only START watchdog. AVPlayer can mount and present its chrome yet never produce a playable
    /// frame (no item .failed, no timePos tick), so the only existing guard was the shared 30s loadTimeout,
    /// which the owner saw as ~30s of dead chrome before libmpv finally took over. If AVFoundation is the
    /// active engine and playback still has not begun after avStartWatchdogSeconds, route to the SAME libmpv
    /// fallback the .failed case uses. NOT armed for libmpv (torrents legitimately warm up far longer, which
    /// is what the 30s loadTimeout / torrent warm-up budget cover). Cancelled the moment playback starts
    /// (the timePos handler cancels loadTimeout/recoveryDeadline and clears this) or the view goes away.
    private func startAVStartWatchdog() {
        avStartWatchdog?.cancel()
        guard useAVPlayerEngine, !forceMPV, !avEngineFailed else { return }
        // HLS belongs on AVPlayer (native ABR quality selector; libmpv has no equivalent), and a slow-network
        // HLS start can legitimately take more than the short watchdog to first-frame. Never demote HLS on the
        // no-frame timer: a genuinely-dead HLS link is still recovered by AVPlayer's own .failed path. The
        // watchdog exists only for the DV/remux mount-but-never-frames case, which is never HLS.
        if PlayerEngineRouter.isHLS(url) { return }
        avStartWatchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(avStartWatchdogSeconds))
            guard !Task.isCancelled, !hasStartedPlaying else { return }
            guard isAVPlayerActive else { return }   // already on libmpv (or torn down): nothing to demote
            DiagnosticsLog.log("player", "AVPlayer start watchdog \(Int(avStartWatchdogSeconds))s reached with no playable frame, falling back to libmpv")
            demoteAVPlayerToMPV()
        }
    }

    /// Arm the overall pre-start recovery cap once per attempt. Idempotent: a hop calls
    /// startLoadTimeout again, but the deadline keeps running so the whole sequence is bounded.
    /// Reset (cancelled to nil) on a deliberate fresh pick and on playback actually starting.
    private func startRecoveryDeadline() {
        guard recoveryDeadline == nil else { return }
        recoveryDeadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(maxRecoverySeconds))
            guard !Task.isCancelled, !hasStartedPlaying, !loadFailed else { return }
            DiagnosticsLog.log("player", "recovery deadline \(Int(maxRecoverySeconds))s reached after \(sourceHops) hops, giving up")
            loadTimeout?.cancel(); autoRetryTask?.cancel(); stallWatchdog?.cancel()
            if loadErrorMsg.isEmpty { loadErrorMsg = "Couldn't start playback after trying several sources." }
            withAnimation { loadFailed = true }
        }
    }

    /// What another device can actually use: the stream URL for direct and debrid
    /// links, a magnet rebuilt from the info hash for torrents (the local server
    /// URL is meaningless off this Apple TV).
    private var shareLink: String? {
        guard let u = curURL else { return nil }
        if isTorrentPlayback {
            let hash = u.pathComponents.count >= 2 ? u.pathComponents[1] : ""
            guard hash.count == 40 else { return nil }
            return "magnet:?xt=urn:btih:\(hash)"
        }
        return u.absoluteString
    }

    /// Decided by the URL shape alone ({server}:11470/{40-hex-hash}/{idx}), which
    /// every torrent URL has and nothing else does; the launch-path flag can go
    /// stale across engine-resolved episode switches, so it is only recorded, not
    /// trusted here.
    private var isTorrentPlayback: Bool {
        guard let u = curURL, u.port == 11470, u.pathComponents.count >= 3 else { return false }
        let hash = u.pathComponents[1]
        return hash.count == 40 && hash.allSatisfy(\.isHexDigit)
    }

    /// What official Stremio does that a bare mpv open does not: wait for the
    /// torrent engine. A cold swarm needs tens of seconds before its first useful
    /// bytes (22s TTFB measured on a WELL-seeded torrent), and early reads come
    /// back truncated, so mpv fails its demux instantly and the quick auto-retries
    /// burn out in seconds. Poll the engine's stats until a few MB are actually
    /// down, narrating peer count and speed, then hand mpv the URL again.
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
        withAnimation { reconnecting = true }
        torrentStatus = "Starting torrent…"
        plog.info("torrent warm-up round \(torrentWarmupsUsed) for \(hash, privacy: .public)")
        DiagnosticsLog.log("player", "torrent warm-up round \(torrentWarmupsUsed) for \(hash)")
        loadTimeout?.cancel()
        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor in
            let deadline = Date().addingTimeInterval(90)
            var warm = false
            while Date() < deadline, !Task.isCancelled, !hasStartedPlaying {
                if let stats = await Self.torrentStats(hash: hash) {
                    DiagnosticsLog.log("torrent", "stats \(hash.prefix(8)): peers=\(stats.peers ?? -1) conn=\(stats.swarmConnections ?? -1) tries=\(stats.connectionTries ?? -1) searching=\(String(describing: stats.peerSearchRunning)) down=\(Int(stats.downloaded ?? -1)) speed=\(Int(stats.downloadSpeed ?? -1))")
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
                plog.info("torrent warm, handing back to mpv")
                DiagnosticsLog.log("player", "torrent warm, reloading")
                retryLoad(resetAutoRetries: true)
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
        let connectionTries: Int?
        let peerSearchRunning: Bool?
        let downloaded: Double?
        let downloadSpeed: Double?
    }

    private static func torrentStats(hash: String) async -> TorrentStats? {
        guard let url = URL(string: "\(StremioServer.base)/\(hash)/stats.json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(TorrentStats.self, from: data)
    }

    /// A pre-playback failure (an endFileError before the first frame). Auto-retry up to `maxAutoRetries`
    /// times with a short backoff before falling back to the manual error overlay, so a transient source
    /// hiccup recovers on its own instead of dumping the viewer to an error screen.
    private func handleLoadFailure(_ msg: String) {
        guard !hasStartedPlaying, !loadFailed else { return }
        loadErrorMsg = msg
        if isTorrentPlayback {
            // The engine simply isn't warm yet; quick mpv retries just burn out.
            warmUpTorrent()
            return
        }
        if isCurrentLiveStream {
            scheduleLiveStreamReconnect(reason: "load failure: \(msg)")
            return
        }
        guard autoRetryCount < maxAutoRetries else {
            reconnecting = false
            // Honor an explicit user pick: a hard failure after the in-place retries surfaces a clear
            // "choose another source" error instead of silently hopping to a different (often lower-quality)
            // source. Only the auto path (Watch Now / resume) falls through to the failover hop below.
            if currentPickWasExplicit {
                if loadErrorMsg.isEmpty { loadErrorMsg = "This source didn't load. Choose another source." }
                withAnimation { loadFailed = true }
                return
            }
            if hopToNextSource(reason: "load failed: \(msg)") { return }
            // CW-resume of a debrid/direct stream whose stored link expired (debrid URLs are time-limited):
            // HomeView.directResume kicks off a background reload of the title's streams, but they may not
            // have arrived yet. Wait briefly for them and retry the hop to a FRESH source, rather than
            // dead-ending on the "sources didn't load" overlay. One wait-cycle per playback, non-torrent only.
            if curMeta != nil, !isTorrentPlayback, !awaitedFreshSources {
                awaitedFreshSources = true
                withAnimation { reconnecting = true }
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
        buffering = true
        withAnimation { reconnecting = true }
        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(autoRetryBackoff))
            guard !Task.isCancelled, !hasStartedPlaying else { return }
            retryLoad(resetAutoRetries: false)
        }
    }

    /// Reload the current stream. Manual retries and fresh loads reset the auto-recovery budget; the
    /// auto-retry path passes `false` so its bounded count keeps counting down toward the overlay.
    private func retryLoad(resetAutoRetries: Bool = true) {
        if resetAutoRetries { autoRetryCount = 0; reconnecting = false; bufferGraceUsed = 0; lastBufferedAtWatchdog = -1 }
        autoRetryTask?.cancel()
        withAnimation { loadFailed = false }
        bufferedTime = 0   // reload: clear the buffered-ahead band until the demuxer re-reports
        buffering = true; hasStartedPlaying = false; appliedResume = false; appliedAutoTracks = false; appliedVolume = false; loadErrorMsg = ""
        loadIntoPlayer(curURL ?? url, headers: curHeaders, live: isCurrentLiveStream)
        startLoadTimeout()
    }

    /// Live HLS providers sometimes surface a transient playlist reload failure as EOF
    /// instead of an mpv error. For VOD EOF means "finished"; for live streams it means
    /// reconnect to the playlist rather than marking watched and closing the player.
    private func handleLiveStreamEOF() -> Bool {
        guard isCurrentLiveStream else { return false }
        scheduleLiveStreamReconnect(reason: "EOF")
        return true
    }

    private func scheduleLiveStreamReconnect(reason: String) {
        buffering = true
        withAnimation { reconnecting = true }
        plog.info("live stream \(reason, privacy: .public), reconnecting")
        DiagnosticsLog.log("player", "live stream \(reason), reconnecting")
        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            retryLoad(resetAutoRetries: false)
        }
    }

    /// Pull external subtitles for the playing title from the account's subtitle add-ons,
    /// once per episode. Movies query by their id; episodes by id:season:episode.
    private func fetchAddonSubtitles() {
        guard let m = curMeta else { return }
        let key = "\(m.type):\(m.videoId)"
        guard key != addonSubsKey else { return }
        let addons = account.addons
        // The account's add-on collection loads async at app start; latching an empty list here would hide
        // add-on subtitles for the whole session. Leave the key unlatched so a later call (playback start /
        // panel open) fetches once the add-ons have arrived.
        guard !addons.isEmpty else { return }
        addonSubsKey = key
        addonSubs = []
        addedSubURLs = []
        Task { @MainActor in
            let subs = await SubtitleAddonService.fetch(addons: addons, type: m.type, videoId: m.videoId)
            guard addonSubsKey == key else { return }   // episode changed mid-fetch
            addonSubs = subs
            if showOptions, panelKind == .subtitles { panelRows = optionRows }
        }
    }

    // MARK: - Community subtitles (pool + sync + embedded upload)

    /// The pool `content_key` for what is playing: the imdb library id, plus season/episode for an episode.
    /// Live streams and titles with no imdb id return nil, no-oping the whole community-subtitle path.
    private var communityContentKey: String? {
        guard let m = curMeta, !isCurrentLiveStream else { return nil }
        return SubtitleReleaseFingerprint.contentKey(imdbId: m.libraryId, season: m.season, episode: m.episode)
    }

    /// The release name for the fingerprint: the playing stream's display name / release text.
    private var communityReleaseName: String? {
        if let s = currentStream { return sourceLabel(s) }
        return curTitle.isEmpty ? nil : curTitle
    }

    /// Build (or rebuild) the one release fingerprint for this playback session, keyed on the active URL so a
    /// source switch recomputes it. `force` rebuilds even when the key is unchanged (e.g. once the real
    /// duration/fps land). Kept consistent so fetch/upload/offset all agree.
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
    /// offset onto the player once. Gated + fail-soft inside the client. De-duped per content key + fingerprint.
    private func fetchPooledSubtitles() {
        guard let contentKey = communityContentKey else { return }
        refreshSubFingerprint()
        let fp = subFingerprint
        let key = "\(contentKey)#\(fp ?? "")"
        guard key != pooledSubsKey else { return }
        pooledSubsKey = key
        Task { @MainActor in
            // SERVE moat gate: the pooled-subtitle READ is login-only on the worker (no VortX sign-in -> empty
            // list, the pool "shows nothing" bug). Thread the real account flag like SourceIndexClient does, so a
            // signed-in device stamps X-VX-Moat and the worker serves the pool.
            let result = await SubtitlePoolClient.fetchPooled(contentKey: contentKey, lang: nil, fingerprint: fp,
                                                              isSignedIn: VortXSyncManager.shared.isSignedIn)
            guard communityContentKey == contentKey else { return }   // title changed mid-fetch
            pooledSubs = result.subs
            VXProbe.log("subs", "subs pooled n=\(result.subs.count)")
            // P3 seed: apply the community-learned offset ONCE (seconds). Works on BOTH engines now: libmpv
            // maps it to `sub-delay`; the AVPlayer engine applies it as the offset on the external-subtitle
            // overlay it renders itself (a no-op until an external cue set is loaded, then it lands correctly).
            // Never override a delay the user already dialed in.
            if !pooledSeededOffset, subDelay == 0, let offsetMs = result.offsetMs, offsetMs != 0 {
                pooledSeededOffset = true
                let seconds = (Double(offsetMs) / 1000.0 * 10).rounded() / 10
                subDelay = seconds
                coordinator.player?.setSubDelay(seconds)
                VXProbe.log("subs", "subs sync \(seconds)s (community seed)")
            }
            if showOptions, panelKind == .subtitles { panelRows = optionRows }
        }
    }

    /// P2: load a pooled subtitle into the player, reusing the exact external-subtitle path (download to a
    /// local file, then mpv `sub-add`). Shows the shared Loading… row state. Fail-soft.
    private func selectPooledSubtitle(_ sub: SubtitlePoolClient.PooledSubtitle) {
        guard subtitleLoadingURL == nil else { return }
        subtitleLoadingURL = sub.url.absoluteString
        if showOptions, panelKind == .subtitles { panelRows = optionRows }
        Task { @MainActor in
            // The pool-hosted sub TEXT is moat-gated too, so pass the same account flag the fetch used.
            guard let localURL = await SubtitlePoolClient.download(sub, isSignedIn: VortXSyncManager.shared.isSignedIn) else {
                subtitleLoadingURL = nil
                if showOptions, panelKind == .subtitles { panelRows = optionRows }
                return
            }
            let title = pooledLabel(sub)
            coordinator.player?.addExternalSubtitle(url: localURL.absoluteString, title: title, lang: sub.lang) { ok in
                subtitleLoadingURL = nil
                if ok { addedPooledIDs.insert(sub.id) }
                if showOptions, panelKind == .subtitles { panelRows = optionRows }
                VXProbe.event("subs", "subs selected \(langName(sub.lang)) (community ok=\(ok))")
            }
        }
    }

    /// The label for a pooled subtitle row: the language name. NO add-on wording (framing rule) — pooled subs
    /// are just "subtitles" with a subtle community provenance shown in the row detail.
    private func pooledLabel(_ sub: SubtitlePoolClient.PooledSubtitle) -> String { langName(sub.lang) }

    /// P3 capture: debounce a manual sync change, then submit the learned offset to the pool. Works on BOTH
    /// engines now: on libmpv it is the `sub-delay`, on AVPlayer it is the offset applied to VortX's own
    /// external-subtitle overlay (add-on/pooled srt/vtt) - the same signed cue offset for this fingerprint.
    /// Gated + fail-soft inside the client.
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
        let inputStr = (curURL ?? url).absoluteString
        Task.detached(priority: .utility) {
            let tracks = SubtitleEmbeddedExtractor.extractTextSubtitles(input: inputStr)
            for track in tracks where track.cueCount > 0 {
                await SubtitlePoolClient.upload(contentKey: contentKey, lang: track.lang, fingerprint: fp,
                                                origin: "embedded", format: track.format, text: track.srt)
            }
        }
    }

    private var isCurrentLiveStream: Bool { curIsLive && !isTorrentPlayback }
    private var initialLiveMode: Bool { !torrent && isLiveMeta(meta) }

    /// The first load's URL/headers, proxied through the embedded server when the launch stream
    /// declares request headers (same routing as loadIntoPlayer, applied to the initial play).
    private var initialPlayback: (url: URL, headers: [String: String]?) {
        if let h = headers, !h.isEmpty, let proxied = StremioServer.proxiedURL(for: url, headers: h) {
            return (proxied, nil)
        }
        return (url, headers)
    }

    /// Live content carries the live meta types; everything else keeps VOD behavior. The
    /// id-scheme heuristic (any id the skip service can't parse = live) would misclassify
    /// VOD from add-ons with custom id schemes, trapping whole drama catalogs in the live
    /// EOF-reconnect loop so episodes could never finish or auto-advance.
    private func isLiveMeta(_ meta: PlaybackMeta?) -> Bool {
        guard let type = meta?.type else { return false }
        return LiveTypes.contains(type)   // shared definition of "live" (tv / channel / events)
    }

    // MARK: - Skip intro / outro (chapter-derived; AniSkip crowd-sourced timings can feed the same model later)

    /// The skip segment the playhead is currently inside, if any. Gated on `hasStartedPlaying` so a stale
    /// segment from the previous file never flashes during a load.
    /// Recompute the active skip span for a playhead value, assigning only on change
    /// so the player body re-renders when the pill appears/disappears, not per tick.
    private func updateCurrentSkip(at time: Double) {
        let skip = hasStartedPlaying ? skipSegments.first { time >= $0.start && time < $0.end } : nil
        // Auto-skip: when the playhead enters a NEW skip segment and the setting is on, jump past it once.
        // Recording the start means a manual seek back into the same segment won't auto-skip it again.
        if autoSkip, let skip, !autoSkippedStarts.contains(skip.start) {
            autoSkippedStarts.insert(skip.start)
            skipTo(skip)
            if currentSkip != nil { currentSkip = nil }
            return
        }
        if skip?.start != currentSkip?.start { currentSkip = skip }
    }

    /// Re-resolve skip spans from every available layer (named chapters + crowd timestamps), once the
    /// file's duration is known. The resolver's sanity guards keep any one bad span from mis-skipping.
    private func refreshSkipSegments() {
        let chapters = coordinator.player?.chapters() ?? []
        let chapterCandidates = SkipSegments.chapterCandidates(chapters: chapters, duration: duration)
        skipSegments = SegmentResolver.resolve(chapterCandidates + apiSkipCandidates, duration: duration)
        chapterFractions = ChapterMarks.fractions(chapters: chapters, duration: duration)
        updateCurrentSkip(at: currentTime)
    }

    /// Pull crowd-sourced intro/credits spans for the current title (disk-cached, non-blocking): the
    /// pill simply appears once the result lands, normally well before the intro is reached.
    private func fetchSkipTimestamps() {
        guard let m = curMeta else { plog.info("skip: no curMeta, not fetching"); return }
        guard SkipTimestampService.supports(metaId: m.libraryId) else {
            skipFetchTask?.cancel()
            apiSkipCandidates = []
            skipFetchKey = ""
            refreshSkipSegments()
            return
        }
        let key = "\(m.libraryId):\(m.season ?? 0):\(m.episode ?? 0)"
        if key != skipFetchKey { apiSkipCandidates = []; autoSkippedStarts = [] }   // new episode: reset auto-skip
        skipFetchKey = key
        let dur = duration
        plog.info("skip: fetching key=\(key, privacy: .public) dur=\(Int(dur), privacy: .public)")
        skipFetchTask?.cancel()
        skipFetchTask = Task { @MainActor in
            let found = await SkipTimestampService.candidates(imdbId: m.libraryId, season: m.season,
                                                              episode: m.episode, durationSeconds: dur)
            guard !Task.isCancelled, skipFetchKey == key else { return }
            apiSkipCandidates = found
            refreshSkipSegments()
            plog.info("skip: \(found.count, privacy: .public) crowd spans, \(skipSegments.count, privacy: .public) resolved segments")
        }
    }

    /// Jump past a skip segment to its end, updating the playhead so the pill clears immediately.
    private func skipTo(_ segment: SkipSegment) {
        coordinator.player?.seek(to: segment.end)
        currentTime = segment.end
    }

    /// Seek by `delta` seconds while the chrome is HIDDEN, without revealing the control bar. A direct
    /// relative seek plus a brief cumulative time pill, so quick Left/Right nudges don't force the whole
    /// bar up (the competitor-parity "seek-while-hidden"). No media yet (duration 0) falls back to reveal.
    private func hiddenSeek(_ delta: Double) {
        guard duration > 0 else { showControls(); return }
        seek(delta)
        withAnimation { hiddenSeekDelta = (hiddenSeekDelta ?? 0) + delta }   // accumulate rapid presses
        hiddenSeekTask?.cancel()
        hiddenSeekTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            withAnimation { hiddenSeekDelta = nil }
        }
    }

    /// The seek-amount pill shown bottom-center while seeking with the chrome hidden (mirrors skipPill).
    private func hiddenSeekPill(_ delta: Double) -> some View {
        let s = Int(delta)
        return VStack {
            Spacer()
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: s >= 0 ? "goforward" : "gobackward")
                Text(s >= 0 ? "+\(s)s" : "\(s)s").fontWeight(.semibold).monospacedDigit()
            }
            .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.md)
            .foregroundStyle(Theme.Palette.textPrimary)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, Theme.Space.screenEdge * 3)
        }
        .transition(.opacity)
    }

    /// The "Skip Intro / Skip Outro" pill, bottom-trailing. Shown only while watching (controls hidden);
    /// pressing Select skips it (see `handlePress`).
    private func skipPill(_ segment: SkipSegment) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "forward.fill")
                    Text(segment.label).fontWeight(.semibold)
                }
                .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.md)
                .foregroundStyle(Theme.Palette.canvas)
                .background(Capsule().fill(Theme.Palette.accent))
                .padding(Theme.Space.screenEdge * 1.5)
            }
        }
        .transition(.opacity)
    }

    /// End-of-episode Up Next card (controls hidden): next episode + countdown + Play Now / Watch Credits.
    /// The remote drives it directly via handlePress (Left/Right pick, Select activates), so there is no
    /// SwiftUI @FocusState here — `upNextWantsCredits` is the highlighted button.
    private var upNextBand: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 28) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UP NEXT").font(.caption.weight(.bold)).tracking(2)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        if let label = nextEpisodeLabel {
                            Text(label).font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                        }
                        if let r = upNextRemaining {
                            Text("Playing in \(r)s").font(.callout).foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    upNextButton("Play Now", systemImage: "play.fill", highlighted: !upNextWantsCredits)
                    upNextButton("Watch Credits", systemImage: nil, highlighted: upNextWantsCredits)
                }
                .padding(.horizontal, 32).padding(.vertical, 22)
                .frame(maxWidth: 820, alignment: .leading)
                .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(Theme.Space.screenEdge * 1.5)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeOut(duration: 0.15), value: upNextWantsCredits)
    }

    private func upNextButton(_ title: String, systemImage: String?, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            if let img = systemImage { Image(systemName: img) }
            Text(title).lineLimit(1)
        }
        .font(.headline.weight(.semibold))
        .foregroundStyle(highlighted ? Theme.Palette.onAccent : Theme.Palette.textPrimary)
        .padding(.horizontal, 24).padding(.vertical, 13)
        .background(highlighted ? AnyShapeStyle(Theme.Palette.accent) : AnyShapeStyle(.white.opacity(0.16)), in: Capsule())
        .overlay(Capsule().stroke(Theme.Palette.canvas, lineWidth: highlighted ? 3 : 0))
        .scaleEffect(highlighted ? 1.06 : 1.0)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Episode navigation (series only; `episodes` is the season's ordered list)

    private var allEpisodes: [CoreVideo] { episodes.isEmpty ? loadedEpisodes : episodes }

    private var episodeIndex: Int? { allEpisodes.firstIndex { $0.id == curMeta?.videoId } }
    private var hasNextEpisode: Bool { episodeIndex.map { $0 + 1 < allEpisodes.count } ?? false }
    private var hasPrevEpisode: Bool { (episodeIndex ?? 0) > 0 }

    /// The `CoreVideo` for the episode currently playing, resolved from the loaded episode list.
    /// Matches on the engine video id first (canonical), falling back to season+episode for direct
    /// resumes whose `curMeta.videoId` predates the freshly loaded list. Nil for movies / live.
    private var currentEpisodeVideo: CoreVideo? {
        guard let m = curMeta, m.type == "series" else { return nil }
        if let v = allEpisodes.first(where: { $0.id == m.videoId }) { return v }
        guard let s = m.season, let e = m.episode else { return nil }
        return allEpisodes.first { $0.season == s && $0.episode == e }
    }

    /// Top-right label text. Appends the episode title to the launch title when a *distinct* one
    /// is known (the model's `episodeTitle` falls back to a generic "Episode N", which we suppress
    /// to avoid noise). `play(episode:)` already bakes the title into `curTitle`, so guard against
    /// duplicating it there. Movies / live / title-less episodes show `curTitle` unchanged.
    private var displayTitle: String {
        guard let v = currentEpisodeVideo,
              let t = v.title, !t.isEmpty,           // a real episode title, not the "Episode N" fallback
              !curTitle.contains(t)                  // don't double-append (play(episode:) already added it)
        else { return curTitle }
        return "\(curTitle) · \(t)"
    }

    private func playNext() { if let i = episodeIndex, i + 1 < allEpisodes.count { play(episode: allEpisodes[i + 1]) } }
    private func playPrevious() { if let i = episodeIndex, i > 0 { play(episode: allEpisodes[i - 1]) } }

    /// Seconds left until auto-advance, when the Up Next band should be on screen: a next episode queued,
    /// a real runtime, the play head in the final stretch, and the user hasn't chosen to watch the credits.
    private var upNextRemaining: Int? {
        guard hasNextEpisode, !upNextSuppressed, duration > 60, currentTime > 0 else { return nil }
        let remaining = duration - currentTime
        guard remaining > 0, remaining <= 20 else { return nil }
        return Int(remaining.rounded(.up))
    }
    /// Show the Up Next band IN PLACE of the credits Skip pill: the moment the play head enters a
    /// credits segment (the same detection that drove the old Skip-Credits pill) and a next episode
    /// exists, the band owns the bottom-right corner so the two never fight for it (the band used to
    /// only appear in the last 20s, surfacing "after the credits were gone"). The last episode (no
    /// next) keeps its plain Skip pill. Its countdown line still appears only inside the last-20s window.
    private var isCreditsUpNext: Bool {
        currentSkip?.kind == .credits && hasNextEpisode && !upNextSuppressed && duration > 60
    }
    /// Label of the episode that plays next, for the Up Next band.
    private var nextEpisodeLabel: String? {
        guard let i = episodeIndex, i + 1 < allEpisodes.count else { return nil }
        let e = allEpisodes[i + 1]
        return "E\(e.episodeNumber) · \(e.episodeTitle)"
    }

    /// Wall-clock time the title will finish ("Ends 10:45 PM"), from the remaining runtime. Tracks the
    /// scrub position while scrubbing. nil for live / before the duration is known.
    private var endsAtClock: String? {
        guard duration > 0 else { return nil }
        let remaining = max(0, duration - (scrubbing ? scrubTarget : currentTime))
        return "Ends \(Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened))"
    }

    /// Auto-advance when an episode ends: next episode if there is one, otherwise leave the player.
    private func autoAdvance() {
        if upNextSuppressed {
            // User chose Watch Credits: play through to the end, then stop here instead of auto-jumping.
            // The episode is marked watched, so Continue Watching rolls forward on its own.
            saveProgress(at: currentTime)
            leavePlayback()
            return
        }
        if hasNextEpisode { playNext(); return }
        // Finished (a movie, or the last episode): record the final position, then rewind the title out of
        // Continue Watching. The engine keeps any item with time_offset > 0 in the rail, so without this a
        // finished title lingers at its end position forever.
        saveProgress(at: currentTime)
        if let m = curMeta { core.finishedWatching(libraryId: m.libraryId) }
        leavePlayback()   // terminal: free the engine, then dismiss
    }

    /// Switch to another episode in place: flush progress, resolve a stream through the ENGINE (same path
    /// as launch), then reload mpv. If the next episode was preloaded in the background, it plays its
    /// already-ranked best source instantly with no resolution wait.
    private func play(episode v: CoreVideo) {
        guard let m = curMeta else { return }
        saveProgress(at: currentTime)
        // Snapshot the engine we're leaving so a DIFFERENT-hash next source can free it — but only
        // ONCE the real next hash is known, never speculatively here. Destroying a SAME-hash engine
        // is the harmful case (a season-pack torrent shares one infoHash across every episode, just a
        // different file index; recreate is a harmless no-op since the server is first-create-wins, but
        // destroy-then-recreate leaves warm-up seeing 0 peers / 0 bytes). So the close moves to wherever
        // the next stream is resolved:
        //   • PRELOAD path: the next stream is known synchronously below → close right there if its hash
        //     differs. A same-hash preload (manual ep switch on a season pack) keeps the live engine.
        //   • ENGINE-resolved FALLBACK (manual nav with no preload — episodes panel, Prev, an early Next):
        //     the hash isn't known until the async resolve, so we do NOT pre-close; the fallback closes
        //     the old engine after it resolves a different-hash stream, mirroring switchStream's guard.
        // A genuinely different-hash old engine is still always freed (the resolved-stream close below,
        // or leavePlayback() on a real exit), so nothing piles up.
        let leavingHash = currentTorrentHash
        withAnimation { showOptions = false }
        buffering = true; hasStartedPlaying = false; appliedResume = false
        loadFailed = false; currentTime = 0; duration = 0; bufferedTime = 0; lastSaved = -1; resumeSeconds = nil; appliedAutoTracks = false; appliedVolume = false
        // A new episode's source is a RANKED auto-pick (auto-advance) or an episode-panel pick (the user chose
        // the EPISODE, not the source), never a source-row tap. Clear the explicit flag so a slow/dead episode
        // source still fails over automatically instead of dead-ending an unattended binge on "choose another
        // source". Also refresh the first-buffer grace budget for the fresh source. Mirrors iOS goToEpisode.
        currentPickWasExplicit = false; bufferGraceUsed = 0; lastBufferedAtWatchdog = -1
        // New episode: reset the community-subtitle session (new content key + fingerprint) so pooled subs,
        // the seeded offset, and the embedded upload all re-run against the new episode (P2/P3/P4).
        subFingerprint = nil; subFingerprintKey = ""; pooledSubsKey = ""; pooledSubs = []
        addedPooledIDs = []; pooledSeededOffset = false; embeddedUploadDone = false
        // Re-arm the watched marker for the NEW episode. Without this, the first episode of a binge sets
        // markedWatched=true at ~90% and every in-place auto-advanced episode after it is blocked by the
        // `!markedWatched` guard, so only the session's first episode ever marks watched (the "watched
        // episodes don't tick" regression; iOS PlayerScreen.goToEpisode already resets it).
        markedWatched = false
        autoAddedThisPlayback = false   // re-arm the 60s auto-add/watch-ping for the new episode (idempotent per show)
        upNextSuppressed = false; upNextWantsCredits = false   // re-arm the Up Next band for the new episode
        sourceHops = 0; exhaustedURLs = []   // fresh episode, fresh failover budget
        recoveryDeadline?.cancel(); recoveryDeadline = nil   // fresh attempt re-arms the overall recovery cap
        let newMeta = PlaybackMeta(libraryId: m.libraryId, videoId: v.id, type: "series",
                                   name: m.name, poster: m.poster, season: v.season, episode: v.episode)
        curMeta = newMeta
        curTitle = "\(m.name) · S\(v.season ?? 0)E\(v.episodeNumber) · \(v.episodeTitle)"
        showInfo = true; selected = .play; flashControls()

        // The preload already fetched and ranked this episode across every add-on → play it now.
        if let pre = preloaded, pre.episodeID == v.id, let u = pre.stream.playableURL {
            preloaded = nil
            warmedID = nil
            DiagnosticsLog.log("binge", "auto-next PRELOAD: wanted binge=\(curBinge ?? "nil") got=\(pre.bingeGroup ?? "nil") name=\(pre.stream.name?.prefix(60) ?? "")")
            curHint = pre.signature
            curBinge = pre.bingeGroup
            curIsTorrent = pre.stream.isTorrent
            curHeaders = pre.stream.requestHeaders
            curIsLive = isLiveMeta(newMeta) && !pre.stream.isTorrent
            torrentWarmupsUsed = 0; torrentStatus = nil
            stallRecoveries = 0
            plog.info("episode switch: playing preloaded best source")
            // Now the real next hash is known: free the engine we're leaving only if it's a DIFFERENT
            // torrent. A same-hash preload (season pack) keeps the live engine — recreate would be a
            // no-op but destroy-then-recreate cold-starts it (0 peers). Mirrors switchStream's guard.
            if let oldHash = leavingHash, oldHash != pre.stream.infoHash?.lowercased() { closeTorrent(hash: oldHash) }
            prepareTorrent(pre.stream)
            curURL = u
            scrubThumbnails.configure(localCacheKey: trickplayLocalCacheKey)
            // Reset the local-capture throttle on the in-place episode switch (same reason as switchStream).
            lastLocalTrickplayCapture = -1000; localTrickplayCaptureInFlight = false
            // @MainActor: the synchronous CoreBridge calls below (loadMeta / streamGroups ->
            // addonNamesByBase, which lazily mutates addonNamesCache) are main-actor-only. A bare
            // Task runs its pre-await body on a background thread, racing the dictionary against
            // the player/DetailView reads.
            Task { @MainActor in
                core.loadMeta(type: "series", id: m.libraryId, streamType: "series", streamId: v.id)
                resumeSeconds = await account.resumeOffset(for: newMeta)
                loadIntoPlayer(u, headers: curHeaders, live: curIsLive)
                startLoadTimeout()
                // Hand the stream to the engine Player once its meta_details catches up, so
                // Continue Watching keeps tracking; harmless if it never matches.
                for _ in 0..<60 {
                    if !core.streamGroups(forStreamId: v.id).isEmpty {
                        core.loadEnginePlayer(for: pre.stream)
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            return
        }

        Task { @MainActor in
            core.loadMeta(type: "series", id: m.libraryId, streamType: "series", streamId: v.id)
            // Wait for THIS episode's streams (matched by id), then take the RANKED best across
            // add-ons: either every add-on has answered, or the first playable landed a few seconds
            // ago and we stop waiting for stragglers.
            var firstPlayableAt: Date?
            for _ in 0..<200 {                                          // ~20s (the wanted-quality debrid can land ~10-12s in)
                let groups = core.streamGroups(forStreamId: v.id)
                let progress = core.streamLoadProgress(forStreamId: v.id)
                let hasPlayable = groups.contains { $0.streams.contains { $0.playableURL != nil } }
                if hasPlayable, firstPlayableAt == nil { firstPlayableAt = Date() }
                // Settle gate (see StreamRanking.resolveSettled): wait for the SAME quality the last episode
                // played (non-torrent unless the user ranks torrents first) so auto-next stays on the user's
                // source instead of grabbing the first torrent that answers.
                let elapsed = firstPlayableAt.map { Date().timeIntervalSince($0) } ?? 0
                if StreamRanking.resolveSettled(groups, loaded: progress.loaded, total: progress.total,
                                                secondsSinceFirstPlayable: elapsed, rememberedQuality: curHint),
                   let s = StreamRanking.best(groups, continuity: curHint, binge: curBinge, pin: sourcePin), let u = s.playableURL {
                    DiagnosticsLog.log("binge", "auto-next FALLBACK: wanted binge=\(curBinge ?? "nil") got=\(s.behaviorHints?.bingeGroup ?? "nil") name=\(s.name?.prefix(60) ?? "")")
                    curBinge = s.behaviorHints?.bingeGroup
                    curHint = StreamRanking.signature(s)
                    curHeaders = s.requestHeaders
                    // The real next hash is finally known: free the engine we left only if this is a
                    // DIFFERENT torrent. On a season pack (same infoHash, different fileIdx — the common
                    // manual-nav case: episodes panel, Prev, an early Next) this leaves the live engine
                    // untouched instead of cold-recreating it. Mirrors switchStream's different-hash guard.
                    if let oldHash = leavingHash, oldHash != s.infoHash?.lowercased() { closeTorrent(hash: oldHash) }
                    core.loadEnginePlayer(for: s)
                    prepareTorrent(s)                                  // no-op for direct / debrid URLs
                    curURL = u
                    curIsLive = isLiveMeta(newMeta) && !s.isTorrent
                    scrubThumbnails.configure(localCacheKey: trickplayLocalCacheKey)
                    // Reset the local-capture throttle on this in-place episode switch (same reason as switchStream).
                    lastLocalTrickplayCapture = -1000; localTrickplayCaptureInFlight = false
                    resumeSeconds = await account.resumeOffset(for: newMeta)
                    loadIntoPlayer(u, headers: curHeaders, live: curIsLive)
                    startLoadTimeout()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            loadErrorMsg = "No playable source found for this episode."
            withAnimation { loadFailed = true }
        }
    }

    // MARK: - Next-episode preload (so auto-advance plays the best link with zero wait)

    /// The next episode's best stream, resolved in the background mid-episode. Fetched over the
    /// add-on HTTP protocol directly so the engine's `meta_details` (which the screen behind the
    /// player still shows) is never disturbed.
    private struct PreloadedEpisode { let episodeID: String; let stream: CoreStream; let signature: String; let bingeGroup: String? }

    /// Kick off the preload once per episode, triggered when playback crosses the halfway mark.
    private func preloadNextIfNeeded() {
        guard let i = episodeIndex, i + 1 < allEpisodes.count else { return }
        let next = allEpisodes[i + 1]
        guard preloaded?.episodeID != next.id, preloadingID != next.id else { return }
        preloadingID = next.id
        let sources = account.streamSources
        // Snapshot the main-actor @State continuity hints here (on the main actor) so the background
        // Task never reads them off-main; the heavy fetch + ranking stays off-main and only the @State
        // writes hop back to the main actor.
        let hint = curHint
        let binge = curBinge
        let pin = sourcePin                     // snapshot on-main; the background rank uses it (#15)
        plog.info("preloading next episode \(next.id, privacy: .public) from \(sources.count, privacy: .public) add-ons")
        Task {
            var groups: [CoreStreamSourceGroup] = []
            await withTaskGroup(of: CoreStreamSourceGroup?.self) { tasks in
                for source in sources {
                    tasks.addTask { await Self.fetchStreams(base: source.base, addon: source.name, id: next.id) }
                }
                for await group in tasks { if let group { groups.append(group) } }
            }
            // Keep the user's add-on priority order for ranking ties. Bases can REPEAT in the
            // add-on list, so this must unique (uniqueKeysWithValues: traps on duplicates).
            let order = Dictionary(sources.enumerated().map { ($1.base, $0) },
                                   uniquingKeysWith: { first, _ in first })
            groups.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
            let withBinge = groups.flatMap { $0.streams }.filter { ($0.behaviorHints?.bingeGroup?.isEmpty == false) }.count
            DiagnosticsLog.log("binge", "preload next ep: want binge=\(binge ?? "nil"), \(withBinge) of \(groups.flatMap { $0.streams }.count) streams carry a bingeGroup")
            let best = StreamRanking.best(groups, continuity: hint, binge: binge, pin: pin)
            // @State writes go back on the main actor (the fetch + rank above intentionally ran off-main).
            await MainActor.run {
                if let best {
                    preloaded = PreloadedEpisode(episodeID: next.id, stream: best, signature: StreamRanking.signature(best),
                                                 bingeGroup: best.behaviorHints?.bingeGroup)
                    plog.info("preload ready: \(StreamRanking.qualityLabel(best), privacy: .public) for \(next.id, privacy: .public)")
                } else {
                    plog.info("preload found nothing for \(next.id, privacy: .public)")
                }
                preloadingID = nil
            }
        }
    }

    /// One add-on's streams for an episode, straight over the Stremio addon protocol.
    private static func fetchStreams(base: String, addon: String, id: String) async -> CoreStreamSourceGroup? {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = URL(string: "\(base)/stream/series/\(escaped).json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        struct Response: Decodable { let streams: [CoreStream]? }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              let streams = response.streams, !streams.isEmpty else { return nil }
        return CoreStreamSourceGroup(id: base, addon: addon, streams: streams)
    }

    /// One ranged read of the chosen next-episode source shortly before the
    /// credits, so the provider has the file hot when auto-advance opens it; the
    /// cold start there is what used to cost 30 to 60 seconds. Torrents start
    /// their peer search at the same moment.
    private func warmNextIfReady() {
        guard let pre = preloaded, warmedID != pre.episodeID, let url = pre.stream.playableURL else { return }
        warmedID = pre.episodeID
        prepareTorrent(pre.stream)
        var request = URLRequest(url: url)
        request.setValue("bytes=0-16777215", forHTTPHeaderField: "Range")   // first 16 MB
        request.timeoutInterval = 60
        let log = plog
        let id = pre.episodeID
        log.info("warming next episode source for \(id, privacy: .public)")
        Task.detached(priority: .utility) {
            let size = (try? await URLSession.shared.data(for: request))?.0.count ?? -1
            log.info("warm result for \(id, privacy: .public): \(size) bytes")
        }
    }

    /// Torrents: ask the embedded server to start fetching peers before playback. No-op for url/debrid.
    private func prepareTorrent(_ stream: CoreStream) {
        guard !PlaybackSettings.torrentsDisabled else { return }
        guard stream.url == nil, let hash = stream.infoHash?.lowercased(),
              let url = URL(string: "\(StremioServer.base)/\(hash)/create") else { return }
        let sources = TorrentTrackers.sources(forHash: hash, streamSources: stream.sources)
        let body: [String: Any] = ["torrent": ["infoHash": hash],
                                   "peerSearch": ["sources": sources, "min": 40, "max": 150]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        // Guarantee the TV-safe cache + connection cap is applied BEFORE this engine is created: the server
        // reads cacheSize + btMaxConnections at engine-creation time (enginefs.getDefaults), and the boot-time
        // apply can silently miss on a slow cold start -- leaving this engine at the 2 GB default cache + 55
        // connections, which jetsams the whole 2 GB Apple TV under torrent load (the owner's "server crash /
        // hang after finishing one title and opening another" report). A quick (<=3 try) VERIFIED apply here
        // makes every torrent engine start capped, not just when the one-shot boot POST happened to land.
        // No-op on a custom remote server (applyServerConfig returns immediately when isCustom).
        Task {
            await StremioServer.applyServerConfig(maxAttempts: 3)
            var request = URLRequest(url: url); request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    /// Tell the embedded server to destroy a torrent engine (GET /{hash}/remove). Each engine
    /// holds peers, sockets, and a growing disk/RAM cache; leaving them running when we switch
    /// source, auto-fail over, advance an episode, or close the player piled them up until the
    /// server's RSS ballooned and it stopped answering (the 0.2.48 "torrents stopped playing,
    /// server went offline" regression). Symmetric with prepareTorrent's create.
    private func closeTorrent(hash: String) {
        let h = hash.lowercased()
        guard h.count == 40, let url = URL(string: "\(StremioServer.base)/\(h)/remove") else { return }
        DiagnosticsLog.log("torrent", "remove engine \(h.prefix(8))")
        URLSession.shared.dataTask(with: url).resume()
    }

    /// The single "user really left playback" exit. Destroys the live torrent engine (no-op for
    /// direct/debrid) right before dismissing, so the engine is freed on a GENUINE exit but never on
    /// a SwiftUI `.id(req.id)` rebuild — onDisappear no longer tears it down (see Fix B). Every real
    /// exit (Back-to-exit, the close button, the terminal auto-advance) routes through here, so no
    /// engine is leaked.
    private func leavePlayback() {
        if let hash = currentTorrentHash { closeTorrent(hash: hash) }
        // Force the OLD engine to halt decode + network and BEGIN teardown synchronously, right now, instead
        // of leaving it to whenever SwiftUI gets around to dismantle*. This is THE debrid crash fix: a debrid
        // title holds the FULL remote demuxer read-ahead + a 4K decoder, and without this stop() that engine
        // was still alive when the next title's player allocated its own buffers -- two decoding players
        // straddling on a 2 GB Apple TV jetsam-killed the whole device (the owner's "finish/stop, browse, open
        // another -> hang"). stop() is idempotent (guards on a live handle/item) so SwiftUI's later dismantle
        // is a harmless no-op, and this runs ONLY on a genuine exit (Back, close, terminal auto-advance), never
        // on an in-place source/episode switch or an onDisappear rebuild, so normal playback is untouched.
        coordinator.player?.stop()
        // Wipe the configurable on-disk streaming cache for the title that just finished/closed, so a
        // completed movie or episode never leaves its buffer on disk (the owner's clear-on-finish
        // guardrail). No-op when the disk cache is off or empty. This runs ONLY on a genuine exit
        // (Back / close / terminal auto-advance), never on an in-place source/episode switch, and is
        // additive: it does not touch the stop() teardown above.
        DiskCacheSetting.clearCache()
        onClose()
    }

    /// The 40-hex info-hash of the currently playing torrent, or nil for a direct/debrid stream.
    /// Matches the ACTIVE streaming server's host:port (the embedded :11470 OR a custom remote server),
    /// not a hardcoded :11470 -- otherwise closeTorrent silently skipped teardown for custom-server
    /// torrents and leaked their swarms (peers/sockets/cache) across plays, the same RSS-balloon that
    /// the embedded path's remove() exists to prevent. curURL is built from StremioServer.base, so the
    /// host+port compare against base is exact.
    private var currentTorrentHash: String? {
        guard let u = curURL, let serverBase = URL(string: StremioServer.base),
              u.host == serverBase.host, u.port == serverBase.port,
              u.pathComponents.count >= 2 else { return nil }
        let hash = u.pathComponents[1]
        return (hash.count == 40 && hash.allSatisfy(\.isHexDigit)) ? hash : nil
    }

    // MARK: - Playback helpers

    /// Seek to the saved position once BOTH the resume offset is fetched and the duration is known.
    /// No-op for live: a live stream's "position" is just elapsed buffer wall-clock, so seeking into a
    /// stored offset is meaningless (and would jump into the past). Mirrors PlayerScreen's live guard.
    private func maybeResume() {
        guard !isCurrentLiveStream else { return }
        guard !appliedResume, duration > 0, let r = resumeSeconds else { return }
        appliedResume = true
        guard r > 5, r < duration - 10 else { return }   // ignore trivial / near-end positions
        coordinator.player?.seek(to: r)
        currentTime = r
        lastSaved = r
    }

    /// Persist the current position to the account library (no-op without a library context). Also a
    /// no-op for live: persisting a live "position" would seed a bogus resume offset / fake Continue
    /// Watching entry the next time the channel opens. Mirrors PlayerScreen's live progress suppression.
    private func saveProgress(at position: Double) {
        guard !isCurrentLiveStream else { return }
        guard let m = curMeta, duration > 0, position >= 0 else { return }
        let dur = duration
        Task { await account.saveProgress(for: m, positionSeconds: position, durationSeconds: dur) }
    }

    private func toggle() {
        if loadFailed { retryLoad(); return }   // Play/Pause retries a failed source
        coordinator.player?.togglePause()
        showControls()
    }

    private func seek(_ delta: Double) {
        coordinator.player?.seek(by: delta)
        flashControls()
    }

    /// Jump back to the very start and keep playing.
    private func restart() {
        commitScrubIfNeeded()
        coordinator.player?.seek(to: 0)
        currentTime = 0; lastSaved = 0
        flashControls()
    }

    // MARK: - Scrub-to-seek (the scrubber row)

    /// Move the preview playhead one step in `dir`. The step grows on rapid or held presses (10s up to
    /// 120s) so you cross a long film in a few presses or a single hold, instead of tapping ±10 a hundred
    /// times. Nothing is actually sought until commit.
    private func scrubBy(_ dir: Int) {
        guard duration > 0 else { return }
        let now = Date().timeIntervalSinceReferenceDate
        if !scrubbing {
            scrubbing = true; scrubTarget = currentTime; scrubStep = 10
        } else if now - lastScrubAt < 0.4 {
            // Gentle LINEAR ramp while holding. The old 1.6x exponential hit the 120s cap in a few
            // repeats, so a brief hold flung the play head by wildly different amounts each press,
            // which is the "jumps randomly" feel. A fixed +6 grows predictably and tops out lower, so
            // a hold glides across the timeline at a controllable, even pace.
            scrubStep = min(scrubStep + 6, 75)
        } else {
            scrubStep = 10                               // paused between presses → back to fine steps
        }
        lastScrubAt = now
        scrubTarget = min(duration, max(0, scrubTarget + Double(dir) * scrubStep))
        scrubThumbnails.show(time: scrubTarget)
        flashControls()
        scheduleScrubCommit()
    }

    /// Commit the seek a beat after the last scrub move, so a hold is one seek at the end, not hundreds.
    private func scheduleScrubCommit() {
        scrubCommit?.cancel()
        scrubCommit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, scrubbing else { return }
            commitScrub()
        }
    }
    private func commitScrub() {
        scrubCommit?.cancel()
        guard scrubbing else { return }
        scrubbing = false
        coordinator.player?.seek(to: scrubTarget)
        currentTime = scrubTarget; lastSaved = scrubTarget
        scrubThumbnails.clear()
        flashControls()
    }
    private func commitScrubIfNeeded() { if scrubbing { commitScrub() } }
    /// Discard the in-progress scrub preview and keep playing where we are (Menu while scrubbing).
    private func cancelScrub() { scrubCommit?.cancel(); scrubbing = false; scrubThumbnails.clear(); flashControls() }

    // MARK: - Local trickplay

    private var trickplayLocalCacheKey: String {
        if let m = curMeta { return "v:\(m.libraryId):\(m.videoId)" }
        return "u:\((curURL ?? url).absoluteString)"
    }

    private func maybeCaptureLocalTrickplay(at time: Double) {
        guard !scrubbing, !buffering, !isPaused else { return }   // AVPlayer now captures too (AVPlayerItemVideoOutput)
        guard time - lastLocalTrickplayCapture >= Self.trickplayCaptureIntervalSecs else { return }
        captureTrickplayFrame(at: time)
    }

    /// The one place a trickplay frame is grabbed (from the timePos tick OR the wall-clock timer). Engine-
    /// agnostic + logged so a silent pool can be traced from a terminal run (which stage refused / nil frame).
    private func captureTrickplayFrame(at time: Double) {
        guard !localTrickplayCaptureInFlight else { return }
        guard let player = coordinator.player else { NSLog("[tp-cap] no player mounted at %.0fs (tvOS)", time); return }
        lastLocalTrickplayCapture = time
        localTrickplayCaptureInFlight = true
        let engine = (player is AVPlayerEngineController) ? "avplayer" : "libmpv"
        // In-flight watchdog: the libmpv capture is serviced on mpv's VO thread inside nextDrawable(); if that
        // thread is momentarily idle the handler may never fire, so release the guard after 3s to avoid a
        // permanent wedge that would silently skip every later capture.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self.localTrickplayCaptureInFlight else { return }
            self.localTrickplayCaptureInFlight = false
            NSLog("[tp-cap] %@ capture at %.0fs never serviced (VO idle, tvOS) - releasing guard", engine, time)
        }
        player.captureFrameJPEGData(maxWidth: 480) { data in
            // MAIN-ACTOR HOP (parity with PlayerScreen; the owner-device zero-contribution fix): the libmpv
            // engine calls this completion on its background capture queue, NOT the main thread, so the
            // @MainActor `localTrickplayCaptureInFlight` reset and `recordCapturedFrameData` (which appends to
            // sessionFrames and fires the community upload) must be hopped onto the main actor here rather than
            // relying on the engine. Otherwise a libmpv play accumulates community frames off-main against
            // main-actor state and can contribute ZERO pool rows. `data` (Data) is Sendable.
            //
            // The heavy JPEG decode runs HERE, off the main actor (this libmpv completion is on a background
            // capture queue), so only the small main-actor tail (in-flight reset + record/upload of the
            // already-decoded frame) hops to the main actor, keeping the ~10s decode off the UI thread.
            guard let data else {
                Task { @MainActor in
                    watchdog.cancel()
                    self.localTrickplayCaptureInFlight = false
                    NSLog("[tp-cap] %@ captureFrameJPEGData returned NIL at %.0fs (tvOS)", engine, time)
                }
                return
            }
            NSLog("[tp-cap] %@ captured %d bytes at %.0fs (tvOS)", engine, data.count, time)
            let decoded = ScrubThumbnailsStore.decodeCapturedFrame(data, at: time)   // heavy decode OFF main
            Task { @MainActor in
                watchdog.cancel()
                self.localTrickplayCaptureInFlight = false
                guard let decoded else { return }   // decode failed / near-black: already logged off-actor
                self.scrubThumbnails.recordDecodedFrame(decoded, data: data, at: time)
            }
        }
    }

    /// Wall-clock capture driver (tvOS twin of PlayerScreen.startTrickplayCaptureTimer): a repeating ~10s
    /// timer gated on active playback, capturing off the LIVE engine position so trickplay is generated even
    /// when the engine's timePos event stream is sparse/coalesced on a 4K/HDR/DV stream.
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

    /// Scrubber row that expands upward to show a trickplay bubble when the user is scrubbing.
    private var trickplayControls: some View {
        let shown = scrubbing ? scrubTarget : currentTime
        let frac = duration > 0 ? min(1, max(0, shown / duration)) : 0
        // Wide enough for the longest side label, the "Ends 10:45 PM" wall-clock line, at tvOS caption
        // size. The earlier 130 fit "1:23:45" but clipped the ends-at clock to its first digits (#71).
        let sideWidth: CGFloat = 210
        let spacing = Theme.Space.md
        let bubbleWidth: CGFloat = 480
        let bubbleHeight: CGFloat = 270
        return GeometryReader { geo in
            let scrubWidth = max(1, geo.size.width - sideWidth * 2 - spacing * 2)
            let knobX = sideWidth + spacing + scrubWidth * frac
            ZStack(alignment: .bottomLeading) {
                if scrubbing, let image = scrubThumbnails.image {
                    trickplayBubble(image, time: shown)
                        .offset(x: min(max(0, knobX - bubbleWidth / 2), max(0, geo.size.width - bubbleWidth)), y: -42)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }
                HStack(spacing: spacing) {
                    Text(timeString(shown)).font(.callout.monospacedDigit())
                        .foregroundStyle(scrubbing ? Theme.Palette.accent : Theme.Palette.textPrimary)
                        .frame(width: sideWidth, alignment: .leading)
                    scrubber
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(timeString(duration)).font(.callout.monospacedDigit())
                            .foregroundStyle(Theme.Palette.textSecondary)
                        if let ends = endsAtClock {
                            Text(ends).font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                    .frame(width: sideWidth, alignment: .trailing)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .animation(.easeOut(duration: 0.12), value: scrubThumbnails.image != nil)
        }
        .frame(height: scrubbing && scrubThumbnails.image != nil ? bubbleHeight + 26 : 28)
    }

    private func trickplayBubble(_ image: UIImage, time: Double) -> some View {
        VStack(spacing: 6) {
            Image(uiImage: image)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 480, height: 270)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(timeString(time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .padding(6)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Theme.Palette.textPrimary.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }

    /// Reveal the bar from a hidden state, selecting Play, and restart the auto-hide timer.
    private func showControls() {
        if !showInfo { withAnimation { showInfo = true } }
        if controlsHidden || selected == .close { selected = .play }
        scheduleHide()
    }
    /// Keep the bar visible and reset the auto-hide timer, without changing the selection.
    private func flashControls() {
        if !showInfo { withAnimation { showInfo = true } }   // no SwiftUI transaction per repeat-press when already shown
        scheduleHide()
    }

    /// Push the auto-hide deadline forward. A single long-lived poll loop (started in
    /// onAppear) does the hiding, so a remote press here is just a Date assignment, not
    /// a Task cancel-and-recreate 6-8 times a second during held-key navigation.
    private func scheduleHide() {
        hideDeadline = Date().addingTimeInterval(8)
    }

    /// The one hide loop. Polls twice a second; hides the bar once the deadline passes
    /// and no options panel is open. Cancelled in onDisappear.
    private func startHideLoop() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if showInfo, !showOptions, !loadFailed, Date() >= hideDeadline {
                    withAnimation { showInfo = false }
                }
            }
        }
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - UIKit remote catcher

/// A focusable UIView that captures every Siri-remote press and forwards it to SwiftUI. This is far more
/// reliable than SwiftUI `@FocusState` + `onMoveCommand` inside a full-screen cover on tvOS.
private struct RemoteCatcher: UIViewControllerRepresentable {
    var onPress: (UIPress.PressType) -> Void
    var onSwipe: () -> Void

    func makeUIViewController(context: Context) -> CatchVC {
        let vc = CatchVC(); vc.onPress = onPress; vc.onSwipe = onSwipe; return vc
    }
    func updateUIViewController(_ vc: CatchVC, context: Context) { vc.onPress = onPress; vc.onSwipe = onSwipe }

    /// Focusable root view for the catcher controller.
    final class FocusableView: UIView {
        override var canBecomeFocused: Bool { true }
    }

    /// Owns the remote. Its root view is the only focusable; `preferredFocusEnvironments` points at it, so
    /// the focus system always has an explicit target to keep, or pull, focus onto the catcher, even when
    /// a directional press would otherwise move focus to nothing (which left the player deaf to the remote).
    final class CatchVC: UIViewController {
        var onPress: ((UIPress.PressType) -> Void)?
        var onSwipe: (() -> Void)?

        override func loadView() { view = FocusableView() }

        override var preferredFocusEnvironments: [UIFocusEnvironment] {
            isViewLoaded ? [view] : super.preferredFocusEnvironments
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            // Swipes on the Siri-remote touch surface are NOT UIPress events, so pressesBegan never sees
            // them. A pan recognizer for indirect (remote) touches wakes the controls on a swipe.
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSurfaceTouch))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            view.addGestureRecognizer(pan)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            setNeedsFocusUpdate(); updateFocusIfNeeded()
        }

        /// Lock focus on the catcher. It is the ONLY focusable while playing and it handles every remote
        /// input itself (hidden state, control-bar navigation, AND the audio/subtitle panel), so it never
        /// needs to yield focus. Without this, a directional press knocks focus to nil and the controls
        /// stop responding until an async re-grab catches up, a race the input never wins under load.
        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            if isViewLoaded, view.window != nil, context.nextFocusedItem !== view {
                return false
            }
            return super.shouldUpdateFocus(in: context)
        }

        /// Swipes both wake the controls AND navigate them: the pan accumulates into
        /// discrete directional presses (one per threshold crossing, dominant axis wins),
        /// so the touch surface moves the selection exactly like the arrow buttons do.
        private var panAccumulator = CGPoint.zero

        @objc private func handleSurfaceTouch(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                panAccumulator = .zero
                onSwipe?()
            case .changed:
                let t = g.translation(in: view)
                panAccumulator.x += t.x
                panAccumulator.y += t.y
                g.setTranslation(.zero, in: view)
                let threshold: CGFloat = 300   // a deliberate flick, not a resting thumb
                while abs(panAccumulator.x) >= threshold || abs(panAccumulator.y) >= threshold {
                    if abs(panAccumulator.x) >= abs(panAccumulator.y) {
                        onPress?(panAccumulator.x > 0 ? .rightArrow : .leftArrow)
                        panAccumulator.x -= panAccumulator.x > 0 ? threshold : -threshold
                        panAccumulator.y = 0
                    } else {
                        onPress?(panAccumulator.y > 0 ? .downArrow : .upArrow)
                        panAccumulator.y -= panAccumulator.y > 0 ? threshold : -threshold
                        panAccumulator.x = 0
                    }
                }
            default:
                panAccumulator = .zero
            }
        }

        // Hold an arrow → repeat the press, so you can hold to seek (the scrubber) or scroll a long list.
        // tvOS skips its own key-repeat because we own focus, so we synthesize it: fire once on press,
        // then repeat after a short hold delay until release. A hard cap guards a missed pressesEnded.
        private var repeatTimer: Timer?
        private var repeatType: UIPress.PressType?
        private var repeatCount = 0

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                switch press.type {
                case .select, .menu, .playPause:
                    onPress?(press.type); handled = true
                case .upArrow, .downArrow, .leftArrow, .rightArrow:
                    onPress?(press.type); handled = true
                    startRepeat(press.type)
                default: break
                }
            }
            if !handled { super.pressesBegan(presses, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            stopRepeat()
            // Swallow the RELEASE of every press type pressesBegan handled, not just
            // the press itself. Forwarding the menu release to UIKit let the system
            // act on it anyway and suspend the app to the home screen, intermittently,
            // raced against the player teardown the menu press had just started.
            let unhandled = presses.filter {
                switch $0.type {
                case .select, .menu, .playPause, .upArrow, .downArrow, .leftArrow, .rightArrow:
                    return false
                default:
                    return true
                }
            }
            if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
        }
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            stopRepeat(); super.pressesCancelled(presses, with: event)
        }

        private func startRepeat(_ type: UIPress.PressType) {
            stopRepeat()
            repeatType = type; repeatCount = 0
            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] t in
                guard let self, let type = self.repeatType else { t.invalidate(); return }
                self.repeatCount += 1
                if self.repeatCount > 120 { self.stopRepeat(); return }   // ~14s safety cap
                self.onPress?(type)
            }
            timer.fireDate = Date().addingTimeInterval(0.45)              // hold delay before repeats kick in
            RunLoop.main.add(timer, forMode: .common)
            repeatTimer = timer
        }
        private func stopRepeat() { repeatTimer?.invalidate(); repeatTimer = nil; repeatType = nil }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            // Keep focus on the catcher: if it drifts off (e.g. a directional press moves focus to nil),
            // re-request. preferredFocusEnvironments gives the system an explicit target (our view), so
            // focus returns reliably with no competitor to fight.
            if isViewLoaded, view.window != nil, (context.nextFocusedItem as? UIView) !== view {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isViewLoaded, self.view.window != nil, !self.view.isFocused else { return }
                    self.setNeedsFocusUpdate()
                    self.updateFocusIfNeeded()
                }
            }
        }
    }
}
