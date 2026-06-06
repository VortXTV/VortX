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
    private enum Focus: Hashable { case player, back, play, fwd, audio, subs, prev, next, episodes }
    @FocusState private var focus: Focus?
    private let plog = Logger(subsystem: "com.stremiox.app", category: "tvplayer")

    /// The video surface is focusable only when no controls/panel are up, so when the bar is shown
    /// the buttons take the remote, and when hidden any input on the surface reveals the bar.
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
                            }
                            if !markedWatched, duration > 0, d / duration >= 0.9, let m = curMeta {
                                markedWatched = true            // ~90% in → flip the watched marker live
                                core.markPlaybackWatched(m)
                            }
                        }
                    case MPVProperty.duration:
                        if let d = data as? Double { duration = d; maybeResume() }
                    case MPVProperty.trackList: refreshTracks()
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
                ProgressView().controlSize(.large).tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showInfo && !showOptions && !loadFailed { controlBar }
            if showOptions { optionsPanel }
            if loadFailed { loadErrorOverlay }
        }
        .focusable(controlsHidden || loadFailed)
        .focused($focus, equals: .player)
        .onMoveCommand { _ in showControls() }            // any direction (bar hidden) reveals the bar
        .onTapGesture { showControls() }                  // Select (bar hidden) reveals the bar
        .onPlayPauseCommand { toggle() }
        .onExitCommand {
            if showOptions { closePanel() }
            else { saveProgress(at: currentTime); dismiss() }
        }
        .onAppear {
            if curURL == nil { curURL = url; curTitle = title; curMeta = meta }   // seed from initial
            showInfo = true; focus = .play; scheduleHide(); startLoadTimeout()
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
        .onDisappear { hideTask?.cancel(); loadTimeout?.cancel(); saveProgress(at: currentTime) }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !curTitle.isEmpty { Text(curTitle).font(.title3.weight(.semibold)).lineLimit(1) }
            HStack(spacing: 14) {
                Text(timeString(currentTime)).font(.callout.monospacedDigit())
                ProgressView(value: duration > 0 ? min(1, currentTime / duration) : 0).tint(.cyan)
                Text(timeString(duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                barButton(.back, "gobackward.10", "−10s") { seek(-10) }
                barButton(.play, isPaused ? "play.fill" : "pause.fill", isPaused ? "Play" : "Pause") { toggle() }
                barButton(.fwd, "goforward.10", "+10s") { seek(10) }
                Spacer(minLength: 24)
                if !audioTracks.isEmpty { barButton(.audio, "waveform", "Audio") { openPanel() } }
                barButton(.subs, "captions.bubble", "Subtitles") { openPanel() }
                if episodes.count > 1 {
                    if hasPrevEpisode { barButton(.prev, "backward.end.fill", "Previous") { playPrevious() } }
                    if hasNextEpisode { barButton(.next, "forward.end.fill", "Next") { playNext() } }
                    barButton(.episodes, "list.bullet", "Episodes") { openPanel() }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        .transition(.opacity)
    }

    private func barButton(_ f: Focus, _ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button { action(); flashControls() } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 26, weight: .semibold))
                Text(label).font(.caption2)
            }
            .frame(width: 100, height: 80)
        }
        .buttonStyle(.card)
        .focused($focus, equals: f)
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
                        Text("No subtitle tracks in this stream").foregroundStyle(.secondary)
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
            .background(.ultraThinMaterial)
        }
        .ignoresSafeArea()
        .transition(.move(edge: .trailing))
    }

    private func trackRow(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.cyan) }
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
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 60)).foregroundStyle(.yellow)
                Text("This source didn't load").font(.title2.weight(.semibold))
                Text(loadErrorMsg.isEmpty
                     ? "It may be uncached on your debrid (still downloading), offline, or an unsupported link."
                     : "It may be uncached/offline/unsupported.  (\(loadErrorMsg))")
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 900)
                Text("Menu = back to sources    ·    Play/Pause = retry")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }
            .padding(60)
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
            try? await Task.sleep(for: .seconds(6))
            guard !showOptions else { return }
            withAnimation { showInfo = false }
            focus = .player                          // hand focus back to the (now focusable) surface
        }
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
