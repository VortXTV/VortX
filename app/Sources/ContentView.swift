import SwiftUI
import WebKit

/// Root: the live Stremio web UI, with captured streams presented full-screen in libmpv.
/// Playback progress from the native player is reported back into stremio-core so
/// Continue Watching updates (via injected `__stremioxProgress`), and closing exits
/// the web player route cleanly (`__stremioxExit`).
struct ContentView: View {
    @State private var nowPlaying: PlayItem?
    @State private var webView: WKWebView?

    var body: some View {
        StremioWebView(onPlay: { stream in nowPlaying = PlayItem(stream) },
                       onWebView: { webView = $0 })
            .ignoresSafeArea()
            .background(Color.black)
            .fullScreenCover(item: $nowPlaying) { item in
                PlayerScreen(url: item.url, title: item.title,
                             resumeSeconds: item.resumeSeconds, hasNext: item.hasNext,
                             onProgress: { time, duration in report("__stremioxProgress", time, duration) },
                             onSeek: { time, duration in report("__stremioxSeek", time, duration) },
                             onNext: { nextEpisode() },
                             onClose: { closePlayer() })
            }
    }

    /// Bridge native-player time into stremio-core (TimeChanged / Seek) so Continue Watching syncs.
    /// Time/duration are passed in seconds; the JS helper converts to the ms the core expects.
    private func report(_ fn: String, _ time: Double, _ duration: Double) {
        guard duration > 0, time >= 0, time.isFinite, duration.isFinite else { return }
        webView?.evaluateJavaScript(String(format: "window.%@ && window.%@(%.3f, %.3f)", fn, fn, time, duration),
                                    completionHandler: nil)
    }

    private func closePlayer() {
        // Leave the player route first; dismiss the cover a beat later so the web is already
        // back on the detail page when the cover lifts (no suppressed-video splash flash).
        webView?.evaluateJavaScript("window.__stremioxExit && window.__stremioxExit()", completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { nowPlaying = nil }
    }

    /// Navigate stremio-web to the next episode and return to it; the next stream's
    /// capture re-presents the native player automatically.
    private func nextEpisode() {
        webView?.evaluateJavaScript("window.__stremioxNext && window.__stremioxNext()", completionHandler: nil)
        nowPlaying = nil
    }
}

private struct PlayItem: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let resumeSeconds: Double
    let hasNext: Bool

    init(_ s: CapturedStream) {
        url = s.url
        title = s.title
        resumeSeconds = s.resumeSeconds
        hasNext = s.hasNext
    }
}
