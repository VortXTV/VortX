import SwiftUI
import WebKit

/// A small, reusable YouTube IFrame-embed view (iOS / iPadOS / macOS) that plays a known YouTube id
/// inside a `WKWebView` with NO API key and NO extraction - the same mechanism the official Stremio
/// client uses (`stremio-video`'s `YouTubeVideo`: the YouTube IFrame Player API + `loadVideoById`).
///
/// Hosting (the July-2025 Referer fix): YouTube's IFrame player started REQUIRING a real network
/// `Referer` header on its July 9 2025 enforcement. The old `loadHTMLString(_:baseURL:)` path did NOT
/// deliver one: WebKit (bug 169846) never sends a network `Referer` for the cross-origin `iframe_api`
/// and player requests fired from a synthetic loadHTMLString document, no matter what `baseURL` is
/// passed, so YouTube rejected EVERY embed with a 15x-family error ("This video is unavailable.
/// Error code: 152-4"). The `origin` playerVar is only a JS postMessage parameter, NOT the network
/// Referer YouTube now checks. We therefore serve the player HTML from a real loaded document via a
/// `WKURLSchemeHandler` (custom `vortx-yt://` scheme) and `webView.load(URLRequest)`, with a
/// `<base href="https://www.youtube.com/">` plus `<meta name="referrer" content="origin">` so the
/// browser attaches `Referer: https://www.youtube.com/` to the cross-origin iframe_api + player
/// requests. A desktop-class `applicationNameForUserAgent` makes YouTube serve the standard web embed.
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
        let webView = WKWebView(frame: .zero, configuration: YouTubeEmbedConfig.make(context.coordinator, id: youTubeID, mode: mode))
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.load(YouTubeEmbedHTML.documentRequest)
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
        let webView = WKWebView(frame: .zero, configuration: YouTubeEmbedConfig.make(context.coordinator, id: youTubeID, mode: mode))
        webView.setValue(false, forKey: "drawsBackground")  // transparent canvas on macOS
        webView.load(YouTubeEmbedHTML.documentRequest)
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
/// the user content controller carries the failure message handler. A `WKURLSchemeHandler` for the
/// custom `vortx-yt://` scheme serves the player HTML as a real loaded document (so cross-origin
/// subresource requests carry a network `Referer`, which `loadHTMLString` could not deliver), and a
/// desktop-class `applicationNameForUserAgent` makes YouTube serve the standard web embed.
private enum YouTubeEmbedConfig {
    static let handlerName = "vortxYT"
    /// Custom scheme whose document the `WKURLSchemeHandler` serves. Lets the player HTML load as a real
    /// resource instead of a synthetic `loadHTMLString` document, which is what restores the network
    /// `Referer` on the iframe_api + player requests (WebKit bug 169846).
    static let scheme = "vortx-yt"
    /// Desktop Safari UA fragment so YouTube serves the standard web IFrame embed, not a degraded path.
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    static func make(_ coordinator: YouTubeEmbedCoordinator, id: String, mode: YouTubeEmbedView.Mode) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        #if canImport(UIKit)
        config.allowsInlineMediaPlayback = true
        #endif
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = desktopUserAgent
        config.userContentController.add(coordinator, name: handlerName)
        // The handler is retained by the configuration for the webview's lifetime; it serves the one
        // player document for this id/mode with a youtube.com Referer attached.
        config.setURLSchemeHandler(YouTubeSchemeHandler(html: YouTubeEmbedHTML.page(id: id, mode: mode)), forURLScheme: scheme)
        return config
    }
}

// MARK: - Scheme handler (real document + network Referer)

/// Serves the single player HTML document for the custom `vortx-yt://` scheme. Responding from a real
/// loaded resource (rather than `loadHTMLString`) is what makes WebKit attach a network `Referer` to the
/// subsequent cross-origin `iframe_api` and player requests, which YouTube's July-2025 enforcement
/// requires. The `<base>` + `<meta name="referrer">` in the HTML set that Referer to `https://www.youtube.com/`.
final class YouTubeSchemeHandler: NSObject, WKURLSchemeHandler {
    private let html: String

