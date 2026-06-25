#if os(iOS) || os(tvOS) || os(macOS)
import SwiftUI
import AVKit
import AVFoundation
import Combine

/// Native AVPlayer surface for adaptive-HLS (`.m3u8`) streams. libmpv does not do mid-stream adaptive
/// bitrate, it locks to one rendition at open, so an adaptive source whose master playlist lacks clean
/// bandwidth ordering can get stuck on the lowest rendition. AVPlayer does true ABR (it ramps to the best
/// rendition the connection sustains, the way Stremio web and desktop do), and brings AirPlay and PiP for
/// free, so HLS streams play here instead of in the libmpv player.
///
/// iOS/tvOS only: macOS keeps the libmpv path (its out-of-process server can transcode HLS itself).
///
/// #76 Phase 1: on iOS the surface is an `AVPlayer` + `AVPlayerLayer` (NOT `AVPlayerViewController`) so VortX
/// owns the chrome — a SwiftUI controls overlay matching the libmpv `PlayerScreen` look (transport, scrubber,
/// skip, close, title, buffering spinner, PiP) sits over the layer, exactly as that player's overlay sits over
/// the Metal layer. tvOS deliberately keeps the bare `AVPlayerViewController`: a focusable custom overlay would
/// fight the Siri-remote focus engine (the documented tvOS player-focus risk), so there AVKit keeps the screen
/// and we close on Menu. Subtitle / audio-track selection and episode next/prev are a later phase (see #76);
/// this phase delivers the VortX chrome + the existing ABR / resume / progress / PiP behaviour, nothing more.
struct HLSPlayerView: View {
    let url: URL
    var title: String = ""
    var headers: [String: String]? = nil
    var resumeSeconds: Double = 0
    var onProgress: (Double, Double) -> Void = { _, _ in }
    var onClose: () -> Void = {}

    /// tvOS in-player episode list (#46): the playing series' episodes, the one currently playing, and the
    /// switch callback. Unused on iOS + macOS (their chrome surfaces episodes through their own overlays).
    var episodes: [CoreVideo] = []
    var currentVideoId: String = ""
    var onSelectEpisode: (CoreVideo) -> Void = { _ in }

    /// tvOS in-player Sources/Quality list (#46): the ranked sources for the playing title, the playing
    /// source's ranking signature, and the switch callback. Unused on iOS + macOS.
    var sources: [CoreStreamSourceGroup] = []
    var currentSourceSignature: String = ""
    var onSelectSource: (CoreStream) -> Void = { _ in }
    /// tvOS only: AVPlayer reported the item could not load (`.failed`). The caller (TVHLSPlayer) re-presents
    /// the stream on libmpv. iOS / macOS have their own AVPlayer -> libmpv fallback in PlayerScreen.
    var onLoadFailed: () -> Void = {}

    /// True for a stream AVPlayer should own: a remote HLS playlist. Torrents (loopback) stay on libmpv.
    static func handles(_ url: URL) -> Bool {
        guard let host = url.host, host != "127.0.0.1", host != "localhost" else { return false }
        return url.pathExtension.lowercased() == "m3u8" || url.absoluteString.lowercased().contains(".m3u8")
    }

    #if os(iOS)
    var body: some View {
        ChromeBody(url: url, title: title, headers: headers, resumeSeconds: resumeSeconds,
                   onProgress: onProgress, onClose: onClose)
    }
    #elseif os(tvOS)
    // tvOS: keep the bare AVPlayerViewController. A custom focusable overlay would compete with the
    // Siri-remote focus engine (the hard-won tvOS player-focus area), so AVKit owns the screen here and
    // the VortX chrome rebuild is iOS/Mac-only in this phase.
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Controller(url: url, headers: headers, resumeSeconds: resumeSeconds, onProgress: onProgress,
                       episodes: episodes, currentVideoId: currentVideoId, onSelectEpisode: onSelectEpisode,
                       sources: sources, currentSourceSignature: currentSourceSignature, onSelectSource: onSelectSource,
                       onLoadFailed: onLoadFailed)
                .ignoresSafeArea()
        }
        .onExitCommand { onClose() }   // Siri-remote Menu leaves the HLS player (the tvOS dismiss idiom)
    }
    #else
    // macOS: SwiftUI VideoPlayer over an AVPlayer. AVPlayerLayer is DV / EDR native, which libmpv/MoltenVK
    // is not (it only tone-maps DV to SDR), so this is the macOS true-Dolby-Vision surface. Native AppKit
    // transport controls; resume + progress mirror the other engines.
    var body: some View {
        MacVideoPlayer(url: url, headers: headers, resumeSeconds: resumeSeconds,
                       onProgress: onProgress, onClose: onClose)
            .ignoresSafeArea()
    }
    #endif
}

