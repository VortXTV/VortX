import SwiftUI
import os

/// Full-screen libmpv player for tvOS with an on-screen, focusable control bar (Back / Play / Fwd /
/// Audio / Subtitles / Previous / Next / Episodes), navigate it with the remote like any other
/// player. When the bar is hidden, any remote input brings it back; Menu exits. Shares the MPVKit
/// core with the iOS app.
struct TVPlayerView: View {
    let url: URL
    let title: String
    var meta: PlaybackMeta? = nil          // when set, resume + record watch progress to the library
    var episodes: [Video] = []             // series' ordered episodes (empty for movies) → Next/Prev/list

    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @State private var markedWatched = false   // mark the engine watched once, near end of playback
    @Environment(\.dismiss) private var dismiss
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
    @State private var showOptions = false             // audio/subtitle/episode list panel
    @State private var loadFailed = false              // playback couldn't start
    @State private var loadErrorMsg = ""
    @State private var hasStartedPlaying = false
    @State private var loadTimeout: Task<Void, Never>?
    // Current episode (changes when switching via Next/Prev/Episodes or auto-advance). Seeded from
    // the passed url/title/meta in onAppear so the first load is unchanged.
    @State private var curURL: URL?
    @State private var curTitle: String = ""
    @State private var curMeta: PlaybackMeta?

    /// Which on-screen control (or the video surface) currently has remote focus.
    private enum Focus: Hashable { case player, close, back, play, fwd, audio, subs, prev, next, episodes }
    @FocusState private var focus: Focus?
    private let plog = Logger(subsystem: "com.stremiox.app", category: "tvplayer")

