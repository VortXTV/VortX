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
    var episodes: [Video] = []             // series' ordered episodes (empty for movies) → Next/Prev/list

    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @State private var markedWatched = false   // mark the engine watched once, near end of playback
    @EnvironmentObject private var presenter: PlayerPresenter   // root overlay: clear request to dismiss
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
    @State private var optionRow = 0                   // highlighted row in the options panel
    @State private var loadFailed = false              // playback couldn't start
    @State private var loadErrorMsg = ""
    @State private var hasStartedPlaying = false
    @State private var loadTimeout: Task<Void, Never>?
    // Current episode (changes when switching via Next/Prev/Episodes or auto-advance). Seeded from
    // the passed url/title/meta in onAppear so the first load is unchanged.
    @State private var curURL: URL?
    @State private var curTitle: String = ""
    @State private var curMeta: PlaybackMeta?

    /// Which on-screen control is currently highlighted (driven by remote left/right, not SwiftUI focus).
    private enum Control: Hashable { case close, back, play, fwd, audio, subs, prev, next, episodes }
    @State private var selected: Control = .play
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

            // UIKit owns ALL remote input (reliable inside the full-screen cover, unlike SwiftUI focus).
            RemoteCatcher { handlePress($0) }

            if buffering && !loadFailed {
                ProgressView().controlSize(.large).tint(Theme.Palette.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showInfo && !showOptions && !loadFailed { controlBar }
            if showOptions { optionsPanel }
            if loadFailed { loadErrorOverlay }
        }
        .onAppear {
            if curURL == nil { curURL = url; curTitle = title; curMeta = meta }   // seed from initial
            showInfo = true; selected = .play; scheduleHide(); startLoadTimeout()
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

    // MARK: - Remote handling (all input arrives here from the UIKit catcher)

    private func handlePress(_ type: UIPress.PressType) {
        if loadFailed {
            switch type {
            case .menu: saveProgress(at: currentTime); presenter.request = nil
            case .select, .playPause: retryLoad()
            default: break
            }
            return
        }
        if showOptions {
            switch type {
            case .menu: closePanel()
            case .upArrow: moveOption(-1)
            case .downArrow: moveOption(1)
            case .select: activateOption()
            default: break
            }
            return
        }
        if controlsHidden {
            switch type {
            case .menu: saveProgress(at: currentTime); presenter.request = nil
            case .playPause: toggle()
            default: showControls()                       // any swipe / select reveals the bar
            }
            return
        }
        // Control bar is shown: navigate it.
        switch type {
        case .menu: saveProgress(at: currentTime); presenter.request = nil
        case .playPause: toggle()
        case .select: activate(selected)
        case .leftArrow: moveSelected(-1)
        case .rightArrow: moveSelected(1)
        case .upArrow, .downArrow: flashControls()        // keep the bar up
        default: break
        }
    }

    /// Controls in remote left/right order (close is leftmost, then transport, then audio/subs/episodes).
    private var visibleControls: [Control] {
        var c: [Control] = [.close, .back]
        if episodes.count > 1 && hasPrevEpisode { c.append(.prev) }
        c.append(.play)
        if episodes.count > 1 && hasNextEpisode { c.append(.next) }
        c.append(.fwd)
        if !audioTracks.isEmpty { c.append(.audio) }
        c.append(.subs)
        if episodes.count > 1 { c.append(.episodes) }
        return c
    }

    private func moveSelected(_ d: Int) {
        let v = visibleControls
        let i = v.firstIndex(of: selected) ?? 0
        selected = v[max(0, min(v.count - 1, i + d))]
        flashControls()
    }

    private func activate(_ c: Control) {
        switch c {
        case .close: saveProgress(at: currentTime); presenter.request = nil
        case .back:  seek(-10)
        case .fwd:   seek(10)
        case .play:  toggle()
        case .prev:  playPrevious()
        case .next:  playNext()
        case .audio, .subs, .episodes: openPanel()
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
                    Text(timeString(currentTime)).font(.callout.monospacedDigit())
                        .foregroundStyle(Theme.Palette.textPrimary)
                    scrubber
                    Text(timeString(duration)).font(.callout.monospacedDigit())
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                ZStack {
                    HStack(spacing: Theme.Space.md) {
                        ctrlButton(.back, "gobackward.10")
                        if episodes.count > 1 && hasPrevEpisode { ctrlButton(.prev, "backward.end.fill") }
                        ctrlButton(.play, isPaused ? "play.fill" : "pause.fill", big: true)
                        if episodes.count > 1 && hasNextEpisode { ctrlButton(.next, "forward.end.fill") }
                        ctrlButton(.fwd, "goforward.10")
                    }
                    HStack(spacing: Theme.Space.md) {
                        if !audioTracks.isEmpty { ctrlButton(.audio, "waveform") }
                        ctrlButton(.subs, "captions.bubble")
                        if episodes.count > 1 { ctrlButton(.episodes, "list.bullet") }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 60).padding(.bottom, 50)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
        }
        .transition(.opacity)
    }

    /// Slim ember seek bar with a knob. Position display; seeking is via the ±10 controls.
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

    private struct OptionRow: Identifiable { let id = UUID(); let label: String; let isSelected: Bool; let action: () -> Void }

    private var optionRows: [OptionRow] {
        var rows: [OptionRow] = []
        for t in audioTracks {
            rows.append(OptionRow(label: "Audio  ·  " + t.label, isSelected: t.selected) {
                coordinator.player?.setAudioTrack(t.id); refreshTracksSoon()
            })
        }
        rows.append(OptionRow(label: "Subtitles  ·  Off", isSelected: subtitleTracks.allSatisfy { !$0.selected }) {
            coordinator.player?.setSubtitleTrack(-1); refreshTracksSoon()
        })
        for t in subtitleTracks {
            rows.append(OptionRow(label: "Subtitles  ·  " + t.label, isSelected: t.selected) {
                coordinator.player?.setSubtitleTrack(t.id); refreshTracksSoon()
            })
        }
        if episodes.count > 1 {
            for ep in episodes {
                rows.append(OptionRow(label: "E\(ep.episodeNumber)  ·  \(ep.episodeTitle)", isSelected: ep.id == curMeta?.videoId) {
                    play(episode: ep)
                })
            }
        }
        return rows
    }

    private var optionsPanel: some View {
        let rows = optionRows
        return HStack(spacing: 0) {
            Spacer()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            HStack {
                                Text(row.label).lineLimit(1)
                                    .foregroundStyle(i == optionRow ? Theme.Palette.canvas : Theme.Palette.textPrimary)
                                Spacer()
                                if row.isSelected {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(i == optionRow ? Theme.Palette.canvas : Theme.Palette.accent)
                                }
                            }
                            .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
                            .background(i == optionRow ? Theme.Palette.accent : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                            .id(i)
                        }
                    }
                    .padding(Theme.Space.lg)
                }
                .onChange(of: optionRow) { _ in withAnimation { proxy.scrollTo(optionRow, anchor: .center) } }
            }
            .frame(width: 760)
            .frame(maxHeight: .infinity)
            .background(Theme.Palette.surface1.opacity(0.98))
        }
        .ignoresSafeArea()
        .transition(.move(edge: .trailing))
    }

    private func moveOption(_ d: Int) {
        let count = optionRows.count
        guard count > 0 else { return }
        optionRow = max(0, min(count - 1, optionRow + d))
    }
    private func activateOption() {
        let rows = optionRows
        guard optionRow >= 0, optionRow < rows.count else { return }
        rows[optionRow].action()
    }

    private func openPanel() {
        refreshTracks()
        hideTask?.cancel()
        optionRow = optionRows.firstIndex { $0.isSelected } ?? 0
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
        if hasNextEpisode { playNext() } else { saveProgress(at: currentTime); presenter.request = nil }
    }

    /// Switch to another episode in place: flush progress, resolve a stream, then reload mpv.
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
        showInfo = true; selected = .play; flashControls()
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
            guard !showOptions else { return }
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
private struct RemoteCatcher: UIViewRepresentable {
    var onPress: (UIPress.PressType) -> Void

    func makeUIView(context: Context) -> CatchView {
        let v = CatchView(); v.onPress = onPress; return v
    }
    func updateUIView(_ uiView: CatchView, context: Context) { uiView.onPress = onPress }

    final class CatchView: UIView {
        var onPress: ((UIPress.PressType) -> Void)?
        override var canBecomeFocused: Bool { true }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { setNeedsFocusUpdate(); updateFocusIfNeeded() }
        }

        /// Trap focus: refuse to let the focus engine move focus AWAY from this view, so a directional
        /// press cannot walk focus off the player. The shell is also `.disabled` while playing (nothing
        /// else is focusable), so this is the lock on the door rather than a fight-the-engine re-grab.
        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            if context.previouslyFocusedItem === self && context.nextFocusedItem !== self {
                return false
            }
            return super.shouldUpdateFocus(in: context)
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                switch press.type {
                case .select, .menu, .playPause, .upArrow, .downArrow, .leftArrow, .rightArrow:
                    onPress?(press.type); handled = true
                default: break
                }
            }
            if !handled { super.pressesBegan(presses, with: event) }
        }
    }
}
