#if VORTX_AETHER_ENGINE
import SwiftUI
import UIKit
import VortXAetherKit

/// Hosts the AetherEngine lane under the same chrome and Coordinator as the libmpv and AVPlayer surfaces.
struct AetherEngineView: UIViewRepresentable {
    @ObservedObject var coordinator: MPVMetalPlayerView.Coordinator
    private var resumeOriginSeconds = 0.0
    private var startsPaused = false

    init(coordinator: MPVMetalPlayerView.Coordinator) {
        self.coordinator = coordinator
    }

    func play(_ url: URL, headers: [String: String]? = nil, audioSidecar: URL? = nil, isDolbyVision: Bool = false) -> Self {
        coordinator.playUrl = url
        coordinator.playHeaders = headers
        coordinator.playAudioSidecar = audioSidecar
        coordinator.contentIsDolbyVision = isDolbyVision
        return self
    }
    func live(_ live: Bool) -> Self { coordinator.playLive = live; return self }
    func initiallyPaused(_ paused: Bool) -> Self {
        var copy = self
        copy.startsPaused = paused
        return copy
    }
    func resumeOrigin(_ seconds: Double?) -> Self {
        var copy = self
        copy.resumeOriginSeconds = seconds ?? 0
        return copy
    }
    func onPropertyChange(_ handler: @escaping (any PlayerEngine, String, Any?, PlayerLoadToken) -> Void) -> Self {
        coordinator.onPropertyChange = handler
        return self
    }

    func makeCoordinator() -> MPVMetalPlayerView.Coordinator { coordinator }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        do {
            let engine = AetherEngineController(player: try VortXAetherPlayer())
            engine.playDelegate = coordinator
            coordinator.player = engine            // weak; the host view retains the engine
            view.attach(engine)
            engine.contentIsDolbyVision = coordinator.contentIsDolbyVision
            if let url = coordinator.playUrl {
                engine.configureResumeOrigin(seconds: resumeOriginSeconds)
                engine.holdsNextLoadPaused = startsPaused
                engine.loadFile(url, headers: coordinator.playHeaders, live: coordinator.playLive,
                                audioSidecar: coordinator.playAudioSidecar, reusing: nil)
            }
        } catch {
            // Without an engine nothing loads; the chrome's start deadline reports the failure.
            DiagnosticsLog.log("player", "AetherEngine could not start: \(error.localizedDescription)")
        }
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {}

    static func dismantleUIView(_ view: HostView, coordinator: MPVMetalPlayerView.Coordinator) {
        view.engine?.stop()
        view.engine = nil
    }

    final class HostView: UIView {
        var engine: AetherEngineController?

        func attach(_ engine: AetherEngineController) {
            self.engine = engine
            let video = engine.player.view
            video.frame = bounds
            video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(video)
            // Text subtitles ride above the picture.
            engine.subtitleOverlay.frame = bounds
            engine.subtitleOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(engine.subtitleOverlay)
        }
    }
}
#endif
