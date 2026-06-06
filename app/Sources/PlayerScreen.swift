import SwiftUI

/// Full-screen native libmpv player with controls (play/pause, seek, video size,
/// playback speed, audio/subtitle tracks via a custom selection sheet).
struct PlayerScreen: View {
    let url: URL
    let title: String
    var resumeSeconds: Double = 0                            // saved position to resume from
    var hasNext: Bool = false                               // show the Next Episode button
    var onProgress: (Double, Double) -> Void = { _, _ in }   // periodic forward progress (TimeChanged)
    var onSeek: (Double, Double) -> Void = { _, _ in }       // exact position on user-seek (Seek)
    var onNext: () -> Void = {}                             // advance to the next episode
    let onClose: () -> Void

    private enum Panel: Identifiable {
        case speed, subtitles, audio, video
        var id: Int { switch self { case .speed: 0; case .subtitles: 1; case .audio: 2; case .video: 3 } }
        var title: String {
            switch self {
            case .speed: "Playback Speed"; case .subtitles: "Subtitles"
            case .audio: "Audio"; case .video: "Video Size"
            }
        }
    }
    private struct Option { let label: String; let selected: Bool; let apply: () -> Void }

    private let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    // "original" (default) = whole frame at correct aspect (panscan=0), like actual Stremio; "zoom"
    // crops to fill (panscan=1); "stretch" distorts. The drawable-size fix keeps "original" uniform.
    private let sizeModes: [(raw: String, label: String)] = [
        ("original", "Original (Default)"), ("zoom", "Zoom (Fill)"), ("stretch", "Stretch")
    ]

    @StateObject private var coordinator = MPVMetalPlayerView.Coordinator()
    @AppStorage("stremiox.videoSize") private var videoSize = "original"   // whole frame, correct aspect
    @State private var appliedSize = false
    @State private var buffering = true
    @State private var currentTime = 0.0
    @State private var duration = 0.0
    @State private var lastReported = -1.0     // last whole-second progress pushed to stremio-core
    @State private var isPaused = false
    @State private var speed = 1.0
    @State private var audioTracks: [MPVTrack] = []
    @State private var subtitleTracks: [MPVTrack] = []
    @State private var controlsVisible = true
    @State private var scrubbing = false
    @State private var panel: Panel?
    @State private var forcedLandscape = false
    @State private var hideTask: Task<Void, Never>?
    @State private var showExternalChooser = false   // "Play in another app" sheet
    @State private var showShare = false             // system share sheet
    @State private var loadFailed = false            // playback couldn't start (dead/uncached link)
    @State private var loadErrorMsg = ""
    @State private var hasStartedPlaying = false
    @State private var loadTimeout: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MPVMetalPlayerView(coordinator: coordinator)
                .play(url)
                .onPropertyChange { _, name, data in
                    switch name {
                    case MPVProperty.pausedForCache: if let b = data as? Bool { buffering = b }
                    case MPVProperty.timePos:
                        if let d = data as? Double {
                            if d > 0, !hasStartedPlaying {      // playback actually began
                                hasStartedPlaying = true; loadTimeout?.cancel(); loadFailed = false
                            }
                            if !scrubbing {
                                currentTime = d
                                if duration > 0, d - lastReported >= 5 {   // push progress ~every 5s
                                    lastReported = d
                                    onProgress(d, duration)
                                }
                            }
                        }
                    case MPVProperty.duration:
                        if let d = data as? Double {
                            duration = d
                            if !appliedSize, d > 0 {                 // run once when the video loads
                                appliedSize = true
                                coordinator.player?.setVideoSize(videoSize)
                                if resumeSeconds > 5, resumeSeconds < d - 10 {   // resume where we left off
                                    coordinator.player?.seek(to: resumeSeconds)
                                    currentTime = resumeSeconds
                                    lastReported = resumeSeconds
                                }
                            }
                        }
                    case MPVProperty.pause: if let b = data as? Bool { isPaused = b }
                    case MPVProperty.trackList: refreshTracks()
                    case MPVProperty.endFileError:
                        loadTimeout?.cancel()
                        if !hasStartedPlaying {                  // only flag failures BEFORE playback
                            loadErrorMsg = (data as? String) ?? ""
                            withAnimation { loadFailed = true }
                        }
                    case MPVProperty.endFileEof:
                        if hasNext { onNext() } else { onClose() }   // episode ended → auto-play next / exit
                    default: break
                    }
                }
                .ignoresSafeArea()

