import SwiftUI
#if canImport(AppKit)
import AppKit
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
    var recordIsTorrent: Bool = false                       // stream rides the embedded torrent engine
    // In-player episode navigation (series only). The ordered season episodes + a closure resolving any
    // episode id to a ready-to-play stream let the player advance Next / Prev and at end-of-episode IN
    // PLACE (a smooth source hot-swap, no cover teardown). Empty for movies / ad-hoc plays. The caller
    // (iOSEpisodeStreams) owns the resolve, so ranking / direct-links / torrent-prime / resume stay in one
    // place. Declared here (right after the record-* inputs) so the call-site argument order is valid.
    // When `episodes` is non-empty the player derives Next/Prev from the CURRENT episode, ignoring the
    // legacy `hasNext` / `onNext`.
    var episodes: [PlayerEpisodeRef] = []
    var loadEpisode: ((String) async -> PlayerEpisodeStream?)? = nil
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

    // MARK: Panels

    private enum Panel: Identifiable, Equatable {
        case speed, subtitles, subtitleSettings, audio, audioSettings, video, sources, episodes, info, playerSettings, sleep
        var id: Int {
            switch self {
            case .speed: 0; case .subtitles: 1; case .subtitleSettings: 2; case .audio: 3
            case .audioSettings: 4; case .video: 5; case .sources: 6; case .info: 7
            case .playerSettings: 8; case .sleep: 9; case .episodes: 10
            }
        }
        var title: String {
            switch self {
            case .speed: "Playback Speed"; case .subtitles: "Subtitles"
            case .subtitleSettings: "Subtitle Settings"; case .audio: "Audio"
            case .audioSettings: "Audio Settings"; case .video: "Aspect Ratio"
            case .sources: "Sources"; case .info: "Playback Info"; case .playerSettings: "Player Settings"
            case .sleep: "Sleep Timer"; case .episodes: "Episodes"
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
        var apply: () -> Void = {}
    }

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    // "original" (default) = whole frame at correct aspect (panscan=0), like actual Stremio; "fill"
    // crops to fill (panscan=1); "stretch" distorts. Labels mirror tvOS's Aspect Ratio panel.
    private let sizeModes: [(raw: String, label: String, detail: String)] = [
        ("original", "Fit", "default"), ("fill", "Fill", "crop to screen"), ("stretch", "Stretch", "fill, distort")
    ]

    @StateObject private var coordinator = MPVMetalPlayerView.Coordinator()
    @AppStorage("stremiox.videoSize") private var videoSize = "original"   // whole frame, correct aspect
    @State private var appliedSize = false
    @State private var appliedInitialResume = false   // the launch-offset seek runs once; switches use nudgeResume
    @State private var markedWatched = false           // ~90%/EOF watched marker fires once per title (mirrors tvOS)
    @State private var buffering = true
    @State private var currentTime = 0.0
    @State private var duration = 0.0
    @State private var lastReported = -1.0     // last whole-second progress pushed to stremio-core
    @State private var isPaused = false
    @State private var speed = 1.0
    @State private var audioTracks: [MPVTrack] = []
    @State private var subtitleTracks: [MPVTrack] = []
    @State private var appliedAutoTracks = false
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
    @State private var showShare = false             // system share sheet
    // Current-episode tracking for in-place episode switching: seeded from the launch values, updated on
    // every Next/Prev/list switch so progress, the watched marker, Continue-Watching, skip timestamps,
    // and add-on subtitles all key off the episode ACTUALLY playing (not the one first opened).
    @State private var curMetaState: PlaybackMeta? = nil
    @State private var curTitleState: String? = nil
    @State private var switchingEpisode = false       // a Next/Prev/list switch is resolving its stream
    private var curMeta: PlaybackMeta? { curMetaState ?? recordMeta }
    private var curTitle: String { curTitleState ?? title }

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

    // Load failure / recovery state (mirrors TVPlayerView).
    @State private var loadFailed = false            // playback couldn't start (dead/uncached link)
    @State private var loadErrorMsg = ""
    @State private var hasStartedPlaying = false
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
    @State private var apiSkipCandidates: [SegmentCandidate] = []
    @State private var currentSkip: SkipSegment?
    @State private var skipFetchKey = ""
    @State private var skipFetchTask: Task<Void, Never>?

    // Playback-info overlay rows, refreshed while the Info panel is open.
    @State private var infoRows: [(String, String)] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MPVMetalPlayerView(coordinator: coordinator)
                .play(initialPlayback.url, headers: initialPlayback.headers)
                .live(initialIsLive)
                .onPropertyChange { _, name, data in handleProperty(name, data) }
                .ignoresSafeArea()

            // Reliable tap-to-toggle: a transparent hit-test layer over the video. The UIKit
            // recognizer on the Metal view frequently missed taps (you had to tap many times);
            // a SwiftUI contentShape layer catches every tap. The controls sit above it, so their
            // buttons still work and a tap on empty space falls through here to toggle.
            Color.clear.contentShape(Rectangle()).onTapGesture { toggleControls() }.ignoresSafeArea()
                .accessibilityLabel("Show player controls")
                .accessibilityAction { toggleControls() }

            if (buffering || reconnecting) && !loadFailed { bufferingOverlay }

            // Skip pill shows only while watching (controls hidden), mirroring tvOS.
            if let seg = currentSkip, !controlsVisible, panel == nil, !loadFailed { skipPill(seg) }

            // Render controls UNCONDITIONALLY (just faded/non-interactive when hidden) so VoiceOver can
            // still reach them when auto-hidden — otherwise a hidden bar drops out of the a11y tree (#31).
            if !loadFailed {
                controls.opacity(controlsVisible ? 1 : 0).allowsHitTesting(controlsVisible)
            }

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
            #endif
        }
        #if os(iOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
        .tint(Theme.Palette.accent)
        .onAppear {
            curURL = url; curHeaders = headers; curIsTorrent = recordIsTorrent
            scheduleHide(); startLoadTimeout()
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true   // hold the screen awake while the player is open (parity with tvOS)
            #elseif os(macOS)
            // macOS has no idle-timer API; hold a display-sleep assertion so the Mac doesn't dim/sleep
            // mid-movie (the iOS/tvOS keep-awake parity that was missing on Mac).
            macSleepActivity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled,
                                                                     reason: "StremioX video playback")
            #endif
        }
        .onDisappear {
            hideTask?.cancel(); loadTimeout?.cancel(); autoRetryTask?.cancel()
            stallWatchdog?.cancel(); recoveryDeadline?.cancel(); skipFetchTask?.cancel()
            refreshTask?.cancel(); sleepTask?.cancel()
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false  // let the screensaver / auto-lock resume once the player closes
            #elseif os(macOS)
            if let token = macSleepActivity { ProcessInfo.processInfo.endActivity(token); macSleepActivity = nil }
            #endif
        }
        .confirmationDialog("Play in another app", isPresented: $showExternalChooser,
                            titleVisibility: .visible) {
            ForEach(ExternalPlayer.installed) { target in
                Button(target.name) {
                    // Handed off, stop local playback so the stream isn't decoded twice.
                    if ExternalPlayer.open(target, stream: curURL ?? url), !isPaused {
                        coordinator.player?.togglePause()
                    }
                }
            }
            Button("Share or open in…") { showShare = true }
            Button("Copy stream link") {
                #if canImport(UIKit)
                UIPasteboard.general.url = curURL ?? url
                #elseif canImport(AppKit)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString((curURL ?? url).absoluteString, forType: .string)
                #endif
            }
            Button("Cancel", role: .cancel) { scheduleHide() }
        } message: {
            Text(externalChooserMessage)
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: [curURL ?? url]) }
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
                    startStallWatchdog()            // arm mid-playback freeze detection
                    fetchSkipTimestamps()           // crowd intro/outro spans (disk-cached, non-blocking)
                    fetchAddonSubtitles()
                }
                if !scrubbing {
                    currentTime = d
                    updateCurrentSkip(at: d)
                    // Live streams must NOT write a resume offset: their "position" is just elapsed
                    // wall-clock of the buffer, and persisting it would make a later open seek into a
                    // bogus offset (or drop a fake Continue-Watching entry).
                    if !isLive, duration > 0, d - lastReported >= 5 {   // push progress ~every 5s
                        lastReported = d
                        onProgress(d, duration)
                    }
                    // ~90% in → flip the engine's watched marker live, so the title leaves Continue
                    // Watching / shows as watched without waiting for EOF (mirrors tvOS:180-183).
                    if !markedWatched, !isLive, duration > 0, d / duration >= 0.9, let m = curMeta {
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
            }
        case MPVProperty.pause:
            if let b = data as? Bool { isPaused = b }
        case MPVProperty.trackList:
            refreshTracks()
            let summary = coordinator.player?.mediaSummary()
            videoHeight = summary?.height ?? 0; audioCodec = summary?.audioCodec ?? ""
            metadataLine = computeMetadataLine()
            if !appliedAutoTracks, !audioTracks.isEmpty || !subtitleTracks.isEmpty {
                appliedAutoTracks = true
                autoSelectTracks()
            }
        case MPVProperty.endFileError:
            if !hasStartedPlaying {                  // only flag failures BEFORE playback
                handleLoadFailure((data as? String) ?? "")
            }
        case MPVProperty.endFileEof:
            // Mark watched if the 90% tick didn't already (short clips), then advance or finish.
            if !markedWatched, !isLive, let m = curMeta { markedWatched = true; core.markPlaybackWatched(m) }
            if sleepAtEpisodeEnd {
                // Sleep timer set to "End of episode": this one finished, so stop here. Do NOT auto-advance,
                // and do NOT finishedWatching (that would clear the whole series from Continue Watching).
                sleepAtEpisodeEnd = false
                onClose()
            } else if canNextEpisode, let i = episodeIndex {
                goToEpisode(episodes[i + 1].id, autoAdvance: true)   // in-place advance to the next episode
            } else if hasNext {
                onNext()                                  // legacy non-episode caller
            } else {
                // Finished (movie or last episode): rewind the title OUT of Continue Watching. The engine
                // keeps any item with time_offset > 0 in the rail, so without this a finished title lingers
                // at its end position forever (the "CW never clears" report). Mirrors tvOS autoAdvance:1479.
                if let m = curMeta { core.finishedWatching(libraryId: m.libraryId) }
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
    /// of TVPlayerView's record-on-start. Records the bare `curURL`/`curHeaders` the active source was
    /// launched with (a proxied loopback URL is rebuilt from these on resume), not the internal
    /// `initialPlayback` rewrite. No-op for ad-hoc plays with no `recordMeta` (e.g. paste-a-link).
    private func recordLastStream() {
        guard !isLive else { return }   // live has no resumable position → don't seed CW direct-resume
        guard let m = curMeta else { return }
        LastStreamStore.record(libraryId: m.libraryId, entry: .init(
            videoId: m.videoId, url: (curURL ?? url).absoluteString, title: curTitle,
            season: m.season, episode: m.episode, name: m.name,
            poster: m.poster, type: m.type, qualityText: recordQualityText,
            torrent: curIsTorrent, savedAt: Date(), headers: curHeaders),
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
        coordinator.player?.loadFile(p.url, headers: p.headers, live: live)
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
        buffering = true; hasStartedPlaying = false; appliedSize = false; loadErrorMsg = ""
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
        appliedSize = false; hasStartedPlaying = false; buffering = true
        loadIntoPlayer(curURL ?? url, headers: curHeaders, live: isLive)
        if resume > 5 { nudgeResume(to: resume) }   // jump back to where it froze once mpv is ready
    }

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

    /// The best playable stream not yet tried for this title / episode, honouring the user's source
    /// ordering + continuity / binge hints. Returns nil when nothing untried remains.
    private func nextUntriedStream() -> CoreStream? {
        let remaining = currentSourceGroups.map { group in
            CoreStreamSourceGroup(id: group.id, addon: group.addon, streams: group.streams.filter { s in
                guard let u = s.playableURL else { return false }
                return u != curURL && !exhaustedURLs.contains(u)
            })
        }
        return StreamRanking.best(remaining, continuity: recordQualityText, binge: nil)
    }

    /// The playing source is dead (retry / stall budget ran out): mark it exhausted and hop to the
    /// next-best untried source automatically. Returns false when the hop budget is spent or nothing
    /// untried remains; the caller then shows the error overlay. Mirrors tvOS `hopToNextSource`.
    @discardableResult
    private func hopToNextSource(reason: String) -> Bool {
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
        if resumeOverride != nil { currentTime = 0; duration = 0 }   // episode switch: brand-new media, reset the clock
        appliedSize = false; appliedAutoTracks = false
        hasStartedPlaying = false; buffering = true; loadErrorMsg = ""
        autoRetryCount = 0; reconnecting = false; autoRetryTask?.cancel()
        torrentWarmupsUsed = 0; torrentStatus = nil   // a new source is a fresh torrent → its own warm-up budget
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
    private var canPrevEpisode: Bool { (episodeIndex ?? -1) > 0 }

    private func goToNextEpisode() { if let i = episodeIndex, i + 1 < episodes.count { goToEpisode(episodes[i + 1].id) } }
    private func goToPrevEpisode() { if let i = episodeIndex, i > 0 { goToEpisode(episodes[i - 1].id) } }

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
            markedWatched = false
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
        switch videoHeight {
        case 2000...:     parts.append("4K")
        case 1300..<2000: parts.append("1440p")
        case 900..<1300:  parts.append("1080p")
        case 600..<900:   parts.append("720p")
        case 1..<600:     parts.append("\(videoHeight)p")
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
            iconButton("gearshape", label: "Player settings") { openPanel(.playerSettings) }   // decoder toggle + playback info (tvOS parity #22)
            iconButton("arrow.up.forward.app", label: "Play in another app") {       // hand off to Infuse / VLC / Share
                hideTask?.cancel()
                showExternalChooser = true
            }
        }
        .padding(.horizontal).padding(.top, 8)
    }

    private var centerTransport: some View {
        HStack(spacing: 44) {
            // Skip back 10s (hidden for live — no fixed timeline to seek within).
            if !isLive {
                seekButton("gobackward.10", by: -10)
            }
            Button { coordinator.player?.togglePause(); scheduleHide() } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 50)).foregroundStyle(.white).shadow(radius: 8)
                    .frame(width: 100, height: 100)
            }
            .accessibilityLabel(isPaused ? "Play" : "Pause")
            if !isLive {
                seekButton("goforward.10", by: 10)
            }
        }
    }

    private func seekButton(_ icon: String, by delta: Double) -> some View {
        Button {
            let target = min(max(currentTime + delta, 0), max(duration - 1, 0))
            coordinator.player?.seek(to: target)
            currentTime = target
            if duration > 0 { onSeek(target, duration); lastReported = target }
            scheduleHide()
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
                    // While dragging, the thumb follows a local scrubTarget so an incoming timePos tick
                    // can't yank it back to the (pre-seek) playback position (#32). On release we commit
                    // scrubTarget once. Outside a drag the thumb tracks live currentTime.
                    Slider(value: Binding(get: { scrubbing ? scrubTarget : currentTime },
                                          set: { scrubTarget = $0 }),
                           in: 0...max(duration, 1)) { editing in
                        scrubbing = editing
                        if editing { scrubTarget = currentTime; hideTask?.cancel() }
                        else {
                            currentTime = scrubTarget
                            coordinator.player?.seek(to: scrubTarget)
                            if duration > 0 { onSeek(scrubTarget, duration); lastReported = scrubTarget }
                            scheduleHide()
                        }
                    }.tint(Theme.Palette.accent)
                    Text(timeString(duration)).font(.caption.monospacedDigit()).foregroundStyle(.white)
                }
            }

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
                if hasAlternateSources {
                    Spacer()
                    controlButton("rectangle.stack", "Sources") { openPanel(.sources) }
                }
                if episodes.count > 1 {
                    Spacer()
                    controlButton("list.bullet", "Episodes") { openPanel(.episodes) }
                }
                Spacer()
                controlButton(sleepArmed ? "moon.zzz.fill" : "moon.zzz", sleepLabel) { openPanel(.sleep) }
            }
            .padding(.horizontal, 8)
        }
        .padding(.horizontal).padding(.bottom, 22)
    }

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
        if skip?.start != currentSkip?.start {
            withAnimation(.easeInOut(duration: 0.2)) { currentSkip = skip }
        }
    }
    private func refreshSkipSegments() {
        let chapterCandidates = SkipSegments.chapterCandidates(chapters: coordinator.player?.chapters() ?? [],
                                                               duration: duration)
        skipSegments = SegmentResolver.resolve(chapterCandidates + apiSkipCandidates, duration: duration)
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
        let dur = duration
        skipFetchTask?.cancel()
        skipFetchTask = Task { @MainActor in
            let found = await SkipTimestampService.candidates(imdbId: m.libraryId, season: m.season,
                                                              episode: m.episode, durationSeconds: dur)
            guard !Task.isCancelled, skipFetchKey == key else { return }
            apiSkipCandidates = found
            refreshSkipSegments()
        }
    }

    // MARK: - Add-on subtitles

    private func fetchAddonSubtitles() {
        guard let m = curMeta else { return }
        let key = "\(m.type):\(m.videoId)"
        guard key != addonSubsKey else { return }
        addonSubsKey = key
        addonSubs = []; addedSubURLs = []
        let addons = account.addons
        Task { @MainActor in
            let subs = await SubtitleAddonService.fetch(addons: addons, type: m.type, videoId: m.videoId)
            guard addonSubsKey == key else { return }   // episode changed mid-fetch
            addonSubs = subs
            if panel == .subtitles { panelRows = rows(for: .subtitles) }
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
                // Selection / value may have changed (sync, size, tracks, sources) — recompute in place
                // so checkmarks + readouts stay honest; panels that should dismiss call close() in apply.
                if let openPanel = panel { panelRows = rows(for: openPanel) }
            } label: {
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
            var rs: [Row] = [Row(label: "Off", selected: subtitleTracks.allSatisfy { !$0.selected }) {
                coordinator.player?.setSubtitleTrack(-1)
            }]
            rs += groupedTrackRows(subtitleTracks) { coordinator.player?.setSubtitleTrack($0) }
            let available = addonSubs.filter { !addedSubURLs.contains($0.url) }
            if !available.isEmpty {
                rs.append(Row(label: "From add-ons", isHeader: true))
                for sub in available.prefix(30) {
                    rs.append(Row(label: langName(sub.lang), detail: sub.addonName) {
                        coordinator.player?.addExternalSubtitle(url: sub.url, title: sub.addonName, lang: sub.lang)
                        addedSubURLs.insert(sub.url)
                    })
                }
            }
            rs.append(Row(label: "Subtitle Settings", detail: "›") { openPanel(.subtitleSettings) })
            return rs
        case .subtitleSettings:
            let now = String(format: "%+.1fs", subDelay)
            var rs = [Row(label: "Sync", isHeader: true),
                      Row(label: "Earlier  −0.1s", detail: now) { adjustSubDelay(-0.1) },
                      Row(label: "Later  +0.1s", detail: now) { adjustSubDelay(0.1) }]
            if subDelay != 0 { rs.append(Row(label: "Reset sync") { adjustSubDelay(-subDelay) }) }
            rs.append(Row(label: "Size", isHeader: true))
            for s in SubtitleStyle.sizes { rs.append(Row(label: s.label, selected: subSize == s.id) { setSubtitleSize(s.id) }) }
            let scalePct = "\(Int((subSizeScale * 100).rounded()))%"
            rs.append(Row(label: "Smaller  −", detail: scalePct) { adjustSubScale(-1) })
            rs.append(Row(label: "Bigger  +", detail: scalePct) { adjustSubScale(1) })
            rs.append(Row(label: "Colour", isHeader: true))
            for c in SubtitleStyle.colors { rs.append(Row(label: c.label, selected: subColor == c.id) { setSubtitleColor(c.id) }) }
            rs.append(Row(label: "Background", isHeader: true))
            for b in SubtitleStyle.backgrounds { rs.append(Row(label: b.label, selected: subBackground == b.id) { setSubtitleBackground(b.id) }) }
            return rs
        case .audio:
            var rs = groupedTrackRows(audioTracks) { coordinator.player?.setAudioTrack($0) }
            rs.append(Row(label: "Audio Settings", detail: "›") { openPanel(.audioSettings) })
            return rs
        case .audioSettings:
            let now = String(format: "%+.1fs", audioDelay)
            var rs = [Row(label: "Sync", isHeader: true),
                      Row(label: "Earlier  −0.1s", detail: now) { adjustAudioDelay(-0.1) },
                      Row(label: "Later  +0.1s", detail: now) { adjustAudioDelay(0.1) }]
            if audioDelay != 0 { rs.append(Row(label: "Reset sync") { adjustAudioDelay(-audioDelay) }) }
            // Output mode, mirrored from Settings so it's reachable mid-playback (the "no passthrough
            // in the player" report). Applies live; mpv re-opens the audio output on the change.
            let mode = AudioOutputMode.current
            rs.append(Row(label: "Output", isHeader: true))
            for m in AudioOutputMode.allCases {
                rs.append(Row(label: m.label, selected: m == mode) {
                    coordinator.player?.setAudioOutputMode(m)
                })
            }
            return rs
        case .sources:
            return sourceRows()
        case .info:
            let stats = infoRows
            if stats.isEmpty { return [Row(label: "No info yet", isHeader: true)] }
            return stats.map { Row(label: $0.0, detail: $0.1) }
        case .playerSettings:
            let hw = coordinator.player?.hardwareDecoding ?? true
            return [
                Row(label: "Decoder", isHeader: true),
                Row(label: "Hardware", detail: "recommended", selected: hw) {
                    coordinator.player?.setHardwareDecoding(true)
                },
                Row(label: "Software", detail: "rescues green / garbled frames", selected: !hw) {
                    coordinator.player?.setHardwareDecoding(false)
                },
                Row(label: "Playback Info", detail: "›") { openPanel(.info) },
            ]
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
        if !isLive, duration > 0 { onProgress(currentTime, duration) }
        onClose()
    }

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
            guard !Task.isCancelled, hasStartedPlaying, !scrubbing, panel == nil, !isPaused else { return }
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
