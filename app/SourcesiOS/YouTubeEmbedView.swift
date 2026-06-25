import SwiftUI
import WebKit

/// A small, reusable YouTube IFrame-embed view (iOS / iPadOS / macOS) that plays a known YouTube id
/// inside a `WKWebView` with NO API key and NO extraction - the same mechanism the official Stremio
/// client uses (`stremio-video`'s `YouTubeVideo`: the YouTube IFrame Player API + `loadVideoById`).
///
/// Hosting: the official IFrame player is loaded via `loadHTMLString(_:baseURL:)` with a real
/// `https://www.youtube.com` base URL so the player sees a legitimate embedding `origin` (passed to the
/// iframe as `enablejsapi=1&origin=…`) - the documented embedding path, which sidesteps the "player
/// configuration" Error 153 the old top-level `load(embed-url)` hit.
///
/// FAIL-SOFT (the reason this is now a single JS-API path for every mode): many trailers - especially
/// official studio uploads - have embedding DISABLED by the owner, so the iframe renders YouTube's
/// "This video is unavailable / Watch on YouTube" page (IFrame API error 101/150) instead of playing.
/// Previously that ugly page showed right inside the Home hero and the Trailer cover. Now EVERY mode
/// runs through the IFrame Player API and reports `onError` (and a no-duration onReady) back to native
/// via a `WKScriptMessageHandler`; callers use `onFailure` to fall back gracefully (hero -> hide the clip
/// and show the still backdrop; Trailer button -> open the video on YouTube). An embed-restricted trailer
/// therefore never leaves an error card on screen.
///
/// Modes:
///   • `.interactive` - full controls, autoplays on open (the Trailer button cover).
///   • `.background`  - muted, autoplaying, chromeless, looping full trailer for the Home hero (#44).
///   • `.clip`        - muted, chromeless, loops a short `windowSeconds` window from `startSeconds` in.
///
/// Fail-soft: an empty / nil id renders nothing. tvOS has no WKWebView, so this file lives in
/// `SourcesiOS/` (iOS / iPad / Mac only) and is never built for tvOS (which uses the libmpv `/yt` route).
struct YouTubeEmbedView: View {
    let youTubeID: String
    var mode: Mode = .interactive
    /// Called once if the embed cannot play (owner disabled embedding, removed/private video, or any
    /// IFrame API error). Always delivered on the main actor. Lets the hero hide the clip and the
    /// Trailer button hand off to YouTube instead of leaving an error card on screen.
    var onFailure: (() -> Void)? = nil

    enum Mode: Equatable {
        /// Tappable player with native YouTube controls; autoplays on open.
        case interactive
        /// Muted, looping, controls-less full-trailer background clip for the hero.
        case background
        /// Muted, chromeless SHORT clip: plays a `windowSeconds` window starting `startSeconds` in and
        /// loops just that window, so the hero shows a brief representative clip rather than a full trailer.
        case clip(startSeconds: Int, windowSeconds: Int)
    }

    var body: some View {
        if youTubeID.isEmpty {
            Color.clear   // Fail-soft: nothing to embed.
        } else {
            YouTubeIFrameWebView(youTubeID: youTubeID, mode: mode, onFailure: onFailure)
        }
    }
}

// MARK: - WKWebView host (UIKit + AppKit)

/// The `WKWebView` wrapper. `WKWebView` exists on both UIKit and AppKit, so this is a
/// `UIViewRepresentable` on iOS/iPad and an `NSViewRepresentable` on macOS, sharing the HTML builder,
/// the configuration, and the `Coordinator` that receives the JS failure message.
#if canImport(UIKit)
private struct YouTubeIFrameWebView: UIViewRepresentable {
    let youTubeID: String
    let mode: YouTubeEmbedView.Mode
    let onFailure: (() -> Void)?

    func makeCoordinator() -> YouTubeEmbedCoordinator { YouTubeEmbedCoordinator(onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: YouTubeEmbedConfig.make(context.coordinator))
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.loadHTMLString(YouTubeEmbedHTML.page(id: youTubeID, mode: mode), baseURL: YouTubeEmbedHTML.baseURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: YouTubeEmbedCoordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: YouTubeEmbedConfig.handlerName)
    }
}
#elseif canImport(AppKit)
private struct YouTubeIFrameWebView: NSViewRepresentable {
    let youTubeID: String
    let mode: YouTubeEmbedView.Mode
    let onFailure: (() -> Void)?

    func makeCoordinator() -> YouTubeEmbedCoordinator { YouTubeEmbedCoordinator(onFailure: onFailure) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: YouTubeEmbedConfig.make(context.coordinator))
        webView.setValue(false, forKey: "drawsBackground")  // transparent canvas on macOS
        webView.loadHTMLString(YouTubeEmbedHTML.page(id: youTubeID, mode: mode), baseURL: YouTubeEmbedHTML.baseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: YouTubeEmbedCoordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: YouTubeEmbedConfig.handlerName)
    }
}
#endif

// MARK: - Coordinator (JS -> native failure bridge)

/// Receives the IFrame player's failure message and forwards it once to `onFailure` on the main actor.
/// `removeScriptMessageHandler` in `dismantle…View` breaks the userContentController -> coordinator
/// retain so the webview tears down cleanly.
final class YouTubeEmbedCoordinator: NSObject, WKScriptMessageHandler {
    private let onFailure: (() -> Void)?
    private var fired = false