#if os(iOS)
// MARK: - iOS: AVPlayerLayer host + VortX chrome overlay

extension HLSPlayerView {
    /// The whole iOS player: the AVPlayerLayer-backed video surface with the VortX controls overlay on top.
    fileprivate struct ChromeBody: View {
        let url: URL
        let title: String
        let headers: [String: String]?
        let resumeSeconds: Double
        let onProgress: (Double, Double) -> Void
        let onClose: () -> Void

        @StateObject private var model = AVPlayerModel()
        @State private var controlsVisible = true
        @State private var hideTask: Task<Void, Never>?
        @State private var scrubbing = false
        @State private var scrubTarget = 0.0

        // skip-button step in seconds, shared with the libmpv PlayerScreen so both players honour the setting.
        @AppStorage("stremiox.seekStep") private var seekStep = "10"
        private var seekStepSeconds: Double { Double(seekStep) ?? 10 }

        var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()

                AVPlayerLayerView(model: model).ignoresSafeArea()

                // Reliable tap-to-toggle over the whole surface; controls sit above so their buttons still work.
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { toggleControls() }
                    .ignoresSafeArea()
                    .accessibilityLabel("Show player controls")
                    .accessibilityAction { toggleControls() }

                if model.buffering { bufferingOverlay }

                if controlsVisible { controls.transition(.opacity) }
            }
            .statusBarHidden(true)
            .animation(.easeOut(duration: 0.18), value: controlsVisible)
            .onAppear {
                model.configure(url: url, headers: headers, resumeSeconds: resumeSeconds, onProgress: onProgress)
                scheduleHide()
            }
            .onDisappear { model.teardown(); hideTask?.cancel() }
            .onReceive(model.$isPaused) { paused in
                // Keep controls up while paused so the user always sees the play button after pausing.
                if paused { showControls(autoHide: false) }
            }
        }

        // MARK: Controls overlay (mirrors PlayerScreen's top / center / bottom bars and Theme look)

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

        private var topBar: some View {
            HStack(spacing: 12) {
                iconButton("chevron.down", label: "Close player") { leave() }
                if !title.isEmpty {
                    Text(title).font(.headline.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(1).shadow(radius: 3)
                }
                Spacer()
                if model.isPiPPossible {
                    iconButton(model.isPiPActive ? "pip.exit" : "pip.enter", label: "Picture in Picture") {
                        model.togglePiP(); scheduleHide()
                    }
                }
            }
            .padding(.horizontal).padding(.top, 8)
        }

        private var centerTransport: some View {
            HStack(spacing: 44) {
                if !model.isLive {
                    seekButton("gobackward.\(seekStep)", by: -seekStepSeconds)
                }
                Button { model.togglePause(); scheduleHide() } label: {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 50)).foregroundStyle(.white).shadow(radius: 8)
                        .frame(width: 100, height: 100)
                }
                .accessibilityLabel(model.isPaused ? "Play" : "Pause")
                if !model.isLive {
                    seekButton("goforward.\(seekStep)", by: seekStepSeconds)
                }
            }
        }

        private var bottomBar: some View {
            VStack(spacing: 14) {
                if model.isLive {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.Palette.danger).frame(width: 8, height: 8)
                        Text("LIVE").font(.caption.weight(.bold)).foregroundStyle(.white)
                        Spacer()
                    }
                } else {
                    HStack(spacing: 12) {
                        Text(timeString(scrubbing ? scrubTarget : model.currentTime))
                            .font(.caption.monospacedDigit()).foregroundStyle(.white)
                        Slider(value: Binding(get: { scrubbing ? scrubTarget : model.currentTime },
                                              set: { scrubTarget = $0 }),
                               in: 0...max(model.duration, 1)) { editing in
                            scrubbing = editing
                            if editing {
                                scrubTarget = model.currentTime; hideTask?.cancel()
                            } else {
                                model.seek(to: scrubTarget)
                                scheduleHide()
                            }
                        }
                        .tint(Theme.Palette.accent)
                        Text(timeString(model.duration)).font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(.horizontal).padding(.bottom, 8)
        }

        private var bufferingOverlay: some View {
            ProgressView().controlSize(.large).tint(.white).transition(.opacity)
        }

        // MARK: Control helpers (match PlayerScreen's iconButton / seekButton / timeString)

        private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: systemName).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white).padding(11).background(.black.opacity(0.35), in: Circle())
                    .frame(width: 44, height: 44).contentShape(Circle())   // min 44pt tap target
            }
            .accessibilityLabel(label)
        }

        private func seekButton(_ icon: String, by delta: Double) -> some View {
            Button {
                model.seek(by: delta); scheduleHide()
            } label: {
                Image(systemName: icon).font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white).shadow(radius: 4).frame(width: 60, height: 60)
            }
            .accessibilityLabel(delta < 0 ? "Skip back" : "Skip forward")
        }

        private func timeString(_ t: Double) -> String {
            guard t.isFinite, t >= 0 else { return "0:00" }
            let total = Int(t), h = total / 3600, m = (total % 3600) / 60, s = total % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        }

        // MARK: Auto-hide + dismiss

        private func toggleControls() {
            if controlsVisible { withAnimation { controlsVisible = false }; hideTask?.cancel() }
            else { showControls(autoHide: true) }
        }

        private func showControls(autoHide: Bool) {
            withAnimation { controlsVisible = true }
            if autoHide { scheduleHide() } else { hideTask?.cancel() }
        }

        /// Hide the controls after ~3.5s of inactivity, unless paused (mirrors PlayerScreen).
        private func scheduleHide() {
            hideTask?.cancel()
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                guard !Task.isCancelled, !model.isPaused, !scrubbing else { return }
                withAnimation { controlsVisible = false }
            }
        }

        private func leave() {
            model.flushProgress()
            onClose()
        }
    }
}