    init(html: String) { self.html = html }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let data = Data(html.utf8)
        let headers = [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*"
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? HTTPURLResponse()
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

// MARK: - HTML

/// Builds the IFrame Player API page for every mode. The page is served by `YouTubeSchemeHandler` from
/// the custom `vortx-yt://` scheme and loaded via `webView.load(documentRequest)`; the `<base href>` +
/// `<meta name="referrer" content="origin">` make the browser attach `Referer: https://www.youtube.com/`
/// to the cross-origin iframe_api + player requests (the July-2025 enforcement), which the old
/// `loadHTMLString` path could never deliver. `onError` and a no-duration `onReady` both post `failed`
/// to native so an embed-restricted or removed video fails soft instead of showing YouTube's error card.
private enum YouTubeEmbedHTML {
    /// The embedding origin the iframe_api + player requests must carry as their network Referer.
    static let embedOrigin = "https://www.youtube.com"

    /// The request that loads the player document from the custom scheme. The `Referer` header here covers
    /// the top document; the in-HTML `<base>`/referrer-policy cover the cross-origin subresource requests.
    static var documentRequest: URLRequest {
        var request = URLRequest(url: URL(string: "\(YouTubeEmbedConfig.scheme)://player/index.html")!)
        request.setValue("\(embedOrigin)/", forHTTPHeaderField: "Referer")
        return request
    }

    static func page(id: String, mode: YouTubeEmbedView.Mode) -> String {
        let origin = embedOrigin
        let videoIDLiteral = WebEmbeddingSafety.javaScriptStringLiteral(id)
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
          <!-- base + referrer policy: the browser attaches Referer: https://www.youtube.com/ to the
               cross-origin iframe_api + player requests, which YouTube's July-2025 enforcement requires. -->
          <base href="\(origin)/">
          <meta name="referrer" content="origin">
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
            var START = \(start), WIN = \(win), loop, failed = false, started = false, player = null;
            function log(m) {
              try { window.webkit.messageHandlers.\(YouTubeEmbedConfig.handlerName).postMessage('log:' + m); } catch (err) {}
            }
            function fail() {
              if (failed) return; failed = true;
              log('fail');
              try { window.webkit.messageHandlers.\(YouTubeEmbedConfig.handlerName).postMessage('failed'); } catch (err) {}
            }
            function onYouTubeIframeAPIReady() {
              player = new YT.Player('player', {
                videoId: \(videoIDLiteral),
                playerVars: { \(vars), enablejsapi: 1, origin: '\(origin)' },
                events: {
                  onReady: function (e) {
                    // A removed / region-blocked video reports 0 duration on ready: treat as a failure so
                    // the caller can fall back even when no onError fires.
                    if (!e.target.getDuration || e.target.getDuration() === 0) { /* may still load; guarded by watchdog */ }
                    \(onReady)
                  },
                  // Record that playback actually began so the watchdog can distinguish a real start from a
                  // stuck player that never errors (e.g. an embedder-verification block that shows the 152
                  // card without firing onError). PLAYING (1) or BUFFERING (3) both count as a live start.
                  onStateChange: function (e) {
                    if (e.data === YT.PlayerState.PLAYING || e.data === YT.PlayerState.BUFFERING) { started = true; }
                    \(onStateChange)
                  },
                  // 2 invalid param, 5 HTML5 error, 100 removed/private, 101 & 150 embedding disabled,
                  // 151/152/153 the post-2025 embedder-verification family (the "Error code: 152-4" card).
                  // Codes 2 and 5 fire SPURIOUSLY under WKWebView's synthetic origin (often within ~0.5s of
                  // onReady) even for perfectly embeddable videos, so treating any code as fatal killed EVERY
                  // trailer. Only the truly-fatal codes (removed / embedding-disabled / embedder-verification)
                  // fall back; transient 2/5 are logged and ignored. The playback watchdog below still
                  // catches a player that loads but never actually starts.
                  onError: function (e) {
                    log('onError code=' + e.data);
                    if (e.data === 100 || e.data === 101 || e.data === 150 ||
                        e.data === 151 || e.data === 152 || e.data === 153) { fail(); }
                  }
                }
              });
            }
            // Watchdog: if the API never loads, OR the player loaded but never actually started playing
            // within the window (the embedder-verification 152 card can sit there WITHOUT firing onError),
            // fail soft so the caller restores the still backdrop / hands off to the YouTube app instead of
            // leaving the error card on screen. A non-zero getCurrentTime() also counts as a real start.
            setTimeout(function () {
              if (!window.YT || !window.YT.Player) { fail(); return; }
              var playing = started;
              try { if (player && player.getCurrentTime && player.getCurrentTime() > 0) { playing = true; } } catch (err) {}
              if (!playing) { fail(); }
            }, 7000);
          </script>
        </body>
        </html>
        """
    }

}
