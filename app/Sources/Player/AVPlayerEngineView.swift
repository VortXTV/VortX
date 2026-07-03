#if os(iOS) || os(tvOS) || os(macOS)
import SwiftUI
import AVKit
import AVFoundation

/// SwiftUI surface that renders an `AVPlayerEngineController` into an `AVPlayerLayer` and wires it to the
/// SHARED `MPVMetalPlayerView.Coordinator`, so the full PlayerScreen chrome drives AVPlayer exactly as it
/// drives the libmpv controller. The mirror of `MPVMetalPlayerView` for the AVFoundation engine: same fluent
/// builders (`play`/`live`/`onPropertyChange`/`onTap`) and the same Coordinator, so PlayerScreen can mount
/// either interchangeably under one overlay.
///
/// iOS + macOS + tvOS (#46, #76): all three reuse the platform chrome over this AVPlayer surface for true
/// Dolby Vision and the "Prefer AVPlayer" override. tvOS mounts this from `TVPlayerView.playerSurface` (the
/// same place it mounts libmpv), so the existing control bar / scrubber / panels drive AVPlayer unchanged;
/// remote input stays on `TVPlayerView`'s UIKit `RemoteCatcher`, never a focusable SwiftUI overlay.
struct AVPlayerEngineView: PlatformViewRepresentable {
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
    // one, mirroring MPVMetalPlayerView), so dismantle's `coordinator:` parameter type lines up.
    func makeCoordinator() -> MPVMetalPlayerView.Coordinator { coordinator }

    /// Shared host-view construction for both platforms (the host views below both expose `playerLayer` +
    /// `engine`): build the engine, bind it to the shared Coordinator, and hand it the layer.
    private func makeHostView() -> AVPlayerLayerHostView {
        let view = AVPlayerLayerHostView()
        let engine = AVPlayerEngineController()
        engine.playDelegate = coordinator
        coordinator.player = engine            // weak; the host view below retains the engine
        view.engine = engine
        view.playerLayer.player = engine.player
        engine.attachLayer(view.playerLayer)   // binds video gravity + PiP to this exact layer
        engine.attachSubtitleOverlay(view.subtitleOverlay)   // draw external srt/vtt subs above the video
        if let url = coordinator.playUrl {
            engine.loadFile(url, headers: coordinator.playHeaders, live: coordinator.playLive)
        }
        return view
    }

    #if os(macOS)
    func makeNSView(context: Context) -> AVPlayerLayerHostView { makeHostView() }
    func updateNSView(_ view: AVPlayerLayerHostView, context: Context) {}
    static func dismantleNSView(_ view: AVPlayerLayerHostView, coordinator: MPVMetalPlayerView.Coordinator) {
        view.engine?.stop(); view.engine = nil
    }

    /// An NSView whose layer hosts an AVPlayerLayer (AppKit has no `layerClass` override, so the layer is
    /// created + resized manually), holding a STRONG reference to the engine because `Coordinator.player` is weak.
    final class AVPlayerLayerHostView: NSView {
        let playerLayer = AVPlayerLayer()
        let subtitleOverlay = SubtitleOverlayView()   // external srt/vtt subs, drawn above the video
        var engine: AVPlayerEngineController?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            let base = CALayer()
            base.backgroundColor = NSColor.black.cgColor
            layer = base
            playerLayer.frame = bounds
            playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            base.addSublayer(playerLayer)
            // The overlay is a subview ABOVE the AVPlayerLayer sublayer, pinned to fill the host.
            subtitleOverlay.frame = bounds
            subtitleOverlay.autoresizingMask = [.width, .height]
            addSubview(subtitleOverlay)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func layout() {
            super.layout()
            playerLayer.frame = bounds
            syncSubtitleInset()
        }
        /// Push the bottom letterbox bar height (host-bottom to picture-bottom, for the current videoGravity)
        /// into the subtitle overlay so external cues ride over the picture rather than the black bar.
        private func syncSubtitleInset() {
            let video = playerLayer.videoRect              // picture rect in the layer's coordinate space
            guard video.height > 0, playerLayer.bounds.height > 0 else { return }
            let bottomBar = max(0, playerLayer.bounds.maxY - video.maxY)
            subtitleOverlay.setVideoBottomInset(bottomBar)
        }
    }
    #else
    func makeUIView(context: Context) -> AVPlayerLayerHostView {
        let view = makeHostView()
        view.backgroundColor = .black
        return view
    }
    func updateUIView(_ view: AVPlayerLayerHostView, context: Context) {}
    static func dismantleUIView(_ view: AVPlayerLayerHostView, coordinator: MPVMetalPlayerView.Coordinator) {
        view.engine?.stop(); view.engine = nil
    }

    /// A UIView whose backing layer is an AVPlayerLayer (so the video fills + resizes with the view), holding
    /// a STRONG reference to the engine because `Coordinator.player` is weak.
    final class AVPlayerLayerHostView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        let subtitleOverlay = SubtitleOverlayView()   // external srt/vtt subs, drawn above the video
        var engine: AVPlayerEngineController?
        override init(frame: CGRect) {
            super.init(frame: frame)
            // The backing layer IS the AVPlayerLayer; the overlay is a subview, so it renders above the video.
            subtitleOverlay.frame = bounds
            subtitleOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(subtitleOverlay)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func layoutSubviews() {
            super.layoutSubviews()
            // Push the bottom letterbox bar height (host-bottom to picture-bottom, for the current videoGravity)
            // into the subtitle overlay so external cues ride over the picture rather than the black bar.
            let video = playerLayer.videoRect            // picture rect in the layer's coordinate space
            guard video.height > 0, playerLayer.bounds.height > 0 else { return }
            let bottomBar = max(0, playerLayer.bounds.maxY - video.maxY)
            subtitleOverlay.setVideoBottomInset(bottomBar)
        }
    }
    #endif
}

/// The SwiftUI representable protocol for the current platform, so `AVPlayerEngineView` is written once.
#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif
#endif