/// Hosts an `AVPlayerLayer` in a plain UIView so VortX owns the video surface (no Apple chrome). The layer is
/// handed back to the model on creation so PiP attaches to this exact layer (PiP needs the live AVPlayerLayer).
private struct AVPlayerLayerView: UIViewRepresentable {
    let model: AVPlayerModel

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.player = model.player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        model.attachLayer(view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== model.player { view.playerLayer.player = model.player }
    }

    /// A UIView whose backing layer is an AVPlayerLayer, so the video fills the view and resizes with it.
    final class PlayerLayerHostView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Drives one AVPlayer for the iOS HLS chrome: ABR (native), resume seek, ~4 Hz time / state for the overlay,
/// 1 Hz progress to Continue Watching, live detection, and PiP over the AVPlayerLayer. KVO + a periodic time
/// observer push state to the SwiftUI overlay; nothing here renders UI.
@MainActor
private final class AVPlayerModel: NSObject, ObservableObject {
    @Published var currentTime = 0.0
    @Published var duration = 0.0
    @Published var isPaused = true
    @Published var buffering = true
    @Published var isLive = false
    @Published var isPiPPossible = false
    @Published var isPiPActive = false

    let player = AVPlayer()

    private var onProgress: (Double, Double) -> Void = { _, _ in }
    private var resumeSeconds = 0.0
    private var didResume = false
    private var lastReported = -10.0

    private var item: AVPlayerItem?
    private var isReady = false
    private var didFlush = false
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var pipController: AVPictureInPictureController?

