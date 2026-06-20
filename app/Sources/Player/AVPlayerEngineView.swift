#if os(iOS)
import SwiftUI
import AVKit
import AVFoundation

/// SwiftUI surface that renders an `AVPlayerEngineController` into an `AVPlayerLayer` and wires it to the
/// SHARED `MPVMetalPlayerView.Coordinator`, so the full PlayerScreen chrome drives AVPlayer exactly as it
/// drives the libmpv controller. The mirror of `MPVMetalPlayerView` for the AVFoundation engine: same fluent
/// builders (`play`/`live`/`onPropertyChange`/`onTap`) and the same Coordinator, so PlayerScreen can mount
/// either interchangeably under one overlay.
///
/// iOS-only (macOS stays on libmpv; tvOS uses a bare AVPlayerViewController).
struct AVPlayerEngineView: UIViewRepresentable {
    @ObservedObject var coordinator: MPVMetalPlayerView.Coordinator

    func play(_ url: URL, headers: [String: String]? = nil) -> Self {
        coordinator.playUrl = url
        coordinator.playHeaders = headers
        return self
    }
    func live(_ live: Bool) -> Self { coordinator.playLive = live; return self }
    func onPropertyChange(_ handler: @escaping (any PlayerEngine, String, Any?) -> Void) -> Self {
        coordinator.onPropertyChange = handler
        return self
    }
    func onTap(_ handler: @escaping () -> Void) -> Self { coordinator.onTap = handler; return self }

    // Bind the representable's Coordinator associatedtype to the shared Coordinator (returns the passed-in
    // one, mirroring MPVMetalPlayerView), so dismantleUIView's `coordinator:` parameter type lines up.
    func makeCoordinator() -> MPVMetalPlayerView.Coordinator { coordinator }

    func makeUIView(context: Context) -> AVPlayerLayerHostView {
        let view = AVPlayerLayerHostView()
        let engine = AVPlayerEngineController()
        engine.playDelegate = coordinator
        coordinator.player = engine            // weak; the host view below retains the engine
        view.engine = engine
        view.playerLayer.player = engine.player
        view.backgroundColor = .black
        engine.attachLayer(view.playerLayer)   // binds video gravity + PiP to this exact layer
        if let url = coordinator.playUrl {
            engine.loadFile(url, headers: coordinator.playHeaders, live: coordinator.playLive)
        }
        return view
    }

    func updateUIView(_ view: AVPlayerLayerHostView, context: Context) {}

    static func dismantleUIView(_ view: AVPlayerLayerHostView, coordinator: MPVMetalPlayerView.Coordinator) {
        view.engine?.stop()
        view.engine = nil
    }

    /// A UIView whose backing layer is an AVPlayerLayer (so the video fills + resizes with the view), holding
    /// a STRONG reference to the engine because `Coordinator.player` is weak.
    final class AVPlayerLayerHostView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var engine: AVPlayerEngineController?
    }
}
#endif
