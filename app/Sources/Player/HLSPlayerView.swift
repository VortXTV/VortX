#if os(iOS) || os(tvOS)
import SwiftUI
import AVKit

/// Native AVPlayer surface for adaptive-HLS (`.m3u8`) streams. libmpv does not do mid-stream adaptive
/// bitrate, it locks to one rendition at open, so an adaptive source whose master playlist lacks clean
/// bandwidth ordering can get stuck on the lowest rendition. AVPlayer does true ABR (it ramps to the best
/// rendition the connection sustains, the way Stremio web and desktop do), and brings AirPlay and PiP for
/// free, so HLS streams play here instead of in the libmpv player.
///
/// iOS/tvOS only: macOS keeps the libmpv path (its out-of-process server can transcode HLS itself).
struct HLSPlayerView: View {
    let url: URL
    var headers: [String: String]? = nil
    var resumeSeconds: Double = 0
    var onProgress: (Double, Double) -> Void = { _, _ in }
    var onClose: () -> Void = {}

    /// True for a stream AVPlayer should own: a remote HLS playlist. Torrents (loopback) stay on libmpv.
    static func handles(_ url: URL) -> Bool {
        guard let host = url.host, host != "127.0.0.1", host != "localhost" else { return false }
        return url.pathExtension.lowercased() == "m3u8" || url.absoluteString.lowercased().contains(".m3u8")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            Controller(url: url, headers: headers, resumeSeconds: resumeSeconds, onProgress: onProgress)
                .ignoresSafeArea()
            // An embedded AVPlayerViewController has no Done button (that only appears when AVKit presents
            // it modally), so add our own. tvOS users also get the Menu button via the controller.
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .padding(12).background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            #if os(iOS)
            .keyboardShortcut(.cancelAction)
            .padding(.top, 12).padding(.leading, 16)
            #endif
            .accessibilityLabel("Close player")
        }
    }

    /// Wraps AVPlayerViewController with native transport controls, ABR, resume, and progress reporting.
    private struct Controller: UIViewControllerRepresentable {
        let url: URL
        let headers: [String: String]?
        let resumeSeconds: Double
        let onProgress: (Double, Double) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(resumeSeconds: resumeSeconds, onProgress: onProgress) }

        func makeUIViewController(context: Context) -> AVPlayerViewController {
            let options = (headers?.isEmpty ?? true) ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers!]
            let asset = AVURLAsset(url: url, options: options)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true   // AirPlay
            context.coordinator.attach(player, item: item)

            let vc = AVPlayerViewController()
            vc.player = player
            vc.allowsPictureInPicturePlayback = true
            #if os(iOS)
            vc.canStartPictureInPictureAutomaticallyFromInline = true
            #endif
            return vc
        }

        func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

        static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
            coordinator.teardown()
            controller.player?.pause()
            controller.player = nil
        }

        final class Coordinator {
            private let resumeSeconds: Double
            private let onProgress: (Double, Double) -> Void
            private weak var player: AVPlayer?
            private var timeObserver: Any?
            private var readyObserver: NSKeyValueObservation?
            private var didResume = false

            init(resumeSeconds: Double, onProgress: @escaping (Double, Double) -> Void) {
                self.resumeSeconds = resumeSeconds
                self.onProgress = onProgress
            }

            func attach(_ player: AVPlayer, item: AVPlayerItem) {
                self.player = player
                // Seek to the saved position once the item is ready, then play.
                readyObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard let self, item.status == .readyToPlay, !self.didResume else { return }
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
                // button binding, so no onClose here (avoids a double dismiss).
                if let player, let dur = player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                    onProgress(player.currentTime().seconds, dur)
                }
            }
        }
    }
}
#endif