    func configure(url: URL, headers: [String: String]?, resumeSeconds: Double,
                   onProgress: @escaping (Double, Double) -> Void) {
        guard item == nil else { return }   // configure once
        self.onProgress = onProgress
        self.resumeSeconds = resumeSeconds

        // Activate .playback before play so PiP and locked-screen/background audio work (PiP refuses to start
        // without an active .playback session) and advertise multichannel so Atmos passes through (#78) and
        // AirPods get Spatial Audio (#88). The libmpv path sets its own session in configureAudioSession, and
        // only one player is active at a time, so this is idempotent across a HLS->torrent hand-off.
        AVPlayerAudioSession.activateForMovie()

        let options = (headers?.isEmpty ?? true) ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers!]
        let asset = AVURLAsset(url: url, options: options)
        let newItem = AVPlayerItem(asset: asset)
        item = newItem
        player.replaceCurrentItem(with: newItem)
        player.allowsExternalPlayback = true   // AirPlay

        observeStatus(of: newItem)
        observeBuffering(of: newItem)
        observeTimeControl()
        addTimeObserver()
    }

    /// The representable hands its AVPlayerLayer here once it exists, so PiP binds to the exact on-screen layer.
    func attachLayer(_ layer: AVPlayerLayer) {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let pip = AVPictureInPictureController(playerLayer: layer)
        pip?.delegate = self
        pipController = pip
        observePiP(pip)
        isPiPPossible = pip?.isPictureInPicturePossible ?? false
    }

    // MARK: Transport (the overlay calls these)

    func togglePause() { player.timeControlStatus == .paused ? player.play() : player.pause() }

    func seek(to seconds: Double) {
        guard isReady else { return }   // ignore scrubs before the item is playable (no resume point clobbering)
        let clamped = duration > 1 ? min(max(seconds, 0), max(duration - 1, 0)) : max(seconds, 0)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
        report(clamped)
    }

    func seek(by delta: Double) { seek(to: currentTime + delta) }

    func togglePiP() {
        guard let pip = pipController else { return }
        pip.isPictureInPictureActive ? pip.stopPictureInPicture() : pip.startPictureInPicture()
    }

    /// Flush the latest position so the resume point is current when the user leaves. Idempotent: the leave()
    /// path and the .onDisappear teardown both call this, so guard against a duplicate Continue-Watching write.
    func flushProgress() {
        guard !didFlush, duration.isFinite, duration > 0 else { return }
        didFlush = true
        onProgress(player.currentTime().seconds, duration)
    }

    func teardown() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        flushProgress()
        player.pause()
        player.replaceCurrentItem(with: nil)
        // Drop the PiP delegate before releasing the controller so a late AVKit callback can't touch torn-down state.
        pipController?.delegate = nil
        pipController = nil
    }

    // MARK: KVO + time observer

    private func observeStatus(of item: AVPlayerItem) {
        let obs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in self.handleReady(item) }
        }
        observations.append(obs)
    }

    private func handleReady(_ item: AVPlayerItem) {
        guard item.status == .readyToPlay else { return }
        isReady = true
        let dur = item.duration.seconds
        if dur.isFinite, dur > 0 {
            duration = dur
            isLive = false
        } else {
            // An indefinite (NaN/infinite) duration is a live HLS stream: no scrubbable timeline.
            isLive = true
        }
        if !didResume {
            didResume = true
            if resumeSeconds > 1, !isLive {
                player.seek(to: CMTime(seconds: resumeSeconds, preferredTimescale: 600))
            }
            player.play()
        }
    }

    private func observeBuffering(of item: AVPlayerItem) {
        let empty = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.buffering = item.isPlaybackBufferEmpty }
        }
        let likely = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in if item.isPlaybackLikelyToKeepUp { self?.buffering = false } }
        }
        observations.append(contentsOf: [empty, likely])
    }

    private func observeTimeControl() {
        let obs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPaused = player.timeControlStatus == .paused
                if player.timeControlStatus == .playing { self.buffering = false }
            }
        }
        observations.append(obs)
    }

    private func addTimeObserver() {
        // ~4 Hz drives the scrubber + time labels; report progress once a second to Continue Watching.
        // The callback is delivered on .main, so it runs synchronously on the main actor (no extra Task hop,
        // which would otherwise leave a window where the callback fires after teardown replaced the item).
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.timeObserver != nil else { return }   // skip a callback queued past teardown
                self.currentTime = time.seconds
                if let dur = self.player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                    self.duration = dur
                    self.report(time.seconds)
                }
            }
        }
    }

    private func report(_ pos: Double) {
        guard duration.isFinite, duration > 0, abs(pos - lastReported) >= 1 else { return }
        lastReported = pos
        onProgress(pos, duration)
    }

    // MARK: PiP

    private func observePiP(_ pip: AVPictureInPictureController?) {
        guard let pip else { return }
        let possible = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] pip, _ in
            Task { @MainActor in self?.isPiPPossible = pip.isPictureInPicturePossible }
        }
        let active = pip.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] pip, _ in
            Task { @MainActor in self?.isPiPActive = pip.isPictureInPictureActive }
        }
        observations.append(contentsOf: [possible, active])
    }
}

