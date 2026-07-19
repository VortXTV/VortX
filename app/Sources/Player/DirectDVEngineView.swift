#if os(iOS) || os(tvOS) || os(macOS)
import SwiftUI
import AVFoundation

/// SwiftUI surface for the DIRECT Dolby Vision lane: renders `VortXDirectDVEngineController` into an
/// `AVSampleBufferDisplayLayer` and wires it to the SHARED `MPVMetalPlayerView.Coordinator`, so the full
/// player chrome drives this engine exactly as it drives libmpv and AVPlayer. The structural mirror of
/// `AVPlayerEngineView`; only the backing layer and engine type differ. There is no AVPlayer and no HLS
/// on this path, so the -12927 declaration/content cross-check cannot exist here (see
/// VortXDirectDVEngine.swift for the architecture note).
struct DirectDVEngineView: PlatformViewRepresentable {
    @ObservedObject var coordinator: MPVMetalPlayerView.Coordinator

    func play(_ url: URL, headers: [String: String]? = nil, isDolbyVision: Bool = true) -> Self {
        coordinator.playUrl = url
        coordinator.playHeaders = headers
        coordinator.contentIsDolbyVision = isDolbyVision
        return self
    }

    func live(_ live: Bool) -> Self { coordinator.playLive = live; return self }
    func onPropertyChange(_ handler: @escaping (any PlayerEngine, String, Any?) -> Void) -> Self {
        coordinator.onPropertyChange = handler
        return self
    }
    func onTap(_ handler: @escaping () -> Void) -> Self { coordinator.onTap = handler; return self }

    func makeCoordinator() -> MPVMetalPlayerView.Coordinator { coordinator }

    /// Shared host-view construction (mirrors AVPlayerEngineView.makeHostView): build the engine, bind it
    /// to the shared Coordinator, attach the layer + subtitle overlay, then load.
    @MainActor
    private func makeHostView() -> DirectDVHostView {
        let view = DirectDVHostView()
        let engine = VortXDirectDVEngineController()
        engine.playDelegate = coordinator
        coordinator.player = engine            // weak; the host view retains the engine
        view.engine = engine
        engine.attachLayer(view.sampleBufferLayer)
        engine.attachSubtitleOverlay(view.subtitleOverlay)
        engine.contentIsDolbyVision = coordinator.contentIsDolbyVision
        if let url = coordinator.playUrl {
            engine.loadFile(url, headers: coordinator.playHeaders, live: coordinator.playLive)
        }
        return view
    }

    #if os(macOS)
    func makeNSView(context: Context) -> DirectDVHostView { makeHostView() }
    func updateNSView(_ view: DirectDVHostView, context: Context) {}
    static func dismantleNSView(_ view: DirectDVHostView, coordinator: MPVMetalPlayerView.Coordinator) {
        view.engine?.stop(); view.engine = nil
    }

    /// AppKit host: the sample-buffer layer is a manually sized sublayer (AppKit has no layerClass).
    final class DirectDVHostView: NSView {
        let sampleBufferLayer = AVSampleBufferDisplayLayer()
        let subtitleOverlay = SubtitleOverlayView()
        var engine: VortXDirectDVEngineController?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            let base = CALayer()
            base.backgroundColor = NSColor.black.cgColor
            layer = base
            sampleBufferLayer.frame = bounds
            sampleBufferLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            base.addSublayer(sampleBufferLayer)
            subtitleOverlay.frame = bounds
            subtitleOverlay.autoresizingMask = [.width, .height]
            addSubview(subtitleOverlay)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func layout() {
            super.layout()
            sampleBufferLayer.frame = bounds
        }
    }
    #else
    func makeUIView(context: Context) -> DirectDVHostView {
        let view = makeHostView()
        view.backgroundColor = .black
        return view
    }
    func updateUIView(_ view: DirectDVHostView, context: Context) {}
    static func dismantleUIView(_ view: DirectDVHostView, coordinator: MPVMetalPlayerView.Coordinator) {
        view.engine?.stop(); view.engine = nil
    }

    /// UIKit host: the backing layer IS the sample-buffer layer, so video fills and resizes with the view.
    final class DirectDVHostView: UIView {
        override static var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var sampleBufferLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
        let subtitleOverlay = SubtitleOverlayView()
        var engine: VortXDirectDVEngineController?
        override init(frame: CGRect) {
            super.init(frame: frame)
            subtitleOverlay.frame = bounds
            subtitleOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(subtitleOverlay)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
    #endif
}
#endif
