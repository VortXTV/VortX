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
    var onClose: () -> Void = {}           // dismiss the dedicated player window

    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @State private var markedWatched = false   // mark the engine watched once, near end of playback
    @StateObject private var coordinator = MPVMetalPlayerView.Coordinator()
    @State private var buffering = true
    @State private var isPaused = false
    @State private var currentTime = 0.0
    @State private var duration = 0.0
    @State private var videoHeight = 0          // metadata line: encoded height (2160 -> "4K")
    @State private var audioCodec = ""          // metadata line: active audio codec (e.g. "eac3")
    @State private var isHDR = false            // metadata line: HDR/DV detected (sig-peak > 1)
    @State private var resumeSeconds: Double? = nil   // nil until fetched; applied once duration known
    @State private var appliedResume = false
    @State private var lastSaved = -1.0               // last position persisted (throttle)
    @State private var showInfo = true
    @State private var hideTask: Task<Void, Never>?
    @State private var audioTracks: [MPVTrack] = []
    @State private var subtitleTracks: [MPVTrack] = []
    @State private var appliedAutoTracks = false       // auto-select audio/subtitle once per load
    @State private var showOptions = false             // options panel (audio / subtitles / aspect / episodes)
    @State private var panelKind: PanelKind = .audio   // which list the options panel shows
    @State private var subDelay: Double = 0            // manual subtitle sync, seconds
    @State private var audioDelay: Double = 0          // manual audio sync, seconds
    @AppStorage(SubtitleStyle.Key.size) private var subSize = SubtitleStyle.defaultSize
    @AppStorage(SubtitleStyle.Key.color) private var subColor = SubtitleStyle.defaultColor
    @AppStorage(SubtitleStyle.Key.background) private var subBackground = SubtitleStyle.defaultBackground
    @State private var optionRow = 0                   // highlighted row in the options panel
    // The open panel's rows, computed ONCE per open/refresh. The rows used to be a
    // computed property read by the panel body, which re-rendered ~4x a second with
    // the clock; for Sources that meant re-ranking a thousand-plus streams on the
    // main thread per frame, freezing the whole player (the "remote stopped
    // responding / sources came up a minute later" reports).
    @State private var panelRows: [OptionRow] = []
    @State private var loadFailed = false              // playback couldn't start
    @State private var loadErrorMsg = ""
    @State private var hasStartedPlaying = false
    @State private var loadTimeout: Task<Void, Never>?
    @State private var autoRetryCount = 0              // bounded auto-recovery attempts before the error overlay
    @State private var reconnecting = false            // showing the "Reconnecting…" auto-retry state
    @State private var autoRetryTask: Task<Void, Never>?
    private let maxAutoRetries = 2                     // transient source hiccups recover; a dead link still falls through fast
    private let autoRetryBackoff = 1.2                 // seconds between auto-retries
    @State private var skipSegments: [SkipSegment] = []   // resolved skip spans (chapters + crowd timestamps)
    @State private var apiSkipCandidates: [SegmentCandidate] = []   // crowd-sourced spans for the current title
    @State private var skipFetchKey = ""                   // imdb:S:E the crowd spans belong to
    @State private var skipFetchTask: Task<Void, Never>?
    // Current episode (changes when switching via Next/Prev/Episodes or auto-advance). Seeded from
    // the passed url/title/meta in onAppear so the first load is unchanged.
    @State private var curURL: URL?
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
    @State private var torrentStatus: String?           // live warm-up line ("Connecting to peers · 12 connected")
    @State private var torrentWarmupsUsed = 0           // bounded warm-up rounds before the error overlay
    @State private var playSpeed = 1.0                  // mpv playback speed (sticky for the session)
    @State private var showStats = false                // live playback info overlay
    @State private var statsRows: [(String, String)] = []
    @State private var showStreamQR = false             // QR overlay sharing the playing link to a phone

    /// Which on-screen control is currently highlighted (driven by remote left/right, not SwiftUI focus).
    private enum Control: Hashable { case close, scrub, restart, back, play, fwd, audio, subs, aspect, playback, prev, next, episodes, sources }
    private enum PanelKind { case audio, audioSettings, subtitles, subtitleSettings, aspect, playback, episodes, sources }
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

            MPVMetalPlayerView(coordinator: coordinator)
                .play(url)
                .onPropertyChange { _, name, data in
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
                                hasStartedPlaying = true; loadTimeout?.cancel(); loadFailed = false
                                autoRetryCount = 0; reconnecting = false; autoRetryTask?.cancel()   // playback started: clear auto-recovery
                                if let m = curMeta, let u = curURL {   // remember the working link for direct resume
                                    LastStreamStore.record(libraryId: m.libraryId, entry: .init(
                                        videoId: m.videoId, url: u.absoluteString, title: curTitle,
                                        season: m.season, episode: m.episode, name: m.name,
                                        poster: m.poster, type: m.type, qualityText: curHint,
                                        torrent: curIsTorrent, savedAt: Date()),
                                        profileID: ProfileStore.shared.activeID)
                                }
                            }
                            currentTime = d
                            if lastSaved < 0 || abs(d - lastSaved) >= 20 {   // persist ~every 20s
                                lastSaved = d
                                saveProgress(at: d)
                                core.reportProgress(timeSeconds: d, durationSeconds: duration)   // live -> engine
                            }
                            if !markedWatched, duration > 0, d / duration >= 0.9, let m = curMeta {
                                markedWatched = true            // ~90% in → flip the watched marker live
                                core.markPlaybackWatched(m)
                            }
                            if duration > 0, d / duration >= 0.5 { preloadNextIfNeeded() }   // halfway → ready the next episode
                            if duration > 0, duration - d <= 100 { warmNextIfReady() }       // near the end → wake the provider
                        }
                    case MPVProperty.videoParamsSigPeak:
                        if let p = data as? Double { isHDR = p > 1.0 }
                    case MPVProperty.duration:
                        if let d = data as? Double { duration = d; maybeResume(); refreshSkipSegments(); fetchSkipTimestamps() }
                    case MPVProperty.trackList:
                        refreshTracks()
                        let s = coordinator.player?.mediaSummary()
                        videoHeight = s?.height ?? 0; audioCodec = s?.audioCodec ?? ""
                        if !appliedAutoTracks, !(audioTracks.isEmpty && subtitleTracks.isEmpty) {
                            appliedAutoTracks = true
                            autoSelectTracks()
                        }
                    case MPVProperty.endFileError:
                        loadTimeout?.cancel()
                        if !hasStartedPlaying { handleLoadFailure((data as? String) ?? "") }
                    case MPVProperty.endFileEof:
                        if !markedWatched, let m = curMeta { markedWatched = true; core.markPlaybackWatched(m) }
                        autoAdvance()                                // episode finished → play next, else exit
                    default: break
                    }
                }
                .ignoresSafeArea()

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
                        Text("Reconnecting…  (\(autoRetryCount)/\(maxAutoRetries))")
                            .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showInfo && !showOptions && !loadFailed { controlBar }
            if showOptions { optionsPanel }
            if loadFailed { loadErrorOverlay }
            if controlsHidden, let seg = currentSkip { skipPill(seg) }
            if showStats, !loadFailed { statsOverlay }
            if showStreamQR, let link = shareLink {
                StreamLinkQRView(title: isTorrentPlayback ? "Magnet link" : "Stream link", link: link)
            }
        }
        .onAppear {
            if curURL == nil { curURL = url; curTitle = title; curMeta = meta; curIsTorrent = torrent }   // seed from initial
            if curHint == nil { curHint = sourceHint }
            if curBinge == nil { curBinge = bingeGroup }
            startStallWatchdog()
            if episodes.isEmpty, let m = curMeta, loadedEpisodes.isEmpty {
                // Direct resume launches with no meta loaded: fetch it behind playback
                // so the sources panel shows THIS title (not whatever detail page was
                // open last), and series get their episode list for Next/auto-advance.
                Task {
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
                    Task { resumeSeconds = await account.resumeOffset(for: m); maybeResume() }
                }
            } else {
                resumeSeconds = 0   // selftest / no library context, nothing to resume
            }
        }
        .onDisappear {
            hideTask?.cancel(); loadTimeout?.cancel(); autoRetryTask?.cancel(); skipFetchTask?.cancel(); stallWatchdog?.cancel()
            saveProgress(at: currentTime)
            core.reportProgress(timeSeconds: currentTime, durationSeconds: duration)   // flush final position to the engine
            UIApplication.shared.isIdleTimerDisabled = false   // let the screensaver resume once the player closes
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
            case .menu: saveProgress(at: currentTime); onClose()
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
            default: break
            }
            return
        }
        if controlsHidden {
            switch type {
            case .menu: saveProgress(at: currentTime); onClose()
            case .playPause: toggle()
            case .select:
                if let seg = currentSkip { skipTo(seg) } else { showControls() }   // pill up → skip, else reveal
            default: showControls()                       // any swipe reveals the bar
            }
            return
        }
        // Control bar is shown: 2D navigation. Up/down moves between rows (close ↔ scrubber ↔ buttons);
        // left/right seeks on the scrubber or moves within the button row.
        switch type {
        case .menu:
            if scrubbing { cancelScrub() } else { saveProgress(at: currentTime); onClose() }
        case .playPause: toggle()
        case .select: activate(selected)
        case .leftArrow: horizontal(-1)
        case .rightArrow: horizontal(1)
        case .upArrow: vertical(-1)
        case .downArrow: vertical(1)
        default: break
        }
    }

    /// The bottom transport row in remote left/right order. `.close` (top bar) and `.scrub` (the seek
    /// bar) are separate rows above this one; up/down moves between the three.
    private var buttonRow: [Control] {
        var c: [Control] = [.restart, .back]
        if allEpisodes.count > 1 && hasPrevEpisode { c.append(.prev) }
        c.append(.play)
        if allEpisodes.count > 1 && hasNextEpisode { c.append(.next) }
        c.append(.fwd)
        if !audioTracks.isEmpty { c.append(.audio) }
        c.append(.subs)
        c.append(.aspect)
        c.append(.playback)
        if hasAlternateSources { c.append(.sources) }   // was drawn but missing here → unreachable by remote
        if allEpisodes.count > 1 { c.append(.episodes) }
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
        case .close:   saveProgress(at: currentTime); onClose()
        case .scrub:   scrubbing ? commitScrub() : toggle()
        case .restart: restart()
        case .back:    seek(-10)
        case .fwd:     seek(10)
        case .play:    toggle()
        case .prev:    playPrevious()
        case .next:    playNext()
        case .audio:    openPanel(.audio)
        case .subs:     openPanel(.subtitles)
        case .aspect:   openPanel(.aspect)
        case .playback: openPanel(.playback)
        case .episodes: openPanel(.episodes)
        case .sources:  openPanel(.sources)
        }
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
                statsRows = coordinator.player?.playbackStats() ?? []
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Control bar

    /// Resolution / HDR / audio summary under the title, read live from mpv.
    private var metadataLine: String {
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
                        Text(curTitle).font(Theme.Typography.sectionTitle)
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
                HStack(spacing: Theme.Space.md) {
                    Text(timeString(scrubbing ? scrubTarget : currentTime)).font(.callout.monospacedDigit())
                        .foregroundStyle(scrubbing ? Theme.Palette.accent : Theme.Palette.textPrimary)
                    scrubber
                    Text(timeString(duration)).font(.callout.monospacedDigit())
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                ZStack {
                    HStack(spacing: Theme.Space.md) {
                        ctrlButton(.restart, "arrow.counterclockwise")
                        ctrlButton(.back, "gobackward.10")
                        if allEpisodes.count > 1 && hasPrevEpisode { ctrlButton(.prev, "backward.end.fill") }
                        ctrlButton(.play, isPaused ? "play.fill" : "pause.fill", big: true)
                        if allEpisodes.count > 1 && hasNextEpisode { ctrlButton(.next, "forward.end.fill") }
                        ctrlButton(.fwd, "goforward.10")
                    }
                    HStack(spacing: Theme.Space.md) {
                        if !audioTracks.isEmpty { ctrlButton(.audio, "waveform") }
                        ctrlButton(.subs, "captions.bubble")
                        ctrlButton(.aspect, "aspectratio")
                        ctrlButton(.playback, "speedometer")
                        if hasAlternateSources { ctrlButton(.sources, "rectangle.2.swap") }
                        if allEpisodes.count > 1 { ctrlButton(.episodes, "list.bullet") }
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
                Capsule().fill(Theme.Palette.textPrimary.opacity(0.22)).frame(height: barH)
                Capsule().fill(Theme.Palette.accent).frame(width: max(0, w * frac), height: barH)
                Circle().fill(Theme.Palette.accent).frame(width: knob, height: knob)
                    .overlay(Circle().stroke(Theme.Palette.canvas, lineWidth: focused ? 3 : 0))
                    .shadow(color: Theme.Palette.accent.opacity(0.6), radius: focused ? 10 : 6)
                    .offset(x: max(0, w * frac - knob / 2))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.15), value: focused)
            .animation(.easeOut(duration: 0.12), value: frac)
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
            .background(Circle().fill(sel ? Theme.Palette.accent : Theme.Palette.textPrimary.opacity(0.12)))
            .scaleEffect(sel ? 1.12 : 1.0)
            .animation(.easeOut(duration: 0.18), value: sel)
    }

    // MARK: - Options panel (audio / subtitles / episodes), driven by optionRow

    private struct OptionRow: Identifiable {
        let id = UUID()
        let label: String
        var detail: String = ""        // right-aligned secondary text (e.g. current value)
        var isSelected: Bool = false
        var isHeader: Bool = false     // section header, not focusable, skipped in navigation
        var action: () -> Void = {}
    }

    /// Rows for the currently-open panel only, never mixed. Tracks are grouped by language; a "Settings"
    /// row drills into a dedicated sub-panel (sync / size / colour for subtitles, sync for audio).
    private var optionRows: [OptionRow] {
        switch panelKind {
        case .audio:
            var rows = groupedTrackRows(audioTracks) { coordinator.player?.setAudioTrack($0); refreshTracksSoon() }
            rows.append(OptionRow(label: "Audio Settings", detail: "›") { openPanel(.audioSettings) })
            return rows
        case .audioSettings:
            let now = String(format: "%+.1fs", audioDelay)
            var rows = [OptionRow(label: "Sync", isHeader: true),
                        OptionRow(label: "Earlier  −0.1s", detail: now) { adjustAudioDelay(-0.1) },
                        OptionRow(label: "Later  +0.1s", detail: now) { adjustAudioDelay(0.1) }]
            if audioDelay != 0 { rows.append(OptionRow(label: "Reset") { adjustAudioDelay(-audioDelay) }) }
            return rows
        case .subtitles:
            var rows = [OptionRow(label: "Off", isSelected: subtitleTracks.allSatisfy { !$0.selected }) {
                coordinator.player?.setSubtitleTrack(-1); refreshTracksSoon()
            }]
            rows += groupedTrackRows(subtitleTracks) { coordinator.player?.setSubtitleTrack($0); refreshTracksSoon() }
            rows.append(OptionRow(label: "Subtitle Settings", detail: "›") { openPanel(.subtitleSettings) })
            return rows
        case .subtitleSettings:
            let now = String(format: "%+.1fs", subDelay)
            var rows = [OptionRow(label: "Sync", isHeader: true),
                        OptionRow(label: "Earlier  −0.1s", detail: now) { adjustSubDelay(-0.1) },
                        OptionRow(label: "Later  +0.1s", detail: now) { adjustSubDelay(0.1) }]
            if subDelay != 0 { rows.append(OptionRow(label: "Reset") { adjustSubDelay(-subDelay) }) }
            rows.append(OptionRow(label: "Size", isHeader: true))
            for s in SubtitleStyle.sizes { rows.append(OptionRow(label: s.label, isSelected: subSize == s.id) { setSubtitleSize(s.id) }) }
            rows.append(OptionRow(label: "Colour", isHeader: true))
            for c in SubtitleStyle.colors { rows.append(OptionRow(label: c.label, isSelected: subColor == c.id) { setSubtitleColor(c.id) }) }
            rows.append(OptionRow(label: "Background", isHeader: true))
            for b in SubtitleStyle.backgrounds { rows.append(OptionRow(label: b.label, isSelected: subBackground == b.id) { setSubtitleBackground(b.id) }) }
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
        case .episodes:
            return allEpisodes.map { ep in
                OptionRow(label: "E\(ep.episodeNumber)  ·  \(ep.episodeTitle)", isSelected: ep.id == curMeta?.videoId) {
                    play(episode: ep)
                }
            }
        case .sources:
            return sourceRows()
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
        let c = code.lowercased()
        if c.isEmpty || c == "und" { return "Unknown" }
        return Locale.current.localizedString(forLanguageCode: c)?.capitalized ?? code.uppercased()
    }

    // MARK: - Source switching (swap to another loaded source without leaving the player)

    /// True when more than one playable source is loaded for the current title / episode.
    private var hasAlternateSources: Bool {
        core.streamGroups().reduce(0) { $0 + $1.streams.filter { $0.playableURL != nil }.count } > 1
    }

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

    /// Switch the playing source in place: reload the picked stream's URL and resume at the current
    /// position (via `resumeSeconds`), so a buffering or low-quality source can be swapped without
    /// leaving the player. Resets the auto-recovery budget for the fresh source.
    private func switchStream(to stream: CoreStream) {
        guard let newURL = stream.playableURL, newURL != curURL else { closePanel(); return }
        closePanel()
        curURL = newURL
        curIsTorrent = stream.isTorrent
        curBinge = stream.behaviorHints?.bingeGroup
        torrentWarmupsUsed = 0; torrentStatus = nil; stallRecoveries = 0
        prepareTorrent(stream)   // mid-playback switches never announced the torrent before
        resumeSeconds = currentTime
        appliedResume = false
        buffering = true; hasStartedPlaying = false; appliedAutoTracks = false; loadErrorMsg = ""
        autoRetryCount = 0; reconnecting = false; autoRetryTask?.cancel()
        coordinator.player?.loadFile(newURL)
        startLoadTimeout()
    }

    /// Nudge subtitle sync by `delta` seconds (rounded to 0.1); keeps the panel open to repeat.
    private func adjustSubDelay(_ delta: Double) {
        subDelay = ((subDelay + delta) * 10).rounded() / 10
        coordinator.player?.setSubDelay(subDelay)
    }
    private func adjustAudioDelay(_ delta: Double) {
        audioDelay = ((audioDelay + delta) * 10).rounded() / 10
        coordinator.player?.setAudioDelay(audioDelay)
    }
    private func setSubtitleSize(_ id: String) { subSize = id; coordinator.player?.applySubtitleStyle() }
    private func setSubtitleColor(_ id: String) { subColor = id; coordinator.player?.applySubtitleStyle() }
    private func setSubtitleBackground(_ id: String) { subBackground = id; coordinator.player?.applySubtitleStyle() }

    private var panelTitle: String {
        switch panelKind {
        case .audio:            return "Audio"
        case .audioSettings:    return "Audio Settings"
        case .subtitles:        return "Subtitles"
        case .subtitleSettings: return "Subtitle Settings"
        case .aspect:           return "Aspect Ratio"
        case .playback:         return "Playback"
        case .episodes:         return "Episodes"
        case .sources:          return "Sources"
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
            // Refresh the cached rows once a second while those panels are up:
            // live arrival without per-frame re-ranking.
            while showOptions, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard showOptions, panelKind == .sources || panelKind == .episodes else { continue }
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

    private func openPanel(_ kind: PanelKind) {
        panelKind = kind
        refreshTracks()
        hideTask?.cancel()
        panelRows = optionRows
        optionRow = panelRows.firstIndex { $0.isSelected } ?? panelRows.firstIndex { !$0.isHeader } ?? 0
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
        if let s = pick.subtitle { coordinator.player?.setSubtitleTrack(s) }   // -1 = off
        refreshTracksSoon()
    }

    // MARK: - Load failure

    private var loadErrorOverlay: some View {
        ZStack {
            Theme.Palette.canvas.opacity(0.94).ignoresSafeArea()
            VStack(spacing: Theme.Space.md) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 60)).foregroundStyle(Theme.Palette.danger)
                Text("This source didn't load")
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
            DiagnosticsLog.log("player", "stall recovery exhausted, showing error overlay")
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
        coordinator.player?.loadFile(curURL ?? url)
    }

    private func startLoadTimeout() {
        loadTimeout?.cancel()
        loadTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !hasStartedPlaying else { return }
            if isTorrentPlayback {
                warmUpTorrent()
                return
            }
            if loadErrorMsg.isEmpty { loadErrorMsg = "Timed out, the source never started." }
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
            if loadErrorMsg.isEmpty { loadErrorMsg = "The torrent never started sending data. Try another source." }
            reconnecting = false; torrentStatus = nil
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
        guard autoRetryCount < maxAutoRetries else {
            reconnecting = false
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
        if resetAutoRetries { autoRetryCount = 0; reconnecting = false }
        autoRetryTask?.cancel()
        withAnimation { loadFailed = false }
        buffering = true; hasStartedPlaying = false; appliedResume = false; appliedAutoTracks = false; loadErrorMsg = ""
        coordinator.player?.loadFile(curURL ?? url)
        startLoadTimeout()
    }

    // MARK: - Skip intro / outro (chapter-derived; AniSkip crowd-sourced timings can feed the same model later)

    /// The skip segment the playhead is currently inside, if any. Gated on `hasStartedPlaying` so a stale
    /// segment from the previous file never flashes during a load.
    private var currentSkip: SkipSegment? {
        guard hasStartedPlaying else { return nil }
        return skipSegments.first { currentTime >= $0.start && currentTime < $0.end }
    }

    /// Re-resolve skip spans from every available layer (named chapters + crowd timestamps), once the
    /// file's duration is known. The resolver's sanity guards keep any one bad span from mis-skipping.
    private func refreshSkipSegments() {
        let chapterCandidates = SkipSegments.chapterCandidates(chapters: coordinator.player?.chapters() ?? [],
                                                               duration: duration)
        skipSegments = SegmentResolver.resolve(chapterCandidates + apiSkipCandidates, duration: duration)
    }

    /// Pull crowd-sourced intro/credits spans for the current title (disk-cached, non-blocking): the
    /// pill simply appears once the result lands, normally well before the intro is reached.
    private func fetchSkipTimestamps() {
        guard let m = curMeta else { plog.info("skip: no curMeta, not fetching"); return }
        let key = "\(m.libraryId):\(m.season ?? 0):\(m.episode ?? 0)"
        if key != skipFetchKey { apiSkipCandidates = [] }   // drop spans from the previous episode
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

    // MARK: - Episode navigation (series only; `episodes` is the season's ordered list)

    private var allEpisodes: [CoreVideo] { episodes.isEmpty ? loadedEpisodes : episodes }

    private var episodeIndex: Int? { allEpisodes.firstIndex { $0.id == curMeta?.videoId } }
    private var hasNextEpisode: Bool { episodeIndex.map { $0 + 1 < allEpisodes.count } ?? false }
    private var hasPrevEpisode: Bool { (episodeIndex ?? 0) > 0 }

    private func playNext() { if let i = episodeIndex, i + 1 < allEpisodes.count { play(episode: allEpisodes[i + 1]) } }
    private func playPrevious() { if let i = episodeIndex, i > 0 { play(episode: allEpisodes[i - 1]) } }

    /// Auto-advance when an episode ends: next episode if there is one, otherwise leave the player.
    private func autoAdvance() {
        if hasNextEpisode { playNext(); return }
        // Finished (a movie, or the last episode): record the final position, then rewind the title out of
        // Continue Watching. The engine keeps any item with time_offset > 0 in the rail, so without this a
        // finished title lingers at its end position forever.
        saveProgress(at: currentTime)
        if let m = curMeta { core.finishedWatching(libraryId: m.libraryId) }
        onClose()
    }

    /// Switch to another episode in place: flush progress, resolve a stream through the ENGINE (same path
    /// as launch), then reload mpv. If the next episode was preloaded in the background, it plays its
    /// already-ranked best source instantly with no resolution wait.
    private func play(episode v: CoreVideo) {
        guard let m = curMeta else { return }
        saveProgress(at: currentTime)
        withAnimation { showOptions = false }
        buffering = true; hasStartedPlaying = false; appliedResume = false
        loadFailed = false; currentTime = 0; duration = 0; lastSaved = -1; resumeSeconds = nil; appliedAutoTracks = false
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
            torrentWarmupsUsed = 0; torrentStatus = nil
            stallRecoveries = 0
            plog.info("episode switch: playing preloaded best source")
            prepareTorrent(pre.stream)
            curURL = u
            Task {
                core.loadMeta(type: "series", id: m.libraryId, streamType: "series", streamId: v.id)
                resumeSeconds = await account.resumeOffset(for: newMeta)
                coordinator.player?.loadFile(u)
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

        Task {
            core.loadMeta(type: "series", id: m.libraryId, streamType: "series", streamId: v.id)
            // Wait for THIS episode's streams (matched by id), then take the RANKED best across
            // add-ons: either every add-on has answered, or the first playable landed a few seconds
            // ago and we stop waiting for stragglers.
            var firstPlayableAt: Date?
            for _ in 0..<100 {                                          // ~10s
                let groups = core.streamGroups(forStreamId: v.id)
                let progress = core.streamLoadProgress(forStreamId: v.id)
                let hasPlayable = groups.contains { $0.streams.contains { $0.playableURL != nil } }
                if hasPlayable, firstPlayableAt == nil { firstPlayableAt = Date() }
                let settled = progress.total > 0 && progress.loaded == progress.total
                let waitedEnough = firstPlayableAt.map { Date().timeIntervalSince($0) > 4 } ?? false
                if settled || waitedEnough,
                   let s = StreamRanking.best(groups, continuity: curHint, binge: curBinge), let u = s.playableURL {
                    DiagnosticsLog.log("binge", "auto-next FALLBACK: wanted binge=\(curBinge ?? "nil") got=\(s.behaviorHints?.bingeGroup ?? "nil") name=\(s.name?.prefix(60) ?? "")")
                    curBinge = s.behaviorHints?.bingeGroup
                    curHint = StreamRanking.signature(s)
                    core.loadEnginePlayer(for: s)
                    prepareTorrent(s)                                  // no-op for direct / debrid URLs
                    curURL = u
                    resumeSeconds = await account.resumeOffset(for: newMeta)
                    coordinator.player?.loadFile(u)
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
            DiagnosticsLog.log("binge", "preload next ep: want binge=\(curBinge ?? "nil"), \(withBinge) of \(groups.flatMap { $0.streams }.count) streams carry a bingeGroup")
            if let best = StreamRanking.best(groups, continuity: curHint, binge: curBinge) {
                preloaded = PreloadedEpisode(episodeID: next.id, stream: best, signature: StreamRanking.signature(best),
                                             bingeGroup: best.behaviorHints?.bingeGroup)
                plog.info("preload ready: \(StreamRanking.qualityLabel(best), privacy: .public) for \(next.id, privacy: .public)")
            } else {
                plog.info("preload found nothing for \(next.id, privacy: .public)")
            }
            preloadingID = nil
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
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - Playback helpers

    /// Seek to the saved position once BOTH the resume offset is fetched and the duration is known.
    private func maybeResume() {
        guard !appliedResume, duration > 0, let r = resumeSeconds else { return }
        appliedResume = true
        guard r > 5, r < duration - 10 else { return }   // ignore trivial / near-end positions
        coordinator.player?.seek(to: r)
        currentTime = r
        lastSaved = r
    }

    /// Persist the current position to the account library (no-op without a library context).
    private func saveProgress(at position: Double) {
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
            scrubStep = min(scrubStep * 1.6, 120)        // accelerate while moving fast / holding
        } else {
            scrubStep = 10                               // paused between presses → back to fine steps
        }
        lastScrubAt = now
        scrubTarget = min(duration, max(0, scrubTarget + Double(dir) * scrubStep))
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
        flashControls()
    }
    private func commitScrubIfNeeded() { if scrubbing { commitScrub() } }
    /// Discard the in-progress scrub preview and keep playing where we are (Menu while scrubbing).
    private func cancelScrub() { scrubCommit?.cancel(); scrubbing = false; flashControls() }

    /// Reveal the bar from a hidden state, selecting Play, and restart the auto-hide timer.
    private func showControls() {
        withAnimation { showInfo = true }
        if controlsHidden || selected == .close { selected = .play }
        scheduleHide()
    }
    /// Keep the bar visible and reset the auto-hide timer, without changing the selection.
    private func flashControls() {
        withAnimation { showInfo = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            // A cancelled sleep still falls through here (try? swallows CancellationError), so check
            // explicitly. Every re-show/navigation cancels the prior task; without this guard that
            // cancelled task would immediately run `showInfo = false` and the bar would vanish on the
            // very next press.
            guard !Task.isCancelled, !showOptions else { return }
            withAnimation { showInfo = false }
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

        @objc private func handleSurfaceTouch(_ g: UIPanGestureRecognizer) {
            if g.state == .began { onSwipe?() }
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