extension AVPlayerModel: AVPictureInPictureControllerDelegate {}
#endif

// MARK: - tvOS: bare AVPlayerViewController (focus-safe, unchanged)

#if os(tvOS)
extension HLSPlayerView {
    /// Wraps AVPlayerViewController with native transport controls, ABR, resume, and progress reporting.
    fileprivate struct Controller: UIViewControllerRepresentable {
        let url: URL
        let headers: [String: String]?
        let resumeSeconds: Double
        let onProgress: (Double, Double) -> Void
        var episodes: [CoreVideo] = []
        var currentVideoId: String = ""
        var onSelectEpisode: (CoreVideo) -> Void = { _ in }
        var sources: [CoreStreamSourceGroup] = []
        var currentSourceSignature: String = ""
        var onSelectSource: (CoreStream) -> Void = { _ in }
        var onLoadFailed: () -> Void = {}

        func makeCoordinator() -> Coordinator { Coordinator(resumeSeconds: resumeSeconds, onProgress: onProgress, onLoadFailed: onLoadFailed) }

        func makeUIViewController(context: Context) -> AVPlayerViewController {
            // Apple TV Atmos passthrough (#78) + AirPods Spatial Audio (#88): claim .playback and advertise
            // multichannel BEFORE the player starts so AVPlayerViewController negotiates the spatial / Atmos
            // layout instead of a stereo downmix. This is the path DV (and its frequent Atmos track) takes.
            AVPlayerAudioSession.activateForMovie()
            let options = (headers?.isEmpty ?? true) ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers!]
            let asset = AVURLAsset(url: url, options: options)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true   // AirPlay
            context.coordinator.attach(player, item: item)

            let vc = AVPlayerViewController()
            vc.player = player
            vc.allowsPictureInPicturePlayback = true
            // #46: in-player chrome. AVKit owns the focus engine for customInfoViewControllers (the Info panel
            // revealed by swiping down on the Siri remote), so these add the episode + source chrome without a
            // custom overlay fighting the remote — the reason this HLS / DV player stays bare.
            var panels: [UIViewController] = []
            let ordered = episodes.orderedBySeasonEpisode
            if ordered.count > 1 {
                let ep = UIHostingController(rootView: TVPlayerEpisodePanel(
                    episodes: ordered, currentVideoId: currentVideoId, onSelect: onSelectEpisode))
                ep.title = String(localized: "Episodes")
                panels.append(ep)
            }
            if !sources.isEmpty {
                let src = UIHostingController(rootView: TVPlayerSourcesPanel(
                    groups: sources, currentSignature: currentSourceSignature, onSelect: onSelectSource))
                src.title = String(localized: "Sources")
                panels.append(src)
            }
            if !panels.isEmpty { vc.customInfoViewControllers = panels }
            return vc
        }