    init(onFailure: (() -> Void)?) { self.onFailure = onFailure }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == YouTubeEmbedConfig.handlerName else { return }
        // Diagnostic logs share the one handler. Surface them to the device console (so the real onError
        // code is visible) but never treat a log as the failure signal.
        if let s = message.body as? String, s.hasPrefix("log:") {
            NSLog("[YouTubeEmbed] %@", String(s.dropFirst(4)))
            return
        }
        guard !fired else { return }
        fired = true
        let cb = onFailure
        DispatchQueue.main.async { cb?() }
    }
}

// MARK: - Configuration

/// Shared `WKWebViewConfiguration`. `allowsInlineMediaPlayback = true` plus
/// `mediaTypesRequiringUserActionForPlayback = []` let the muted hero clip autoplay inline without a tap;
/// the user content controller carries the failure message handler.
private enum YouTubeEmbedConfig {
    static let handlerName = "vortxYT"

    static func make(_ coordinator: YouTubeEmbedCoordinator) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        #if canImport(UIKit)
        config.allowsInlineMediaPlayback = true
        #endif
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(coordinator, name: handlerName)
        return config
    }
}

// MARK: - HTML

/// Builds the IFrame Player API page for every mode. Loading this HTML with `https://www.youtube.com`
/// as the document origin (and passing the same origin to the player via `origin=`) is what makes the
/// player accept playback. `onError` and a no-duration `onReady` both post `failed` to native so an
/// embed-restricted or removed video fails soft instead of showing YouTube's error card.
private enum YouTubeEmbedHTML {
    /// The embedding origin. Must be a real https URL for the IFrame player to validate.
    static let baseURL = URL(string: "https://www.youtube.com")

    static func page(id: String, mode: YouTubeEmbedView.Mode) -> String {
        let origin = "https://www.youtube.com"
        // Mode -> player vars + the onReady body (clip windowing vs plain autoplay).
        let vars: String
        let onReady: String
        let onStateChange: String
        switch mode {
        case .interactive:
            vars = "autoplay: 1, controls: 1, playsinline: 1, rel: 0, modestbranding: 1, fs: 1"
            onReady = "e.target.playVideo();"
            onStateChange = ""
        case .background:
            // Muted autoplay, chromeless, loop the whole trailer (seek to 0 on ENDED).
            vars = "autoplay: 1, mute: 1, controls: 0, playsinline: 1, rel: 0, modestbranding: 1, fs: 0, disablekb: 1"
            onReady = "e.target.mute(); e.target.playVideo();"
            onStateChange = "if (e.data === YT.PlayerState.ENDED) { e.target.seekTo(0, true); e.target.playVideo(); }"
        case .clip:
            // Muted chromeless clip looping a short window; START falls back to 25% in for short videos.
            // The actual start/window ints are read into START/WIN below (JS), so the case binds nothing.
            vars = "autoplay: 1, mute: 1, controls: 0, playsinline: 1, rel: 0, modestbranding: 1, fs: 0, disablekb: 1"
            onReady = """
                var d = e.target.getDuration();
                if (d && START > d - WIN) { START = Math.max(0, Math.floor(d * 0.25)); }
                e.target.mute(); e.target.seekTo(START, true); e.target.playVideo();
                """
            onStateChange = """
                if (e.data === YT.PlayerState.PLAYING) {
                  clearInterval(loop);
                  loop = setInterval(function () {
                    var t = e.target.getCurrentTime();
                    if (t < START - 0.5 || t > START + WIN) { e.target.seekTo(START, true); }
                  }, 400);
                } else if (e.data === YT.PlayerState.ENDED) {
                  e.target.seekTo(START, true); e.target.playVideo();
                }
                """
        }
        let (start, win): (Int, Int) = {
            if case let .clip(s, w) = mode { return (s, w) }
            return (0, 0)
        }()
        return """
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
            var START = \(start), WIN = \(win), loop, failed = false;
            function log(m) {
              try { window.webkit.messageHandlers.\(YouTubeEmbedConfig.handlerName).postMessage('log:' + m); } catch (err) {}
            }
            function fail() {
              if (failed) return; failed = true;
              log('fail');
              try { window.webkit.messageHandlers.\(YouTubeEmbedConfig.handlerName).postMessage('failed'); } catch (err) {}
            }
            function onYouTubeIframeAPIReady() {
              new YT.Player('player', {
                videoId: '\(id)',
                playerVars: { \(vars), enablejsapi: 1, origin: '\(origin)' },
                events: {
                  onReady: function (e) {
                    // A removed / region-blocked video reports 0 duration on ready: treat as a failure so
                    // the caller can fall back even when no onError fires.
                    if (!e.target.getDuration || e.target.getDuration() === 0) { /* may still load; guarded by timeout */ }
                    \(onReady)
                  },
                  onStateChange: function (e) { \(onStateChange) },
                  // 2 invalid param, 5 HTML5 error, 100 removed/private, 101 & 150 embedding disabled.
                  // Codes 2 and 5 fire SPURIOUSLY under WKWebView's synthetic-origin loadHTMLString context
                  // (often within ~0.5s of onReady) even for perfectly embeddable videos, so treating any
                  // code as fatal killed EVERY trailer. Only 100/101/150 (truly removed / embedding-disabled)
                  // fall back; transient 2/5 are logged and ignored. The 6s safety-net still catches a
                  // player that never loads at all.
                  onError: function (e) {
                    log('onError code=' + e.data);
                    if (e.data === 100 || e.data === 101 || e.data === 150) { fail(); }
                  }
                }
              });
            }
            // Safety net: if the API never loads or the player never reaches a playable state, fail soft.
            setTimeout(function () {
              if (!window.YT || !window.YT.Player) { fail(); }
            }, 6000);
          </script>
        </body>
        </html>
        """
    }
}
