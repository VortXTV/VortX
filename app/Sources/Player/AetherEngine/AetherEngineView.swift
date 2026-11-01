#if VORTX_AETHER_ENGINE
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Hosts the AetherEngine lane under the same chrome and Coordinator as the libmpv and AVPlayer surfaces.
struct AetherEngineView: PlatformViewRepresentable {
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

    /// A new host with its engine attached and loading. An engine that could not start reports that on its
    /// first load, which the chrome answers by handing the source to libmpv.
    private func makeHostView() -> HostView {
        let view = HostView()
        let engine = AetherEngineController()
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
        return view
    }

    #if os(macOS)
    func makeNSView(context: Context) -> HostView { makeHostView() }
    func updateNSView(_ view: HostView, context: Context) {}
    static func dismantleNSView(_ view: HostView, coordinator: MPVMetalPlayerView.Coordinator) {
        view.engine?.stop()
        view.engine = nil
    }

    final class HostView: NSView {
        var engine: AetherEngineController?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func attach(_ engine: AetherEngineController) {
            self.engine = engine
            if let video = engine.player?.view {
                video.frame = bounds
                video.autoresizingMask = [.width, .height]
                addSubview(video)
            }
            // Text subtitles ride above the picture.
            engine.subtitleOverlay.frame = bounds
            engine.subtitleOverlay.autoresizingMask = [.width, .height]
            addSubview(engine.subtitleOverlay)
        }
    }
    #else
    func makeUIView(context: Context) -> HostView { makeHostView() }
    func updateUIView(_ view: HostView, context: Context) {}
    static func dismantleUIView(_ view: HostView, coordinator: MPVMetalPlayerView.Coordinator) {
        view.engine?.stop()
        view.engine = nil
    }

    final class HostView: UIView {
        var engine: AetherEngineController?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func attach(_ engine: AetherEngineController) {
            self.engine = engine
            if let video = engine.player?.view {
                video.frame = bounds
                video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(video)
            }
            // Text subtitles ride above the picture.
            engine.subtitleOverlay.frame = bounds
            engine.subtitleOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(engine.subtitleOverlay)
        }
    }
    #endif
}
#endif
