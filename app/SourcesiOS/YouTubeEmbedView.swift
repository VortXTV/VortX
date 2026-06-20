import SwiftUI
import WebKit

/// A small, reusable YouTube IFrame-embed view (iOS / iPadOS / macOS) that plays a known YouTube id
/// inside a `WKWebView` with NO API key and NO extraction — the same mechanism the official Stremio
/// client uses (`stremio-video`'s `YouTubeVideo`: the YouTube IFrame Player API + `loadVideoById`).
///
/// Why this finally works where the old embed failed: the previous attempt did
/// `webView.load(URLRequest(url: youtube.com/embed/<id>))`, navigating to the embed as a TOP-LEVEL
/// document with no controllable origin/Referer — YouTube rejected that with "Error 153 — Video
/// player configuration error". This view instead hosts the official IFrame player via
/// `loadHTMLString(_:baseURL:)` with a real `https://www.youtube.com` base URL, so the player sees a
/// legitimate embedding `origin` (passed to the iframe as `enablejsapi=1&origin=…`). That is the
/// documented embedding path every website uses and is what sidesteps Error 153.
///
/// Two modes:
///   • `.interactive` — full controls, user-initiated playback (the detail-page Trailer button).
///   • `.background`  — muted, autoplaying, chromeless, looping clip for the Home hero (#44). Muted
///     autoplay is the only reliably-allowed autoplay on iOS/WKWebView, which is exactly what a hero
///     wants. `playsinline=1` keeps it inside our layout instead of forcing fullscreen.
///
/// Fail-soft: an empty / nil id renders nothing (callers gate on a resolved id). tvOS has no
/// WKWebView, so this whole file lives in `SourcesiOS/` (iOS/iPad/Mac only) and is never built for tvOS.
struct YouTubeEmbedView: View {
    let youTubeID: String
    var mode: Mode = .interactive

    enum Mode {
        /// Tappable player with native YouTube controls.
        case interactive
        /// Muted, looping, controls-less background clip for the hero.
        case background
        /// Muted, chromeless SHORT clip: plays a `windowSeconds` window starting `startSeconds` in and
        /// loops just that window, so the hero shows a brief representative clip rather than a full
        /// trailer. Uses the IFrame Player API so it can seek-loop a sub-window (URL loop only loops
        /// the whole video).
        case clip(startSeconds: Int, windowSeconds: Int)
    }

    var body: some View {
        if youTubeID.isEmpty {
            // Fail-soft: nothing to embed.
            Color.clear
        } else {
            YouTubeIFrameWebView(youTubeID: youTubeID, mode: mode)
        }
    }
}

// MARK: - WKWebView host (UIKit + AppKit)