    /// True when no control bar / panel / error is up, so the full-screen catch button owns the remote.
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
                            if b { saveProgress(at: currentTime) }   // persist on pause
                        }
                    case MPVProperty.timePos:
                        if let d = data as? Double {
                            if d > 0, !hasStartedPlaying {            // playback actually began
                                hasStartedPlaying = true; loadTimeout?.cancel(); loadFailed = false
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
                        }
                    case MPVProperty.videoParamsSigPeak:
                        if let p = data as? Double { isHDR = p > 1.0 }
                    case MPVProperty.duration:
                        if let d = data as? Double { duration = d; maybeResume() }
                    case MPVProperty.trackList:
                        refreshTracks()
                        let s = coordinator.player?.mediaSummary()
                        videoHeight = s?.height ?? 0; audioCodec = s?.audioCodec ?? ""
                    case MPVProperty.endFileError:
                        loadTimeout?.cancel()
                        if !hasStartedPlaying { loadErrorMsg = (data as? String) ?? ""; withAnimation { loadFailed = true } }
                    case MPVProperty.endFileEof:
                        if !markedWatched, let m = curMeta { markedWatched = true; core.markPlaybackWatched(m) }
                        autoAdvance()                                // episode finished → play next, else exit
                    default: break
                    }
                }
                .ignoresSafeArea()

            if buffering && !loadFailed {
                ProgressView().controlSize(.large).tint(Theme.Palette.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // When the bar is hidden, a transparent focusable layer owns the remote: any swipe or Select
            // reveals the controls. A focusable Color (not a Button) avoids tvOS's button focus
            // highlight, which was washing the whole video white, while still catching remote input.
            if controlsHidden {
                Color.clear
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($focus, equals: .player)
                    .onMoveCommand { _ in showControls() }
                    .onTapGesture { showControls() }
            }
            if showInfo && !showOptions && !loadFailed { controlBar }
            if showOptions { optionsPanel }
            if loadFailed { loadErrorOverlay }
        }
        .defaultFocus($focus, .play)                      // seed focus into the cover (device-safe)
        .onPlayPauseCommand { toggle() }
        .onExitCommand {
            if showOptions { closePanel() }
            else { saveProgress(at: currentTime); dismiss() }
        }
        .onChange(of: focus) { _ in
            if showInfo { scheduleHide() }                // moving across the bar keeps it visible
        }
        .onAppear {
            if curURL == nil { curURL = url; curTitle = title; curMeta = meta }   // seed from initial
            showInfo = true; scheduleHide(); startLoadTimeout()
            DispatchQueue.main.async { focus = .play }    // after the cover's focus env is ready
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
            hideTask?.cancel(); loadTimeout?.cancel()
            saveProgress(at: currentTime)
            core.reportProgress(timeSeconds: currentTime, durationSeconds: duration)   // flush final position to the engine
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
            // Top chrome: back + title + live metadata
            HStack(alignment: .top, spacing: Theme.Space.lg) {
                ctrlButton(.close, "chevron.left") { saveProgress(at: currentTime); dismiss() }
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

            // Bottom: scrubber + centered transport with trailing audio/subs/episodes
            VStack(spacing: Theme.Space.lg) {
                HStack(spacing: Theme.Space.md) {
                    Text(timeString(currentTime)).font(.callout.monospacedDigit())
                        .foregroundStyle(Theme.Palette.textPrimary)
                    scrubber
                    Text(timeString(duration)).font(.callout.monospacedDigit())
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                ZStack {
                    HStack(spacing: Theme.Space.md) {
                        ctrlButton(.back, "gobackward.10") { seek(-10) }
                        if episodes.count > 1 && hasPrevEpisode { ctrlButton(.prev, "backward.end.fill") { playPrevious() } }
                        ctrlButton(.play, isPaused ? "play.fill" : "pause.fill", big: true) { toggle() }
                        if episodes.count > 1 && hasNextEpisode { ctrlButton(.next, "forward.end.fill") { playNext() } }
                        ctrlButton(.fwd, "goforward.10") { seek(10) }
                    }
                    HStack(spacing: Theme.Space.md) {
                        if !audioTracks.isEmpty { ctrlButton(.audio, "waveform") { openPanel() } }
                        ctrlButton(.subs, "captions.bubble") { openPanel() }
                        if episodes.count > 1 { ctrlButton(.episodes, "list.bullet") { openPanel() } }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 60).padding(.bottom, 50)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
        }
        .transition(.opacity)
    }

    /// Slim ember seek bar with a knob. Position display; seeking is via the ±10 controls / remote.
    private var scrubber: some View {
        GeometryReader { geo in
            let frac = duration > 0 ? min(1, max(0, currentTime / duration)) : 0
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.textPrimary.opacity(0.22)).frame(height: 6)
                Capsule().fill(Theme.Palette.accent).frame(width: max(0, w * frac), height: 6)
                Circle().fill(Theme.Palette.accent).frame(width: 18, height: 18)
                    .shadow(color: Theme.Palette.accent.opacity(0.6), radius: 6)
                    .offset(x: max(0, w * frac - 9))
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 18)
    }

    /// Circular, focus-reactive control. Focused → ember fill + lift; the play button is larger.
    private func ctrlButton(_ f: Focus, _ icon: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        let focused = (focus == f)
        let d: CGFloat = big ? 92 : 64
        return Button { action(); flashControls() } label: {
            Image(systemName: icon)
                .font(.system(size: big ? 38 : 26, weight: .semibold))
                .foregroundStyle(focused ? Theme.Palette.canvas : Theme.Palette.textPrimary)
                .frame(width: d, height: d)
                .background(Circle().fill(focused ? Theme.Palette.accent : Theme.Palette.textPrimary.opacity(0.12)))
                .scaleEffect(focused ? 1.12 : 1.0)
        }
        .buttonStyle(.plain)
        .focused($focus, equals: f)
        .animation(.easeOut(duration: 0.18), value: focused)
    }

    // MARK: - Options panel (audio / subtitles / episodes)

    private var optionsPanel: some View {
        HStack(spacing: 0) {
            Spacer()
            List {
                if !audioTracks.isEmpty {
                    Section("Audio") {
                        ForEach(audioTracks) { t in
                            trackRow(t.label, selected: t.selected) {
                                coordinator.player?.setAudioTrack(t.id); refreshTracksSoon()
                            }
                        }
                    }
                }
                Section("Subtitles") {
                    trackRow("Off", selected: subtitleTracks.allSatisfy { !$0.selected }) {
                        coordinator.player?.setSubtitleTrack(-1); refreshTracksSoon()
                    }
                    ForEach(subtitleTracks) { t in
                        trackRow(t.label, selected: t.selected) {
                            coordinator.player?.setSubtitleTrack(t.id); refreshTracksSoon()
                        }
                    }
                    if subtitleTracks.isEmpty {
                        Text("No subtitle tracks in this stream").foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                if episodes.count > 1 {
                    Section("Episodes") {
                        ForEach(episodes) { ep in
                            trackRow("\(ep.episodeNumber). \(ep.episodeTitle)",
                                     selected: ep.id == curMeta?.videoId) { play(episode: ep) }
                        }
                    }
                }
            }
            .frame(width: 720)
            .frame(maxHeight: .infinity)
            .background(Theme.Palette.surface1.opacity(0.98))
        }
        .ignoresSafeArea()
        .transition(.move(edge: .trailing))
    }

    private func trackRow(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.Palette.accent) }
            }
        }
    }

    private func openPanel() {
        refreshTracks()
        hideTask?.cancel()
        withAnimation { showOptions = true }
    }
    private func closePanel() {
        withAnimation { showOptions = false }
        showInfo = true; focus = .play; scheduleHide()
    }

    private func refreshTracks() {
        audioTracks = coordinator.player?.tracks(ofType: "audio") ?? []
        subtitleTracks = coordinator.player?.tracks(ofType: "sub") ?? []
    }
    private func refreshTracksSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { refreshTracks() }
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
                Text("Menu = back to sources    ·    Play/Pause = retry")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary).padding(.top, Theme.Space.xs)
            }
            .padding(Theme.Space.screenEdge)
        }
        .transition(.opacity)
    }

    private func startLoadTimeout() {
        loadTimeout?.cancel()
        loadTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !hasStartedPlaying else { return }
            if loadErrorMsg.isEmpty { loadErrorMsg = "Timed out, the source never started." }
            withAnimation { loadFailed = true }
        }
    }

    private func retryLoad() {
        withAnimation { loadFailed = false }
        buffering = true; hasStartedPlaying = false; appliedResume = false; loadErrorMsg = ""
        coordinator.player?.loadFile(curURL ?? url)
        startLoadTimeout()
    }

    // MARK: - Episode navigation (series only; `episodes` is the season's ordered list)

    private var episodeIndex: Int? { episodes.firstIndex { $0.id == curMeta?.videoId } }
    private var hasNextEpisode: Bool { episodeIndex.map { $0 + 1 < episodes.count } ?? false }
    private var hasPrevEpisode: Bool { (episodeIndex ?? 0) > 0 }

    private func playNext() { if let i = episodeIndex, i + 1 < episodes.count { play(episode: episodes[i + 1]) } }
    private func playPrevious() { if let i = episodeIndex, i > 0 { play(episode: episodes[i - 1]) } }

    /// Auto-advance when an episode ends: next episode if there is one, otherwise leave the player.
    private func autoAdvance() {
        if hasNextEpisode { playNext() } else { saveProgress(at: currentTime); dismiss() }
    }

    /// Switch to another episode in place: flush progress, resolve a stream (same proven path as
    /// StreamList), then reload mpv. Falls back to the load-error overlay if nothing is playable.
    private func play(episode v: Video) {
        guard let m = curMeta else { return }
        saveProgress(at: currentTime)
        withAnimation { showOptions = false }
        buffering = true; hasStartedPlaying = false; appliedResume = false
        loadFailed = false; currentTime = 0; duration = 0; lastSaved = -1; resumeSeconds = nil
        let newMeta = PlaybackMeta(libraryId: m.libraryId, videoId: v.id, type: "series",
                                   name: m.name, poster: m.poster, season: v.season, episode: v.episode)
        curMeta = newMeta
        curTitle = "\(m.name) · S\(v.season ?? 0)E\(v.episodeNumber) · \(v.episodeTitle)"
        showInfo = true; focus = .play; flashControls()
        Task {
            var client = AddonClient(); client.streamSources = account.streamSources
            let streams = await client.streams(type: "series", videoId: v.id)
            guard let s = streams.first(where: { $0.isPlayable }), let u = StremioServer.resolveURL(for: s) else {
                loadErrorMsg = "No playable source found for this episode."
                withAnimation { loadFailed = true }
                return
            }
            StremioServer.prepare(s)                       // torrents: create on the local server
            curURL = u
            resumeSeconds = await account.resumeOffset(for: newMeta)
            coordinator.player?.loadFile(u)
            startLoadTimeout()
        }
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

    /// Reveal the bar from a hidden state and focus the Play button.
    private func showControls() {
        withAnimation { showInfo = true }
        if focus == .player || focus == nil { focus = .play }
        scheduleHide()
    }
    /// Keep the bar visible + reset the auto-hide timer, without moving focus (used by button taps).
    private func flashControls() {
        withAnimation { showInfo = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !showOptions else { return }
            withAnimation { showInfo = false }
            focus = .player                          // hand focus to the full-screen catch button
        }
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
