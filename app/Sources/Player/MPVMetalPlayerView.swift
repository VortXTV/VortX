import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// SwiftUI's controller-representable protocol differs by platform; alias it so the struct body is
// shared and only the make/update/dismantle methods (whose names differ) branch below.
#if canImport(UIKit)
typealias PlatformViewControllerRepresentable = UIViewControllerRepresentable
#elseif canImport(AppKit)
typealias PlatformViewControllerRepresentable = NSViewControllerRepresentable
#endif

struct MPVMetalPlayerView: PlatformViewControllerRepresentable {
    @ObservedObject var coordinator: Coordinator

    /// Shared construction + wiring of the player controller (identical on every platform).
    private func makeController(_ context: Context) -> MPVMetalViewController {
        let mpv = MPVMetalViewController()
        mpv.playDelegate = coordinator
        mpv.playUrl = coordinator.playUrl
        mpv.playHeaders = coordinator.playHeaders
        mpv.playUrlLive = coordinator.playLive
        mpv.playAudioSidecarURL = coordinator.playAudioSidecar
        mpv.startMuted = coordinator.muted
        mpv.loopPlayback = coordinator.loops
        mpv.forceFillVideo = coordinator.forceFill
        let coord = context.coordinator
        mpv.onSingleTap = { [weak coord] in coord?.onTap?() }
        context.coordinator.player = mpv
        return mpv
    }

    #if canImport(UIKit)
    func makeUIViewController(context: Context) -> MPVMetalViewController { makeController(context) }
    func updateUIViewController(_ controller: MPVMetalViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: MPVMetalViewController, coordinator: Coordinator) {
        controller.stop()
    }
    #elseif canImport(AppKit)
    func makeNSViewController(context: Context) -> MPVMetalViewController { makeController(context) }
    func updateNSViewController(_ controller: MPVMetalViewController, context: Context) {}
    static func dismantleNSViewController(_ controller: MPVMetalViewController, coordinator: Coordinator) {
        controller.stop()
    }
    #endif

    public func makeCoordinator() -> Coordinator {
        coordinator
    }

    func play(_ url: URL, headers: [String: String]? = nil, audioSidecar: URL? = nil) -> Self {
        coordinator.playUrl = url
        coordinator.playHeaders = headers
        coordinator.playAudioSidecar = audioSidecar
        return self
    }

    func live(_ live: Bool) -> Self {
        coordinator.playLive = live
        return self
    }

    /// Hero-preview only (#44): mount this libmpv instance muted and looping for an ambient background
    /// trailer clip. The main player never calls this, so its audio + auto-next behaviour is unchanged.
    func muted(_ muted: Bool, loop: Bool = false) -> Self {
        coordinator.muted = muted
        coordinator.loops = loop
        return self
    }

    /// Hero-preview only (#44): crop-to-fill so the ambient clip fills the whole hero band instead of a small
    /// letterboxed box. Never called by the main player, so real playback aspect is unchanged.
    func videoFill(_ fill: Bool) -> Self {
        coordinator.forceFill = fill
        return self
    }

    func onPropertyChange(_ handler: @escaping (any PlayerEngine, String, Any?) -> Void) -> Self {
        coordinator.onPropertyChange = handler
        return self
    }

    func onTap(_ handler: @escaping () -> Void) -> Self {
        coordinator.onTap = handler
        return self
    }

    @MainActor
    public final class Coordinator: MPVPlayerDelegate, ObservableObject {
        // `any PlayerEngine` so the same Coordinator + chrome can be driven by either the libmpv
        // controller or an AVFoundation engine; whichever is assigned here is what the chrome talks to.
        weak var player: (any PlayerEngine)?

        var playUrl : URL?
        var playHeaders: [String: String]?
        var playLive = false
        /// yt-direct adaptive pair: external audio stream mounted with the (video-only) playUrl at load.
        var playAudioSidecar: URL?
        /// Hero-preview only (#44): start the libmpv instance muted / looping for an ambient background clip.
        var muted = false
        var loops = false
        /// Ambient hero clip only (#44): crop-to-fill so the clip fills the whole hero band, never letterboxed.
        var forceFill = false
        var onPropertyChange: ((any PlayerEngine, String, Any?) -> Void)?
        var onTap: (() -> Void)?

        func play(_ url: URL) {
            player?.loadFile(url, headers: playHeaders, live: playLive)
        }

        func propertyChange(propertyName: String, data: Any?) {
            guard let player else { return }

            self.onPropertyChange?(player, propertyName, data)
        }
    }
}