/// The `WKWebView` wrapper. `WKWebView` exists on both UIKit and AppKit, so this is a
/// `UIViewRepresentable` on iOS/iPad and an `NSViewRepresentable` on macOS, sharing the HTML builder
/// and the configuration (which must enable inline + non-user-action playback for autoplay to work).
#if canImport(UIKit)
private struct YouTubeIFrameWebView: UIViewRepresentable {
    let youTubeID: String
    let mode: YouTubeEmbedView.Mode

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: YouTubeEmbedConfig.make())
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.loadHTMLString(YouTubeEmbedHTML.page(id: youTubeID, mode: mode),
                               baseURL: YouTubeEmbedHTML.baseURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#elseif canImport(AppKit)
private struct YouTubeIFrameWebView: NSViewRepresentable {
    let youTubeID: String
    let mode: YouTubeEmbedView.Mode

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: YouTubeEmbedConfig.make())
        webView.setValue(false, forKey: "drawsBackground")  // transparent canvas on macOS
        webView.loadHTMLString(YouTubeEmbedHTML.page(id: youTubeID, mode: mode),
                               baseURL: YouTubeEmbedHTML.baseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
#endif

// MARK: - Configuration

/// Shared `WKWebViewConfiguration`. `allowsInlineMediaPlayback = true` plus
/// `mediaTypesRequiringUserActionForPlayback = []` are required so the muted hero clip can autoplay
/// inline without a tap; the interactive trailer simply uses its native controls.
private enum YouTubeEmbedConfig {
    static func make() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        #if canImport(UIKit)
        config.allowsInlineMediaPlayback = true
        #endif
        config.mediaTypesRequiringUserActionForPlayback = []
        return config
    }
}

// MARK: - HTML

/// Builds the IFrame-player HTML. The single most important detail is `baseURL`: loading this HTML
/// with `https://www.youtube.com` as the document origin (and passing the same origin to the iframe
/// via `origin=`) is what makes the YouTube IFrame player accept playback — without it the player
/// returns Error 153. The body is edge-to-edge black with a 16:9-filling iframe.
private enum YouTubeEmbedHTML {
    /// The embedding origin. Must be a real https URL for the IFrame player to validate.
    static let baseURL = URL(string: "https://www.youtube.com")

    static func page(id: String, mode: YouTubeEmbedView.Mode) -> String {
        let origin = "https://www.youtube.com"
        // Common params. `playsinline=1` (no forced fullscreen), `rel=0` (no unrelated end-cards),
        // `modestbranding=1`, `enablejsapi=1` + `origin` (the embedding handshake), `fs` controls the
        // fullscreen button.
        let params: String
        switch mode {
        case .interactive:
            params = "playsinline=1&rel=0&modestbranding=1&enablejsapi=1&fs=1&origin=\(origin)"
        case .background:
            // Muted autoplay + loop (loop needs `playlist=<id>`), chromeless.
            params = "autoplay=1&mute=1&controls=0&loop=1&playlist=\(id)&playsinline=1&rel=0&modestbranding=1&enablejsapi=1&fs=0&origin=\(origin)"
        case .clip(let start, let seconds):
            // A short looped window needs the JS API (URL `loop` only loops the whole video).
            return clipPage(id: id, origin: origin, start: start, seconds: seconds)
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <style>
            * { margin: 0; padding: 0; }
            html, body { width: 100%; height: 100%; background: #000; overflow: hidden; }
            .frame { position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0; }
          </style>
        </head>
        <body>
          <iframe class="frame"
                  src="https://www.youtube.com/embed/\(id)?\(params)"
                  frameborder="0"
                  allow="autoplay; encrypted-media; picture-in-picture"
                  allowfullscreen>
          </iframe>
        </body>
        </html>
        """
    }

    /// IFrame Player API page for a short, muted, looping clip WINDOW (the hero "5-6 second clip"): plays
    /// a `seconds`-long window starting `start` seconds in and seeks back to keep looping only that window.
    /// Starting a few seconds in skips studio/title cards so the window lands on real footage; when the
    /// fixed start would overrun a short video it falls back to 25% in. Muted + chromeless + playsinline,
    /// the only reliably-allowed inline autoplay on iOS/WKWebView.
    static func clipPage(id: String, origin: String, start: Int, seconds: Int) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <style>
            * { margin: 0; padding: 0; }
            html, body { width: 100%; height: 100%; background: #000; overflow: hidden; }
            #player { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
          </style>
        </head>
        <body>
          <div id="player"></div>
          <script src="https://www.youtube.com/iframe_api"></script>
          <script>
            var START = \(start), WIN = \(seconds), loop;
            function onYouTubeIframeAPIReady() {
              new YT.Player('player', {
                videoId: '\(id)',
                playerVars: { autoplay: 1, mute: 1, controls: 0, playsinline: 1, rel: 0,
                              modestbranding: 1, fs: 0, disablekb: 1, enablejsapi: 1, origin: '\(origin)' },
                events: {
                  onReady: function (e) {
                    var d = e.target.getDuration();
                    if (d && START > d - WIN) { START = Math.max(0, Math.floor(d * 0.25)); }
                    e.target.mute();
                    e.target.seekTo(START, true);
                    e.target.playVideo();
                  },
                  onStateChange: function (e) {
                    if (e.data === YT.PlayerState.PLAYING) {
                      clearInterval(loop);
                      loop = setInterval(function () {
                        var t = e.target.getCurrentTime();
                        if (t < START - 0.5 || t > START + WIN) { e.target.seekTo(START, true); }
                      }, 400);
                    } else if (e.data === YT.PlayerState.ENDED) {
                      e.target.seekTo(START, true);
                      e.target.playVideo();
                    }
                  }
                }
              });
            }
          </script>
        </body>
        </html>
        """
    }
}