            // Reliable tap-to-toggle: a transparent hit-test layer over the video. The UIKit
            // recognizer on the Metal view frequently missed taps (you had to tap many times);
            // a SwiftUI contentShape layer catches every tap. The controls sit above it, so their
            // buttons still work and a tap on empty space falls through here to toggle.
            Color.clear.contentShape(Rectangle()).onTapGesture { toggleControls() }.ignoresSafeArea()

            if buffering && !loadFailed { ProgressView().controlSize(.large).tint(.white) }

            if controlsVisible && !loadFailed { controls.transition(.opacity) }

            if let panel { selectionSheet(panel) }

            if loadFailed { loadErrorOverlay }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { scheduleHide(); startLoadTimeout() }
        .onDisappear { hideTask?.cancel(); loadTimeout?.cancel() }
        .confirmationDialog("Play in another app", isPresented: $showExternalChooser,
                            titleVisibility: .visible) {
            ForEach(ExternalPlayer.installed) { target in
                Button(target.name) {
                    // Handed off, stop local playback so the stream isn't decoded twice.
                    if ExternalPlayer.open(target, stream: url), !isPaused {
                        coordinator.player?.togglePause()
                    }
                }
            }
            Button("Share or open in…") { showShare = true }
            Button("Copy stream link") { UIPasteboard.general.url = url }
            Button("Cancel", role: .cancel) { scheduleHide() }
        } message: {
            Text(externalChooserMessage)
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: [url]) }
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

    // MARK: - Load failure handling

    private var loadErrorOverlay: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 46)).foregroundStyle(.yellow)
                Text("This source didn't load").font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text(loadErrorHint).font(.callout).foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center).frame(maxWidth: 480).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button { retryLoad() } label: { Label("Retry", systemImage: "arrow.clockwise").padding(6) }
                    Button { onClose() } label: { Label("Back to sources", systemImage: "chevron.left").padding(6) }
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).padding(.top, 6)
            }
            .padding(40)
        }
        .transition(.opacity)
    }

    private var loadErrorHint: String {
        let base = "It may be uncached on your debrid (still downloading), offline, or an unsupported link. Go back and pick a different source."
        return loadErrorMsg.isEmpty ? base : base + "\n\n(\(loadErrorMsg))"
    }

    /// Fail the screen if playback never starts (covers hard hangs that don't even emit an error).
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
        buffering = true; hasStartedPlaying = false; appliedSize = false; loadErrorMsg = ""
        coordinator.player?.loadFile(url)
        startLoadTimeout()
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    iconButton("chevron.down") {
                        if duration > 0 { onProgress(currentTime, duration) }   // final progress before exit
                        onClose()
                    }
                    if !title.isEmpty {
                        Text(title).font(.headline.weight(.semibold)).foregroundStyle(.white)
                            .lineLimit(1).shadow(radius: 3)
                    }
                    Spacer()
                    if hasNext {
                        iconButton("forward.end.fill") {
                            if duration > 0 { onProgress(currentTime, duration) }   // flush before advancing
                            onNext()
                        }
                    }
                    iconButton(forcedLandscape ? "arrow.down.right.and.arrow.up.left"
                                               : "arrow.up.left.and.arrow.down.right") {
                        forcedLandscape.toggle()
                        coordinator.player?.setOrientation(landscape: forcedLandscape)
                        scheduleHide()
                    }
                    iconButton("arrow.up.forward.app") {       // hand off to Infuse / VLC / Share
                        hideTask?.cancel()
                        showExternalChooser = true
                    }
                    iconButton("aspectratio") { open(.video) }
                }
                .padding(.horizontal).padding(.top, 8)

                Spacer()

                Button { coordinator.player?.togglePause(); scheduleHide() } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 50)).foregroundStyle(.white).shadow(radius: 8)
                        .frame(width: 100, height: 100)
                }

                Spacer()

                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        Text(timeString(currentTime)).font(.caption.monospacedDigit()).foregroundStyle(.white)
                        Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                            scrubbing = editing
                            if editing { hideTask?.cancel() }
                            else {
                                coordinator.player?.seek(to: currentTime)
                                if duration > 0 { onSeek(currentTime, duration); lastReported = currentTime }
                                scheduleHide()
                            }
                        }.tint(.white)
                        Text(timeString(duration)).font(.caption.monospacedDigit()).foregroundStyle(.white)
                    }

                    HStack(spacing: 0) {
                        controlButton("speedometer", speed == 1.0 ? "Speed" : speedLabel(speed)) { open(.speed) }
                        Spacer()
                        controlButton("captions.bubble", "Subtitles") { open(.subtitles) }
                        if audioTracks.count > 1 {
                            Spacer()
                            controlButton("waveform", "Audio") { open(.audio) }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal).padding(.bottom, 22)
            }
        }
    }

    private func selectionSheet(_ p: Panel) -> some View {
        let opts = options(for: p)
        return ZStack(alignment: .bottom) {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { close() }
            VStack(alignment: .leading, spacing: 0) {
                Text(p.title).font(.headline).foregroundStyle(.white)
                    .padding(.horizontal).padding(.vertical, 14)
                Divider().overlay(.white.opacity(0.15))
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(opts.indices, id: \.self) { i in
                            Button { opts[i].apply(); refreshSoon(); close() } label: {
                                HStack {
                                    Text(opts[i].label).foregroundStyle(.white)
                                    Spacer()
                                    if opts[i].selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                                .padding(.horizontal).padding(.vertical, 13)
                                .contentShape(Rectangle())
                            }
                            if i < opts.count - 1 { Divider().overlay(.white.opacity(0.08)) }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .background(Color(white: 0.13))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .padding()
            .tint(.cyan)
        }
        .transition(.opacity)
    }

    private func options(for p: Panel) -> [Option] {
        switch p {
        case .video:
            return sizeModes.map { m in Option(label: m.label, selected: videoSize == m.raw) {
                videoSize = m.raw; coordinator.player?.setVideoSize(m.raw)
            } }
        case .speed:
            return speeds.map { s in Option(label: speedLabel(s), selected: abs(speed - s) < 0.01) {
                speed = s; coordinator.player?.setSpeed(s)
            } }
        case .subtitles:
            let off = Option(label: "Off", selected: subtitleTracks.allSatisfy { !$0.selected }) {
                coordinator.player?.setSubtitleTrack(-1)
            }
            return [off] + subtitleTracks.map { t in Option(label: t.label, selected: t.selected) {
                coordinator.player?.setSubtitleTrack(t.id)
            } }
        case .audio:
            return audioTracks.map { t in Option(label: t.label, selected: t.selected) {
                coordinator.player?.setAudioTrack(t.id)
            } }
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

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white).padding(11).background(.black.opacity(0.35), in: Circle())
        }
    }

    private func open(_ p: Panel) {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { panel = p }
    }
    private func close() {
        withAnimation(.easeInOut(duration: 0.15)) { panel = nil }
        scheduleHide()
    }

    private func refreshTracks() {
        audioTracks = coordinator.player?.tracks(ofType: "audio") ?? []
        subtitleTracks = coordinator.player?.tracks(ofType: "sub") ?? []
    }
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshTracks() }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !scrubbing, panel == nil else { return }
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