        func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
            // Both panels (episodes + sources) are baked once in makeUIViewController. RootView presents this
            // player with `.id(req.id)`, so every episode OR source switch mints a new request id -> full
            // teardown + rebuild, and `currentVideoId`/`onSelectEpisode`/`sources`/`currentSourceSignature`/
            // `onSelectSource` are never stale here. If that invariant ever changes (e.g. a live in-place
            // refresh of `sources`), rebuild `controller.customInfoViewControllers` in this method.
        }

        static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
            coordinator.teardown()
            controller.player?.pause()
            controller.player = nil
        }

        final class Coordinator {
            private let resumeSeconds: Double
            private let onProgress: (Double, Double) -> Void
            private let onLoadFailed: () -> Void
            private weak var player: AVPlayer?
            private var timeObserver: Any?
            private var readyObserver: NSKeyValueObservation?
            private var didResume = false
            private var didFail = false

            init(resumeSeconds: Double, onProgress: @escaping (Double, Double) -> Void, onLoadFailed: @escaping () -> Void = {}) {
                self.resumeSeconds = resumeSeconds
                self.onProgress = onProgress
                self.onLoadFailed = onLoadFailed
            }

            func attach(_ player: AVPlayer, item: AVPlayerItem) {
                self.player = player
                // Seek to the saved position once the item is ready, then play. If AVFoundation cannot open
                // the item (.failed), hand the stream back to the caller so it can re-present on libmpv -
                // without this, a remote HLS / DV-in-MP4 that AVPlayer chokes on left a black screen with no
                // recovery (the tvOS "nothing plays" bug). Mirrors PlayerScreen.avEngineFailed on iOS/macOS.
                readyObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard let self else { return }
                    if item.status == .failed, !self.didFail {
                        self.didFail = true
                        Task { @MainActor in self.onLoadFailed() }
                        return
                    }
                    guard item.status == .readyToPlay, !self.didResume else { return }
                    self.didResume = true
                    if self.resumeSeconds > 1 {
                        player.seek(to: CMTime(seconds: self.resumeSeconds, preferredTimescale: 600))
                    }
                    player.play()
                }
                // Report progress every second so Continue Watching updates, mirroring the libmpv hook.
                timeObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main
                ) { [weak self] time in
                    guard let self, let dur = self.player?.currentItem?.duration.seconds,
                          dur.isFinite, dur > 0 else { return }
                    self.onProgress(time.seconds, dur)
                }
            }

            func teardown() {
                if let player, let timeObserver { player.removeTimeObserver(timeObserver) }
                timeObserver = nil
                readyObserver?.invalidate(); readyObserver = nil
                // Flush a final position so the resume point is current. The close itself is driven by the
                // onExitCommand, so no onClose here (avoids a double dismiss).
                if let player, let dur = player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                    onProgress(player.currentTime().seconds, dur)
                }
            }
        }
    }
}
#endif

#if os(macOS)
/// macOS true-Dolby-Vision / HLS surface: a SwiftUI `VideoPlayer` over an `AVPlayer`. AVPlayerLayer is DV /
/// EDR native (libmpv/MoltenVK only tone-maps DV to SDR), so DV streams the router sends here play in true
/// Dolby Vision on a capable display. A reference-type model owns the player + observers so the resume seek
/// and the once-per-second progress report survive SwiftUI value-type re-renders.
private struct MacVideoPlayer: View {
    let url: URL
    var headers: [String: String]? = nil
    var resumeSeconds: Double = 0
    var onProgress: (Double, Double) -> Void = { _, _ in }
    var onClose: () -> Void = {}

    @StateObject private var model = Model()

    var body: some View {
        VideoPlayer(player: model.player)
            .ignoresSafeArea()
            .onAppear { model.start(url: url, headers: headers, resume: resumeSeconds, onProgress: onProgress) }
            .onDisappear { model.stop(onProgress: onProgress) }
    }

    final class Model: ObservableObject {
        let player = AVPlayer()
        private var timeObserver: Any?
        private var statusObserver: NSKeyValueObservation?
        private var didResume = false

        func start(url: URL, headers: [String: String]?, resume: Double, onProgress: @escaping (Double, Double) -> Void) {
            let options = (headers?.isEmpty ?? true) ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers!]
            let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
            player.replaceCurrentItem(with: item)
            player.allowsExternalPlayback = true
            statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self, item.status == .readyToPlay, !self.didResume else { return }
                self.didResume = true
                if resume > 1 { self.player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
                self.player.play()
            }
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main
            ) { [weak self] time in
                guard let self, let dur = self.player.currentItem?.duration.seconds, dur.isFinite, dur > 0 else { return }
                onProgress(time.seconds, dur)
            }
        }

        func stop(onProgress: (Double, Double) -> Void) {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            timeObserver = nil
            statusObserver?.invalidate(); statusObserver = nil
            if let dur = player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                onProgress(player.currentTime().seconds, dur)
            }
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }
}
#endif
#endif
